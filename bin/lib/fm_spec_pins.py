"""T-049: dispatch-authorized immutable snapshots, shared by all pin consumers.

The state store is outside worker write authority. Hashes detect corruption;
committed self sources additionally verify against git. Dispatch-time external
approval does not claim a pre-answer proposal binding.
"""
import argparse
from datetime import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from fm_project_paths import registry_reader


# The engine revision that first required task-specific dispatch authority.
# A backdated greenlight alone cannot make a newly written pin legacy.
TASK_DISPATCH_COMMIT = 'f61b71457f18c4aec744ae1b9ff84b1bd5b84728'
LEGACY_REASON = 'Pre-T-171 cross-task direct-order approval replaced by this task captain choice'


def digest(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def git(root, *args):
    result = subprocess.run(['git', '-C', str(root), *args], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise ValueError('git source unavailable: ' + ' '.join(args))
    return result.stdout.decode('utf-8')


def contract(text, project):
    """Use the engine parser for all fields, with legacy or relocated project:."""
    reader = registry_reader()
    if reader is None:
        raise ValueError('contract parser unavailable')
    lines = text.splitlines()
    if not any(re.match(r'^project:\s*(?:#.*)?$', line) for line in lines):
        projects = reader._config_key(lines, 'projects')
        entry = reader._config_key(projects[1], project) if projects else None
        block = reader._config_key(entry[1], 'project') if entry else None
        if block:
            body = block[1]
            indent = min((len(s) - len(s.lstrip()) for s in body if s.strip()), default=0)
            text = 'project:\n' + '\n'.join('  ' + s[indent:] for s in body) + '\n'
        else:
            raise ValueError('no approved gate contract')
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8') as stream:
        stream.write(text)
        stream.flush()
        return reader.project_contract(stream.name)


class Pins:
    def __init__(self, env, task):
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', task):
            raise ValueError('invalid pin task')
        self.task = task
        self.engine = Path(env['FM_ENGINE_ROOT'])
        self.target = Path(env['FM_TARGET_ROOT'])
        self.state = Path(env['FM_STATE_DIR'])
        self.external = env.get('FM_EXTERNAL') == '1'
        self.project = env.get('FM_PROJECT') or 'firstmate-workflow'
        self.tasks = Path(env['FM_TASKS_DIR'])
        self.design = Path(env['FM_DESIGN'])
        self.directory = self.state / 'pins' / task
        self.base = env.get('FM_BASE') or 'main'
        self.engine_base = 'main' if self.external else self.base
        for path in (self.state, self.state / 'pins', self.directory):
            if path.is_symlink():
                raise ValueError('pin store must not be a symlink')

    def events(self):
        path = self.state / 'events.jsonl'
        if not path.exists():
            return []
        events = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        return [e for e in events if e.get('project', 'firstmate-workflow') == self.project]

    def readiness_decision(self):
        # fm-ready retires this record on dispatch. The ended card still names
        # the dispatch judgment when a first pin is created on a later round.
        path = self.state / 'ready' / (self.task + '.json')
        if path.is_file() and not path.is_symlink():
            record = json.loads(path.read_text())
            if record.get('task') == self.task:
                return record.get('decision') if record.get('episode') else record.get('ended')
        return None

    def answer(self, decision):
        if not isinstance(decision, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', decision):
            return None
        path = self.state / 'decisions' / (decision + '.json')
        if not path.is_file() or path.is_symlink():
            return None
        answer = json.loads(path.read_text())
        if (answer.get('chosen') == 'A' and answer.get('kind', 'choice') == 'choice'
                and answer.get('task') == self.task and answer.get('id') == decision
                and answer.get('project', 'firstmate-workflow') == self.project):
            return answer
        return None

    def approval(self, decision=None):
        events = self.events()
        readiness = self.readiness_decision() if not decision else None
        for event in reversed(events):
            data = event.get('data') or {}
            if event.get('type') != 'decision_made' or event.get('task') != self.task:
                continue
            id = data.get('decision', '')
            if id != (decision or readiness):
                continue
            answer = self.answer(id)
            if (answer is None or event.get('actor') != 'captain'
                    or data.get('chosen') != 'A'):
                continue
            if not event.get('ts'):
                continue
            return dict(kind='choice', decision=id, author='captain', time=event['ts'],
                        event=event, answer=answer)
        if decision:
            raise ValueError('missing or mismatched captain authorization for project/task/decision')

        for event in reversed(events):
            if (event.get('type') == 'greenlit'
                    and event.get('ts')
                    and (event.get('task') == self.task
                         or (not event.get('task')
                             and (not readiness or self.answer(readiness) is not None)))):
                return dict(kind='direct-order', decision=event.get('id') or 'greenlit:' + event['ts'],
                            author='captain', time=event['ts'], event=event)
        return None

    def snapshot(self, path, commit, *, local=False, optional=False, seeded=False):
        rel = str(path.relative_to(self.engine)) if not self.external else str(path)
        text = None
        if not self.external:
            try:
                text = git(self.engine, 'show', commit + ':' + rel)
            except ValueError:
                if not (local or seeded or optional):
                    raise
        if self.external or local or (text is None and seeded):
            if path.is_file():
                current = path.read_bytes().decode('utf-8')
                if text != current:
                    text = current
                    source = 'local' if self.external else ('seeded' if seeded else 'uncommitted')
                    return dict(text=text, sha256=digest(text), source=source, path=rel)
            elif not optional:
                raise ValueError('missing approved source: ' + str(path))
            elif local:
                return dict(text='', sha256=digest(''), source='uncommitted', path=rel, absent=True)
        if text is None:
            if not optional:
                raise ValueError('missing approved source: ' + str(path))
            return dict(text='', sha256=digest(''), source='absent', path=rel,
                        **({} if self.external else {'commit': commit}))
        return dict(text=text, sha256=digest(text), source='committed', path=rel, commit=commit)

    def collect(self, repin=False):
        engine_commit = git(self.engine, 'rev-parse', self.engine_base + '^{commit}').strip()
        target_commit = git(self.target, 'rev-parse', self.base + '^{commit}').strip()
        conventions = self.state.parent / 'CONVENTIONS.md' if self.external else self.engine / 'CONVENTIONS.md'
        snapshots = dict(
            spec=self.snapshot(self.tasks / (self.task + '.json'), engine_commit, local=repin, seeded=not repin),
            design=self.snapshot(self.design, engine_commit, local=repin),
            conventions=self.snapshot(conventions, engine_commit, local=repin, optional=not self.external))
        path = self.state / 'config.yaml' if self.external else self.engine / 'config.yaml'
        # Legacy external registry contracts are captured as local data too.
        if self.external and not path.is_file():
            path = self.engine / 'config.yaml'
        snapshots['contract'] = self.snapshot(path, engine_commit)
        parsed = contract(snapshots['contract']['text'], self.project)
        spec = json.loads(snapshots['spec']['text'])
        if spec.get('id') != self.task or not isinstance(spec.get('scope'), list) or not spec['scope']:
            raise ValueError('invalid approved task scope')
        if not all(isinstance(s, str) and s and '\n' not in s for s in spec['scope']):
            raise ValueError('invalid approved scope glob')
        return engine_commit, target_commit, snapshots, parsed

    def legacy_approval(self, pin):
        """Recognize only the historical cross-task first-pin approval class.

        Pins have engine provenance, not a separate creation timestamp. Require
        a strict ancestor of the T-171 engine revision; missing history refuses
        migration rather than treating an unknown revision as old.
        """
        approval = pin['approval']
        event = approval.get('event', {})
        if (pin['version'] != 1 or approval.get('kind') != 'direct-order'
                or event.get('type') != 'greenlit'
                or not isinstance(event.get('task'), str)
                or event['task'] in ('', self.task)
                or pin['engine_commit'] == TASK_DISPATCH_COMMIT):
            return False
        try:
            ancestor = git(self.engine, 'merge-base', pin['engine_commit'], TASK_DISPATCH_COMMIT + '^').strip()
        except ValueError:
            return False
        return ancestor == pin['engine_commit']

    def resolve(self, if_present=False, *, for_repin=False):
        # A leftover lock/temp file is not a pin. Enumerate explicitly so an
        # unreadable store is an error, never silently treated as absent.
        records = [p for p in self.directory.iterdir() if p.name.endswith('.json')] if self.directory.exists() else []
        paths = sorted(records, key=lambda p: int(p.stem) if p.stem.isdigit() else -1)
        if not paths and if_present:
            return None
        if not paths:
            raise ValueError('no pin for ' + self.project + '/' + self.task)
        previous = None
        legacy_version = None
        for version, path in enumerate(paths, 1):
            if path.is_symlink() or path.name != str(version) + '.json':
                raise ValueError('invalid append-only pin sequence')
            pin = json.loads(path.read_text())
            if (pin.get('project') != self.project or pin.get('task') != self.task
                    or pin.get('version') != version or pin.get('schema') != 1
                    or pin.get('external') != self.external):
                raise ValueError('pin identity/version mismatch')
            if pin.get('previous_sha256') != (digest(json.dumps(previous, sort_keys=True)) if previous else None):
                raise ValueError('pin history hash mismatch')
            for field in ('engine_commit', 'target_base_commit'):
                if not re.fullmatch(r'[0-9a-f]{40,64}', pin.get(field, '')):
                    raise ValueError('invalid ' + field + ' provenance')
            if pin.get('approval_binding') != 'dispatch-time':
                raise ValueError('unsupported approval binding')
            approval = pin['approval']
            if (approval.get('author') != 'captain' or not approval.get('time')
                    or approval.get('event') not in self.events()):
                raise ValueError('pin approval provenance mismatch')
            if approval['kind'] == 'choice':
                answer = approval['answer']
                decision_id = approval['decision']
                if not re.fullmatch(r'[A-Za-z0-9_-]+', decision_id):
                    raise ValueError('invalid approval decision identity')
                receipt_path = self.state / 'decisions' / (decision_id + '.json')
                if receipt_path.is_symlink():
                    raise ValueError('approval receipt must not be a symlink')
                receipt = json.loads(receipt_path.read_text())
                for field in ('id', 'task', 'project', 'chosen', 'kind', 'ts'):
                    if receipt.get(field) != answer.get(field):
                        raise ValueError('pin approval receipt provenance mismatch')
                event = approval['event']
                if (answer.get('id') != approval['decision'] or answer.get('task') != self.task
                        or answer.get('project', 'firstmate-workflow') != self.project
                        or answer.get('chosen') != 'A' or answer.get('kind', 'choice') != 'choice'
                        or event.get('actor') != 'captain' or event.get('type') != 'decision_made'
                        or event.get('task') != self.task or event.get('data', {}).get('chosen') != 'A'
                        or event.get('data', {}).get('decision') != approval['decision']):
                    raise ValueError('pin approval provenance mismatch')
            elif (approval['kind'] != 'direct-order' or version != 1
                  or approval['event'].get('type') != 'greenlit'
                  or approval['event'].get('task') not in (None, '', self.task)):
                if not self.legacy_approval(pin):
                    raise ValueError('pin authorization mismatch')
                legacy_version = version
            if 'supersedes_legacy' in pin or 'supersedes_legacy_reason' in pin:
                if (pin.get('supersedes_legacy') != legacy_version or legacy_version is None
                        or version != legacy_version + 1 or pin.get('source') != 'repin'
                        or approval['kind'] != 'choice'
                        or not isinstance(pin.get('supersedes_legacy_reason'), str)
                        or not pin['supersedes_legacy_reason'].strip()):
                    raise ValueError('invalid legacy supersession')
            if approval['time'] != approval['event'].get('ts'):
                raise ValueError('pin approval time mismatch')
            if previous:
                self.check_approval_order(previous.get('spec_approval', previous['approval']), approval)
            spec_approval = pin.get('spec_approval')
            if spec_approval:
                if version != 1 or pin['source'] != 'first-pin-on-resume' or self.external:
                    raise ValueError('invalid branch spec approval')
                current = self.approval(spec_approval['decision'])
                if (any(current.get(key) != spec_approval.get(key)
                        for key in ('kind', 'decision', 'author', 'time', 'event'))
                        or any(current['answer'].get(key) != spec_approval['answer'].get(key)
                               for key in ('id', 'task', 'project', 'chosen', 'kind', 'ts', 'expected_head'))):
                    raise ValueError('branch spec approval provenance mismatch')
                self.check_approval_order(approval, spec_approval)
                if pin['snapshots']['spec']['source'] != 'approved-branch':
                    raise ValueError('branch approval requires branch snapshot')
            if set(pin['snapshots']) != {'spec', 'design', 'conventions', 'contract'}:
                raise ValueError('incomplete pin snapshots')
            expected = {
                'spec': str(self.tasks / (self.task + '.json')),
                'design': str(self.design),
                'conventions': str(self.state.parent / 'CONVENTIONS.md' if self.external
                                   else self.engine / 'CONVENTIONS.md'),
                'contract': str(self.state / 'config.yaml' if self.external else self.engine / 'config.yaml'),
            }
            for name, snap in pin['snapshots'].items():
                expected_path = expected[name] if self.external else str(Path(expected[name]).relative_to(self.engine))
                allowed_paths = {expected_path}
                if self.external and name == 'contract':
                    allowed_paths.add(str(self.engine / 'config.yaml'))
                if snap.get('path') not in allowed_paths:
                    raise ValueError(name + ' source path provenance mismatch')
                if digest(snap['text']) != snap['sha256']:
                    raise ValueError(name + ' snapshot hash mismatch')
                source = snap['source']
                if source == 'committed':
                    if self.external or snap.get('commit') != pin['engine_commit']:
                        raise ValueError('invalid committed provenance')
                    if git(self.engine, 'show', snap['commit'] + ':' + snap['path']) != snap['text']:
                        raise ValueError(name + ' committed provenance mismatch')
                elif source == 'absent':
                    if name != 'conventions' or self.external or snap['text']:
                        raise ValueError('invalid absent provenance')
                    try:
                        git(self.engine, 'show', snap['commit'] + ':' + snap['path'])
                    except ValueError:
                        pass
                    else:
                        raise ValueError('absent provenance mismatch')
                elif source == 'approved-branch':
                    if self.external or name != 'spec' or not spec_approval:
                        raise ValueError('invalid branch snapshot provenance')
                    head = spec_approval['answer'].get('expected_head', '')
                    if not re.fullmatch(r'[0-9a-f]{40,64}', head) or snap.get('commit') != head:
                        raise ValueError('branch spec commit mismatch')
                    if git(self.engine, 'show', head + ':' + snap['path']) != snap['text']:
                        raise ValueError('branch spec bytes mismatch')
                elif source not in (('local',) if self.external else ('seeded', 'uncommitted')):
                    raise ValueError('invalid snapshot provenance')
                if not self.external and source == 'seeded':
                    if name != 'spec' or version != 1:
                        raise ValueError('invalid seeded provenance')
                    try:
                        git(self.engine, 'show', pin['engine_commit'] + ':' + snap['path'])
                    except ValueError:
                        pass
                    else:
                        raise ValueError('seeded source already exists on approved base')
                if not self.external and source == 'uncommitted' and (version == 1 or approval['kind'] != 'choice'):
                    raise ValueError('uncommitted source requires authorized repin')
                if name == 'contract' and not self.external and source != 'committed':
                    raise ValueError('self contract must come from accepted engine base')
            if contract(pin['snapshots']['contract']['text'], self.project) != pin['contract']:
                raise ValueError('contract snapshot mismatch')
            spec = json.loads(pin['snapshots']['spec']['text'])
            if (spec.get('id') != self.task or not isinstance(spec.get('scope'), list)
                    or not spec['scope'] or not all(isinstance(s, str) and s and '\n' not in s for s in spec['scope'])):
                raise ValueError('invalid pinned task scope')
            previous = pin
        # Older chains can already contain valid choice-approved successors
        # without a migration marker. Never rewrite those historical records.
        if legacy_version == previous['version'] and not for_repin:
            raise ValueError('pin authorization mismatch')
        return previous

    def approved_branch_spec(self, worktree, snapshots, dispatch):
        """Only a captain choice naming the exact proposed commit can widen pin 1.

        expected_head is already carried by choice requests and answer receipts.
        Human prose alone cannot establish approval of arbitrary branch bytes.
        """
        snap = snapshots['spec']
        path = Path(worktree) / snap['path']
        if not path.is_file() or path.is_symlink():
            return None
        text = path.read_bytes().decode('utf-8')
        if text == snap['text']:
            return None
        for event in reversed(self.events()):
            if event.get('type') != 'decision_made' or event.get('task') != self.task:
                continue
            decision = (event.get('data') or {}).get('decision')
            if not decision or decision == dispatch['decision']:
                continue
            try:
                approval = self.approval(decision)
                self.check_approval_order(dispatch, approval)
                head = approval['answer'].get('expected_head', '')
                if not isinstance(head, str) or not re.fullmatch(r'[0-9a-f]{40,64}', head):
                    continue
                if git(self.engine, 'show', head + ':' + snap['path']) != text:
                    continue
            except ValueError:
                continue
            snapshots['spec'] = dict(text=text, sha256=digest(text), source='approved-branch',
                                     path=snap['path'], commit=head)
            return approval
        return None

    def create(self, decision=None, resume=False, spec_worktree=None):
        if list(self.directory.glob('*.json')) and not decision:
            return self.resolve()
        approval = self.approval(decision)
        if approval is None:
            return None
        if decision and not list(self.directory.glob('*.json')):
            raise ValueError('repin requires an existing pin')
        engine, target, snapshots, parsed = self.collect(repin=bool(decision))
        spec_approval = None
        if resume and not decision and not self.external and spec_worktree:
            spec_approval = self.approved_branch_spec(spec_worktree, snapshots, approval)
            spec = json.loads(snapshots['spec']['text'])
            if (spec.get('id') != self.task or not isinstance(spec.get('scope'), list)
                    or not spec['scope'] or not all(isinstance(s, str) and s and '\n' not in s
                                                   for s in spec['scope'])):
                raise ValueError('invalid approved branch task scope')
        if decision:
            old = self.resolve(for_repin=True)
            self.check_repin(old, decision, snapshots, approval)
        self.directory.mkdir(parents=True, exist_ok=True)
        lock = self.directory / '.lock'
        if lock.is_symlink():
            raise ValueError('pin lock must not be a symlink')
        with lock.open('a') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            old = self.resolve(for_repin=bool(decision)) if list(self.directory.glob('*.json')) else None
            if old and not decision:
                return old
            if decision:
                self.check_repin(old, decision, snapshots, approval)
            pin = dict(schema=1, project=self.project, task=self.task, external=self.external,
                       version=old['version'] + 1 if old else 1, engine_commit=engine,
                       target_base_commit=target, snapshots=snapshots, contract=parsed,
                       source='repin' if decision else ('first-pin-on-resume' if resume else 'dispatch'),
                       approval=approval, approval_binding='dispatch-time',
                       previous_sha256=digest(json.dumps(old, sort_keys=True)) if old else None)
            if old and self.legacy_approval(old):
                pin['supersedes_legacy'] = old['version']
                pin['supersedes_legacy_reason'] = LEGACY_REASON
            if spec_approval:
                pin['spec_approval'] = spec_approval
            # Publish fully written bytes atomically, without replacing any record.
            with tempfile.NamedTemporaryFile(mode='w', dir=self.directory, delete=False) as out:
                temporary = Path(out.name)
                json.dump(pin, out, indent=2)
                out.write('\n'); out.flush(); os.fsync(out.fileno())
            try:
                os.link(temporary, self.directory / (str(pin['version']) + '.json'))
            finally:
                temporary.unlink()
            return pin

    def check_repin(self, old, decision, snapshots, approval):
        if not old:
            raise ValueError('repin requires an existing pin')
        for path in self.directory.glob('*.json'):
            record = json.loads(path.read_text())
            if decision in (record['approval']['decision'], record.get('spec_approval', {}).get('decision')):
                raise ValueError('repin decision already used')
        self.check_approval_order(old.get('spec_approval', old['approval']), approval)
        if (not self.legacy_approval(old)
                and all(old['snapshots'][key]['sha256'] == snap['sha256'] for key, snap in snapshots.items())):
            raise ValueError('snapshots unchanged; no repin written')

    @staticmethod
    def check_approval_order(previous, current):
        try:
            before = datetime.fromisoformat(previous['time'].replace('Z', '+00:00'))
            after = datetime.fromisoformat(current['time'].replace('Z', '+00:00'))
            valid = before.tzinfo is not None and after.tzinfo is not None and after > before
        except (ValueError, TypeError):
            valid = False
        if not valid:
            raise ValueError('repin requires approval newer than the superseded pin approval')

    def scope(self, head, base):
        import fnmatch
        pin = self.resolve()
        spec = json.loads(pin['snapshots']['spec']['text'])
        if not self.external:
            try:
                actual = git(self.target, 'show', head + ':' + pin['snapshots']['spec']['path'])
            except ValueError:
                actual = ''
            if actual != pin['snapshots']['spec']['text']:
                raise ValueError('self task entry differs from pin')
        paths = git(self.target, 'diff', '--no-renames', '--name-only', '-z', base + '...' + head).split('\0')
        for path in filter(None, paths):
            if any(part.startswith('.fm-') for part in Path(path).parts):
                raise ValueError('forbidden .fm-* path: ' + path)
            if not any(fnmatch.fnmatchcase(path, pattern) for pattern in spec['scope']):
                raise ValueError('out of scope: ' + path)
        return pin


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['create', 'resolve', 'scope'])
    parser.add_argument('--task', required=True)
    parser.add_argument('--decision')
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--spec-worktree')
    parser.add_argument('--if-present', action='store_true')
    parser.add_argument('--head')
    parser.add_argument('--base', default='main')
    args = parser.parse_args()
    try:
        pins = Pins(os.environ, args.task)
        if args.command == 'create':
            pin = pins.create(args.decision, args.resume, args.spec_worktree)
            if pin is None:
                print('fm-pin: no dispatch authorization; no pin written', file=sys.stderr)
                return 3
        elif args.command == 'scope':
            pin = pins.scope(args.head, args.base)
        else:
            pin = pins.resolve(if_present=args.if_present)
            if pin is None:
                return 3
        print(json.dumps(pin))
        return 0
    except (ValueError, OSError, KeyError, TypeError) as error:
        print('fm-pin: ' + str(error), file=sys.stderr)
        return 65


if __name__ == '__main__':
    sys.exit(main())
