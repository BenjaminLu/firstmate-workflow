#!/usr/bin/env bash
# fm-tool-retry.sh <name> -- <command...> (T-306): run a CI step, and run it
# once more only when it failed on an external browser tool error - the
# Chromium protocol error that turned main red in the design-capture step.
# A failure that also reports an assertion is never retried, nor is any
# other failure, nor a second tool error: the second attempt's exit is the
# step's. The retry is logged by the step's name, so a green step that
# needed one says so. Exit 64 on usage.
set -uo pipefail
exec </dev/null
name="${1-}"
if [ -z "$name" ] || [ "${2-}" != -- ] || [ $# -lt 3 ]; then
  echo 'usage: fm-tool-retry.sh <name> -- <command...>' >&2
  exit 64
fi
shift 2
# What the browser tool says when it, not the page under test, failed.
tool_errors='Protocol error|Target closed|Target page, context or browser has been closed|Browser has been closed|browser has disconnected'
# What a failed check says; any of these and the failure is the step's own.
assertions='AssertionError|expect\(|screenshots are missing'
log="$(mktemp "${TMPDIR:-/tmp}/fm-tool-retry.XXXXXX")" || { echo 'fm-tool-retry: mktemp failed' >&2; exit 70; }
trap 'rm -f "$log"' EXIT
attempt() {
  "$@" 2>&1 | tee "$log"
  return "${PIPESTATUS[0]}"
}
attempt "$@"; rc=$?
[ "$rc" -ne 0 ] || exit 0
if grep -Eq "$assertions" "$log" || ! grep -Eq "$tool_errors" "$log"; then
  exit "$rc"
fi
printf 'fm-tool-retry: retrying %s once after a browser tool error: %s\n' \
  "$name" "$(grep -Em1 "$tool_errors" "$log")" >&2
attempt "$@"; rc=$?
[ "$rc" -eq 0 ] || printf 'fm-tool-retry: %s failed again after its one retry (exit %s)\n' "$name" "$rc" >&2
exit "$rc"
