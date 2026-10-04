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


def private_fetch():
    """Reject shared fetch pseudo-refs in executable text beneath a root."""
    from pathlib import Path
    import shlex
    import sys

    forbidden = 'FETCH' + '_HEAD'
    bad = False
    root = Path(sys.argv[2])
    for path in sorted((root / 'bin').rglob('*')):
        if not path.is_file():
            continue
        data = path.read_bytes()
        if b'\0' in data:
            continue
        try:
            text = data.decode('utf-8')
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if forbidden not in line or line.lstrip().startswith('#'):
                continue
            try:
                active = ' '.join(shlex.split(line, comments=True))
            except ValueError:
                # Incomplete quoted snippets are still source, never an exemption.
                active = line
            if forbidden in active:
                print(f'{path.relative_to(root)}:{number}: shared fetch pseudo-ref is forbidden')
                bad = True
    sys.exit(1 if bad else 0)


def design_layout():
    """Every ### in the last `## N.` section of the design is numbered N.x (T-189).

    An unnumbered ### appended there lands in the same final hunk as every
    other append, so parallel branches conflict; numbered homes are mid-file.
    Subsequent numbered ## sections must advance by exactly one; an unnumbered
    ## after the last numbered section cannot create a new tail home either.
    Fenced code is skipped the way fm_prompt_context.anchors() skips it.
    """
    from pathlib import Path
    import re

    path = Path(sys.argv[2])
    if not path.exists():
        return
    headings, fence = [], None
    for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        marker = re.match(r'^\s*(`{3,}|~{3,})', line)
        if marker:
            token = marker.group(1)
            if fence is None:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = None
            continue
        match = re.match(r'^(#{1,6})\s+(.+)', line)
        if match and fence is None:
            headings.append((number, len(match[1]), match[2]))
    last = None
    previous = None
    bad = False
    for index, (number, level, text) in enumerate(headings):
        match = re.match(r'^(\d+)\.', text) if level == 2 else None
        if match:
            current = int(match[1])
            if previous is not None and current != previous + 1:
                print(f'{path}:{number}: ## {text} - after numbered section §{previous}, '
                      f'a new ## heading must be numbered {previous + 1}.; '
                      'put new material in its numbered home')
                bad = True
            previous = current
            last = index
    if last is not None:
        section = re.match(r'^(\d+)\.', headings[last][2])[1]
        for number, level, text in headings[last + 1:]:
            if level == 2:
                print(f'{path}:{number}: ## {text} - after the last numbered section, §{section}, '
                      f'a new ## heading must be numbered {int(section) + 1}.; '
                      'put new material in its numbered home')
                bad = True
            if level == 3 and not text.startswith(section + '.'):
                print(f'{path}:{number}: ### {text} - in the last section, §{section}, a ### '
                      f'heading starts with "{section}."; put new material in its numbered home')
                bad = True
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    {"variable-boundary": variable_boundary, "compile": compile_modules,
     "private-fetch": private_fetch, "design-layout": design_layout}[sys.argv[1]]()
