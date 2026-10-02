#!/usr/bin/env bash
# fm-project.sh: the managed clone of a target and what a target needs
# (design 15.1 and 15.6). Nothing here reaches the network: the clone comes
# from a bare repository standing in for GitHub, and gh is the stub, which
# answers the two API calls verify makes in the shapes GitHub returns.
set -uo pipefail
# a live managed run exports FM_ROOT, FM_PROJECT and friends into this shell;
# the fixture names its engine root and project itself
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*|GHSTATE)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
P="$ROOT/bin/fm-project.sh"

t="$(safe_tmpdir)"
export FM_HOME="$t/fm-home"
eng="$t/engine"
mkdir -p "$eng"
git -C "$eng" init -q -b main
cp -R "$ROOT/.githooks" "$eng/.githooks"
{ printf 'vendor: claude\ndefault_project: self-host\n'
  printf 'projects:\n'
  printf '  self-host:\n    repo: .\n    github: owner-a/engine\n    base: main\n    required_check: ci\n'
  printf '  example-app:\n    github: example-org/example-app\n    base: trunk\n    required_check: check\n'
} > "$eng/config.yaml"

# GitHub, locally: example-org/example-app with a trunk and one other branch
remotes="$t/remotes"
bare="$remotes/example-org/example-app.git"
mkdir -p "$bare"; git init -q --bare -b trunk "$bare"
seed="$t/seed"; git init -q -b trunk "$seed"
git -C "$seed" config user.email a@b.c; git -C "$seed" config user.name t
git -C "$seed" config core.hooksPath /dev/null
echo app > "$seed/app.txt"; git -C "$seed" add -A; git -C "$seed" commit -qm init
git -C "$seed" push -q "$bare" trunk trunk:old-branch

gh="$t/gh"; mkdir -p "$gh"
export GHSTATE="$gh" FM_GH="$ROOT/tests/gh-stub.sh" FM_GITHUB_URL="$remotes"
# run the way a caller does: by path, not through bash, so a lost
# executable bit fails here rather than in the first script that calls it
run() { "$P" "$@" > "$t/out" 2> "$t/err"; printf '%s' "$?"; }
clone="$FM_HOME/projects/example-app/repo"

# --- how it is called (5.3.1) --------------------------------------------
assert_ok "test -x '$P'" "fm-project.sh is executable, as its header and its messages tell people to run it"
assert_eq "64" "$(run)" "no subcommand is a usage error"
assert_contains "$(cat "$t/err")" "usage: fm-project.sh" "and says how to call it"
assert_eq "64" "$(run launch example-app --repo "$eng")" "an unknown subcommand exits 64"
assert_eq "64" "$(run sync --repo "$eng")" "sync with no project name exits 64"
assert_eq "64" "$(run verify --repo "$eng")" "and so does verify"
assert_eq "64" "$(run sync example-app other --repo "$eng")" "two names is one too many"
assert_eq "64" "$(run sync example-app --bogus --repo "$eng")" "an unknown flag exits 64"
assert_eq "64" "$(run sync example-app --repo)" "--repo with nothing after it exits 64"
assert_contains "$(cat "$t/err")" "--repo" "and names the flag"
assert_eq "65" "$(run sync no-such-app --repo "$eng")" "an unregistered project exits 65, like an unknown task"
assert_eq "65" "$(run verify no-such-app --repo "$eng")" "for verify too"
assert_ne "" "$(cat "$t/err")" "and says why"

# --- the self project: both are no-ops that succeed ----------------------
assert_eq "0" "$(run sync self-host --repo "$eng")" "sync of the self project succeeds"
assert_eq "0" "$(run verify self-host --repo "$eng")" "verify of the self project succeeds"
assert_ok "test ! -e '$eng/state/projects'" "and nothing was cloned for it"
assert_eq "" "$(git -C "$eng" config --local --get core.hooksPath)" "nor was the engine's hooks path touched"
assert_eq "" "$(git -C "$eng" config --local --get firstmate.base)" "nor its guard"
# FM_ROOT names the engine root the same way --repo does
assert_eq "0" "$(cd "$t" && FM_ROOT="$eng" "$P" sync self-host >/dev/null 2>&1; echo $?)" \
  "FM_ROOT is the engine root when --repo is not given"

# the engine's real registry entry, not a fixture: firstmate-workflow is the
# self project, so naming it takes the same no-op and clones nothing
real="$t/real-engine"; mkdir -p "$real"; git -C "$real" init -q -b main
cp "$ROOT/config.yaml" "$real/config.yaml"; cp -R "$ROOT/.githooks" "$real/.githooks"
assert_eq "." "$(bash -c '. "$1/bin/fm-config.sh"; fm_project_get firstmate-workflow repo "$2/config.yaml"' _ "$ROOT" "$real")" \
  "the real config.yaml registers firstmate-workflow with repo: ."
assert_eq "0" "$(run sync firstmate-workflow --repo "$real")" "sync of the real self project succeeds"
assert_contains "$(cat "$t/out")" "nothing to sync" "as the no-op"
assert_eq "0" "$(run verify firstmate-workflow --repo "$real")" "verify of the real self project succeeds"
assert_contains "$(cat "$t/out")" "nothing to verify" "as the no-op"
assert_ok "test ! -e '$real/state/projects'" "and nothing was cloned for it"
assert_eq "" "$(git -C "$real" config --local --get core.hooksPath)" "nor its hooks path touched"
assert_eq "" "$(git -C "$real" config --local --get firstmate.base)" "nor its guard"

# --- verify before there is a clone --------------------------------------
assert_eq "70" "$(run verify example-app --repo "$eng")" "verify with no clone, no protection, no repository refuses with 70"
err="$(cat "$t/err")"
assert_contains "$err" "$FM_HOME/projects/example-app/repo" "it names the missing clone"
assert_contains "$(cat "$t/out")" "branch protection unknown for example-org/example-app trunk" \
  "and the branch protection it could not read"
assert_contains "$err" "captain-confirmed checks and policy" "unknown protection requires confirmation"

# --- sync: the first time it clones --------------------------------------
assert_eq "0" "$(run sync example-app --repo "$eng")" "sync clones a registered target"
assert_ok "test -d '$clone/.git'" "into FM_HOME/projects/<name>/repo"
assert_eq "$remotes/example-org/example-app.git" "$(git -C "$clone" remote get-url origin)" \
  "from the project's github repository"
assert_eq "app" "$(cat "$clone/app.txt" 2>/dev/null)" "with the target's tree checked out"
assert_eq "$eng/.githooks" "$(git -C "$clone" config --local --get core.hooksPath)" \
  "core.hooksPath in the clone's local config is the engine's .githooks/"
assert_eq "trunk" "$(git -C "$clone" config --local --get firstmate.base)" \
  "and the clone tells the guard which base is the project's"
assert_eq "1" "$(grep -cxF '.fm-*' "$clone/.git/info/exclude" 2>/dev/null)" ".fm-* is in the clone's info/exclude"
assert_eq "" "$(git -C "$clone" status --porcelain)" "and nothing was written into the target's tree"
assert_eq "app.txt" "$(git -C "$clone" ls-files)" "which holds exactly what the target holds"
echo say > "$clone/.fm-say.md"; echo p > "$clone/.fm-prompt.md"
assert_eq "" "$(git -C "$clone" status --porcelain)" "a firstmate note in the clone stays local"
rm -f "$clone/.fm-say.md" "$clone/.fm-prompt.md"
assert_eq "" "$(git -C "$eng" config --local --get core.hooksPath)" "the engine's own hooks path is untouched"
assert_eq "" "$(git -C "$eng" config --local --get firstmate.base)" "and so is its guard"

# the guard is live in the clone: the project's base is protected
git -C "$clone" config user.email a@b.c; git -C "$clone" config user.name t
# The clone has no engine bin/, so a hook that broke there for some other
# reason would refuse everything and still pass a refusal test. Every refusal
# is paired with an allowed action on the same clone, and must name the base.
echo local > "$clone/app.txt"
assert_eq "1" "$(git -C "$clone" commit -qam on-trunk > /dev/null 2> "$t/hook"; echo $?)" \
  "the clone's hooks refuse a commit on the project's base"
assert_contains "$(cat "$t/hook")" "refusing to commit on trunk" "naming the base"
git -C "$clone" checkout -q -- app.txt
git -C "$clone" checkout -q -b t-001-work
echo work > "$clone/app.txt"
assert_ok "git -C '$clone' commit -qam on-branch" "and allow one on a task branch"
assert_ne "0" "$(git -C "$clone" push -q origin t-001-work:trunk > /dev/null 2> "$t/hook"; echo $?)" \
  "and refuse a push onto the base"
assert_contains "$(cat "$t/hook")" "refusing to push directly to trunk" "naming the base"
assert_ne "$(git -C "$clone" rev-parse t-001-work)" "$(git -C "$bare" rev-parse trunk)" "and the base on the remote did not move"
assert_ok "git -C '$clone' push -q origin t-001-work:t-001-work" "while a push of the task branch goes through"
assert_eq "$(git -C "$clone" rev-parse t-001-work)" "$(git -C "$bare" rev-parse t-001-work 2>/dev/null)" \
  "and lands on the remote"
git -C "$clone" checkout -q trunk

# --- sync again: fetch and prune, nothing duplicated ---------------------
git -C "$seed" push -q "$bare" trunk:new-branch
git -C "$seed" push -q "$bare" :old-branch
assert_ok "git -C '$clone' rev-parse -q --verify refs/remotes/origin/old-branch" "the clone saw old-branch before"
assert_eq "0" "$(run sync example-app --repo "$eng")" "sync of an existing clone succeeds"
assert_ok "git -C '$clone' rev-parse -q --verify refs/remotes/origin/new-branch" "it fetches"
assert_fail "git -C '$clone' rev-parse -q --verify refs/remotes/origin/old-branch" "and prunes"
assert_eq "1" "$(grep -cxF '.fm-*' "$clone/.git/info/exclude")" "the exclude line is not added twice"
assert_eq "t-001-work" "$(git -C "$clone" branch --list t-001-work --format='%(refname:short)')" \
  "and the clone's own branches are left alone"
# an exclude file whose last pattern has no final newline keeps that pattern
printf '# local\n*.log' > "$clone/.git/info/exclude"
assert_eq "0" "$(run sync example-app --repo "$eng")" "sync of a clone whose exclude file lacks a final newline"
assert_eq "1" "$(grep -cxF '*.log' "$clone/.git/info/exclude")" "keeps its last pattern intact"
assert_eq "1" "$(grep -cxF '.fm-*' "$clone/.git/info/exclude")" "and puts .fm-* on a line of its own, once"
git -C "$clone" config core.hooksPath /elsewhere
git -C "$clone" config firstmate.base main
assert_eq "0" "$(run sync example-app --repo "$eng")" "sync repairs a drifted clone"
assert_eq "$eng/.githooks" "$(git -C "$clone" config --local --get core.hooksPath)" "hooks path back on the engine's"
assert_eq "trunk" "$(git -C "$clone" config --local --get firstmate.base)" "guard base back on the project's"

# --- verify: every item, named -------------------------------------------
api="$gh/api/repos/example-org/example-app"
mkdir -p "$api/branches/trunk"
# GET /repos/{owner}/{repo}/branches/{branch}/protection, as GitHub returns it
protection() {   # protection <strict> <enforce_admins> <context> [both|contexts|checks]
  local ctx="[\"$3\"]" chk="[{\"context\": \"$3\", \"app_id\": 15368}]"
  case "${4:-both}" in contexts) chk='[]' ;; checks) ctx='[]' ;; esac
  cat > "$api/branches/trunk/protection.json" <<JSON
{
  "url": "https://api.github.com/repos/example-org/example-app/branches/trunk/protection",
  "required_status_checks": {
    "url": "https://api.github.com/repos/example-org/example-app/branches/trunk/protection/required_status_checks",
    "strict": $1,
    "contexts": $ctx,
    "contexts_url": "https://api.github.com/repos/example-org/example-app/branches/trunk/protection/required_status_checks/contexts",
    "checks": $chk
  },
  "required_pull_request_reviews": {
    "url": "https://api.github.com/repos/example-org/example-app/branches/trunk/protection/required_pull_request_reviews",
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "require_last_push_approval": false,
    "required_approving_review_count": 0
  },
  "required_signatures": {"url": "https://api.github.com/repos/example-org/example-app/branches/trunk/protection/required_signatures", "enabled": false},
  "enforce_admins": {"url": "https://api.github.com/repos/example-org/example-app/branches/trunk/protection/enforce_admins", "enabled": $2},
  "required_linear_history": {"enabled": false},
  "allow_force_pushes": {"enabled": false},
  "allow_deletions": {"enabled": false},
  "block_creations": {"enabled": false},
  "required_conversation_resolution": {"enabled": false},
  "lock_branch": {"enabled": false},
  "allow_fork_syncing": {"enabled": false}
}
JSON
}
# GET /repos/{owner}/{repo}
repository() {   # repository <private> <visibility>
  cat > "$api.json" <<JSON
{
  "id": 1296269,
  "name": "example-app",
  "full_name": "example-org/example-app",
  "owner": {"login": "example-org", "type": "Organization"},
  "private": $1,
  "visibility": "$2",
  "default_branch": "trunk",
  "archived": false
}
JSON
}
# Private policy replaces the withdrawn engine-wide public/protection rules.
# Literal helper dependency: tests/lib/onboarding/repository.json.
python3 - "$ROOT" "$FM_HOME/projects/example-app" <<'PYCONVENTIONS'
import sys
from pathlib import Path
sys.dont_write_bytecode=True
sys.path.insert(0,sys.argv[1]+'/bin/lib')
from fm_onboard import infer, approve
e=dict(source='github',repository='example-org/example-app',base='trunk',pulls=[],commits=[],
       protection={'status':'unknown'},repository_info={'allow_squash_merge':True,'allow_merge_commit':False,'allow_rebase_merge':False,'delete_branch_on_merge':False})
approve(Path(sys.argv[2]),e,infer(e),dict(confirmed=True,policy_confirmed=True,captain='captain',
    intent='Drive application',product='Application',required_checks=['check'],contract={'check':'true'}))
PYCONVENTIONS
repository false public
protection true true check

assert_eq "0" "$(run verify example-app --repo "$eng")" "a protected, public, guarded target verifies"
assert_eq "" "$(cat "$t/err")" "and complains about nothing"

protection true false check
assert_eq "0" "$(run verify example-app --repo "$eng")" "enforce_admins off follows confirmed project policy"
assert_contains "$(cat "$t/out")" "enforce_admins" "and reports it"

protection false true check
assert_eq "0" "$(run verify example-app --repo "$eng")" "strictness follows confirmed project policy"
assert_contains "$(cat "$t/out")" "strict" "and reports strictness"

protection true true lint
assert_eq "0" "$(run verify example-app --repo "$eng")" "confirmed check need not be visible in protection"
assert_contains "$(cat "$t/out")" "lint" "and reports visible protection check"
# GitHub lists a required check under contexts, under checks[].context, or
# both; each alone must count, so dropping either reading goes red
protection true true check checks
assert_eq "0" "$(run verify example-app --repo "$eng")" "a check required only in checks[].context verifies"
protection true true check contexts
assert_eq "0" "$(run verify example-app --repo "$eng")" "a check required only in contexts verifies"

# a protection rule with no required status checks at all: GitHub omits the key
protection true true check
jq 'del(.required_status_checks)' "$api/branches/trunk/protection.json" > "$t/p.json"
mv "$t/p.json" "$api/branches/trunk/protection.json"
assert_eq "0" "$(run verify example-app --repo "$eng")" "confirmed checks remain authoritative when protection omits statuses"
assert_contains "$(cat "$t/out")" "protection visible" "protection facts remain visible"

protection true true check
rm -f "$api/branches/trunk/protection.json"
assert_eq "0" "$(run verify example-app --repo "$eng")" "404 is unknown and accepts confirmed checks and policy"
assert_contains "$(cat "$t/out")" "protection unknown" "404 never claims no protection"
protection true true check

repository true private
assert_eq "0" "$(run verify example-app --repo "$eng")" "a private repository verifies"
assert_eq "" "$(cat "$t/err")" "private visibility is not a refusal"
assert_contains "$(cat "$t/out")" "verified" "private repository uses the same protection checks"
repository false internal
assert_eq "0" "$(run verify example-app --repo "$eng")" "internal visibility is accepted"
repository false public

# An unreadable rule is unknown, and a confirmation is bound to this target.
mv "$api/branches/trunk/protection.json" "$t/protection-held.json"
mv "$api.json" "$t/repository-held.json"
confirmation="$FM_HOME/projects/example-app/CONVENTIONS.md"
mv "$confirmation" "$t/held-conventions.md"
assert_eq "70" "$(run verify example-app --repo "$eng")" "unreadable protection without captain confirmation refuses"
cp "$t/held-conventions.md" "$confirmation"
assert_eq "0" "$(run verify example-app --repo "$eng")" "captain-confirmed checks and policy resolve unknown protection"
sed 's/base: "trunk"/base: "other"/' "$confirmation" > "$t/wrong-conventions.md"
cp "$t/wrong-conventions.md" "$confirmation"
assert_eq "70" "$(run verify example-app --repo "$eng")" "confirmation for a different base grants no readiness"
cp "$t/held-conventions.md" "$confirmation"
mv "$t/protection-held.json" "$api/branches/trunk/protection.json"
mv "$t/repository-held.json" "$api.json"

git -C "$clone" config core.hooksPath "$ROOT/.githooks-elsewhere"
assert_eq "70" "$(run verify example-app --repo "$eng")" "a clone not hooked to the engine's .githooks refuses"
assert_contains "$(cat "$t/err")" "core.hooksPath" "and names the hooks path"
git -C "$clone" config --unset core.hooksPath
assert_eq "70" "$(run verify example-app --repo "$eng")" "and so does one with no hooks path"
# git reads a relative hooks path from the clone's top level, not from the
# directory verify was started in: from the engine root, `.githooks` names
# the engine's hooks to the caller but the clone's own (absent) ones to git
git -C "$clone" config core.hooksPath .githooks
assert_eq "70" "$(cd "$eng" && run verify example-app --repo "$eng")" \
  "a relative hooks path is judged where git reads it, not where verify runs"
assert_contains "$(cat "$t/err")" "core.hooksPath" "and names the hooks path"
# and git expands ~ in it, so a ~ path to the engine's hooks is the engine's
# shellcheck disable=SC2088
git -C "$clone" config core.hooksPath "~/engine/.githooks"
assert_eq "0" "$(HOME="$t" run verify example-app --repo "$eng")" \
  "a ~ hooks path that git expands to the engine's .githooks verifies"
git -C "$clone" config core.hooksPath "$eng/.githooks"
git -C "$clone" config firstmate.base main
assert_eq "70" "$(run verify example-app --repo "$eng")" "a guard protecting some other base refuses"
assert_contains "$(cat "$t/err")" "firstmate.base" "and names the guard's base"
git -C "$clone" config firstmate.base trunk
# hooked and guarded, but a clone of some other repository guards nothing of the target's
git -C "$clone" remote set-url origin "$remotes/example-org/not-this.git"
assert_eq "70" "$(run verify example-app --repo "$eng")" "a clone of some other repository refuses"
assert_contains "$(cat "$t/err")" "origin" "and names the origin"
git -C "$clone" remote set-url origin "$bare"
assert_eq "0" "$(run verify example-app --repo "$eng")" "and the right origin verifies again"

# Visibility/protection variation does not hide a broken local guard
protection false false lint
repository true private
git -C "$clone" config --unset core.hooksPath
assert_eq "70" "$(run verify example-app --repo "$eng")" "several missing items refuse once"
err="$(cat "$t/err")"
assert_contains "$err" core.hooksPath "naming the broken guard among reported facts"
protection true true check; repository false public
assert_eq "0" "$(run sync example-app --repo "$eng")" "a sync puts the hooks back"
assert_eq "0" "$(run verify example-app --repo "$eng")" "and the target verifies again"

# --- sync never touches a checkout outside state/projects/ ---------------
# a directory standing where the clone belongs is inside the ENGINE's
# checkout, so git run there would fetch, hook and exclude the engine itself
mkdir -p "$FM_HOME/projects/other-app/repo"
printf '  other-app:\n    github: example-org/other-app\n    base: main\n    required_check: ci\n' >> "$eng/config.yaml"
assert_eq "70" "$(run sync other-app --repo "$eng")" "a directory that is not its own clone is refused"
assert_contains "$(cat "$t/err")" "not a clone" "and says so"
assert_eq "" "$(git -C "$eng" config --local --get core.hooksPath)" "the engine's hooks path is still untouched"
assert_eq "" "$(git -C "$eng" config --local --get firstmate.base)" "and so is its guard"
assert_eq "" "$(grep -xF '.fm-*' "$eng/.git/info/exclude" 2>/dev/null)" "and its exclude file"
rm -rf "$FM_HOME/projects/other-app"

# a clone of some other repository standing in the place is not this project's
git clone -q "$bare" "$t/foreign" 2>/dev/null
git -C "$t/foreign" remote set-url origin "$remotes/example-org/not-this.git"
mkdir -p "$FM_HOME/projects/other-app"; mv "$t/foreign" "$FM_HOME/projects/other-app/repo"
assert_eq "70" "$(run sync other-app --repo "$eng")" "a clone with the wrong origin is refused"
assert_contains "$(cat "$t/err")" "origin" "and the origin is named"
assert_eq "" "$(git -C "$FM_HOME/projects/other-app/repo" config --local --get core.hooksPath)" "and that clone is not hooked"
rm -rf "$FM_HOME/projects/other-app"

# A symlink out of state/projects/ is refused, and what it points at untouched.
# Each case below is one that only its own symlink check stops: nothing else
# in sync would refuse it before git writes through the link.
#
# the project directory: its repo/ does not exist yet, so without the check
# sync would clone into the captain's checkout
outside="$t/captains-checkout"; git clone -q "$bare" "$outside" 2>/dev/null
git -C "$outside" remote set-url origin "$remotes/example-org/other-app.git"
ln -s "$outside" "$FM_HOME/projects/other-app"
assert_eq "65" "$(run sync other-app --repo "$eng")" "a project directory that is a symlink out is refused"
assert_contains "$(cat "$t/err")" "symlink" "and says so"
assert_ok "test ! -e '$outside/repo'" "nothing is cloned into the checkout it points at"
assert_eq "" "$(git -C "$outside" config --local --get core.hooksPath)" "which is not hooked"
assert_eq "" "$(grep -xF '.fm-*' "$outside/.git/info/exclude" 2>/dev/null)" "nor excluded"
rm -f "$FM_HOME/projects/other-app"
# the clone path, dangling: nothing exists there for the clone check to
# inspect, so without the check git would clone through the link
nowhere="$t/nowhere"
mkdir -p "$FM_HOME/projects/other-app"; ln -s "$nowhere/repo" "$FM_HOME/projects/other-app/repo"
assert_eq "65" "$(run sync other-app --repo "$eng")" "a clone path that is a symlink is refused"
assert_contains "$(cat "$t/err")" "symlink" "and says so"
assert_ok "test ! -e '$nowhere'" "and nothing is written where it points"
# verify names the same refusal: advising a sync that would refuse it is no help
assert_eq "65" "$(run verify other-app --repo "$eng")" "verify of a symlinked clone path refuses"
assert_contains "$(cat "$t/err")" "symlink" "naming the symlink"
assert_lacks "$(cat "$t/err")" "no managed clone" "not a missing clone"
rm -rf "$FM_HOME/projects/other-app"

# state/ and state/projects/ themselves: a first sync would make the project
# directory through the link and clone there
for link in projects projects/example-app; do
  e="$t/engine-${link//\//-}"; away="$t/away-${link//\//-}"
  mkdir -p "$e" "$away"; git -C "$e" init -q -b main
  cp "$eng/config.yaml" "$e/config.yaml"; cp -R "$ROOT/.githooks" "$e/.githooks"
  link_home="$t/home-${link//\//-}"
  mkdir -p "$(dirname "$link_home/$link")"; ln -s "$away" "$link_home/$link"
  assert_eq "65" "$(FM_HOME="$link_home" run sync example-app --repo "$e")" "sync refuses when $link/ is a symlink out"
  assert_contains "$(cat "$t/err")" "symlink" "and says so"
  assert_eq "" "$(ls -A "$away")" "leaving what $link/ points at empty"
  assert_eq "65" "$(FM_HOME="$link_home" run verify example-app --repo "$e")" "verify refuses it too"
  assert_contains "$(cat "$t/err")" "symlink" "naming the symlink"
done

# --- sync's own failures -------------------------------------------------
fresh="$t/engine-fresh"; mkdir -p "$fresh"; git -C "$fresh" init -q -b main
cp "$eng/config.yaml" "$fresh/config.yaml"; cp -R "$ROOT/.githooks" "$fresh/.githooks"
export FM_HOME="$t/fresh-home"
fclone="$FM_HOME/projects/example-app/repo"
assert_ne "0" "$(FM_GITHUB_URL="$t/no-github" run sync example-app --repo "$fresh")" \
  "sync fails when the repository cannot be cloned"
assert_contains "$(cat "$t/err")" "could not clone" "and says so"
assert_ok "test ! -e '$fclone'" "leaving no clone behind"
assert_eq "0" "$(run sync example-app --repo "$fresh")" "the same engine clones once GitHub answers"
mv "$bare" "$bare.away"
assert_ne "0" "$(run sync example-app --repo "$fresh")" "sync fails when the clone cannot fetch"
assert_contains "$(cat "$t/err")" "could not fetch" "and says so"
mv "$bare.away" "$bare"
# an engine with no .githooks/ has no guard to hook the clone to
bare_eng="$t/engine-nohooks"; mkdir -p "$bare_eng"; git -C "$bare_eng" init -q -b main
cp "$eng/config.yaml" "$bare_eng/config.yaml"
assert_eq "70" "$(run sync example-app --repo "$bare_eng")" "sync refuses an engine with no .githooks/"
assert_contains "$(cat "$t/err")" ".githooks" "and names it"
assert_ok "test ! -e '$bare_eng/state/projects/example-app/repo'" "and clones nothing"

safe_rm_rf "$t"
finish
