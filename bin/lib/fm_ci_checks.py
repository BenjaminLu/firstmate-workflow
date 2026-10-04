"""Fast Python checks for ci.sh."""

import sys


def variable_boundary():
    from pathlib import Path
    import re
    import sys

    pattern = re.compile(rb'\$[A-Za-z_][A-Za-z0-9_]*[\x80-\xff]')
    failed = False
    for root in (Path('bin'), Path('tests')):
        for path in sorted(root.rglob('*')):
            if not path.is_file():
                continue
            content = path.read_bytes()
            if b'\0' in content:
                continue
            for number, line in enumerate(content.split(b'\n'), 1):
                if pattern.search(line):
                    print(f'{path}:{number}: brace the variable before non-ASCII text')
                    failed = True
    sys.exit(1 if failed else 0)

def compile_modules():
    """Compile every library module, keeping all bytecode in CI's scratch tree."""
    from pathlib import Path
    import py_compile
    import tempfile

    failed = False
    with tempfile.TemporaryDirectory(prefix='py-compile-', dir=sys.argv[2]) as cache:
        for index, path in enumerate(sorted(Path('bin/lib').rglob('*.py'))):
            try:
                py_compile.compile(str(path), cfile=str(Path(cache) / f'{index}.pyc'),
                                   doraise=True)
            except py_compile.PyCompileError as error:
                print(error, file=sys.stderr)
                failed = True
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    {"variable-boundary": variable_boundary, "compile": compile_modules}[sys.argv[1]]()
