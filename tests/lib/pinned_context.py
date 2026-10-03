import hashlib
import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location('context', ROOT / 'bin/lib/fm_prompt_context.py')
context = importlib.util.module_from_spec(spec)
spec.loader.exec_module(context)


class PinnedContext(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.folder = self.root / 'private/state/runs/worker/pinned'
        self.pin = dict(project='private', task='T-173', version=2,
                        contract={'check': 'approved-check'}, snapshots={})
        texts = dict(spec=json.dumps({'id': 'T-173', 'acceptance': ['See §15.10']}),
                     design='# Design\r\n## 6. Gates\nall gates\n## 7. List\nall criteria\n'
                            '## 8. Board\n' + '船' * 50000 + '\n### 15.10 Private data\nTAIL\n',
                     conventions='whole conventions\r\n', contract='project:\n  check: approved-check\n')
        for key, text in texts.items():
            self.pin['snapshots'][key] = dict(text=text, sha256=hashlib.sha256(text.encode()).hexdigest())
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        self.env['FM_PINNED_DIR'] = str(self.folder)
        self.addCleanup(self.writable)

    def writable(self):
        if self.folder.exists():
            self.folder.chmod(0o700)
            for file in self.folder.iterdir():
                file.chmod(0o600)

    def render(self):
        return subprocess.run([sys.executable, str(ROOT / 'bin/lib/fm_prompt_context.py'), 'pin', 'worker'],
                              input=json.dumps(self.pin), text=True, capture_output=True, env=self.env)

    def test_complete_readonly_snapshots_and_anchors(self):
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        for key, filename in [('spec', 'spec.json'), ('design', 'design.md'),
                              ('conventions', 'CONVENTIONS.md'), ('contract', 'contract.yaml')]:
            path = self.folder / filename
            self.assertEqual(path.read_bytes(), self.pin['snapshots'][key]['text'].encode())
            self.assertEqual(path.stat().st_mode & 0o222, 0)
            self.assertIn(str(path), result.stdout)
            self.assertIn(self.pin['snapshots'][key]['sha256'], result.stdout)
        self.assertEqual(self.folder.stat().st_mode & 0o222, 0)
        self.assertIn('15.10 Private data', result.stdout)
        self.assertIn('lines 8-9', result.stdout)
        for section in ('6. Gates', '7. List', '8. Board'):
            self.assertIn(section, result.stdout)
        self.assertNotIn('TRIMMED', result.stdout)
        self.assertNotIn('船', result.stdout)
        self.assertIn('whole conventions', result.stdout)
        self.assertIn('approved-check', result.stdout)
        self.assertFalse((self.root / 'engine/pinned').exists())
        self.assertFalse((self.root / 'target/pinned').exists())

    def test_tampered_snapshot_refuses_before_materialization(self):
        self.pin['snapshots']['design']['text'] += 'tamper'
        result = self.render()
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertIn('design snapshot hash mismatch', result.stderr)
        self.assertFalse(self.folder.exists())

    def test_missing_conventions_explicit_and_existing_empty_file_preserved(self):
        snap = self.pin['snapshots']['conventions']
        snap.update(text='', sha256=hashlib.sha256(b'').hexdigest(), source='absent')
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CONVENTIONS.md: absent', result.stdout)
        self.assertFalse((self.folder / 'CONVENTIONS.md').exists())

    def test_existing_folder_cannot_be_replaced_or_tampered(self):
        self.assertEqual(self.render().returncode, 0)
        self.writable()
        (self.folder / 'design.md').write_text('tampered')
        result = self.render()
        self.assertEqual(result.returncode, 65)
        self.assertIn('pinned', result.stderr)

    def test_legacy_sources_are_complete_and_explicitly_unpinned(self):
        engine = self.root / 'engine'
        engine.mkdir()
        design = engine / 'design.md'
        design.write_bytes(self.pin['snapshots']['design']['text'].encode())
        (engine / 'config.yaml').write_text('project:\n  check: legacy-check\n')
        env = dict(self.env, FM_ENGINE_ROOT=str(engine), FM_STATE_DIR=str(engine / 'state'),
                   FM_DESIGN=str(design), FM_PROJECT='firstmate-workflow', FM_EXTERNAL='0')
        result = subprocess.run([sys.executable, str(ROOT / 'bin/lib/fm_prompt_context.py'), 'legacy', 'reviewer'],
                                input=self.pin['snapshots']['spec']['text'], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('UNPINNED', result.stdout)
        self.assertIn('CONVENTIONS.md: absent', result.stdout)
        self.assertEqual((self.folder / 'design.md').read_bytes(), design.read_bytes())

    def test_external_authorized_pin_is_used_after_private_sources_change(self):
        sys.path.insert(0, str(ROOT / 'bin/lib'))
        from fm_spec_pins import Pins
        engine = self.root / 'engine'
        engine.mkdir()
        target = self.root / 'target'
        target.mkdir()
        env = dict(self.env, HERDR_ENV='0')
        for checkout in (engine, target):
            subprocess.run(['git', 'init', '-q', '-b', 'main', str(checkout)], env=env, check=True)
            subprocess.run(['git', '-C', str(checkout), '-c', 'core.hooksPath=/dev/null',
                            '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                            'commit', '-qm', 'base', '--allow-empty'], env=env, check=True)
        private = self.root / 'private'
        state = private / 'state'
        state.mkdir(parents=True)
        (private / 'tasks').mkdir()
        (private / 'tasks/T-173.json').write_text('{"id":"T-173","scope":["src/**"],"acceptance":["§15.10"]}')
        for key, path in [('design', private / 'design.md'), ('conventions', private / 'CONVENTIONS.md'),
                          ('contract', state / 'config.yaml')]:
            path.write_bytes(self.pin['snapshots'][key]['text'].encode())
        (state / 'events.jsonl').write_text(json.dumps(dict(type='greenlit', actor='captain',
                                                          project='private', ts='2026-10-03T00:00:00Z')) + '\n')
        pins = Pins(dict(FM_ENGINE_ROOT=str(engine), FM_TARGET_ROOT=str(target), FM_STATE_DIR=str(state),
                         FM_EXTERNAL='1', FM_PROJECT='private', FM_TASKS_DIR=str(private / 'tasks'),
                         FM_DESIGN=str(private / 'design.md')), 'T-173')
        approved = pins.create()
        (private / 'design.md').write_text('mutable replacement')
        self.pin = pins.resolve()
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.folder / 'design.md').read_bytes(), approved['snapshots']['design']['text'].encode())
        self.assertFalse((engine / 'state').exists())
        self.assertFalse((target / 'pinned').exists())
        self.assertIn(str(self.folder / 'design.md'), result.stdout)

    def test_real_sandbox_reads_pinned_but_denies_writes_key_and_other_run(self):
        platform = 'darwin' if sys.platform == 'darwin' else 'linux'
        tool = shutil.which('sandbox-exec' if platform == 'darwin' else 'bwrap')
        if not tool:
            self.skipTest('OS sandbox tool unavailable; profile tests still apply')
        if os.environ.get('FM_IN_ROUND') == '1':
            self.skipTest('real sandbox cannot nest inside a crew round')
        self.assertEqual(self.render().returncode, 0)
        state = self.root / 'private/state'
        key = state / 'evidence-signing.key'
        key.write_text('fixture signing key')
        other = state / 'runs/another/secret'
        other.parent.mkdir(parents=True)
        other.write_text('other round')
        tree = self.root / 'target'
        tree.mkdir()
        policy = dict(write=['{root}'], read=[str(self.root), '/usr', '/bin', '/lib', '/lib64',
                                             '/etc', '/System', '/opt', '/Library'],
                      never_read=[str(state)], repo_config=[], vendors={}, dimensions=[],
                      network=[], env_scrub=[], procs=2048, cpu=600)
        path = self.root / 'policy.json'
        path.write_text(json.dumps(policy))
        result = subprocess.run(['bash', str(ROOT / 'bin/fm-sandbox.sh'), 'profile',
                                 '--policy=' + str(path), '--root=' + str(tree)],
                                env=dict(self.env, FM_SANDBOX_OS=platform), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        if platform == 'darwin':
            profile = self.root / 'profile.sb'
            profile.write_text(result.stdout)
            command = [tool, '-f', str(profile)]
        else:
            command = [tool, *result.stdout.splitlines()]
        probe = """
import os, sys
from pathlib import Path
folder, key, other = map(Path, sys.argv[1:])
assert (folder / 'design.md').read_bytes()
for denied in (key, other):
    try:
        denied.read_bytes()
    except OSError:
        pass
    else:
        raise AssertionError('private sibling readable: ' + str(denied))
try:
    (folder / 'design.md').chmod(0o644)
    (folder / 'design.md').write_text('round modification')
except OSError:
    pass
else:
    raise AssertionError('pinned design writable')
"""
        result = subprocess.run(command + [sys.executable, '-c', probe, str(self.folder), str(key), str(other)],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_sandbox_profiles_grant_only_pinned_read_access(self):
        self.assertEqual(self.render().returncode, 0)
        tree = self.root / 'target'
        tree.mkdir()
        policy = dict(write=['{root}', '{tmp}'], read=['/usr', '/bin'],
                      never_read=[str(self.root / 'private')], repo_config=[], vendors={},
                      dimensions=[], network=[], env_scrub=[], procs=2048, cpu=600)
        policy_path = self.root / 'policy.json'
        policy_path.write_text(json.dumps(policy))
        for platform in ('darwin', 'linux'):
            env = dict(self.env, FM_SANDBOX_OS=platform)
            result = subprocess.run(['bash', str(ROOT / 'bin/fm-sandbox.sh'), 'profile',
                                     '--policy=' + str(policy_path), '--root=' + str(tree)],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            if platform == 'darwin':
                rule = '(allow file-read* (subpath ' + json.dumps(str(self.folder)) + '))'
                self.assertIn(rule, result.stdout)
                self.assertGreater(result.stdout.index(rule), result.stdout.index('never readable'))
                self.assertIn('(deny file-write* (subpath ' + json.dumps(str(self.folder)), result.stdout)
            else:
                self.assertIn('--ro-bind\n' + str(self.folder) + '\n' + str(self.folder), result.stdout)
            self.assertNotIn('evidence-signing.key', result.stdout)
            self.assertNotIn('/runs/another', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
