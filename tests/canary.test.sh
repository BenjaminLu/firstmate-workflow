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

safe_rm_rf "$t"

finish
