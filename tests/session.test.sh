#!/usr/bin/env bash
# T-036 session surface: heartbeat pane text is not board state until
# the managed transport emits through fm-emit.sh (see herdr.test.sh).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

# Keep this suite focused on the contract boundary; full session lifecycle
# lives with managed Herdr transport tests.
assert_ok "test -f '$ROOT/bin/fm-herdr.py'" "managed transport entrypoint is present"
assert_ok "grep -q 'crew_status' '$ROOT/bin/fm-herdr.py'" \
  "herdr mid-run status uses crew_status, not vendor-only invention"
assert_ok "grep -q 'fm-emit.sh' '$ROOT/bin/fm-herdr.py'" \
  "herdr board updates go through fm-emit.sh"
hits="$(grep -nE 'progress[[:space:]]*=[[:space:]]*[0-9]+|pct[[:space:]]*=[[:space:]]*[0-9]+' \
  "$ROOT/bin/fm-herdr.py" | grep -v '^[[:space:]]*#' || true)"
assert_eq "" "$hits" "herdr does not invent a fixed percentage"

finish
