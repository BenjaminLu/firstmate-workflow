#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/board.sh
. "$ROOT/tests/lib/board.sh"
export HERDR_ENV=0
k="$(safe_tmpdir)"
export XDG_CONFIG_HOME="$k/config"
keeper=''
cleanup() {
  if [ -n "$keeper" ]; then
    # The keeper drains its child before exiting; wait on the kernel notice.
    PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/bin/lib" "$keeper" <<'PYTHON'
import os, signal, sys
sys.path.insert(0, sys.argv[1])
from fm_lifeline import ProcessExit, OwnerGone, wait_exits
try:
    watch = ProcessExit(int(sys.argv[2]))
except (ProcessLookupError, OwnerGone):
    sys.exit(0)
try:
    os.kill(int(sys.argv[2]), signal.SIGTERM)
except ProcessLookupError:
    pass
wait_exits([watch])
PYTHON
  fi
}
trap cleanup EXIT
mkdir -p "$k/board" "$k/state/pending" "$k/design/tasks"
cp "$ROOT/board/server.ts" "$k/board/"
cp -R "$ROOT/board/public" "$k/board/public"
# Static serving is independent of the build toolchain; e2e loads the real build.
mkdir -p "$k/board/public/voyage2d"
printf '%s\n' '<!doctype html><title>Live fixture</title>' > "$k/board/public/voyage2d/index.html"
keeper="$(HERDR_ENV=0 FM_ROOT="$k" FM_PORT=0 bash "$ROOT/bin/lib/fm-lifeline.sh" --owner-pid "$$" --log "$k/board.log" -- bun run "$k/board/server.ts")"
port="$(board_port "$k/board.log" "$keeper")" || port=''
status='server did not start'; page=''; url=''
if [ -n "$port" ]; then
  url="http://127.0.0.1:$port"
  status="$(curl -s --max-time 15 -o "$k/live.html" -w '%{http_code}' "$url/voyage2d/index.html")"
  page="$(curl -sf --max-time 15 "$url/")"
fi
assert_eq 200 "$status" "voyage Live bundle is served by the real board"
assert_contains "$page" 'src="game.js"' "board page loads the voyage controller"
for locale in en zh-TW; do
  for key in voyageShow voyagePanel voyageFull voyageWorkflow voyageTitle; do
    assert_ok "jq -e --arg key '$key' '.[\$key] | type == \"string\" and length > 0' '$ROOT/i18n/ui.$locale.json'" "voyage label $key exists in $locale"
  done
done
rm "$k/board/public/voyage2d/index.html"
plain="$(curl -sf --max-time 15 "$url/")"
assert_lacks "$plain" 'src="game.js"' "missing Live bundle leaves the plain board"
assert_contains "$plain" 'id="deckwrap"' "plain board retains pending decisions"
assert_ok "git -C '$ROOT' check-ignore --no-index -q board/public/voyage2d/index.html" "generated Live bundle is gitignored"
cleanup || bad "voyage fixture teardown did not finish"
keeper=''
finish
