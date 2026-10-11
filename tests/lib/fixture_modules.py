#!/usr/bin/env python3
"""Copy a declared set of engine modules into a test fixture (T-279).

  fixture_modules.py [--root <dir>] list <set>         the repository paths it would copy
  fixture_modules.py [--root <dir>] copy <set> <dest>  copy them into <dest>

The sets are declared in tests/lib/fixture-modules.json, beside this file. A
set copies every file it declares, plus every bin/lib Python module that a
copied Python file imports when it loads: an import the ast module finds
outside any function body, a top-level if or try included, followed
transitively. An import inside a function body is lazy and is not followed,
so code that falls back when an optional module is missing still does.

A file under bin/lib/ lands in <dest>/lib/; any other file under bin/ lands
in <dest>/. A path the set lists under keep_existing is not overwritten when
<dest> already holds it. --root names the tree to copy from; it defaults to
the repository this file lives in.
"""
import ast
import json
from pathlib import Path
import shutil
import sys

HERE = Path(__file__).resolve().parent
REGISTRY = HERE / 'fixture-modules.json'


class Refused(Exception):
    pass


def load_sets():
    data = json.loads(REGISTRY.read_text(encoding='utf-8'))
    if not isinstance(data, dict) or data.get('version') != 1 or not isinstance(data.get('sets'), dict):
        raise Refused(f'{REGISTRY}: not a version 1 registry of sets')
    return data['sets']


def declared(sets, name, seen=()):
    """(files, keep_existing) of a set, its included sets first."""
    if name not in sets:
        raise Refused(f'no such set: {name}')
    if name in seen:
        raise Refused(f'set {name} includes itself')
    entry, files, keep = sets[name], [], []
    for inner in entry.get('include', []):
        more, kept = declared(sets, inner, seen + (name,))
        files += more
        keep += kept
    files += entry.get('files', [])
    keep += entry.get('keep_existing', [])
    return files, keep


def load_imports(path):
    """The top module names a Python file imports when it loads."""
    tree = ast.parse(path.read_text(encoding='utf-8'), filename=str(path))
    names, todo = [], list(tree.body)
    while todo:
        node = todo.pop(0)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
            continue
        if isinstance(node, ast.Import):
            names += [alias.name.split('.')[0] for alias in node.names]
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            names.append(node.module.split('.')[0])
        todo += list(ast.iter_child_nodes(node))
    return names


def closure(root, name):
    files, keep = declared(load_sets(), name)
    out = []
    for rel in files:
        if not (rel.startswith('bin/') and (root / rel).is_file()):
            raise Refused(f'set {name} declares {rel}, which is not a file under bin/')
        if rel not in out:
            out.append(rel)
    todo = [rel for rel in out if rel.endswith('.py')]
    while todo:
        rel = todo.pop(0)
        for module in load_imports(root / rel):
            dep = f'bin/lib/{module}.py'
            if dep not in out and (root / dep).is_file():
                out.append(dep)
                todo.append(dep)
    return out, keep


def landing(dest, rel):
    if rel.startswith('bin/lib/'):
        return dest / 'lib' / rel[len('bin/lib/'):]
    return dest / rel[len('bin/'):]


def main(argv):
    root = HERE.parent.parent
    if argv[:1] == ['--root'] and len(argv) >= 2:
        root, argv = Path(argv[1]), argv[2:]
    try:
        if len(argv) == 2 and argv[0] == 'list':
            print('\n'.join(closure(root, argv[1])[0]))
            return 0
        if len(argv) == 3 and argv[0] == 'copy':
            files, keep = closure(root, argv[1])
            dest = Path(argv[2])
            for rel in files:
                target = landing(dest, rel)
                if rel in keep and target.exists():
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(root / rel, target)
            return 0
    except (Refused, OSError, SyntaxError, ValueError) as err:
        print(f'fixture_modules.py: {err}', file=sys.stderr)
        return 2
    print('usage: fixture_modules.py [--root <dir>] list <set> | copy <set> <dest>', file=sys.stderr)
    return 64


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
