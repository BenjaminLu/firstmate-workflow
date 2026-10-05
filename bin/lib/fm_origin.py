"""Validate configured origin identity without applying transport rewrites."""
import os
import subprocess
import sys


class _GitFailure(Exception):
    pass


def _read(root, operation, key):
    args = ['git', '-C', os.fspath(root), 'config', '--includes', '--show-scope']

    def run(options):
        try:
            result = subprocess.run(args + options + [operation, key], capture_output=True)
        except OSError:
            raise _GitFailure('git config could not be executed') from None
        if result.returncode == 1:
            return b''
        if result.returncode != 0:
            # Git's stderr may contain a global rewrite target. Do not expose it.
            raise _GitFailure(f'git config failed (exit {result.returncode})')
        return result.stdout

    raw = run([])
    if not raw:
        return []
    if operation == '--get-regexp':
        # Both a subsection (the rewrite target) and a value can contain
        # spaces/newlines, so key/value output is not always separable. Read
        # NUL-framed names, then each exact key's scoped values. This also
        # prevents a global target containing scope-like text being exposed.
        fields = run(['--null', '--name-only']).split(b'\0')
        if fields[-1] != b'' or len(fields) % 2 != 1:
            raise _GitFailure('git config returned invalid scoped records')
        keys = dict.fromkeys(fields[1:-1:2])
        return [(scope, name, value) for name in keys
                for scope, value in _read(root, '--get-all', os.fsdecode(name))]
    # The usual scope<TAB>value<LF> form is unambiguous for a single line.
    # Multiple lines may be multiple values OR embedded newlines (even a
    # scope-looking continuation). Ask git for NUL framing before parsing.
    if raw.count(b'\n') > 1:
        fields = run(['--null']).split(b'\0')
        if fields[-1] != b'' or len(fields) % 2 != 1:
            raise _GitFailure('git config returned invalid scoped records')
        records = list(zip(fields[:-1:2], fields[1:-1:2]))
    else:
        scope, delimiter, value = raw.removesuffix(b'\n').partition(b'\t')
        if not delimiter:
            raise _GitFailure('git config returned invalid scoped records')
        records = [(scope, value)]
    return records


def _escaped(value):
    """repr's one-line escaping, without its surrounding quotation marks."""
    return repr(os.fsdecode(value))[1:-1]


def _quoted(value):
    return "'" + _escaped(value).replace("'", "\\'") + "'"


def check(root, expected) -> str | None:
    """Return None for this project's origin, otherwise a one-line reason."""
    expected = os.fsencode(expected)
    try:
        urls = [value for _, value in _read(root, '--get-all', 'remote.origin.url')]
        if urls != [expected]:
            return f'its origin is {_quoted(b", ".join(urls))}, not {_escaped(expected)}'
        for _, value in _read(root, '--get-all', 'remote.origin.pushurl'):
            if value != expected:
                return f'its push origin is {_quoted(value)}, not {_escaped(expected)}'
        for scope, key, value in _read(root, '--get-regexp', r'^url\..*\.(insteadof|pushinsteadof)$'):
            if scope in (b'global', b'system'):
                continue
            if expected.startswith(value):
                target = key[len(b'url.'):].rsplit(b'.', 1)[0]
                return f'its local config rewrites {_escaped(value)} to {_escaped(target)}'
    except _GitFailure as error:
        return str(error)
    return None


def main():
    if len(sys.argv) != 4 or sys.argv[1] != 'check':
        print('fm-origin: usage: fm_origin.py check <root> <expected>', file=sys.stderr)
        return 65
    reason = check(sys.argv[2], sys.argv[3])
    if reason is not None:
        print('fm-origin: ' + reason, file=sys.stderr)
        return 65
    return 0


if __name__ == '__main__':
    sys.exit(main())
