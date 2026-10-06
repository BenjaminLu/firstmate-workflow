#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
d="$(safe_tmpdir)"
trap 'safe_rm_rf "$d"' EXIT
python3 "$ROOT/tests/lib/ste_cases.py" observations > "$d/observations"
assert_eq 0 "$?" 'STE observations load the production checker'
while IFS=$'\t' read -r actual name; do
  assert_eq true "$actual" "$name"
done < "$d/observations"
for mode in pass fail missing counts state control surrogate pair legacy; do
  python3 "$ROOT/tests/lib/ste_cases.py" fixture "$mode" > "$d/details.json"
  python3 "$ROOT/bin/lib/fm_ste.py" check-details "$d/details.json" > "$d/report" 2> "$d/error"
  rc=$?
  expected=64
  case "$mode" in pass|legacy) expected=0;; fail) expected=65;; esac
  assert_eq "$expected" "$rc" "check-details exit: $mode"
  case "$mode" in
    pass) assert_eq true "$(jq -r '.intent_card and .ok' "$d/report")" 'passing report';;
    fail) assert_contains "$(cat "$d/error")" 'en intent: Ensure the check passes. -> R6 Ensure -> make sure' 'sentence diagnostic';;
    legacy) assert_eq '{"intent_card":false}' "$(jq -c . "$d/report")" 'legacy bypass report';;
  esac
done
# T-228: malformed authoring is a shape error, before the STE prose report.
for mode in align-missing align-zh merge-full merge-label merge-missing legacy no-done; do
  python3 "$ROOT/tests/lib/ste_cases.py" fixture "$mode" > "$d/details.json"
  kind_args=()
  case "$mode" in
    merge-full|merge-label|legacy) kind_args=(--kind merge);;
    merge-missing) kind_args=(--kind merge-untracked);;
  esac
  python3 "$ROOT/bin/lib/fm_ste.py" check-details ${kind_args[@]+"${kind_args[@]}"} "$d/details.json" > "$d/report" 2> "$d/error"
  rc=$?
  expected=64
  case "$mode" in align-zh|merge-full|legacy) expected=0;; esac
  assert_eq "$expected" "$rc" "card authoring exit: $mode"
  case "$mode" in
    align-missing)
      assert_contains "$(cat "$d/error")" 'en.done' 'alignment names locale and field'
      assert_contains "$(cat "$d/error")" 'Intent 2' 'alignment names missing intent';;
    align-zh|merge-full)
      assert_eq true "$(jq -r '.intent_card and .ok' "$d/report")" "valid authored card: $mode";;
    merge-label) assert_contains "$(cat "$d/error")" 'zh-TW.title' 'merge label names locale';;
    merge-missing)
      assert_contains "$(cat "$d/error")" 'en.change_table' 'merge requires the full field set'
      python3 "$ROOT/bin/lib/fm_ste.py" check-details "$d/details.json" > "$d/report" 2> "$d/error"
      assert_eq 0 "$?" 'choice allows omitted change table'
      assert_eq true "$(jq -r '.intent_card and .ok' "$d/report")" 'choice still checks prose';;
    legacy) assert_eq '{"intent_card":false}' "$(jq -c . "$d/report")" 'legacy merge bypass report';;
    no-done) assert_contains "$(cat "$d/error")" 'en.done: required on an intent card' 'intent cards require done';;
  esac
done
python3 "$ROOT/bin/lib/fm_ste.py" check-details --kind > "$d/report" 2> "$d/error"
assert_eq 64 "$?" 'kind requires a value and file'
assert_contains "$(cat "$d/error")" 'check-details [--kind <kind>] <file>' 'usage shows optional kind'
python3 "$ROOT/bin/lib/fm_ste.py" rules > "$d/rules"
assert_eq 0 "$?" 'rules CLI succeeds'
for id in R{1..10} Z{1..8}; do
  assert_eq true "$(jq --arg id "$id" 'any(.rules[]; .id == $id and (.text.en|length>0) and (.text["zh-TW"]|length>0))' "$d/rules")" "bilingual rule $id"
done
finish
