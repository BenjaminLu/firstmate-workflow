#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/review.sh
. "$ROOT/tests/lib/review.sh"
for mode in normal preflight; do
  d="$(fixture)"; r="$d/repo"; gh="$(ghstub "$d")"
  args=(--branch work)
  [ "$mode" != preflight ] || args=(--spec-preflight)
  out="$(cd "$r" && FM_ROOT="$r" FM_GH="$gh" FM_SESSION_PID=abc bin/fm-review.sh --task T-Z "${args[@]}" 2>&1)"; rc=$?
  assert_eq 75 "$rc" "$mode malformed owner exits 75"
  assert_contains "$out" 'no session owns this review' "$mode explains ownership refusal"
  assert_eq '' "$(find "$r/state" -name identity.json -print)" "$mode refuses before identity allocation"
  safe_rm_rf "$d"
done

d="$(fixture)"; r="$d/repo"; gh="$(ghstub "$d")"
cat > "$r/bin/adapters/mock.sh" <<'SH'
#!/usr/bin/env bash
printf '%s' "$FM_SESSION_PID" > "$FM_SEEN/owner"
printf 'APPROVE:T-Z\n' > "$3/verdict.txt"
SH
chmod +x "$r/bin/adapters/mock.sh"
# The sleeper is started under a lifeline owned by this test and explicitly ended.
python3 - "$ROOT" "$d" "$gh" <<'PY'
import os, select, subprocess, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1])/'bin/lib'))
import fm_lifeline
root, home = map(Path, sys.argv[1:3])
ready = home/'owner-ready'
os.mkfifo(ready)
owner = fm_lifeline.start(['bash', '-c', 'echo "$$" > "$1"; exec sleep 300', '_', str(ready)], owner=os.getpid())
try:
    fd = os.open(ready, os.O_RDWR | os.O_NONBLOCK)
    try:
        assert select.select([fd], [], [], 5)[0], 'session sleeper did not start'
        sleeper = int(os.read(fd, 100))
    finally:
        os.close(fd)
    env = dict(os.environ, FIRSTMATE_CI_SESSION=str(sleeper), FM_ROOT=str(home/'repo'), FM_SEEN=str(home), FM_GH=sys.argv[3])
    env.pop('FM_SESSION_PID', None)
    result = subprocess.run([str(home/'repo/bin/fm-review.sh'), '--task', 'T-Z', '--branch', 'work'], cwd=home/'repo', env=env, text=True, capture_output=True, timeout=90)
    assert result.returncode == 0, result.stdout + result.stderr
    assert (home/'owner').read_text() == str(sleeper), 'adapter must see owner pinned at review start'
finally:
    owner.terminate()
    owner.wait(timeout=10)
PY
assert_eq 0 "$?" 'review pins the CI session owner for the managed adapter'
finish
