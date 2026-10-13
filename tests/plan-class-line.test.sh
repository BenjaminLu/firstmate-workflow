#!/usr/bin/env bash
# T-304: the class-list check reads a found-and-fixed line with detail in it,
# between and after the numbers. A block still needs a searched: line and both
# numbers, and fixed is never more than found.
# Feature dependencies: bin/lib/fm_plan.py bin/lib/fm_evidence.py
# Shared fixtures: tests/lib.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
isolate_tmpdir
d="$(safe_tmpdir)"
check() {   # check <found-and-fixed line> [searched line]: the check's exit status
  printf 'Built.\n\nSWEPT:T-Z the class\n%s\n  %s\n' "${2-  searched: grep -n x src/}" "$1" > "$d/note"
  python3 "$ROOT/bin/lib/fm_plan.py" check-class --task T-Z --file "$d/note" > "$d/out" 2>&1
  echo $?
}

# --- plan: class line with detail -----------------------------------------
# Fail-first: main reads only 'found N, fixed M' with the numbers back to back.
assert_eq 0 "$(check 'found 2 (the merge card), fixed 2')" 'plan: class line with detail'
assert_eq 0 "$(check 'found 1, fixed 1 (tests/lib.sh)')" 'detail after the numbers passes'
assert_eq 0 "$(check 'found 3 (two in bin/, one in tests/), fixed 3 (all three)')" 'detail in both places passes'
assert_eq 0 "$(check 'found 2, fixed 2')" 'the plain line still passes'
assert_eq 65 "$(check 'found some, fixed all')" 'a block without numbers is still refused'
assert_contains "$(cat "$d/out")" 'no complete SWEPT:T-Z block' 'the refusal names the incomplete block'
assert_eq 65 "$(check 'found 2 (the merge card)')" 'a block with only one number is refused'
assert_eq 65 "$(check 'found 2, fixed 2' '  looked around')" 'a block without a searched: line is refused'
assert_eq 65 "$(check 'found 2 (the merge card), fixed 3')" 'fixed more than found is refused'
assert_contains "$(cat "$d/out")" 'fixed 3 but found 2' 'the refusal says which numbers'
# Every block is read: one good block does not carry a bad one.
printf 'SWEPT:T-Z a\n  searched: ls\n  found 1, fixed 1\nSWEPT:T-Z b\n  searched: ls\n  found 1 (x), fixed 2\n' > "$d/note"
assert_fail "python3 '$ROOT/bin/lib/fm_plan.py' check-class --task T-Z --file '$d/note'" 'a later bad block is refused'
safe_rm_rf "$d"
finish
