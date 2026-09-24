#!/usr/bin/env bash
# A board that can open a file on the machine it runs on is a board that has
# to be boring about which file.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
command -v bun >/dev/null 2>&1 || { echo "    bun not installed - open suite skipped"; exit 0; }

d="$(mktemp -d)"; r="$d/repo"
mkdir -p "$r/bin" "$r/state" "$r/design" "$r/board/public" "$r/src" "$d/outside"
cp "$ROOT/bin/fm-emit.sh" "$r/bin/"; cp "$ROOT/board/server.ts" "$r/board/"
cp "$ROOT/board/public/index.html" "$r/board/public/"
printf '{"tasks":[]}\n' > "$r/design/tasks.json"
# an editor that records rather than opens
printf '#!/usr/bin/env bash\necho "$*" >> "%s/opened"\n' "$d" > "$d/fake-editor"
chmod +x "$d/fake-editor"
printf 'editor: %s/fake-editor\n' "$d" > "$r/config.yaml"
echo "inside the repo" > "$r/src/visible"
echo "not yours" > "$d/outside/secret"
ln -s "$d/outside/secret" "$r/src/escape"
git init -q -b main "$r" >/dev/null 2>&1
( cd "$r" && git config user.email a@b.c && git config user.name t && git add -A >/dev/null 2>&1 && git commit -qm base >/dev/null 2>&1 )

# The kernel picks the port and the server says which one it got. A RANDOM
# range overlapped the other suites' ranges, and with the gate running suites
# side by side a readiness loop could be answered by somebody else's board.
board_port() {   # board_port <log> <pid>: the port the server printed; 1 if it died first
  local log="$1" pid="$2" end=$(( $(date +%s) + 60 )) port
  while [ "$(date +%s)" -le "$end" ]; do
    port="$(sed -n 's|^board on http://127\.0\.0\.1:\([0-9][0-9]*\).*|\1|p' "$log" 2>/dev/null | head -1)"
    [ -n "$port" ] && { printf '%s' "$port"; return 0; }
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}
FM_ROOT="$r" FM_PORT=0 bun run "$r/board/server.ts" >"$d/out" 2>&1 </dev/null &
pid=$!; trap 'kill "$pid" 2>/dev/null' EXIT
PORT="$(board_port "$d/out" "$pid")"
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORT/api/state" >/dev/null 2>&1 && break; sleep 0.25; done
u="http://127.0.0.1:$PORT"

code() { curl -s -o /dev/null -w '%{http_code}' "$1"; }

assert_eq "200" "$(code "$u/file?path=src/visible")" "a file inside the repository can be shown"
assert_contains "$(curl -s "$u/file?path=src/visible")" "inside the repo" "and it is the right file"

assert_eq "403" "$(code "$u/file?path=../outside/secret")" "a path climbing out with .. is refused"
assert_eq "403" "$(code "$u/file?path=src/escape")" "a symlink pointing out is refused"
assert_eq "403" "$(code "$u/file?path=/etc/passwd")" "an absolute path outside is refused"
assert_fail "curl -s '$u/file?path=src/escape' | grep -q 'not yours'" "and none of them leaked the contents"

assert_eq "200" "$(code "$u/open?path=src/visible")" "a file inside the repository can be opened"
# the editor is launched, not waited on, so the response beats the process
for _ in $(seq 1 40); do [ -s "$d/opened" ] && break; sleep 0.25; done
assert_contains "$(cat "$d/opened" 2>/dev/null)" "src/visible" "the editor was handed the resolved path"
assert_eq "403" "$(code "$u/open?path=../outside/secret")" "open refuses the same paths show does"
assert_eq "403" "$(code "$u/open?path=src/escape")" "including through a symlink"
sleep 1   # give any refused open the chance it will not get
assert_eq "1" "$(wc -l < "$d/opened" 2>/dev/null | tr -d ' ')" "only the legitimate path ever reached the editor"

assert_eq "400" "$(code "$u/diff?branch=main;rm%20-rf%20/")" "a branch name with a shell metacharacter is refused"
assert_eq "404" "$(code "$u/diff?branch=no-such-branch")" "an unknown branch is a 404, not a 500"

kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
rm -rf "$d"
finish
