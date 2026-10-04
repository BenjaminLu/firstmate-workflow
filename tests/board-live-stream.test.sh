#!/usr/bin/env bash
# T-168: real HTTP, quiet SSE, and deterministic replacement during a read.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/board.sh
. "$ROOT/tests/lib/board.sh"
d="$(safe_tmpdir)"
mkdir -p "$d/bin" "$d/board/public" "$d/design/tasks" "$d/state/pending" "$d/state/decisions"
# shellcheck source=tests/lib/config-modules.sh
. "$ROOT/tests/lib/config-modules.sh"
cp "$ROOT/bin/fm-config.sh" "$d/bin/"; config_modules_fixture "$d/bin/"
cp -R "$ROOT/bin/lib" "$d/bin/"
cp "$ROOT/board/server.ts" "$d/board/"
cp "$ROOT/tests/lib/board-read-race.ts" "$d/board/"
# Only replace the fs import with the fault-injection facade. All server
# logic stays byte-for-byte the source under test, including in gate 5.
python3 - "$d/board/server.ts" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); p.write_text(p.read_text().replace('from "node:fs"', 'from "./board-read-race.ts"'))
PY
printf 'vendor: codex\n' > "$d/config.yaml"
printf '{"type":"greenlit"}\n' > "$d/state/events.jsonl"
printf '{"id":"D-1","kind":"choice"}\n' > "$d/state/pending/D-1.json"
XDG_CONFIG_HOME="$(safe_tmpdir)"; export XDG_CONFIG_HOME
pid="$(FM_ROOT="$d" FM_PORT=0 "$ROOT/bin/lib/fm-lifeline.sh" --owner-pid "$$" --log "$d/out" -- bun run "$d/board/server.ts")"
printf '%s\n' "$pid" > "$d/keepers"
cleanup() { stop_pids "$d/keepers"; safe_rm_rf "$d"; safe_rm_rf "$XDG_CONFIG_HOME"; }
trap cleanup EXIT
if ! PORT="$(board_port "$d/out" "$pid")" || [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
  assert_eq "listening port" "none" "board starts before live-stream and replacement assertions"
  cat "$d/out" >&2
  finish
  exit 1
fi
# curl times out by our own deadline; an EOF or a server timeout is a failure.
curl -sN --max-time 17 "http://127.0.0.1:$PORT/events" > "$d/stream" 2> "$d/curl-error"; rc=$?
assert_eq 28 "$rc" "quiet SSE stays open beyond the old ten-second idle limit"
assert_contains "$(cat "$d/stream")" ': beat' "quiet SSE receives its fifteen-second heartbeat"
assert_contains "$(cat "$d/stream")" 'event: state' "quiet SSE sends its initial state"

python3 - "$d" "$PORT" <<'PY'
import http.client
import json
from pathlib import Path
import sys
import threading
import time
root, port = Path(sys.argv[1]), int(sys.argv[2])

def state():
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
    try:
        conn.request('GET', '/api/state')
        response = conn.getresponse()
        data = json.loads(response.read())
        assert response.status == 200 or (response.status == 503 and data.get('error')), (response.status, data)
        return response.status, data
    finally:
        conn.close()

status, original = state()
assert status == 200 and original['engine']['vendor'] == 'codex'
# The facade moves the actual file away immediately before the chosen fs
# call, restores it in finally, and records proof that the race happened.
for operation, path in [('statSync', 'config.yaml'), ('readFileSync', 'config.yaml'),
                        ('readFileSync', 'state/events.jsonl'),
                        ('readdirSync', 'state/pending'), ('readdirSync', 'state/decisions')]:
    (root / 'race.json').write_text(json.dumps({'operation': operation, 'path': str(root / path)}))
    status, data = state()
    assert not (root / 'race.json').exists(), ('race was not exercised', operation, path)
    if path == 'config.yaml':
        assert status == 200 and data['engine'] == original['engine'], 'a config replacement must retain the last good read'
    assert state()[0] == 200, ('server did not recover', operation, path)

# An initial stream read failure is a JSON response, not a broken HTTP body.
(root / 'race.json').write_text(json.dumps({'operation': 'readdirSync', 'path': str(root / 'state/pending')}))
conn = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
try:
    conn.request('GET', '/events'); response = conn.getresponse()
    assert response.status == 503 and json.loads(response.read()).get('error')
finally:
    conn.close()

# Keep a stream open while its timer encounters exactly the same failures.
# A change to events forces the timer to rebuild state for directory reads.
for operation, path in [('statSync', 'config.yaml'), ('readdirSync', 'state/pending'),
                        ('readFileSync', 'state/events.jsonl'), ('readdirSync', 'state/decisions')]:
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=20)
    try:
        conn.request('GET', '/events'); stream = conn.getresponse()
        while True:
            line = stream.readline()
            assert line, 'stream ended before its initial state'
            if line == b'\n': break
        (root / 'race.json').write_text(json.dumps({'operation': operation, 'path': str(root / path)}))
        with (root / 'state/events.jsonl').open('a') as f:
            f.write('{"type":"greenlit"}\n')
        while True:
            line = stream.readline()
            assert line, 'file replacement disconnected the SSE stream'
            if line.startswith(b': beat'):
                break
        assert not (root / 'race.json').exists(), ('timer did not exercise race', operation, path)
        assert state()[0] == 200
    finally:
        conn.close()

# Concurrent HTTP requests during real removal/restoration, with no facade.
errors = []
def replace_config():
    try:
        for _ in range(40):
            (root / 'config.yaml').rename(root / 'config.saved')
            time.sleep(.005)
            (root / 'config.saved').rename(root / 'config.yaml')
            time.sleep(.005)
    except Exception as e:
        errors.append(e)
thread = threading.Thread(target=replace_config)
thread.start()
try:
    for _ in range(40):
        state()
finally:
    thread.join()
assert not errors, errors
assert state()[0] == 200
PY
rc=$?
assert_eq 0 "$rc" "replacement races answer JSON and leave the server and SSE alive"
cleanup
trap - EXIT
finish
