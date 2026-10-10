#!/usr/bin/env bash
# The module sets test fixtures copy (T-279): declared once in
# tests/lib/fixture-modules.json, copied by tests/lib/fixture_modules.py with
# every bin/lib module a member imports when it loads, so an import added to
# a member reaches every fixture without a registry edit.
# Helpers: tests/lib/fixture_modules.py tests/lib/fixture-modules.json
# tests/lib/config-modules.sh tests/lib/project-storage.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
modules() { python3 "$ROOT/tests/lib/fixture_modules.py" "$@"; }
work="$(safe_tmpdir)"
trap 'safe_rm_rf "$work"' EXIT

# Import every copied Python module with the destination as the only place
# outside the standard library that Python may look.
imports_cleanly() {  # imports_cleanly <dest>: prints each module that fails to import
  python3 -I - "$1" <<'PY'
import importlib.util, pathlib, sys
dest = pathlib.Path(sys.argv[1])
sys.path[:] = [str(dest / 'lib')] + [p for p in sys.path if 'site-packages' not in p and p]
sys.dont_write_bytecode = True
for path in sorted(dest.glob('*.py')) + sorted((dest / 'lib').glob('*.py')):
    spec = importlib.util.spec_from_file_location(path.stem.replace('-', '_'), path)
    try:
        spec.loader.exec_module(importlib.util.module_from_spec(spec))
    except Exception as err:  # each failure is named, not raised
        print(f'{path.name}: {type(err).__name__}: {err}')
PY
}

# --- the helpers keep their interface ------------------------------------
c="$work/config"
config_modules_fixture "$c"
assert_eq 0 "$?" "config_modules_fixture copies its set"
for f in fm_registry.py fm_config_values.py fm_config_tasks.py fm_config_runtime.py fm_ci_checks.py; do
  assert_ok "[ -f '$c/lib/$f' ]" "the config set lands bin/lib/$f in <dest>/lib/"
done
assert_eq "" "$(imports_cleanly "$c")" "every module of the config set imports from the destination alone"

p="$work/storage"
project_storage_fixture "$p"
assert_eq 0 "$?" "project_storage_fixture copies its set"
for f in fm-config.sh fm-emit.sh fm-herdr.py lib/fm_gates.json lib/fm-task-grammar.sh lib/fm_binding.py lib/fm_registry.py; do
  assert_ok "[ -f '$p/$f' ]" "the project-storage set lands $f where it always has"
done
assert_eq "" "$(imports_cleanly "$p")" "every module of the project-storage set imports from the destination alone"
listed="$(modules list project-storage)"
held="$(cd "$p" && find . -type f)"
assert_eq "$(grep -c . <<<"$listed")" "$(grep -c . <<<"$held")" "the destination holds exactly what list prints"

# --- an existing binding stub is kept -----------------------------------
s="$work/stub"
mkdir -p "$s/lib"
printf 'STUB = True\n' > "$s/lib/fm_binding.py"
project_storage_fixture "$s"
assert_eq "STUB = True" "$(cat "$s/lib/fm_binding.py")" "an installed fm_binding.py stub is kept"
assert_ok "[ -f '$s/lib/fm_spec_pins.py' ]" "while the rest of the set is copied around it"

# --- the import closure, in a temporary copy of bin/ --------------------
r="$work/repo"
mkdir -p "$r"
cp -R "$ROOT/bin" "$r/bin"
printf 'import fm_probe_deeper\n' > "$r/bin/lib/fm_probe_added.py"
printf 'VALUE = 1\n' > "$r/bin/lib/fm_probe_deeper.py"
printf 'VALUE = 2\n' > "$r/bin/lib/fm_probe_lazy.py"
cat >> "$r/bin/lib/fm_registry.py" <<'PY'
try:
    import fm_probe_added
except ImportError:
    fm_probe_added = None


def _later():
    import fm_probe_lazy
    return fm_probe_lazy
PY
listed="$(modules --root "$r" list config)"
assert_contains "$listed" "bin/lib/fm_probe_added.py" "a module added to a member's top-level imports is copied without a registry edit"
assert_contains "$listed" "bin/lib/fm_probe_deeper.py" "and what it imports in turn"
assert_lacks "$listed" "fm_probe_lazy" "a lazy import inside a function is not followed"
d="$work/closure"
modules --root "$r" copy config "$d"
assert_ok "[ -f '$d/lib/fm_probe_added.py' ] && [ -f '$d/lib/fm_probe_deeper.py' ]" "copy brings the added imports into <dest>/lib/"
assert_fail "[ -e '$d/lib/fm_probe_lazy.py' ]" "and leaves the lazy one behind"
assert_eq "" "$(imports_cleanly "$d")" "the copied set still imports from the destination alone"

finish
