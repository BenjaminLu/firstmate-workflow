#!/usr/bin/env bash
# T-243: windows and stable store cursors through the real HTTP server.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/board.sh
. "$ROOT/tests/lib/board.sh"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
d="$(safe_tmpdir)"
XDG_CONFIG_HOME="$(safe_tmpdir)"; export XDG_CONFIG_HOME
mkdir -p "$d/bin" "$d/board/public" "$d/state/decisions" "$d/design/tasks"
cp -R "$ROOT/bin/lib" "$d/bin/"
project_storage_fixture "$d/bin"
cp "$ROOT/board/server.ts" "$d/board/"
cat > "$d/config.yaml" <<'Y'
default_project: alpha
projects:
  alpha:
    repo: .
    github: example/alpha
    base: main
    required_check: ci
  beta:
    github: example/beta
    base: main
    required_check: ci
Y
project_fixture_config "$d"
beta="$(project_fixture_state "$d" beta)"
: > "$d/pids"
cleanup() { stop_pids "$d/pids"; safe_rm_rf "$(cat "$d/.fixture-fm-home")"; safe_rm_rf "$d"; safe_rm_rf "$XDG_CONFIG_HOME"; }
trap cleanup EXIT
# Literal dependency for gate 4 selection.
python3 "$ROOT/tests/lib/board_state_paging.py" seed "$d" "$beta" || exit 1
FM_ROOT="$d" FM_PORT=0 python3 "$ROOT/bin/lib/fm_lifeline.py" keep --pid "$$" --name paging-board -- \
  bun run "$d/board/server.ts" > "$d/board.log" 2>&1 < /dev/null &
pid=$!; printf '%s\n' "$pid" >> "$d/pids"
PORT="$(board_port "$d/board.log" "$pid")" || { cat "$d/board.log"; exit 1; }
python3 "$ROOT/tests/lib/board_state_paging.py" check "$d" "$beta" "$PORT"
# Keep each acceptance claim literal and separate for fail-first attribution.
# Missing results fail too; Python prints the claim and traceback on failure.
paging_result() { cat "$d/paging-results/$1" 2>/dev/null || printf 'MISSING'; }
assert_eq PASS "$(paging_result windows_totals)" "paging: windows_totals"
assert_eq PASS "$(paging_result unsettled_responses)" "paging: unsettled_responses"
assert_eq PASS "$(paging_result newest_50_responses)" "paging: newest_50_responses"
assert_eq PASS "$(paging_result superseded_refusal)" "paging: superseded_refusal"
assert_eq PASS "$(paging_result just_merged_response)" "paging: just_merged_response"
assert_eq PASS "$(paging_result complete_handoffs)" "paging: complete_handoffs"
assert_eq PASS "$(paging_result complete_merged_outcomes)" "paging: complete_merged_outcomes"
assert_eq PASS "$(paging_result newest_200_outcomes)" "paging: newest_200_outcomes"
assert_eq PASS "$(paging_result unchanged_counts)" "paging: unchanged_counts"
assert_eq PASS "$(paging_result responses_half_size)" "paging: responses_half_size"
assert_eq PASS "$(paging_result outcomes_half_size)" "paging: outcomes_half_size"
assert_eq PASS "$(paging_result first_page_equals_recent)" "paging: first_page_equals_recent"
assert_eq PASS "$(paging_result limit_clamped)" "paging: limit_clamped"
assert_eq PASS "$(paging_result recent_cursors)" "paging: recent_cursors"
assert_eq PASS "$(paging_result pages_exactly_once)" "paging: pages_exactly_once"
assert_eq PASS "$(paging_result older_only_pr_link)" "paging: older_only_pr_link"
assert_eq PASS "$(paging_result external_append_paging)" "paging: external_append_paging"
assert_eq PASS "$(paging_result bad_cursor_400)" "paging: bad_cursor_400"
assert_eq PASS "$(paging_result stale_cursor_409)" "paging: stale_cursor_409"
assert_eq PASS "$(paging_result response_timestamp_order)" "paging: response_timestamp_order"
assert_eq PASS "$(paging_result outcome_timestamp_order)" "paging: outcome_timestamp_order"
assert_eq PASS "$(paging_result beta_windows_totals)" "paging: beta_windows_totals"
assert_eq PASS "$(paging_result response_outcome_timestamp)" "paging: response_outcome_timestamp"
assert_eq PASS "$(paging_result project_filter_before_windows)" "paging: project_filter_before_windows"
assert_eq PASS "$(paging_result folded_page_parity)" "paging: folded_page_parity"
assert_eq PASS "$(paging_result evidence_warning)" "paging: evidence_warning"
assert_eq PASS "$(paging_result lost_run_folded)" "paging: lost_run_folded"
finish
