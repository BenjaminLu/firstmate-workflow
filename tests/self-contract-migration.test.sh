#!/usr/bin/env bash
# Exercise the shipped self contract through session, gate 5 and CI readers.
set -uo pipefail
for key in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do unset "$key" || true; done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/lib/spec-pins.sh"
isolate_tmpdir
d="$(safe_tmpdir)"
stubs="$(safe_tmpdir)"
# Only the dependency installers are stubbed. The contract commands, template,
# environment and setup working directory still pass through the real readers.
cat > "$stubs/bun" <<'STUB'
#!/usr/bin/env bash
[ "$*" = 'install --frozen-lockfile' ] || exit 90
touch installed
STUB
cat > "$stubs/bunx" <<'STUB'
#!/usr/bin/env bash
[ "$*" = 'playwright install chromium' ] || exit 91
touch browser-installed
STUB
chmod +x "$stubs/bun" "$stubs/bunx"
export PATH="$stubs:$PATH" FM_GATE_LOCK="$d/gate.lock"
cp "$ROOT/config.yaml" "$d/config.yaml"
python3 - "$ROOT" "$d" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys
from unittest.mock import patch
sys.dont_write_bytecode = True
os.environ['HERDR_ENV'] = '0'
root, repo = map(Path, sys.argv[1:])
sys.path.insert(0, str(root / 'bin/lib'))
spec = importlib.util.spec_from_file_location('herdr', root / 'bin/fm-herdr.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
from fm_spec_pins import contract
text = (repo / 'config.yaml').read_text()
assert '\n    project:' in text and '\nproject:' not in text, 'shipped contract must live only in registry'
expected = {
    'setup': 'bun install --frozen-lockfile && bunx playwright install chromium',
    'check': 'bin/ci.sh', 'check_env': {'FM_CI_MAX_SECONDS': '600'},
    'tests': ['tests/**', '*.test.*', '*.spec.*'],
    'test': 'case {file} in *.test.sh) bash {file} ;; esac',
    'docs': ['design/**', 'README.md', 'LICENSE', 'CODE_OF_CONDUCT.md',
             'CONTRIBUTING.md', 'SECURITY.md', '.github/ISSUE_TEMPLATE/**',
             '.github/pull_request_template.md'],
}
assert m.project_contract(repo / 'config.yaml') == expected
assert contract(text, 'firstmate-workflow') == expected
with patch.object(m, 'record_root', return_value=repo):
    start = m.project_report(repo, run_setup=True)
    assert start['ready'] and start['setup']['exit'] == 0, start
    for name in ('installed', 'browser-installed'):
        assert (repo / name).exists()
        (repo / name).unlink()
    status = m.project_report(repo)
    assert status['ready'] and status['declared'] == start['declared'], status
    assert not (repo / 'installed').exists() and not (repo / 'browser-installed').exists()
    (repo / 'config.yaml').write_text(text + '\nproject:\n  check: false\n')
    assert not m.project_report(repo)['ready'], 'session must refuse duplicate contracts'
    try:
        contract((repo / 'config.yaml').read_text(), 'firstmate-workflow')
    except ValueError:
        pass
    else:
        raise AssertionError('pin reader must refuse duplicate contracts')
(repo / 'config.yaml').write_text(text)
PY
assert_eq 0 "$?" "shipped registry contract is unchanged and serves session start/status"
git -C "$d" init -q -b main
git -C "$d" config user.email a@b.c
git -C "$d" config user.name fixture
mkdir -p "$d/design/tasks" "$d/bin" "$d/tests"
echo old > "$d/bin/value"
echo design > "$d/design/design.md"
echo '{"id":"T-X","scope":["bin/**","tests/**"]}' > "$d/design/tasks/T-X.json"
printf 'state/\ngate.lock\n' > "$d/.gitignore"
git -C "$d" add -A; git -C "$d" commit -qm base
seed_spec_pin "$d" T-X
git -C "$d" checkout -qb work
echo new > "$d/bin/value"
cat > "$d/tests/value.test.sh" <<'TEST'
test "$FM_CI_MAX_SECONDS" = 600 && test -f installed && test -f browser-installed && test "$(cat bin/value)" = new
TEST
git -C "$d" add -A; git -C "$d" commit -qm feature
run_gate() { "$ROOT/bin/fm-gate.sh" --repo "$d" --task T-X --branch work --only 5 > "$d.gate" 2>&1; }
assert_ok run_gate "gate 5 runs the shipped registry contract snapshot"
run_failfirst() { (cd "$d" && bash "$ROOT/bin/fm-failfirst.sh" main) > "$d.report" 2>&1; }
assert_ok run_failfirst "standalone fail-first runs the shipped registry contract"
printf '\nproject:\n  check: false\n' >> "$d/config.yaml"
git -C "$d" add config.yaml; git -C "$d" commit -qm duplicate
assert_fail run_failfirst "standalone fail-first refuses duplicate self contract locations"
assert_contains "$(cat "$d.report")" 'project block does not read' "duplicate refusal comes from contract parsing"
finish
