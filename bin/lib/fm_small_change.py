#!/usr/bin/env python3
"""Small-change records bound to an approved pin (T-277).

A small change is a path record (a few exact test or documentation files the
pinned scope does not cover) or an erratum (a typo fix in the pinned title or
one acceptance line). firstmate writes records outside any round. Gate 3, the
round prompts and the merge card read them; the self project only.

The store follows the pin store's rules: append-only, no symlinks, a .lock
taken with flock while writing, and atomic publication by os.link. Every
reader validates the whole store before it uses any record.
"""
import argparse
from datetime import datetime, timezone
import fcntl
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ADDED_LIMIT = 20
REMOVED_LIMIT = 20
MAX_PATHS = 5
MAX_PATH_LENGTH = 200
MAX_PER_PIN = 3
REASON_LIMITS = {'en': 200, 'zh-TW': 120}
REF_LIMIT = 200
ORIGINS = ('worker-ask', 'review-finding', 'firstmate')
COMMON = {'schema', 'project', 'task', 'number', 'pin_version', 'pin_sha256', 'kind',
          'reason', 'origin', 'author', 'created', 'previous_sha256'}
KINDS = ('paths', 'erratum')
MAX_DIFFERING_WORDS = 3
MAX_WORD_DISTANCE = 2
MEANING_WORDS = set('not no never none nor must may should shall can cannot only all any '
                    'every each without unless'.split())
STATUS = {True: {'en': 'checked by the review', 'zh-TW': '審查已確認'},
          False: {'en': 'not checked by the review', 'zh-TW': '審查未確認'}}
QUESTION = {'en': 'Do you accept the small changes listed in the notes?',
            'zh-TW': '你接受備註列出的小改動嗎？'}
CORRECTED = 'The corrected wording is the meaning; the pinned bytes are unchanged.'
EXTERNAL = 'small-change tier is self-project only; use the full process'


def pin_digest(pin):
    """The same digest previous_sha256 uses in the pin chain."""
    return hashlib.sha256(json.dumps(pin, sort_keys=True).encode('utf-8')).hexdigest()


def file_digest(data):
    return hashlib.sha256(data).hexdigest()


def integer(value):
    return type(value) is int


def store_path(state, task):
    return Path(state) / 'small-changes' / task


# --- Eligibility rules ------------------------------------------------------

def path_refusal(path, scope):
    """Return why a path cannot join the tier, or '' when it can."""
    if not isinstance(path, str) or not path:
        return 'a path must be nonempty text'
    if len(path) > MAX_PATH_LENGTH:
        return f'path longer than {MAX_PATH_LENGTH} characters: {path[:40]}...'
    if any(ord(c) < 32 or ord(c) == 127 or c == '\\' for c in path):
        return 'path contains a control character or backslash: ' + path
    if any(c in path for c in '*?['):
        return 'path contains a glob character: ' + path
    if path.startswith('/'):
        return 'path starts with /: ' + path
    parts = path.split('/')
    if any(part in ('', '.', '..') for part in parts):
        return 'path is not a plain relative path: ' + path
    if any(part.startswith('.fm-') for part in parts):
        return 'path has a .fm- part: ' + path
    if not (path == 'README.md' or path.startswith(('tests/', 'docs/'))):
        return 'only README.md, tests/ and docs/ paths are eligible: ' + path
    if any(fnmatch.fnmatchcase(path, pattern) for pattern in scope):
        return 'path is already in the pinned scope: ' + path
    return ''


def distance(a, b):
    previous = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        current = [i]
        for j, y in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x != y)))
        previous = current
    return previous[-1]


def word_refusal(word):
    core = word.lstrip('(').rstrip('.,;:!?)')
    if not core:
        return 'a punctuation-only word changed'
    if re.search(r'[0-9`/_=.]', core):
        return 'a changed word contains a digit, code or path character: ' + core
    if core[:2].upper() in ('T-', 'D-'):
        return 'a changed word names a task or decision: ' + core
    if len(core) >= 7 and re.fullmatch(r'[a-fA-F]+', core):
        return 'a changed word could be a hash: ' + core
    if core.lower() in MEANING_WORDS:
        return 'a meaning word changed: ' + core
    return ''


def typo_refusal(before, after):
    """The mechanical typo guard; it cannot prove that meaning is unchanged."""
    if not isinstance(before, str) or not isinstance(after, str):
        return 'erratum wording must be text'
    if before == after:
        return 'the corrected wording is the same as the current wording'
    old, new = re.split(r'(\s+)', before), re.split(r'(\s+)', after)
    if len(old) != len(new) or old[1::2] != new[1::2]:
        return 'the word count or the whitespace changed'
    pairs = [(a, b) for a, b in zip(old[0::2], new[0::2]) if a != b]
    if len(pairs) > MAX_DIFFERING_WORDS:
        return f'more than {MAX_DIFFERING_WORDS} words changed'
    for a, b in pairs:
        for word in (a, b):
            reason = word_refusal(word)
            if reason:
                return reason
        if distance(a, b) > MAX_WORD_DISTANCE:
            return f'a word changed by more than {MAX_WORD_DISTANCE} edits: {a} -> {b}'
        x = a.lstrip('(').rstrip('.,;:!?)').lower()
        y = b.lstrip('(').rstrip('.,;:!?)').lower()
        if x != y and (x.startswith(y) or x.endswith(y) or y.startswith(x) or y.endswith(x)):
            return f'a word only gained or lost letters at one end: {a} -> {b}'
    return ''


def wording(spec, field, index):
    if field == 'title':
        value = spec.get('title')
    else:
        acceptance = spec.get('acceptance')
        value = acceptance[index] if isinstance(acceptance, list) and 0 <= index < len(acceptance) else None
    if not isinstance(value, str):
        raise ValueError('the pinned spec has no text at that field')
    return value


# --- Merge card note text ---------------------------------------------------

def target(record):
    if record['kind'] == 'paths':
        return ', '.join(record['paths'])
    erratum = record['erratum']
    return 'title' if erratum['field'] == 'title' else 'acceptance:' + str(erratum['index'])


def sentence(text):
    text = text.strip()
    return text if text[-1:] in ('.', '!', '?', '。', '！', '？') else text + ('。' if re.search(r'[一-鿿]', text) else '.')


def notes(record, checked):
    """The fixed note text the merge card shows for one record."""
    kind_tw = '路徑' if record['kind'] == 'paths' else '勘誤'
    en = (f'Small change {record["number"]} ({record["kind"]}): {target(record)}. '
          f'Reason: {sentence(record["reason"]["en"])} Review status: {STATUS[checked]["en"]}.')
    tw = (f'小改動 {record["number"]}（{kind_tw}）：{target(record)}。'
          f'原因：{sentence(record["reason"]["zh-TW"])}審查狀態：{STATUS[checked]["zh-TW"]}。')
    return {'en': en, 'zh-TW': tw}


def note_refusal(record):
    """Apply check_details' notes checks to the longer, unchecked note."""
    from fm_ste import _text, check, split
    for lang, text in notes(record, False).items():
        try:
            _text(text, lang + '.notes.text')
        except ValueError as error:
            return str(error)
        for part in split(text):
            result = check(part, 'fact')
            for issue in result['issues']:
                if issue['severity'] == 'fail':
                    return f'{lang} note fails the STE check: {part} -> {issue["rule"]} {issue["detail"]}'
    return ''


# --- Store validation -------------------------------------------------------

def refuse(number, reason):
    raise ValueError(f'invalid small-change record {number}: {reason}')


def check_text(value, limit):
    return (isinstance(value, str) and value.strip() != '' and len(value) <= limit
            and '\n' not in value and '\r' not in value)


def check_record(record, number, previous, project, task, chain, prior):
    """Validate one record against the pin version it names."""
    if not isinstance(record, dict):
        refuse(number, 'not a JSON object')
    kind = record.get('kind')
    if kind not in KINDS:
        refuse(number, 'unknown kind')
    if set(record) != COMMON | {kind}:
        refuse(number, 'wrong key set')
    if not integer(record['schema']) or record['schema'] != 1:
        refuse(number, 'schema is not the integer 1')
    if not integer(record['number']) or record['number'] != number:
        refuse(number, 'number does not match the file name')
    if record['project'] != project or record['task'] != task:
        refuse(number, 'wrong project or task')
    if not integer(record['pin_version']) or record['pin_version'] < 1:
        refuse(number, 'pin_version is not a positive integer')
    versions = {pin['version']: pin for pin in chain}
    pin = versions.get(record['pin_version'])
    if pin is None:
        refuse(number, 'pin_version is not in the verified pin chain')
    if record['pin_sha256'] != pin_digest(pin):
        refuse(number, 'pin_sha256 does not match that pin version')
    reason = record['reason']
    if (not isinstance(reason, dict) or set(reason) != set(REASON_LIMITS)
            or not all(check_text(reason[lang], limit) for lang, limit in REASON_LIMITS.items())):
        refuse(number, 'reason needs single-line en and zh-TW text within the limits')
    origin = record['origin']
    if (not isinstance(origin, dict) or set(origin) != {'kind', 'ref'}
            or origin['kind'] not in ORIGINS or not check_text(origin['ref'], REF_LIMIT)):
        refuse(number, 'origin needs a known kind and a nonempty single-line ref')
    if record['author'] != 'firstmate':
        refuse(number, 'author is not firstmate')
    created = record['created']
    try:
        if not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|\+00:00)', created):
            raise ValueError
        datetime.fromisoformat(created.replace('Z', '+00:00'))
    except (TypeError, ValueError):
        refuse(number, 'created is not an ISO 8601 UTC time')
    if record['previous_sha256'] != previous:
        refuse(number, 'previous_sha256 chain mismatch')
    same = [r for r in prior if r['pin_version'] == record['pin_version']]
    if len(same) >= MAX_PER_PIN:
        refuse(number, f'more than {MAX_PER_PIN} records for pin version {record["pin_version"]}')
    spec = json.loads(pin['snapshots']['spec']['text'])
    if kind == 'paths':
        paths = record['paths']
        if not isinstance(paths, list) or not 1 <= len(paths) <= MAX_PATHS:
            refuse(number, f'paths needs 1 to {MAX_PATHS} entries')
        if len(set(map(str, paths))) != len(paths):
            refuse(number, 'paths repeats an entry')
        for path in paths:
            why = path_refusal(path, spec['scope'])
            if why:
                refuse(number, why)
    else:
        erratum = record['erratum']
        if not isinstance(erratum, dict) or set(erratum) != {'field', 'index', 'before', 'after'}:
            refuse(number, 'erratum needs field, index, before and after')
        field, index = erratum['field'], erratum['index']
        if field == 'title':
            if index is not None:
                refuse(number, 'a title erratum needs a null index')
        elif field == 'acceptance':
            acceptance = spec.get('acceptance')
            count = len(acceptance) if isinstance(acceptance, list) else 0
            if not integer(index) or not 0 <= index < count:
                refuse(number, 'acceptance index out of range')
        else:
            refuse(number, 'erratum field must be title or acceptance')
        try:
            current = wording(errata_applied(spec, same), field, index)
        except ValueError as error:
            refuse(number, str(error))
        if erratum['before'] != current:
            refuse(number, 'erratum before is not the current wording')
        why = typo_refusal(erratum['before'], erratum['after'])
        if why:
            refuse(number, why)


def errata_applied(spec, records):
    """The spec with errata applied in record order; the pin bytes never change."""
    spec = json.loads(json.dumps(spec))
    for record in records:
        if record['kind'] != 'erratum':
            continue
        erratum = record['erratum']
        if erratum['field'] == 'title':
            spec['title'] = erratum['after']
        else:
            spec['acceptance'][erratum['index']] = erratum['after']
    return spec


def read_store(directory, extra=None):
    """Return [(number, bytes)] for every record file; refuse symlinks and odd names."""
    for path in (directory.parent, directory):
        if path.is_symlink():
            raise ValueError('invalid small-change store: ' + path.name + ' is a symlink')
    if not directory.is_dir():
        raise ValueError('invalid small-change store: not a directory')
    lock = directory / '.lock'
    if lock.is_symlink():
        raise ValueError('invalid small-change store: .lock is a symlink')
    names = sorted((p for p in directory.iterdir() if p.name.endswith('.json')),
                   key=lambda p: (len(p.name), p.name))
    files = []
    for number, path in enumerate(names, 1):
        if not re.fullmatch(r'[1-9][0-9]*\.json', path.name):
            refuse(number, 'file name is not <n>.json: ' + path.name)
        if path.name != f'{number}.json':
            refuse(number, 'numbering gap or file name mismatch: ' + path.name)
        if path.is_symlink() or not path.is_file():
            refuse(number, 'record file is a symlink or not a file')
        files.append((number, path.read_bytes()))
    if extra is not None:
        files.append((len(files) + 1, extra))
    return files


def load(state, project, task, chain, extra=None):
    """Validate the whole store; return [(record, sha256)] in number order."""
    entries = []
    previous = None
    for number, data in read_store(store_path(state, task), extra):
        try:
            record = json.loads(data.decode('utf-8'))
        except (UnicodeDecodeError, ValueError):
            refuse(number, 'not valid JSON')
        check_record(record, number, previous, project, task, chain, [r for r, _ in entries])
        sha = file_digest(data)
        entries.append((record, sha))
        previous = sha
    return entries


def bound(entries, pin):
    """Keep only the records bound to this exact pin."""
    version, sha = pin.get('version'), pin_digest(pin)
    return [(r, s) for r, s in entries if r['pin_version'] == version and r['pin_sha256'] == sha]


def current(env, task):
    """Validated records bound to the task's latest verified pin."""
    from fm_spec_pins import Pins
    pins = Pins(env, task)
    if pins.external:
        return []
    chain = pins.chain()
    return bound(load(pins.state, pins.project, task, chain), chain[-1])


def store_digest(state, task):
    """The record files' bytes in number order, for the advancement fingerprint."""
    directory = store_path(state, task)
    hasher = hashlib.sha256()
    try:
        if directory.is_symlink() or directory.parent.is_symlink() or not directory.is_dir():
            return 'invalid-store'
        names = sorted((p for p in directory.iterdir() if re.fullmatch(r'[0-9]+\.json', p.name)),
                       key=lambda p: int(p.stem))
        for path in names:
            if path.is_symlink():
                return 'invalid-store'
            hasher.update(path.name.encode() + b'\0' + path.read_bytes() + b'\0')
    except OSError:
        return 'unreadable-store'
    return hasher.hexdigest()


# --- Gate 3 -----------------------------------------------------------------

def budget(target_root, base, head, paths):
    """Refuse more than the fixed line budget across all record paths."""
    result = subprocess.run(['git', '-C', str(target_root), 'diff', '--no-renames', '--numstat',
                             base + '...' + head, '--', *paths],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise ValueError('small-change budget unavailable: git diff failed')
    added = removed = 0
    for line in result.stdout.decode('utf-8').splitlines():
        if not line.strip():
            continue
        plus, minus, name = line.split('\t', 2)
        if plus == '-' or minus == '-':
            raise ValueError('small-change path is binary: ' + name)
        added += int(plus)
        removed += int(minus)
    if added > ADDED_LIMIT or removed > REMOVED_LIMIT:
        raise ValueError(f'small-change budget exceeded: +{added} -{removed} '
                         f'(limit +{ADDED_LIMIT} -{REMOVED_LIMIT})')


def allowed_paths(pins, chain):
    """Validate the store against the chain; return the latest pin's record paths."""
    entries = bound(load(pins.state, pins.project, pins.task, chain), chain[-1])
    return {path for record, _ in entries if record['kind'] == 'paths' for path in record['paths']}


# --- Round prompts ----------------------------------------------------------

def prompt_section(env, pin, role):
    from fm_spec_pins import Pins
    pins = Pins(env, pin['task'])
    if pins.external:
        return ''
    entries = bound(load(pins.state, pins.project, pins.task, pins.chain()), pin)
    if not entries:
        return ''
    lines = ['', '# Small changes recorded for this pin', '',
             f'firstmate recorded these small changes for pin version {pin["version"]} '
             'without a repin. They are part of the approved inputs for this round.']
    for record, sha in entries:
        lines.append('')
        head = f'- Record {record["number"]} (sha256 {sha[:12]}), {record["kind"]}'
        if record['kind'] == 'paths':
            lines.append(head + ': ' + ', '.join('`' + p + '`' for p in record['paths']))
            lines.append('  You may change these exact paths in addition to the scope list. '
                         f'Budget: +{ADDED_LIMIT} -{REMOVED_LIMIT} lines in total across all record paths; '
                         'no binary files.')
        else:
            erratum = record['erratum']
            lines.append(head + ' to ' + target(record))
            lines.append('  Corrected wording: ' + erratum['after'])
            lines.append('  ' + CORRECTED)
        lines.append('  Reason: ' + record['reason']['en'])
        if role == 'reviewer':
            lines.append(f'  When this record passes your check, write the standalone line '
                         f'`SMALL-CHANGE-CHECKED:{pins.task} {record["number"]} {sha[:12]}`.')
    return '\n'.join(lines)


# --- Merge card disclosure ----------------------------------------------------

def checked(task, record, sha, verdict, head):
    if not isinstance(verdict, dict) or verdict.get('verdict') != 'APPROVE' or verdict.get('head') != head:
        return False
    text = verdict.get('text')
    if not isinstance(text, str):
        return False
    from fm_evidence import unquoted
    line = f'SMALL-CHANGE-CHECKED:{task} {record["number"]} {sha[:12]}'
    return any(candidate.strip() == line for candidate in unquoted(text))


def disclose(details, entries, task, verdict, head):
    """A copy of the details with one caution note per record and one question."""
    combined = json.loads(json.dumps(details))
    for lang in ('en', 'zh-TW'):
        loc = combined.get(lang)
        if not isinstance(loc, dict):
            raise ValueError(lang + ': details locale missing')
        loc['notes'] = list(loc.get('notes', [])) + [
            dict(kind='caution', text=notes(record, checked(task, record, sha, verdict, head))[lang])
            for record, sha in entries]
        loc['questions'] = list(loc.get('questions', [])) + [dict(kind='fact', text=QUESTION[lang])]
    return combined


def fit_failure(combined, kind='merge'):
    """The first check_details failure for the combined details, or ''."""
    from fm_ste import check_details
    try:
        report = check_details(combined, kind=kind)
    except ValueError as error:
        return str(error)
    if not report.get('intent_card'):
        return 'details are not an intent card'
    for section in ('locales', 'labels'):
        for lang, items in report[section].items():
            for entry in items:
                for issue in entry['issues']:
                    if issue['severity'] == 'fail':
                        return '{} {}: {} -> {} {}'.format(lang, entry['field'], entry['sentence'],
                                                         issue['rule'], issue['detail'])
    return ''


# --- The stock command --------------------------------------------------------

class Usage(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Usage(message)


def arguments(argv):
    parser = Parser(prog='fm-project.sh small-change', add_help=False)
    parser.add_argument('--project')
    parser.add_argument('--repo')
    parser.add_argument('--task', required=True)
    parser.add_argument('--origin', required=True)
    parser.add_argument('--ref', required=True)
    parser.add_argument('--reason-en', required=True)
    parser.add_argument('--reason-tw', required=True)
    parser.add_argument('--path', action='append')
    parser.add_argument('--erratum')
    parser.add_argument('--after')
    args = parser.parse_args(argv)
    if bool(args.path) == bool(args.erratum):
        raise Usage('give either --path or --erratum')
    if args.erratum and args.after is None:
        raise Usage('--erratum needs --after')
    if args.path and args.after is not None:
        raise Usage('--after belongs to --erratum')
    if args.origin not in ORIGINS:
        raise Usage('unknown --origin kind: ' + args.origin)
    if args.erratum and not re.fullmatch(r'title|acceptance:(0|[1-9][0-9]*)', args.erratum):
        raise Usage('--erratum takes title or acceptance:N')
    return args


class Locked:
    def __init__(self, path):
        self.path = path

    def __enter__(self):
        if self.path.is_symlink():
            raise ValueError(self.path.name + ' must not be a symlink')
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o644)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_):
        os.close(self.fd)


def merge_authority(state, project, task):
    """Refuse while a merge card for this task waits or an approved merge has not failed."""
    from fm_merge_outcome import merge_outcome
    for folder in ('pending', 'decisions'):
        for path in sorted((Path(state) / folder).glob('*.json')):
            try:
                item = json.loads(path.read_text())
            except (OSError, ValueError):
                continue
            if (not isinstance(item, dict) or item.get('kind') not in ('merge', 'merge-untracked')
                    or item.get('task') != task or item.get('project', project) != project):
                continue
            if folder == 'pending':
                raise ValueError('a merge card is pending; let the captain answer it first')
            if item.get('chosen') == 'A' and merge_outcome(item) != 'failed':
                raise ValueError('the captain already approved a merge for this task')


def create(env, args):
    from fm_spec_pins import Pins
    pins = Pins(env, args.task)
    if pins.external:
        raise Usage(EXTERNAL)
    if args.project and args.project != pins.project:
        raise ValueError('project does not match the resolved project')
    for lang, value in (('en', args.reason_en), ('zh-TW', args.reason_tw)):
        if not check_text(value, REASON_LIMITS[lang]):
            raise ValueError(f'reason {lang} must be single-line text of at most {REASON_LIMITS[lang]} characters')
    if not check_text(args.ref, REF_LIMIT):
        raise ValueError(f'ref must be single-line text of at most {REF_LIMIT} characters')
    state = pins.state
    # Lock order: merge-turn.lock first, then the store's .lock. The merge
    # loop holds merge-turn.lock from preparing details to requesting a card.
    with Locked(state / 'merge-turn.lock'):
        merge_authority(state, pins.project, pins.task)
        chain = pins.chain()
        pin = chain[-1]
        directory = store_path(state, pins.task)
        if directory.parent.is_symlink() or directory.is_symlink():
            raise ValueError('small-change store must not be a symlink')
        directory.mkdir(parents=True, exist_ok=True)
        with Locked(directory / '.lock'):
            entries = load(state, pins.project, pins.task, chain)
            if len(bound(entries, pin)) >= MAX_PER_PIN:
                raise ValueError(f'pin version {pin["version"]} already has {MAX_PER_PIN} small-change '
                                 'records; use the full process')
            record = dict(schema=1, project=pins.project, task=pins.task, number=len(entries) + 1,
                          pin_version=pin['version'], pin_sha256=pin_digest(pin))
            if args.path:
                record['kind'] = 'paths'
            else:
                record['kind'] = 'erratum'
            record.update(reason={'en': args.reason_en, 'zh-TW': args.reason_tw},
                          origin={'kind': args.origin, 'ref': args.ref}, author='firstmate',
                          created=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                          previous_sha256=entries[-1][1] if entries else None)
            if args.path:
                record['paths'] = args.path
            else:
                field, _, index = args.erratum.partition(':')
                index = int(index) if field == 'acceptance' else None
                spec = errata_applied(json.loads(pin['snapshots']['spec']['text']),
                                      [r for r, _ in bound(entries, pin)])
                if field == 'acceptance' and not (isinstance(spec.get('acceptance'), list)
                                                  and index < len(spec['acceptance'])):
                    raise ValueError('acceptance index out of range')
                record['erratum'] = dict(field=field, index=index, before=wording(spec, field, index),
                                         after=args.after)
            data = (json.dumps(record, indent=2, ensure_ascii=False) + '\n').encode('utf-8')
            try:
                load(state, pins.project, pins.task, chain, extra=data)
            except ValueError as error:
                raise ValueError(str(error).split(': ', 1)[-1]) from None
            why = note_refusal(record)
            if why:
                raise ValueError(why)
            with tempfile.NamedTemporaryFile(mode='wb', dir=directory, suffix='.tmp', delete=False) as out:
                temporary = Path(out.name)
                out.write(data)
                out.flush()
                os.fsync(out.fileno())
            try:
                os.link(temporary, directory / (str(record['number']) + '.json'))
            finally:
                temporary.unlink()
    return record


def main(argv):
    if not argv or argv[0] not in ('check-args', 'create'):
        print('usage: fm_small_change.py check-args|create <options>', file=sys.stderr)
        return 64
    try:
        args = arguments(argv[1:])
    except Usage as error:
        print('fm-small-change: ' + str(error), file=sys.stderr)
        return 64
    if argv[0] == 'check-args':
        return 0
    if os.environ.get('FM_EXTERNAL') == '1':
        print('fm-small-change: ' + EXTERNAL, file=sys.stderr)
        return 64
    if os.environ.get('FM_IN_ROUND'):
        print('fm-small-change: run it from the operator shell, not inside a crew round', file=sys.stderr)
        return 65
    try:
        record = create(os.environ, args)
    except Usage as error:
        print('fm-small-change: ' + str(error), file=sys.stderr)
        return 64
    except (ValueError, OSError, KeyError, TypeError) as error:
        print('fm-small-change: ' + ' '.join(str(error).split()), file=sys.stderr)
        return 65
    print(json.dumps(record, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
