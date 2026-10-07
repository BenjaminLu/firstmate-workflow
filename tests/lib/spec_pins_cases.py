"""Feature-owned fail-first cases; invoked by tests/spec-pins.test.sh."""
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
from fm_spec_pins import Pins


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.DEVNULL).decode().strip()


class SpecPins(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'engine'
        self.root.mkdir()
        git(self.root, 'init', '-q', '-b', 'main')
        git(self.root, 'config', 'user.email', 'fixture@example.test')
        git(self.root, 'config', 'user.name', 'fixture')
        (self.root / 'design/tasks').mkdir(parents=True)
        self.spec = self.root / 'design/tasks/T-X.json'
        self.spec.write_text(json.dumps({'id': 'T-X', 'scope': ['src/**', 'design/tasks/T-X.json', '**']}))
        (self.root / 'design/design.md').write_text('approved design\n')
        (self.root / 'config.yaml').write_text('project:\n  check: true\n  docs:\n    - docs/**\n')
        git(self.root, 'add', '.')
        git(self.root, 'commit', '-qm', 'approved base')
        self.state = self.root / 'state'
        self.state.mkdir()
        self.env = dict(FM_ENGINE_ROOT=str(self.root), FM_TARGET_ROOT=str(self.root),
                        FM_STATE_DIR=str(self.state), FM_PROJECT='firstmate-workflow', FM_EXTERNAL='0',
                        FM_TASKS_DIR=str(self.spec.parent), FM_DESIGN=str(self.root / 'design/design.md'))
        self.p = Pins(self.env, 'T-X')

    def event(self, typ='greenlit', ts='2026-10-03T00:00:00Z', **kwargs):
        event = dict(type=typ, ts=ts, actor='captain', **kwargs)
        with (self.state / 'events.jsonl').open('a') as f:
            f.write(json.dumps(event) + '\n')
        return event

    def decision(self, id='D-1', project='firstmate-workflow', task='T-X', chosen='A', kind='choice', ts='2026-10-03T00:01:00Z'):
        (self.state / 'decisions').mkdir(exist_ok=True)
        (self.state / f'decisions/{id}.json').write_text(json.dumps(dict(
            id=id, project=project, task=task, chosen=chosen, kind=kind, ts=ts)))
        self.event('decision_made', ts=ts, project=project, task=task, data=dict(decision=id, chosen=chosen))

    def readiness(self, decision='D-1', retired=False):
        (self.state / 'ready').mkdir(exist_ok=True)
        record = (dict(task='T-X', ended=decision, ended_at='2026-10-03T00:03:00Z')
                  if retired else dict(task='T-X', decision=decision, episode='@-1/-1',
                                       judged_at='2026-10-03T00:00:00Z'))
        (self.state / 'ready/T-X.json').write_text(json.dumps(record))

    def legacy_pin(self):
        # Stand in for the fixed historical T-171 boundary with a fixture
        # descendant. All ancestry checks still run real git, offline, even
        # in shallow CI checkouts and in the CLI's separate Python process.
        boundary = 'f61b71457f18c4aec744ae1b9ff84b1bd5b84728'
        base = git(self.root, 'rev-parse', 'HEAD')
        git(self.root, 'commit', '--allow-empty', '-qm', 'fixture T-171 boundary')
        boundary_commit = git(self.root, 'rev-parse', 'HEAD')
        git(self.root, 'reset', '--hard', base)
        real_git = shutil.which('git')
        shim_dir = Path(self.tmp.name) / 'tools'
        shim_dir.mkdir()
        shim = shim_dir / 'git'
        shim.write_text('#!' + sys.executable + '\nimport os, sys\n'
                        + f'args = [a.replace({boundary!r}, {boundary_commit!r}) for a in sys.argv[1:]]\n'
                        + f'os.execv({real_git!r}, [{real_git!r}] + args)\n')
        shim.chmod(0o755)
        env_patch = patch.dict(os.environ, PATH=str(shim_dir) + os.pathsep + os.environ['PATH'],
                               HERDR_ENV='0')
        env_patch.start()
        self.addCleanup(env_patch.stop)
        self.event(task='T-X')
        first = self.p.create()
        event = self.event(task='T-166', ts='2026-10-02T07:53:54Z')
        first['approval'] = dict(kind='direct-order', author='captain',
                                 decision='greenlit:' + event['ts'], time=event['ts'], event=event)
        (self.p.directory / '1.json').write_text(json.dumps(first))
        return first, boundary_commit

    def pin_cli(self, *args):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        env['HERDR_ENV'] = '0'
        return subprocess.run(['bash', str(ROOT / 'bin/fm-project.sh'), 'repin',
            '--repo', str(self.root), '--project', 'firstmate-workflow', '--task', 'T-X',
            *args], env=env, capture_output=True, text=True)

    def legacy_gate(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        env.update(HERDR_ENV='0', FM_GATE_LOCK=str(Path(self.tmp.name) / 'gate.lock'))
        return subprocess.run(['bash', str(ROOT / 'bin/fm-gate.sh'), '--repo', str(self.root),
            '--task', 'T-X', '--branch', 'main', '--only', '3'],
            env=env, capture_output=True, text=True)

    def test_legacy_cli_repin_replaces_authority_without_snapshot_change(self):
        first, _ = self.legacy_pin()
        original = (self.p.directory / '1.json').read_bytes()
        with self.assertRaisesRegex(ValueError, 'pin authorization mismatch'):
            self.p.resolve()
        self.assertEqual(self.legacy_gate().returncode, 3)
        self.decision()
        result = self.pin_cli('--decision', 'D-1')
        self.assertEqual(result.returncode, 0, result.stderr)
        second = json.loads(result.stdout)
        self.assertEqual(second['version'], 2)
        self.assertEqual(second['supersedes_legacy'], 1)
        self.assertIn('T-171', second['supersedes_legacy_reason'])
        self.assertEqual(second['approval']['decision'], 'D-1')
        self.assertEqual({k: v['sha256'] for k, v in second['snapshots'].items()},
                         {k: v['sha256'] for k, v in first['snapshots'].items()})
        self.assertEqual((self.p.directory / '1.json').read_bytes(), original)
        self.assertEqual(self.p.resolve(), second)
        gate = self.legacy_gate()
        self.assertEqual(gate.returncode, 0, gate.stderr)
        # Ordinary unchanged repins still refuse, even above a legacy ancestor.
        self.decision('D-2', ts='2026-10-03T00:02:00Z')
        with self.assertRaisesRegex(ValueError, 'unchanged'):
            self.p.create(decision='D-2')
        self.spec.write_text('{"id":"T-X","scope":["new/**"]}')
        reused = self.pin_cli('--decision', 'D-1')
        self.assertEqual(reused.returncode, 65)
        self.assertIn('already used', reused.stderr)
        self.assertFalse((self.p.directory / '3.json').exists())

    def test_legacy_repin_rejects_wrong_authority_and_order(self):
        self.legacy_pin()
        for kwargs in (dict(task='T-Y'), dict(project='other'), dict(chosen='B'),
                       dict(kind='merge'), dict(kind='scope')):
            with self.subTest(**kwargs):
                self.decision(**kwargs)
                result = self.pin_cli('--decision', 'D-1')
                self.assertEqual(result.returncode, 65)
                self.assertIn('authorization', result.stderr)
                self.assertFalse((self.p.directory / '2.json').exists())
        self.decision(ts='2026-10-02T07:53:54Z')
        with self.assertRaisesRegex(ValueError, 'newer'):
            self.p.create(decision='D-1')

    def test_legacy_ancestor_under_existing_v2_and_v3(self):
        first, _ = self.legacy_pin()
        from fm_spec_pins import digest
        # Versions already appended under the old rule carry no migration
        # marker. Keep their exact bytes; their own choices authorize them.
        previous = first
        for version in (2, 3):
            self.decision(f'D-{version}', ts=f'2026-10-03T00:0{version}:00Z')
            record = dict(first, version=version, source='repin',
                          approval=self.p.approval(f'D-{version}'),
                          previous_sha256=digest(json.dumps(previous, sort_keys=True)))
            (self.p.directory / f'{version}.json').write_text(json.dumps(record))
            previous = record
        self.assertEqual(self.p.resolve(), previous)
        self.assertEqual(self.legacy_gate().returncode, 0)
        self.spec.write_text('{"id":"T-X","scope":["new/**"]}')
        for decision in ('D-2', 'D-3'):
            with self.assertRaisesRegex(ValueError, 'already used'):
                self.p.create(decision=decision)
        self.decision('D-4', ts='2026-10-03T00:04:00Z')
        fourth = self.p.create(decision='D-4')
        self.assertEqual(fourth['version'], 4)
        self.assertEqual(self.p.resolve(), fourth)

    def test_legacy_migration_does_not_bypass_corruption(self):
        first, _ = self.legacy_pin()
        self.decision()
        first['snapshots']['design']['text'] += 'corrupt'
        (self.p.directory / '1.json').write_text(json.dumps(first))
        with self.assertRaisesRegex(ValueError, 'snapshot hash mismatch'):
            self.p.create(decision='D-1')
        self.assertFalse((self.p.directory / '2.json').exists())

    def test_legacy_supersession_metadata_is_checked(self):
        self.legacy_pin()
        self.decision()
        second = self.p.create(decision='D-1')
        for fields in (dict(supersedes_legacy=2), dict(supersedes_legacy_reason=''),
                       dict(source='dispatch')):
            with self.subTest(**fields):
                (self.p.directory / '2.json').write_text(json.dumps(dict(second, **fields)))
                with self.assertRaisesRegex(ValueError, 'invalid legacy supersession'):
                    self.p.resolve()

    def test_legacy_migration_preserves_history_hash_checks(self):
        self.legacy_pin()
        self.decision()
        second = self.p.create(decision='D-1')
        second['previous_sha256'] = '0' * 64
        (self.p.directory / '2.json').write_text(json.dumps(second))
        with self.assertRaisesRegex(ValueError, 'history hash mismatch'):
            self.p.resolve()

    def test_post_t171_cross_task_pin_is_not_legacy(self):
        first, boundary = self.legacy_pin()
        first['engine_commit'] = boundary
        for snap in first['snapshots'].values():
            if 'commit' in snap:
                snap['commit'] = boundary
        (self.p.directory / '1.json').write_text(json.dumps(first))
        self.decision()
        with self.assertRaisesRegex(ValueError, 'pin authorization mismatch'):
            self.p.create(decision='D-1')
        self.assertFalse((self.p.directory / '2.json').exists())

    def test_unrelated_choice_never_dispatches(self):
        self.decision()
        self.assertIsNone(self.p.create())
        self.assertFalse(self.p.directory.exists())

    def test_greenlight_cannot_name_another_project_or_task(self):
        self.event(task='T-Y')
        self.event(project='other')
        self.assertIsNone(self.p.create())

    def test_scope_answer_before_first_pin_remains_repin_authority(self):
        self.readiness()
        self.decision()
        self.decision('D-2', ts='2026-10-03T00:02:00Z')
        first = self.p.create()
        self.assertEqual(first['approval']['decision'], 'D-1')
        self.spec.write_text('{"id":"T-X","scope":["wider/**"]}')
        second = self.p.create(decision='D-2')
        self.assertEqual(second['version'], 2)
        self.assertEqual(self.p.resolve(), second)

    def test_direct_order_survives_unrelated_choice(self):
        self.event()
        self.decision()
        pin = self.p.create()
        self.assertIsNotNone(pin, 'production project greenlight authorizes the first pin')
        self.assertEqual(pin['approval']['kind'], 'direct-order')

    def test_pre_pin_scope_answer_authorizes_cli_repin(self):
        self.event()
        self.decision()
        self.p.create()
        self.spec.write_text('{"id":"T-X","scope":["wider/**"]}')
        env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        result = subprocess.run(['bash', str(ROOT / 'bin/fm-project.sh'), 'repin',
            '--repo', str(self.root), '--project', 'firstmate-workflow', '--task', 'T-X',
            '--decision', 'D-1'], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['version'], 2)

    def test_wrong_task_readiness_cannot_dispatch(self):
        self.decision()
        self.readiness()
        (self.state / 'ready/T-X.json').write_text(json.dumps(
            dict(task='T-Y', decision='D-1', episode='@-1/-1')))
        self.assertIsNone(self.p.create())

    def test_project_greenlight_respects_only_own_readiness_answer(self):
        self.event()
        self.readiness()
        for chosen in ('B', 'C', 'D'):
            with self.subTest(chosen=chosen):
                self.decision(chosen=chosen)
                self.assertIsNone(self.p.create())
        self.decision()
        # Production legacy fixtures can have a receipt without decision_made.
        (self.state / 'events.jsonl').unlink()
        self.event()
        pin = self.p.create()
        self.assertEqual(pin['approval']['kind'], 'direct-order')
        self.assertEqual(self.p.resolve(), pin)

    def test_unanswered_readiness_blocks_project_greenlight(self):
        self.event()
        self.readiness()
        self.assertIsNone(self.p.create())

    def test_task_direct_order_overrides_readiness_hold(self):
        self.readiness()
        self.decision(chosen='B')
        self.event(task='T-X')
        pin = self.p.create()
        self.assertEqual(pin['approval']['kind'], 'direct-order')
        self.assertEqual(self.p.resolve(), pin)

    def test_resume_does_not_accept_wrong_commit_or_unapproved_bytes(self):
        self.event()
        base_text = self.spec.read_text()
        head = git(self.root, 'rev-parse', 'HEAD')
        self.spec.write_text('{"id":"T-X","scope":["unapproved/**"]}')
        self.decision()
        receipt = self.state / 'decisions/D-1.json'
        answer = json.loads(receipt.read_text())
        answer['expected_head'] = head
        receipt.write_text(json.dumps(answer))
        pin = self.p.create(resume=True, spec_worktree=self.root)
        self.assertEqual(pin['snapshots']['spec']['text'], base_text)
        self.assertNotIn('spec_approval', pin)

    def test_resumed_branch_requires_exact_unused_decision(self):
        self.event()
        base_text = self.spec.read_text()
        worktree = Path(self.tmp.name) / 'round'
        git(self.root, 'worktree', 'add', '-qb', 'task-branch', str(worktree), 'main')
        branch_spec = worktree / 'design/tasks/T-X.json'
        branch_spec.write_text('{"id":"T-X","scope":["wider/**"]}')
        git(worktree, 'add', '.')
        git(worktree, 'commit', '-qm', 'proposed task change')
        head = git(worktree, 'rev-parse', 'HEAD')
        self.decision()
        # An unrelated card cannot authorize these bytes, even on resume.
        first = self.p.create(resume=True, spec_worktree=worktree)
        self.assertEqual(first['snapshots']['spec']['text'], base_text)
        (self.p.directory / '1.json').unlink()
        receipt = self.state / 'decisions/D-1.json'
        answer = json.loads(receipt.read_text())
        answer['expected_head'] = head
        receipt.write_text(json.dumps(answer))
        pin = self.p.create(resume=True, spec_worktree=worktree)
        self.assertEqual(pin['snapshots']['spec']['text'], branch_spec.read_text())
        self.assertEqual(pin['approval']['kind'], 'direct-order')
        self.assertEqual(pin['spec_approval']['decision'], 'D-1')
        self.assertEqual(self.p.resolve(), pin)
        self.spec.write_text('{"id":"T-X","scope":["extra/**"]}')
        with self.assertRaisesRegex(ValueError, 'already used'):
            self.p.create(decision='D-1')
        self.decision('D-2', ts='2026-10-03T00:02:00Z')
        revised = self.p.create(decision='D-2')
        self.assertEqual(self.p.resolve(), revised)
        # Exact commit provenance and the receipt are rechecked by consumers.
        answer['expected_head'] = git(self.root, 'rev-parse', 'main')
        receipt.write_text(json.dumps(answer))
        with self.assertRaises(ValueError):
            self.p.resolve()

    def test_no_authorization_writes_nothing(self):
        self.assertIsNone(self.p.create())
        self.assertFalse((self.state / 'pins').exists())
        with self.assertRaisesRegex(ValueError, 'no pin'):
            self.p.resolve()

    def test_committed_self_direct_order_and_hashes(self):
        self.event()
        pin = self.p.create()
        self.assertEqual(pin['approval']['kind'], 'direct-order')
        self.assertEqual(pin['snapshots']['spec']['source'], 'committed')
        self.assertEqual(pin['contract']['docs'], ['docs/**'])
        self.assertEqual(self.p.resolve(), pin)
        self.spec.write_text('{}')
        self.assertEqual(self.p.resolve(), pin)
        with self.assertRaisesRegex(ValueError, 'task entry differs'):
            git(self.root, 'add', str(self.spec))
            git(self.root, 'commit', '-qm', 'worker rewrites scope')
            self.p.scope('HEAD', 'main')

    def test_readiness_and_resume(self):
        self.readiness(retired=True)
        self.decision()
        pin = self.p.create(resume=True)
        self.assertIsNotNone(pin, 'retired readiness still authorizes the first pin')
        self.assertEqual(pin['source'], 'first-pin-on-resume')
        self.assertEqual(pin['approval']['decision'], 'D-1')
        self.assertEqual(pin['approval']['author'], 'captain')
        self.assertEqual(self.p.create(), pin)

    def test_seeded_self(self):
        git(self.root, 'rm', str(self.spec))
        git(self.root, 'commit', '-qm', 'base without new task')
        self.spec.parent.mkdir(parents=True, exist_ok=True)
        self.spec.write_text('{"id":"T-X","scope":["src/**"]}')
        self.event()
        self.assertEqual(self.p.create()['snapshots']['spec']['source'], 'seeded')

    def test_changed_snapshot_and_authorized_repin(self):
        self.event()
        first = self.p.create()
        self.decision()
        with self.assertRaisesRegex(ValueError, 'unchanged'):
            self.p.create(decision='D-1')
        self.spec.write_text('{"id":"T-X","scope":["src/**"]}')
        self.decision('D-2', task='T-Y')
        with self.assertRaisesRegex(ValueError, 'authorization'):
            self.p.create(decision='D-2')
        second = self.p.create(decision='D-1')
        self.assertEqual(second['version'], 2)
        self.assertEqual(json.loads((self.state / 'pins/T-X/1.json').read_text()), first)
        self.assertEqual(self.p.resolve(), second)
        self.spec.write_text('{"id":"T-X","scope":["other/**"]}')
        with self.assertRaisesRegex(ValueError, 'already used'):
            self.p.create(decision='D-1')

    def test_repin_requires_strictly_newer_approval(self):
        self.event()
        first = self.p.create()
        self.spec.write_text('{"id":"T-X","scope":["wider/**"]}')
        for ts in ('2026-10-02T23:59:59Z', '2026-10-03T00:00:00Z',
                   '2026-10-03T08:00:00+08:00'):
            with self.subTest(ts=ts):
                self.decision(ts=ts)
                with self.assertRaisesRegex(ValueError, 'newer'):
                    self.p.create(decision='D-1')
                self.assertEqual(list(self.p.directory.glob('*.json')),
                                 [self.p.directory / '1.json'])
                self.assertEqual(self.p.resolve(), first)

    def test_empty_interrupted_store_is_absent_to_shell_consumers(self):
        self.p.directory.mkdir(parents=True)
        (self.p.directory / '.lock').touch()
        (self.p.directory / 'tmp-incomplete').write_text('partial')
        result = subprocess.run(['bash', '-c',
            '. "$1/bin/fm-config.sh"; fm_pin_existing T-X', '_', str(ROOT)],
            env=dict(os.environ, **self.env), capture_output=True, text=True)
        self.assertEqual(result.returncode, 3, result.stderr)
        self.event()
        self.assertEqual(self.p.create()['version'], 1)

    def test_corruption_and_fm_paths(self):
        self.event()
        pin = self.p.create()
        (self.root / '.fm-secret').write_text('secret')
        git(self.root, 'add', '.fm-secret')
        git(self.root, 'commit', '-qm', 'bad path')
        with self.assertRaisesRegex(ValueError, '.fm-'):
            self.p.scope('HEAD', pin['target_base_commit'])
        path = self.state / 'pins/T-X/1.json'
        pin['snapshots']['design']['text'] += 'tampered'
        path.write_text(json.dumps(pin))
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            self.p.resolve()

    def test_external_private_snapshots(self):
        home = Path(self.tmp.name) / 'private/projects/client'
        state = home / 'state'
        state.mkdir(parents=True)
        (home / 'tasks').mkdir()
        (home / 'tasks/T-X.json').write_text('{"id":"T-X","scope":["src/**"]}')
        (home / 'design.md').write_text('private design')
        (home / 'CONVENTIONS.md').write_text('private conventions')
        (state / 'config.yaml').write_text('project:\n  check: private-check\n  docs:\n    - guide/**\n')
        self.state = state
        self.readiness()
        self.decision(project='client')
        p = Pins(dict(self.env, FM_EXTERNAL='1', FM_PROJECT='client', FM_STATE_DIR=str(state),
                      FM_TASKS_DIR=str(home / 'tasks'), FM_DESIGN=str(home / 'design.md')), 'T-X')
        pin = p.create()
        self.assertEqual(pin['approval_binding'], 'dispatch-time')
        self.assertEqual(pin['contract']['docs'], ['guide/**'])
        (home / 'design.md').unlink()
        self.assertEqual(p.resolve(), pin)
        self.assertFalse((self.root / 'state/pins').exists())
        self.decision('D-2', project='client', ts='2026-10-03T00:02:00Z')
        (home / 'design.md').write_text('revised private design')
        (home / 'CONVENTIONS.md').write_text('revised private conventions')
        (home / 'tasks/T-X.json').write_text('{"id":"T-X","scope":["changed/**"]}')
        (state / 'config.yaml').write_text('project:\n  check: new-private-check\n')
        revised = p.create(decision='D-2')
        self.assertEqual(revised['version'], 2)
        for key in ('spec', 'design', 'conventions', 'contract'):
            self.assertNotEqual(pin['snapshots'][key]['sha256'], revised['snapshots'][key]['sha256'])
        self.assertEqual(p.resolve(), revised)

    def test_scope_and_committed_provenance(self):
        self.spec.write_text('{"id":"T-X","scope":["src/**"]}')
        git(self.root, 'add', '.')
        git(self.root, 'commit', '-qm', 'narrow scope')
        self.event()
        pin = self.p.create()
        (self.root / 'outside').write_text('x')
        git(self.root, 'add', 'outside')
        git(self.root, 'commit', '-qm', 'outside')
        with self.assertRaisesRegex(ValueError, 'out of scope: outside'):
            self.p.scope('HEAD', pin['target_base_commit'])
        pin['snapshots']['spec']['text'] = '{"id":"T-X","scope":["**"]}'
        import hashlib
        pin['snapshots']['spec']['sha256'] = hashlib.sha256(pin['snapshots']['spec']['text'].encode()).hexdigest()
        (self.state / 'pins/T-X/1.json').write_text(json.dumps(pin))
        with self.assertRaisesRegex(ValueError, 'committed provenance'):
            self.p.resolve()

    def test_relocated_contract_keeps_all_fields(self):
        (self.root / 'config.yaml').write_text("""projects:
  firstmate-workflow:
    repo: .
    github: owner/engine
    base: main
    required_check: ci
    project:
      setup: install-tool
      check: run-check
      test: run-test {file}
      tests:
        - tests/**
      docs:
        - guide/**
      check_env:
        MODE: fixture
""")
        git(self.root, 'add', 'config.yaml')
        git(self.root, 'commit', '-qm', 'relocate contract')
        self.event()
        pin = self.p.create()
        self.assertEqual(pin['contract'], dict(setup='install-tool', check='run-check',
                         test='run-test {file}', tests=['tests/**'], docs=['guide/**'],
                         check_env={'MODE': 'fixture'}))
        self.assertEqual(self.p.resolve(), pin)

    def test_repin_refuses_every_mismatched_approval(self):
        self.event()
        self.p.create()
        self.spec.write_text('{"id":"T-X","scope":["different/**"]}')
        for kwargs in (dict(project='other'), dict(task='T-Y'), dict(chosen='B'), dict(kind='merge')):
            with self.subTest(**kwargs):
                self.decision(**kwargs)
                with self.assertRaisesRegex(ValueError, 'authorization'):
                    self.p.create(decision='D-1')
                self.assertFalse((self.state / 'pins/T-X/2.json').exists())
        with self.assertRaisesRegex(ValueError, 'authorization'):
            self.p.create(decision='not-found')

    def test_repin_cli_default_and_explicit_self(self):
        self.event()
        self.p.create()
        for number, args in enumerate(([], ['--project', 'firstmate-workflow']), 1):
            self.spec.write_text(json.dumps({'id': 'T-X', 'scope': [f'src/{number}/**']}))
            self.decision(f'D-{number}', ts=f'2026-10-03T00:0{number}:00Z')
            env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
            result = subprocess.run(['bash', str(ROOT / 'bin/fm-project.sh'), 'repin',
                        '--repo', str(self.root), '--task', 'T-X', '--decision', f'D-{number}', *args],
                        env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['version'], number + 1)
        events = [json.loads(line) for line in (self.state / 'events.jsonl').read_text().splitlines()]
        emitted = [e for e in events if e['type'] == 'spec_repinned']
        self.assertEqual(len(emitted), 2)
        self.assertTrue(all(e['summary']['en'] and e['summary']['zh-TW'] for e in emitted))

    def test_repin_cli_external_emits_in_private_project(self):
        fm_home = Path(self.tmp.name) / 'private'
        home = fm_home / 'projects/client'
        self.state = home / 'state'
        self.state.mkdir(parents=True)
        (home / 'tasks').mkdir()
        (home / 'tasks/T-X.json').write_text('{"id":"T-X","scope":["src/**"]}')
        (home / 'design.md').write_text('private design')
        (home / 'CONVENTIONS.md').write_text('private conventions')
        (self.state / 'config.yaml').write_text('project:\n  check: true\n')
        target = home / 'repo'
        git(self.root, 'clone', '-q', str(self.root), str(target))
        git(target, 'remote', 'set-url', 'origin', 'https://github.com/owner/client.git')
        (self.root / 'config.yaml').write_text(
            'projects:\n  firstmate-workflow:\n    repo: .\n    github: owner/engine\n'
            '    base: main\n    required_check: ci\n'
            '  client:\n    github: owner/client\n    base: main\n    required_check: ci\n')
        self.event(project='client')
        p = Pins(dict(self.env, FM_EXTERNAL='1', FM_PROJECT='client',
                      FM_TARGET_ROOT=str(target), FM_STATE_DIR=str(self.state),
                      FM_TASKS_DIR=str(home / 'tasks'), FM_DESIGN=str(home / 'design.md')), 'T-X')
        first = p.create()
        (home / 'design.md').write_text('changed private design')
        self.decision(project='client')
        env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        env['FM_HOME'] = str(fm_home)
        result = subprocess.run(['bash', str(ROOT / 'bin/fm-project.sh'), 'repin',
            '--repo', str(self.root), '--project', 'client', '--task', 'T-X',
            '--decision', 'D-1'], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['version'], 2)
        self.assertEqual(json.loads((p.directory / '1.json').read_text()), first)
        emitted = [json.loads(line) for line in (self.state / 'events.jsonl').read_text().splitlines()
                   if json.loads(line)['type'] == 'spec_repinned']
        self.assertEqual(len(emitted), 1)
        self.assertEqual(emitted[0]['project'], 'client')
        self.assertEqual(emitted[0]['task'], 'T-X')
        self.assertTrue(emitted[0]['summary']['en'] and emitted[0]['summary']['zh-TW'])
        self.assertFalse((self.root / 'state/pins').exists())
        self.assertFalse((self.root / 'state/events.jsonl').exists())

    def test_no_pin_gate_has_specific_reason(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        env['FM_GATE_LOCK'] = str(Path(self.tmp.name) / 'gate.lock')
        result = subprocess.run(['bash', str(ROOT / 'bin/fm-gate.sh'), '--repo', str(self.root),
                    '--task', 'T-X', '--branch', 'main', '--only', '3'], env=env, text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 3)
        self.assertIn('no pin', result.stderr)


unittest.main()
