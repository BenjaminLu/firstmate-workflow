#!/usr/bin/env bash
# Feature dependencies: bin/lib/fm_spec_preflight.py bin/lib/fm_preflight_budget.py
# bin/lib/fm-spec-preflight.sh bin/lib/fm_evidence.py bin/lib/fm_ste.py bin/fm-herdr.py
# tests/lib/spec_preflight_fresh.py
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
export HERDR_ENV=0
case_py() { python3 "$ROOT/tests/lib/spec_preflight_fresh.py" "$ROOT" "$1"; }
case_py test_short_spec_passes_in_one_pass
assert_eq 0 "$?" 'preflight: short spec passes in one pass'
case_py test_re_pass_judges_new_bytes_only
assert_eq 0 "$?" 'preflight: re-pass judges new bytes only'
case_py test_refused_rewrite_reasons_still_reach_the_next_prompt
assert_eq 0 "$?" 'preflight: refused rewrite reasons reach the next prompt'
case_py test_fourth_pass_raises_budget_card
assert_eq 0 "$?" 'preflight: fourth pass raises budget card'
case_py test_custom_budget_answer_resets_the_count
assert_eq 0 "$?" 'preflight: custom budget answer resets the count'
case_py test_budget_card_failure_names_the_recovery
assert_eq 0 "$?" 'preflight: budget card failure names the recovery'
case_py test_old_receipt_still_authorizes_pin
assert_eq 0 "$?" 'preflight: old receipt still authorizes pin'
case_py test_malformed_final_line_refused
assert_eq 0 "$?" 'preflight: malformed final line refused'
case_py test_prompt_validates_before_store_and_reads_without_locks
assert_eq 0 "$?" 'preflight: prompt validates before the store and reads take no lock'
finish
