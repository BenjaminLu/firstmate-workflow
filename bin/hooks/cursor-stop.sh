#!/usr/bin/env bash
# Cursor stop hook (T-137). Cursor submits {"followup_message": ...} as the
# next user message when the hook returns it, up to the hook's loop_limit. So
# this hook parks on the arm while work is in flight and returns what woke it
# as that follow-up. A stop that is not a completed turn (the user aborted, or
# it errored) is never parked on, and a park that runs out with no event
# returns nothing: the loop limit bounds how often the session is re-entered.
set -uo pipefail
# shellcheck source=bin/hooks/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
payload="$(fm_hook_payload)"
fm_hook_active || exit 0
status="$(fm_hook_field "$payload" '.status' completed)"
[ "$status" = completed ] || exit 0
reason="$(fm_hook_park "${FM_HOOK_PARK_SECS:-3300}")"
if [ -n "$reason" ]; then
  jq -cn --arg r "$(fm_hook_wake_text "$reason")" '{followup_message:$r}'
elif [ "$(fm_inflight_count)" -gt 0 ]; then
  jq -cn --arg r "$(fm_hook_still_text)" '{followup_message:$r}'
fi
exit 0
