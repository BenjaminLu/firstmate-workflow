#!/usr/bin/env bash
# T-036 session surface: heartbeat pane text is not board state until
# the managed transport emits through fm-emit.sh (same path as herdr.test.sh).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "    python3 missing - session suite skipped"; exit 0; }
[ -f "$ROOT/bin/fm-herdr.py" ] || { echo "fm-herdr.py missing" >&2; exit 1; }

d="$(mktemp -d)"; mkdir -p "$d/bin" "$d/state"
cp "$ROOT/bin/fm-emit.sh" "$d/bin/"
cp "$ROOT/bin/fm-herdr.py" "$d/bin/"

assert_ok "FM_CREW_STATUS_SECS=0 python3 '$d/bin/fm-herdr.py' emit-status --root '$d' \
  --actor session-h --task T-S --role worker \
  --en 'pane heartbeat' --tw '窗格心跳'" \
  "managed transport emit-status writes crew_status through fm-emit.sh"
assert_eq "crew_status" "$(jq -r .type "$d/state/events.jsonl")" "session path uses crew_status"
assert_eq "pane heartbeat" \
  "$(jq -r '.data.activity.en' "$d/state/events.jsonl")" \
  "pane text becomes board activity only after emit"
assert_eq "null" \
  "$(jq -c '.data.progress // null' "$d/state/events.jsonl")" \
  "session heartbeat without a denominator claims no progress"

rm -rf "$d"
finish
