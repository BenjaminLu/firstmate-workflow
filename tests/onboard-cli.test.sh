#!/usr/bin/env bash
# Public CLI and private command/prompt routing, including an empty folder.
set -uo pipefail
for k in $(env | sed -nE 's/^(FM_[^=]*|HERDR_[^=]*|GH_REPO)=.*$/\1/p'); do unset "$k"; done
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
t="$(safe_tmpdir)"; eng="$t/engine"; fresh="$t/fresh"
mkdir -p "$eng" "$fresh"
printf 'vendor: mock\n' > "$eng/config.yaml"
export FM_HOME="$t/private"
"$ROOT/bin/fm-project.sh" add "$fresh" --name seed --repo "$eng" > "$t/proposal"
assert_eq 0 "$?" "project add inspects an empty local folder without history"
assert_eq 3 "$(jq '.questions | length' "$t/proposal")" "CLI offers at most three missing-contract questions"
assert_ok "test ! -e '$fresh/.git'" "inspection does not invent an initial commit"
assert_ok "test ! -e '$FM_HOME/projects/seed/CONVENTIONS.md'" "unconfirmed proposal cannot become executable policy"
cat > "$t/answers.json" <<'EOF'
{"confirmed":true,"policy_confirmed":true,"captain":"captain","intent":"Start product","product":"Private product brief","repository":"owner/product","visibility":"private","base":"main","bootstrap_authorized":true,"merge_method":"squash","available_merge_methods":["squash"],"delete_branch":false,"required_checks":["ci"],"contract":{"setup":"npm ci","check":"npm test","test":"bash {file}","tests":["tests/*.sh"],"check_env":{"MODE":"private"}}}
EOF
"$ROOT/bin/fm-project.sh" add "$fresh" --name seed --repo "$eng" --answers "$t/answers.json" > "$t/out"
assert_eq 0 "$?" "explicit product remote and bootstrap contract permits onboarding"
assert_contains "$(cat "$FM_HOME/projects/seed/CONVENTIONS.md")" 'Private product brief' "private conventions record product intent"
assert_lacks "$(cat "$eng/config.yaml")" 'Private product brief' "engine registry excludes private contract"
assert_lacks "$(cat "$eng/config.yaml")" 'npm' "engine registry contains routing only"
assert_ok "test ! -e '$fresh/.git'" "bootstrap authorization does not itself create a commit or remote"
command="$(bash -c '. "$1/bin/fm-config.sh"; fm_project_contract seed check "$2/config.yaml"' _ "$ROOT" "$eng")"
assert_eq 'npm test' "$command" "registered external command comes from private state config"
globs="$(bash -c '. "$1/bin/fm-config.sh"; fm_project_contract seed tests "$2/config.yaml"' _ "$ROOT" "$eng")"
assert_eq 'tests/*.sh' "$globs" "private command contract preserves list shape"
bash -c '. "$1/bin/fm-config.sh"; fm_storage_init "$2" seed; fm_conventions_prompt' _ "$ROOT" "$eng" > "$t/prompt"
assert_eq 0 "$?" "shared crew prompt reader resolves bound private contract"
assert_contains "$(cat "$t/prompt")" 'Private product brief' "worker and reviewer contract includes conventions prose"
printf '{"post":"comments"}\n' > "$t/changes.json"
"$ROOT/bin/fm-project.sh" edit seed --repo "$eng" --changes "$t/changes.json" --captain captain --intent 'Use comments' > "$t/diff"
assert_eq 0 "$?" "chat edit uses project command entrypoint"
assert_contains "$(cat "$t/diff")" '+post: comments' "chat edit reports exact changed line"
# Review and fail-first pass tree paths; neither may become authority.
mkdir -p "$t/tree"
printf 'project:\n  check: unapproved-repository-command\n' > "$t/tree/config.yaml"
for candidate in "$fresh/config.yaml" "$t/tree/config.yaml"; do
  FM_EXTERNAL=1 FM_STATE_DIR="$t/missing-state" bash -c '. "$1/bin/fm-config.sh"; fm_project check "$2"' _ "$ROOT" "$candidate" > "$t/refusal" 2>&1
  assert_eq 65 "$?" "missing private contract refuses tree config $candidate"
  assert_lacks "$(cat "$t/refusal")" 'unapproved-repository-command' "unapproved command never returned"
done
private_command="$(FM_EXTERNAL=1 FM_STATE_DIR="$FM_HOME/projects/seed/state" bash -c '. "$1/bin/fm-config.sh"; fm_project check "$2"' _ "$ROOT" "$t/tree/config.yaml")"
assert_eq 'npm test' "$private_command" "shell reader prefers approved private command over tree config"
self_command="$(FM_EXTERNAL=0 bash -c '. "$1/bin/fm-config.sh"; fm_project check "$2"' _ "$ROOT" "$t/tree/config.yaml")"
assert_eq 'unapproved-repository-command' "$self_command" "self shell reader retains explicit file behavior"
safe_rm_rf "$t"
finish
