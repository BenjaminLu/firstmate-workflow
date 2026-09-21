#!/usr/bin/env bash
# Validate discoverable role metadata and local Markdown link structure.
set -euo pipefail
ROOT="${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
errors = []
roles = ('firstmate', 'worker', 'reviewer')
paths = [root / 'AGENTS.md', root / 'CLAUDE.md']
for role in roles:
    path = root / 'skills' / role / 'SKILL.md'
    paths.append(path)
    if not path.is_file():
        errors.append(f'missing role: {role}')
        continue
    text = path.read_text()
    front = re.match(r'\A---\n(.*?)\n---\n', text, re.S)
    fields = dict(re.findall(r'^([a-z-]+): (.+)$', front[1], re.M)) if front else {}
    if fields.get('name') != role or not fields.get('description', '').strip():
        errors.append(f'{role}: missing or inconsistent role metadata')
for path in paths:
    if not path.is_file():
        errors.append(f'missing entrypoint: {path.relative_to(root)}')
        continue
    for link in re.findall(r'\[[^\]]+\]\(([^)]+)\)', path.read_text()):
        if '://' not in link and not (path.parent / link.split('#')[0]).exists():
            errors.append(f'{path.relative_to(root)}: broken link {link}')
router = root / 'AGENTS.md'
if router.is_file():
    destinations = re.findall(r'\[[^\]]+\]\(([^)]+)\)', router.read_text())
    for role in roles:
        if f'skills/{role}/SKILL.md' not in destinations:
            errors.append(f'router has no link to {role}')
entry = root / 'CLAUDE.md'
if entry.is_file() and entry.read_text().strip() != '@AGENTS.md':
    errors.append('Claude entrypoint must import the shared router')
if errors:
    sys.exit('\n'.join(errors))
print('role metadata and entrypoint links: passed')
PY
