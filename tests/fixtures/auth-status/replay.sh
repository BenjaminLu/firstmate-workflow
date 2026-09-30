#!/usr/bin/env bash
# Answers as a vendor's CLI did in one recorded transcript (T-121), so a stub
# status check says exactly what the real one said, never words a test made
# up. Each fixture beside this file is a header of "# key: value" lines -
# the command, the CLI version, the date, how it was recorded, the exit
# code - then the CLI's answer, verbatim but for what the header says was
# redacted.
#
#   replay.sh <fixture>             the answer, and the recorded exit code
#   replay.sh <fixture> --version   the recorded CLI version line
set -u
f="${1:?usage: replay.sh <fixture> [--version]}"
[ -r "$f" ] || { echo "replay.sh: no fixture at $f" >&2; exit 70; }
if [ "${2:-}" = --version ]; then
  sed -n 's/^# cli: //p' "$f"
  exit 0
fi
grep -v '^#' "$f"
exit "$(sed -n 's/^# exit: //p' "$f")"
