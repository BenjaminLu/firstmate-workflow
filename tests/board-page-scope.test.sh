#!/usr/bin/env bash
# T-308: every board page script runs in a scope of its own, so no two of
# them can declare the same global name. Classic scripts share one global
# scope; a second `const t` stops that script and every script after it
# ("Identifier 't' has already been declared"). Read from the source, with
# tests/lib/page_scope.py; tests/e2e/board-page-errors.spec.ts loads the page.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import re
import sys
from pathlib import Path
sys.dont_write_bytecode = True
root = Path(sys.argv[1])
sys.path.insert(0, str(root / 'tests/lib'))
import page_scope  # tests/lib/page_scope.py

checks = []
def check(name, passed, detail=''):
    checks.append((name, passed, detail))

# the checker itself: it refuses the collision it exists for, and passes
# each allowed shape, so a checker that passes everything is red here
bad = ['const t = (k) => k;\n', 'function render() {}\n', 'let a, b;\n(() => {})();\n',
       '(() => {})();\nwindow.x = 1;\n', 'var TASK_GRAMMAR = 1;\n',
       'const A = (() => 1)();\nconst B = (() => 2)();\n']
check('board: the scope check refuses a top-level declaration',
      all(page_scope.check(src)[1] for src in bad),
      [src for src in bad if not page_scope.check(src)[1]])
good = {
    '(() => {\nconst t = `${"}"}` + /}/.source; window.X = t;\n})();\n': [],
    '// a comment {\nconst SHIP = (() => {\n  return { a: 1 };\n})();\n'
    'if (typeof module !== "undefined") module.exports = SHIP;\n': ['SHIP'],
    '(function () { var x = 1; })()\n(() => {})()\n': [],
}
check('board: the scope check passes a script in its own scope',
      all(page_scope.check(src) == (names, []) for src, names in good.items()),
      {src: page_scope.check(src) for src in good})

public = root / 'board/public'
html = (public / 'index.html').read_text()
scripts = {path.name: path.read_text() for path in sorted(public.glob('*.js'))}
for n, body in enumerate(page_scope.page_scripts(html), 1):
    scripts[f'index.html inline script {n}'] = body
# the board serves diagram.js with the task grammar in front of it (T-119):
# that prefix is one more declaration, of diagram.js as served
server = (root / 'board/server.ts').read_text()
prefix = re.search(r'const GRAMMAR_JS = `var ([A-Z_]+) = \(\$\{taskGrammar\.toString\(\)\}\)\(\);\\n`;', server)
check('board: the served task grammar is one declared name', prefix is not None,
      'GRAMMAR_JS changed shape; read it here again')

owners = {}
for name, src in scripts.items():
    names, problems = page_scope.check(src)
    check(f'board: {name} keeps its own scope', not problems, problems)
    shared = names + page_scope.window_names(src)
    if name == 'diagram.js' and prefix:
        shared.append(prefix.group(1))
    for global_name in shared:
        owners.setdefault(global_name, []).append(name)
check('board: no two page scripts share a global name',
      all(len(set(by)) == 1 and len(by) == 1 for by in owners.values()),
      {k: v for k, v in owners.items() if len(v) > 1})
# every script the page names is one this suite read
named = re.findall(r'<script src="/?([^"]+)"', html) + re.findall(r"script\.src = '/?([^']+)'", html)
check('board: every script the page loads is checked',
      bool(named) and all(src in scripts for src in named), named)
check('board: the page has its own inline script checked',
      any(name.startswith('index.html inline') for name in scripts))

for name, passed, detail in checks:
    print(f"    {name:<52} {'ok' if passed else 'FAIL'}")
    if not passed and detail:
        print(f'      {detail}')
sys.exit(0 if all(passed for _, passed, _ in checks) else 1)
PY
