#!/usr/bin/env bash
# The destroy workload (T-128): proves that fm-worker.sh's mirror survives a
# round that destroys its own tree, for the self project's shape and for an
# external one cloned through fm-project.sh. Runs bin/fm-canary.sh itself,
# --sections=destroy, so this is the same code the real canary runs at the
# merge gate - not a reimplementation that could drift from it. No vendor:
# every round is the mock-hostile stand-in adapter
# (tests/fixtures/hostile-adapter/), so this spends no model call and needs
# no vendor logged in. The per-vendor probes (--sections=vendors) are
# fm-canary.sh's own province, not part of CI; this file is.
set -uo pipefail
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
export HERDR_ENV=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Feature dependencies: bin/fm-canary.sh bin/lib/fm_spec_preflight.py bin/lib/fm_evidence.py
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

t="$(safe_tmpdir)"

# This suite is not the operator: fm-canary.sh's own state (results,
# transcripts, per-round scratch) goes under this run's own safe_tmpdir, not
# the real repository's state/canary - a suite that wrote there would corrupt
# an operator's own canary history, and did (T-128 round 8 review).
canary_state="$t/canary"

out="$(cd "$ROOT" && TMPDIR="$t" FM_CANARY_STATE_DIR="$canary_state" bin/fm-canary.sh --sections=destroy 2>"$t/stderr")"; rc=$?
_t "the destroy workload exits 0: every fixture and mode restored what the round destroyed"
if [ "$rc" = 0 ]; then ok
else bad "exit $rc; stdout: $(tr '\n' ' ' <<<"$out" | cut -c1-400); stderr: $(tr '\n' ' ' < "$t/stderr" | cut -c1-400)"
fi

results="$canary_state/destroy-results.jsonl"
assert_ok "test -f '$results'" "it records one line per fixture and mode"

n="$(jq -c . < "$results" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "10" "$n" "five hostile modes, two fixtures - self and external - is ten rounds"

# The scratch stores disappear on return; the canary retains the signed records
# read back from those stores together with the exact source bytes.
python3 - "$canary_state/destroy-preflights.jsonl" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
tasks = {'T-DESTROYTREE', 'T-DESTROYGIT', 'T-DESTROYTRUNCATE',
         'T-DESTROYFILLTMP', 'T-DESTROYEMPTYVAR'}
assert len(rows) == 10, 'each of the ten worker dispatches needs fixture evidence'
assert {(r['fixture'], r['record']['task']) for r in rows} == {
    (fixture, task) for fixture in ('self', 'external') for task in tasks}
for row in rows:
    record = row['record']
    spec = row['spec_text'].encode('utf-8')
    assert record['spec_sha256'] == hashlib.sha256(spec).hexdigest(), 'exact fixture bytes'
    assert json.loads(spec)['id'] == record['task']
    assert record['kind'] == 'spec-preflight' and record['verdict'] == 'SPEC-OK'
    assert record['provenance']['canary_fixture'] is True, 'explicit fixture provenance'
    assert record['provenance']['level'] == 'legacy', 'no invented model authentication'
    assert record['signature'], 'the ordinary evidence writer signs fixture receipts'
    project = 'self' if row['fixture'] == 'self' else 'destroy-fixture'
    assert record['project'] == project
    suffix = '/evidence/' + ('self/' if project == 'self' else '') + record['task']
    assert row['evidence_directory'].endswith(suffix), 'resolved project evidence layout'
PY
assert_eq 0 "$?" "every canary dispatch retains a marked SPEC-OK bound to its exact fixture spec"

not_ok="$(jq -r 'select(.ok != true) | "\(.fixture)/\(.mode): \(.why)"' < "$results" 2>/dev/null)"
_t "every one of them says ok"
if [ -z "$not_ok" ]; then ok; else bad "$not_ok"; fi

for fixture in self external; do
  for mode in tree git truncate fill-tmp empty-var; do
    assert_eq "true" "$(jq -r --arg f "$fixture" --arg m "$mode" \
      'select(.fixture==$f and .mode==$m) | .ok' "$results" 2>/dev/null)" \
      "$fixture/$mode: fm-canary.sh reports it restored"
  done
done

for mode in tree git truncate fill-tmp empty-var; do
  assert_eq 0 "$(jq -r --arg m "$mode" 'select(.fixture=="external" and .mode==$m) | .worker_exit' "$results")" \
    "external/$mode: confirmed conventions let the worker exit zero"
done
assert_eq 5 "$(jq -s '[.[] | select(.fixture=="external" and .ok==true)] | length' "$results")"   "confirmed external conventions let every hostile round reach restoration"

# fm-canary.sh's own scratch fixtures are gone by the time it returns (it
# builds them under its own directory and removes it when done), so what
# is checked below is the durable record it wrote - destroy-results.jsonl -
# and, in it, the actual worktree_restored event each round emitted, which
# destroy_case in bin/fm-canary.sh could only have there by reading it back
# from the fixture's own event log while it still existed.
# bin/fm-emit.sh's TYPES enum has no worktree_restored type and is out of
# this task's scope to add one to, so the event rides the existing
# worker_crashed type, named precisely by .data.event_kind (bin/fm-worker.sh's
# mirror_restore).
tree_row="$(jq -c --arg f self --arg m tree 'select(.fixture==$f and .mode==$m)' "$results" 2>/dev/null)"
assert_eq "worker_crashed" "$(jq -r '.worktree_restored.type' <<<"$tree_row")" \
  "the self fixture's tree-mode round left a worktree_restored event"
assert_eq "worktree_restored" "$(jq -r '.worktree_restored.data.event_kind' <<<"$tree_row")" \
  "named precisely by its data.event_kind"
assert_ne "" "$(jq -r '.worktree_restored.actor' <<<"$tree_row")" \
  "naming the actor - the round - not just the task"
assert_eq "true" "$(jq -r '.worktree_restored.summary.en | (type == "string" and test("\\S"))' <<<"$tree_row" 2>/dev/null)" \
  "with an English summary"
assert_eq "true" "$(jq -r '.worktree_restored.summary."zh-TW" | (type == "string" and test("\\S"))' <<<"$tree_row" 2>/dev/null)" \
  "and a zh-TW one (design section 9)"

# --- the model beside the verdict (T-127) -------------------------------
# fm-canary.sh's own docstring says the per-vendor probes need real logins
# and real model calls, so they are not part of CI on their own; that does
# not excuse the model/version reporting this task adds to them from a
# test. cursor-agent is stood in for entirely - its own binary, its own
# login var - the same way tests/adapter-contract.test.sh stands in for
# every vendor's CLI, so no real network call or real login is spent. Its
# own model-list preflight (bin/adapters/cursor-agent.sh,
# fm_adapter_model_listcheck) refuses the round before fm-sandbox.sh's own
# confinement ever starts, so this needs no OS sandbox stand-in either.
vpk="$(safe_tmpdir)"
mkdir -p "$vpk/fakebin"
# cursor-agent's own CLI, stood in: --version answers plainly; --list-models
# names a catalogue without config.yaml's cursor-agent model, so its own
# preflight refuses the round before it starts, the way an operator would
# actually see it.
#
# T-146: a model is named per vendor, and this repository's config.yaml
# names none for cursor-agent (it runs on its CLI's default). So the probe
# runs from a copy of this checkout's bin/ beside a copy of its config.yaml
# that puts the worker on codex and gives cursor-agent a model of its own:
# the probe must be handed cursor-agent's model, never the worker vendor's
# (gpt-6-astra) - which the canary did while it resolved one model per role.
cat > "$vpk/fakebin/cursor-agent" <<'S'
#!/usr/bin/env bash
if [ "$1" = --version ]; then printf '1.2.3 (Cursor Agent)\n'; exit 0; fi
if [ "$1" = --list-models ]; then printf 'gpt-visor-1 - GPT Visor\n'; exit 0; fi
cat >/dev/null
printf '{"type":"result","model":"gpt-visor-1"}\n'
exit 0
S
chmod +x "$vpk/fakebin/cursor-agent"
vroot="$vpk/root"; mkdir -p "$vroot"
cp -R "$ROOT/bin" "$vroot/bin"
awk '/^vendor:/ { print "vendor: codex"; next }
     { print }
     /^models:/ { print "  cursor-agent: gpt-cursor-canary" }' "$ROOT/config.yaml" > "$vroot/config.yaml"
assert_eq "codex gpt-6-astra gpt-cursor-canary" \
  "$(cd "$vroot" && . bin/fm-config.sh && printf '%s %s %s' "$(fm_role_vendor worker config.yaml)" \
     "$(fm_cfg_in models codex config.yaml)" "$(fm_cfg_in models cursor-agent config.yaml)")" \
  "the fixture's worker runs on codex, and codex and cursor-agent each name a model"
canary_vendors="$t/canary-vendors"
vtmp="$t/canary-vendors-tmp"; mkdir -p "$vtmp"
vout="$(cd "$vroot" && TMPDIR="$vtmp" FM_CANARY_STATE_DIR="$canary_vendors" \
  FM_SANDBOX_OS=linux \
  CURSOR_API_KEY=fm-canary-test-key \
  PATH="$vpk/fakebin:$PATH" \
  bin/fm-canary.sh --sections=vendors --vendor=cursor-agent 2>"$vpk/stderr")"
vresults="$canary_vendors/results.jsonl"
assert_ok "test -f '$vresults'" "the vendor probe records one line for cursor-agent"
crow="$(jq -c 'select(.vendor=="cursor-agent")' "$vresults" 2>/dev/null)"
assert_eq "gpt-cursor-canary" "$(jq -r '.model_requested' <<<"$crow")" \
  "it records the model config.yaml asked for: cursor-agent's own, not the codex worker's (T-146)"
assert_contains "$(jq -r '.version' <<<"$crow")" "1.2.3" "and the CLI's own version"
assert_eq "refused" "$(jq -r '.outcome' <<<"$crow")" \
  "a model the CLI's own catalogue does not name refuses the round before it starts"
assert_contains "$vout" "model=gpt-cursor-canary" \
  "the verdict line beside the vendor names the model config.yaml asked for"
_t "and never the worker vendor's model, which cursor-agent would refuse"
case "$vout" in *gpt-6-astra*) bad "the verdict line names gpt-6-astra: $vout" ;; *) ok ;; esac
assert_contains "$vout" "refused: started=no" \
  "and says the round was refused, not that it merely failed"
safe_rm_rf "$vpk"

safe_rm_rf "$t"

finish
