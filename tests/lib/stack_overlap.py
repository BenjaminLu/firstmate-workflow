"""T-278: approved-scope overlap, the approved-scope reader and dispatch holds.

Every case runs on a disposable self engine with committed approved sources.
Only GitHub is a stub; no network, no background process (dispatch is dry).
"""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

# Never notify a live Herdr from a fixture that raises cards.
os.environ['HERDR_ENV'] = '0'

sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_stack  # noqa: E402

A = 'a' * 40
CLEAN = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}


def feature(name):
    """The base has no such function; say so instead of an AttributeError."""
    value = getattr(fm_stack, name, None)
    if value is None:
        raise AssertionError('fm_stack.' + name + ' is absent (pre-T-278 base)')
    return value


class Engine:
    """A self engine: tasks {id: (scope, depends_on)}, approvals for `approved`."""

    def __init__(self, tmp, tasks, approved=None):
        self.root = Path(tmp) / 'engine'
        bin_dir = self.root / 'bin'
        (self.root / 'design/tasks').mkdir(parents=True)
        (self.root / 'state').mkdir()
        bin_dir.mkdir()
        for name in ('fm-config.sh', 'fm-herdr.py', 'fm-dispatch.sh', 'fm-ready.sh', 'fm-emit.sh'):
            shutil.copy(ROOT / 'bin' / name, bin_dir / name)
        shutil.copytree(ROOT / 'bin/lib', bin_dir / 'lib', ignore=shutil.ignore_patterns('__pycache__'))
        (bin_dir / 'fm-worker.sh').write_text('#!/usr/bin/env bash\nexit 0\n')
        (bin_dir / 'fm-worker.sh').chmod(0o755)
        (self.root / 'config.yaml').write_text('concurrency: 5\nproject:\n  check: true\n')
        (self.root / 'design/design.md').write_text('# design\n')
        for task, (scope, depends) in tasks.items():
            self.task(task, scope, depends)
        self.git('init', '-q', '-b', 'main')
        self.git('add', 'config.yaml', 'design')
        self.git('-c', 'user.email=a@b.c', '-c', 'user.name=t', 'commit', '-qm', 'approved sources')
        # Task-named greenlights only: a task-less one would approve every task.
        for task in (tasks if approved is None else approved):
            self.event(type='greenlit', actor='captain', task=task)
        self.gh_calls = self.root / 'ghcalls'
        self.pulls([])

    def task(self, task, scope, depends=()):
        (self.root / 'design/tasks' / (task + '.json')).write_text(json.dumps(dict(
            id=task, title='fixture ' + task, depends_on=list(depends), scope=scope, acceptance=['x'])) + '\n')

    def git(self, *args):
        subprocess.run(['git', '-C', str(self.root), *args], check=True, capture_output=True, timeout=60)

    def event(self, **row):
        row.setdefault('ts', '2026-10-03T00:00:00Z')
        with (self.root / 'state/events.jsonl').open('a') as out:
            out.write(json.dumps(row) + '\n')

    def flight(self, task, pr=None):
        self.event(type='dispatched', actor='firstmate', task=task)
        if pr:
            self.event(type='pr_opened', actor='github', task=task, pr=pr)

    def pulls(self, rows):
        stub = self.root / 'gh'
        (self.root / 'pulls.json').write_text(json.dumps(rows))
        stub.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "' + str(self.gh_calls) + '"\n'
                        'case "$1 $2" in\n  "pr list") cat "' + str(self.root / 'pulls.json') + '" ;;\n'
                        '  *) echo "unexpected GitHub call: $*" >&2; exit 1 ;;\nesac\n')
        stub.chmod(0o755)

    def policy(self, stacking='allowed', force=True):
        path = self.root / 'state/autopilot/self-stack-policy.json'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(dict(version=1, stacking=stacking, force_with_lease=force,
                                        captain_authorization='D-firstmate-workflow-T278-9')))

    def clear(self, task, number):
        decision = 'D-%d' % number
        subprocess.run(['bash', str(self.root / 'bin/fm-ready.sh'), 'judged', '--task', task,
                        '--decision', decision, '--repo', str(self.root)],
                       env=self.env(), capture_output=True, timeout=60)
        (self.root / 'state/decisions').mkdir(exist_ok=True)
        (self.root / 'state/decisions' / (decision + '.json')).write_text(json.dumps(
            dict(id=decision, chosen='A', task=task, kind='choice')) + '\n')

    def env(self):
        return dict(CLEAN, FM_ROOT=str(self.root), GH_REPO='fixture/project', FM_GH=str(self.root / 'gh'),
                    HERDR_ENV='0', FM_TRANSPORT='direct')

    def pin_env(self):
        return dict(CLEAN, FM_ENGINE_ROOT=str(self.root), FM_TARGET_ROOT=str(self.root),
                    FM_STATE_DIR=str(self.root / 'state'), FM_TASKS_DIR=str(self.root / 'design/tasks'),
                    FM_DESIGN=str(self.root / 'design/design.md'))

    def select(self, task, local_origin=False):
        """fm_stack select through bin/lib/fm-stack.sh, exactly as fm-worker.sh asks it."""
        env = self.env()
        if local_origin:
            # A local bare origin has no GitHub mapping; any repository lookup fails.
            del env['GH_REPO']
            bare = self.root.parent / 'origin.git'
            subprocess.run(['git', 'init', '-q', '--bare', str(bare)], check=True, capture_output=True, timeout=60)
            self.git('remote', 'add', 'origin', str(bare))
        out = subprocess.run(['bash', '-c', '. "$1/bin/fm-config.sh" && . "$1/bin/lib/fm-stack.sh" '
                              '&& fm_storage_init "$1" && fm_stack select --task "$2"', '_', str(self.root), task],
                             env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)
        return out.returncode, out.stdout.strip(), out.stderr

    def dispatch(self, *args):
        out = subprocess.run(['bash', str(self.root / 'bin/fm-dispatch.sh'), '--repo', str(self.root),
                              '--dry-run', *args], env=self.env(), capture_output=True, text=True,
                             stdin=subprocess.DEVNULL, timeout=120)
        started = [line for line in out.stdout.splitlines() if not line.startswith('fm-dispatch')]
        return out.returncode, started, out.stderr


class Overlap(unittest.TestCase):
    # (a) FAIL-FIRST: the base has no overlap function.
    def test_every_change_one_example_both_ways(self):
        overlap = feature('scopes_overlap')
        for left, right in (('bin/fm.sh', 'bin/fm.sh'), ('tests/lib/*.py', 'tests/lib/stack.py'),
                            ('tests/**', 'tests/lib/*.py'), ('*.md', 'docs/**')):
            self.assertTrue(overlap([left], [right]), (left, right))
            self.assertTrue(overlap([right], [left]), (right, left))
        for left, right in (('bin/fm.sh', 'bin/fm-merge.sh'), ('tests/lib/*.py', 'tests/e2e/*.ts'),
                            ('bin/lib/x.py', 'bin/lib/xy.py')):
            self.assertFalse(overlap([left], [right]), (left, right))
            self.assertFalse(overlap([right], [left]), (right, left))


class Reader(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.tmp = tmp.name

    # (b) FAIL-FIRST: the base has no approved-scope reader.
    def test_pinned_scope_wins_over_a_different_checkout_file(self):
        reader = feature('approved_scope')
        engine = Engine(self.tmp, {'T-1': (['src/**'], [])})
        from fm_spec_pins import Pins
        self.assertIsNotNone(Pins(engine.pin_env(), 'T-1').create())
        engine.task('T-1', ['elsewhere/**'])
        engine.git('-c', 'user.email=a@b.c', '-c', 'user.name=t', 'commit', '-qam', 'later edit')
        self.assertEqual(['src/**'], reader(engine.pin_env(), 'T-1'))

    def test_prospective_approved_snapshot_before_the_first_pin(self):
        reader = feature('approved_scope')
        engine = Engine(self.tmp, {'T-1': (['docs/**'], [])})
        # T-256: before the first pin a self spec is the local file the pin will freeze.
        engine.task('T-1', ['src/**'])
        self.assertEqual(['src/**'], reader(engine.pin_env(), 'T-1'))
        self.assertFalse((engine.root / 'state/pins').exists(), 'reading writes no pin')
        from fm_spec_pins import Pins
        self.assertIsNotNone(Pins(engine.pin_env(), 'T-1').create())
        engine.task('T-1', ['mutable/**'])  # after the pin, a local edit is never read
        self.assertEqual(['src/**'], reader(engine.pin_env(), 'T-1'))

    def test_no_approval_or_corrupt_pin_is_unreadable(self):
        reader = feature('approved_scope')
        engine = Engine(self.tmp, {'T-1': (['src/**'], []), 'T-2': (['lib/**'], [])}, approved=['T-2'])
        with self.assertRaisesRegex(ValueError, 'overlap check unavailable: T-1'):
            reader(engine.pin_env(), 'T-1')
        pins = engine.root / 'state/pins/T-2'
        pins.mkdir(parents=True)
        (pins / '1.json').write_text('{')
        with self.assertRaisesRegex(ValueError, 'overlap check unavailable: T-2'):
            reader(engine.pin_env(), 'T-2')


class Dispatch(unittest.TestCase):
    """(c) FAIL-FIRST: the base dispatches overlapping self tasks in parallel."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.tmp = tmp.name

    def engine(self, tasks, **kwargs):
        return Engine(self.tmp, tasks, **kwargs)

    def test_one_overlap_without_policy_holds_with_reason(self):
        engine = self.engine({'T-1': (['src/**'], []), 'T-2': (['src/a.py'], [])})
        engine.flight('T-1', 7)
        code, started, err = engine.dispatch('--task', 'T-2')
        self.assertEqual(0, code, err)
        self.assertEqual([], started)
        self.assertIn('T-2 overlaps T-1 (PR #7)', err)
        self.assertFalse(engine.gh_calls.exists(), 'an overlap hold reads no GitHub')

    def test_two_overlaps_hold_listing_both_in_task_order(self):
        engine = self.engine({'T-9': (['src/**'], []), 'T-10': (['src/x/*.py'], []), 'T-2': (['src/x/a.py'], [])})
        engine.flight('T-10', 12)
        engine.flight('T-9')
        code, started, err = engine.dispatch('--task', 'T-2')
        self.assertEqual([], started)
        self.assertIn('T-2 overlaps T-9 (no PR yet), T-10 (PR #12)', err)

    def test_single_member_without_pr_holds_under_policy(self):
        engine = self.engine({'T-1': (['src/**'], []), 'T-2': (['src/**'], [])})
        engine.policy()
        engine.flight('T-1')
        code, started, err = engine.dispatch('--task', 'T-2')
        self.assertEqual([], started)
        self.assertIn('T-2 overlaps T-1 (no PR yet)', err)

    def test_dependency_plus_a_different_overlap_holds(self):
        engine = self.engine({'T-1': (['src/**'], []), 'T-3': (['docs/**'], []),
                              'T-2': (['src/b.py'], ['T-3'])})
        engine.policy()
        engine.flight('T-1', 7)
        engine.pulls([dict(number=7, headRefName='t-1-x', headRefOid=A, isCrossRepository=False, baseRefName='main')])
        code, started, err = engine.dispatch('--task', 'T-2')
        self.assertEqual([], started)
        self.assertIn('T-2 overlaps T-1 (PR #7), T-3 (no PR yet)', err)

    def test_dependency_and_overlap_on_the_same_task_stacks_once_under_policy(self):
        engine = self.engine({'T-1': (['src/**'], []), 'T-2': (['src/b.py'], ['T-1'])})
        engine.policy()
        engine.flight('T-1', 7)
        engine.pulls([dict(number=7, headRefName='t-1-x', headRefOid=A, isCrossRepository=False, baseRefName='main')])
        code, started, err = engine.dispatch('--task', 'T-2')
        self.assertEqual(0, code, err)
        self.assertEqual(['T-2'], started, err)
        calls = engine.gh_calls.read_text().splitlines()
        self.assertEqual(1, sum(call.startswith('pr list --repo fixture/project') for call in calls), calls)

    def test_stacked_overlap_parent_holds_with_one_level_reason(self):
        engine = self.engine({'T-1': (['src/**'], []), 'T-2': (['src/b.py'], [])})
        engine.policy()
        engine.flight('T-1', 7)
        engine.pulls([dict(number=7, headRefName='t-1-x', headRefOid=A, isCrossRepository=False,
                           baseRefName='t-0-base')])
        code, started, err = engine.dispatch('--task', 'T-2')
        self.assertEqual([], started)
        self.assertIn('T-2 waits for stacked PR #7 to reach main', err)

    def test_overlap_hold_releases_on_merge_and_on_close(self):
        for outcome in ('merged', 'closed'):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as tmp:
                engine = Engine(tmp, {'T-1': (['src/**'], []), 'T-2': (['src/b.py'], [])})
                engine.flight('T-1', 7)
                self.assertEqual([], engine.dispatch('--task', 'T-2')[1])
                engine.event(type=outcome, actor='github', task='T-1', pr=7)
                code, started, err = engine.dispatch('--task', 'T-2')
                self.assertEqual(['T-2'], started, err)

    def test_unreadable_scope_holds(self):
        engine = self.engine({'T-1': (['lib/**'], []), 'T-2': (['src/b.py'], [])}, approved=['T-2'])
        engine.flight('T-1', 7)
        code, started, err = engine.dispatch('--task', 'T-2')
        self.assertEqual([], started)
        self.assertIn('T-2 overlap check unavailable: T-1', err)

    def test_two_overlapping_candidates_in_one_run_select_only_one(self):
        engine = self.engine({'T-2': (['src/**'], []), 'T-3': (['src/c.py'], []), 'T-4': (['docs/**'], [])})
        for number, task in enumerate(('T-2', 'T-3', 'T-4'), 1001):
            engine.clear(task, number)
        code, started, err = engine.dispatch()
        self.assertEqual(0, code, err)
        self.assertEqual(['T-2', 'T-4'], started, err)
        self.assertIn('T-3 overlaps T-2 (no PR yet)', err)

    def test_second_dispatcher_on_old_events_sees_reservation_under_lock(self):
        engine = self.engine({'T-2': (['src/b.py'], []), 'T-3': (['src/**'], [])})
        spec = importlib.util.spec_from_file_location('fm_concurrent_t278', engine.root / 'bin/lib/fm_concurrent.py')
        module = importlib.util.module_from_spec(spec)
        with patch.dict(os.environ, engine.env(), clear=True):
            spec.loader.exec_module(module)
            prepare = module.prepare
            def raced(*args, **kwargs):
                eligible = prepare(*args, **kwargs)
                # Another dispatcher reserves T-3 after this one prepared.
                engine.flight('T-3')
                return eligible
            out, err = io.StringIO(), io.StringIO()
            with patch.object(module, 'prepare', side_effect=raced), \
                 contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                self.assertEqual(0, module.dispatch(engine.root, '', 'T-2', True, ''))
        self.assertNotIn('T-2', [line for line in out.getvalue().splitlines() if not line.startswith('fm-dispatch')])
        self.assertIn('T-2 overlaps T-3 (no PR yet)', err.getvalue())

    def test_nothing_in_flight_reads_no_scope(self):
        # REGRESSION: with nothing in flight the reader is never reached.
        engine = self.engine({'T-2': (['src/**'], [])}, approved=['T-9'])
        code, started, err = engine.dispatch('--task', 'T-2')
        self.assertEqual(['T-2'], started, err)


class Selector(unittest.TestCase):
    """Selector compatibility: local fixtures and every pin-valid task ID.

    FAIL-FIRST: the base selector resolves the GitHub repository before it
    reads anything, accepts only numeric T-/SK- IDs and ignores overlap.
    """

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.tmp = tmp.name

    def test_no_conflict_candidate_with_a_local_origin_needs_no_repository(self):
        engine = Engine(self.tmp, {'T-1': (['src/**'], []), 'T-Z': (['lib/**'], [])})
        engine.flight('T-1', 7)  # in flight, so the approved-scope reader runs for T-Z
        code, out, err = engine.select('T-Z', local_origin=True)
        self.assertEqual(0, code, err)
        self.assertEqual({'name': 'main'}, json.loads(out or 'null'))
        self.assertFalse(engine.gh_calls.exists(), 'a candidate with C empty reads no GitHub')

    def test_two_overlapping_non_numeric_ids_still_hold(self):
        engine = Engine(self.tmp, {'T-Z': (['src/**'], []), 'T-Y': (['src/a.py'], [])})
        engine.flight('T-Z')
        code, out, err = engine.select('T-Y', local_origin=True)
        self.assertEqual(65, code, err)
        self.assertIn('overlaps T-Z (no PR yet)', err)
        self.assertEqual('', out)

    def test_conflicts_list_numeric_ids_by_number_then_others_by_string(self):
        tasks = {task: (['src/**'], []) for task in ('SK-20', 'T-Z', 'T-10', 'T-B', 'T-9')}
        tasks['T-50'] = (['src/x.py'], [])
        engine = Engine(self.tmp, tasks)
        for task in ('T-Z', 'SK-20', 'T-B', 'T-10', 'T-9'):
            engine.flight(task)
        code, out, err = engine.select('T-50', local_origin=True)
        self.assertEqual(65, code, err)
        self.assertIn('overlaps T-9 (no PR yet), T-10 (no PR yet), SK-20 (no PR yet), '
                      'T-B (no PR yet), T-Z (no PR yet)', err)

    def test_dependency_only_hold_with_a_local_origin_needs_no_repository(self):
        # FAIL-FIRST: 93c49783 resolved the repository before select_base's local
        # refusal, so both holds exited with `GitHub repository unavailable`.
        for name, depends, allowed in (('hold policy, one dependency', ['T-1'], False),
                                       ('allowed policy, two dependencies', ['T-1', 'T-3'], True)):
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                engine = Engine(tmp, {'T-1': (['docs/**'], []), 'T-3': (['etc/**'], []),
                                      'T-2': (['src/**'], depends)})
                if allowed:
                    engine.policy()
                engine.flight('T-1', 7)
                lookups = engine.root / 'lookups'
                with (engine.root / 'bin/lib/fm-stack.sh').open('a') as out:
                    out.write('fm_stack_repository() { echo lookup >> "%s"; return 1; }\n' % lookups)
                code, out, err = engine.select('T-2', local_origin=True)
                self.assertEqual(65, code, err)
                self.assertIn('task waits for dependencies', err)
                self.assertEqual('', out)
                self.assertFalse(lookups.exists(), 'a local dependency hold resolves no repository')
                self.assertFalse(engine.gh_calls.exists(), 'a local dependency hold reads no GitHub')

    def test_allowed_dependency_only_candidate_keeps_the_qualified_pr_lookup(self):
        engine = Engine(self.tmp, {'T-1': (['docs/**'], []), 'T-2': (['src/**'], ['T-1'])})
        engine.policy()
        engine.flight('T-1', 7)
        engine.pulls([dict(number=7, headRefName='t-1-parent', headRefOid=A, isCrossRepository=False,
                           baseRefName='main')])
        code, out, err = engine.select('T-2')
        self.assertEqual(0, code, err)
        self.assertEqual({'name': 't-1-parent', 'head': A, 'pr': 7}, json.loads(out or 'null'))
        calls = engine.gh_calls.read_text().splitlines() if engine.gh_calls.exists() else []
        self.assertTrue(any(call.startswith('pr list --repo fixture/project') for call in calls), calls)


class NamedTestResult(unittest.TextTestResult):
    """Expose behavioral outcomes in the fail-first collector's line format."""
    def startTest(self, test):
        self._fm_failed = False
        self._fm_skipped = False
        super().startTest(test)

    def addFailure(self, test, err):
        self._fm_failed = True
        super().addFailure(test, err)

    def addError(self, test, err):
        self._fm_failed = True
        super().addError(test, err)

    def addSubTest(self, test, subtest, err):
        if err is not None:
            self._fm_failed = True
        super().addSubTest(test, subtest, err)

    def addSkip(self, test, reason):
        self._fm_skipped = True
        super().addSkip(test, reason)

    def stopTest(self, test):
        super().stopTest(test)
        if not self._fm_skipped:
            name = '%s.%s' % (type(test).__name__, test._testMethodName)
            sys.stdout.write('    %-52s %s\n' % (name, 'FAIL' if self._fm_failed else 'ok'))
            sys.stdout.flush()


if __name__ == '__main__':
    suite = unittest.TestLoader().loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(verbosity=2, resultclass=NamedTestResult).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
