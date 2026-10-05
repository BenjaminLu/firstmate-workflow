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
finish
