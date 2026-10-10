#!/usr/bin/env bash
# T-220: private-ref base synchronization preserves local work and fetch state.
set -uo pipefail
for key in $(env | sed -nE 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do unset "$key"; done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
. "$ROOT/bin/fm-config.sh"
# shellcheck source=bin/lib/fm-carry-base.sh
. "$ROOT/bin/lib/fm-carry-base.sh"
t="$(safe_tmpdir)"
fixture() {
  d="$t/$1"; mkdir -p "$d"
  git init -qb main "$d"
  git -C "$d" config user.name Fixture
  git -C "$d" config user.email fixture@example.invalid
  printf old > "$d/changed"; printf original > "$d/unrelated"
  git -C "$d" add .; git -C "$d" commit -qm base
  old="$(git -C "$d" rev-parse HEAD)"
  git clone -q --bare "$d" "$d-origin"
  git -C "$d" remote add origin "$d-origin"
  git clone -q "$d-origin" "$d-writer"
  git -C "$d-writer" config user.name Fixture
  git -C "$d-writer" config user.email fixture@example.invalid
  printf updated > "$d-writer/changed"
  git -C "$d-writer" commit -qam advance
  git -C "$d-writer" push -q origin main
  live="$(git -C "$d-writer" rev-parse HEAD)"
  export FM_EXTERNAL=0 FM_TARGET_ROOT="$d" FM_BASE=main
}
sync_result() {
  out="$(fm_carry_sync_base "${3:-main}" 2>&1)"; status=$?
  assert_eq "$1" "$status" "$4 status"
  assert_contains "$out" "$2" "$4 reason"
  assert_eq '' "$(git -C "$d" for-each-ref --format='%(refname)' refs/fm/carry-base/)" "$4 deletes private refs"
}
fixture checked
printf dirty > "$d/unrelated"; printf untracked > "$d/local"
sync_result 0 '' main 'checked out base'
assert_eq "$live" "$(git -C "$d" rev-parse main)" 'main advances'
assert_eq dirty "$(cat "$d/unrelated")" 'unrelated tracked dirt preserved'
assert_eq untracked "$(cat "$d/local")" 'untracked preserved'
fixture task
git -C "$d" checkout -qb task
sync_result 0 '' main 'base not checked out'
assert_eq "$live" "$(git -C "$d" rev-parse main)" 'unattached base advances'
assert_eq "$old" "$(git -C "$d" rev-parse HEAD)" 'task HEAD unchanged'
assert_eq task "$(git -C "$d" branch --show-current)" 'task branch unchanged'
fixture divergent
printf own > "$d/own"; git -C "$d" add .; git -C "$d" commit -qm own
own="$(git -C "$d" rev-parse HEAD)"
sync_result 75 'cannot be fast-forwarded' main divergent
assert_eq "$own" "$(git -C "$d" rev-parse main)" 'divergent ref unchanged'
fixture dirty
printf dirt > "$d/changed"
sync_result 75 'without touching local changes' main dirty
assert_eq "$old" "$(git -C "$d" rev-parse main)" 'dirty ref unchanged'
assert_eq dirt "$(cat "$d/changed")" 'dirty content unchanged'
fixture unreachable
git -C "$d" remote set-url origin "$t/missing"
sync_result 75 'cannot fetch' main unreachable
assert_eq "$old" "$(git -C "$d" rev-parse main)" 'failed fetch changes no base'
sync_result 75 'not the project base' other wrong-base
out="$(fm_carry_sync_base '' 2>&1)"
assert_eq 75 "$?" 'missing PR base waits'
assert_contains "$out" 'PR base name is unreadable' 'missing base gives explicit reason'
fixture fetch-head
git -C "$d" checkout -qb task
printf task > "$d/task"; git -C "$d" add .; git -C "$d" commit -qm task
printf '%s\t\tbranch task\n' "$(git -C "$d" rev-parse HEAD)" > "$d/.git/FETCH_HEAD"
cp "$d/.git/FETCH_HEAD" "$t/fetch-before"
sync_result 0 '' main fetch-head
assert_eq "$live" "$(git -C "$d" rev-parse main)" 'private fetch ignores concurrent FETCH_HEAD'
assert_ok "cmp '$t/fetch-before' '$d/.git/FETCH_HEAD'" 'FETCH_HEAD byte identical'
fixture linked
git -C "$d" checkout -qb task
git -C "$d" worktree add -q "$d-linked" main
sync_result 75 'another worktree' main linked
assert_eq "$old" "$(git -C "$d" rev-parse main)" 'linked base unchanged'
git -C "$d" worktree remove "$d-linked"
fixture missing
git -C "$d" branch -m task
sync_result 75 'does not exist' main missing
assert_fail "git -C '$d' show-ref --verify refs/heads/main" 'missing ref never created'
fixture external
git -C "$d" branch -m master
git -C "$d-origin" update-ref refs/heads/master "$live"
export FM_EXTERNAL=1 FM_BASE=master
sync_result 0 '' master external
assert_eq "$live" "$(git -C "$d" rev-parse master)" 'external master advances'
fixture external-dirty
git -C "$d" branch -m master
git -C "$d-origin" update-ref refs/heads/master "$live"
printf dirt > "$d/unrelated"
export FM_EXTERNAL=1 FM_BASE=master
sync_result 75 'without touching local work' master external-dirty
assert_eq "$old" "$(git -C "$d" rev-parse master)" 'dirty managed base unchanged'
# T-262: genuine SSH upload-pack observes both named carry-base fetch paths.
# Literal dependencies: bin/lib/fm_git_transfer.py bin/lib/fm-ssh-transfer.sh bin/fm-config.sh
transport_git="$(command -v git)"
cat > "$t/carry-ssh" <<'SSH'
#!/usr/bin/env python3
import json, os, shlex, sys
identity, args = sys.argv[1], sys.argv[2:]
with open(os.environ['CARRY_SSH_LOG'], 'a') as stream:
    stream.write(json.dumps({'identity': identity, 'args': args,
        'count': os.environ.get('GIT_CONFIG_COUNT'),
        'parameters': os.environ.get('GIT_CONFIG_PARAMETERS')}) + '\n')
if os.environ.get('CARRY_SSH_FAIL') == '1':
    sys.exit(255)
remote = shlex.split(args[-1])[-1]
os.execv(os.environ['CARRY_REAL_GIT'], [os.environ['CARRY_REAL_GIT'], 'upload-pack', remote])
SSH
chmod +x "$t/carry-ssh"
carry_transport_case() (
  mode="$1"
  unset GIT_SSH_COMMAND GIT_SSH FM_SSH_GENERATED_COMMAND GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
  fixture "transport-$mode"
  if [ "$mode" = external ]; then
    git -C "$d" branch -m master
    git -C "$d-origin" update-ref refs/heads/master "$live"
    export FM_EXTERNAL=1 FM_BASE=master
  fi
  git -C "$d" remote set-url origin "ssh://example.invalid$d-origin"
  # Source first, then mutate inherited config separately for each real fetch.
  . "$ROOT/bin/fm-config.sh"
  export CARRY_REAL_GIT="$transport_git" CARRY_SSH_LOG="$t/transport-$mode.jsonl"
  export GIT_SSH_VARIANT=ssh GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.sshCommand
  export GIT_CONFIG_VALUE_0="'$t/carry-ssh' count"
  owner_command="$GIT_SSH_COMMAND"
  out="$(fm_carry_sync_base "$FM_BASE" 2>&1)"; status=$?
  assert_eq 0 "$status" "$mode COUNT-selected carry fetch succeeds"
  assert_eq 1 "$GIT_CONFIG_COUNT" "$mode child preparation retains parent COUNT"
  assert_eq "'$t/carry-ssh' count" "$GIT_CONFIG_VALUE_0" "$mode parent identity unchanged"
  assert_eq "$owner_command" "$GIT_SSH_COMMAND" "$mode generated parent command unchanged"
  assert_eq "$live" "$(git -C "$d" rev-parse "$FM_BASE")" "$mode COUNT fetch advances base"
  unset GIT_CONFIG_COUNT
  export GIT_CONFIG_PARAMETERS="'core.sshCommand=\"$t/carry-ssh\" parameters'"
  out="$(fm_carry_sync_base "$FM_BASE" 2>&1)"; status=$?
  assert_eq 0 "$status" "$mode changed PARAMETERS fetch succeeds"
  assert_eq "'core.sshCommand=\"$t/carry-ssh\" parameters'" "$GIT_CONFIG_PARAMETERS" "$mode child preparation retains parent PARAMETERS"
  export CARRY_SSH_FAIL=1
  out="$(fm_carry_sync_base "$FM_BASE" 2>&1)"; status=$?
  assert_eq 75 "$status" "$mode failed prepared fetch stays failed"
  assert_contains "$out" 'cannot fetch the live base' "$mode failed transport diagnostic retained"
  assert_eq '' "$(git -C "$d" for-each-ref --format='%(refname)' refs/fm/carry-base/)" "$mode transport failure cleans private refs"
  assert_eq "$live" "$(git -C "$d" rev-parse "$FM_BASE")" "$mode failed fetch leaves base unchanged"
  assert_ok "python3 - '$CARRY_SSH_LOG' <<'CHECK'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert [row['identity'] for row in rows] == ['count', 'parameters', 'parameters'], rows
for row in rows:
    assert row['count'] is None and row['parameters'] is None, row
    for option in ('ConnectTimeout=20', 'ServerAliveInterval=15', 'ServerAliveCountMax=4'):
        assert option in row['args'], row
CHECK" "$mode actual SSH sees late identity, bounds and native inherited-config stripping"
)
carry_transport_case self
carry_transport_case external
safe_rm_rf "$t"
finish
