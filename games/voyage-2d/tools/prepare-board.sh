#!/usr/bin/env bash
# Build for the board that will serve this checkout, never a frozen engine copy.
set -uo pipefail
root="${1:?board checkout required}"
if python3 "$root/games/voyage-2d/tools/build.py" --live; then
  exit 0
fi
# A failed build must not expose yesterday's bundle or partially written HTML.
rm -f "$root/board/public/voyage2d/index.html" "$root/board/public/voyage2d/captain.webp"
echo 'voyage: Live build failed; board will start without the voyage panel' >&2
exit 1
