#!/usr/bin/env bash
# T-302: put a fixture task past its plan, as firstmate does outside a round.
# A self worker's first round on a spec's bytes returns a plan and the next
# round builds only once firstmate has accepted it. A fixture round that tests
# something else (the canary's hostile rounds, sandbox, panes, publication)
# launches a build round, so its driver calls this first: it retains a plan
# report with one proof row per done line for the fixture's round and head
# through `fm_evidence report --plan`, then accepts it with no answers through
# `fm_evidence accept-plan`. Callers: bin/fm-canary.sh, tests/lib/fixture_plan.sh.
#
#   bin/lib/fm-fixture-plan.sh <code root> <repo> <task> [round] [head]
#
# The plan names the spec bytes the launcher will pin: the existing pin's, the
# snapshot fm_spec_pins.py would take now, or, with no pin to take, the
# unpinned task fm_task reads. head defaults to the repo's HEAD, the head a
# fresh branch's first round starts at. Call it right before a launch: a spec
# already past its plan is left as it is, so a later round stays a later round.
set -uo pipefail
[ $# -ge 3 ] || { echo "usage: fm-fixture-plan.sh <code root> <repo> <task> [round] [head]" >&2; exit 64; }
code="$1" repo="$2" task="$3" round="${4:-1}" head="${5:-}"
[ -n "$head" ] || head="$(git -C "$repo" rev-parse HEAD)" || exit 1
# firstmate accepts plans outside any round; a suite run inside one must not
# lend the fixture its own round
unset FM_RUN_DIR FM_ROLE FM_IN_ROUND
cd "$repo" || exit 1
# shellcheck source=bin/fm-config.sh
. "$code/bin/fm-config.sh"
fm_storage_init "$repo" || exit 65
scratch="$(mktemp -d "${TMPDIR:-/tmp}/fixture-plan.XXXXXX")" || exit 70
trap 'rm -rf "$scratch"' EXIT
fm_task "$task" "${FM_TASKS_DIR:-design/tasks}" > "$scratch/unpinned.json" 2>/dev/null || :
spec_sha="$(python3 - "$code/bin/lib" "$task" "$scratch" "$(fm_evidence_project)" <<'PY'
import hashlib, json, os, sys
from pathlib import Path
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from fm_evidence import Store
from fm_spec_pins import Pins
task, scratch = sys.argv[2], Path(sys.argv[3])
pins = Pins(os.environ, task)
try:
    pin = pins.resolve(if_present=True)
    text = (pin['snapshots'] if pin else pins.collect()[2])['spec']['text']
except (ValueError, OSError):
    text = (scratch / 'unpinned.json').read_text()
spec_sha = hashlib.sha256(text.encode('utf-8')).hexdigest()
if any(r['kind'] == 'plan-accept' and r.get('plan_spec_sha256') == spec_sha
       for r in Store(os.environ['FM_STATE_DIR'], sys.argv[4], task, external=False).records()):
    sys.exit(0)
rows = ''.join(f'| {n} | the fixture suite | this suite | the fixture builds nothing |\n'
               for n, _ in enumerate(json.loads(text).get('acceptance') or [], 1))
(scratch / 'plan.md').write_text('Files: the fixture task scope\n\n' + rows)
print(spec_sha)
PY
)" || { echo "fm-fixture-plan: the spec of $task does not read" >&2; exit 65; }
[ -n "$spec_sha" ] || exit 0
: > "$scratch/answers.md"
TASK="$task" fm_evidence report --round "$round" --actor "worker-fixture-plan" --head "$head" \
  --file "$scratch/plan.md" --plan "$spec_sha" || exit 1
TASK="$task" fm_evidence accept-plan --round "$round" --head "$head" --file "$scratch/answers.md"
