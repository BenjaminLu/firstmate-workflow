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
# Allocation below requests imani explicitly. Without pins, the random draw
# can put imani on the reviewer roster and correctly refuse that request.
rosters:
  workers: [imani]
  reviewers: [ada]
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
assert_eq imani "$(jq -r .name "$run/identity.json")" "external worker uses the fixture's pinned worker name"
assert_ok "test -f '$store/state/crew/rosters.json'" "external roster draw is retained only in project state"
FM_PROJECT=private-app python3 "$ROOT/bin/lib/fm_lifeline.py" push "$eng" D-private-app-T001-1 answered private >/dev/null
assert_eq 0 "$?" "private wake can be pushed without a waiter"
assert_ok "test -f '$store/state/session/wake.jsonl'" "private wake is outside engine"
assert_eq "dispatch.lock" "$(find "$eng/state" -type f -exec basename {} \;)" "allocation retains only the global lock, never private records, in engine state"
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
  setup: printf wrong > repository-contract-ran.txt
  docs:
    - '*.md'
YAML
cat > "$store/state/config.yaml" <<'YAML'
project:
  setup: printf prepared > prepared.txt
  check: test -f prepared.txt
YAML
FM_PROJECT=private-app python3 - "$ROOT" "$eng" > "$t/setup-report" <<'PYTHON'
import importlib.util, json, pathlib, sys
spec = importlib.util.spec_from_file_location('herdr', pathlib.Path(sys.argv[1]) / 'bin/fm-herdr.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
status = module.project_report(sys.argv[2])
pathlib.Path(sys.argv[2], 'status-report.json').write_text(json.dumps(status))
print(json.dumps(module.project_report(sys.argv[2], run_setup=True)))
PYTHON
assert_eq true "$(jq -r .ready "$eng/status-report.json")" "external report reads private check despite conflicting repository config"
assert_eq 'setup,check' "$(jq -r '.declared | join(",")' "$eng/status-report.json")" "external report declares only private contract keys"
assert_eq null "$(jq -r .setup "$eng/status-report.json")" "status reports setup without executing it"
assert_eq true "$(jq -r .ready "$t/setup-report")" "external startup uses private setup contract"
assert_ok "test -f '$store/repo/prepared.txt'" "setup executes in target clone"
assert_ok "test ! -e '$store/repo/repository-contract-ran.txt'" "startup never executes repository contract"
assert_ok "test -f '$store/state/session/project-setup.log'" "setup evidence is private"
assert_ok "test ! -e '$eng/prepared.txt'" "setup does not execute in engine"
FM_PROJECT=private-app python3 - "$ROOT" "$eng" "$store" > "$t/contract-guards" <<'PYTHON'
import importlib.util, json, os, pathlib, sys
spec = importlib.util.spec_from_file_location('herdr', pathlib.Path(sys.argv[1]) / 'bin/fm-herdr.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
engine, store = map(pathlib.Path, sys.argv[2:])
private = store / 'state/config.yaml'
saved = private.read_text()
private.unlink()
try:
    missing = module.project_report(engine, run_setup=True)
finally:
    private.write_text(saved)
with (engine / 'config.yaml').open('a') as config:
    config.write('project:\n  setup: printf self > self-prepared.txt\n  check: test -f self-prepared.txt\n')
os.environ['FM_PROJECT'] = 'self'
self_report = module.project_report(engine, run_setup=True)
print(json.dumps(dict(missing=missing, self=self_report)))
PYTHON
assert_eq false "$(jq -r .missing.ready "$t/contract-guards")" "missing private contract leaves external startup unready"
assert_ok "test ! -e '$store/repo/repository-contract-ran.txt'" "missing private contract never falls back to repository setup"
assert_eq true "$(jq -r .self.ready "$t/contract-guards")" "self startup retains engine contract"
assert_ok "test -f '$eng/self-prepared.txt'" "self setup retains engine working directory"
FM_ROOT="$eng" "$ROOT/bin/fm-emit.sh" --actor captain --type greenlit >/dev/null
assert_ok "test -f '$eng/state/events.jsonl'" "self events retain original layout"
assert_eq 1 "$(wc -l < "$eng/state/events.jsonl" | tr -d ' ')" "self log contains no private event"
"$ROOT/bin/fm-merge.sh" --pr 1 --project private-app --repo "$eng" > "$t/out" 2> "$t/err"; rc=$?
assert_eq 65 "$rc" "external merge waits for project policy"
assert_contains "$(cat "$t/err")" 'CONVENTIONS.md' "merge refusal names missing contract"
assert_contains "$(cat "$t/err")" 'readable' "merge refusal explains unreadable policy"
safe_rm_rf "$t"
finish
