#!/usr/bin/env bash
# bin/lib/fm_private_names.py
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(sys.argv[1]) / 'bin/lib'))
import fm_private_names as P

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp) / 'engine'
    root.mkdir()
    home = Path(tmp) / 'private'
    (home / 'owners').mkdir(parents=True)
    for owner in ('Other-Owner', 'sElF-oWnEr'):
        (home / 'owners' / (owner + '.yaml')).write_text('')
    config = root / 'config.yaml'
    config.write_text(f'''home: {home}
projects: # routing
  self: # engine
    repo: .
    github: Self-Owner/engine
  invented-project:
    github: External-Owner/invented-repo
  shared-owner:
    github: SELF-OWNER/shared-repo
''')
    expected = {'invented-project', 'External-Owner/invented-repo', 'invented-repo',
                'External-Owner', 'Other-Owner', 'shared-owner', 'SELF-OWNER/shared-repo', 'shared-repo'}
    assert P.names(config, home) == expected, 'registry and owner stems exclude self owner case-insensitively'
    assert P.digest('MiXeD') == hashlib.sha256(b'mixed').hexdigest()
    env = dict(os.environ, FM_HOME=str(home))
    command = [sys.executable, str(Path(sys.argv[1]) / 'bin/lib/fm_private_names.py'), 'update', '--repo', str(root)]
    result = subprocess.run(command, env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    target = root / 'tests/fixtures/private-name-digests.txt'
    values = lambda: {line for line in target.read_text().splitlines() if not line.startswith('#')}
    assert values() == {P.digest(n) for n in expected}, 'update creates the complete digest file'
    assert target.read_text().splitlines()[1:] == sorted(values()), 'digests are sorted and deduplicated'
    extra = 'retired-invented-name'
    result = subprocess.run(command + ['--name-stdin'], input=extra + '\n', env=env, capture_output=True, text=True)
    assert result.returncode == 0
    assert P.digest(extra) in values(), 'stdin merges retired names'
    for name in expected | {extra}:
        assert name not in result.stdout + result.stderr, 'CLI never echoes a private name'
    config.write_text('projects:\n  self:\n    repo: .\n    github: Self-Owner/engine\n')
    before = target.read_bytes()
    result = subprocess.run(command, env=env, capture_output=True, text=True)
    assert result.returncode == 0 and '0 added' in result.stdout
    assert target.read_bytes() == before, 'updates never remove digests'
    with patch.object(P.os, 'replace', side_effect=OSError('write refused')):
        try:
            P.write(target, [P.digest('another-invented-name')])
        except OSError:
            pass
        else:
            raise AssertionError('write error must propagate')
    assert target.read_bytes() == before, 'failed atomic write preserves old bytes'
    assert list(target.parent.iterdir()) == [target], 'failed write removes temporary file'
    with patch.dict(os.environ, {}, clear=True):
        config.write_text(f'home: {home}\nprojects:\n  self:\n    repo: .\n    github: Self-Owner/engine\n')
        assert P.update(root) == 0, 'configured home is used without FM_HOME'
    default_home = Path(tmp) / '.firstmate'
    (default_home / 'owners').mkdir(parents=True)
    (default_home / 'owners/default-owner.yaml').touch()
    config.write_text('projects:\n  self:\n    repo: .\n    github: Self-Owner/engine\n')
    with patch.dict(os.environ, {'HOME': tmp}, clear=True):
        assert P.update(root) == 1, 'default home resolves beneath HOME'
    override = Path(tmp) / 'override'
    (override / 'owners').mkdir(parents=True)
    (override / 'owners/override-owner.yaml').touch()
    config.write_text(f'home: {home}\nprojects:\n  self:\n    repo: .\n    github: Self-Owner/engine\n')
    with patch.dict(os.environ, {'FM_HOME': str(override)}):
        assert P.update(root) == 1, 'environment home takes precedence'
    target.unlink()
    target.mkdir()
    result = subprocess.run(command, env=env, capture_output=True, text=True)
    assert result.returncode != 0 and result.stderr, 'unwritable destination fails with stderr'
    assert target.is_dir(), 'failed update preserves destination'
print('Private name digest checks passed.')
PY
