#!/usr/bin/env bash
# Feature-owned tests: external project storage never enters the engine tree.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
t="$(safe_tmpdir)"
eng="$t/engine"; mkdir -p "$eng"
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
export FM_HOME="$t/home"
unset FM_PROJECT
field() { bash -c '. "$1/bin/fm-config.sh"; fm_project_get "$3" "$4" "$2/config.yaml"' _ "$ROOT" "$eng" "$1" "$2"; }
assert_eq "$FM_HOME/projects/private-app/repo" "$(field private-app root)" "external clone is outside engine"
assert_eq "$FM_HOME/projects/private-app/tasks" "$(field private-app tasks)" "private specs are external"
assert_eq "$FM_HOME/projects/private-app/state" "$(field private-app state)" "private records are external"
assert_eq "$FM_HOME/projects/private-app/worktrees" "$(field private-app worktrees)" "worktrees are siblings of clone"
assert_eq "$eng" "$(field self root)" "self clone root is unchanged"
assert_eq "$eng/state" "$(field self state)" "self state is unchanged"
assert_eq "$eng/state/worktrees" "$(field self worktrees)" "self worktrees are unchanged"
assert_eq 65 "$(FM_HOME="$eng/nested" field private-app root >/dev/null 2>&1; echo $?)" "nested home is refused before mutation"
mkdir -p "$t/home/projects"
ln -s "$eng" "$t/home/projects/private-app"
assert_eq 65 "$(field private-app root >/dev/null 2>&1; echo $?)" "project symlink escape is refused"
rm "$t/home/projects/private-app"
assert_eq 65 "$(field ../escape root >/dev/null 2>&1; echo $?)" "traversal name is refused"
mkdir -p "$FM_HOME/projects/private-app/tasks" "$FM_HOME/projects/private-app/worktrees"
ln -s "$eng/config.yaml" "$FM_HOME/projects/private-app/tasks/T-001.json"
assert_eq 65 "$(field private-app tasks >/dev/null 2>&1; echo $?)" "task record symlink escape is refused"
rm "$FM_HOME/projects/private-app/tasks/T-001.json"
ln -s "$eng/config.yaml" "$FM_HOME/projects/private-app/worktrees/T-001.pid"
assert_eq 65 "$(field private-app worktrees >/dev/null 2>&1; echo $?)" "worktree owner symlink escape is refused"
assert_ok "test ! -e '$eng/state'" "resolution writes no engine records"
# Storage compatibility is independent of external path validation.
mkdir -p "$t/plain"
printf 'vendor: mock\n' > "$t/plain/config.yaml"
storage() { bash -c '. "$1/bin/fm-config.sh"; fm_storage_init "$2" || exit $?; printf "%s|%s" "$FM_EXTERNAL" "$FM_STATE_DIR"' _ "$ROOT" "$1"; }
assert_eq "0|$t/plain/state" "$(FM_PROJECT=example-app storage "$t/plain")" "no registry keeps ambient project on self storage"
sed '/default_project:/d' "$eng/config.yaml" > "$t/config"; mv "$t/config" "$eng/config.yaml"
assert_eq "0|$eng/state" "$(storage "$eng")" "unnamed registry uses its self entry"
printf 'projects: broken\n' > "$t/plain/config.yaml"
assert_eq "0|$t/plain/state" "$(storage "$t/plain" 2>/dev/null)" "unnamed malformed registry preserves self storage"
# Record readers must work with no shell in PATH and never launch a resolver.
python3 - "$ROOT" "$t" <<'PYTHON'
import importlib.util, os, pathlib, subprocess, sys
spec = importlib.util.spec_from_file_location('paths', pathlib.Path(sys.argv[1]) / 'bin/lib/fm_project_paths.py')
paths = importlib.util.module_from_spec(spec); spec.loader.exec_module(paths)
root = pathlib.Path(sys.argv[2]) / 'plain'
subprocess.check_output = lambda *a, **k: (_ for _ in ()).throw(AssertionError('record routing spawned a process'))
subprocess.run = subprocess.check_output
os.environ.pop('FM_PROJECT', None)
assert paths.record_root(root) == root.resolve(), 'malformed self config must not throw'
(root / 'config.yaml').unlink()
assert paths.record_root(root) == root.resolve(), 'missing config must not throw'
(root / 'config.yaml').write_text('vendor: mock\n')
os.environ['FM_PROJECT'] = 'old-self-name'
assert paths.record_root(root) == root.resolve(), 'no registry preserves ambient self name'
engine = pathlib.Path(sys.argv[2]) / 'engine'
(pathlib.Path(os.environ['FM_HOME']) / 'projects/private-app/worktrees/T-001.pid').unlink()
os.environ['FM_PROJECT'] = 'private-app'
assert paths.record_root(engine) == pathlib.Path(os.environ['FM_HOME']) / 'projects/private-app', 'external records resolve without a shell'
store = pathlib.Path(os.environ['FM_HOME']) / 'projects/private-app'
(store / 'state').mkdir()
(store / 'state/runs').symlink_to(root, target_is_directory=True)
try:
    paths.record_root(engine)
except ValueError:
    pass
else:
    raise AssertionError('routing links must be refused without spawning a validator')
(store / 'state/runs').unlink()
(engine / 'state/projects/private-app').mkdir(parents=True)
try:
    paths.record_root(engine)
except ValueError:
    pass
else:
    raise AssertionError('legacy records still require approved migration')
(engine / 'state/projects/private-app').rmdir()
os.environ['FM_PROJECT'] = 'unknown'
try:
    paths.record_root(engine)
except ValueError:
    pass
else:
    raise AssertionError('explicit unknown project must be refused')
PYTHON
assert_eq 0 "$?" "Python record routing needs no shell and preserves self and external boundaries"
# A reader may exist but be unusable, as in the hook-guidance fixture.
python3 - "$ROOT" "$t" <<'PYTHON'
import importlib.util, os, pathlib, sys
source = pathlib.Path(sys.argv[1]) / 'bin/lib/fm_project_paths.py'
helpers = ('_config_lines', '_config_key', '_indent', '_project_scalar')
usable = {name: f'def {name}(*args): return None\n' for name in helpers}
cases = {'stub': 'pass\n', 'import-error': 'raise ImportError("reader unavailable")\n',
         'import-runtime': 'raise RuntimeError("reader unavailable")\n',
         'syntax': 'def broken(\n'}
for missing in helpers:
    cases['missing-' + missing] = ''.join(code for name, code in usable.items() if name != missing)
for failing in helpers:
    # Each helper fails only when used, after the reader has loaded correctly.
    good = {
        '_config_lines': 'def _config_lines(*args): return []\n',
        '_config_key': 'def _config_key(lines, key): return ("", ["  self:"]) if key == "projects" else (".", [])\n',
        '_indent': 'def _indent(*args): return 2\n',
        '_project_scalar': 'def _project_scalar(*args): return "."\n',
    }
    good[failing] = f'def {failing}(*args): raise RuntimeError("reader failed")\n'
    cases['failing-' + failing] = ''.join(good.values())
for case, reader in cases.items():
    engine = pathlib.Path(sys.argv[2]) / case
    (engine / 'bin/lib').mkdir(parents=True)
    module_file = engine / 'bin/lib/fm_project_paths.py'
    module_file.write_text(source.read_text())
    (engine / 'bin/fm-herdr.py').write_text(reader)
    spec = importlib.util.spec_from_file_location('paths_' + case, module_file)
    paths = importlib.util.module_from_spec(spec); spec.loader.exec_module(paths)
    for selected, external in (('', ''), ('firstmate-workflow', ''), ('custom-self', '0')):
        os.environ['FM_PROJECT'], os.environ['FM_EXTERNAL'] = selected, external
        assert paths.record_root(engine) == engine.resolve(), (case, selected, 'self must survive unusable reader')
        assert paths.record_root(engine) == engine.resolve(), (case, 'failed import must not poison the cache')
    for external in ('', '1'):
        os.environ['FM_PROJECT'], os.environ['FM_EXTERNAL'] = 'private-app', external
        try:
            paths.record_root(engine)
        except ValueError:
            pass
        else:
            raise AssertionError((case, external, 'explicit external selection must fail closed'))
PYTHON
assert_eq 0 "$?" "unusable registry readers preserve self routing and refuse explicit external routing"
safe_rm_rf "$t"
finish
