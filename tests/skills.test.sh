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
    # SK-002: firstmate must brief every worker round with evidence, not symptoms.
    for sentence in (
        'A worker round needs a brief, not a symptom: firstmate coordinates and must hand every worker round the evidence to fix its problem, never make the worker hunt (captain, 2026-09-28).',
        'Before each round, read the failing checks\' logs and the review, open the code, and post a brief naming per item the failing assertion with its log lines, the file:line and source around it, the verified root cause, the expected change and what must not change; update a BEHIND branch first, and do not run rounds with overlapping scope in parallel.',
        'A brief that only relays symptoms ("CI is red, find out why") is not a brief: rounds with such briefs converged in ~20 minutes, rounds without took 30-70 minutes and 150-290 turns, and workers still do not run the suites.',
    ):
        if sentence not in prose:
            errors.append(f'firstmate skill lacks process rule: {sentence}')
    # SK-003: fixes to stale text found in the 2026-09-29 audit against bb8a5aa.
    for sentence in (
        'the only `gh` command firstmate runs itself is `gh pr update-branch`, and only on a pull request GitHub reports as both BEHIND and MERGEABLE (see Process rules, below).',
        'Dispatching a task is not routine: propose it and wait for the captain\'s go before dispatching (Standing orders, below).',
        'Propose a task and wait for the captain\'s go before dispatching it.',
        'A hand-raised decision id (`D-<digits>`, for the one card with no owning task) is picked from `D-1000` up, never an id below it.',
        'A task\'s `scope` lists every file its acceptance criteria need changed; sweep for one that does not before dispatch.',
        'Route no round to a vendor that is out of quota until its quota resets; T-124 will automate that check.',
        'codex is a supported vendor that was out of quota on 2026-09-27, not a banned one (captain, 2026-09-29).',
        'A merge happens only through a board card; a chat order to merge counts only inside an explicit, time-boxed authorisation the captain gives in chat, naming the card, and only one merge at a time.',
        'reconcile discrepancies explicitly. Reconnect to existing live agents and preserve interrupted work before any restart.',
        'No adapter applies `config.yaml`\'s `model:` key until T-127 merges, so report the CLI\'s own default model as the model actually in use, for every role, until then.',
        '`fm-review.sh` takes the attempt\'s own `final.txt` when Herdr recorded this run as a chain attempt, and the round\'s combined output directory and log tail otherwise (`attempt_output`, fm-review.sh:618-620), and either way that is substring matching, which does not by itself establish current-head approval.',
        'A run-mode checkout is never swept while its owner round is alive (T-123): liveness is read from a kernel `flock` the round holds on its own checkout\'s owner file, not `kill -0`, whose EPERM under the sandbox used to read a live checkout as abandoned.',
        'A round whose transcript ends with no signed verdict is retried once, automatically, with a fresh checkout, and the board says so in `en` and `zh-TW`; a second empty ending is reported as today.',
        'Since T-118, raising this card puts the task in the captain\'s lane at once - any pending card does that, not only a merge card - and it returns to ready, backlog or another lane only once the card is answered.',
        '## Author and verify captain decisions Prepare complete authored content and a bespoke before/after/options diagram',
        'The damage the board left before T-118 is repaired once, not swept for: T-118 has merged, so run `bin/fm-reconcile.sh --repair-cards --repo <root>` once (a dry run)',
        'Managed launches create a dedicated tab with one owned root pane and the same canonical actor as the tab, pane and sidebar label.',
    ):
        if sentence not in prose:
            errors.append(f'firstmate skill lacks SK-003 fix: {sentence}')
    if prose.count('Do not edit a shell script or runtime wrapper while a live process executes it.') != 1:
        errors.append('firstmate skill should carry that sentence exactly once (SK-003: duplicate removed)')
if errors:
    sys.exit('\n'.join(errors))
print('role metadata and entrypoint links: passed')
PY
