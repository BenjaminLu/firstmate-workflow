#!/usr/bin/env bash
# Codex Stop hook (T-137). Codex continues a turn when a Stop hook answers
# {"decision":"block","reason":...}, the reason being what the model reads
# next. So this hook is the wake: while work is in flight it parks on the arm,
# and answers with what woke it. If the park runs out first it answers with
# the instruction to park as a foreground call instead - unless this stop is
# already a hook's continuation (stop_hook_active), which it lets end.
set -uo pipefail
# shellcheck source=bin/hooks/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
payload="$(fm_hook_payload)"
fm_hook_active || exit 0
active="$(fm_hook_field "$payload" '.stop_hook_active' false)"
reason="$(fm_hook_park "${FM_HOOK_PARK_SECS:-3300}")"
if [ -n "$reason" ]; then
  jq -cn --arg r "$(fm_hook_wake_text "$reason")" '{decision:"block",reason:$r}'
elif [ "$(fm_inflight_count)" -gt 0 ] && [ "$active" != true ]; then
  jq -cn --arg r "$(fm_hook_still_text)" '{decision:"block",reason:$r}'
fi
exit 0
