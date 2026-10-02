"""T-049: dispatch-authorized immutable snapshots, shared by all pin consumers.

The state store is outside worker write authority. Hashes detect corruption;
committed self sources additionally verify against git. Dispatch-time external
approval does not claim a pre-answer proposal binding.
"""
import argparse
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

    def approval(self, decision=None):
        events = self.events()
        for event in reversed(events):
            data = event.get('data') or {}
            if event.get('type') != 'decision_made' or event.get('task') != self.task:
                continue
            id = data.get('decision', '')
            if decision and id != decision:
                continue
            if not re.fullmatch(r'[A-Za-z0-9_-]+', id):
                continue
            path = self.state / 'decisions' / (id + '.json')
            if not path.is_file() or path.is_symlink():
                continue
            answer = json.loads(path.read_text())
            if (event.get('actor') != 'captain' or data.get('chosen') != 'A'
                    or answer.get('chosen') != 'A' or answer.get('kind', 'choice') != 'choice'
                    or answer.get('task') != self.task or answer.get('id') != id
                    or answer.get('project', 'firstmate-workflow') != self.project):
                continue
            if not event.get('ts'):
                continue
            return dict(kind='choice', decision=id, author='captain', time=event['ts'],
                        event=event, answer=answer)
        if decision:
            raise ValueError('missing or mismatched captain authorization for project/task/decision')
        # A readiness card which has not been authorized must not become a
        # direct order merely because an older global greenlight exists.
        if any(e.get('task') == self.task and e.get('type') in ('decision_requested', 'decision_made')
               for e in events):
            return None
        for event in reversed(events):
            if event.get('type') == 'greenlit' and event.get('ts'):
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

    def resolve(self):
        paths = sorted(self.directory.glob('*.json'), key=lambda p: int(p.stem) if p.stem.isdigit() else -1)
        if not paths:
            raise ValueError('no pin for ' + self.project + '/' + self.task)
        previous = None
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
            elif approval['kind'] != 'direct-order' or version != 1 or approval['event'].get('type') != 'greenlit':
                raise ValueError('pin authorization mismatch')
            if approval['time'] != approval['event'].get('ts'):
                raise ValueError('pin approval time mismatch')
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
        return previous

    def create(self, decision=None, resume=False):
        if list(self.directory.glob('*.json')) and not decision:
            return self.resolve()
        approval = self.approval(decision)
        if approval is None:
            return None
        if decision and not list(self.directory.glob('*.json')):
            raise ValueError('repin requires an existing pin')
        engine, target, snapshots, parsed = self.collect(repin=bool(decision))
        if decision:
            old = self.resolve()
            self.check_repin(old, decision, snapshots)
        self.directory.mkdir(parents=True, exist_ok=True)
        lock = self.directory / '.lock'
        if lock.is_symlink():
            raise ValueError('pin lock must not be a symlink')
        with lock.open('a') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            old = self.resolve() if list(self.directory.glob('*.json')) else None
            if old and not decision:
                return old
            if decision:
                self.check_repin(old, decision, snapshots)
            pin = dict(schema=1, project=self.project, task=self.task, external=self.external,
                       version=old['version'] + 1 if old else 1, engine_commit=engine,
                       target_base_commit=target, snapshots=snapshots, contract=parsed,
                       source='repin' if decision else ('first-pin-on-resume' if resume else 'dispatch'),
                       approval=approval, approval_binding='dispatch-time',
                       previous_sha256=digest(json.dumps(old, sort_keys=True)) if old else None)
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

    def check_repin(self, old, decision, snapshots):
        if not old:
            raise ValueError('repin requires an existing pin')
        for path in self.directory.glob('*.json'):
            if json.loads(path.read_text())['approval']['decision'] == decision:
                raise ValueError('repin decision already used')
        if all(old['snapshots'][key]['sha256'] == snap['sha256'] for key, snap in snapshots.items()):
            raise ValueError('snapshots unchanged; no repin written')

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
    parser.add_argument('--head')
    parser.add_argument('--base', default='main')
    args = parser.parse_args()
    try:
        pins = Pins(os.environ, args.task)
        if args.command == 'create':
            pin = pins.create(args.decision, args.resume)
            if pin is None:
                print('fm-pin: no dispatch authorization; no pin written', file=sys.stderr)
                return 3
        elif args.command == 'scope':
            pin = pins.scope(args.head, args.base)
        else:
            pin = pins.resolve()
        print(json.dumps(pin))
        return 0
    except (ValueError, OSError, KeyError, TypeError) as error:
        print('fm-pin: ' + str(error), file=sys.stderr)
        return 65


if __name__ == '__main__':
    sys.exit(main())
