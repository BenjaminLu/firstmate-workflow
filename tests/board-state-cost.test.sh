#!/usr/bin/env bash
# T-235: real rebuilds, child invocation counts, and cache invalidation over HTTP.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/board.sh
. "$ROOT/tests/lib/board.sh"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
d="$(safe_tmpdir)"
XDG_CONFIG_HOME="$(safe_tmpdir)"; export XDG_CONFIG_HOME
mkdir -p "$d/bin" "$d/board/public" "$d/state/session/acknowledged" "$d/design/tasks" "$d/shims"
cp -R "$ROOT/bin/lib" "$d/bin/"
project_storage_fixture "$d/bin"
cp "$ROOT/board/server.ts" "$d/board/"
cat > "$d/config.yaml" <<'Y'
vendor: mock
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
mkdir -p "$(dirname "$beta")/tasks"
real_python="$(command -v python3)"; real_bash="$(command -v bash)"
export COST_ROOT="$d" COST_PYTHON="$real_python" COST_BASH="$real_bash"
cat > "$d/shims/python3" <<'S'
#!/bin/bash
printf 'python3 %s\n' "$*" >> "$COST_ROOT/calls"
case "$*" in *fm_lifeline.py\ acknowledged*)
  if [ -e "$COST_ROOT/ack-busy" ]; then cat > /dev/null; printf '{}\n'; exit 75; fi ;;
esac
exec "$COST_PYTHON" "$@"
S
cat > "$d/shims/bash" <<'S'
#!/bin/bash
printf 'bash %s\n' "$*" >> "$COST_ROOT/calls"
case "$*" in *fm_tasks*)
  if [ -e "$COST_ROOT/block" ]; then
    printf 'blocked fm_tasks\n' >> "$COST_ROOT/calls"
    read -r release < "$COST_ROOT/release"
  fi
  "$COST_BASH" "$@"; result=$?
  printf 'finished fm_tasks\n' >> "$COST_ROOT/calls"
  exit "$result" ;;
esac
exec "$COST_BASH" "$@"
S
chmod +x "$d/shims/"*
python3 - "$d" "$beta" <<'PY'
import json, sys
from pathlib import Path
root, beta = map(Path, sys.argv[1:])
for project, state, tasks in [('alpha', root/'state', root/'design/tasks'), ('beta', beta, beta.parent/'tasks')]:
    (tasks/'T-001.json').write_text(json.dumps(dict(id='T-001',title=project+' one',milestone='M1',depends_on=[])))
    with (state/'events.jsonl').open('w') as f:
        for i in range(25000):
            f.write(json.dumps(dict(type='progress', task='T-001', project=project, actor='captain', ts='2026-01-01T00:00:00Z', data={'n':i}))+'\n')
with (root/'state/session/wake.jsonl').open('w') as f:
    for i in range(200):
        f.write(json.dumps(dict(id=f'wake-{i}',woken=10))+'\n')
        (root/f'state/session/acknowledged/wake-{i}.json').write_text('{"acknowledged":10}')
PY
: > "$d/pids"
cleanup() { stop_pids "$d/pids"; safe_rm_rf "$(cat "$d/.fixture-fm-home")"; safe_rm_rf "$d"; safe_rm_rf "$XDG_CONFIG_HOME"; }
trap cleanup EXIT
start_board() {
  local tag="$1" cold="$2" budget="$3" board_root="${4:-$d}"
  local budget_env=()
  [ "$budget" = default ] || budget_env=("FM_BOARD_BUDGET_MS=$budget")
  env -u FM_BOARD_BUDGET_MS ${budget_env[@]+"${budget_env[@]}"} PATH="$d/shims:$PATH" FM_ROOT="$board_root" FM_PORT=0 FM_BOARD_COLD="$cold" \
    python3 "$ROOT/bin/lib/fm_lifeline.py" keep --pid "$$" --name "cost-$tag" -- \
    bun run "$d/board/server.ts" > "$d/$tag.log" 2>&1 < /dev/null &
  local pid=$!; printf '%s\n' "$pid" >> "$d/pids"
  board_port "$d/$tag.log" "$pid" > "$d/$tag.port"; local rc=$?
  assert_eq 0 "$rc" "$tag board starts before state assertions"
  if [ "$rc" -ne 0 ]; then cat "$d/$tag.log" >&2; finish; exit 1; fi
}
start_board cached 0 1
PORT="$(cat "$d/cached.port")"
get() { curl -sf --max-time 10 "http://127.0.0.1:$PORT/api/state${1-}"; }
wait_for 60 get; rc=$?
assert_eq 0 "$rc" "cached board answers its first 50000-event state request"
if [ "$rc" -ne 0 ]; then cat "$d/cached.log" >&2; finish; exit 1; fi
append_event() { printf '{"type":"progress","project":"alpha","task":"T-001","actor":"captain","data":{"cost":"%s"}}\n' "$1" >> "$d/state/events.jsonl"; }
: > "$d/calls"
for n in 1 2 3; do
  append_event "$n"
  get > "$d/state.json"; rc=$?
  assert_eq 0 "$rc" "real rebuild $n answers before spawn counts"
  if [ "$rc" -ne 0 ]; then finish; exit 1; fi
done
assert_eq 0 "$(grep -c 'fm_lifeline.py acknowledged' "$d/calls" || true)" "unchanged acknowledgements spawn no reader across real rebuilds"
assert_eq 0 "$(grep -c 'fm_tasks' "$d/calls" || true)" "unchanged task lists spawn no reader across real rebuilds"
assert_eq 1 "$(grep -c 'fm-board: /api/state build .* ms (events .* ms, tasks .* ms, watch .* ms, rest .* ms)' "$d/cached.log" || true)" "budget warning is emitted once within sixty seconds"
# A changed directory returns its previous answer while its sole refresh blocks.
mkfifo "$d/release"; touch "$d/block"
printf '{"id":"T-001","title":"new alpha title","depends_on":[]}\n' > "$d/design/tasks/T-001.json"
get > "$d/stale.json"
assert_eq 'alpha one' "$(jq -r '.tasks[]|select(.project=="alpha")|.title' "$d/stale.json")" "task refresh does not block the request"
assert_ok "wait_for 10 grep -q 'blocked fm_tasks' '$d/calls'" "task reader reaches the controlled FIFO"
python3 "$ROOT/bin/lib/fm_lifeline.py" keep --pid "$$" --name cost-stream -- \
  curl -sN --max-time 15 "http://127.0.0.1:$PORT/events" > "$d/stream" 2>/dev/null &
printf '%s\n' "$!" >> "$d/pids"
assert_ok "wait_for 5 grep -q 'event: state' '$d/stream'" "stream opens while task refresh is blocked"
rm "$d/block"
printf 'go\n' > "$d/release"
assert_ok "wait_for 10 grep -q 'finished fm_tasks' '$d/calls'" "released task reader finishes"
assert_ok "wait_for 2 grep -q 'new alpha title' '$d/stream'" "async replacement reaches an open stream without another write"
get > "$d/state.json"
assert_eq 'new alpha title' "$(jq -r '.tasks[]|select(.project=="alpha")|.title' "$d/state.json")" "completed refresh replaces task definitions"
# Only beaconAge derives from the clock in this fixture: seconds since the watch
# started. No live crew or card timestamps are synthesized by this fixture.
normalize() { jq -S 'del(.watch.beaconAge)' "$1"; }
start_board cold 1 100000
COLD_PORT="$(cat "$d/cold.port")"
equal_cold() {
  get > "$d/cached.json" || return 1
  curl -sf --max-time 30 "http://127.0.0.1:$COLD_PORT/api/state" > "$d/cold.json" || return 1
  normalize "$d/cached.json" > "$d/cached.norm"
  normalize "$d/cold.json" > "$d/cold.norm"
  cmp -s "$d/cached.norm" "$d/cold.norm"
}
assert_ok equal_cold "cold and cached bodies agree on 50000 events and two projects"
append_event timing
sleep 1.1
assert_ok "curl -sf --max-time 3 'http://127.0.0.1:$PORT/api/state' > '$d/timed.json'" "a real warm 50000-event rebuild answers within three seconds"
get > "$d/one.json"; get > "$d/two.json"
assert_ok "cmp -s '$d/one.json' '$d/two.json'" "unchanged requests reuse the exact body"
for n in $(seq 1 10); do append_event "append-$n"; done
assert_eq append-10 "$(get '?project=alpha' | jq -r '[.recent[]|select(.project=="alpha")][0].data.cost')" "appended events appear immediately"
assert_ok equal_cold "append results equal cold replay"
# Same inode, shorter, longer (different prefix), then equal-size replacement.
printf '{"type":"parked","task":"T-001","project":"alpha"}\n' > "$d/state/events.jsonl"
assert_ok equal_cold "truncation replaces cached events"
printf '{"type":"parked","task":"T-001","project":"alpha"}\n' > "$d/replacement"
mv "$d/replacement" "$d/state/events.jsonl"
assert_ok equal_cold "inode replacement discards parsed events"
printf '{"type":"unparked","task":"T-001","project":"alpha"}\n{"type":"progress","actor":"captain"}\n' > "$d/state/events.jsonl"
assert_ok equal_cold "longer in-place rewrite fails the prefix check"
printf '{"type":"progress","task":"T-001","project":"alpha"}\n{"type":"progress","actor":"captain"}\n' > "$d/state/events.jsonl"
assert_ok equal_cold "same-size in-place rewrite replaces cached events"
# A valid tail belongs to the response immediately, but stays buffered until
# its newline arrives; finishing or extending it must never duplicate an event.
printf '{"type":"parked","task":"T-001","project":"alpha"}' > "$d/state/events.jsonl"
assert_ok equal_cold "complete final event without newline equals cold replay"
sleep 1.1
assert_ok equal_cold "unchanged unterminated event survives a real rebuild"
mv "$d/state/events.jsonl" "$d/events.saved"
assert_ok equal_cold "missing log retains its last valid unterminated event"
mv "$d/events.saved" "$d/state/events.jsonl"
printf '\n{"type":"unparked","task":"T-001","project":"alpha"}' >> "$d/state/events.jsonl"
assert_ok equal_cold "appended unterminated event equals cold replay without duplicates"
printf '\n{"type":"progress","task":"T-001","data":{"cost":"partial' >> "$d/state/events.jsonl"
assert_ok equal_cold "incomplete final JSON is buffered without becoming an event"
printf ' completed"}}' >> "$d/state/events.jsonl"
assert_ok equal_cold "completing buffered JSON without newline equals cold replay"
printf '\n' >> "$d/state/events.jsonl"
assert_ok equal_cold "terminating buffered JSON does not duplicate its event"
printf '\ninvalid JSON\n' >> "$d/state/events.jsonl"
assert_ok equal_cold "blank and malformed final lines agree with cold replay"
# Invalid lists settle to [], and their failed read is retained until a change.
printf '{' > "$d/design/tasks/T-001.json"
get > /dev/null
empty_defs() { get | jq -e '.tasks[]|select(.project=="alpha" and .id=="T-001")|.title==null' > /dev/null; }
assert_ok 'wait_for 10 empty_defs' "a malformed task list clears the cached definitions"
assert_ok equal_cold "malformed task list agrees with cold reader"
: > "$d/calls"
for n in 1 2 3; do append_event "invalid-$n"; get > /dev/null; done
assert_eq 0 "$(grep -c 'fm_tasks' "$d/calls" || true)" "a malformed unchanged list is not respawned"
mkdir -p "$d/state/pending" "$d/state/ready" "$d/state/pins/T-001" "$d/state/skill-updates"
printf '{"id":"D-1","task":"T-001","title":"pending","kind":"choice"}\n' > "$d/state/pending/D-1.json"
assert_eq 1 "$(get | jq '.pending|length')" "a new pending card invalidates immediately"
printf '{"id":"D-1","task":"T-001","title":"rewritten","kind":"choice"}\n' > "$d/state/pending/D-1.json"
assert_eq rewritten "$(get | jq -r '.pending[0].title')" "in-place pending rewrite invalidates immediately"
printf '{"acknowledged":0}' > "$d/state/session/acknowledged/wake-0.json"
assert_eq 1 "$(get | jq .watch.waiting)" "in-place ack rewrite invalidates immediately"
printf '{"acknowledged":10}' > "$d/state/session/acknowledged/wake-0.json"
assert_eq 0 "$(get | jq .watch.waiting)" "restored ack is immediately committed"
printf '{"decision":"D-1"}' > "$d/state/ready/T-001.json"
assert_eq ready "$(get | jq -r '.tasks[]|select(.project=="alpha" and .id=="T-001")|.stage')" "readiness record invalidates the memo"
for version in 1 2; do
  jq -nc --arg title "pin $version" '{snapshots:{spec:{text:({title:$title}|tojson)}}}' > "$d/state/pins/T-001/$version.json"
  assert_eq "pin $version" "$(get | jq -r '.tasks[]|select(.project=="alpha" and .id=="T-001")|.title')" "a pin under an existing directory invalidates immediately"
done
jq -nc '{snapshots:{spec:{text:({title:"rewritten pin"}|tojson)}}}' > "$d/state/pins/T-001/2.json"
assert_eq 'rewritten pin' "$(get | jq -r '.tasks[]|select(.project=="alpha" and .id=="T-001")|.title')" "in-place pin rewrite invalidates immediately"
rm "$d/state/pins/T-001/1.json" "$d/state/pins/T-001/2.json"
printf '{"title":"proposal title"}' > "$d/state/skill-updates/T-001.json"
assert_eq 'proposal title' "$(get | jq -r '.tasks[]|select(.project=="alpha" and .id=="T-001")|.title')" "skill proposal invalidates immediately"
get > /dev/null
ln -s "$d/design" "$beta/routing-link"
assert_eq 503 "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/state")" "warm memo still validates external routing"
rm "$beta/routing-link"
assert_eq 200 "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/state")" "removing unsafe routing restores the response"
# POST writes invalidate the cached board before the next GET.
wcurl "$PORT" -sf --max-time 10 -X POST -H 'content-type: application/json' \
  -d '{"project":"beta","task":"T-001","action":"park"}' "http://127.0.0.1:$PORT/tasks" > "$d/post.json"
assert_eq true "$(jq -r .ok "$d/post.json")" "park POST succeeds"
assert_eq parked "$(get | jq -r '.tasks[]|select(.project=="beta" and .id=="T-001")|.stage')" "park POST appears on the very next read"
# A busy answer cannot become a cached acknowledgement snapshot.
: > "$d/calls"; touch "$d/ack-busy"
printf '{"acknowledged":11}' > "$d/state/session/acknowledged/wake-0.json"
assert_eq 200 "$(get | jq .watch.waiting)" "busy acknowledgement reader conservatively counts every wake"
rm "$d/ack-busy"
assert_eq 0 "$(get | jq .watch.waiting)" "the next request retries a busy acknowledgement snapshot"
assert_eq 2 "$(grep -c 'fm_lifeline.py acknowledged' "$d/calls" || true)" "busy answer is not cached"
# Hold a real FIFO reader without changing a file when it exits. A memo of watch
# would therefore remain alive; the board must probe its reader on every call.
mkdir -p "$d/state/session/wake.d" "$d/state/watch"
mkfifo "$d/state/session/wake.d/cost"
cat > "$d/watch-reader.py" <<'PYWATCH'
import os, signal, sys
from pathlib import Path
root = Path(sys.argv[1])
fd = os.open(root/'state/session/wake.d/cost', os.O_RDWR)
(root/'reader-ready').touch()
signal.pause()
PYWATCH
python3 "$ROOT/bin/lib/fm_lifeline.py" keep --pid "$$" --name cost-watch -- \
  python3 "$d/watch-reader.py" "$d" > "$d/reader.log" 2>&1 &
watch_pid=$!; printf '%s\n' "$watch_pid" >> "$d/pids"
assert_ok "wait_for 10 test -f '$d/reader-ready'" "watch reader opens its FIFO"
jq -nc --arg bell "$d/state/session/wake.d/cost" '{bell:$bell,started:"2026-01-01T00:00:00Z",gen:1}' > "$d/state/watch/owner.json"
assert_eq true "$(get | jq .watch.alive)" "watch FIFO reader is alive"
kill "$watch_pid"; wait "$watch_pid" 2>/dev/null || true
assert_eq false "$(get | jq .watch.alive)" "watch reader exit is visible on the very next read"
# CLI busy status changes, but its stdout and the library's return stay unknown.
python3 - "$d" "$real_python" <<'PYLOCK'
import fcntl, json, os, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1]); python = sys.argv[2]
sys.path.insert(0, str(root/'bin/lib'))
import fm_lifeline as life
cmd = [python, str(root/'bin/lib/fm_lifeline.py'), 'acknowledged', str(root)]
plain = subprocess.run(cmd, input='["unacknowledged"]', text=True, capture_output=True)
assert plain.returncode == 0, plain.stderr
with (root/'state/session/.ack.lock').open('a+') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    busy = subprocess.run(cmd, input='["unacknowledged"]', text=True, capture_output=True)
    assert busy.returncode == 75, (busy.returncode, busy.stderr)
    assert busy.stdout == plain.stdout
    assert life.acknowledged_many(root, ['unacknowledged'], blocking=False) == {'unacknowledged':None}
PYLOCK
assert_eq 0 "$?" "busy CLI exits 75 with unchanged stdout and library semantics"
# The same board switches default projects on the next request. The external
# reader's record_root and the registry's state directory must agree.
sed 's/default_project: alpha/default_project: beta/' "$d/config.yaml" > "$d/config.next"
mv "$d/config.next" "$d/config.yaml"
mkdir -p "$beta/session/acknowledged"
python3 - "$d" "$beta" <<'PYROOT'
import sys
from pathlib import Path
root, state = map(Path, sys.argv[1:])
sys.path.insert(0, str(root/'bin/lib'))
from fm_lifeline import record_root
assert Path(record_root(root))/'state' == state
for i in range(200):
    (state/f'session/acknowledged/wake-{i}.json').write_text('{"acknowledged":10}')
PYROOT
assert_eq 0 "$?" "external default record_root agrees with board registry storage"
assert_eq beta "$(get | jq -r .default_project)" "config edit changes the next request's default"
assert_eq 0 "$(get | jq .watch.waiting)" "external default reads its own acknowledgements"
printf '{"acknowledged":0}' > "$beta/session/acknowledged/wake-0.json"
assert_eq 1 "$(get | jq .watch.waiting)" "external acknowledgement rewrite invalidates the reader"
# A fresh small board with the documented default budget logs no slow build.
mkdir -p "$d/small-root/board/public" "$d/small-root/state"
start_board small 0 default "$d/small-root"
SMALL_PORT="$(cat "$d/small.port")"
curl -sf --max-time 30 "http://127.0.0.1:$SMALL_PORT/api/state" > /dev/null
assert_eq 0 "$?" "small board answers before checking its budget log"
assert_eq 0 "$(grep -c 'fm-board: /api/state build' "$d/small.log" || true)" "small default-budget build logs no warning"
finish
