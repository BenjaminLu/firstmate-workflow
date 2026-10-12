#!/usr/bin/env bash
# T-297: the spec preflight is removed. A spec pins and dispatches with no
# preflight record; old SPEC-OK and SPEC-GAPS receipts and an answered
# pass-budget card change nothing; the old command fails with one pointer line.
# Feature dependencies: bin/fm-worker.sh bin/fm-review.sh bin/fm-config.sh
# bin/lib/fm_spec_pins.py bin/lib/fm_spec_preflight.py bin/lib/fm_evidence.py
# Shared fixtures: tests/lib/worker.sh tests/lib/spec-preflight.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"

preflight_receipts() {  # preflight_receipts <repo>: how many spec-preflight receipts it holds
  find "$1/state/evidence" -type f -name '*.json' -exec jq -r 'select(.kind=="spec-preflight")|.kind' {} + 2>/dev/null \
    | wc -l | tr -d ' '
}
dispatch_case() {  # dispatch_case <label> <setup function>: a first round that pins and runs;
  # sets dispatched_receipts to the spec-preflight receipts before and after
  local d repo GH
  d="$(fixture)"; repo="$d/repo"; GH="$(ghstub "$d")"
  printf '%s\n' '{"type":"greenlit","actor":"captain","ts":"2026-10-03T00:00:00Z"}' > "$repo/state/events.jsonl"
  cat > "$repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
printf 'called\n' > "$FM_SEEN/called"
mkdir -p "$3/src"
printf 'implemented\n' > "$3/src/feature"
M
  chmod +x "$repo/bin/adapters/mock.sh"
  "$2" "$repo"
  receipts="$(preflight_receipts "$repo")"
  (cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-worker.sh --task T-Z) > "$d/out" 2>&1
  assert_eq 0 "$?" "$1"
  assert_ok "test -s '$d/called'" "$1: the adapter runs"
  assert_ok "test -f '$repo/state/pins/T-Z/1.json'" "$1: the spec is pinned"
  assert_eq "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$repo/design/tasks/T-Z.json")" \
    "$(jq -r .snapshots.spec.sha256 "$repo/state/pins/T-Z/1.json")" "$1: the pin holds the approved bytes"
  assert_lacks "$(cat "$d/out")" 'SPEC-OK' "$1: nothing asks for a SPEC-OK"
  dispatched_receipts="$receipts $(preflight_receipts "$repo")"
  safe_rm_rf "$d"
}

# --- dispatch: no preflight needed (fail-first) ---------------------------
none() { rm -rf "$1/state/evidence"; }  # whatever a shared fixture seeded
dispatch_case 'dispatch: no preflight needed' none
assert_eq '0 0' "$dispatched_receipts" 'dispatch: no preflight needed, and none is written'

# --- preflight: old records still accepted (regression) ------------------
# An old SPEC-OK receipt, and an answered pass-budget card (T-288) left over.
old_ok() {
  seed_spec_preflight "$1" T-Z
  mkdir -p "$1/state/preflight-budget" "$1/state/decisions"
  printf '%s\n' '{"version":1,"project":"self","task":"T-Z","cards":[{"id":"D-self-TZ-1","passes":3}]}' \
    > "$1/state/preflight-budget/T-Z.json"
  printf '%s\n' '{"id":"D-self-TZ-1","task":"T-Z","kind":"choice","chosen":"B","ts":"2026-10-03T00:00:00Z"}' \
    > "$1/state/decisions/D-self-TZ-1.json"
}
dispatch_case 'preflight: old records still accepted' old_ok
assert_eq '1 1' "$dispatched_receipts" 'the old SPEC-OK receipt stays as it was'

# --- preflight: old gaps record does not block (fail-first) --------------
old_gaps() { seed_spec_preflight "$1" T-Z '' self '' SPEC-GAPS; }
dispatch_case 'preflight: old gaps record does not block' old_gaps
assert_eq '1 1' "$dispatched_receipts" 'the old SPEC-GAPS receipt stays as it was'

# --- preflight: removed with pointer (fail-first) -------------------------
d="$(fixture)"; repo="$d/repo"
cp "$ROOT/bin/fm-review.sh" "$repo/bin/"
spec="$repo/design/tasks/T-Z.json"
printf '{}\n' > "$d/card.json"; printf '{}\n' > "$d/draft.json"
pointer="fm-review: the spec preflight is removed; the worker's first round now checks the spec"
removed() {  # removed <label> <args...>
  local label="$1"; shift
  (cd "$repo" && FM_ROOT="$repo" bin/fm-review.sh "$@") > "$d/out" 2> "$d/err"
  assert_eq 64 "$?" "$label: exits 64"
  assert_eq "$pointer" "$(cat "$d/err")" "preflight: removed with pointer ($label)"
  assert_eq '' "$(cat "$d/out")" "$label: nothing on standard output"
}
removed 'spec' --spec-preflight --task T-Z --spec "$spec"
removed 'with --card' --spec-preflight --task T-Z --spec "$spec" --card "$d/card.json"
removed 'with --pr-authoring' --spec-preflight --task T-Z --spec "$spec" --pr-authoring "$d/draft.json"
removed 'flag last' --task T-Z --card "$d/card.json" --pr-authoring "$d/draft.json" --spec "$spec" --spec-preflight
removed 'flag alone' --spec-preflight
assert_eq '' "$(find "$repo/state" -name identity.json -print)" 'the removed command allocates no crew identity'
assert_eq '' "$(find "$repo/state/evidence" -type f 2>/dev/null)" 'the removed command writes no receipt'
safe_rm_rf "$d"
finish
