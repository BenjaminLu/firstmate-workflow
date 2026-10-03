"""Find inline Python without parsing unrelated shell syntax.

This is a source guard, not a bash parser: inspect Python command positions,
quoted -c operands and heredocs. Recognize simple literal assignments so the
base launchers' read/cat payloads remain measurable. Unknown forms are ignored.
"""
import re


_QUOTED = r"(?:'[^']*'|\"(?:\\[\s\S]|[^\"\\])*\")"
_NAME = r'[A-Za-z_]\w*'
# Match the whole interpreter word, including quoted command lookup. Python
# can also be an argument to a sandbox tool or an element of a command array.
_PYTHON = r'(?:[^\s;|&()\'"`$]+/)?python[0-9.]*'
_LOOKUP = r'\$\([ \t]*command[ \t]+-v[ \t]+' + _PYTHON + r'[ \t]*\)'
_REFERENCE = r'\$(?:' + _NAME + r'|\{' + _NAME + r'\})'
_INTERPRETER = '(?:' + '|'.join((_LOOKUP, _PYTHON, _REFERENCE)) + ')'
_INTERPRETER_WORD = '(?:"' + _INTERPRETER + '"|\'' + _PYTHON + "'|" + _INTERPRETER + ')'
_COMMAND = re.compile(r'(?:^|[ \t;|&(`])(' + _INTERPRETER_WORD + r')(?=[ \t]|$)')
_ASSIGN = re.compile(r'[ \t]*(' + _NAME + r')=(' + _INTERPRETER_WORD + r')(?=[ \t\n;]|$)')
_HEREDOC = re.compile(r'''(?<!<)<<(-?)[ \t]*(['"]?)(\w+)\2(?![\w'"<])''')
_SPACE = r'(?:[ \t]|\\\n)'
_INLINE = re.compile(_SPACE + r'*(?:-[BuEIsS]' + _SPACE + r'+)*-c'
                     + _SPACE + r'+(' + _QUOTED + r')')
_LITERAL = re.compile(r'[ \t]*(' + _NAME + r')=(' + _QUOTED + r')(?=[ \t\n;]|$)')
_READ = re.compile(r'\bread\b[^\n]*[ \t](' + _NAME + r')[ \t]*$')
_CAT = re.compile(r'[ \t]*(' + _NAME + r')=\$\([ \t]*cat[ \t]*$')
_VARIABLE = re.compile(r'^\$(?:(' + _NAME + r')|\{(' + _NAME + r')\})$')


def is_python(word, variables):
    if word[:1] in ("'", '"'):
        word = word[1:-1]
    reference = _VARIABLE.fullmatch(word)
    if reference:
        word = variables.get(reference[1] or reference[2], '')
    return re.fullmatch(_PYTHON + '|' + _LOOKUP, word) is not None


def python_commands(line, variables):
    for command in _COMMAND.finditer(line):
        if is_python(command[1], variables):
            yield command


def heredoc_body(source, start, marker, strip_tabs):
    """Return body and end offset, or None for an unclassified document."""
    body = []
    for line in source[start:].splitlines(keepends=True):
        start += len(line)
        value = line.rstrip('\n')
        if strip_tabs:
            value = value.lstrip('\t')
        if value == marker:
            return '\n'.join(body), start
        body.append(value)
    return None


def embedded_programs(source):
    variables = {}
    cursor = 0
    while cursor < len(source):
        end = source.find('\n', cursor)
        end = len(source) if end < 0 else end + 1
        while source[cursor:end].endswith('\\\n') and end < len(source):
            following = source.find('\n', end)
            end = len(source) if following < 0 else following + 1
        # Preserve offsets and original quoted program line spans; only the
        # command-position/marker search needs a joined logical shell line.
        line = source[cursor:end].replace('\\\n', '  ')
        if line.lstrip().startswith('#'):
            cursor = end
            continue
        assignment = _ASSIGN.match(source, cursor)
        if assignment and is_python(assignment[2], variables):
            word = assignment[2]
            variables[assignment[1]] = word[1:-1] if word[:1] in ("'", '"') else word
            cursor = assignment.end()
            continue
        literal = _LITERAL.match(source, cursor)
        if literal and '$(' not in literal[2] and '`' not in literal[2]:
            variables[literal[1]] = literal[2][1:-1]
            cursor = literal.end()
            continue
        document = _HEREDOC.search(line)
        if document:
            captured = heredoc_body(source, end, document[3], document[1] == '-')
            if captured is not None:
                body, after = captured
                prefix = line[:document.start()]
                if any(python_commands(prefix, variables)):
                    yield body
                else:
                    assignment = _READ.search(prefix) or _CAT.fullmatch(prefix)
                    if assignment:
                        variables[assignment[1]] = body
                cursor = after
                continue
        # Only inspect arguments immediately following an actual Python word.
        # Module invocations and anything we cannot classify need no action.
        for command in python_commands(line, variables):
            inline = _INLINE.match(source, cursor + command.end())
            if inline is None:
                continue
            program = inline[1][1:-1]
            reference = _VARIABLE.fullmatch(program)
            if reference:
                program = variables.get(reference[1] or reference[2], '')
            if program:
                yield program
            end = max(end, inline.end())
        cursor = end
