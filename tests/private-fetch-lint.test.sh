#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/ci.sh"
d="$(fixture)"
trap 'safe_rm_rf "$d"' EXIT
cp "$ROOT/bin/ci.sh" "$ROOT/bin/fm-config.sh" "$d/bin/"
mkdir -p "$d/bin/nested"
for file in read.py read.sh extensionless; do
  printf '%s\n' 'git rev-parse FETCH_HEAD' > "$d/bin/nested/$file"
  rc=0
  out="$(FM_ROOT="$d" bash "$d/bin/ci.sh" --stage fast 2>&1)" || rc=$?
  assert_eq 1 "$rc" "a planted shared fetch read fails CI ($file)"
  assert_contains "$out" 'x private fetch refs' "the private-ref lint rejects the planted read"
  assert_contains "$out" "bin/nested/$file:1:" "the lint names the shared read"
  rm "$d/bin/nested/$file"
done
printf '%s\n' '# FETCH_HEAD is forbidden here.' 'print("safe") # FETCH_HEAD comment' > "$d/bin/nested/comment.py"
rc=0
out="$(FM_ROOT="$d" bash "$d/bin/ci.sh" --stage fast 2>&1)" || rc=$?
assert_eq 0 "$rc" "comments can explain the old shared ref"
assert_contains "$out" '+ private fetch refs' "the private-ref lint accepts comments"
printf '%s\n' 'print("# FETCH_HEAD")' > "$d/bin/nested/comment.py"
out="$(FM_ROOT="$d" bash "$d/bin/ci.sh" --stage fast 2>&1)"
assert_contains "$out" 'x private fetch refs' "a hash inside a string is not a comment exemption"
finish
