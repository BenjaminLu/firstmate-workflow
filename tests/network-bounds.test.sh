#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
isolate_tmpdir
d="$(safe_tmpdir)"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
git init -q "$d/repo"
cd "$d/repo" || exit 1
unset FM_SSH_GENERATED_COMMAND GIT_SSH_COMMAND GIT_SSH GIT_HTTP_LOW_SPEED_LIMIT GIT_HTTP_LOW_SPEED_TIME
# shellcheck source=bin/fm-config.sh
. "$ROOT/bin/fm-config.sh"
opts='-o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4'
assert_eq "$FM_SSH_GENERATED_COMMAND" "$GIT_SSH_COMMAND" 'default ssh is lazy and owned'
assert_eq 1000 "${GIT_HTTP_LOW_SPEED_LIMIT:-}" 'https minimum speed default'
assert_eq 60 "${GIT_HTTP_LOW_SPEED_TIME:-}" 'https stall duration default'
assert_eq '1000|60' "$(bash -c 'printf "%s|%s" "${GIT_HTTP_LOW_SPEED_LIMIT:-}" "${GIT_HTTP_LOW_SPEED_TIME:-}"')" 'https defaults are exported to child commands'
assert_eq 'custom -o ServerAliveInterval=9|7|8' "$(
  export GIT_SSH_COMMAND='custom -o ServerAliveInterval=9' GIT_HTTP_LOW_SPEED_LIMIT=7 GIT_HTTP_LOW_SPEED_TIME=8
  . "$ROOT/bin/fm-config.sh"
  printf '%s|%s|%s' "$GIT_SSH_COMMAND" "$GIT_HTTP_LOW_SPEED_LIMIT" "$GIT_HTTP_LOW_SPEED_TIME"
)" 'explicit keepalive and https settings survive'
assert_eq "foo $opts" "$(export GIT_SSH_COMMAND=foo; . "$ROOT/bin/fm-config.sh"; printf '%s' "$GIT_SSH_COMMAND")" 'custom ssh gains bounds'
git -C "$d/repo" config core.sshCommand 'ssh -i /tmp/key'

assert_eq unset "$(unset GIT_SSH_COMMAND; export GIT_SSH=custom; . "$ROOT/bin/fm-config.sh"; printf '%s' "${GIT_SSH_COMMAND-unset}")" 'GIT_SSH executable is left alone'
mkdir "$d/tools"
cat > "$d/tools/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NET_DIR/ssh-args"
exit 255
SH
chmod +x "$d/tools/ssh"
export NET_DIR="$d"
PATH="$d/tools:$PATH" fm_git_transfer git ls-remote ssh://git@example.invalid/repo >/dev/null 2>&1
assert_contains "$(cat "$d/ssh-args")" "-i /tmp/key $opts" 'actual transfer preserves repository identity and timeout options'
cat > "$d/gh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$NET_DIR/calls"
[ "${NET_EXIT:-}" != 1 ] || exit 1
printf '%s' "${NET_PART:-}"
sleep 30
SH
chmod +x "$d/gh"
export FM_GH="$d/gh" FM_GH_TIMEOUT=1 FM_GH_RETRY_DELAYS='0 0' FM_EXTERNAL=0
unset GH
# Fail promptly on base: later cases require the newly introduced runner.
if ! declare -F fm_with_timeout >/dev/null; then
  assert_eq present missing 'bounded executable runner exists'
  cd "$ROOT" || exit 1
  finish
  exit 1
fi
# No timeout failure may keep a descendant holding command-substitution stdout.
for scenario in read write download field partial direct explicit_get non_get; do
  : > "$d/calls"; export NET_PART=''
  expected=1
  case "$scenario" in
    read) args=(pr view 9 --json isDraft); expected=3 ;;
    write) args=(pr comment 9 --body x) ;;
    download) args=(run download 1 -n x -D d) ;;
    field) args=(api repos/o/r/issues/1/comments -f body=x) ;;
    partial) args=(pr view 9); expected=3; export NET_PART=part ;;
    direct) args=(api repos/o/r/commits/x/check-runs); expected=3 ;;
    explicit_get) args=(api repos/o/r/issues -F page=1 --method=GET); expected=3 ;;
    non_get) args=(api repos/o/r/issues -XPOST) ;;
  esac
  start=$SECONDS
  if [ "$scenario" = direct ]; then out="$(fm_gh_read "$FM_GH" "${args[@]}")"; rc=$?
  else out="$(fm_github "${args[@]}")"; rc=$?; fi
  assert_eq 124 "$rc" "$scenario timeout returns 124"
  assert_eq "$expected" "$(wc -l < "$d/calls" | tr -d ' ')" "$scenario attempts are bounded"
  assert_ok "test $((SECONDS-start)) -lt 30" "$scenario captured call returns before child sleep"
  assert_eq "$NET_PART" "$out" "$scenario prints only the final attempt"
  while read -r pgid; do
    live="$(ps -eo pgid=,stat=,args= | awk -v g="$pgid" '$1 == g && $2 !~ /^Z/ {print}')"
    assert_eq '' "$live" "$scenario leaves no live child in gh group"
  done < "$d/calls"
done
: > "$d/calls"
out="$(NET_EXIT=1 fm_github pr view 9)"; rc=$?
assert_eq 1 "$rc" 'not-found exit is unchanged'
assert_eq 1 "$(wc -l < "$d/calls" | tr -d ' ')" 'not-found is never retried'

cat > "$d/exit-gh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  signal) kill -TERM "$$" ;;
  *) exit "$1" ;;
esac
SH
chmod +x "$d/exit-gh"
fm_with_timeout 1 "$d/exit-gh" 8; rc=$?
assert_eq 8 "$rc" 'runner preserves executable exit status'
fm_with_timeout 1 "$d/exit-gh" signal; rc=$?
assert_eq 143 "$rc" 'runner maps signal death to 128 plus signal'
fm_with_timeout 1 "$d/no-such-command" 2>/dev/null; rc=$?
assert_eq 127 "$rc" 'unexecutable command returns 127'
for flag in -f -F --field --raw-field --input; do
  fm_gh_is_read api repos/o/r/issues "$flag" payload; rc=$?
  assert_eq 1 "$rc" "$flag implies a write"
  fm_gh_is_read api repos/o/r/issues "$flag" payload -X GET; rc=$?
  assert_eq 0 "$rc" "explicit GET overrides $flag"
done
for flag in --field=x --raw-field=x --input=x -fbody=x -Fbody=x; do
  fm_gh_is_read api repos/o/r/issues "$flag"; rc=$?
  assert_eq 1 "$rc" "$flag attached value implies a write"
done

# Use the lifeline to own the signal-test launcher; the FIFO pushes readiness.
python3 - "$ROOT" "$d" <<'PY'
import os, signal, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1])/'bin/lib'))
import fm_lifeline
root, home = map(Path, sys.argv[1:])
fifo = home/'ready'
os.mkfifo(fifo)
stub = home/'term-gh'
# The foreground sleep shim announces its own start, then becomes sleep.
# This proves TERM cleans a descendant, not just an as-yet childless shell.
import shlex, shutil
sleep_dir = home/'sleep-tools'
sleep_dir.mkdir()
sleep_stub = sleep_dir/'sleep'
sleep_stub.write_text('#!/bin/bash\necho "$$ $TIMEOUT_GROUP $TIMEOUT_RUNNER" > "$NET_DIR/ready"\nexec ' + shlex.quote(shutil.which('sleep')) + ' "$@"\n')
sleep_stub.chmod(0o755)
stub.write_text('#!/bin/bash\nexport TIMEOUT_RUNNER=$PPID TIMEOUT_GROUP=$$\nPATH="$NET_DIR/sleep-tools:$PATH" sleep 30\n')
stub.chmod(0o755)
proc = fm_lifeline.start(['bash', '-c', '. "$1/bin/fm-config.sh"; fm_with_timeout 30 "$2/term-gh"; echo $? > "$2/status"', '_', str(root), str(home)], owner=os.getpid())
try:
    import select
    fd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
    try:
        assert select.select([fd], [], [], 5)[0], 'timeout command did not start'
        sleeper, child, runner = map(int, os.read(fd, 100).split())
    finally:
        os.close(fd)
    import time
    start = time.monotonic()
    os.kill(runner, signal.SIGTERM)
    proc.wait(timeout=5)
    assert (home/'status').read_text().strip() == '143', 'TERM must map to 143'
    assert time.monotonic()-start < 5
    import subprocess
    rows = subprocess.check_output(['ps', '-eo', 'pgid=,stat=,args='], text=True)
    assert not any(row.split()[0] == str(child) and not row.split()[1].startswith('Z') for row in rows.splitlines()), 'TERM left a descendant alive'
finally:
    if proc.poll() is None:
        proc.terminate()
        proc.wait(timeout=10)
PY
assert_eq 0 "$?" 'TERM forwards to the whole command group and exits 143'

# Real pack CLI: failed-log timeout must preserve a written pack and gap.
cat > "$d/pack-gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'pr view') printf '{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","mergeStateStatus":"CLEAN"}' ;;
  'pr checks') echo '[{"name":"ci","state":"FAILURE","bucket":"fail","link":"https://github.com/o/r/actions/runs/1/job/2"}]' ;;
  'api '*) echo '{"check_runs":[{"id":2,"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"ci","conclusion":"failure","status":"completed","details_url":"https://github.com/o/r/actions/runs/1/job/2"}]}' ;;
  'run view') exec sleep 30 ;;
esac
SH
chmod +x "$d/pack-gh"
echo '{"id":"T-Z","acceptance":["bounded evidence"]}' > "$d/spec.json"
start=$SECONDS
python3 "$ROOT/bin/lib/fm_context_pack.py" --state "$d/state" --project self --task T-Z --head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --actor worker-test --root "$d/repo" --spec "$d/spec.json" --output "$d/pack.md" --coverage "$d/coverage.json" --round 1 --pr 9 --gh "$d/pack-gh"
assert_eq 0 "$?" 'pack survives failed-log timeout'
assert_ok "test $((SECONDS-start)) -lt 10" 'pack timeout is bounded'
assert_contains "$(cat "$d/pack.md")" 'timed out' 'pack records failed-log timeout gap'
# Collector command and JSON evidence timeout paths use the same deadline.
python3 - "$ROOT" "$d" <<'PY_TIMEOUT'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1])/'bin/lib'))
from fm_context_pack import Collector
home = Path(sys.argv[2])
collector = Collector(home, str(home/'pack-gh'), 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
try:
    collector.command(['sleep', '30'])
    raise AssertionError('command timeout must report unavailable evidence')
except ValueError as error:
    assert str(error) == 'sleep evidence unavailable: timed out'
assert collector.github('run', 'view') is None
assert 'gh evidence unavailable: timed out' in collector.gaps
PY_TIMEOUT
assert_eq 0 "$?" 'collector command and JSON timeouts record unavailable evidence'
cd "$ROOT" || exit 1
finish
