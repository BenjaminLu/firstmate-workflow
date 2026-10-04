#!/usr/bin/env bash
# The shell API must delegate Python programs to compile-checked modules.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import shlex
import sys
import subprocess
import tempfile

root = Path(sys.argv[1])
for name in ('bin/fm-config.sh', 'bin/ci.sh'):
    source = (root / name).read_text()
    for number, line in enumerate(source.splitlines(), 1):
        if line.lstrip().startswith('#'):
            continue
        assert not re.search(r'\bpython3\s+(?:-\s+[^\n]*?)?<<', line), (
            f'{name}:{number}: embedded Python heredoc must move to bin/lib')
    for match in re.finditer(r'\bpython3\s+-c\s+', source):
        lexer = shlex.shlex(source[match.end():], posix=True)
        lexer.whitespace_split = True
        program = next(lexer)
        assert len(program.splitlines()) <= 5, (
            f'{name}: embedded Python -c program exceeds five lines')
print('PASS: shell entrypoints contain no embedded Python programs')

with tempfile.TemporaryDirectory() as temporary:
    tree = Path(temporary)
    library = tree / 'bin/lib/nested'
    library.mkdir(parents=True)
    module = library / 'example.py'
    module.write_text('answer = 42\n')
    command = [sys.executable, str(root / 'bin/lib/fm_ci_checks.py'), 'compile', str(tree)]
    result = subprocess.run(command, cwd=tree, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert not list(tree.rglob('*.pyc')), 'compilation must leave no target bytecode'
    module.write_text('def broken(:\n')
    result = subprocess.run(command, cwd=tree, capture_output=True, text=True)
    assert result.returncode == 1, 'nested module syntax errors must fail compilation'
    assert 'example.py' in result.stderr, result.stderr
    assert not list(tree.rglob('*.pyc')), 'failed compilation must clean scratch bytecode'
print('PASS: recursive Python compilation rejects invalid modules without target artifacts')
PY
