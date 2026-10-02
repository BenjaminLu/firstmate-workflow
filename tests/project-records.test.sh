#!/usr/bin/env bash
set -uo pipefail
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
t="$(safe_tmpdir)"; eng="$t/engine"; export FM_HOME="$t/home"
mkdir -p "$eng"
cat > "$eng/config.yaml" <<'YAML'
default_project: self
projects:
  self:
    repo: .
    github: owner/engine
    base: main
    required_check: ci
  private-app:
    github: owner/private-app
    base: trunk
    required_check: ci
YAML
store="$FM_HOME/projects/private-app"
FM_ROOT="$eng" "$ROOT/bin/fm-emit.sh" --project private-app --actor captain --type greenlit --en approved --tw 已核准 > "$t/out"
assert_eq 0 "$?" "external event can be written"
assert_ok "test -f '$store/state/events.jsonl'" "external event is stored privately"
assert_ok "test ! -e '$eng/state'" "external emit makes no engine state"
assert_eq private-app "$(jq -r .project "$store/state/events.jsonl")" "event keeps explicit project identity"
id="$("$ROOT/bin/fm-decide.sh" --allocate --project private-app --task T-001 --repo "$eng")"
assert_eq D-private-app-T001-1 "$id" "external decision allocator retains owned ids"
assert_ok "test -f '$store/state/decision-ids/private-app/T001/1.json'" "decision reservations are private"
mkdir -p "$store/tasks"
printf '%s\n' '{"id":"T-001","title":"Private task","depends_on":[],"scope":["app/**"]}' > "$store/tasks/T-001.json"
out="$("$ROOT/bin/fm-ready.sh" list --project private-app --repo "$eng")"
assert_eq 0 "$?" "readiness reads external specs"
assert_contains "$out" T-001 "external task appears in readiness"
assert_ok "test ! -e '$eng/state'" "readiness and decisions make no engine records"
run="$(FM_PROJECT=private-app python3 "$ROOT/bin/fm-herdr.py" allocate "$eng" worker T-001 imani)"
assert_eq 0 "$?" "Herdr allocates external identity"
assert_ok "test -f '$run/identity.json'" "identity record exists"
assert_eq "$store/state/runs" "$(dirname "$run")" "run and recovery records use project state"
assert_eq private-app "$(jq -r .project "$run/identity.json")" "Herdr keeps project identity separate from actor"
FM_PROJECT=private-app python3 "$ROOT/bin/lib/fm_lifeline.py" push "$eng" D-private-app-T001-1 answered private >/dev/null
assert_eq 0 "$?" "private wake can be pushed without a waiter"
assert_ok "test -f '$store/state/session/wake.jsonl'" "private wake is outside engine"
assert_ok "test ! -e '$eng/state'" "run allocation and wake create no engine records"
out="$("$ROOT/bin/fm.sh" tasks --repo "$eng" --project private-app)"
assert_eq 0 "$?" "tasks command accepts explicit external project"
assert_contains "$out" 'Private task' "tasks command reads external specs"
mkdir -p "$store/repo" "$eng/i18n" "$store/state/pending"
cp "$ROOT"/i18n/* "$eng/i18n/"
printf '%s\n' '{"id":"D-private-app-T001-1","task":"T-001","project":"private-app","kind":"choice","title":"Private decision"}' > "$store/state/pending/$id.json"
"$ROOT/bin/fm-diagram.sh" --repo "$eng" --decision "$id" > "$t/diagram-out"
assert_eq 0 "$?" "external decision diagram renders"
assert_ok "test -f '$store/state/diagrams/$id.en.html'" "diagram is retained in external state"
assert_ok "test ! -e '$eng/board/public/diagrams'" "private diagram is not copied into engine public tree"
cat > "$store/repo/config.yaml" <<'YAML'
project:
  setup: printf prepared > prepared.txt
  check: test -f prepared.txt
YAML
FM_PROJECT=private-app python3 - "$ROOT" "$eng" > "$t/setup-report" <<'PYTHON'
import importlib.util, json, pathlib, sys
spec = importlib.util.spec_from_file_location('herdr', pathlib.Path(sys.argv[1]) / 'bin/fm-herdr.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
print(json.dumps(module.project_report(sys.argv[2], run_setup=True)))
PYTHON
assert_eq true "$(jq -r .ready "$t/setup-report")" "external session uses target setup contract"
assert_ok "test -f '$store/repo/prepared.txt'" "setup executes in target clone"
assert_ok "test -f '$store/state/session/project-setup.log'" "setup evidence is private"
assert_ok "test ! -e '$eng/prepared.txt'" "setup does not execute in engine"
FM_ROOT="$eng" "$ROOT/bin/fm-emit.sh" --actor captain --type greenlit >/dev/null
assert_ok "test -f '$eng/state/events.jsonl'" "self events retain original layout"
assert_eq 1 "$(wc -l < "$eng/state/events.jsonl" | tr -d ' ')" "self log contains no private event"
"$ROOT/bin/fm-merge.sh" --pr 1 --project private-app --repo "$eng" > "$t/out" 2> "$t/err"; rc=$?
assert_eq 65 "$rc" "external merge waits for project policy"
assert_contains "$(cat "$t/err")" 'T-139' "merge refusal explains policy handoff"
assert_contains "$(cat "$t/err")" '合併政策' "merge refusal is bilingual"
safe_rm_rf "$t"
finish
