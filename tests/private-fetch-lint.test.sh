#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
d="$(safe_tmpdir)"
trap 'safe_rm_rf "$d"' EXIT
mkdir -p "$d/bin/nested"
for file in read.py read.sh extensionless; do
  printf '%s\n' 'git rev-parse FETCH_HEAD' > "$d/bin/nested/$file"
  rc=0
  out="$(python3 "$ROOT/bin/lib/fm_ci_checks.py" private-fetch "$d" 2>&1)" || rc=$?
  # Pair status with the diagnostic: an unknown subcommand also exits 1 on base.
  assert_eq "1:bin/nested/$file:1: shared fetch pseudo-ref is forbidden" "$rc:$out" "a planted shared fetch read fails CI ($file)"
  assert_contains "$out" 'shared fetch pseudo-ref is forbidden' "the private-ref lint rejects the planted read"
  assert_contains "$out" "bin/nested/$file:1:" "the lint names the shared read"
  rm "$d/bin/nested/$file"
done
printf '%s\n' '# FETCH_HEAD is forbidden here.' 'print("safe") # FETCH_HEAD comment' > "$d/bin/nested/comment.py"
rc=0
out="$(python3 "$ROOT/bin/lib/fm_ci_checks.py" private-fetch "$d" 2>&1)" || rc=$?
assert_eq 0 "$rc" "comments can explain the old shared ref"
assert_eq '' "$out" "the private-ref lint accepts comments"
printf '%s\n' 'print("# FETCH_HEAD")' > "$d/bin/nested/comment.py"
rc=0
out="$(python3 "$ROOT/bin/lib/fm_ci_checks.py" private-fetch "$d" 2>&1)" || rc=$?
assert_eq '1:bin/nested/comment.py:1: shared fetch pseudo-ref is forbidden' "$rc:$out" "a hash inside a string is not a comment exemption"
finish
