#!/usr/bin/env bash
# Startup cursors and real gh exit-status semantics; no network access.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib.sh"
for case_name in \
  first_start_skips_long_history_and_persists_before_poll \
  startup_boundary_is_durable_before_any_local_read_or_poll \
  saved_zero_cursors_resume_instead_of_skipping_unread_events \
  forwarded_wake_is_not_a_decision \
  missing_logs_start_at_zero_and_accept_later_events \
  conditional_304_returns_cached_body_without_changing_failure_state \
  conditional_304_poll_uses_normal_cadence_without_backoff \
  500_backs_off_even_with_cached_body_and_zero_exit_status; do
  python3 "$ROOT/tests/lib/autopilot_startup_cache.py" "$ROOT" "StartupCache.test_$case_name"
  assert_eq 0 "$?" "autopilot startup cache: $case_name"
done
finish
