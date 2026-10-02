#!/usr/bin/env bash
# The closed list comes from local verdict records, from the first rejection.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
fixture() {
  local d; d="$(safe_tmpdir)"; mkdir -p "$d/bin" "$d/state"
  cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-protocol.sh" "$d/bin/"
  cp -R "$ROOT/bin/lib" "$d/bin/"
  project_storage_fixture "$d/bin/"
  printf 'vendor: mock\n' > "$d/config.yaml"
  printf '%s' "$d"
}
record() { python3 "$ROOT/tests/lib/evidence.py" "$ROOT" "$1/state" T-Z "$2" "$3"; }
run() { FM_ROOT="$1" "$1/bin/fm-protocol.sh" check --task T-Z --round "${2:-1}" --repo "$1"; }
code() { run "$@" >/dev/null 2>&1; printf '%s' "$?"; }
d="$(fixture)"
assert_eq 3 "$(code "$d")" 'missing local verdict is reported without reading comments'
record "$d" reviewer-1 'REJECT:T-Z'
assert_eq 3 "$(code "$d")" 'round one rejection without a complete list is refused'
assert_contains "$(run "$d" 2>&1)" 'no complete standing list' 'the missing list is named'
rm -rf "$d"
first=$'1. open name the helper\n2. open empty case\nCRITERIA-COMPLETE:T-Z\nREJECT:T-Z'
d="$(fixture)"; record "$d" reviewer-1 "$first"
assert_eq 0 "$(code "$d")" 'a round-one complete standing list is valid without an ask'
record "$d" worker-1 $'PRIVATE_REASONING\nASK-PASS-CRITERIA:T-Z'
record "$d" firstmate 'Take both items in one pass'
assert_eq 0 "$(code "$d" 2)" 'worker notes and firstmate briefs are not verdicts'
record "$d" reviewer-1 $'1. done helper\n2. open empty case\n3. open NEW-GROUND:T-Z cache\nCRITERIA-COMPLETE:T-Z\nREJECT:T-Z'
assert_eq 0 "$(code "$d" 2)" 'numbered NEW-GROUND extends the standing list'
record "$d" reviewer-1 $'1. done helper\n2. done empty case\n3. open cache\n4. open REGRESSION:T-Z parser\nCRITERIA-COMPLETE:T-Z\nREJECT:T-Z'
assert_eq 0 "$(code "$d" 3)" 'numbered REGRESSION extends the standing list'
rm -rf "$d"
for kind in dropped unlabelled states unnumbered; do
  d="$(fixture)"; record "$d" reviewer-1 "$first"
  case "$kind" in
    dropped) next=$'1. done helper\n'; reason='dropped item 2' ;;
    unlabelled) next=$'1. done helper\n2. open empty\n3. open logging\n'; reason='new item 3' ;;
    states) next=$'1. helper\n2. empty\n'; reason='done/open' ;;
    unnumbered) next=''; reason='no complete standing list' ;;
  esac
  record "$d" reviewer-1 "${next}"$'CRITERIA-COMPLETE:T-Z\nREJECT:T-Z'
  assert_eq 3 "$(code "$d" 2)" "$kind closed-list violation is refused"
  assert_contains "$(run "$d" 2 2>&1)" "$reason" "$kind violation names its reason"
  assert_contains "$(cat "$d/state/events.jsonl")" protocol_violation "$kind is recorded on the board"
  rm -rf "$d"
done
d="$(fixture)"; record "$d" reviewer-1 "$first"
record "$d" other-reviewer 'REJECT:T-Z'
assert_eq 0 "$(FM_REVIEWER_LOGIN=reviewer-1 code "$d" 2)" 'explicit reviewer filtering applies to local verdicts'
assert_eq 3 "$(code "$d" 2)" 'without filtering the latest local rejection counts'
rm -rf "$d"
finish
