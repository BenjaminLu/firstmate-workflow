#!/usr/bin/env bash
# tests/lib/onboarding/gh.py
# tests/lib/onboarding/repository.json
# tests/lib/onboarding/pulls.json
# tests/lib/onboarding/reviews.json
# tests/lib/onboarding/status.json
set -uo pipefail
for k in $(env | sed -nE 's/^(FM_[^=]*|HERDR_[^=]*|GH_REPO)=.*$/\1/p'); do unset "$k"; done
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib.sh"
t="$(safe_tmpdir)"; eng="$t/engine"; seed="$t/seed"
mkdir -p "$eng" "$t/host/consenlabs"
cp -R "$ROOT/.githooks" "$eng/"
printf 'default_project: self\nprojects:\n  self:\n    repo: .\n    github: consenlabs/tokenlon-mm-agent\n    base: master\n    required_check: ci\n' > "$eng/config.yaml"
export FM_HOME="$t/private" FM_GITHUB_URL="file://$t/host" FM_GH="$ROOT/tests/lib/onboarding/gh.py" ONBOARD_GH_LOG="$t/gh.log"
git init -q -b master "$seed"
git -C "$seed" config user.name Fixture
git -C "$seed" config user.email fixture@example.test
printf 'app\n' > "$seed/app"
git -C "$seed" add app
git -C "$seed" -c core.hooksPath=/dev/null commit -qm 'feat: initial'
printf 'second\n' >> "$seed/app"
git -C "$seed" -c core.hooksPath=/dev/null commit -qam 'fix: second'
git clone -q --bare "$seed" "$t/host/consenlabs/tokenlon-mm-agent.git"
P="$ROOT/bin/fm-project.sh"
"$P" add consenlabs/tokenlon-mm-agent --name agent --repo "$eng" > "$t/proposal"
assert_eq 0 "$?" "remote add crosses shell and gh boundaries"
assert_eq unknown "$(jq -r '.inferred.protection.status' "$t/proposal")" "gh nonzero with JSON stdout is unknown protection"
assert_contains "$(jq -r '.inferred.protection.reason' "$t/proposal")" 'HTTP 404' "gh stderr explains unknown fact"
assert_eq 3 "$(jq '.questions|length' "$t/proposal")" "remote add asks three evidenced questions"
assert_contains "$(jq -r '.inferred.commit_examples[]' "$t/proposal")" 'feat: initial' "temporary history clone reads real git subjects"
assert_ok "test ! -e '$FM_HOME/projects/agent/repo'" "inspection creates no unmanaged repo clone"
cat > "$t/answers" <<'EOF'
{"confirmed":true,"policy_confirmed":true,"captain":"captain","intent":"Maintain agent","product":"Private agent brief","required_checks":["continuous-integration/drone/pr"],"contract":{"check":"npm test"}}
EOF
"$P" add consenlabs/tokenlon-mm-agent --name agent --repo "$eng" --answers "$t/answers" > "$t/out"
assert_eq 0 "$?" "remote add writes approved private policy"
assert_eq 'base github required_check' "$(sed -n '/  agent:/,/  self:/p' "$eng/config.yaml" | sed -nE 's/^    ([a-z_]+):.*/\1/p' | sort | paste -sd ' ' -)" "remote registry entry contains routing only"
assert_lacks "$(cat "$eng/config.yaml")" 'Private agent brief' "private product stays out of registry"
ONBOARD_DRIFT=1 "$P" drift agent --repo "$eng" > "$t/drift"
assert_eq 0 "$?" "drift CLI re-inspects registered repository"
assert_contains "$(cat "$t/drift")" delete_branch "drift CLI proposes changed fact"
"$P" add consenlabs/tokenlon-mm-agent --name self --repo "$eng" --answers "$t/answers" > "$t/out" 2>&1
assert_eq 65 "$?" "remote add refuses self replacement"
assert_contains "$(cat "$t/out")" "cannot replace the self project" "self refusal identifies protected registry entry"
sed 's/"required_checks"/"repository":"other\/repo","required_checks"/' "$t/answers" > "$t/wrong"
"$P" add consenlabs/tokenlon-mm-agent --name agent --repo "$eng" --answers "$t/wrong" > "$t/out" 2>&1
assert_eq 65 "$?" "remote add refuses existing name with different binding"
assert_contains "$(cat "$t/out")" "existing registry binding differs" "name refusal identifies conflicting binding"
# A prior onboarding version left a shallow no-checkout repo. Sync repairs it.
home="$FM_HOME/projects/agent"
git clone -q --depth 1 --no-checkout "$FM_GITHUB_URL/consenlabs/tokenlon-mm-agent.git" "$home/repo"
"$P" sync agent --repo "$eng" > "$t/sync" 2>&1
assert_eq 0 "$?" "sync repairs legacy inspection clone"
assert_eq false "$(git -C "$home/repo" rev-parse --is-shallow-repository)" "sync deepens legacy clone"
assert_ok "test -f '$home/repo/app'" "sync populates legacy checkout"
assert_eq master "$(git -C "$home/repo" config firstmate.base)" "sync installs protected base guard"
assert_eq "$eng/.githooks" "$(git -C "$home/repo" config core.hooksPath)" "sync installs engine hooks"
assert_contains "$(cat "$home/repo/.git/info/exclude")" '.fm-*' "sync installs scratch excludes"
# An empty remote is a legitimate managed clone, not a legacy checkout to repair.
mkdir -p "$t/host/owner"
git init -q --bare -b trunk "$t/host/owner/empty.git"
cat >> "$eng/config.yaml" <<'EOF'
  empty:
    github: owner/empty
    base: trunk
    required_check: ci
EOF
"$P" sync empty --repo "$eng" > "$t/empty-sync" 2>&1
assert_eq 0 "$?" "sync clones an empty remote"
empty="$FM_HOME/projects/empty/repo"
"$P" sync empty --repo "$eng" > "$t/empty-sync" 2>&1
assert_eq 0 "$?" "sync accepts an existing empty clone with unborn HEAD"
assert_fail "git -C '$empty' rev-parse --verify 'HEAD^{commit}'" "empty sync creates no bootstrap commit"
assert_ok "test ! -e '$empty/.git/index'" "empty sync leaves the unborn index absent"
assert_eq trunk "$(git -C "$empty" config firstmate.base)" "empty sync installs protected base guard"
assert_eq "$eng/.githooks" "$(git -C "$empty" config core.hooksPath)" "empty sync installs engine hooks"
assert_contains "$(cat "$empty/.git/info/exclude")" '.fm-*' "empty sync installs scratch excludes"
git -C "$home/repo" remote set-url origin "$t/wrong.git"
"$P" add consenlabs/tokenlon-mm-agent --name agent --repo "$eng" > "$t/out" 2>&1
assert_eq 65 "$?" "remote add refuses mismatched managed origin"
assert_contains "$(cat "$t/out")" 'origin does not match' "origin refusal names the cause"
safe_rm_rf "$t"
finish
