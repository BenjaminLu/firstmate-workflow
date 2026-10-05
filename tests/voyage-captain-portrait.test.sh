#!/usr/bin/env bash
# T-215: the portrait is generated from the voyage's captain, never copied art.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
k="$(safe_tmpdir)"
trap 'safe_rm_rf "$k"' EXIT
mkdir -p "$k/games" "$k/board/public"
cp -R "$ROOT/games/voyage-2d" "$k/games/"
python3 "$k/games/voyage-2d/tools/build.py" --output "$k/playground.html"
test ! -e "$k/board/public/voyage2d/captain.webp"
python3 "$k/games/voyage-2d/tools/build.py" --live
python3 - "$k" <<'PY'
import base64, json, sys
from pathlib import Path
root = Path(sys.argv[1])
sprite = json.loads((root / 'games/voyage-2d/bake/sprites.json').read_text())['crew']['captain']['facings']['f']['whole']['img']
assert (root / 'board/public/voyage2d/captain.webp').read_bytes() == base64.b64decode(sprite.split(',', 1)[1]), 'portrait must be the baked front-facing captain'
PY
mkdir -p "$k/stubs"
printf '#!/bin/sh\nexit 1\n' > "$k/stubs/bun"
chmod +x "$k/stubs/bun"
if PATH="$k/stubs:$PATH" bash "$k/games/voyage-2d/tools/prepare-board.sh" "$k"; then
  echo 'forced failed build unexpectedly succeeded' >&2; exit 1
fi
test ! -e "$k/board/public/voyage2d/index.html"
test ! -e "$k/board/public/voyage2d/captain.webp"
