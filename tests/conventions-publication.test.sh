#!/usr/bin/env bash
# Shared policy reaches real merge/checkpoint entrypoints; no network.
set -uo pipefail
for k in $(env | sed -nE 's/^(FM_[^=]*|HERDR_[^=]*|GH_REPO)=.*$/\1/p'); do unset "$k"; done
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/lib/binding-fixture.sh"
t="$(safe_tmpdir)"
export FM_HOME="$t/private" FM_GITHUB_URL="$t/remotes"
eng="$t/engine"; mkdir -p "$eng" "$t/remotes/org/app.git"
cp -R "$ROOT/.githooks" "$eng/.githooks"
cat > "$eng/config.yaml" <<'EOF'
projects:
  app:
    github: org/app
    base: trunk
    required_check: drone
EOF
home="$FM_HOME/projects/app"; mkdir -p "$home"
git init -q --bare -b trunk "$t/remotes/org/app.git"
git clone -q "$t/remotes/org/app.git" "$home/repo" 2>/dev/null
git -C "$home/repo" config user.name Fixture
git -C "$home/repo" config user.email fixture@example.test
git -C "$home/repo" config firstmate.base trunk
printf 'initial\n' > "$home/repo/app"
git -C "$home/repo" add app
git -C "$home/repo" -c core.hooksPath=/dev/null commit -qm initial
git -C "$home/repo" push -q origin trunk
mkdir -p "$home/worktrees"
git -C "$home/repo" worktree add -qb t-001-work "$home/worktrees/T-001"
printf 'changed\n' > "$home/worktrees/T-001/app"
export FM_PROJECT=app FM_ROOT="$eng"
bash "$ROOT/bin/fm-checkpoint.sh" --dir "$home/worktrees/T-001" --repo "$eng" --message fixture > "$t/out" 2>&1
assert_eq 65 "$?" "external checkpoint without conventions refuses"
# Exercise the worker's real EXIT handler and publication function, with only
# unrelated lifecycle recording replaced. The policy and checkpoint stay real.
{
  cat <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
source "$ROOT/bin/fm-config.sh"
REPO="$eng"
fm_storage_init "$REPO" || exit 65
FM_CODE_ROOT="$ROOT"
tree="$home/worktrees/T-001"; branch=t-001-work; TASK=T-001
_fm_wip_done=0
rebuild_settle() { :; }
catchup_settle() { :; }
fm_record_end() { :; }
clean_scratch() { :; }
emit() { printf '%s\n' "$*" >> "$EXIT_EVENTS"; }
emit_once() { :; }
wake_round_end() { :; }
EOF
  sed -n '/^publish_wip_if_dirty() {/,/^}/p' "$ROOT/bin/fm-worker.sh"
  sed -n '/^finished() {/,/^}/p' "$ROOT/bin/fm-worker.sh"
  sed -n '/^trap finished EXIT$/p' "$ROOT/bin/fm-worker.sh"
  printf '%s\n' 'exit 143'
} > "$t/worker-exit.sh"
export ROOT eng home EXIT_EVENTS="$t/exit-events"
bash "$t/worker-exit.sh" > "$t/exit-out" 2>&1
assert_eq 143 "$?" "external worker EXIT retains interruption status without conventions"
assert_eq changed "$(cat "$home/worktrees/T-001/app")" "refused exit checkpoint retains dirty work"
assert_fail "git -C '$t/remotes/org/app.git' rev-parse --verify t-001-work" "unconfirmed worker exit creates no remote task branch"
# Literal dependency: tests/lib/onboarding/repository.json. Policy shape is
# generated through onboarding, not an independent hand-written bypass.
python3 - "$ROOT" "$home" <<'PY'
import sys
from pathlib import Path
sys.dont_write_bytecode=True
sys.path.insert(0,sys.argv[1]+'/bin/lib')
from fm_onboard import infer, approve
home=Path(sys.argv[2])
e=dict(repository='org/app',base='trunk',source='github',pulls=[],commits=[],
       protection={'status':'unknown'},repository_info={'allow_merge_commit':True,'allow_squash_merge':False,'allow_rebase_merge':False,'delete_branch_on_merge':False})
p=infer(e)
approve(home,e,p,dict(confirmed=True,policy_confirmed=True,captain='captain',intent='Use app',
    product='Application',required_checks=['drone'],contract={'check':'true'},land='card',review='fm',post='local'))
PY
bash "$ROOT/bin/fm-checkpoint.sh" --dir "$home/worktrees/T-001" --repo "$eng" --message fixture > "$t/out" 2>&1
assert_eq 0 "$?" "external interrupted-round checkpoint follows confirmed policy"
assert_eq "$(git -C "$home/worktrees/T-001" rev-parse HEAD)" "$(git -C "$t/remotes/org/app.git" rev-parse t-001-work)" "checkpoint publishes actual task head"
printf 'exit save\n' > "$home/worktrees/T-001/exit-save"
bash "$t/worker-exit.sh" > "$t/exit-out" 2>&1
assert_eq 143 "$?" "confirmed external worker EXIT retains interruption status"
assert_eq 'exit save' "$(git -C "$t/remotes/org/app.git" show t-001-work:exit-save 2>/dev/null)" "external worker EXIT publishes dirty work under confirmed conventions"
assert_eq '' "$(git -C "$home/worktrees/T-001" status --porcelain)" "external worker EXIT checkpoint leaves a clean tree"
assert_contains "$(cat "$EXIT_EVENTS" 2>/dev/null)" 'commit_pushed' "external worker EXIT verifies and records its checkpoint"
mkdir -p "$eng/bin"
cp "$ROOT/bin/fm-merge.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-herdr.py" "$eng/bin/"
cp -R "$ROOT/bin/lib" "$eng/bin/"
binding_service_fixture "$eng"
cat > "$t/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "$1 $2" in
 'pr view') printf '%s\n' '{"state":"OPEN","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","headRefName":"t-001-work","title":"T-001: work"}' ;;
 'pr merge') exit 0 ;;
 *) exit 1 ;;
esac
EOF
chmod +x "$t/gh"
export FM_GH="$t/gh" FM_TEST_GH_LOG="$t/gh.log"
bash "$eng/bin/fm-merge.sh" --project app --repo "$eng" --pr 1 --task T-001 --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$t/out" 2>&1
assert_eq 0 "$?" "external merge consumes confirmed project method"
assert_contains "$(cat "$t/gh.log")" "--merge" "merge uses configured merge-commit method"
assert_lacks "$(cat "$t/gh.log")" "--delete-branch" "retention policy keeps branch"
assert_contains "$(cat "$t/gh.log")" "--repo org/app" "merge names project repository explicitly"
sed 's/land: card/land: handoff/' "$home/CONVENTIONS.md" > "$t/policy"
cp "$t/policy" "$home/CONVENTIONS.md"
: > "$t/gh.log"
bash "$eng/bin/fm-merge.sh" --project app --repo "$eng" --pr 1 --task T-001 --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$t/out" 2>&1
assert_eq 65 "$?" "handoff policy refuses engine merge"
assert_eq "" "$(cat "$t/gh.log")" "handoff makes no GitHub mutation"
safe_rm_rf "$t"
finish
