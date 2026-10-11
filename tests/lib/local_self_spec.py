"""Task-local storage behavior, exercised against real fixture git trees."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
# Never notify a live Herdr from a fixture that raises cards.
os.environ['HERDR_ENV'] = '0'
ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'tests/lib'))
sys.argv.insert(1, str(ROOT))
from spec_pins_cases import SpecPins as Fixture, git
SpecPins = Fixture

class LocalSelfSpec(unittest.TestCase):
    def setUp(self):
        guard = patch.dict(os.environ, HERDR_ENV='0')
        guard.start()
        self.addCleanup(guard.stop)
        self.fixture.setUp(self)
    event = SpecPins.event
    decision = SpecPins.decision
    # A class attribute, not a module name: the loader would run its cases here.
    fixture = SpecPins
    def test_local_snapshot_ignores_committed_bytes(self):
        self.spec.write_text(json.dumps({'id': 'T-X', 'scope': ['local/**']}))
        _, _, snapshots, _ = self.p.collect()
        self.assertEqual(snapshots['spec']['source'], 'local-self')
        self.assertEqual(json.loads(snapshots['spec']['text'])['scope'], ['local/**'])

    def test_untracked_snapshot(self):
        git(self.root, 'rm', '--cached', 'design/tasks/T-X.json')
        git(self.root, 'commit', '-qm', 'untrack')
        self.event(task='T-X')
        self.p.create()
        self.assertEqual(self.p.resolve()['snapshots']['spec']['source'], 'local-self')

    def test_repin_keeps_local_self_provenance(self):
        self.event(task='T-X')
        self.p.create()
        self.spec.write_text('{"id":"T-X","scope":["changed/**"]}')
        self.decision()
        pin = self.p.create(decision='D-1')
        self.assertEqual(pin['version'], 2)
        self.assertEqual(self.p.resolve()['snapshots']['spec']['source'], 'local-self')

    def test_scope_rejects_added_modified_and_deleted_specs(self):
        self.event(task='T-X')
        self.p.create()
        base = git(self.root, 'rev-parse', 'HEAD')
        self.spec.write_text(self.spec.read_text() + '\n')
        git(self.root, 'add', '.')
        git(self.root, 'commit', '-qm', 'modified spec')
        with self.assertRaisesRegex(ValueError, 'task spec in diff: design/tasks/T-X.json'):
            self.p.scope('HEAD', base)
        git(self.root, 'rm', 'design/tasks/T-X.json')
        git(self.root, 'commit', '-qm', 'delete spec')
        with self.assertRaisesRegex(ValueError, 'task spec in diff: design/tasks/T-X.json'):
            self.p.scope('HEAD', base)
        # git rm removed the now-empty design/tasks/ directory too.
        self.spec.parent.mkdir(parents=True, exist_ok=True)
        self.spec.write_text('{"id":"T-X"}')
        git(self.root, 'add', '.')
        git(self.root, 'commit', '-qm', 'added spec')
        with self.assertRaisesRegex(ValueError, 'task spec in diff:'):
            self.p.scope('HEAD', 'HEAD^')

    def test_old_committed_and_seeded_pins_resolve(self):
        self.event(task='T-X')
        pin = self.p.create()
        snap = pin['snapshots']['spec']
        snap.update(source='committed', commit=pin['engine_commit'])
        record = self.p.directory / '1.json'
        record.write_text(json.dumps(pin))
        self.assertEqual(self.p.resolve(), pin)
        git(self.root, 'rm', '--cached', 'design/tasks/T-X.json')
        git(self.root, 'commit', '-qm', 'base without spec')
        self.spec.write_text(snap['text'])
        record.unlink()
        pin = self.p.create()
        pin['snapshots']['spec']['source'] = 'seeded'
        record.write_text(json.dumps(pin))
        self.assertEqual(self.p.resolve(), pin)

    def test_local_self_invalid_on_other_snapshot_or_external(self):
        self.event(task='T-X')
        pin = self.p.create()
        self.assertEqual(self.p.resolve()['snapshots']['spec']['source'], 'local-self')
        record = self.p.directory / '1.json'
        for name in ('design', 'conventions', 'contract'):
            original = pin['snapshots'][name]['source']
            pin['snapshots'][name]['source'] = 'local-self'
            record.write_text(json.dumps(pin))
            with self.assertRaisesRegex(ValueError, 'invalid snapshot provenance'):
                self.p.resolve()
            pin['snapshots'][name]['source'] = original
        # External provenance rejects the source before any git lookup.
        from fm_spec_pins import Pins
        home = Path(self.tmp.name) / 'private'
        (home / 'tasks').mkdir(parents=True)
        state = home / 'state'
        state.mkdir()
        (home / 'tasks/T-X.json').write_text(self.spec.read_text())
        (home / 'design.md').write_text('external design')
        (home / 'CONVENTIONS.md').write_text('external conventions')
        (state / 'config.yaml').write_text('project:\n  check: true\n')
        env = dict(self.env, FM_EXTERNAL='1', FM_TASKS_DIR=str(home / 'tasks'),
                   FM_STATE_DIR=str(state), FM_DESIGN=str(home / 'design.md'))
        external = Pins(env, 'T-X')
        (state / 'events.jsonl').write_text((self.state / 'events.jsonl').read_text())
        extpin = external.create()
        extpin['snapshots']['spec']['source'] = 'local-self'
        (external.directory / '1.json').write_text(json.dumps(extpin))
        with self.assertRaisesRegex(ValueError, 'invalid snapshot provenance'):
            external.resolve()

    def test_external_design_tasks_uses_scope(self):
        from unittest.mock import patch
        self.event(task='T-X')
        pin = self.p.create()
        base = git(self.root, 'rev-parse', 'HEAD')
        (self.spec.parent / 'T-OTHER.json').write_text('{}')
        git(self.root, 'add', '.')
        git(self.root, 'commit', '-qm', 'external task-shaped source')
        self.p.external = True
        with patch.object(self.p, 'chain', return_value=[pin]):
            self.p.scope('HEAD', base)
            pin['snapshots']['spec']['text'] = '{"id":"T-X","scope":["src/**"]}'
            with self.assertRaisesRegex(ValueError, 'out of scope: design/tasks/T-OTHER.json'):
                self.p.scope('HEAD', base)

    def test_readers_with_no_spec_on_head(self):
        import os
        from unittest.mock import patch
        import fm_binding
        from fm_autopilot import Pilot
        git(self.root, 'rm', '--cached', 'design/tasks/T-X.json')
        git(self.root, 'commit', '-qm', 'untrack')
        env = dict(self.env)
        head = git(self.root, 'rev-parse', 'HEAD')
        with patch.dict(os.environ, env), patch.object(fm_binding, 'approved_pin', return_value=None):
            binding = fm_binding.source_binding('T-X', head, head, ROOT)
            from fm_binding import digest
            self.assertEqual(binding['spec_sha256'], digest(self.spec.read_bytes()))
        pilot = object.__new__(Pilot)
        pilot.ctx = dict(tasks=str(self.spec.parent))
        pilot.adoption_env = lambda: env
        self.assertEqual(pilot.read_head_spec({}, 'T-X')['id'], 'T-X')
        self.event(task='T-X')
        pin = self.p.create()
        self.spec.unlink()
        self.assertEqual(pilot.read_head_spec({}, 'T-X'), json.loads(pin['snapshots']['spec']['text']))
        with patch.dict(os.environ, env), patch.object(fm_binding, 'approved_pin', return_value=pin):
            self.assertEqual(fm_binding.source_binding('T-X', head, head, ROOT)['spec_sha256'],
                             pin['snapshots']['spec']['sha256'])

    def head_with_other_spec(self):
        """The head commits one spec; the local file holds another."""
        self.spec.write_text(json.dumps({'id': 'T-X', 'scope': ['committed/**']}))
        git(self.root, 'add', '.')
        git(self.root, 'commit', '-qm', 'branch spec')
        self.spec.write_text(json.dumps({'id': 'T-X', 'scope': ['local/**']}))
        return git(self.root, 'rev-parse', 'HEAD')

    def spec_shows(self, module):
        """Patch module.subprocess.run and collect every git show of a task spec."""
        real = subprocess.run
        shown = []
        def run(argv, *args, **kwargs):
            if 'show' in argv and any(':design/tasks/' in str(arg) for arg in argv):
                shown.append(argv)
            return real(argv, *args, **kwargs)
        return patch.object(module.subprocess, 'run', side_effect=run), shown

    def test_merge_details_reads_local_spec_not_head(self):
        import hashlib
        import fm_merge_details
        head = self.head_with_other_spec()
        want = hashlib.sha256(self.spec.read_bytes()).hexdigest()
        guard, shown = self.spec_shows(fm_merge_details)
        with guard:
            text = fm_merge_details._spec_text('T-X', head, want, self.root, dict(self.env))
        self.assertEqual(json.loads(text)['scope'], ['local/**'])
        self.assertEqual(shown, [])

    def test_evidence_pinned_scope_reads_local_spec_not_head(self):
        import fm_evidence
        head = self.head_with_other_spec()
        run = Path(self.tmp.name) / 'run'
        run.mkdir()
        with patch.dict(os.environ, self.env):
            self.assertEqual(fm_evidence.pinned_scope(run, 'T-X', head), ['local/**'])
            self.spec.unlink()
            self.assertEqual(fm_evidence.pinned_scope(run, 'T-X', head), [])
            (run / 'pinned').mkdir()
            (run / 'pinned/spec.json').write_text('{"id":"T-X","scope":["pinned/**"]}')
            self.assertEqual(fm_evidence.pinned_scope(run, 'T-X', head), ['pinned/**'])

    def test_decide_reads_local_spec_not_head(self):
        """fm-decide's spec walk, run as written, with no pin."""
        head = self.head_with_other_spec()
        source = (ROOT / 'bin/fm-decide.sh').read_text()
        walk = source.split("<<'PYWALK'\n", 1)[1].split('\nPYWALK\n', 1)[0]
        details = Path(self.tmp.name) / 'details.json'
        details.write_text('{"en":{},"zh-TW":{}}')
        output = Path(self.tmp.name) / 'spec-out.json'
        trace = Path(self.tmp.name) / 'git-trace'
        env = dict(os.environ, HERDR_ENV='0', GIT_TRACE=str(trace), FM_STATE_DIR=str(self.state),
                   FM_TARGET_ROOT=str(self.root), FM_EXTERNAL='0', FM_PROJECT='firstmate-workflow')
        argv = [sys.executable, '-', str(ROOT / 'bin/lib'), 'T-X', head, str(self.root), str(details), str(output)]
        result = subprocess.run(argv, input=walk, capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(output.read_text())['scope'], ['local/**'])
        self.assertNotIn(':design/tasks/T-X.json', trace.read_text() if trace.exists() else '')
        self.spec.unlink()
        result = subprocess.run(argv, input=walk, capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 65)
        self.assertIn(str(self.spec), result.stderr)

del SpecPins, Fixture

if __name__ == '__main__':
    unittest.main()
