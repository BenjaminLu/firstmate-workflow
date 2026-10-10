#!/usr/bin/env python3
"""Plain-writing checks for specs, cards and posted text (T-270).

The rules live in skills/firstmate/plain-writing.md and the terms in
i18n/glossary.json. This module only holds the mechanical part: glued
numbers, slash chains, unexplained glossary terms, the protected-token guard
for reviewer rewrites, rewrite-block extraction and the zh-CN rendering the
board uses. None of it can judge meaning.
"""
from collections import Counter
import datetime
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
LOCALES = ('en', 'zh-TW')
TOP = ('bin', 'board', 'tests', 'design', 'skills', 'i18n', 'docs', 'games', 'state', '.github')
ID = re.compile(r'[a-z][a-z0-9-]*')
BLOCKS = ('fm-reworded-spec', 'fm-reworded-card', 'fm-reworded-pr-authoring', 'fm-merge-card')

CODE = r'`[^`\n]*`'
URL = r'https?://\S+'
HASH = r'\b[0-9a-fA-F]{7,}\b'
TASK = r'\b(?:T|SK)-[A-Za-z0-9]+\b'
DECISION = r'\bD-[A-Za-z0-9][A-Za-z0-9-]*'
VERSION = r'\bv?\d+(?:\.\d+)+\b|\bv\d+\b'
MARKER = (r'\b(?:APPROVE|REJECT|SPEC-OK|SPEC-GAPS|PREFLIGHT-COMPLETE|CRITERIA-COMPLETE|REGRESSION'
          r'|NEW-GROUND|MISSED|SCOPE-BLOCKED|SWEPT|ASK-[A-Z][A-Z-]*|WORKER_[A-Z_]+):\S*'
          r'|^\s*EVIDENCE:.*$|<!--.*?-->')
FILE_LINE = r'[A-Za-z0-9_./-]+\.[A-Za-z0-9]+:\d+(?:-\d+)?'


def _path(token):
    """A repository path: a slash plus a dot or a top-level directory name."""
    bare = token.strip('()[]{}<>"\'.,;:!?')
    if '/' not in bare:
        return False
    return '.' in bare or any(part in TOP for part in bare.split('/'))


def strip(text):
    """Remove the tokens the checks never read; keep word boundaries."""
    text = re.sub(CODE, ' ', text)
    text = re.sub(MARKER, ' ', text, flags=re.M)
    text = re.sub(URL, ' ', text)
    text = re.sub(r'\S+', lambda m: ' ' if _path(m.group()) else m.group(), text)
    for pattern in (HASH, TASK, DECISION, VERSION):
        text = re.sub(pattern, ' ', text)
    return text


def glued(text):
    """Letters and digits that touch inside one word: All13, ts2672."""
    return [word for word in re.findall(r'[A-Za-z0-9]+', strip(text))
            if re.search(r'[A-Za-z][0-9]|[0-9][A-Za-z]', word)]


def slashes(text):
    """Three or more words joined by slashes: a/b/c."""
    return re.findall(r'[^\W_][\w-]*(?:/[^\W_][\w-]*){2,}', strip(text))


# --- glossary -------------------------------------------------------------

def i18n_file(name, root=None):
    """i18n/<name> under the given code root only; never another checkout."""
    return (Path(root) if root else ROOT) / 'i18n' / name


def glossary_path(root=None):
    return i18n_file('glossary.json', root)


def validate_glossary(data):
    if not isinstance(data, dict) or data.get('schema') != 1 or not isinstance(data.get('terms'), list):
        raise ValueError('glossary.json: expected {"schema": 1, "terms": [...]}')
    seen = set()
    for entry in data['terms']:
        if not isinstance(entry, dict) or not isinstance(entry.get('id'), str) or not ID.fullmatch(entry['id']):
            raise ValueError('glossary.json: each term needs an id matching ^[a-z][a-z0-9-]*$')
        if entry['id'] in seen:
            raise ValueError('glossary.json: duplicate id ' + entry['id'])
        seen.add(entry['id'])
        for lang in LOCALES:
            loc = entry.get(lang)
            where = 'glossary.json: ' + entry['id'] + '.' + lang
            if not isinstance(loc, dict):
                raise ValueError(where + ': missing locale')
            for key in ('term', 'text'):
                if not isinstance(loc.get(key), str) or not loc[key].strip():
                    raise ValueError(where + '.' + key + ': expected nonempty text')
            aliases = loc.get('aliases')
            if not isinstance(aliases, list) or not all(isinstance(a, str) and a.strip() for a in aliases):
                raise ValueError(where + '.aliases: expected a list of nonempty strings')
    return data


def read_i18n(name, root):
    """The text of i18n/<name>; a missing or unreadable file is an error
    naming that file, never an empty dictionary."""
    path = i18n_file(name, root)
    try:
        return path.read_text(encoding='utf-8')
    except (OSError, UnicodeDecodeError) as error:
        raise ValueError(('missing ' if not path.exists() else 'unreadable ') + str(path)
                         + ': ' + str(error)) from None


def load_glossary(root=None):
    """Read and validate glossary.json from the code root."""
    return validate_glossary(json.loads(read_i18n('glossary.json', root)))


def find_terms(text, lang, glossary):
    """Glossary ids whose term or alias appears; the longer overlap wins."""
    clean = strip(text)
    candidates = []
    for entry in glossary['terms']:
        loc = entry[lang]
        for form in [loc['term'], *loc['aliases']]:
            if lang == 'en':
                pattern = r'(?<![A-Za-z0-9])' + re.escape(form) + r'(?![A-Za-z0-9])'
                found = [(m.start(), m.end()) for m in re.finditer(pattern, clean, re.I)]
            else:
                found, start = [], clean.find(form)
                while start >= 0:
                    found.append((start, start + len(form)))
                    start = clean.find(form, start + 1)
            candidates += [(start, end, entry['id']) for start, end in found]
    taken, result = [], []
    for start, end, ident in sorted(candidates, key=lambda c: (-(c[1] - c[0]), c[0])):
        if any(start < e and s < end for s, e in taken):
            continue
        taken.append((start, end))
        result.append((start, end, ident))
    return [ident for _, _, ident in sorted(result)]


def expand(ids, lang, glossary):
    """{id, term, text} for each id, as fm-decide stores them on a card."""
    by_id = {entry['id']: entry for entry in glossary['terms']}
    return [dict(id=ident, term=by_id[ident][lang]['term'], text=by_id[ident][lang]['text']) for ident in ids]


def ids_of(glossary):
    """Stored cards carry expanded objects; authors and checks use ids."""
    return [item.get('id') if isinstance(item, dict) else item for item in glossary or []]


# --- card text --------------------------------------------------------------

def card_texts(loc):
    """Every human-visible card string in one locale, with its field name."""
    out = []

    def add(field, value):
        if isinstance(value, str):
            out.append((field, value))

    if not isinstance(loc, dict):
        return out
    for field in ('title', 'explanation', 'before', 'after', 'outcome'):
        add(field, loc.get(field))
    options = loc.get('options')
    if isinstance(options, dict):
        for key, option in options.items():
            if isinstance(option, dict):
                for field in ('description', 'pros', 'cons'):
                    add('options.' + key + '.' + field, option.get(field))
    for field in ('intent', 'why', 'how', 'done', 'notes', 'questions', 'change_table'):
        for item in loc.get(field) or []:
            if isinstance(item, dict):
                add(field, item.get('text'))
    for field in ('scope_in', 'scope_out'):
        for item in loc.get(field) or []:
            add(field, item)
    for point in loc.get('change_points') or []:
        if isinstance(point, dict):
            add('change_points.how', point.get('how'))
    door = loc.get('door')
    if isinstance(door, dict):
        for field in ('reason', 'rollback'):
            add('door.' + field, door.get(field))
    check = loc.get('check')
    if isinstance(check, dict):
        for field in ('q', 'why'):
            add('check.' + field, check.get(field))
        for option in check.get('options') or []:
            add('check.options', option)
    for field in ('before_nodes', 'after_nodes'):
        for item in loc.get(field) or []:
            if isinstance(item, dict):
                add(field, item.get('label'))
    return out


def lint(text, lang='en', glossary=None, listed=None, field='text'):
    """Findings for one text: glued numbers, slash chains and, when a
    glossary is given, terms whose id is not in `listed`."""
    findings = [dict(check='glued-number', field=field, match=m) for m in glued(text)]
    findings += [dict(check='slash-chain', field=field, match=m) for m in slashes(text)]
    if glossary is not None:
        listed = set(listed or ())
        for ident in dict.fromkeys(find_terms(text, lang, glossary)):
            if ident not in listed:
                findings.append(dict(check='unexplained-term', field=field, match=ident))
    return findings


def check_card(details, glossary):
    """Problems that block a card request (Change 8); empty means plain."""
    problems = []
    known = {entry['id'] for entry in glossary['terms']}
    for lang in LOCALES:
        loc = details.get(lang) if isinstance(details, dict) else None
        if not isinstance(loc, dict):
            problems.append(lang + ': missing locale')
            continue
        for field in ('why', 'how'):
            items = loc.get(field)
            if not isinstance(items, list) or not items:
                problems.append(lang + '.' + field + ': expected a nonempty list')
                continue
            for item in items:
                if (not isinstance(item, dict) or set(item) != {'kind', 'text'}
                        or item['kind'] not in ('step', 'fact') or not isinstance(item['text'], str)
                        or not item['text'].strip()):
                    problems.append(lang + '.' + field + ': each item is {kind: step|fact, text}')
                    break
        listed = loc.get('glossary')
        if not isinstance(listed, list) or not all(isinstance(i, str) for i in listed):
            problems.append(lang + '.glossary: expected a list of glossary ids')
            listed = []
        for ident in listed:
            if ident not in known:
                problems.append(lang + '.glossary: unknown id ' + ident)
        for field, text in card_texts(loc):
            for finding in lint(text, lang, glossary, listed, field):
                problems.append('{}.{}: {} "{}"'.format(lang, field, finding['check'], finding['match']))
    return problems


# --- zh-CN ------------------------------------------------------------------

def tw2cn_rows(root=None):
    """The rows board/server.ts sends, in file order."""
    rows = []
    for line in read_i18n('tw2cn.tsv', root).split('\n'):
        if line.strip() == '' or line.startswith('#'):
            continue
        pair = line.split('\t')
        if len(pair) == 2:
            rows.append(pair)
    return rows


def to_cn(text, rows):
    """Apply each row as split(a).join(b), exactly as board/public/index.html."""
    for a, b in rows:
        text = b.join(list(text)) if a == '' else text.replace(a, b)
    return text


def card_cn(details, rows):
    """The zh-CN card the board shows: zh-TW strings through the table."""
    def walk(value):
        if isinstance(value, str):
            return to_cn(value, rows)
        if isinstance(value, list):
            return [walk(v) for v in value]
        if isinstance(value, dict):
            return {k: walk(v) for k, v in value.items()}
        return value
    return walk((details or {}).get('zh-TW', {}))


# --- reviewer rewrites --------------------------------------------------------

def protected(text):
    """Multiset of tokens a rewrite must keep (Change 6)."""
    tokens = []

    def take(pattern, value, flags=0):
        tokens.extend(m.group() for m in re.finditer(pattern, value, flags))
        return re.sub(pattern, ' ', value, flags=flags)

    rest = take(CODE, text)
    rest = take(URL, rest)
    rest = take(FILE_LINE, rest)
    kept = []
    for token in rest.split():
        if _path(token):
            tokens.append(token.strip('()[]{}<>"\'.,;:!?'))
        else:
            kept.append(token)
    rest = ' '.join(kept)
    for pattern in (HASH, TASK, DECISION):
        rest = take(pattern, rest)
    take(r'\d+(?:[.,]\d+)*', rest)
    return Counter(tokens)


def blocks(answer):
    """{kind: [content, ...]} for each rewrite fence; 'unclosed' on a missing end."""
    found = {kind: [] for kind in BLOCKS}
    lines = answer.splitlines()
    i, fence = 0, None
    while i < len(lines):
        line = lines[i]
        opener = re.fullmatch(r'```json (' + '|'.join(BLOCKS) + ')', line)
        if fence is None and opener:
            body, i = [], i + 1
            while i < len(lines) and lines[i] != '```':
                body.append(lines[i])
                i += 1
            if i >= len(lines):
                found[opener[1]].append(None)
                return found, True
            found[opener[1]].append('\n'.join(body) + '\n')
        else:
            match = re.match(r'^\s*(`{3,}|~{3,})', line)
            if match:
                if fence is None:
                    fence = match[1]
                elif match[1][0] == fence[0] and len(match[1]) >= len(fence):
                    fence = None
        i += 1
    return found, False


def without(text, kinds=('fm-merge-card',)):
    """The text with every block of these kinds removed; an unclosed block
    takes the rest of the text with it."""
    out, skipping = [], False
    for line in text.split('\n'):
        if skipping:
            skipping = line != '```'
            continue
        if any(line == '```json ' + kind for kind in kinds):
            skipping = True
            continue
        out.append(line)
    return '\n'.join(out)


def candidate(found, kind, solicited=True):
    """(text, None) for one usable block, (None, reason) when refused, or (None, None)."""
    contents = found.get(kind, [])
    if not contents:
        return None, None
    if not solicited:
        return None, 'unsolicited'
    if len(contents) > 1:
        return None, 'duplicate'
    if contents[0] is None:
        return None, 'unclosed'
    try:
        value = json.loads(contents[0])
    except ValueError:
        return None, 'not-an-object'
    if not isinstance(value, dict):
        return None, 'not-an-object'
    return contents[0], None


def _guard(old, new, where):
    if protected(old) != protected(new):
        raise ValueError(where + ': protected tokens changed')


def compare(old, new, allowed, where=''):
    """Identical except strings at allowed paths, which keep protected tokens.

    `allowed(path)` gets a tuple of keys and indexes from the root.
    """
    def walk(a, b, path):
        label = where + '.'.join(str(p) for p in path)
        if allowed(path) and isinstance(a, str) and isinstance(b, str):
            if a != b:
                _guard(a, b, label)
            return
        if type(a) is not type(b):
            raise ValueError(label + ': changed type')
        if isinstance(a, dict):
            if set(a) != set(b):
                raise ValueError(label + ': changed keys')
            for key in a:
                walk(a[key], b[key], path + (key,))
        elif isinstance(a, list):
            if len(a) != len(b):
                raise ValueError(label + ': changed list length')
            for index, (x, y) in enumerate(zip(a, b)):
                walk(x, y, path + (index,))
        elif a != b:
            raise ValueError(label + ': only prose may change')
    walk(old, new, ())


def spec_prose(path):
    return path == ('title',) or (len(path) == 2 and path[0] == 'acceptance')


def card_prose(path):
    if len(path) < 2 or path[0] not in LOCALES:
        return False
    rest = path[1:]
    if rest in (('title',), ('explanation',), ('before',), ('after',), ('outcome',)):
        return True
    if len(rest) == 3 and rest[0] == 'options' and rest[2] in ('description', 'pros', 'cons'):
        return True
    if len(rest) == 3 and rest[0] in ('why', 'how', 'notes', 'questions', 'change_table') and rest[2] == 'text':
        return True
    return len(rest) == 3 and rest[0] in ('before_nodes', 'after_nodes') and rest[2] == 'label'


def pr_prose(path):
    if path in (('subject',), ('problem',), ('expected_result',), ('approach',)):
        return True
    return len(path) == 3 and path[0] == 'intent_notes' and path[2] == 'note'


# --- advisory log -------------------------------------------------------------

def log_findings(log, source, findings):
    """Append advisory findings to firstmate's log; never raise."""
    if not findings or not log:
        return
    try:
        path = Path(log)
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('a', encoding='utf-8') as out:
            out.write(json.dumps(dict(ts=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                                      source=source, findings=findings), ensure_ascii=False) + '\n')
    except OSError:
        pass


def default_log():
    state = os.environ.get('FM_STATE_DIR')
    return str(Path(state) / 'runtime/plain-writing.jsonl') if state else ''


def _read(path):
    return sys.stdin.read() if path == '-' else Path(path).read_text(encoding='utf-8')


def main(argv):
    """fm_plain.py lint <file|-> [--source <name>] [--log <path>]: advisory only.
    fm_plain.py public <file|->: the text without fm-merge-card blocks.
    `-` reads standard input, so a caller needs no temporary file."""
    if len(argv) == 2 and argv[0] == 'public':
        try:
            sys.stdout.write(without(_read(argv[1])))
        except OSError as error:
            print('fm_plain: ' + str(error), file=sys.stderr)
            return 65
        return 0
    if len(argv) < 2 or argv[0] != 'lint':
        print('usage: fm_plain.py lint <file> [--source <name>] [--log <path>] | public <file>', file=sys.stderr)
        return 64
    source, log = 'text', default_log()
    rest = argv[2:]
    while rest:
        if rest[0] in ('--source', '--log') and len(rest) > 1:
            if rest[0] == '--source':
                source = rest[1]
            else:
                log = rest[1]
            rest = rest[2:]
        else:
            print('fm_plain: unknown argument ' + rest[0], file=sys.stderr)
            return 64
    try:
        text = _read(argv[1])
        glossary = load_glossary()
    except (OSError, ValueError) as error:
        # Advisory: a broken reader never stops the post it would have read,
        # but the failure reaches firstmate's log with the file it names.
        log_findings(log, source, [dict(check='lint-failed', match=str(error))])
        print('fm_plain: advisory lint skipped: ' + str(error), file=sys.stderr)
        return 0
    lang = 'zh-TW' if re.search(r'[\u4e00-\u9fff]', text) else 'en'
    findings = lint(text, lang, glossary, [])
    log_findings(log, source, findings)
    for finding in findings:
        print('fm_plain: advisory {} {} "{}"'.format(source, finding['check'], finding['match']), file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
