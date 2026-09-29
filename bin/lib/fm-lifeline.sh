#!/usr/bin/env bash
# The bash side of the one way fm starts a background process, and of the
# wake (T-151; the rule and the mechanism are in bin/lib/fm_lifeline.py).
#
#   bin/lib/fm-lifeline.sh [--session | --owner-pid <pid>] [--log <file>] -- <command> [args...]
#
# Starts <command> in the background under a keeper that ends it when its
# owner dies, and prints the keeper's pid, which lives exactly as long as
# the command. The owner is the session by default: FM_SESSION_PID, else
# the nearest ancestor that is not a shell - the harness firstmate runs in,
# not the short-lived shell that ran this line. Output goes to --log, or
# nowhere. Nothing is ever started without an owner, and there is no
# `setsid ... &` to reach for instead.
#
#   bin/lib/fm-lifeline.sh ring <root> <line>
#   bin/lib/fm-lifeline.sh await <root> <file> [seconds]
#
# The wake: `ring` rings every waiter's own doorbell under
# <root>/state/session/wake.d; `await` registers one, looks for <file>, and
# looks again on every ring until it exists (exit 0) or the seconds run out
# (exit 1). The bell is a hint; the file is the answer.
set -uo pipefail
exec < /dev/null
case "${1-}" in
  ring|await) exec python3 "$(dirname "${BASH_SOURCE[0]}")/fm_lifeline.py" "$@" ;;
esac
exec python3 "$(dirname "${BASH_SOURCE[0]}")/fm_lifeline.py" spawn "$@"
