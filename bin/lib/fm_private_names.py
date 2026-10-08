"""Keep private-name fingerprints without publishing the names themselves."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from fm_project_paths import registry_reader

DIGEST_FILE = 'tests/fixtures/private-name-digests.txt'


def _config(path):
    reader = registry_reader()
    if reader is None:
        raise ValueError('registry reader unavailable')
    return reader, reader._config_lines(Path(path).parent)


def _scalar(reader, lines, key):
    field = reader._config_key(lines, key)
    return reader._project_scalar(field[0], key) if field else ''


def names(engine_config, fm_home):
    reader, lines = _config(engine_config)
    block = reader._config_key(lines, 'projects')
    body = [line for line in block[1] if line.strip()] if block else []
    level = min((reader._indent(line) for line in body), default=0)
    entries = {}
    for line in body:
        if reader._indent(line) == level:
            match = re.fullmatch(r'\s*([a-z0-9-]+):\s*', line)
            if not match:
                raise ValueError('invalid registry entry')
            name = match[1]
            children = reader._config_key(body, name)[1]
            entries[name] = {key: _scalar(reader, children, key) for key in ('repo', 'github')}
    self_owners = {e['github'].split('/')[0].lower() for e in entries.values() if e['repo'] == '.'}
    result = set()
    for name, entry in entries.items():
        if entry['repo'] == '.':
            continue
        pair = entry['github']
        if not re.fullmatch(r'[A-Za-z0-9._-]+/[A-Za-z0-9._-]+', pair):
            raise ValueError('invalid registry repository')
        owner, repository = pair.split('/')
        result.update((name, pair, repository))
        if owner.lower() not in self_owners:
            result.add(owner)
    for path in (Path(fm_home).expanduser() / 'owners').glob('*.yaml'):
        if path.is_file() and path.stem.lower() not in self_owners:
            result.add(path.stem)
    return result


def digest(name):
    return hashlib.sha256(name.lower().encode('utf-8')).hexdigest()


def _digests(text):
    values = {line.strip() for line in text.splitlines() if line.strip() and not line.startswith('#')}
    if any(not re.fullmatch(r'[0-9a-f]{64}', value) for value in values):
        raise ValueError('invalid private-name digest file')
    return values


def write(path, digests):
    path = Path(path)
    content = '# Digests only; no private names.\n' + ''.join(value + '\n' for value in sorted(set(digests)))
    _digests(content)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, delete=False) as output:
            temporary = Path(output.name)
            output.write(content)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def update(repo, extra_names=()):
    repo = Path(repo)
    config = repo / 'config.yaml'
    reader, lines = _config(config)
    home = Path(os.environ.get('FM_HOME', _scalar(reader, lines, 'home') or '~/.firstmate')).expanduser()
    path = repo / DIGEST_FILE
    previous = _digests(path.read_text()) if path.exists() else set()
    merged = previous | {digest(name) for name in names(config, home)}
    merged.update(digest(name.strip()) for name in extra_names if name.strip())
    write(path, merged)
    return len(merged - previous)


def _tokens(line):
    tokens = re.findall(r'[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)?', line)
    def normalized(token):
        return token.lower().removesuffix('.').removesuffix('.git')
    for token in tokens:
        for part in [token, *token.split('/')]:
            part = normalized(part)
            yield part
            decision = re.fullmatch(r'd-(.+)-t[0-9]+-[0-9]+', part)
            if decision:
                yield decision[1]
    for left, right in zip(tokens, tokens[1:]):
        yield normalized(left) + '-' + normalized(right)


def scan(repo):
    """Scan HEAD blobs only, including the committed digest list."""
    def git(*args, **kwargs):
        return subprocess.run(['git', '-C', str(repo), *args], capture_output=True, **kwargs)
    tree = git('ls-tree', '-rz', 'HEAD')
    if tree.returncode:
        # Fixture repositories and new engines may not have a first commit yet.
        if git('rev-parse', '--verify', 'HEAD').returncode:
            return []
        raise ValueError('cannot read committed tree')
    blobs = []
    for entry in tree.stdout.split(b'\0'):
        if not entry:
            continue
        metadata, path = entry.split(b'\t', 1)
        _, kind, oid = metadata.split()
        if kind == b'blob':
            blobs.append((os.fsdecode(path), oid))
    result = git('cat-file', '--batch', input=b''.join(oid + b'\n' for _, oid in blobs))
    if result.returncode:
        raise ValueError('cannot read committed blobs')
    contents = {}
    offset = 0
    for path, _ in blobs:
        end = result.stdout.index(b'\n', offset)
        size = int(result.stdout[offset:end].split()[-1])
        contents[path] = result.stdout[end + 1:end + 1 + size]
        offset = end + size + 2
    if DIGEST_FILE not in contents:
        return []
    forbidden = _digests(contents[DIGEST_FILE].decode('utf-8'))
    problems = []
    for path, content in contents.items():
        if path == DIGEST_FILE:
            continue
        try:
            text = content.decode('utf-8')
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if any(digest(token) in forbidden for token in _tokens(line)):
                problems.append(f'external name digest in {path}:{number}')
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['update'])
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--name-stdin', action='store_true')
    args = parser.parse_args()
    try:
        added = update(args.repo, sys.stdin if args.name_stdin else ())
    except (OSError, ValueError) as error:
        # Exception filenames or parser inputs can themselves contain a name.
        reason = os.strerror(error.errno) if isinstance(error, OSError) and error.errno else type(error).__name__
        print('private-name digests not updated: ' + reason, file=sys.stderr)
        return 1
    print(f'private-name digests updated ({added} added)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
