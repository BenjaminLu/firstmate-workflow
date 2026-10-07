#!/usr/bin/env bash
# T-243: windows and stable store cursors through the real HTTP server.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/board.sh
. "$ROOT/tests/lib/board.sh"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
d="$(safe_tmpdir)"
XDG_CONFIG_HOME="$(safe_tmpdir)"; export XDG_CONFIG_HOME
mkdir -p "$d/bin" "$d/board/public" "$d/state/decisions" "$d/design/tasks"
cp -R "$ROOT/bin/lib" "$d/bin/"
project_storage_fixture "$d/bin"
cp "$ROOT/board/server.ts" "$d/board/"
cat > "$d/config.yaml" <<'Y'
default_project: alpha
projects:
  alpha:
    repo: .
    github: example/alpha
    base: main
    required_check: ci
  beta:
    github: example/beta
    base: main
    required_check: ci
Y
project_fixture_config "$d"
beta="$(project_fixture_state "$d" beta)"
: > "$d/pids"
cleanup() { stop_pids "$d/pids"; safe_rm_rf "$(cat "$d/.fixture-fm-home")"; safe_rm_rf "$d"; safe_rm_rf "$XDG_CONFIG_HOME"; }
trap cleanup EXIT
# Literal dependency for gate 4 selection.
python3 "$ROOT/tests/lib/board_state_paging.py" seed "$d" "$beta" || exit 1
FM_ROOT="$d" FM_PORT=0 python3 "$ROOT/bin/lib/fm_lifeline.py" keep --pid "$$" --name paging-board -- \
  bun run "$d/board/server.ts" > "$d/board.log" 2>&1 < /dev/null &
pid=$!; printf '%s\n' "$pid" >> "$d/pids"
PORT="$(board_port "$d/board.log" "$pid")" || { cat "$d/board.log"; exit 1; }
python3 "$ROOT/tests/lib/board_state_paging.py" check "$d" "$beta" "$PORT"
assert_eq 0 "$?" "state windows, complete game streams, stable paging and cursor refusals"
finish
