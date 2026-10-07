#!/usr/bin/env bash
# Public prose and committed control files must not disclose external projects.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1])
PATHS = ['README.md', ':(glob)design/*.md', 'skills', 'docs', 'bin', 'board']


def git(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *args], capture_output=True)


def registry(repo, *args, fixture=False):
    env = dict(os.environ)
    if fixture:
        env.pop('FM_HOME', None)
    result = subprocess.run(['bash', '-c', '. "$1/bin/fm-config.sh"; shift; "$@"',
                             '_', str(ROOT), *args, str(repo / 'config.yaml')],
                            env=env, capture_output=True, text=True)
    assert result.returncode == 0, 'cannot read project registry: ' + result.stderr
    return result.stdout.strip()


def check(repo, fixture=False):
    problems = []
    local = git(repo, 'grep', '-nE', r'/Use[r]s/[^/]+/(Desktop|\.firstmate)', '--', *PATHS)
    assert local.returncode in (0, 1), local.stderr
    if local.returncode == 0:
        problems.append('local paths in public text')
    projects = []
    for name in registry(repo, 'fm_projects', fixture=fixture).splitlines():
        if registry(repo, 'fm_project_get', name, 'repo', fixture=fixture) == '.':
            continue
        fields = {key: registry(repo, 'fm_project_get', name, key, fixture=fixture)
                  for key in ('github', 'home', 'root', 'state', 'tasks', 'design', 'conventions')}
        projects.append((name, fields))
    with tempfile.NamedTemporaryFile(mode='w', prefix='private-text-patterns-') as patterns:
        for name, fields in projects:
            patterns.write(name + '\n' + fields['github'] + '\n')
        patterns.flush()
        if projects:
            names = git(repo, 'grep', '-nF', '-f', patterns.name, '--', *PATHS)
            assert names.returncode in (0, 1), names.stderr
            if names.returncode == 0:
                problems.append('external names in public text')
        elif not fixture:
            print('No external registry entries; external-name check has no patterns.')
    tracked = git(repo, 'ls-files', '-z')
    assert tracked.returncode == 0, tracked.stderr
    files = [repo / os.fsdecode(p) for p in tracked.stdout.split(b'\0') if p]
    private_hashes = set()
    for name, fields in projects:
        roots = [Path(fields[key]).resolve() for key in ('home', 'root', 'state', 'tasks', 'design')]
        for file in files:
            if (file.relative_to(repo).parts[:2] == ('projects', name)
                    or any(file.resolve().is_relative_to(path) for path in roots)):
                problems.append('external control path is tracked')
        sources = [Path(fields['conventions']), Path(fields['design'])]
        sources += list(Path(fields['tasks']).glob('*.json'))
        for source in sources:
            if source.is_file():
                private_hashes.add(hashlib.sha256(source.read_bytes()).digest())
    for file in files:
        if file.is_file() and hashlib.sha256(file.read_bytes()).digest() in private_hashes:
            problems.append('external control bytes are tracked')
    return problems


with tempfile.TemporaryDirectory(prefix='external-private-text-') as temporary:
    base = Path(temporary)
    repo = base / 'engine'
    repo.mkdir()
    home = base / 'private'
    private = home / 'projects/invented-orbit'
    (private / 'tasks').mkdir(parents=True)
    (repo / 'config.yaml').write_text(f'''home: {home}
projects:
  invented-orbit:
    github: imaginary-owner/orbit-widget
    base: main
    required_check: ci
''')
    assert git(repo, 'init', '-q').returncode == 0
    readme = repo / 'README.md'
    readme.write_text('Generic external workflow.\n')
    assert git(repo, 'add', 'README.md').returncode == 0
    assert check(repo, fixture=True) == []
    for name in ('invented-orbit', 'imaginary-owner/orbit-widget'):
        readme.write_text(name + '\n')
        assert 'external names in public text' in check(repo, fixture=True)
        readme.write_text('Generic external workflow.\n')
        assert check(repo, fixture=True) == []
    readme.write_text('/Users/fixture/Desktop/private-repo\n')
    assert 'local paths in public text' in check(repo, fixture=True)
    readme.write_text('Generic external workflow.\n')
    for source in (private / 'CONVENTIONS.md', private / 'design.md', private / 'tasks/T-001.json'):
        source.write_text('Private fixture control bytes: ' + source.name + '\n')
        copy = repo / 'copied-control.txt'
        copy.write_bytes(source.read_bytes())
        assert git(repo, 'add', 'copied-control.txt').returncode == 0
        assert 'external control bytes are tracked' in check(repo, fixture=True)
        assert git(repo, 'rm', '-f', 'copied-control.txt').returncode == 0
        assert check(repo, fixture=True) == []
    copy = repo / 'projects/invented-orbit/CONVENTIONS.md'
    copy.parent.mkdir(parents=True)
    copy.write_bytes((private / 'CONVENTIONS.md').read_bytes())
    assert git(repo, 'add', str(copy.relative_to(repo))).returncode == 0
    assert 'external control path is tracked' in check(repo, fixture=True)
    assert git(repo, 'rm', '-f', str(copy.relative_to(repo))).returncode == 0
    assert check(repo, fixture=True) == []

problems = check(ROOT)
assert not problems, '; '.join(sorted(set(problems)))
print('External private text and control-file checks passed.')
PY
