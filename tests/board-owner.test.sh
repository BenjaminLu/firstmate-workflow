#!/usr/bin/env bash
# T-308: the board stays up for as long as the session that started it,
# under every harness. A harness may run each command under a short-lived
# helper of its own, in a process group it kills once the command returns
# (Codex's codex-linux-sandbox); a board owned by that helper died with it.
# And a harness sandbox may refuse network listeners: then start says why,
# and how to fix it, instead of failing somewhere inside the board's start.
set -uo pipefail
exec < /dev/null
# A live managed worker exports FM_* / HERDR_* into this shell; the fixture
# names its own session, never the outer run's.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

T="$(safe_tmpdir)"
harness_pid=''
cleanup() {
  # the simulated harness is this suite's own; ending it ends the board it owns
  [ -z "$harness_pid" ] || { kill -TERM "$harness_pid" 2>/dev/null; wait "$harness_pid" 2>/dev/null; }
  # and a helper that was never reaped, should the start have hung
  pkill -KILL -f "$T/harness/" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

# a free loopback port, or nothing where this machine refuses to listen
free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()' 2>/dev/null
}
answers() { curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$1/api/state"; }
wait_for() {   # wait_for <seconds> <command...>: 0 once the command succeeds, 1 at the deadline
  local end=$(( $(date +%s) + $1 )); shift
  until "$@" >/dev/null 2>&1; do
    [ "$(date +%s)" -le "$end" ] || return 1
    sleep 0.1
  done
}
gone() { ! answers "$1"; }

# --- board: a refused listener is reported ---------------------------------
# A sandbox that refuses listeners, as Python sees it: every bind is refused.
# The board's own start is a stub here, so reaching it is what fails.
r="$T/refused"; mkdir -p "$r/site"
cp -R "$ROOT/bin" "$r/bin"; cp -R "$ROOT/skills" "$r/skills"
# `exec` keeps the pid, so the frozen-entry check passes without a snapshot
# (as tests/session-startup.test.sh runs it), and the stub stands in for
# everything after the check
printf '%s\n' 'import sys' 'print("stub " + " ".join(sys.argv[1:3]))' > "$r/bin/fm-herdr.py"
cat > "$r/site/sitecustomize.py" <<'PY'
import socket
def refuse(self, *args, **kwargs):
    raise PermissionError(1, 'Operation not permitted')
socket.socket.bind = refuse
PY
port="$(free_port)"; port="${port:-47391}"
printf 'reviewer:\n  vendor: claude\n  model: claude-opus-5-5\nboard:\n  port: %s\n' "$port" > "$r/config.yaml"
mkdir -p "$r/home"
start_refused() {
  env -i PATH="$PATH" HOME="$r/home" FM_HOME="$r/home" FIRSTMATE_CI_SESSION=1 \
    ${FIRSTMATE_CI_SCOPE:+FIRSTMATE_CI_SCOPE="$FIRSTMATE_CI_SCOPE"} PYTHONPATH="$r/site" \
    bash -c 'export FM_ENTRY_PID=$$ FM_ENTRY_SCRIPT=fm-session.sh; exec "$0" "$@"' \
    "$r/bin/fm-session.sh" start --repo "$r" > "$r/out" 2> "$r/err"
}
start_refused; rc=$?
assert_eq "69" "$rc" "board: a refused listener is reported"
assert_contains "$(cat "$r/err")" "the board cannot listen on 127.0.0.1:$port (Operation not permitted)" \
  "start names the port and the reason"
assert_contains "$(cat "$r/err")" "Fix: run bin/fm-session.sh start again outside the sandbox" "start names the fix"
assert_contains "$(cat "$r/err")" "看板無法在 127.0.0.1:$port 監聽" "and says so in Chinese too"
assert_lacks "$(cat "$r/out")" "stub session start" "and starts no board it knows cannot listen"

# A board that already answers on the port needs no listener of this
# command's own: start goes on to it.
if [ -n "$(free_port)" ]; then
  python3 -c 'import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen()
open(sys.argv[2], "w").close(); time.sleep(60)' "$port" "$r/listening" &
listener=$!
wait_for 10 test -e "$r/listening"
start_refused; rc=$?
kill "$listener" 2>/dev/null; wait "$listener" 2>/dev/null
assert_eq "0" "$rc" "a board already answering is reused, not refused"
assert_contains "$(cat "$r/out")" "stub session start" "and start goes on to it"
else
  echo "    loopback listeners refused here - reuse case left to CI"
fi

# --- board: survives a harness that reaps the command group -----------------
port="$(free_port)"
bun="$(command -v bun || true)"
if [ -z "$port" ] || [ -z "$bun" ]; then
  echo "    loopback listeners or Bun unavailable - board survival left to CI"
  [ "$_fails" -eq 0 ]; exit
fi
s="$T/repo"; mkdir -p "$s" "$T/config" "$T/harness"
cp -R "$ROOT/bin" "$s/bin"; cp -R "$ROOT/board" "$s/board"; cp -R "$ROOT/i18n" "$s/i18n"
printf 'board:\n  port: %s\n' "$port" > "$s/config.yaml"
# The harness and its per-command helper are real processes with the names a
# harness's have: Bun itself, under those names, so the kernel reports them.
real_bun="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$bun")"
for name in codex codex-linux-sandbox; do
  ln "$real_bun" "$T/harness/$name" 2>/dev/null || cp "$real_bun" "$T/harness/$name"
done
# codex: runs each command in a process group of its own and kills that
# group once the command returns, then lives on, as the session does
cat > "$T/harness/codex.js" <<'JS'
const { spawn } = require("child_process");
const fs = require("fs");
const [helper, helperJs, command, reaped] = process.argv.slice(2);
const child = spawn(helper, [helperJs, command], { detached: true, stdio: ["ignore", "pipe", "inherit"] });
let out = "";
child.stdout.on("data", (data) => {
  out += data;
  if (out.includes("FM-COMMAND-RETURNED")) { try { process.kill(-child.pid, "SIGKILL"); } catch {} }
});
child.on("exit", () => fs.writeFileSync(reaped, out));
setInterval(() => {}, 1 << 30);
JS
# codex-linux-sandbox: runs the command, says it returned, and waits to be reaped
cat > "$T/harness/helper.js" <<'JS'
const { spawnSync } = require("child_process");
const result = spawnSync("bash", ["-c", process.argv[2]], { stdio: ["ignore", "inherit", "inherit"] });
process.stdout.write("\nFM-COMMAND-RETURNED " + result.status + "\n");
setInterval(() => {}, 1 << 30);
JS
# the command: the board's own start, as fm board and fm-session.sh start run
# it, with only the browser left out
cat > "$T/harness/start.py" <<'PY'
import importlib.util, json, sys
from pathlib import Path
repo = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('fm_herdr', repo / 'bin/fm-herdr.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.board_open = lambda url, port: dict(opener_invoked=False, tab=None)
print(json.dumps(m.board_start(repo)))
PY
env -u FIRSTMATE_CI_SESSION -u FM_SESSION_PID -u FM_PORT XDG_CONFIG_HOME="$T/config" \
  "$T/harness/codex" "$T/harness/codex.js" "$T/harness/codex-linux-sandbox" "$T/harness/helper.js" \
  "PATH='$PATH' '$(command -v python3)' '$T/harness/start.py' '$s'" "$T/reaped" &
harness_pid=$!
wait_for 90 test -s "$T/reaped"
record="$(sed -n 's/^\({.*}\)$/\1/p' "$T/reaped" 2>/dev/null | tail -1)"
assert_contains "$(cat "$T/reaped" 2>/dev/null)" "FM-COMMAND-RETURNED 0" "the board's start returned under the harness"
# the helper is gone with its group; the keeper has had time to act on it
sleep 2
assert_eq "$harness_pid" "$(jq -r '.owner' <<<"${record:-null}" 2>/dev/null)" "the board's owner is the harness, not its helper"
assert_ok "answers $port" "board: survives a harness that reaps the command group"
# T-151 unchanged: the board still ends with its owner
kill -TERM "$harness_pid" 2>/dev/null; wait "$harness_pid" 2>/dev/null; harness_pid=''
assert_ok "wait_for 20 gone $port" "and ends when the harness session ends"
[ "$_fails" -eq 0 ]
