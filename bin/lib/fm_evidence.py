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
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import uuid

KINDS = {'brief', 'pack', 'worker-report', 'ask', 'verdict'}


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
    lines = list(unquoted(text))
    ends = [n for n, line in enumerate(lines) if line.strip() == 'CRITERIA-COMPLETE:' + task]
    if not ends:
        return []
    return [(int(m[1]), m[2]) for line in lines[:ends[-1]]
            if (m := re.match(r'^\s*(\d+)[.)]\s+(.+)', line))]


def protocol(records, task):
    """Syntax only: neither finding semantics nor new-ground truth is proven."""
    previous = {}
    errors = []
    for record in records:
        if record['kind'] != 'verdict':
            continue
        items = criteria(record['text'], task)
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
            if previous and not any(label + ':' + task in current[n]
                                    for label in ('REGRESSION', 'NEW-GROUND')):
                errors.append(f'new item {n} has no REGRESSION or NEW-GROUND label')
        previous = current
    return errors


class Store:
    def __init__(self, state, project, task):
        for value in (project, task):
            if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', value):
                raise ValueError('invalid project/task identity')
        self.project, self.task = project, task
        self.directory = Path(state) / 'evidence' / project / task

    def records(self):
        records = []
        for path in sorted(self.directory.glob('[0-9]*.json')):
            record = json.loads(path.read_text())
            if record['project'] != self.project or record['task'] != self.task:
                raise ValueError('record identity does not match its storage location')
            if record['kind'] == 'verdict':
                provenance = record.get('provenance', {})
                if (provenance.get('final_source') != 'codex-json-completed-turn'
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
        if not re.fullmatch(r'[0-9a-f]{40,64}', head):
            raise ValueError('record requires a full head SHA')
        if kind == 'verdict' and not fields.get('provenance'):
            raise ValueError('verdict requires authenticated final-answer provenance')
        record = dict(fields, project=self.project, task=self.task, round=int(round_number),
                      actor=actor, kind=kind, head=head,
                      time=datetime.datetime.now(datetime.timezone.utc).isoformat(), text=text)
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
        return [r for r in self.records() if r['kind'] == 'verdict']

    def history(self, reviewer=False):
        output = []
        for record in self.records():
            if record['kind'] == 'verdict':
                fence = uuid.uuid4().hex
                output.append(f'Local review round {record["round"]}, head {record["head"]}, '
                              f'reviewer {record["actor"]}\n----- begin {fence} -----\n'
                              f'{record["text"]}\n----- end {fence} -----')
            elif record['kind'] == 'ask':
                # Do not pass a worker's prose or reasoning to a reviewer.
                if 'ASK-PASS-CRITERIA:' + self.task in record['text'].splitlines():
                    output.append('ASK-PASS-CRITERIA:' + self.task)
        return '\n\n'.join(output) or 'No authenticated local review history exists.'


def authenticated(store, args):
    """Only the managed T-163 final selector may supply verdict text."""
    module_path = Path(args.code) / 'bin/fm-herdr.py'
    spec = importlib.util.spec_from_file_location('managed', module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    run = Path(args.run)
    identity = json.loads((run / 'identity.json').read_text())
    for key, value in (('project', store.project), ('task', store.task),
                       ('role', 'reviewer'), ('round', args.round)):
        if identity.get(key) != value:
            raise ValueError('review identity mismatch: ' + key)
    answer = module.review_final(str(run), args.attempt, os.environ)
    if not answer:
        raise ValueError('no T-163 authenticated final answer for this attempt; legacy/custom output is not authority')
    result = json.loads((run / 'last-result.json').read_text())
    decided = verdict_marker(answer, store.task)
    if not decided:
        raise ValueError('authenticated answer has no unquoted standalone verdict')
    return store.append('verdict', args.round, os.environ['FM_ACTOR'], args.head, answer,
                        verdict=decided, base=args.base, patch=args.patch,
                        reviewer=identity, provenance=result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['brief', 'report', 'verdict', 'history', 'gate', 'protocol'])
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
    parser.add_argument('--reviewer', action='store_true')
    args = parser.parse_args()
    store = Store(args.state, args.project, args.task)
    if args.command == 'brief':
        store.append('brief', args.round, 'firstmate', args.head, Path(args.file).read_text(), authorized=True)
    elif args.command == 'report':
        text = Path(args.file).read_text()
        kind = 'ask' if re.search(r'^(?:ASK-[A-Z-]+|SCOPE-BLOCKED):' + re.escape(args.task) + r'\s*$', text, re.M) else 'worker-report'
        store.append(kind, args.round, args.actor, args.head, text)
    elif args.command == 'verdict':
        print(authenticated(store, args)['verdict'])
    elif args.command == 'history':
        print(store.history(args.reviewer))
    elif args.command == 'protocol':
        records = store.verdicts()
        if not records:
            raise ValueError('missing authenticated local verdict; PR comments are not fallback evidence')
        errors = protocol(records, args.task)
        if errors:
            raise ValueError('; '.join(errors))
        print('Local standing-list syntax valid; semantics require review.')
    elif args.command == 'gate':
        records = store.verdicts()
        if not records:
            raise ValueError('missing authenticated local verdict; PR comments are not fallback evidence')
        record = records[-1]
        if record['verdict'] != 'APPROVE':
            raise ValueError('latest local verdict is REJECT; a later rejection supersedes any earlier approval')
        if record['head'] != args.head and not (args.patch and record.get('patch') == args.patch):
            raise ValueError('latest local approval covers neither this head nor this patch')
        errors = protocol(records, args.task)
        if errors:
            raise ValueError('; '.join(errors))
        print('Authenticated local approval covers this change.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError) as error:
        print('fm-evidence: ' + str(error), file=sys.stderr)
        sys.exit(1)
