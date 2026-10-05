#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
# shellcheck source=tests/lib/board.sh
. "$ROOT/tests/lib/board.sh"
export HERDR_ENV=0
k="$(safe_tmpdir)"
XDG_CONFIG_HOME="$(safe_tmpdir)"; export XDG_CONFIG_HOME
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
trap 'cleanup; safe_rm_rf "$XDG_CONFIG_HOME"' EXIT
mkdir -p "$k/bin" "$k/board" "$k/state/pending" "$k/design/tasks"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$k/bin/"
project_storage_fixture "$k/bin/"
cp -R "$ROOT/bin/lib" "$k/bin/"
cp -R "$ROOT/i18n" "$k/i18n"
cp "$ROOT/board/server.ts" "$k/board/"
cp -R "$ROOT/board/public" "$k/board/public"
# Static serving is independent of the build toolchain; e2e loads the real build.
mkdir -p "$k/board/public/voyage2d"
printf '%s\n' '<!doctype html><title>Live fixture</title>' > "$k/board/public/voyage2d/index.html"
printf 'portrait fixture' > "$k/board/public/voyage2d/captain.webp"
keeper="$(HERDR_ENV=0 FM_ROOT="$k" FM_PORT=0 bash "$ROOT/bin/lib/fm-lifeline.sh" --owner-pid "$$" --log "$k/board.log" -- bun run "$k/board/server.ts")"
port="$(board_port "$k/board.log" "$keeper")" || port=''
status='server did not start'; page=''; url=''
if [ -z "$port" ]; then
  diagnostic="$(sed -n '/refused/p' "$k/board.log")"
  [ -n "$diagnostic" ] || diagnostic="$(cat "$k/board.log")"
  status="$status: ${diagnostic:-board log is empty}"
fi
if [ -n "$port" ]; then
  url="http://127.0.0.1:$port"
  status="$(curl -s --max-time 15 -o "$k/live.html" -w '%{http_code}' "$url/voyage2d/index.html")"
  page="$(curl -sf --max-time 15 "$url/")"
fi
portrait_type=''
if [ -n "$url" ]; then
  portrait_type="$(curl -sf --max-time 15 -o "$k/captain.webp" -w '%{content_type}' "$url/voyage2d/captain.webp")"
fi
assert_eq image/webp "$portrait_type" "generated captain portrait is served as WebP"
assert_eq 'portrait fixture' "$(cat "$k/captain.webp" 2>/dev/null)" "portrait bytes reach the browser"
assert_ok "git -C '$ROOT' check-ignore --no-index -q board/public/voyage2d/captain.webp" "generated captain portrait is gitignored"
assert_eq 200 "$status" "voyage Live bundle is served by the real board"
assert_contains "$page" 'src="game.js"' "board page loads the voyage controller"
for locale in en zh-TW; do
  for key in voyageShow voyagePanel voyageFull voyageWorkflow voyageTitle; do
    assert_ok "jq -e --arg key '$key' '.[\$key] | type == \"string\" and length > 0' '$ROOT/i18n/ui.$locale.json'" "voyage label $key exists in $locale"
  done
done
rm "$k/board/public/voyage2d/index.html"
plain_status="$status"; plain=''
if [ -n "$url" ]; then
  plain_status="$(curl -s --max-time 15 -o "$k/plain.html" -w '%{http_code}' "$url/")"
  plain="$(cat "$k/plain.html")"
fi
assert_eq 200 "$plain_status" "plain board is served successfully without the Live bundle"
assert_lacks "$plain" 'src="game.js"' "missing Live bundle leaves the plain board"
assert_contains "$plain" 'id="deckwrap"' "plain board retains pending decisions"
assert_ok "git -C '$ROOT' check-ignore --no-index -q board/public/voyage2d/index.html" "generated Live bundle is gitignored"
cleanup || bad "voyage fixture teardown did not finish"
keeper=''
finish
