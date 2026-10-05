#!/usr/bin/env bash
set -uo pipefail
for key in $(env | sed -n 's/^\(FM_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$key"; done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
t="$(safe_tmpdir)"; engine="$t/engine"; export FM_HOME="$t/home" FM_GITHUB_URL="$t/remotes"
mkdir -p "$engine/.githooks" "$t/remotes/owner"
cat > "$engine/config.yaml" <<'YAML'
projects:
  private-app:
    github: owner/private-app
    base: main
    required_check: ci
YAML
git init -q --bare "$t/remotes/owner/private-app.git"
legacy="$engine/state/projects/private-app"
mkdir -p "$legacy/state"
git clone -q "$t/remotes/owner/private-app.git" "$legacy/repo" 2>/dev/null
printf 'private retained evidence\n' > "$legacy/state/evidence.txt"
project="$FM_HOME/projects/private-app"
mkdir -p "$engine/state/runs/old-run" "$engine/state/pending" "$engine/state/pins/private-app" "$engine/state/diagrams"
printf '%s\n' '{"project":"private-app","type":"dispatched","data":{"private":"retained event"}}' '{"project":"self","type":"greenlit"}' > "$engine/state/events.jsonl"
printf '%s\n' '{"project":"private-app","task":"T-001"}' > "$engine/state/runs/old-run/identity.json"
printf 'retained prompt\n' > "$engine/state/runs/old-run/prompt.md"
printf '%s\n' '{"status":"completed"}' > "$engine/state/runs/old-run/process.json"
printf '%s\n' '{"id":"D-private-app-T001-1","project":"private-app","details":"retained decision"}' > "$engine/state/pending/D-private-app-T001-1.json"
printf 'retained pin\n' > "$engine/state/pins/private-app/spec.json"
printf 'retained diagram\n' > "$engine/state/diagrams/D-private-app-T001-1.mmd"
for store in mirrors evidence decision-ids context-packs wake recovery; do
  mkdir -p "$engine/state/$store/private-app"
  printf 'retained %s\n' "$store" > "$engine/state/$store/private-app/record.txt"
done
mkdir -p "$engine/state/session"
printf '%s\n' '{"project":"private-app","reason":"private wake"}' '{"project":"self","reason":"self wake"}' > "$engine/state/session/wake.jsonl"
"$ROOT/bin/fm-project.sh" sync private-app --repo "$engine" > "$t/out" 2> "$t/err"; rc=$?
assert_eq 65 "$rc" "legacy clone requires explicit migration approval"
assert_ok "test -f '$legacy/state/evidence.txt'" "refused migration retains every source record"
assert_ok "test ! -e '$project'" "refused migration creates no destination"
"$ROOT/bin/fm-project.sh" sync private-app --migrate --repo "$engine" > "$t/out" 2> "$t/err"; rc=$?
assert_eq 0 "$rc" "approved migration moves clone and records"
assert_eq 'private retained evidence' "$(cat "$project/state/evidence.txt")" "migration retains record contents"
assert_ok "test ! -e '$legacy'" "atomic migration leaves no private legacy copy"
assert_eq 'retained event' "$(jq -r '.data.private' "$project/state/events.jsonl")" "migration retains shared project events"
assert_eq self "$(jq -r .project "$engine/state/events.jsonl")" "migration leaves unrelated shared events in place"
assert_eq 'retained prompt' "$(cat "$project/state/runs/old-run/prompt.md")" "migration retains shared run context"
assert_ok "test ! -e '$engine/state/runs/old-run'" "migration removes engine run copy"
assert_eq completed "$(jq -r .status "$project/state/runs/old-run/process.json")" "migration retains completed ownership records"
assert_eq 'retained decision' "$(jq -r .details "$project/state/pending/D-private-app-T001-1.json")" "migration retains shared decisions"
assert_eq 'retained pin' "$(cat "$project/state/pins/private-app/spec.json")" "migration retains namespaced pins"
assert_eq 'retained diagram' "$(cat "$project/state/diagrams/D-private-app-T001-1.mmd")" "migration retains decision diagrams"
for store in mirrors evidence decision-ids context-packs wake recovery; do
  assert_eq "retained $store" "$(cat "$project/state/$store/private-app/record.txt")" "migration retains $store records"
  assert_ok "test ! -e '$engine/state/$store/private-app'" "migration removes engine $store copy"
done
assert_eq 'private wake' "$(jq -r .reason "$project/state/session/wake.jsonl")" "migration partitions wake queue"
assert_eq 'self wake' "$(jq -r .reason "$engine/state/session/wake.jsonl")" "migration preserves unrelated wake queue"
"$ROOT/bin/fm-project.sh" history on private-app --repo "$engine" > "$t/out" 2> "$t/err"; rc=$?
assert_eq 0 "$rc" "project can enable local spec history"
assert_eq '' "$(git -C "$project" remote)" "history has no remote"
assert_eq repo/file "$(git -C "$project" check-ignore repo/file)" "history excludes clone"
assert_eq worktrees/T-001/file "$(git -C "$project" check-ignore worktrees/T-001/file)" "history excludes worktrees"
assert_eq state/evidence.txt "$(git -C "$project" check-ignore state/evidence.txt)" "history excludes execution evidence"
# Inject a transfer failure after one shared record moved: rollback must
# restore every source byte and remove the partially consolidated destination.
python3 - "$ROOT" "$t" <<'PYTEST'
import importlib.util
import pathlib
import subprocess
import sys
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('migration', pathlib.Path(sys.argv[1]) / 'bin/lib/fm_project_migrate.py')
module = importlib.util.module_from_spec(spec)
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / 'bin/lib'))
spec.loader.exec_module(module)
t = pathlib.Path(sys.argv[2])
engine = t / 'rollback-engine'
source = engine / 'state/projects/private-app'
source.mkdir(parents=True)
origin = str(t / 'remotes/owner/private-app.git')
subprocess.run(['git', 'clone', '-q', origin, str(source / 'repo')], check=True)
pins = engine / 'state/pins/private-app'
pins.mkdir(parents=True)
(pins / 'a.json').write_text('first private record')
(pins / 'b.json').write_text('second private record')
target = t / 'rollback-home/projects/private-app'
rename = module.os.rename

def fail_second(old, new):
    if pathlib.Path(old) == pins / 'b.json':
        raise OSError('injected transfer failure')
    return rename(old, new)

with patch.object(module.os, 'rename', fail_second):
    try:
        module.migrate(source, target, origin)
    except OSError as error:
        assert str(error) == 'injected transfer failure'
    else:
        raise AssertionError('injected failure was ignored')
assert (source / 'repo/.git').is_dir()
assert (pins / 'a.json').read_text() == 'first private record'
assert (pins / 'b.json').read_text() == 'second private record'
assert not target.exists()
PYTEST
assert_eq 0 "$?" "failed shared transfer rolls back clone and all records"
# Migration shares configured-origin validation, including global rewrites.
export GIT_CONFIG_GLOBAL="$t/gitconfig" GIT_CONFIG_NOSYSTEM=1
ln -s "$t/remotes" "$t/alias"
git config --global "url.$t/alias/.insteadOf" "$t/remotes/"
python3 - "$ROOT" "$t" <<'PYTEST'
import pathlib
import subprocess
import sys
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / 'bin/lib'))
import fm_project_migrate
root = pathlib.Path(sys.argv[2])
origin = str(root / 'remotes/owner/private-app.git')
for name in ('accepted', 'wrong'):
    source = root / 'rewrite-engine/state/projects' / name
    source.mkdir(parents=True)
    repo = source / 'repo'
    subprocess.run(['git', 'clone', '-q', origin, str(repo)], check=True)
    loaded = subprocess.check_output(['git', '-C', str(repo), 'remote', 'get-url', 'origin'], text=True)
    assert loaded == str(root / 'alias/owner/private-app.git') + '\n', 'migration global rewrite setup loaded'
    target = root / 'rewrite-home/projects' / name
    if name == 'accepted':
        fm_project_migrate.migrate(source, target, origin)
        assert (target / 'repo/.git').is_dir(), 'global rewrite must allow legacy migration'
        assert not source.exists()
    else:
        subprocess.run(['git', '-C', str(repo), 'remote', 'set-url', 'origin', str(root / 'other.git')], check=True)
        try:
            fm_project_migrate.migrate(source, target, origin)
        except ValueError as error:
            assert str(error) == 'legacy origin mismatch'
        else:
            raise AssertionError('wrong configured legacy origin was accepted')
        assert repo.is_dir() and not target.exists()
PYTEST
assert_eq 0 "$?" "migration accepts global rewrite and refuses wrong configured origin"
unset GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
safe_rm_rf "$t"
finish
