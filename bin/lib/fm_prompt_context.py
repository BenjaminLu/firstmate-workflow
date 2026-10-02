#!/usr/bin/env python3
"""Render launcher-owned design context; never trim conventions or gate policy."""
import hashlib
import json
import re
from pathlib import Path
import sys

DESIGN_CAP = 48000


def design(text, role='', task=''):
    raw = text.encode('utf-8')
    # Keep the former self excerpt (sections 6 and 7 through the heading of
    # section 8) whole. Then prioritize headings naming this task or role.
    # Selection uses source spans, so no content is duplicated or invented.
    headings = list(re.finditer(r'^(#{2,6}) .+$', text, re.M))
    required = []
    relevant = []
    for i, match in enumerate(headings):
        start, heading = match.start(), match.group()
        level = len(match.group(1))
        end = next((m.start() for m in headings[i + 1:] if len(m.group(1)) <= level), len(text))
        if re.match(r'## [67]\.', heading):
            required.append((start, end))
        elif re.match(r'## 8\.', heading):
            required.append((start, match.end() + int(text[match.end():].startswith('\n'))))
        elif ((task and re.search(r'(?<![\w-])' + re.escape(task) + r'(?![\w-])', heading))
              or (role and re.search(r'\b' + re.escape(role) + r's?\b', heading, re.I))):
            relevant.append((start, end))
    # Task headings take precedence over generic role headings; uncovered
    # atomic spans prevent nested headings from copying any source twice.
    relevant.sort(key=lambda span: (task not in text[span[0]:].split('\n', 1)[0], span[0]))
    mandatory = ''.join(text[start:end] for start, end in required)
    if len(mandatory.encode('utf-8')) > DESIGN_CAP:
        raise ValueError('required design sections exceed the cap; firstmate must supply a bounded relevant design')
    selected = list(required)
    remaining = DESIGN_CAP - len(mandatory.encode('utf-8'))
    # Add task/role sections first, then the remaining source in order. Each
    # truncated span is explicitly separated so omitted text cannot join prose.
    boundaries = sorted({0, len(text)} | {x for span in required + relevant for x in span})
    uncovered = [(a, b) for a, b in zip(boundaries, boundaries[1:])
                 if not any(a >= c and b <= d for c, d in required)]
    for region_start, region_end in relevant + [(0, len(text))]:
        for start, end in list(uncovered):
            if start < region_start or end > region_end:
                continue
            uncovered.remove((start, end))
            piece = text[start:end].encode('utf-8')[:remaining].decode('utf-8', errors='ignore')
            if piece:
                selected.append((start, start + len(piece)))
                remaining -= len(piece.encode('utf-8'))
    selected.sort()
    excerpt_bytes = DESIGN_CAP - remaining
    print(f'Design cap: {DESIGN_CAP} UTF-8 bytes; source: {len(raw)} bytes; '
          f'sha256={hashlib.sha256(raw).hexdigest()}.')
    if excerpt_bytes < len(raw):
        print(f'TRIMMED: showing {excerpt_bytes} source bytes; gates and standing list '
              f'are retained whole, then task {task or "unknown"} and role {role or "unknown"} '
              'headings are prioritized. Omitted spans are marked below; coverage is incomplete.')
    print()
    cursor = 0
    for start, end in selected:
        if start > cursor:
            print('\n[TRIMMED: design span omitted]\n')
        print(text[start:end], end='')
        cursor = end
    if cursor < len(text):
        print('\n[TRIMMED: design span omitted]')
    print()


def main():
    if sys.argv[1] == 'pin':
        pin = json.load(sys.stdin)
        print('\n# Approved spec pin\n')
        fields = ('project', 'task', 'version', 'engine_commit', 'target_base_commit',
                  'source', 'approval_binding', 'contract')
        record = {key: pin.get(key) for key in fields}
        record['approval'] = {key: pin.get('approval', {}).get(key)
                              for key in ('decision', 'author', 'time', 'kind')}
        print(json.dumps(record, ensure_ascii=False, indent=2))
        print('\n# Approved design\n')
        design(pin['snapshots']['design']['text'], sys.argv[2] if len(sys.argv) > 2 else '', pin.get('task', ''))
        print('\n# Approved CONVENTIONS.md\n')
        print(pin['snapshots']['conventions']['text'])
    else:
        path = Path(sys.argv[2])
        if path.is_file():
            design(path.read_text(encoding='utf-8'), sys.argv[3] if len(sys.argv) > 3 else '',
                   sys.argv[4] if len(sys.argv) > 4 else '')
        else:
            print('Design unavailable; coverage unknown. Ask firstmate for project context.')


if __name__ == '__main__':
    try:
        main()
    except ValueError as error:
        print(f'fm-prompt-context: {error}', file=sys.stderr)
        sys.exit(65)
