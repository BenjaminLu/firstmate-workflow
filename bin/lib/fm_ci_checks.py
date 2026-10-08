"""Fast Python checks for ci.sh."""

import sys


def variable_boundary():
    from pathlib import Path
    import re
    import sys

    pattern = re.compile(rb'\$[A-Za-z_][A-Za-z0-9_]*[\x80-\xff]')
    failed = False
    for root in (Path('bin'), Path('tests'), Path('.githooks')):
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

def shell_files(root):
    """Yield shell sources in the three lint roots, excluding binary/lint data."""
    import re

    for directory in ('bin', 'tests', '.githooks'):
        for path in sorted((root / directory).rglob('*')):
            if not path.is_file():
                continue
            data = path.read_bytes()
            if b'\0' in data or re.search(rb'^# fm:lint-source', data, re.M):
                continue
            first = data.split(b'\n', 1)[0]
            if path.suffix == '.sh' or re.match(
                    rb'^#!\s*(?:\S*/)?(?:bash|sh)(?:\s|$)', first) or re.match(
                    rb'^#!\s*\S*/env\s+(?:-S\s+)?(?:bash|sh)(?:\s|$)', first):
                yield path


def portability(check, message):
    from pathlib import Path
    import re

    root = Path(sys.argv[2])
    failed = False
    for path in shell_files(root):
        previous = ''
        for number, line in enumerate(path.read_bytes().decode(
                'utf-8', errors='surrogateescape').split('\n'), 1):
            allowed = re.fullmatch(r'# fm:allow-portability: (?=.*\S).*', previous)
            if not allowed and not line.lstrip().startswith('#') and check(line):
                print(f'{path.relative_to(root)}:{number}: {message}')
                failed = True
            previous = line
    sys.exit(1 if failed else 0)


def patsub_amp():
    import re

    # Keep the established diagram-suite expression, now applied recursively.
    pattern = re.compile(r'\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?/[/#%]?[^}/]*/[^}]*&')
    portability(pattern.search,
                'a literal & in a pattern replacement differs between bash 3.2 and 5.2')


def has_brace_json(line):
    """Read each quoted substitution on this line, respecting quoted parentheses."""
    import re

    for opening in re.finditer(r'"\$\(', line):
        index = opening.end()
        depth = 1
        quote = None
        word = []
        while index < len(line) and depth:
            char = line[index]
            if quote == "'":
                if char == "'":
                    quote = None
            elif char == '\\' and index + 1 < len(line):
                if quote == '"':
                    word.extend(line[index:index + 2])
                index += 1
            elif quote == '"':
                if char == '"':
                    text = ''.join(word)
                    if '\\"' in text and re.search(r'\{[^}]*,[^}]*\}', text):
                        return True
                    quote = None
                else:
                    word.append(char)
            elif char in "\"'":
                quote = char
                word = []
            elif char == '(':
                depth += 1
            elif char == ')':
                depth -= 1
            index += 1
    return False


def brace_json():
    portability(has_brace_json,
                'escaped JSON with a comma inside "$(...)" is brace-expanded by bash 3.2; '
                'build it with jq or outside the substitution')


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


def coverage():
    """Check that shard assignments cover every bash suite exactly once."""
    from collections import Counter
    from glob import escape, glob
    from pathlib import Path
    import re
    import sys

    directory, root = map(Path, sys.argv[2:])
    files = sorted(Path(path) for path in glob(escape(str(directory)) + "/*.txt") if Path(path).is_file())
    expected = {Path(path).relative_to(root).as_posix()
                for path in glob(escape(str(root)) + "/tests/*.test.sh")}
    counts = Counter()
    shards = set()
    total = None
    errors = []
    if not files:
        errors.append(f"no assignment files in {sys.argv[2]}")
    for path in files:
        with path.open(newline="") as stream:
            lines = stream.read().split("\n")
        match = re.fullmatch(r"# shard ([1-9][0-9]*)/([1-9][0-9]*)", lines[0])
        if not match:
            errors.append(f"bad header: {path}")
            continue
        index, size = map(int, match.groups())
        if index > size:
            errors.append(f"shard out of range: {path}")
            continue
        if total is None:
            total = size
        if size != total:
            errors.append(f"shard count disagrees: {path}")
        if index in shards:
            errors.append(f"duplicate shard {index}: {path}")
        shards.add(index)
        counts.update(line for line in lines[1:] if line)
    if total is not None:
        for index in range(1, total + 1):
            if index not in shards:
                errors.append(f"missing shard {index}")
    for path in sorted(expected | counts.keys()):
        if path not in expected:
            errors.append(f"unknown suite: {path}")
        if counts[path] == 0:
            errors.append(f"suite in no shard: {path}")
        elif counts[path] > 1:
            errors.append(f"suite in {counts[path]} shards: {path}")
    if errors:
        for error in errors:
            print(f"ci: coverage: {error}")
        sys.exit(1)
    print(f"ci: coverage: {len(expected)} suites, each in exactly one of {total} shards")


if __name__ == "__main__":
    {"variable-boundary": variable_boundary, "compile": compile_modules,
     "private-fetch": private_fetch, "design-layout": design_layout,
     "coverage": coverage, "patsub-amp": patsub_amp, "brace-json": brace_json}[sys.argv[1]]()
