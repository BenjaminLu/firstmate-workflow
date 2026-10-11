#!/usr/bin/env python3
"""Read a source file the way its own language parser reads it (T-279).

  source_scan.py code --bash <path> <file>      the file without comments
  source_scan.py sh-guard --bash <path> <file>  0 when the top level exports HERDR_ENV=0
  source_scan.py py-guard <file>                0 when the module body sets HERDR_ENV to '0'

A Python file (*.py) is parsed with ast: docstrings go, every other string
stays, because a string can be a real command argument. Any other file is a
shell file, parsed by the bash named with --bash and never read as plain text:
`<bash> -n` first, then the file wrapped in a function with eval and printed
back with `declare -f`. That output is shell again, lexed as bash lexes it, so
the text of a quoted string, $'...', `...`, $(...) or heredoc of any delimiter
is never read as a command. A file that does not parse exits 2, naming the file.
heredoc_split(), for importers, also returns each heredoc body apart, so a
script a file writes can be judged as the script it is.
The parsing bash gets an empty environment, an empty PATH and no startup
files, so even a wrapper the file could close early has nothing to run.
"""
import ast
import os
import re
import subprocess
import sys
import tempfile

WRAP = '__fm_scan'
END = ': __fm_scan_end'  # keeps an all-comment file a valid function body
# Reads the file with a builtin (PATH is empty), defines the wrapper, prints it.
SCRIPT = ('IFS= read -r -d "" __fm_src < "$1"\n'
          'eval "' + WRAP + '() {\n$__fm_src\n' + END + '\n}" || exit 2\n'
          'declare -f ' + WRAP + '\n')
# One simple export of plain words, one of them HERDR_ENV=0. bash prints every
# operator with spaces round it, so a word holds none of ; & | < >.
_WORD = r"""[A-Za-z_][A-Za-z0-9_]*(=[^\s;&|<>]*)?"""
# A later HERDR_ENV= in the same export would win, so none may follow.
GUARD = re.compile(r"""export( %s)* HERDR_ENV=(0|'0'|"0")( (?!HERDR_ENV=)%s)*;?""" % (_WORD, _WORD))
# Where a printed word may end: a blank or an operator character.
_WORD_END = ' \t\n;&|<>()'


class Refused(Exception):
    pass


def bash_run(bash, *args):
    with tempfile.TemporaryDirectory(prefix='fm-scan-path.') as empty:
        return subprocess.run([bash, '--noprofile', '--norc', *args], env={'PATH': empty},
                              stdin=subprocess.DEVNULL, capture_output=True, text=True)


def shell_lines(bash, path, bodies=None):
    """The body of the wrapper, as (is code, line); a literal's text is not code,
    and a heredoc's line is None. Each heredoc body is appended to bodies."""
    if bash_run(bash, '-n', path).returncode != 0:
        raise Refused(f'{path}: bash cannot parse this file')
    done = bash_run(bash, '-c', SCRIPT, 'source_scan', path)
    lines = done.stdout.split('\n')
    if done.returncode != 0 or len(lines) < 3 or not lines[0].startswith(WRAP):
        raise Refused(f'{path}: bash cannot parse this file')
    body = lines[2:]
    while body and body[-1] == '':
        body.pop()
    # bash prints a trailing `cmd &` on one line with the command after it
    last = body[-2].rstrip() if len(body) >= 2 and body[-1] == '}' else ''
    tail = next((t for t in (END + ';', END) if last.endswith(t)), None)
    if tail is None:
        raise Refused(f'{path}: bash cannot parse this file')
    last = last[:-len(tail)].rstrip()
    return literal_lines(body[:-2] + ([last] if last.strip() else []), bodies)


def heredoc_word(text, i):
    """The delimiter of the heredoc word at text[i:], quotes removed, and its end."""
    word = ''
    while i < len(text) and text[i] in ' \t':
        i += 1
    while i < len(text) and text[i] not in _WORD_END:
        ch = text[i]
        if ch == '\\' and i + 1 < len(text):
            word, i = word + text[i + 1], i + 2
        elif ch in '\'"':
            close = text.find(ch, i + 1)
            close = len(text) if close < 0 else close
            word, i = word + text[i + 1:close], close + 1
        else:
            word, i = word + ch, i + 1
    return word, i


def literal_lines(lines, bodies=None):
    """Each printed line as (is code, line). bash's declare -f output is shell
    again, so it is lexed as bash lexes it: a line is code only when it starts
    outside every quote, $'...', `...`, $(...), $((...)), ${...} and heredoc
    body, whatever the heredoc delimiter. Anything else is a literal's text."""
    text = '\n'.join(lines)
    stack, pending, out, i, n = [], [], [], 0, len(text)
    line_code = True  # the state at the start of the current line

    def word_start(j):
        return j == 0 or text[j - 1] in ' \t\n;&|()<>'

    while i <= n:
        if i == n or text[i] == '\n':
            end = i
            begin = text.rfind('\n', 0, end) + 1
            out.append((line_code, text[begin:end]))
            i += 1
            # a heredoc body starts after the newline that ends its command
            if pending and (not stack or stack[-1][0] in ('cs', 'pe')):
                for delim, strip in pending:
                    got = []
                    while i < n:
                        stop = text.find('\n', i)
                        stop = n if stop < 0 else stop
                        body = text[i:stop]
                        out.append((None, body))
                        i = stop + 1
                        if (body.lstrip('\t') if strip else body) == delim:
                            break
                        got.append(body)
                    if bodies is not None:
                        bodies.append(''.join(line + '\n' for line in got))
                pending = []
            line_code = not stack
            continue
        ch, top = text[i], (stack[-1][0] if stack else 'code')
        two, three = text[i:i + 2], text[i:i + 3]
        if top == 'sq':
            if ch == "'":
                stack.pop()
            i += 1
        elif top in ('ansi', 'bt'):
            if ch == '\\':
                i += 2
                continue
            if ch == ("'" if top == 'ansi' else '`'):
                stack.pop()
            i += 1
        elif top == 'arith':
            if two == '))' and stack[-1][1] == 0:
                stack.pop()
                i += 2
                continue
            stack[-1][1] += {'(': 1, ')': -1}.get(ch, 0)
            i += 1
        elif top == 'dq':
            if ch == '\\':
                i += 2
            elif ch == '"':
                stack.pop()
                i += 1
            elif ch == '`':
                stack.append(['bt', 0])
                i += 1
            elif three == '$((':
                stack.append(['arith', 0])
                i += 3
            elif two == '$(':
                stack.append(['cs', 0])
                i += 2
            elif two == '${':
                stack.append(['pe', 0])
                i += 2
            else:
                i += 1
        else:  # code: the top level, or inside $(...) or ${...}
            if ch == '\\':
                i += 2
            elif ch == "'":
                stack.append(['sq', 0])
                i += 1
            elif two in ("$'", '$"'):
                stack.append(['ansi' if two == "$'" else 'dq', 0])
                i += 2
            elif ch == '"':
                stack.append(['dq', 0])
                i += 1
            elif ch == '`':
                stack.append(['bt', 0])
                i += 1
            elif three == '$((':
                stack.append(['arith', 0])
                i += 3
            elif two == '((' and word_start(i):  # an arithmetic command: its << is a shift
                stack.append(['arith', 0])
                i += 2
            elif two == '$(':
                stack.append(['cs', 0])
                i += 2
            elif two == '${':
                stack.append(['pe', 0])
                i += 2
            elif ch == '#' and top != 'pe' and word_start(i):
                stop = text.find('\n', i)
                i = n if stop < 0 else stop
            elif two == '<<' and text[i + 2:i + 3] != '<' and (i == 0 or text[i - 1] != '<'):
                strip = text[i + 2:i + 3] == '-'
                delim, i = heredoc_word(text, i + 2 + strip)
                pending.append((delim, strip))
            elif top == 'cs' and ch in '()':
                if ch == ')' and stack[-1][1] == 0:
                    stack.pop()
                else:
                    stack[-1][1] += 1 if ch == '(' else -1
                i += 1
            elif top == 'pe' and ch == '}':
                stack.pop()
                i += 1
            else:
                i += 1
    return out


def shell_code(bash, path):
    """Only a line that starts as a command loses the wrapper's indent; the
    text of a literal is kept as bash keeps it."""
    return '\n'.join(line[4:] if code and line.startswith('    ') else line
                     for code, line in shell_lines(bash, path))


def heredoc_split(bash, path, dest=None):
    """(the file's code less every heredoc body, [each heredoc body]); with
    dest, body n is also written to <dest>/<n>.sh."""
    bodies = []
    lines = shell_lines(bash, path, bodies)
    for n, body in enumerate(bodies if dest else []):
        with open(os.path.join(dest, '%d.sh' % n), 'w', encoding='utf-8') as out:
            out.write(body)
    return '\n'.join(line[4:] if code and line.startswith('    ') else line
                      for code, line in lines if code is not None), bodies


def shell_guard(bash, path):
    for code, line in shell_lines(bash, path):
        if code and line.startswith('    ') and not line[4:5].isspace() \
                and GUARD.fullmatch(line[4:]) is not None:
            return True
    return False


def python_tree(path):
    try:
        with open(path, encoding='utf-8') as handle:
            return ast.parse(handle.read(), filename=path)
    except (SyntaxError, ValueError, UnicodeDecodeError) as err:
        raise Refused(f'{path}: python cannot parse this file: {err}')


def python_code(path):
    tree = python_tree(path)
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            body = node.body
            if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) \
                    and isinstance(body[0].value.value, str):
                node.body = body[1:] or [ast.Pass()]
    return ast.unparse(tree)


def is_guard(stmt):
    if not isinstance(stmt, ast.Assign):
        return False
    value = stmt.value
    if not (isinstance(value, ast.Constant) and value.value == '0'):
        return False
    for target in stmt.targets:
        if isinstance(target, ast.Subscript) and isinstance(target.value, ast.Attribute) \
                and isinstance(target.value.value, ast.Name) and target.value.value.id == 'os' \
                and target.value.attr == 'environ' and isinstance(target.slice, ast.Constant) \
                and target.slice.value == 'HERDR_ENV':
            return True
    return False


def python_guard(path):
    return any(is_guard(stmt) for stmt in python_tree(path).body)


def usage():
    print('usage: source_scan.py code|sh-guard --bash <path> <file> | py-guard <file>', file=sys.stderr)
    return 64


def main(argv):
    if not argv:
        return usage()
    command, rest = argv[0], argv[1:]
    bash = None
    if command in ('code', 'sh-guard'):
        if len(rest) < 3 or rest[0] != '--bash':
            print(f'source_scan.py: {command} needs --bash <path>; it never picks a bash itself', file=sys.stderr)
            return 64
        bash, rest = rest[1], rest[2:]
        if len(rest) != 1:
            return usage()
        if not (os.path.isfile(bash) and os.access(bash, os.X_OK)):
            print(f'source_scan.py: --bash {bash} is not an executable file', file=sys.stderr)
            return 64
    elif command != 'py-guard' or len(rest) != 1:
        return usage()
    path = rest[0]
    if not os.path.isfile(path):
        print(f'source_scan.py: {path}: no such file', file=sys.stderr)
        return 2
    try:
        if command == 'py-guard':
            return 0 if python_guard(path) else 1
        if command == 'sh-guard':
            return 0 if shell_guard(bash, path) else 1
        if path.endswith('.py'):
            text = python_code(path)
        else:
            text = shell_code(bash, path)
    except Refused as err:
        print(f'source_scan.py: {err}', file=sys.stderr)
        return 2
    sys.stdout.write(text + '\n' if text else '')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
