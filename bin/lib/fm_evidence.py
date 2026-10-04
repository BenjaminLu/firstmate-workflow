#!/usr/bin/env python3
"""Trusted, outside-round local evidence writer and readers (T-135).

The OS sandbox protects this directory from crews. These are durable receipts,
not credentials: copying a JSON object out of an untrusted checkout grants no
provenance. Callers resolve the state root from the operator's configuration.
"""
import argparse
import datetime
import fcntl
import hashlib
import hmac
import secrets
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import uuid

KINDS = {'brief', 'pack', 'worker-report', 'ask', 'verdict', 'readiness', 'external-verdict', 'projection'}


def unquoted(text):
    fenced = None
    for line in text.splitlines():
        match = re.match(r'^\s*(`{3,}|~{3,})', line)
        if match:
            fence = match[1]
            if fenced is None:
                fenced = fence
            elif fence[0] == fenced[0] and len(fence) >= len(fenced):
                fenced = None
            continue
        if fenced is None and not line.lstrip().startswith('>'):
            yield line


def verdict_marker(text, task):
    found = [line.strip().split(':')[0] for line in unquoted(text)
             if line.strip() in ('APPROVE:' + task, 'REJECT:' + task)]
    return found[-1] if found else None


def criteria(text, task):
    """Read the last numbered block adjacent to the final closing marker.

    Blank lines separate item paragraphs, not lists. An unindented paragraph
    after a blank line ends the block; adjacent wrapped lines and indented
    continuation paragraphs remain part of the item. Numbering never defines
    a boundary: duplicate or skipped numbers must reach protocol() unchanged.
    """
    lines = list(unquoted(text))
    ends = [n for n, line in enumerate(lines) if line.strip() == 'CRITERIA-COMPLETE:' + task]
    if not ends:
        return []
    items = []
    blank = False
    for line in lines[:ends[-1]]:
        match = re.match(r'^\s*(\d+)[.)]\s+(.+)', line)
        if match:
            items.append((int(match[1]), [match[2]]))
        elif not line.strip():
            if items:
                items[-1][1].append('')
            blank = True
            continue
        elif items:
            # Markdown headings and thematic breaks cannot be lazy wrapping.
            boundary = re.match(r'^\s{0,3}(?:#{1,6}\s|(?:[-*_]\s*){3,}$)', line)
            if boundary or (blank and not line[0].isspace()):
                items = []
            else:
                items[-1][1].append(line)
        blank = False
    return [(number, '\n'.join(body).rstrip()) for number, body in items]


def protocol(records, task):
    """Syntax only: neither finding semantics nor new-ground truth is proven."""
    previous = {}
    errors = []
    for record in records:
        if record['kind'] != 'verdict':
            continue
        items = criteria(record['text'], task)
        if record['verdict'] == 'REJECT' or items:
            errors = []  # judge the current correction against the standing list
        if record['verdict'] == 'REJECT' and not items:
            errors.append('REJECT has no complete standing list')
            continue
        if not items:
            continue
        numbers = [n for n, _ in items]
        if numbers != list(range(1, max(numbers) + 1)):
            errors.append('standing list numbering is not consecutive and unique')
        current = dict(items)
        for n in previous:
            if n not in current:
                errors.append(f'standing list dropped item {n}')
            elif not re.match(r'^(?:\*\*)?(done|open)\b', current[n], re.I):
                errors.append(f'item {n} has no done/open state')
        for n in current.keys() - previous.keys():
            if previous and not any(label + ':' + task in current[n].splitlines()[0]
                                    for label in ('REGRESSION', 'NEW-GROUND')):
                errors.append(f'new item {n} has no REGRESSION or NEW-GROUND label')
        previous.update(current)  # a dropped item remains standing until restored
    return errors


class Store:
    def __init__(self, state, project, task, external=None):
        for value in (project, task):
            if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', value):
                raise ValueError('invalid project/task identity')
        self.project, self.task = project, task
        self.state = Path(state)
        if external is None:
            external = os.environ.get('FM_EXTERNAL') == '1'
        if external and (self.state / 'evidence' / project / task).exists():
            raise ValueError('legacy external evidence layout requires approved migration; refusing to lose history')
        self.directory = self.state / 'evidence'
        if not external:
            self.directory /= project
        self.directory /= task
        self.key_path = self.state / 'evidence-signing.key'

    def key(self, create=False):
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        if create and not self.key_path.exists():
            fd, pending = tempfile.mkstemp(prefix='.evidence-key-', dir=self.state)
            try:
                with os.fdopen(fd, 'wb') as output:
                    output.write(secrets.token_bytes(32))
                    output.flush()
                    os.fsync(output.fileno())
                try:
                    os.link(pending, self.key_path)
                except FileExistsError:
                    pass
            finally:
                os.unlink(pending)
        fd = os.open(self.key_path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, 'rb') as source:
            if os.fstat(source.fileno()).st_mode & 0o077:
                raise ValueError('evidence signing key is not private')
            key = source.read()
        if len(key) != 32:
            raise ValueError('invalid evidence signing key')
        return key

    def signature(self, record, create=False):
        payload = {k: v for k, v in record.items() if k != 'signature'}
        return hmac.new(self.key(create), json.dumps(payload, sort_keys=True,
                        separators=(',', ':'), ensure_ascii=False).encode(), hashlib.sha256).hexdigest()

    def records(self):
        records = []
        for path in sorted(self.directory.glob('[0-9]*.json')):
            record = json.loads(path.read_text())
            if record.get('signature'):
                if not hmac.compare_digest(record['signature'], self.signature(record)):
                    raise ValueError('forged or modified local evidence record')
            elif record.get('kind') not in ('brief', 'pack', 'worker-report', 'ask', 'verdict') or 'binding' in record:
                raise ValueError('unsigned evidence cannot claim source-bound authority')
            # Pre-T-138 records stay immutable and readable for the standing
            # list. Only a new signed, source-bound verdict can authorize gate 7.

            if record['project'] != self.project or record['task'] != self.task:
                raise ValueError('record identity does not match its storage location')
            if record['kind'] == 'verdict':
                provenance = record.get('provenance', {})
                level = provenance.get('level')
                if level not in ('legacy', 'authenticated'):
                    raise ValueError('local verdict has no supported provenance level')
                if level == 'authenticated' and (provenance.get('final_source') != 'codex-json-completed-turn'
                        or provenance.get('final_sha256') != hashlib.sha256(record['text'].encode()).hexdigest()
                        or provenance.get('actor') != record['actor']
                        or provenance.get('task') != self.task
                        or provenance.get('role') != 'reviewer'):
                    raise ValueError('local verdict lacks authenticated final-answer provenance')
            records.append(record)
        return records

    def append(self, kind, round_number, actor, head, text, **fields):
        if kind not in KINDS or int(round_number) < 1 or not actor:
            raise ValueError('invalid record kind, round or actor')
        if not re.fullmatch(r'[0-9a-f]{40,64}', head) and not (
                kind == 'verdict' and head == '' and fields.get('provenance', {}).get('level') == 'legacy'):
            raise ValueError('record requires a full head SHA')
        if kind == 'verdict' and not fields.get('provenance'):
            raise ValueError('verdict requires final-answer provenance')
        record = dict(fields, project=self.project, task=self.task, round=int(round_number),
                      actor=actor, kind=kind, head=head,
                      time=datetime.datetime.now(datetime.timezone.utc).isoformat(), text=text)
        record['signature'] = self.signature(record, create=True)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.directory / '.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            existing = self.records()
            sequence = len(existing) + 1
            destination = self.directory / f'{sequence:08d}-{uuid.uuid4().hex}.json'
            fd, name = tempfile.mkstemp(prefix='.pending-', dir=self.directory)
            try:
                with os.fdopen(fd, 'w') as output:
                    json.dump(record, output, ensure_ascii=False)
                    output.write('\n')
                    output.flush()
                    os.fsync(output.fileno())
                os.link(name, destination)  # no replacement of an existing record
                directory_fd = os.open(self.directory, os.O_RDONLY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
            finally:
                os.unlink(name)
        return record

    def brief(self, round_number, head):
        return next((r for r in reversed(self.records()) if r['kind'] == 'brief'
                     and r.get('authorized') is True and r['actor'] == 'firstmate'
                     and r['round'] == round_number and r['head'] == head), None)

    def verdicts(self):
        reviewer = os.environ.get('FM_REVIEWER_LOGIN', '')
        return [r for r in self.records() if r['kind'] == 'verdict'
                and (not reviewer or r.get('login', r['actor']) == reviewer)]

    def history(self, reviewer=False):
        output = []
        login = os.environ.get('FM_REVIEWER_LOGIN', '')
        for record in self.records():
            if record['kind'] == 'verdict':
                if login and record.get('login', record['actor']) != login:
                    continue
                fence = uuid.uuid4().hex
                output.append(f'Local review round {record["round"]}, head {record["head"]}, '
                              f'reviewer {record["actor"]}, provenance {record["provenance"]["level"]}, '
                              f'seal={"signed" if record.get("signature") else "unsealed legacy"}\n----- begin {fence} -----\n'
                              f'{record["text"]}\n----- end {fence} -----')
            elif record['kind'] == 'ask':
                # Do not pass a worker's prose or reasoning to a reviewer.
                if 'ASK-PASS-CRITERIA:' + self.task in record['text'].splitlines():
                    output.append('ASK-PASS-CRITERIA:' + self.task)
        return '\n\n'.join(output) or 'No local review history exists.'


def retain_verdict(store, args):
    """Launcher selects the vendor; adapter-authored receipts cannot upgrade it.

    The T-163 selector is authoritative only on the managed Codex path. Other
    adapters keep the existing selected final/combined output as legacy evidence.
    The run directory and this writer remain outside the round's write roots.
    """
    run = Path(args.run)
    binding = json.loads((run / 'evidence-binding.json').read_text())
    if any(binding.get(k) != getattr(args, k) for k in ('head', 'base', 'patch')):
        raise ValueError('review source binding changed during round')
    identity = json.loads((run / 'identity.json').read_text())
    for key, value in (('project', store.project), ('task', store.task),
                       ('role', 'reviewer'), ('round', args.round)):
        actual = identity.get(key)
        # Pre-registry launchers record no project; only their private self
        # namespace represents that absence. Never relabel the crew identity.
        if key == 'project' and actual is None:
            actual = 'self'
        if actual != value:
            raise ValueError('review identity mismatch: ' + key)
    if args.vendor == 'codex':
        module_path = Path(args.code) / 'bin/fm-herdr.py'
        spec = importlib.util.spec_from_file_location('managed', module_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        answer = module.review_final(str(run), args.attempt, os.environ)
        if not answer:
            raise ValueError('no T-163 authenticated final answer for this Codex attempt')
        provenance = dict(json.loads((run / 'last-result.json').read_text()), level='authenticated')
    else:
        answer = Path(args.file).read_text()
        provenance = dict(level='legacy', vendor=args.vendor, chain_attempt=args.attempt)
    # Preserve the existing fail-closed decision for legacy prose mentioning a
    # signature without signing one. Quoted markers never approve a head.
    decided = verdict_marker(answer, store.task) or 'REJECT'
    return store.append('verdict', args.round, os.environ['FM_ACTOR'], args.head, answer,
                        verdict=decided, base=args.base, patch=args.patch,
                        reviewer=identity, login=os.environ.get('FM_REVIEWER_LOGIN', os.environ['FM_ACTOR']),
                        provenance=provenance, binding=binding, attempt=args.attempt, vendor=args.vendor,
                        model=identity.get('model', 'unknown'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['brief', 'report', 'verdict', 'history', 'gate', 'protocol', 'pin'])
    parser.add_argument('--state', required=True)
    parser.add_argument('--project', required=True)
    parser.add_argument('--task', required=True)
    parser.add_argument('--round', type=int, default=1)
    parser.add_argument('--head', default='')
    parser.add_argument('--base', default='')
    parser.add_argument('--patch', default='')
    parser.add_argument('--actor', default='firstmate')
    parser.add_argument('--file')
    parser.add_argument('--run')
    parser.add_argument('--attempt')
    parser.add_argument('--code')
    parser.add_argument('--vendor', default='legacy')
    parser.add_argument('--reviewer', action='store_true')
    args = parser.parse_args()
    store = Store(args.state, args.project, args.task)
    if args.command == 'pin':
        from fm_binding import source_binding
        binding = source_binding(args.task, args.head, args.base, args.code)
        if binding['patch'] != args.patch:
            raise ValueError('review patch does not match source')
        Path(args.run, 'evidence-binding.json').write_text(json.dumps(binding))
    elif args.command == 'brief':
        store.append('brief', args.round, 'firstmate', args.head, Path(args.file).read_text(), authorized=True)
    elif args.command == 'report':
        text = Path(args.file).read_text()
        kind = 'ask' if re.search(r'^(?:ASK-[A-Z-]+|SCOPE-BLOCKED):' + re.escape(args.task) + r'\s*$', text, re.M) else 'worker-report'
        store.append(kind, args.round, args.actor, args.head, text)
    elif args.command == 'verdict':
        record = retain_verdict(store, args)
        Path(args.run, 'evidence-record.json').write_text(json.dumps(record))
        print(record['verdict'])
    elif args.command == 'history':
        print(store.history(args.reviewer))
    elif args.command == 'protocol':
        records = store.verdicts()
        if not records:
            raise ValueError('missing local verdict; PR comments are not fallback evidence')
        errors = protocol(records, args.task)
        if errors:
            raise ValueError('; '.join(errors))
        print('Local standing-list syntax valid; semantics require review.')
    elif args.command == 'gate':
        records = store.verdicts()
        if not records:
            raise ValueError('missing local verdict; PR comments are not fallback evidence')
        record = records[-1]
        if record['verdict'] != 'APPROVE':
            raise ValueError(f'condition 2 failed: the latest verdict is REJECT:{args.task}; a later rejection supersedes any earlier approval')
        if not record.get('signature'):
            raise ValueError('unsigned legacy approval requires a new signed, source-bound review')
        if not record['head']:
            raise ValueError('legacy local verdict has no reviewed head; a bound review is required')
        if record['head'] != args.head and not (args.patch and record.get('patch') == args.patch):
            raise ValueError('condition 1 failed: latest local approval covers neither this head nor this patch-id')
        from fm_binding import source_binding, git
        current = source_binding(args.task, args.head, args.base, args.code)
        bound = record.get('binding')
        if not bound:
            raise ValueError('local verdict needs signed source binding; review again')
        for key in ('spec_sha256', 'contract_sha256', 'conventions_sha256'):
            if current[key] != bound.get(key):
                raise ValueError('review binding mismatch: ' + key)
        root = os.environ['FM_TARGET_ROOT']
        original = source_binding(args.task, record['head'], record['base'], args.code)
        for key in ('head', 'base', 'patch', 'files'):
            if original[key] != bound.get(key):
                raise ValueError('review source no longer verifies: ' + key)
        if record['head'] != args.head:
            git(root, 'merge-base', '--is-ancestor', record['base'], args.base)
            if bound['patch'] != current['patch']:
                raise ValueError('changed patch requires review')
        errors = protocol(records, args.task)
        if errors:
            raise ValueError('; '.join(errors))
        print(f"Local approval covers this change; provenance={record['provenance']['level']}.")
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError) as error:
        print('fm-evidence: ' + str(error), file=sys.stderr)
        sys.exit(1)
