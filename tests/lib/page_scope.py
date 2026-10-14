"""The top level of a classic page script, read without running it (T-308).

Classic scripts on one page share one global scope: two that both declare
`const t` stop the second with "Identifier 't' has already been declared",
and every script after it with it. A board page script therefore keeps its
own scope: its top level holds only

  (() => { ... })();                       a scope of its own
  const NAME = (() => { ... })();          one exported name, upper case
  if (typeof module !== "undefined") module.exports = NAME;

and anything it shares with the page it sets on `window` by name inside
that scope. top_level() returns the tokens a script holds outside every
bracket, which is all the check needs; strings, template literals,
comments and regular expressions are skipped as wholes so that a brace in
one does not count.
"""
import re

_REGEX_AFTER = {'return', 'typeof', 'instanceof', 'in', 'of', 'new', 'delete',
                'void', 'throw', 'case', 'do', 'else', 'yield', 'await'}
_OPEN = {'(': ')', '[': ']', '{': '}'}


def _string(src, i, quote):
    i += 1
    while i < len(src) and src[i] != quote:
        i += 2 if src[i] == '\\' else 1
    return i + 1


def _regex(src, i):
    i += 1; in_class = False
    while i < len(src):
        c = src[i]
        if c == '\\': i += 2; continue
        if c == '[': in_class = True
        elif c == ']': in_class = False
        elif c == '/' and not in_class: break
        elif c == '\n': raise ValueError('unterminated regular expression')
        i += 1
    i += 1
    while i < len(src) and (src[i].isalnum() or src[i] in '_$'): i += 1
    return i


def tokens(src):
    """Yield (depth, token) for every token outside strings and comments:
    depth is the number of brackets open around it; an opening bracket is
    yielded at the depth outside it, as is its closing bracket."""
    stack = []; prev = None; i = 0; n = len(src)
    def template(i):
        # from inside a template literal: to its end, or into a ${
        while i < n:
            c = src[i]
            if c == '\\': i += 2; continue
            if c == '`': return i + 1, False
            if c == '$' and src[i + 1:i + 2] == '{': return i + 2, True
            i += 1
        raise ValueError('unterminated template literal')
    while i < n:
        c = src[i]
        if c.isspace(): i += 1; continue
        if src.startswith('//', i):
            j = src.find('\n', i); i = n if j < 0 else j; continue
        if src.startswith('/*', i):
            j = src.find('*/', i + 2)
            if j < 0: raise ValueError('unterminated comment')
            i = j + 2; continue
        if c in '\'"':
            i = _string(src, i, c); yield len(stack), 'str'; prev = 'str'; continue
        if c == '`':
            yield len(stack), 'tmpl'
            i, into = template(i + 1)
            if into: stack.append('${')
            prev = 'tmpl'; continue
        if c == '/' and (prev is None or prev in _REGEX_AFTER
                         or (not re.match(r'[\w$]', prev) and prev not in (')', ']', 'str', 'tmpl', 'num', 'regex'))):
            i = _regex(src, i); yield len(stack), 'regex'; prev = 'regex'; continue
        m = re.compile(r'[A-Za-z_$][\w$]*').match(src, i)
        if m:
            word = m.group(); i = m.end(); yield len(stack), word; prev = word; continue
        m = re.compile(r'\.?\d[\w.]*').match(src, i)
        if m:
            i = m.end(); yield len(stack), 'num'; prev = 'num'; continue
        if c in _OPEN:
            yield len(stack), c; stack.append(c); i += 1; prev = c; continue
        if c in ')]}':
            if not stack: raise ValueError(f'unbalanced {c}')
            top = stack.pop()
            if top == '${':
                if c != '}': raise ValueError('unbalanced template expression')
                i, into = template(i + 1)
                if into: stack.append('${')
                prev = 'tmpl'; continue
            if _OPEN[top] != c: raise ValueError(f'{top} closed by {c}')
            yield len(stack), c; i += 1; prev = c; continue
        m = re.compile(r'=>|[=!<>]=?=?|&&|\|\||\?\?|\?\.|\.\.\.|[-+*%&|^~?:;,.]').match(src, i)
        tok = m.group() if m else c
        i += len(tok); yield len(stack), tok; prev = tok
    if stack: raise ValueError('unclosed ' + stack[-1])


def top_level(src):
    """The script's top-level tokens, in order, with the first token inside
    each top-level bracket kept beside it as `(<first>`."""
    out = []; first_inside = False
    for depth, tok in tokens(src):
        if depth == 0:
            out.append(tok); first_inside = tok == '('
        elif depth == 1 and first_inside:
            out[-1] = '(' + tok; first_inside = False
    return out


_FN = r'\((?:\(|function|async)'
_SCOPE = re.compile(rf'{_FN} \) \( \)')
STATEMENT = re.compile(
    rf'^(?:(?:const|var) (?P<name>[A-Z][A-Z0-9_]*) = )?{_FN} \) \( \)(?: ;)?$'
    r'|^if \(typeof \) module \. exports = (?P<module>[A-Z][A-Z0-9_]*)(?: ;)?$')


def statements(top):
    """Split top-level tokens at `;` and at the end of each IIFE call, which
    is where a script that leaves out its semicolons ends a statement."""
    out, cur = [], []
    for tok in top:
        cur.append(tok)
        text = ' '.join(cur)
        if tok == ';' or (tok == ')' and _SCOPE.search(text) and text.endswith('( )')):
            out.append(text); cur = []
    if cur: out.append(' '.join(cur))
    # a lone `;` after an IIFE call belongs to it
    merged = []
    for s in out:
        if s == ';' and merged: merged[-1] += ' ;'
        else: merged.append(s)
    return merged


def check(src):
    """(exported names, problems) for one script's source."""
    names, problems = [], []
    try:
        top = top_level(src)
    except ValueError as error:
        return names, [f'cannot be read: {error}']
    for stmt in statements(top):
        m = STATEMENT.match(stmt)
        if not m:
            problems.append(f'top level holds `{stmt}`')
        elif m.group('name'):
            names.append(m.group('name'))
        elif m.group('module') and m.group('module') not in names:
            problems.append(f'exports {m.group("module")}, which it does not declare')
    if len(names) > 1:
        problems.append('declares more than one name: ' + ', '.join(names))
    return names, problems


def window_names(src):
    """Names a script sets on `window`: `window.X =` and
    `Object.assign(window, { X, Y })`."""
    found = re.findall(r'\bwindow\.([A-Za-z_$][\w$]*)\s*=(?![=>])', src)
    for group in re.findall(r'Object\.assign\(\s*window\s*,\s*\{([^}]*)\}', src):
        found += [part.split(':')[0].strip() for part in group.split(',') if part.strip()]
    return found


def page_scripts(index_html):
    """The inline scripts of a page, in order: the body of each <script>
    without a src."""
    return re.findall(r'<script>(.*?)</script>', index_html, re.S)
