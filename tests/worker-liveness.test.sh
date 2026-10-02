#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# Real ordinary-worker evidence must be consumable by recovery. No emitter
# protocol is invented here; only GitHub and the adapter are controlled.
di="$(fixture T-999)"; ri="$di/repo"
cp "$ROOT/bin/fm-reconcile.sh" "$ri/bin/"; project_storage_fixture "$ri/bin/"
mkdir -p "$di/stub"
cat > "$di/stub/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --json number,state,title,headRefName "*) echo '[]';;
  *" pr list "*) echo 42;;
esac
SH
chmod +x "$di/stub/gh"
cat > "$ri/bin/adapters/mock.sh" <<'SH'
#!/usr/bin/env bash
echo started >> "$FM_ROOT/starts"
while [ ! -e "$FM_ROOT/release" ]; do sleep 0.1; done
mkdir -p "$3/src"
printf 'completed\n' > "$3/src/recovered"
SH
chmod +x "$ri/bin/adapters/mock.sh"
FM_WORKER_LOCK_PID="$$" FM_ROOT="$ri" FM_GH="$di/stub/gh" "$ri/bin/fm-worker.sh" --task T-999 --pr 42 >"$di/worker.out" 2>&1 &
ordinary=$!
for _ in $(seq 1 100); do [ -s "$ri/starts" ] && break; sleep 0.1; done
assert_ok "test -s '$ri/starts'" "ordinary worker reached its adapter"
assert_ok "jq -se 'any(.[]; .type==\"dispatched\" and (.data.recovery // false)==false)' '$ri/state/events.jsonl'" "ancestor lock environment does not turn an ordinary attempt into recovery"
assert_eq "$ordinary" "$(cat "$ri/state/worktrees/T-999.pid" 2>/dev/null)" "ordinary worker publishes its actual PID"
FM_ROOT="$ri" FM_GH="$di/stub/gh" "$ri/bin/fm-worker.sh" --task T-999 --pr 42 >"$di/duplicate.out" 2>&1
assert_eq 70 "$?" "an overlapping ordinary launch refuses the held lock"
assert_eq "$ordinary" "$(cat "$ri/state/worktrees/T-999.pid" 2>/dev/null)" "a refused duplicate preserves the owner's PID"
FM_ROOT="$ri" FM_GH="$di/stub/gh" "$ri/bin/fm-reconcile.sh" >"$di/live.out" 2>&1
assert_eq 0 "$?" "reconcile accepts live ordinary-worker evidence"
assert_lacks "$(cat "$di/live.out")" "redispatch T-999" "live ordinary worker is not duplicated"
kill -KILL "$ordinary" 2>/dev/null
wait "$ordinary" 2>/dev/null
FM_ROOT="$ri" FM_GH="$di/stub/gh" "$ri/bin/fm-reconcile.sh" >"$di/dead.out" 2>&1
recovery_rc=$?
assert_eq 0 "$recovery_rc" "reconcile revives a killed ordinary worker"
[ "$recovery_rc" = 0 ] || cat "$di/dead.out"
assert_contains "$(cat "$di/dead.out")" "redispatch T-999 on #42" "recovery passes the actual retry PR"
for _ in $(seq 1 100); do [ "$(wc -l < "$ri/starts" | tr -d ' ')" = 2 ] && break; sleep 0.1; done
assert_eq 2 "$(wc -l < "$ri/starts" | tr -d ' ')" "the real replacement reaches its adapter"
assert_ok "jq -se 'any(.[]; .type==\"worker_crashed\" and .pr==42)' '$ri/state/events.jsonl'" "ordinary crash retains its PR association"
assert_eq 42 "$(jq -r 'select(.type=="dispatched")|.pr' "$ri/state/events.jsonl" | tail -1)" "replacement dispatch retains the retry PR"
assert_ok "jq -se 'last(.[]|select(.type==\"dispatched\"))|.data.recovery==true and .data.role==\"worker\"' '$ri/state/events.jsonl'" "real associated replacement preserves recovery semantics"
FM_ROOT="$ri" FM_GH="$di/stub/gh" "$ri/bin/fm-reconcile.sh" >"$di/repeat.out" 2>&1
assert_lacks "$(cat "$di/repeat.out")" "redispatch T-999" "replacement evidence prevents another recovery"
: > "$ri/release"
for _ in $(seq 1 100); do [ ! -e "$ri/state/worktrees/T-999.pid" ] && break; sleep 0.1; done
assert_fail "test -e '$ri/state/worktrees/T-999.pid'" "a completed ordinary run removes its liveness claim"
assert_ok "jq -se 'any(.[]; .type==\"agent_finished\" and .actor!=\"reconcile\")' '$ri/state/events.jsonl'" "the real emitter records worker endings"
rm -rf "$di"

df="$(fixture T-998)"; rf="$df/repo"
mkdir -p "$rf/state/worktrees/T-998.pid.next"
FM_ROOT="$rf" "$rf/bin/fm-worker.sh" --task T-998 >"$df/out" 2>&1
assert_eq 70 "$?" "ordinary PID publication failure refuses to run"
assert_fail "test -d '$rf/state/worktrees/T-998'" "publication failure precedes worktree mutation"
assert_fail "test -e '$rf/state/worktrees/T-998.pid'" "failed publication leaves no false PID claim"
rm -rf "$df"


cd "$ROOT" || exit 1
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
