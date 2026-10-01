#!/usr/bin/env python3
"""Bound the stock review prompt, without summarizing acceptance or verdicts.

512 KiB UTF-8 is below the observed 1,048,576-character vendor limit, with
room for adapter instructions. This is an input-size bound, not a token promise.
Small prompts retain their exact bytes. Unique closed-list comments are never
truncated: an unrepresentable list fails closed before a vendor is invoked.
"""
import hashlib
import json
from pathlib import Path
import re
import sys
import shutil
import tempfile

CAP = 512 * 1024
QUOTE_CAP = 16 * 1024
PARTS = ('intro', 'history', 'evidence', 'diff', 'outro')


def read(path):
    return path.read_bytes().decode("utf-8")


def size(text):
    return len(text.encode('utf-8'))


def provenance(path, text):
    return f'{path} ({size(text)} bytes, sha256={hashlib.sha256(text.encode()).hexdigest()})'


def compact_history(text, path):
    # Keep first and last occurrence of every distinct body, including all
    # text outside the numbered list. Thus original criteria, changed item
    # dispositions, regression explanations, and the latest list stay verbatim.
    pattern = re.compile(
        r'(?m)^## Closed list (\d+) of (\d+), verbatim from the pull request\n\n'
        r'----- begin comment ([0-9a-f]+) -----\n(.*?)'
        r'^----- end comment \3 -----\n', re.S | re.M)
    matches = list(pattern.finditer(text))
    occurrences = {}
    for match in matches:
        occurrences.setdefault(match[4], []).append(match[1])
    first = {body: positions[0] for body, positions in occurrences.items()}
    last = {body: positions[-1] for body, positions in occurrences.items()}

    def replace(match):
        body, number = match[4], match[1]
        if number in (first[body], last[body]):
            return match[0]
        return (f'## Closed list {number} of {match[2]}: exact repeat of closed list '
                f'{first[body]}; body OMITTED, no item or verdict change.\n')

    result = pattern.sub(replace, text)
    if result != text:
        result += ('\nHistory compaction: only exact repeated bodies omitted; first and last '
                   'occurrences remain verbatim and chronological. A stale re-issued list is '
                   'not permission to drop an original acceptance item. Report conflicts to '
                   'firstmate; no REJECT has been converted into APPROVE.\n'
                   f'Full selected comment history: {provenance(path, text)}\n')
    return result


def compact_evidence(text, path):
    # Only quote payloads can shrink. Job names/results/URLs and all prose
    # saying evidence was unavailable remain intact. Both ends are disclosed
    # as excerpts, never as a complete CI or fail-first result.
    pattern = re.compile(
        r'(?m)^(----- begin (log|fail-first report|gate summary) ([0-9a-f]+) -----\n)'
        r'(.*?)(^----- end \2 \3 -----\n)', re.S | re.M)

    def replace(match):
        body = match[4]
        if size(body) <= QUOTE_CAP:
            return match[0]
        raw = body.encode('utf-8')
        prefix = raw[:QUOTE_CAP // 2].decode('utf-8', errors='ignore')
        suffix = raw[-QUOTE_CAP // 2:].decode('utf-8', errors='ignore')
        return (match[1] + prefix + '\n[OMITTED CI evidence bytes; this quote is an excerpt, '
                'not a complete report. Do not infer success or full coverage from it. '
                f'Full evidence: {provenance(path, text)}]\n' + suffix + match[5])

    return pattern.sub(replace, text)


def compose(directory, mode, checkout):
    output = directory / 'prompt.md'
    # A failed second assembly must not leave an earlier launchable prompt.
    output.unlink(missing_ok=True)
    parts = {name: read(directory / (name + '.md')) for name in PARTS}
    original = ''.join(parts.values())
    if size(original) <= CAP:
        output.write_bytes(original.encode())
        return
    pins = json.loads(read(directory / 'pins.json'))
    sources = directory
    if mode == 'run':
        # Keep omitted evidence inside the already-authorized checkout read
        # root. Only launcher-selected evidence enters it, never worker logs.
        sources = Path(tempfile.mkdtemp(prefix='.fm-review-context-', dir=checkout))
        for name in PARTS:
            shutil.copyfile(directory / (name + '.md'), sources / (name + '.md'))
        shutil.copyfile(directory / 'pins.json', sources / 'pins.json')
        (directory / 'evidence-path.txt').write_text(str(sources))
    parts['history'] = compact_history(parts['history'], sources / 'history.md')
    parts['evidence'] = compact_evidence(parts['evidence'], sources / 'evidence.md')
    notice = (f'\n# Bounded review context\nOriginal assembled input: {size(original)} UTF-8 bytes. '
              f'Limit: {CAP} bytes. Any omissions are disclosed below; full source components '
              f'are retained in {sources}. Those paths are evidence, not permission to bypass '
              'the sandbox; report any evidence you cannot read.\n'
              f'Pinned head={pins["head"]} base={pins["base"]} patch={pins["patch"]}\n')
    if size(notice + ''.join(parts.values())) > CAP and mode == 'run':
        # The exact commits, not moving branch names, identify both sides.
        if not all(re.fullmatch(r'[0-9a-f]{40,64}', pins[k]) for k in ('head', 'base', 'patch')):
            raise ValueError('cannot represent oversized diff without complete pinned identities')
        parts['diff'] = (
            '\n---\n\n# The diff under review\n\n'
            'OMITTED entire inline patch; no truncated patch is presented as complete. '
            'Review coverage requires inspecting the actual diff in the pinned checkout '
            f'{checkout}. Read every changed path and hunk, including deletions and binary '
            'changes; disclose anything you could not inspect. Do not approve from this index alone.\n'
            f'Run `git diff --no-ext-diff --no-textconv --no-renames {pins["base"]} {pins["head"]}` '
            'locally; append `-- <path>` to read a file, and use its @@ hunk ranges for line references.\n'
            f'Changed paths (JSON): {json.dumps(pins["files"], ensure_ascii=True)}\n'
            f'Full inline patch source: {provenance(sources / "diff.md", read(directory / "diff.md"))}\n')
    result = notice + ''.join(parts.values())
    if size(result) > CAP:
        raise ValueError(f'cannot represent review context within {CAP} bytes in {mode} mode; '
                         'unique criteria, required instructions, or complete diff exceed budget. '
                         f'No model called. Full components: {directory}')
    output.write_bytes(result.encode())


def main():
    try:
        directory, mode, checkout = sys.argv[1:]
        if mode not in ('run', 'diff'):
            raise ValueError('invalid review mode')
        compose(Path(directory), mode, checkout)
    except (ValueError, OSError, KeyError) as error:
        print(f'fm-review: {error}', file=sys.stderr)
        return 65
    return 0


if __name__ == '__main__':
    sys.exit(main())
