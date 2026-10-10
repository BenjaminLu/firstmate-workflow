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

KINDS = {'brief', 'pack', 'worker-report', 'ask', 'verdict', 'readiness', 'external-verdict', 'projection', 'spec-preflight', 'experimental-evidence'}


def numbered_unquoted(text):
    """(raw line index, line) for every line outside fences and block quotes."""
    fenced = None
    for index, line in enumerate(text.splitlines()):
        match = re.match(r'^\s*(`{3,}|~{3,})', line)
        if match:
            fence = match[1]
            if fenced is None:
                fenced = fence
            elif fence[0] == fenced[0] and len(fence) >= len(fenced):
                fenced = None
            continue
        if fenced is None and not line.lstrip().startswith('>'):
            yield index, line


def unquoted(text):
    for _, line in numbered_unquoted(text):
        yield line


def verdict_marker(text, task):
    found = [line.strip().split(':')[0] for line in unquoted(text)
             if line.strip() in ('APPROVE:' + task, 'REJECT:' + task)]
    return found[-1] if found else None


def criteria(text, task):
    """Read the last numbered block adjacent to the final closing marker.

    A restart at 1 after a blank line or an unindented label starts a new
    list. Otherwise blank lines, wrapped text and indented paragraphs stay
    with their item. Adjacent duplicate numbers and non-restart numbering
    errors reach protocol() unchanged.
    """
    return standing(text, task)[0]


def standing(text, task):
    """criteria() plus the raw line span of that list: (items, first, close).

    first is the raw index of the list's first item and close that of the
    final closing marker; both are None when there is no closed list.
    """
    lines = list(numbered_unquoted(text))
    ends = [n for n, (_, line) in enumerate(lines) if line.strip() == 'CRITERIA-COMPLETE:' + task]
    if not ends:
        return [], None, None
    items = []
    first = None
    blank = False
    label = False
    for raw, line in lines[:ends[-1]]:
        match = re.match(r'^\s*(\d+)[.)]\s+(.+)', line)
        if match:
            if int(match[1]) == 1 and (blank or label):
                items = []
            if not items:
                first = raw
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
        # A non-item line can label the next list even without blank lines.
        # Keep it as wrapped text unless the next item restarts at 1.
        label = not match and not line[0].isspace()
    if not items:
        return [], None, None
    return ([(number, '\n'.join(body).rstrip()) for number, body in items],
            first, lines[ends[-1]][0])


FIX_LABELS = ('file', 'change', 'fixes', 'fail-first')


def item_is_open(body, task, earlier):
    """open, or with no earlier list anything not done; labelled new items are open."""
    head = body.splitlines()[0] if body else ''
    if re.match(r'^(?:\*\*)?done\b', head, re.I):
        return False
    if re.match(r'^(?:\*\*)?open\b', head, re.I) or not earlier:
        return True
    return any(label + ':' + task in head for label in ('REGRESSION', 'NEW-GROUND'))


def severity(body):
    """T-276: `follow-up` when the item's first line carries only that tag; else `must-fix`."""
    head = body.splitlines()[0] if body else ''
    return 'follow-up' if '[follow-up]' in head and '[must-fix]' not in head else 'must-fix'


GIT_ESCAPES = {'a': 7, 'b': 8, 'f': 12, 'n': 10, 'r': 13, 't': 9, 'v': 11, '"': 34, '\\': 92}


def header_name(rest):
    """The file name of a ---/+++ header: Git C-quoting decoded, timestamp dropped."""
    if not rest.startswith('"'):
        return rest.split('\t', 1)[0]
    data = bytearray()
    index = 1
    while index < len(rest):
        char = rest[index]
        if char == '"':
            return data.decode('utf-8', 'surrogateescape')
        if char != '\\':
            data += char.encode('utf-8', 'surrogateescape')
            index += 1
            continue
        octal = re.match(r'[0-7]{3}', rest[index + 1:])
        if octal:
            data.append(int(octal[0], 8) & 0xff)
            index += 4
        elif index + 1 < len(rest) and rest[index + 1] in GIT_ESCAPES:
            data.append(GIT_ESCAPES[rest[index + 1]])
            index += 2
        else:
            return None
    return None


def patch_paths(content):
    """Repository paths a unified diff names; None when it names none validly.

    A ---/+++ line is a file header only outside a hunk: inside one, the
    `@@ -a,b +c,d @@` counts say how many lines are content.
    """
    paths = set()
    old = new = 0
    for line in content.splitlines():
        if old > 0 or new > 0:
            mark = line[:1]
            if mark in (' ', ''):
                old, new = old - 1, new - 1
            elif mark == '-':
                old -= 1
            elif mark == '+':
                new -= 1
            elif mark != '\\':
                old = new = 0
            continue
        hunk = re.match(r'^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@', line)
        if hunk:
            old = int(hunk[1]) if hunk[1] is not None else 1
            new = int(hunk[2]) if hunk[2] is not None else 1
            continue
        match = re.match(r'^(?:---|\+\+\+) (.+)$', line)
        if not match:
            continue
        path = header_name(match[1])
        if path == '/dev/null':
            continue
        if path is None or not re.match(r'^[ab]/.', path):
            return None
        path = path[2:]
        if path.startswith('/') or '..' in Path(path).parts:
            return None
        paths.add(path)
    return sorted(paths)


def fixes(text, task, earlier=False):
    """Fix proposals of the final standing list (T-272); writes nothing.

    Only fenced `diff fix-<N>` / `text fix-<N>` blocks and indented
    DECISION:<task> lines between the list's first item and its closing
    marker count. Returns {N: dict(kind, content, open, errors, blocks)} for
    every item of the list and every number a proposal names; kind and
    content are the first proposal's (patch, text, decision or None) and
    blocks lists every fenced (kind, content) in order, duplicates included.
    `earlier` says whether an earlier standing list exists.
    """
    items, first, close = standing(text, task)
    result = {}
    if first is None:
        return result
    states = {}
    for number, body in items:
        states[number] = item_is_open(body, task, earlier)
    found = {}
    raw = text.splitlines()
    current = None
    fence = None
    for line in raw[first:close]:
        if fence is not None:
            closing = re.match(r'^\s*(`{3,}|~{3,})', line)
            if closing and closing[1][0] == fence['marker'][0] and len(closing[1]) >= len(fence['marker']):
                kind = re.fullmatch(r'(diff|text)\s+fix-(\d+)', fence['info'])
                if kind:
                    body = ''.join(row + '\n' for row in fence['lines'])
                    found.setdefault(int(kind[2]), []).append(
                        ('patch' if kind[1] == 'diff' else 'text', body))
                fence = None
            else:
                indent = len(line) - len(line.lstrip(' '))
                fence['lines'].append(line[min(indent, fence['indent']):])
            continue
        opening = re.match(r'^(\s*)(`{3,}|~{3,})(.*)$', line)
        if opening:
            fence = dict(indent=len(opening[1]), marker=opening[2], info=opening[3].strip(), lines=[])
            continue
        if line.lstrip().startswith('>'):
            continue
        item = re.match(r'^\s*(\d+)[.)]\s+', line)
        if item:
            current = int(item[1])
            continue
        decision = re.match(r'^[ \t]+DECISION:' + re.escape(task) + r'[ \t]+(\S.*?)\s*$', line)
        if decision and current is not None:
            found.setdefault(current, []).append(('decision', decision[1]))
    for number in sorted(set(states) | set(found)):
        entries = found.get(number, [])
        blocks = [entry for entry in entries if entry[0] != 'decision']
        decisions = [entry for entry in entries if entry[0] == 'decision']
        is_open = states.get(number, False)
        errors = []
        if not is_open and entries:
            errors.append(f'item {number}: a fix-{number} block or DECISION names no open item of this standing list')
        if is_open and not entries:
            errors.append(f'open item {number} has no fix proposal or DECISION')
        if len(blocks) > 1:
            errors.append(f'item {number} has more than one fix block')
        if blocks and decisions:
            errors.append(f'item {number} has both a fix block and a DECISION line')
        if len(decisions) > 1:
            errors.append(f'item {number} has more than one DECISION line')
        for kind, content in blocks:
            if kind == 'patch' and (not content.strip() or not patch_paths(content)
                                    or not re.search(r'(?m)^@@ ', content)):
                errors.append(f'item {number} fix patch is empty or not a unified diff with a/ and b/ paths')
            if kind == 'text':
                for label in FIX_LABELS:
                    if not re.search(r'(?m)^\s*' + re.escape(label) + r':[ \t]*\S', content):
                        errors.append(f'item {number} text fix has no non-empty {label}: line')
        kind, content = entries[0] if entries else (None, None)
        result[number] = dict(kind=kind, content=content, open=is_open, errors=errors, blocks=blocks)
    return result


def fix_checks(text, task, head, root, scope, git='git', seconds=60):
    """Read-only applicability of each patch proposal against the reviewed head.

    The head is read into a temporary index in a new system temporary
    directory; `git apply --cached --check` never writes the repository's
    index, refs or worktree. A check that cannot run is `unavailable`.
    Every patch block is checked, duplicates included: an item with any
    patch is a patch whose result is its worst block's, with the union of
    their outside-scope paths.
    """
    import fnmatch
    import shutil
    import subprocess
    import time
    proposals = fixes(text, task)
    items = {}
    patches = [n for n, entry in proposals.items() if any(kind == 'patch' for kind, _ in entry['blocks'])]
    directory = None
    try:
        deadline = time.monotonic() + seconds
        env = None
        if patches:
            if not root:
                raise ValueError('no target repository to check patches against')
            directory = tempfile.mkdtemp(prefix='fm-fix-check-')
            for owner in (Path(root), Path(__file__).resolve().parents[2]):
                if Path(directory).resolve().is_relative_to(owner.resolve()):
                    raise ValueError('temporary index would sit inside a repository')
            env = dict(os.environ, GIT_INDEX_FILE=str(Path(directory) / 'index'))
            # A reviewed tree, never the repository's own index.
            read = subprocess.run([git, '-C', str(root), 'read-tree', head], env=env,
                                  stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                  timeout=max(1, deadline - time.monotonic()))
            if read.returncode:
                raise ValueError('git read-tree of the reviewed head failed')
        for number, entry in sorted(proposals.items()):
            if entry['kind'] is None:
                continue
            bodies = [content for kind, content in entry['blocks'] if kind == 'patch']
            row = dict(kind='patch' if bodies else entry['kind'], apply='not-a-patch', message=None,
                       outside_scope=[])
            outside = set()
            for body in bodies:
                applied = subprocess.run([git, '-C', str(root), 'apply', '--cached', '--check', '-'],
                                         env=env, input=body, capture_output=True, text=True,
                                         timeout=max(1, deadline - time.monotonic()))
                if applied.returncode and row['apply'] != 'does-not-apply':
                    lines = [line for line in applied.stderr.splitlines() if line.strip()]
                    row['apply'] = 'does-not-apply'
                    row['message'] = lines[0] if lines else 'git apply refused the patch'
                elif not applied.returncode and row['apply'] == 'not-a-patch':
                    row['apply'] = 'applies'
                outside.update(path for path in patch_paths(body) or []
                               if not any(fnmatch.fnmatchcase(path, glob) for glob in scope))
            row['outside_scope'] = sorted(outside)
            items[str(number)] = row
        return dict(version=1, status='complete', reason=None, items=items)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        reason = 'patch check timed out' if isinstance(error, subprocess.TimeoutExpired) else str(error)
        return dict(version=1, status='unavailable', reason=reason, items={})
    finally:
        if directory is not None:
            shutil.rmtree(directory, ignore_errors=True)


def check_line(checks, number):
    if not isinstance(checks, dict) or checks.get('status') != 'complete':
        return 'patch check unavailable'
    row = checks.get('items', {}).get(str(number))
    if row is None:
        return f'patch check missing for item {number}'
    if row.get('apply') == 'not-a-patch':
        line = 'patch check: not a patch'
    elif row.get('apply') == 'applies':
        line = 'patch check: applies to the reviewed head'
    else:
        line = 'patch check: does not apply to the reviewed head: ' + (row.get('message') or 'no message')
    if row.get('outside_scope'):
        line += '; outside the pinned scope: ' + ', '.join(row['outside_scope'])
    return line


class Refused(ValueError):
    """fixes-brief refused; nothing was written (exit 65)."""


def fixes_brief(store, next_round, head):
    """Write the review-fix draft for the latest REJECT at head (T-272).

    Returns (path, has_decision). An existing draft for the same head and
    verdict is never overwritten, so firstmate's appended context survives.
    """
    if not re.fullmatch(r'[0-9a-f]{40,64}', head or ''):
        raise Refused('fixes-brief needs a full head SHA')
    verdicts = store.verdicts()
    positions = [n for n, r in enumerate(verdicts) if r['verdict'] == 'REJECT' and r['head'] == head]
    if not positions:
        raise Refused('no REJECT verdict for head ' + head)
    record = verdicts[positions[-1]]
    if int(next_round) != int(record['round']) + 1:
        raise Refused(f'round {next_round} does not follow the REJECT of round {record["round"]}')
    if record.get('fix_protocol') != 1:
        raise Refused('legacy REJECT carries no fix proposals; write the brief by hand')
    errors = protocol(verdicts[:positions[-1] + 1], store.task)
    if errors:
        raise Refused('the REJECT fails the review protocol: ' + '; '.join(errors))
    earlier = any(criteria(r['text'], store.task) for r in verdicts[:positions[-1]])
    proposals = fixes(record['text'], store.task, earlier)
    items = criteria(record['text'], store.task)
    # T-276: a follow-up's decision does not hold the must-fix work.
    later = {number for number, body in items if severity(body) == 'follow-up'}
    decision = any(entry['kind'] == 'decision' and number not in later for number, entry in proposals.items())
    folder = store.state / 'briefs'
    path = folder / f'{store.task}-r{next_round}-{head[:12]}-{record["signature"][:8]}-review-fixes.md'
    if path.exists():
        return path, decision

    def proposal(number, entry):
        content = entry['content']
        longest = max((len(run) for run in re.findall(r'`+', content)), default=0)
        fence = '`' * max(3, longest + 1)
        info = ('diff' if entry['kind'] == 'patch' else 'text') + f' fix-{number}'
        return f'\n{fence}{info}\n{content}{fence}\n\n{check_line(record.get("fix_checks"), number)}\n'
    output = []
    for number, body in items:
        entry = proposals.get(number, {})
        if not entry.get('open'):
            output.append(f'{number}. deferred: done in the reviewed round; keep as is\n')
        elif number in later:
            # Fixed after the must-fix items; the reviewer's proposal stays below.
            output.append(f'{number}. deferred: follow-up, not needed for approval: {body.splitlines()[0]}\n')
            if entry['kind'] == 'decision':
                output.append(f'   proposed captain question: {entry["content"]}\n')
            elif entry['kind']:
                output.append(proposal(number, entry))
        elif entry['kind'] == 'decision':
            output.append(f'{number}. deferred: captain decision needed: {entry["content"]}\n')
        else:
            output.append(f'{number}. fix: {body.splitlines()[0]}\n' + proposal(number, entry))
    output.append(f'\nSource: reviewer {record["actor"]}, round {record["round"]}, '
                  f'head {record["head"]}, signature {record["signature"]}\n')
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, pending = tempfile.mkstemp(prefix='.review-fixes-', dir=folder)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(''.join(output))
        try:
            os.link(pending, path)  # never replace a draft firstmate may have extended
        except FileExistsError:
            pass
    finally:
        os.unlink(pending)
    return path, decision


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
        if record['verdict'] == 'REJECT' and record.get('fix_protocol') == 1:
            # T-272: verdicts retained before the field are judged by the old rules.
            for entry in fixes(record['text'], task, earlier=bool(previous)).values():
                errors.extend(entry['errors'])
        if record.get('severity_protocol') == 1:
            # T-276: verdicts retained before the field keep the old rules.
            must = []
            for n, body in items:
                head = body.splitlines()[0] if body else ''
                if '[must-fix]' in head and '[follow-up]' in head:
                    errors.append(f'item {n} has two severity tags')
                if item_is_open(body, task, bool(previous)) and severity(body) == 'must-fix':
                    must.append(n)
            if record['verdict'] == 'REJECT' and not must:
                errors.append('REJECT has no open must-fix item')
            if record['verdict'] == 'APPROVE':
                errors.extend(f'APPROVE leaves must-fix item {n} open' for n in must)
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
        if create:
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
        # Writers publish complete immutable records atomically. Readers need
        # neither the append lock nor permission to create directories.
        records = []
        for path in sorted(self.directory.glob('[0-9]*.json')):
            record = json.loads(path.read_text())
            if record.get('signature'):
                if not hmac.compare_digest(record['signature'], self.signature(record)):
                    raise ValueError('forged or modified local evidence record')
            elif record.get('kind') not in ('brief', 'pack', 'worker-report', 'ask', 'verdict') or 'binding' in record:
                raise ValueError('unsigned evidence cannot claim source-bound authority')
            # Pre-T-138 records stay immutable and readable for the standing
            # list. Only a new signed, source-bound verdict can authorize gate 6.

            if record['project'] != self.project or record['task'] != self.task:
                raise ValueError('record identity does not match its storage location')
            if record['kind'] in ('verdict', 'spec-preflight'):
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
            if record['kind'] == 'spec-preflight':
                from fm_spec_preflight import decision
                if (not re.fullmatch(r'[0-9a-f]{64}', record.get('spec_sha256', ''))
                        or decision(record['text'], self.task) != record.get('verdict')
                        or (record['provenance']['level'] == 'authenticated'
                            and record['provenance'].get('spec_preflight') != record['spec_sha256'])):
                    raise ValueError('invalid spec-preflight source binding or final')
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

    def experiments(self, head, base, code):
        # Sparse ordinary consumers remain independent of the optional module.
        if not any(r['kind'] == 'experimental-evidence' for r in self.records()):
            return [], []
        from fm_experimental_evidence import collect
        return collect(self, head, base, code)


def merge_card_of(answer, decided):
    """The reviewer's fm-merge-card block (T-270) and its status.

    absent: no block; malformed: unclosed, more than one, or not one JSON
    object; ignored: a block on a REJECT; present: one object on an APPROVE.
    The answer text itself is retained unchanged.
    """
    from fm_plain import blocks
    found, _ = blocks(answer)
    contents = found['fm-merge-card']
    if not contents:
        return None, 'absent'
    if None in contents:
        return None, 'malformed'
    if decided != 'APPROVE':
        return None, 'ignored'
    if len(contents) > 1:
        return None, 'malformed'
    try:
        card = json.loads(contents[0])
    except ValueError:
        return None, 'malformed'
    return (card, 'present') if isinstance(card, dict) else (None, 'malformed')


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
    # T-272: check the exact answer's patch proposals before the single append.
    checks = fix_checks(answer, store.task, args.head, os.environ.get('FM_TARGET_ROOT', ''),
                        pinned_scope(run, store.task, args.head))
    merge_card, merge_card_status = merge_card_of(answer, decided)
    return store.append('verdict', args.round, os.environ['FM_ACTOR'], args.head, answer,
                        verdict=decided, base=args.base, patch=args.patch,
                        merge_card=merge_card, merge_card_status=merge_card_status,
                        reviewer=identity, login=os.environ.get('FM_REVIEWER_LOGIN', os.environ['FM_ACTOR']),
                        provenance=provenance, binding=binding, attempt=args.attempt, vendor=args.vendor,
                        model=identity.get('model', 'unknown'), fix_protocol=1, fix_checks=checks,
                        severity_protocol=1)


def pinned_scope(run, task, head):
    """The round's pinned scope, else the head's committed task entry, else none."""
    import subprocess
    try:
        pinned = Path(run) / 'pinned/spec.json'
        if pinned.is_file():
            return list(json.loads(pinned.read_text()).get('scope', []))
        root = os.environ.get('FM_TARGET_ROOT', '')
        if root and os.environ.get('FM_EXTERNAL') != '1':
            shown = subprocess.run(['git', '-C', root, 'show', f'{head}:design/tasks/{task}.json'],
                                   stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
            if shown.returncode == 0:
                return list(json.loads(shown.stdout).get('scope', []))
    except (OSError, ValueError, AttributeError, subprocess.SubprocessError):
        pass
    return []


def avoided_reviewer(store):
    """The reviewer name of the task's latest REJECT, whatever its protocol (T-272)."""
    rejects = [r for r in store.records() if r['kind'] == 'verdict' and r.get('verdict') == 'REJECT']
    if not rejects:
        return ''
    reviewer = rejects[-1].get('reviewer')
    name = reviewer.get('name') if isinstance(reviewer, dict) else None
    if not name:
        found = re.match(r'^reviewer-(.+)-([a-z0-9]+)-r([0-9]+)([a-z]*)$', rejects[-1].get('actor', ''))
        name = found[1] if found else ''
    return name or ''


def follow_ups(store):
    """Open follow-up items left by the task's latest verdict when it is an APPROVE (T-276).

    From that APPROVE's own list, else from the latest earlier list.
    """
    verdicts = store.verdicts()
    if not verdicts or verdicts[-1].get('verdict') != 'APPROVE':
        return []
    for index in range(len(verdicts) - 1, -1, -1):
        items = criteria(verdicts[index]['text'], store.task)
        if items:
            earlier = any(criteria(r['text'], store.task) for r in verdicts[:index])
            return [dict(number=n, line=body.splitlines()[0]) for n, body in items
                    if item_is_open(body, store.task, earlier) and severity(body) == 'follow-up']
    return []


def summary(store):
    """Read and authenticate all records before exposing an explicit projection."""
    from fm_binding import gate_list, gate_entry
    try:
        mapping = gate_list()
    except ValueError:
        mapping = None
    result = []
    for record in store.records():
        row = {key: record.get(key) for key in ('kind', 'round', 'actor', 'head', 'time')}
        if record['kind'] == 'verdict':
            row['verdict'] = record.get('verdict')
        elif record['kind'] == 'brief':
            lines = record.get('text', '').splitlines()
            row['brief'] = lines[0] if lines else ''
        elif record['kind'] == 'external-verdict':
            row.update(ready=record.get('ready'),
                       blockers=[blocker[:200] for blocker in record.get('blockers', [])],
                       states={reviewer: {key: state.get(key) for key in ('state', 'reviewed_head', 'covers')}
                               for reviewer, state in record.get('states', {}).items()},
                       findings=[{key: finding.get(key) for key in
                                  ('id', 'reviewer', 'path', 'line', 'reviewed_head', 'resolved')}
                                 for finding in record.get('findings', [])])
        elif record['kind'] == 'readiness':
            row.update(gate_base=record.get('gate_base'), gates=record.get('gates', []),
                       checks=[{key: check.get(key) for key in ('name', 'conclusion')}
                               for check in record.get('checks', [])])
            if mapping is None:
                row['gates_unmapped'] = True
            else:
                row['gates'] = [gate for value in row['gates']
                                if (gate := gate_entry(value, mapping)) is not None]
        elif record['kind'] == 'experimental-evidence':
            row.update(has_experiments=True, experiment_count=len(record.get('experiments', [])),
                       provenance_level='unverified')
        result.append(row)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['brief', 'report', 'verdict', 'history', 'gate', 'protocol', 'pin', 'summary',
                                            'experiment-retain', 'fixes-brief', 'avoid-reviewer', 'follow-ups'])
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
    parser.add_argument('--external', action='store_true', default=None)
    parser.add_argument('--signature')
    args = parser.parse_args()
    if args.command == 'experiment-retain':
        # Inline admission before importing the optional module (including its
        # bytecode cache writes), any state initialization or binding command.
        if (os.environ.get('FM_ROLE') in ('worker', 'reviewer')
                or os.environ.get('FM_IN_ROUND') == '1'
                or os.environ.get('FM_RUN_DIR')):
            raise ValueError('experimental retention requires the outside-round operator')
    store = Store(args.state, args.project, args.task, external=args.external)
    if args.command == 'experiment-retain':
        from fm_experimental_evidence import retain
        record = retain(store, args)
        print('Retained operator-attested experimental evidence; execution unverified by stock.')
    elif args.command == 'summary':
        print(json.dumps(summary(store), ensure_ascii=False))
    elif args.command == 'pin':
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
    elif args.command == 'fixes-brief':
        path, _ = fixes_brief(store, args.round, args.head)
        print(path)
    elif args.command == 'avoid-reviewer':
        print(avoided_reviewer(store))
    elif args.command == 'follow-ups':
        print(json.dumps(follow_ups(store), ensure_ascii=False))
    elif args.command == 'history':
        print(store.history(args.reviewer))
    elif args.command == 'protocol':
        records = store.verdicts()
        if not records:
            raise ValueError('missing local verdict; PR comments are not fallback evidence')
        if args.signature is not None:
            # Judge the sequence up to the triggering verdict; later records cannot mask it.
            bound = [n for n, record in enumerate(records) if record.get('signature') == args.signature]
            if not args.signature or not bound:
                raise ValueError('no local verdict carries this signature')
            records = records[:bound[-1] + 1]
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
    except Refused as error:
        print('fm-evidence: ' + str(error), file=sys.stderr)
        sys.exit(65)
    except (ValueError, OSError, KeyError, TypeError) as error:
        # Metadata readers need the failure reason, never a private key path.
        message = (error.strerror or 'evidence read failed') if len(sys.argv) > 1 and sys.argv[1] == 'summary' and isinstance(error, OSError) else str(error)
        print('fm-evidence: ' + message, file=sys.stderr)
        sys.exit(1)
