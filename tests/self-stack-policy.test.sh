#!/usr/bin/env bash
# T-278: the self-stack-policy runtime file, its only writer (an answered
# captain card), self restacks and the transitions of work already in flight.
# Python fixture dependency: tests/lib/self_stack_policy.py
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# shellcheck source=tests/lib/binding-fixture.sh
. "$ROOT/tests/lib/binding-fixture.sh"

python3 "$ROOT/tests/lib/self_stack_policy.py" "$ROOT"
assert_eq 0 "$?" 'T-278 policy file, writer, restack and transition cases'

# Transition: a worker with an existing pull request keeps that PR's base,
# even with an overlapping self task in flight and stacking held; it never
# runs the overlap check (bin/fm-worker.sh: existing PRs own their base).
d="$(fixture T-902)"; r="$d/repo"
binding_service_fixture "$r"
printf '{"id":"T-901","depends_on":[],"scope":["src/**"],"acceptance":["x"]}\n' > "$r/design/tasks/T-901.json"
git -C "$r" add -A; git -C "$r" commit -qm 'overlap contract'
git -C "$r" checkout -qb t-901-parent
mkdir -p "$r/src"; echo parent > "$r/src/parent"
git -C "$r" add src; git -C "$r" commit -qm parent
git -C "$r" push -q origin main t-901-parent
git -C "$r" checkout -q main
printf 't-901-parent\n' > "$r/.fixture-pr-base"
{
  jq -cn '{ts:"2026-10-03T00:00:00Z",actor:"captain",type:"greenlit",task:"T-901"}'
  jq -cn '{ts:"2026-10-03T00:00:01Z",actor:"firstmate",type:"dispatched",task:"T-901"}'
  jq -cn '{ts:"2026-10-03T00:00:02Z",actor:"github",type:"pr_opened",task:"T-901",pr:1}'
} >> "$r/state/events.jsonl"
seed_self_pr_authoring "$r" T-902 self
ghstub "$d" >/dev/null
out="$(cd "$r" && GH_REPO=fixture/project FM_ROOT="$r" FM_GH="$d/stub/gh" bin/fm-worker.sh --task T-902 --pr 5 2>&1)"
printf '%s\n' "$out" > "$d/worker.out"
assert_lacks "$out" 'overlaps T-901' 'existing PR worker runs no overlap check'
assert_ok "test -f '$r/state/worktrees/T-902/src/parent'" 'existing PR worker builds on its own PR base'
cd "$ROOT" || exit 1
rm -rf "$d"
finish
