#!/usr/bin/env bash
# T-168: dispatch exits; its session-owned worker keeps running.
set -uo pipefail
exec < /dev/null
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do unset "$_fm_k" || true; done
export HERDR_ENV=0 FM_TRANSPORT=direct
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=bin/fm-config.sh
. "$ROOT/bin/fm-config.sh"
# Run by the normal CI suite selection; comments and redirections are not
# bare background launches. The old worker start ended with a lone &.
assert_eq "" "$(fm_strip_comments "$ROOT/bin/fm-dispatch.sh" | grep -nE '(^|[^&])&[[:space:]]*$' || true)" \
  "dispatch contains no bare background start"
d="$(safe_tmpdir)"
trap 'safe_rm_rf "$d"' EXIT
mkdir -p "$d/bin" "$d/design/tasks" "$d/state"
cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-dispatch.sh" "$ROOT/bin/fm-herdr.py" "$d/bin/"
cp -R "$ROOT/bin/lib" "$d/bin/"
printf 'concurrency: 1\n' > "$d/config.yaml"
printf '{"id":"T-001","depends_on":[]}\n' > "$d/design/tasks/T-001.json"
printf '{"type":"greenlit"}\n' > "$d/state/events.jsonl"
cat > "$d/bin/fm-worker.sh" <<'WORKER'
#!/usr/bin/env bash
exec python3 -c 'import os,time; from pathlib import Path; d=Path(os.environ["FM_ROOT"]); (d/"worker.pid").write_text(str(os.getpid())); time.sleep(1); (d/"run-started").write_text("started"); time.sleep(300)'
WORKER
chmod +x "$d/bin/fm-worker.sh"
python3 - "$ROOT" "$d" <<'PY'
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
root, fixture = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location('life', root / 'bin/lib/fm_lifeline.py')
life = importlib.util.module_from_spec(spec); spec.loader.exec_module(life)
keepers = []
def stop(p):
    if p.poll() is None:
        p.terminate()
    try: p.wait(timeout=10)
    except subprocess.TimeoutExpired: p.kill(); p.wait()
def wait_file(path):
    # Bounded observation in a test, not a production process owner.
    end = time.monotonic() + 15
    while time.monotonic() < end:
        if path.exists() and path.read_text(): return path.read_text()
        time.sleep(.05)
    raise AssertionError(f'{path.name} never appeared')
try:
    owner = life.start(['sleep', '300'], owner=os.getpid()); keepers.append(owner)
    env = dict(os.environ, FM_ROOT=str(fixture), FM_SESSION_PID=str(owner.pid))
    with (fixture / 'dispatch.log').open('w') as log:
        dispatch = life.start(['bash', str(fixture / 'bin/fm-dispatch.sh'), '--repo', str(fixture), '--task', 'T-001'],
                              owner=owner.pid, env=env, stdout=log, stderr=log)
        keepers.append(dispatch)
        assert dispatch.wait(timeout=30) == 0, (fixture / 'dispatch.log').read_text()
    assert wait_file(fixture / 'run-started') == 'started', 'worker must survive dispatch exit'
    worker = int(wait_file(fixture / 'worker.pid'))
    os.kill(worker, 0)
    stop(owner)
    end = time.monotonic() + 10
    while time.monotonic() < end:
        try: os.kill(worker, 0)
        except ProcessLookupError: break
        time.sleep(.05)
    else: raise AssertionError('worker outlived its session owner')
finally:
    for p in reversed(keepers): stop(p)
PY
rc=$?
assert_eq 0 "$rc" "dispatch under lifeline starts a worker that survives dispatch and ends with its owner"
finish
