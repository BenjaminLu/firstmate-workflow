"""Read inline Python from shell words and here-documents, without executing shell.

This guard follows literal assignments used by python3 -c, including cat and read
here-documents. External file reads contain no embedded program to measure.
"""
import re
import shlex


# Keep quoted newlines inside a word; only unquoted shell syntax separates it.
_WORD = re.compile(r'''(?:[^\s'"\\;|&()<>]+|'[^']*'|"(?:\\.|[^"\\])*"|\\[\s\S])+''')
_OPERATOR = re.compile(r'<<<|<<-|<<|[;|&()<>\n]')
_VARIABLE = re.compile(r'^\$(?:([A-Za-z_]\w*)|\{([A-Za-z_]\w*)\})$')
_ASSIGNMENT = re.compile(r'^([A-Za-z_]\w*)=(.*)$', re.S)


def shell_tokens(source):
    """Yield (kind, value), treating heredoc bodies as data, never shell."""
    cursor = 0
    pending = []
    delimiter = None
    while cursor < len(source):
        char = source[cursor]
        if char in ' \t\r':
            cursor += 1
            continue
        if source.startswith('\\\n', cursor):
            cursor += 2
            continue
        if char == '#':
            end = source.find('\n', cursor)
            cursor = len(source) if end < 0 else end
            continue
        operator = _OPERATOR.match(source, cursor)
        if operator:
            value = operator[0]
            cursor = operator.end()
            if value in ('<<', '<<-'):
                delimiter = value
            elif value == '\n':
                for marker, strip_tabs in pending:
                    body = []
                    while cursor < len(source):
                        end = source.find('\n', cursor)
                        end = len(source) if end < 0 else end
                        line = source[cursor:end]
                        cursor = min(end + 1, len(source))
                        if strip_tabs:
                            line = line.lstrip('\t')
                        if line == marker:
                            break
                        body.append(line)
                    yield 'heredoc', '\n'.join(body)
                pending.clear()
            yield 'operator', value
            continue
        word = _WORD.match(source, cursor)
        if word is None:
            raise ValueError('unrecognized shell word at ' + str(cursor))
        cursor = word.end()
        value = shlex.split(word[0], posix=True)[0]
        if delimiter is not None:
            pending.append((value, delimiter == '<<-'))
            delimiter = None
        yield 'word', value


def embedded_programs(source, inherited=None):
    variables = dict(inherited or {})
    command = []
    assignment = None

    def resolve(value):
        reference = _VARIABLE.fullmatch(value)
        if reference:
            return variables.get(reference[1] or reference[2], '')
        return value

    for kind, value in shell_tokens(source):
        if kind == 'heredoc':
            if 'python3' in command:
                yield value
            elif 'read' in command and '<<' in command:
                variables[command[command.index('<<') - 1]] = value
            elif 'read' in command and '<<-' in command:
                variables[command[command.index('<<-') - 1]] = value
            elif assignment is not None and 'cat' in command:
                variables[assignment] = value
            continue
        if kind == 'operator':
            if value in ('<<', '<<-'):
                command.append(value)
            if value in ('\n', ';', '|', '&'):
                command = []
                assignment = None
            continue
        match = _ASSIGNMENT.fullmatch(value)
        if match:
            assignment = match[1]
            variables[assignment] = match[2]
        expression = match[2] if match else value
        if expression.startswith('$(') and expression.endswith(')'):
            # shlex preserves the inner single quotes of a double-quoted
            # command substitution, so its -c argument remains one word.
            yield from embedded_programs(expression[2:-1], variables)
        # A python3 command may be wrapped by env or command substitutions.
        # Only its -c operand is source; other operands are program arguments.
        if len(command) >= 2 and command[-1] == '-c' and 'python3' in command:
            yield resolve(value)
            command = []
        command.append(value)
