#!/usr/bin/env bash
# T-036: managed-transport mid-run status goes through fm-emit.sh only.
# Pane heartbeat text is not board state until emit-status runs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "    python3 missing - herdr suite skipped"; exit 0; }
[ -f "$ROOT/bin/fm-herdr.py" ] || { echo "fm-herdr.py missing" >&2; exit 1; }

d="$(mktemp -d)"; mkdir -p "$d/bin" "$d/state"
cp "$ROOT/bin/fm-emit.sh" "$d/bin/"
cp "$ROOT/bin/fm-herdr.py" "$d/bin/"

# Heartbeat activity without claiming percent complete.
assert_ok "python3 '$d/bin/fm-herdr.py' emit-status --root '$d' \
  --actor worker-h --task T-H --role worker \
  --en 'still running' --tw '仍在跑'" \
  "herdr emit-status writes through fm-emit.sh"
assert_eq "crew_status" "$(jq -r .type "$d/state/events.jsonl")" "event type is crew_status"
assert_eq "still running" \
  "$(jq -r '.data.activity.en' "$d/state/events.jsonl")" \
  "authored en activity round-trips"
assert_eq "仍在跑" \
  "$(jq -r '.data.activity["zh-TW"]' "$d/state/events.jsonl")" \
  "authored zh-TW activity round-trips"
assert_eq "null" \
  "$(jq -c '.data.progress // null' "$d/state/events.jsonl")" \
  "heartbeat without a denominator claims no progress"

# Identical heartbeat coalesces under the throttle.
assert_ok "FM_CREW_STATUS_SECS=60 python3 '$d/bin/fm-herdr.py' emit-status --root '$d' \
  --actor worker-h --task T-H --role worker \
  --en 'still running' --tw '仍在跑'" \
  "identical heartbeat is a quiet success"
assert_eq "1" "$(wc -l < "$d/state/events.jsonl" | tr -d ' ')" \
  "identical herdr heartbeats do not flood the log"

# Bounded progress only when done/total is real.
assert_ok "python3 '$d/bin/fm-herdr.py' emit-status --root '$d' \
  --actor worker-h --task T-H --role worker \
  --en 'gates 3/7' --tw '關卡 3/7' --done 3 --total 7" \
  "herdr can attach bounded progress"
assert_eq '{"done":3,"total":7}' \
  "$(jq -c 'select(.data.progress)|.data.progress' "$d/state/events.jsonl" | tail -1)" \
  "bounded progress is on the emitted event"

# Refuse inventing percent from a half pair.
assert_fail "python3 '$d/bin/fm-herdr.py' emit-status --root '$d' \
  --actor worker-h --task T-H --en 'x' --tw 'y' --done 1" \
  "done without total is refused"
assert_fail "python3 '$d/bin/fm-herdr.py' emit-status --root '$d' \
  --actor worker-h --task T-H --en 'x' --tw 'y' --done 9 --total 3" \
  "done > total is refused"

rm -rf "$d"
finish
