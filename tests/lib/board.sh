# shellcheck shell=bash
# The board's contract is HTTP, so the suite speaks HTTP. No browser download
# in CI: a headless Chromium is a minute of install to assert what curl can.
set -uo pipefail
# A live managed worker exports FM_RUN_DIR / FM_ENTRY_* / FM_WORKER_TASK_LOCK_FD
# and Herdr pane ids into this shell. Suites must not inherit them or freeze,
# identity, locks and pushes bind to the outer run instead of the fixture.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=bin/fm-config.sh
. "$ROOT/bin/fm-config.sh"   # fm_tasks_write: a fixture's tasks, one file each

command -v bun >/dev/null 2>&1 || { echo "    bun not installed - board suite skipped"; exit 0; }


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

# Both the sweep and the check read code with its comments taken off, so a
# comment that names the variable stands in for neither.
code_of() {   # code_of <file>: its code, without # comments, or // ones in TypeScript
  case "$1" in
    *.ts) sed -e 's#^[[:space:]]*//.*$##' -e 's#[[:space:]]//.*$##' "$1" ;;
    *) fm_strip_comments "$1" ;;
  esac
}
secret_of() { cat "$XDG_CONFIG_HOME/firstmate/board-$1.secret"; }
# wcurl <port> <curl args...>: curl as a script on this machine writes to that
# board, with the bearer from the secret file and the board's own Origin
wcurl() {
  local port="$1"; shift
  curl -H "Origin: http://127.0.0.1:$port" -H "Authorization: Bearer $(secret_of "$port")" "$@"
}

# Merges run in the background (T-054), so their outcome is something to wait
# for, with a bound: a helper that never finishes fails the assertion after it
# rather than hanging the suite.
wait_for() {   # wait_for <seconds> <command...>: 0 once the command succeeds, 1 at the deadline
  local end=$(( $(date +%s) + $1 )); shift
  until "$@" >/dev/null 2>&1; do
    [ "$(date +%s)" -le "$end" ] || return 1
    sleep 0.1
  done
}
# stop_pids <file>: TERM every pid listed in <file>, wait (bounded) until
# each is gone, then KILL what is not. A suite ends with nothing it
# started still running: bin/ci.sh turns a survivor red (T-151).
stop_pids() {
  local p n
  [ -f "$1" ] || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    kill -TERM "$p" 2>/dev/null || continue
    n=0
    while kill -0 "$p" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
    kill -KILL "$p" 2>/dev/null || true
  done < "$1"
}

