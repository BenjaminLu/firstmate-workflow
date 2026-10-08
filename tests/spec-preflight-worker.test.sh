#!/usr/bin/env bash
# Feature dependencies: bin/fm-worker.sh bin/lib/fm_spec_preflight.py bin/lib/fm_spec_pins.py
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
d="$(fixture)"; repo="$d/repo"; GH="$(ghstub "$d")"
# This feature starts without the fixture's assumed preflight.
rm -rf "$repo/state/evidence"
printf 'vendor: mock\nproject:\n  check: true\n' > "$repo/config.yaml"
printf 'state/\n' > "$repo/.gitignore"
git -C "$repo" add config.yaml .gitignore; git -C "$repo" commit -qm contract
git -C "$repo" push -q origin main
printf '%s\n' '{"type":"greenlit","actor":"captain","ts":"2026-10-03T00:00:00Z"}' > "$repo/state/events.jsonl"
cat > "$repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
printf 'called\n' > "$FM_SEEN/called"
exit 1
M
chmod +x "$repo/bin/adapters/mock.sh"
run_worker() {
  rm -f "$d/called"
  (cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-worker.sh --task T-Z) > "$d/out" 2>&1
  worker_rc=$?
}
check_refusal_clean() {
  assert_eq 0 "$(jq -s '[.[] | select(.type=="dispatched" or .type=="commit_pushed")]|length' "$repo/state/events.jsonl")" 'refusal emits no dispatch or checkpoint'
  assert_ok "test ! -e '$repo/state/worktrees/T-Z.pid'" 'refusal publishes no worker pid'
  assert_eq '' "$(git -C "$repo" ls-remote --heads origin 't-z-*')" 'refusal pushes no task branch'
  assert_ok "test ! -d '$repo/state/worktrees/T-Z'" 'refusal creates no worktree'
  assert_eq '' "$(git -C "$repo" for-each-ref --format='%(refname)' 'refs/heads/t-z-*')" 'refusal creates no local task branch'
}
run_worker
check_refusal_clean
assert_eq 65 "$worker_rc" 'first round refuses without SPEC-OK'
assert_ok "test ! -e '$d/called'" 'missing preflight never invokes adapter'
assert_contains "$(cat "$d/out")" 'fm-review.sh --spec-preflight --task T-Z --spec' 'refusal gives repair command'
assert_ok "test ! -e '$repo/state/pins/T-Z/1.json'" 'missing preflight refuses before first pin publication'
cp "$repo/design/tasks/T-Z.json" "$d/other.json"
printf '\n' >> "$d/other.json"
seed_spec_preflight "$repo" T-Z "$d/other.json"
run_worker
assert_eq 65 "$worker_rc" 'SPEC-OK for different bytes refuses'
check_refusal_clean
assert_ok "test ! -e '$repo/state/pins/T-Z/1.json'" 'mismatched preflight refuses before first pin publication'
assert_ok "test ! -e '$d/called'" 'mismatched preflight never invokes adapter'
seed_spec_preflight "$repo" T-Z
seed_self_pr_authoring "$repo" T-Z
run_worker
assert_ok "test -s '$d/called'" 'exact spec bytes start worker adapter'
# A repin is a normal approved new snapshot, never a mutation of pin 1.
mkdir -p "$repo/state/decisions"
printf '%s\n' '{"id":"D-repin","task":"T-Z","kind":"choice","chosen":"A"}' > "$repo/state/decisions/D-repin.json"
printf '%s\n' '{"type":"decision_made","actor":"captain","task":"T-Z","ts":"2026-10-04T00:00:00Z","data":{"decision":"D-repin","chosen":"A"}}' >> "$repo/state/events.jsonl"
cp "$d/other.json" "$repo/design/tasks/T-Z.json"
# Use the existing pin API; preflight checks dispatch after repin too.
(cd "$repo" && . bin/fm-config.sh && fm_storage_init "$repo" && fm_pin create --task T-Z --decision D-repin) > "$d/repin" 2>&1
assert_eq 0 "$?" 'fixture creates an authorized repin'
# This new byte version had the other-bytes receipt; change once more for a
# fresh repin with no preflight, proving the check uses the latest snapshot.
printf '\n' >> "$repo/design/tasks/T-Z.json"
printf '%s\n' '{"id":"D-repin2","task":"T-Z","kind":"choice","chosen":"A"}' > "$repo/state/decisions/D-repin2.json"
printf '%s\n' '{"type":"decision_made","actor":"captain","task":"T-Z","ts":"2026-10-04T01:00:00Z","data":{"decision":"D-repin2","chosen":"A"}}' >> "$repo/state/events.jsonl"
(cd "$repo" && . bin/fm-config.sh && fm_storage_init "$repo" && fm_pin create --task T-Z --decision D-repin2) > "$d/repin2" 2>&1
assert_eq 0 "$?" 'fixture creates next authorized repin'
cp "$repo/state/events.jsonl" "$d/events-before-refusal"
cp "$repo/state/worktrees/T-Z.pid" "$d/pid-before-refusal"
git -C "$repo" ls-remote --heads origin > "$d/refs-before-refusal"
run_worker
assert_eq 65 "$worker_rc" 'repin without fresh SPEC-OK refuses'
assert_ok "cmp '$repo/state/events.jsonl' '$d/events-before-refusal'" 'repin refusal emits no new events'
assert_ok "cmp '$repo/state/worktrees/T-Z.pid' '$d/pid-before-refusal'" 'repin refusal leaves prior pid untouched'
assert_eq "$(cat "$d/refs-before-refusal")" "$(git -C "$repo" ls-remote --heads origin)" 'repin refusal leaves remote refs untouched'
assert_ok "test ! -e '$d/called'" 'repin cannot inherit old receipt'
seed_spec_preflight "$repo" T-Z
seed_self_pr_authoring "$repo" T-Z
run_worker
assert_ok "test -s '$d/called'" 'repin exact bytes start after fresh preflight'
rm -rf "$d"
finish
