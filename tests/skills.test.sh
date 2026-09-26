#!/usr/bin/env bash
# Validate discoverable role metadata and local Markdown link structure.
set -euo pipefail
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
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
# SK-001: the process rules learned on 2026-09-25, one sentence each.
firstmate = root / 'skills' / 'firstmate' / 'SKILL.md'
if firstmate.is_file():
    prose = ' '.join(firstmate.read_text().split())
    for sentence in (
        'Within one project, raise one merge card at a time: merging one pull request makes every other open one in that project BEHIND and voids the head its card verified.',
        'Cards of other projects are not held by it (design §15.10, point 3).',
        'Run `gh pr update-branch` before a review round, never after an `APPROVE`: a moved head restarts both checks, and T-104 lost two rounds that way.',
        'A test stub answers exactly as the vendor does, in output shape, exit code and a literal `null`, never as our own code expects.',
        'Before dispatching, sweep the spec for paths that no longer exist, such as `design/tasks.json` after T-090.',
        'Workers do not run the test suite: GitHub CI and the gates verify, and no worker acceptance says to run `ci.sh` (captain\'s rule).',
    ):
        if sentence not in prose:
            errors.append(f'firstmate skill lacks process rule: {sentence}')
if errors:
    sys.exit('\n'.join(errors))
print('role metadata and entrypoint links: passed')
PY
