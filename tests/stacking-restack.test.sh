#!/usr/bin/env bash
set -uo pipefail
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do unset "$_fm_k" || true; done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=tests/lib/stacking.sh
. "$ROOT/tests/lib/stacking.sh"
d="$(safe_tmpdir)"
trap 'rm -rf "$d"' EXIT
mkdir -p "$d/bin" "$d/state/runs"
cp "$ROOT/bin/fm-config.sh" "$d/bin/"
cp -R "$ROOT/bin/lib" "$d/bin/"
printf 'vendor: mock\n' > "$d/config.yaml"
stacking_policy "$d/CONVENTIONS.md" hold
stacking_gh "$d" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa t-901-parent
out="$(GH_REPO=fixture/project FM_ROOT="$d" FM_GH="$d/gh" bash "$d/bin/lib/fm-restack.sh" --repo "$d" --pr 2 --parent 1 --expected-head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2>&1)"; code=$?
assert_eq 65 "$code" 'restack entrypoint refuses held policy'
assert_contains "$out" 'confirmed stacking and force-with-lease policy' 'restack explains policy refusal'
assert_fail "test -s '$d/ghcalls'" 'restack policy refusal precedes GitHub'
stacking_policy "$d/CONVENTIONS.md" allowed true
cat > "$d/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = 'pr view' ] || exit 1
printf '{"state":"OPEN","headRefName":"t-902-child","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","baseRefName":"t-901-parent","baseRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n'
STUB
# The foreground Python owner holds the worker lock while its synchronous
# child runs. It releases the descriptor on exit; no background process.
out="$(GH_REPO=fixture/project FM_ROOT="$d" FM_GH="$d/gh" python3 - "$d" <<'PY'
import fcntl, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
with (root / 'state/runs/.worker-T-902.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    result = subprocess.run(['bash', str(root / 'bin/lib/fm-restack.sh'), '--repo', str(root),
        '--pr', '2', '--parent', '1', '--expected-head', 'b' * 40],
        capture_output=True, text=True, timeout=30)
    print(result.stdout + result.stderr)
    sys.exit(result.returncode)
PY
)"; code=$?
assert_eq 75 "$code" 'restack entrypoint refuses live worker lock'
assert_contains "$out" 'task has a live worker; restack held' 'restack lock refusal names active owner'
# No worker owns the lock now; GitHub reports a different authoritative head.
sed 's/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/cccccccccccccccccccccccccccccccccccccccc/g' "$d/gh" > "$d/gh-moved"
chmod +x "$d/gh-moved"
out="$(GH_REPO=fixture/project FM_ROOT="$d" FM_GH="$d/gh-moved" bash "$d/bin/lib/fm-restack.sh" --repo "$d" --pr 2 --parent 1 --expected-head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2>&1)"; code=$?
assert_eq 67 "$code" 'restack entrypoint distinguishes GitHub head movement'
assert_contains "$out" 'task head changed on GitHub' 'restack names authoritative head movement'
# FAIL-FIRST: retain an adopted push only for a known published outcome.
cat > "$d/bin/lib/fm_adopt.py" <<'PY_STUB'
import os, sys
assert sys.argv[1:] == ['task-of', '--pr', '2']
if os.environ.get('ADOPT_ERROR') == '1': sys.exit('adopted by two tasks')
print('T-902')
PY_STUB
cat > "$d/bin/lib/fm_stack.py" <<'PY_STUB'
import os, sys
from pathlib import Path
Path(os.environ['STACK_CALLED']).write_text('called')
sys.exit(int(os.environ['STACK_EXIT']))
PY_STUB
cat > "$d/bin/fm-emit.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$EMIT_ARGS"
exit "${EMIT_EXIT:-0}"
STUB
chmod +x "$d/bin/fm-emit.sh"
export EMIT_ARGS="$d/emit-args" STACK_CALLED="$d/stack-called"
for STACK_EXIT in 0 69 71; do
  export STACK_EXIT
  rm -f "$EMIT_ARGS"
  out="$(GH_REPO=fixture/project FM_ROOT="$d" bash "$d/bin/lib/fm-restack.sh" --repo "$d" --pr 2 --parent 1 --expected-head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2>&1)"; code=$?
  assert_eq "$STACK_EXIT" "$code" "REGRESSION: wrapper preserves restack exit $STACK_EXIT"
  if [ "$STACK_EXIT" = 71 ]; then
    assert_fail "test -e '$EMIT_ARGS'" 'unknown push emits no adopted event'
    assert_contains "$out" 'repin adopt.head with a new spec and A card' 'unknown push recovery guidance'
  else
    emitted="$(cat "$EMIT_ARGS")"
    assert_contains "$emitted" 'firstmate' 'restack event uses firstmate actor'
    assert_contains "$emitted" 'commit_pushed' 'restack event counts as push'
    assert_contains "$emitted" '"restacked":true,"adopt_pr":2' 'restack event retains adopted PR identity'
    assert_contains "$emitted" 'T-902 #2: adopted child restacked' 'private-safe English summary'
    assert_contains "$emitted" 'T-902 #2 已重設接手子 PR 的基底' 'private-safe Traditional Chinese summary'
  fi
done
for STACK_EXIT in 0 69; do
  export STACK_EXIT
  out="$(EMIT_EXIT=1 GH_REPO=fixture/project FM_ROOT="$d" bash "$d/bin/lib/fm-restack.sh" --repo "$d" --pr 2 --parent 1 --expected-head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2>&1)"; code=$?
  assert_eq 71 "$code" 'FAIL-FIRST: failed retention never reports successful restack'
  assert_contains "$out" 'restack published but event retention failed; synchronize the head and repin adoption before retry' 'retention failure recovery'
done
rm -f "$STACK_CALLED"
out="$(ADOPT_ERROR=1 GH_REPO=fixture/project FM_ROOT="$d" bash "$d/bin/lib/fm-restack.sh" --repo "$d" --pr 2 --parent 1 --expected-head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2>&1)"; code=$?
assert_ne 0 "$code" 'REGRESSION: duplicate ownership stops wrapper'
assert_fail "test -e '$STACK_CALLED'" 'FAIL-FIRST: task-of failure precedes restack'
# Feature-owned Python restack cases share tests/lib/stacking_fixture.py.
for case_name in test_adopted_restack_identity_authorization test_adopted_restack_guards_and_retarget test_adopted_dependency_and_parent_release; do
  PYTHONPATH="$ROOT/bin/lib" python3 "$ROOT/tests/stacking_cases.py" "Stacking.$case_name"
  assert_eq 0 "$?" "$case_name"
done
# Feature fixture dependency: tests/lib/external_adopt.py
python3 "$ROOT/tests/lib/external_adopt.py" "$ROOT" restack
assert_eq 0 "$?" 'FAIL-FIRST: real adopted restack before a worker round'
finish
