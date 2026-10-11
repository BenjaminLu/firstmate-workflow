#!/usr/bin/env python3
"""The rule inventory of the firstmate skill (T-279).

  python3 bin/lib/fm_rules.py check --root <dir>

skills/firstmate/rule-inventory.json lists every rule sentence of
skills/firstmate/SKILL.md: a sentence, outside a fenced code block, that holds
the word must, never, always, "do not" or "don't". Each entry quotes its rule
under the heading it sits beneath and says whether code already refuses a
breach (enforced, with the refusal message as evidence), could (enforceable,
with a proposal), or the rule needs judgement.

`check` prints one line per problem and exits 1 when there is any. When there
is none it prints the number of rules in each class and exits 0. It writes no
file, and it reads nothing outside <dir>: a path that is absolute, holds `..`,
or resolves outside <dir> through a symbolic link is refused unread. For each
rule sentence no entry covers, it also prints a stub entry, one line of JSON,
for the author to paste into the inventory and give a class.
"""
import io
import json
import re
import sys
import tokenize
from pathlib import Path, PurePosixPath

INVENTORY = 'skills/firstmate/rule-inventory.json'
SKILL = 'skills/firstmate/SKILL.md'
CLASSES = ('enforced', 'enforceable', 'judgement')
RULE_ID = re.compile(r'R-[0-9]{3,}')
RULE_WORD = re.compile(r"\b(must|never|always|do not|don['’]t)\b", re.IGNORECASE)
# A sentence ends after . ; ? or ! when whitespace and then an upper-case
# letter, a backtick or an opening bracket follow.
SENTENCE_END = re.compile(r'(?<=[.;?!])\s+(?=[A-Z`\[(])')
HEADING = re.compile(r' {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$')
FENCE = re.compile(r' {0,3}(`{3,}|~{3,})')
LIST_ITEM = re.compile(r'\s*(?:[-*+]|[0-9]+[.)])\s+')
MIN_QUOTE = 20


def squash(text):
    """Runs of whitespace collapsed to one space."""
    return ' '.join(text.split())


class Tree:
    """Reads files inside one root, and refuses any path that leaves it."""

    def __init__(self, root):
        self.root = Path(root).resolve()
        self.cache = {}

    def path(self, rel):
        """(path, None) for a readable file inside the root, else (None, reason)."""
        if not isinstance(rel, str) or not rel:
            return None, 'is not a relative path'
        pure = PurePosixPath(rel)
        if pure.is_absolute() or rel.startswith('\\'):
            return None, f'{rel} is an absolute path'
        if '..' in pure.parts:
            return None, f'{rel} holds ..'
        resolved = (self.root / rel).resolve()
        if resolved != self.root and self.root not in resolved.parents:
            return None, f'{rel} resolves outside the tree'
        if not resolved.is_file():
            return None, f'{rel} does not exist'
        return resolved, None

    def read(self, rel):
        if rel not in self.cache:
            path, why = self.path(rel)
            if why:
                self.cache[rel] = (None, why)
            else:
                try:
                    self.cache[rel] = (path.read_text(encoding='utf-8'), None)
                except (OSError, UnicodeDecodeError) as err:
                    self.cache[rel] = (None, f'{rel} cannot be read: {err}')
        return self.cache[rel]


def markdown_lines(text):
    """(line number, line, heading text or None, inside a fence) for each line."""
    out, fence = [], None
    for number, line in enumerate(text.split('\n'), 1):
        mark = FENCE.match(line)
        if fence:
            if mark and mark.group(1)[0] == fence[0] and len(mark.group(1)) >= len(fence) \
                    and not line[mark.end():].strip():
                fence = None
            out.append((number, line, None, True))
            continue
        if mark:
            fence = mark.group(1)
            out.append((number, line, None, True))
            continue
        heading = HEADING.fullmatch(line)
        out.append((number, line, (heading.group(2) or '') if heading else None, False))
    return out


def sections(text):
    """[(heading, section text)] in file order; '' is the text before the first heading."""
    found, heading, lines = [], '', []
    for _, line, title, _ in markdown_lines(text):
        if title is not None:
            found.append((heading, '\n'.join(lines)))
            heading, lines = title, []
        lines.append(line)
    found.append((heading, '\n'.join(lines)))
    return found


def blocks(text):
    """Each paragraph and list item outside fences: (heading, [(line number, text)])."""
    out, heading, current = [], '', []

    def close():
        if current:
            out.append((heading, list(current)))
            current.clear()

    for number, line, title, fenced in markdown_lines(text):
        if fenced or title is not None or not line.strip():
            close()
            if title is not None:
                heading = title
            continue
        if LIST_ITEM.match(line):
            close()
        current.append((number, squash(line)))
    close()
    return out


def rule_sentences(text):
    """(heading, line number, sentence) for every rule sentence of a Markdown text."""
    out = []
    for heading, lines in blocks(text):
        joined, starts, offset = '', [], 0
        for number, part in lines:
            starts.append((offset, number))
            joined += part + ' '
            offset = len(joined)
        joined = joined.rstrip()
        position = 0
        for piece in SENTENCE_END.split(joined) + ['']:
            if not piece:
                continue
            at = joined.index(piece, position)
            position = at + len(piece)
            if RULE_WORD.search(piece):
                line = max(number for start, number in starts if start <= at)
                out.append((heading, line, piece))
    return out


def comment_free(rel, text):
    """The parts of a file that are not comments: Python string tokens, or other lines."""
    if not rel.endswith('.py'):
        return [line for line in text.split('\n') if not line.lstrip().startswith(('#', '//'))]
    lines = text.splitlines(keepends=True)
    offsets = [0]
    for line in lines:
        offsets.append(offsets[-1] + len(line))
    spans, depth, start = [], 0, None
    fstring_start = getattr(tokenize, 'FSTRING_START', None)
    fstring_end = getattr(tokenize, 'FSTRING_END', None)
    for token in tokenize.generate_tokens(io.StringIO(text).readline):
        if token.type == tokenize.STRING and not depth:
            spans.append(token.string)
        elif fstring_start is not None and token.type == fstring_start:
            if not depth:
                start = offsets[token.start[0] - 1] + token.start[1]
            depth += 1
        elif fstring_end is not None and token.type == fstring_end:
            depth -= 1
            if not depth:
                spans.append(text[start:offsets[token.end[0] - 1] + token.end[1]])
    return spans


def check_entry(index, entry, seen, retired, problems):
    """Schema problems of one entry; returns its label."""
    if not isinstance(entry, dict):
        problems.append(f'rules[{index}]: not an object')
        return None
    rule_id = entry.get('id')
    valid = isinstance(rule_id, str) and RULE_ID.fullmatch(rule_id)
    label = rule_id if valid else f'rules[{index}]'
    if 'id' not in entry:
        problems.append(f'{label}: missing field id')
    elif not isinstance(rule_id, str):
        problems.append(f'{label}: id must be a string')
    elif not valid:
        problems.append(f'{label}: id {rule_id!r} is not R- followed by three or more digits')
    elif rule_id in seen:
        problems.append(f'{label}: id appears more than once in rules')
    elif rule_id in retired:
        problems.append(f'{label}: id is also in retired')
    if valid:
        seen.add(rule_id)
    for field in ('file', 'heading', 'quote', 'class'):
        if field not in entry:
            problems.append(f'{label}: missing field {field}')
        elif not isinstance(entry[field], str):
            problems.append(f'{label}: {field} must be a string')
    quote = entry.get('quote')
    if isinstance(quote, str) and len(squash(quote)) < MIN_QUOTE:
        problems.append(f'{label}: quote is shorter than {MIN_QUOTE} characters')
    kind = entry.get('class')
    if isinstance(kind, str) and kind not in CLASSES:
        problems.append(f'{label}: class {kind!r} is not one of {", ".join(CLASSES)}')
    if 'evidence' in entry:
        evidence = entry['evidence']
        if not isinstance(evidence, list) or not all(
                isinstance(item, dict) and isinstance(item.get('file'), str)
                and isinstance(item.get('text'), str) and item['text'] for item in evidence):
            problems.append(f'{label}: evidence must be a list of objects with string file and text')
            entry['evidence'] = []
    if 'proposal' in entry and not (isinstance(entry['proposal'], str) and entry['proposal'].strip()):
        problems.append(f'{label}: proposal must be a non-empty string')
    if kind == 'enforced' and not entry.get('evidence'):
        problems.append(f'{label}: an enforced rule needs evidence')
    if kind == 'enforceable' and 'proposal' not in entry:
        problems.append(f'{label}: an enforceable rule needs a proposal')
    return label


def check_quote(tree, label, entry, problems):
    text, why = tree.read(entry['file'])
    if why:
        problems.append(f'{label}: file {why}')
        return
    quote, heading = squash(entry['quote']), entry['heading']
    count = squash(text).count(quote)
    if count == 0:
        problems.append(f'{label}: quote not found in {entry["file"]}')
        return
    if count > 1:
        problems.append(f'{label}: quote appears {count} times in {entry["file"]}; it must appear once')
        return
    titles = [title for title, _ in sections(text)]
    if not any(title == heading and quote in squash(body) for title, body in sections(text)):
        where = 'under another heading' if heading in titles else 'and there is no such heading'
        problems.append(f'{label}: quote is not under heading {heading!r} ({where})')


def check_evidence(tree, label, entry, problems):
    for item in entry.get('evidence') or []:
        rel = item['file']
        text, why = tree.read(rel)
        if why:
            problems.append(f'{label}: evidence {why}')
            continue
        if item['text'] not in text:
            problems.append(f'{label}: evidence {rel}: text not found: {item["text"]!r}')
            continue
        try:
            parts = comment_free(rel, text)
        except (tokenize.TokenError, SyntaxError) as err:
            problems.append(f'{label}: evidence {rel}: cannot be tokenized: {err}')
            continue
        if not any(item['text'] in part for part in parts):
            where = 'outside a string' if rel.endswith('.py') else 'in a comment'
            problems.append(f'{label}: evidence {rel}: text found only {where}: {item["text"]!r}')


def check(root):
    """(problems, stubs, summary) for the tree at root."""
    tree, problems = Tree(root), []
    raw, why = tree.read(INVENTORY)
    if why:
        return [f'the inventory: {why}'], [], None
    try:
        inventory = json.loads(raw)
    except ValueError as err:
        return [f'{INVENTORY}: not valid JSON: {err}'], [], None
    if not isinstance(inventory, dict):
        return [f'{INVENTORY}: the top level is not an object'], [], None
    if type(inventory.get('version')) is not int or inventory['version'] != 1:
        return [f'{INVENTORY}: version is not the integer 1'], [], None
    for field in ('rules', 'retired'):
        if not isinstance(inventory.get(field), list):
            return [f'{INVENTORY}: {field} is missing or not an array'], [], None
    retired = set()
    for index, item in enumerate(inventory['retired']):
        if not (isinstance(item, str) and RULE_ID.fullmatch(item)):
            problems.append(f'retired[{index}]: not a rule ID of the form R-001')
        elif item in retired:
            problems.append(f'retired[{index}]: {item} appears more than once in retired')
        else:
            retired.add(item)
    seen, counts, quotes = set(), {kind: 0 for kind in CLASSES}, []
    for index, entry in enumerate(inventory['rules']):
        label = check_entry(index, entry, seen, retired, problems)
        if label is None:
            continue
        if entry.get('class') in CLASSES:
            counts[entry['class']] += 1
        if all(isinstance(entry.get(field), str) for field in ('file', 'heading', 'quote')):
            check_quote(tree, label, entry, problems)
            if entry['file'] == SKILL:
                quotes.append(squash(entry['quote']))
        if entry.get('class') == 'enforced':
            check_evidence(tree, label, entry, problems)
    text, why = tree.read(SKILL)
    if why:
        problems.append(f'{SKILL}: {why}')
        return problems, [], None
    stubs = []
    for heading, line, sentence in rule_sentences(text):
        if not any(quote in sentence for quote in quotes):
            problems.append(f'{SKILL}:{line}: a rule sentence with no inventory entry: {sentence}')
            stubs.append((len(problems) - 1, json.dumps(
                {'id': '', 'file': SKILL, 'heading': heading, 'quote': sentence, 'class': ''},
                ensure_ascii=False)))
    total = sum(counts.values())
    summary = f'{total} rules: ' + ', '.join(f'{counts[kind]} {kind}' for kind in CLASSES)
    return problems, stubs, summary


def main(argv):
    if len(argv) != 3 or argv[0] != 'check' or argv[1] != '--root':
        print('usage: fm_rules.py check --root <dir>', file=sys.stderr)
        return 64
    if not Path(argv[2]).is_dir():
        print(f'fm_rules.py: --root {argv[2]} is not a directory', file=sys.stderr)
        return 64
    problems, stubs, summary = check(argv[2])
    stub_after = dict(stubs)
    for index, problem in enumerate(problems):
        print(problem)
        if index in stub_after:
            print(stub_after[index])
    if problems:
        return 1
    print(summary)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
