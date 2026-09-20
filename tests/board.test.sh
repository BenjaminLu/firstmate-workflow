#!/usr/bin/env bash
# The board's contract is HTTP, so the suite speaks HTTP. No browser download
# in CI: a headless Chromium is a minute of install to assert what curl can.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

command -v bun >/dev/null 2>&1 || { echo "    bun not installed - board suite skipped"; exit 0; }

d="$(mktemp -d)"; mkdir -p "$d/bin" "$d/state" "$d/design" "$d/board/public"
cp "$ROOT/bin/fm-emit.sh" "$d/bin/"
cp "$ROOT/board/server.ts" "$d/board/"
cp "$ROOT/board/public/index.html" "$d/board/public/"
cat > "$d/design/tasks.json" <<'J'
{"tasks":[{"id":"T-A","title":"first","milestone":"M0","depends_on":[]},
          {"id":"T-B","title":"second","milestone":"M0","depends_on":["T-A"]}]}
J
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor captain --type greenlit --en "go" --tw "開工" >/dev/null
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-1 --task T-A --type dispatched --en "picked up T-A" --tw "領走 T-A" >/dev/null

PORT=$(( 14000 + RANDOM % 900 ))
# detach every descriptor: ci.sh runs suites inside $(...), and a child that
# keeps stdout open holds the command substitution open with it
FM_ROOT="$d" FM_PORT="$PORT" bun run "$d/board/server.ts" > "$d/out" 2>&1 < /dev/null &
pid=$!
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORT/api/state" >/dev/null 2>&1 && break; sleep 0.25; done
trap 'kill "$pid" 2>/dev/null' EXIT

s="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_ok "[ -n '$s' ]" "the state endpoint answers"
assert_eq "true" "$(jq -r .greenlit <<<"$s")" "it reports the green light"
assert_eq "working" "$(jq -r '.tasks[]|select(.id=="T-A")|.stage' <<<"$s")" "a dispatched task reads as working"
assert_eq "queued"  "$(jq -r '.tasks[]|select(.id=="T-B")|.stage' <<<"$s")" "an untouched task reads as queued"
assert_eq "1" "$(jq -r .counts.inflight <<<"$s")" "the counts follow the log"

page="$(curl -sf "http://127.0.0.1:$PORT/")"
assert_contains "$page" "Captain" "the page is served"
assert_contains "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/../../etc/passwd")" "40" \
  "it will not serve a path climbing out of board/public"

# the stream carries the state, and a new event reaches an open stream
( sleep 1; FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor worker-1 --task T-A --type merged \
    --en "merged T-A" --tw "T-A 已合併" >/dev/null ) &
writer=$!
# --max-time bounds the read; a bare wait here would also wait on the server,
# which never exits
curl -sN --max-time 4 "http://127.0.0.1:$PORT/events" > "$d/stream" 2>/dev/null || true
wait "$writer" 2>/dev/null || true
stream="$(cat "$d/stream")"
assert_contains "$stream" "event: state" "the stream opens with the state"
assert_contains "$stream" "merged" "an event written while the stream is open reaches it"

# loopback only - on the option that binds, not on the file's prose
assert_ok "sed 's|//.*||' '$ROOT/board/server.ts' | grep -qE 'hostname:[[:space:]]*\"127\\.0\\.0\\.1\"'" \
  "the bind option is 127.0.0.1"
# strip from // onward: a trailing comment is still a comment
assert_fail "sed 's|//.*||' '$ROOT/board/server.ts' | grep -qF '0.0.0.0'" \
  "no code binds 0.0.0.0"

kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null || true
rm -rf "$d"
finish
