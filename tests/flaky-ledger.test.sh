#!/usr/bin/env bash
# T-274: the flaky-test ledger, bin/lib/fm_flaky.py. Each named assertion is
# one test in tests/lib/flaky_ledger.py, run in its own process, with fixtures
# from tests/fixtures/flaky-ledger/.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

# A missing helper is never behavioural evidence: without it every case below
# prints a skip line and the suite exits 0, so fail-first counts none of them.

while IFS='|' read -r name label; do
  [ -n "$name" ] || continue
  if [ ! -f "$ROOT/bin/lib/fm_flaky.py" ]; then
    printf '    %-52sskip (no helper)\n' "$label"; continue
  fi
  out="$(python3 "$ROOT/tests/lib/flaky_ledger.py" "$ROOT" "$name" 2>&1)"; rc=$?
  _t "$label"; if [ "$rc" = 0 ]; then ok; else bad "$out"; fi
done <<'CASES'
test_first_hit_records_ci_time|first hit: first_seen is the hit's at, not the clock
test_line_number_and_locale_join_one_signature|line number and locale suffix join one signature
test_same_failure_is_one_hit_and_rerun_sets_only_its_flag|same run, job and attempt is one hit; --rerun sets its flag
test_later_attempt_is_a_second_hit|a later attempt of the same job is a second hit
test_other_owner_same_repository_name_is_another_flake|another owner/name with the same name stays separate
test_investigate_refuses_while_open_and_while_fix_task|investigate refuses while open and while fix-task
test_link_and_fixed_persist_task_pr_and_commit|link and fixed persist task, pull request and commit
test_show_prints_every_signature_with_count_and_status|show prints every signature with count and status
test_fixture_with_active_investigation_counts_and_refuses|fixture hits count and its open investigation refuses
test_external_project_uses_its_private_root|an external project uses its private root
test_unresolvable_external_project_writes_nothing|an unresolvable external project exits 65, writes nothing
test_unknown_fields_survive_a_rewrite|unknown fields survive a rewrite
test_hits_after_a_fix_start_a_new_cycle|after fixed --at, new hits count 1 then 2
test_same_post_fix_hit_twice_counts_once|the same post-fix hit twice keeps the count at 1
test_investigate_from_fixed_keeps_history|investigate from fixed keeps the earlier one in history
test_fixed_without_fixed_at_is_refused|fixed without fixed_at: hit, show, investigate exit 65
test_investigate_keeps_unknown_fields_of_a_none_record|investigate from none keeps the record's unknown fields
test_canonical_name_in_external_context_writes_nothing|canonical name with FM_EXTERNAL=1 and no registry: 65, writes nothing
CASES

finish
