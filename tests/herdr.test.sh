#!/usr/bin/env bash
# No real Herdr control or model calls: lifecycle observations are isolated.
set -euo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys
import shutil
import subprocess
import signal
import time

sys.dont_write_bytecode = True  # Import production code without dirtying the checkout.
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('managed', root / 'bin/fm-herdr.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# A positive wait is for its real condition, against a deadline wide enough
# for a loaded machine. Counts of short sleeps - two seconds for the first
# worker's prompt, five for a run to settle - ran out under the gate's
# parallel pool while the process they waited on was still on its way. The
# loop returns the moment the condition holds, so the width costs nothing on
# a quiet machine. Negative windows (nothing happens within N) are not this.
WAIT = 120
def eventually(predicate, seconds=WAIT):
    end = time.monotonic() + seconds
    while True:
        value = predicate()
        if value or time.monotonic() > end: return value
        time.sleep(.02)

class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.run = m.allocate(self.root, 'worker', 'T-035', '')
        self.owner = dict(owned=True, actor=self.run.name, task='T-035',
                          run=str(self.run), run_token=self.run.name, pane_id='owned', caller='caller',
                          terminal_id='terminal', shell_pid=91, tab_id='tab-owned',
                          caller_tab='tab-caller', workspace_id='workspace')
        m.save(self.run / 'owner.json', self.owner)
        # Observed on real Herdr (2026-09-23/24): after the adapter exits and the
        # pane is back at an idle shell prompt, `pane list` still reports
        # agent_status 'working'. The fixture reports what Herdr reports.
        self.pane = dict(pane_id='owned', terminal_id='terminal',
                         label=self.run.name, agent_status='working', tab_id='tab-owned', workspace_id='workspace',
                         tokens=dict(fm_actor=self.run.name, fm_task='T-035', fm_run=self.run.name))
        self.proc = dict(pane_id='owned', shell_pid=91, foreground_processes=[dict(pid=91)])
        self.tab = dict(tab_id='tab-owned', workspace_id='workspace', label=self.run.name, pane_count=1)
        self.layout = dict(tab_id='tab-owned', workspace_id='workspace', panes=[dict(pane_id='owned')], splits=[])
        self.calls = []
        (self.run / 'final.txt').write_text('Evidence.\nWORKER_COMPLETE:T-035\n')
        (self.run / 'cli.log').write_text('transcript')
        m.save(self.run / 'result.json', dict(actor=self.run.name, task='T-035', exit_code=0, status='completed'))
    def control(self, *args):
        self.calls.append(args)
        if args == ('api', 'snapshot'): return dict(snapshot=dict(tabs=[self.tab], panes=[self.pane], layouts=[self.layout]))
        if args[:2] == ('pane', 'get'): return dict(pane=self.pane)
        if args[:2] == ('pane', 'process-info'): return dict(process_info=self.proc)
        if args[:2] == ('pane', 'close'):
            self.assertTrue((self.run / 'result.json').is_file())
            self.assertTrue((self.run / 'final.txt').is_file())
            self.assertTrue((self.run / 'cli.log').is_file())
            return {}
        raise AssertionError(args)
    def close(self):
        return m.close_owned(self.run, self.owner, self.control)
    def test_completed_closes_only_owned_after_evidence(self):
        self.assertEqual('closed', self.close())
        self.assertEqual(('pane', 'close', 'owned'), self.calls[-1])
    def test_herdr_still_reporting_working_decides_nothing(self):
        # T-044: a stale 'working' neither closes nor retains; the shell and
        # the result do. Each retain case keeps agent_status 'working' too.
        self.assertEqual('working', self.pane['agent_status'])
        self.assertEqual('closed', self.close())
        self.assertIn(('pane', 'close', 'owned'), self.calls)
        def retained(expected):
            self.calls.clear(); self.assertEqual(expected, self.close())
            self.assertFalse(any(c[:2] == ('pane', 'close') for c in self.calls))
        self.proc['foreground_processes'] = [dict(pid=91), dict(pid=4242)]
        retained('retained: busy or shell changed')
        self.proc['foreground_processes'] = [dict(pid=91)]
        m.save(self.run / 'result.json', dict(actor=self.run.name, task='T-035', exit_code=0, status='blocked'))
        retained('retained: incomplete result')
        m.save(self.run / 'result.json', dict(actor=self.run.name, task='T-035', exit_code=0, status='completed'))
        self.pane['tokens']['fm_actor'] = 'other'
        retained('retained: pane identity or state changed')
        self.pane['tokens']['fm_actor'] = self.run.name
        self.pane['terminal_id'] = 'reused'
        retained('retained: pane identity or state changed')
    def test_uncertain_observations_never_target_close(self):
        variants = [('pane', 'terminal_id', 'reused'), ('pane', 'pane_id', 'caller'),
                    ('pane', 'label', 'other'),
                    ('pane', 'tab_id', 'tab-caller'), ('tab', 'pane_count', 2),
                    ('tab', 'label', 'reused'), ('tab', 'workspace_id', 'elsewhere'),
                    ('layout', 'panes', [dict(pane_id='owned'), dict(pane_id='user')]),
                    ('layout', 'splits', [dict(id='split')]),
                    ('proc', 'shell_pid', 92), ('proc', 'foreground_processes', []),
                    ('proc', 'foreground_processes', [dict(pid=99)])]
        for obj, key, value in variants:
            with self.subTest(obj=obj, key=key):
                target = getattr(self, obj); old = target.get(key); target[key] = value
                self.calls.clear(); self.assertNotEqual('closed', self.close())
                self.assertFalse(any(c[:2] == ('pane', 'close') for c in self.calls))
                target[key] = old
        for key in ['fm_task', 'fm_run', 'fm_actor']:
            old = self.pane['tokens'][key]; self.pane['tokens'][key] = 'other'
            self.assertNotEqual('closed', self.close()); self.pane['tokens'][key] = old
    def test_rc_zero_is_not_completion(self):
        for status in ['blocked', 'failed', 'incomplete', 'unknown', '']:
            m.save(self.run / 'result.json', dict(actor=self.run.name, task='T-035', exit_code=0, status=status))
            self.assertNotEqual('closed', self.close())
        self.assertEqual('unknown', m.completion('worker', 'T-035', 'quoted WORKER_COMPLETE:T-035'))
        self.assertEqual('blocked', m.completion('worker', 'T-035', 'WORKER_BLOCKED:T-035'))
        self.assertEqual('unknown', m.completion('worker', 'T-035', 'WORKER_BLOCKED:T-035\nWORKER_COMPLETE:T-035'))
        self.assertEqual('completed', m.completion('reviewer', 'T-035', 'REJECT:T-035\nREVIEWER_COMPLETE:T-035'))
    def test_changed_owner_and_caller_retained(self):
        m.save(self.run / 'owner.json', {**self.owner, 'task':'other'})
        self.assertNotEqual('closed', self.close())
        self.owner['caller'] = 'owned'; m.save(self.run / 'owner.json', self.owner)
        self.assertNotEqual('closed', self.close())
        self.owner['caller'] = 'caller'; self.owner['owned'] = False
        m.save(self.run / 'owner.json', self.owner)
        self.assertNotEqual('closed', self.close())
    def test_missing_evidence_retained(self):
        (self.run / 'final.txt').unlink()
        self.assertNotEqual('closed', self.close())
    def test_pane_child_publishes_last_result_and_closes(self):
        attempt = self.run / 'codex-child'
        attempt.mkdir()
        owner = dict(self.owner, run=str(attempt), run_token=attempt.name)
        m.save(attempt / 'owner.json', owner)
        self.pane['tokens'] = dict(fm_actor=self.run.name, fm_task='T-035', fm_run=attempt.name)
        (attempt / 'final.txt').write_text('Evidence.\nWORKER_COMPLETE:T-035\n')
        (attempt / 'cli.log').write_text('transcript')
        m.save(attempt / 'result.json', dict(actor=self.run.name, task='T-035',
               exit_code=0, status='completed'))
        result = dict(actor=self.run.name, task='T-035', exit_code=0, status='completed',
                      chain_attempt='token')
        m.publish_last_result(attempt, result)
        last = json.loads((self.run / 'last-result.json').read_text())
        self.assertEqual(str(attempt), last['attempt'])
        self.assertEqual('completed', last['status'])
        close = m.close_from_child(attempt, owner, result, control=self.control, wait_pid=0)
        self.assertEqual('closed', close)
        self.assertIn(('pane', 'close', 'owned'), self.calls)
        recorded = json.loads((attempt / 'close.json').read_text())
        self.assertEqual('closed', recorded['status'])
        self.assertEqual('pane-child', recorded['source'])
    def test_reconnect_notice_before_a_complete_result_is_still_provenance(self):
        # These CLIs print transport notices onto the transcript stream. Reading
        # the file as one object filed the finished worker as uncertain, and an
        # uncertain run keeps its pane: one reconnect left the tab open for good.
        answer='Done.\nWORKER_COMPLETE:T-035\n'
        log=self.run/'noisy.log'
        log.write_text('Connection lost, reconnecting to https://vendor.invalid (attempt 1)...\n'
                       'Retry attempt 1...\n'
                       +json.dumps(dict(type='result',subtype='success',is_error=False,result=answer))+'\n')
        self.assertEqual(answer,m.cli_final('cursor-agent',log))
        self.assertEqual('completed',m.completion('worker','T-035',m.cli_final('cursor-agent',log)))
        log.write_text(json.dumps(dict(type='result',is_error=False,result=answer),indent=2))
        self.assertEqual(answer,m.cli_final('cursor-agent',log))
        log.write_text(json.dumps(dict(response=answer))+'\n')
        self.assertEqual(answer,m.cli_final('gemini',log))
    def test_partial_failed_or_superseded_vendor_output_authorizes_nothing(self):
        log=self.run/'partial.log'
        log.write_text('Connection lost...\n{"type":"result","is_error":false,"result":"Done')
        self.assertIsNone(m.cli_final('cursor-agent',log))
        log.write_text(json.dumps(dict(type='result',is_error=True,result='Done'))+'\n')
        self.assertIsNone(m.cli_final('cursor-agent',log))
        log.write_text(json.dumps(dict(is_error=False,result='Done'))+'\n')
        self.assertIsNone(m.cli_final('cursor-agent',log))
        # A retry appends: the earlier success must not speak for the later failure.
        log.write_text(json.dumps(dict(type='result',is_error=False,result='Done'))+'\n'
                       +json.dumps(dict(type='result',is_error=True,result='then failed'))+'\n')
        self.assertIsNone(m.cli_final('cursor-agent',log))
        # Vendors that publish their own final answer are not parsed at all.
        log.write_text(json.dumps(dict(type='result',is_error=False,result='Done'))+'\n')
        self.assertIsNone(m.cli_final('codex',log))
        self.assertIsNone(m.cli_final('cursor-agent',self.run/'absent.log'))
    def test_identity_concurrency_retry_alias_and_limits(self):
        # Distinct aliases: a live alias is refused (T-089), and every one of
        # these runs is live because none has finished.
        def new(i): return m.allocate(self.root, 'worker' if i % 2 else 'reviewer', 'T-035', f'Mira{i} Long')
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            runs = list(pool.map(new, range(24)))
        self.assertEqual(24, len({p.name for p in runs}))
        for p in runs:
            self.assertRegex(p.name, r'^(worker|reviewer)-mira[0-9]+-long-t035-r[0-9]+$')
            self.assertLessEqual(len(p.name), 32)
            self.assertEqual(p.name, json.loads((p / 'identity.json').read_text())['actor'])
        # The same alias again, once its holder has finished: the counter
        # still tells the runs apart.
        again = []
        for _ in range(3):
            again.append(m.allocate(self.root, 'reviewer', 'T-035', 'Mira Long'))
            m.save(again[-1] / 'orchestration-result.json', dict(process_exit=0))
        self.assertEqual(3, len({p.name for p in again}))
        self.assertEqual({'mira-long'}, {json.loads((p / 'identity.json').read_text())['name'] for p in again})
        for p in again: self.assertLessEqual(len(p.name), 32)
        # An alias the actor has no room for is refused, never cut (T-089).
        with self.assertRaisesRegex(RuntimeError, 'does not fit'):
            m.allocate(self.root, 'reviewer', 'T-035', 'Mira ' * 30)
    def test_snapshot_survives_source_change(self):
        (self.root / 'bin').mkdir(); (self.root / 'skills').mkdir()
        src = self.root / 'bin/example.sh'; src.write_text('original')
        snap = m.snapshot(self.root)
        src.write_text('changed')
        self.assertEqual('original', (snap / 'bin/example.sh').read_text())
        self.assertIn('bin/example.sh', json.loads((snap / 'manifest.json').read_text()))

class Roster(unittest.TestCase):
    """T-089: every crew member has a name of their own, from one fleet roster."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
    def name(self, run):
        return json.loads((run / 'identity.json').read_text())['name']
    def finish(self, run):
        # What fm_record_end writes when a run's orchestration ends.
        m.save(run / 'orchestration-result.json', dict(process_exit=0))
    def test_concurrent_workers_get_different_names(self):
        def new(i): return m.allocate(self.root, 'worker', f'T-{100 + i}', '')
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            runs = list(pool.map(new, range(6)))
        names = [self.name(run) for run in runs]
        self.assertEqual(6, len(set(names)), names)
        for run, name in zip(runs, names):
            self.assertIn(name, m.DEFAULT_ROSTER)
            self.assertRegex(run.name, r'^worker-' + name + r'-t1[0-9]+-r[0-9]+$')
    def test_worker_and_reviewer_live_at_once_never_share_a_name(self):
        worker = m.allocate(self.root, 'worker', 'T-200', '')
        reviewer = m.allocate(self.root, 'reviewer', 'T-200', '')
        other = m.allocate(self.root, 'reviewer', 'T-201', '')
        self.assertEqual(3, len({self.name(worker), self.name(reviewer), self.name(other)}))
        self.assertRegex(reviewer.name, r'^reviewer-' + self.name(reviewer) + r'-t200-r[0-9]+$')
    def test_a_tasks_reviewer_is_not_its_workers_name_even_when_free(self):
        worker = m.allocate(self.root, 'worker', 'T-220', '')
        self.finish(worker)  # the roster's first name is free again
        reviewer = m.allocate(self.root, 'reviewer', 'T-220', '')
        self.assertEqual(m.DEFAULT_ROSTER[0], self.name(worker))
        self.assertNotEqual(self.name(worker), self.name(reviewer))
    def test_a_tasks_reviewer_never_takes_its_workers_name_even_when_it_is_the_only_free_one(self):
        import io, contextlib
        (self.root / 'config.yaml').write_text('roster:\n  - ada\n  - bo\n')
        worker = m.allocate(self.root, 'worker', 'T-230', '')
        m.allocate(self.root, 'worker', 'T-231', '')  # bo is live
        self.finish(worker)          # ada is free again, and the only free name
        said = io.StringIO()
        with contextlib.redirect_stderr(said):
            reviewer = m.allocate(self.root, 'reviewer', 'T-230', '')
        self.assertEqual('ada', self.name(worker))
        self.assertEqual('bo2', self.name(reviewer))
        # ada is free, so the report must not say every name is live.
        self.assertEqual('fm-herdr: no roster name is free for this task (1 of 2 live,'
                         ' ada held by its other role); reusing bo as bo2\n', said.getvalue())
        # Round two of the worker, too, keeps clear of the reviewer's name.
        self.finish(reviewer)
        again = m.allocate(self.root, 'worker', 'T-230', '')
        self.assertEqual('ada', self.name(again))
        self.finish(again)
        with self.assertRaisesRegex(RuntimeError, "ada is this task's other role"):
            m.allocate(self.root, 'reviewer', 'T-230', 'ada')
    def test_second_round_keeps_the_first_rounds_name_when_free(self):
        holder = m.allocate(self.root, 'worker', 'T-300', '')
        first = m.allocate(self.root, 'worker', 'T-301', '')
        self.assertNotEqual(self.name(holder), self.name(first))
        # The roster's first name is free again, yet round two is the same person.
        self.finish(holder); self.finish(first)
        second = m.allocate(self.root, 'worker', 'T-301', '')
        self.assertEqual(self.name(first), self.name(second))
        self.assertNotEqual(first.name, second.name)
    def test_second_round_moves_on_when_the_first_name_is_live(self):
        first = m.allocate(self.root, 'worker', 'T-310', '')
        self.finish(first)
        taken = m.allocate(self.root, 'worker', 'T-311', self.name(first))
        second = m.allocate(self.root, 'worker', 'T-310', '')
        self.assertEqual(self.name(first), self.name(taken))
        self.assertNotEqual(self.name(first), self.name(second))
    def test_finished_and_dead_runs_free_their_names(self):
        first = m.allocate(self.root, 'worker', 'T-400', '')
        self.finish(first)
        self.assertEqual(self.name(first), self.name(m.allocate(self.root, 'reviewer', 'T-401', '')))
    def test_an_unfinished_run_is_live_until_proven_over(self):
        # Every path through run_is_live, one run at a time. No clock: a run
        # allocated long ago with nothing recorded yet is still starting.
        run = m.allocate(self.root, 'worker', 'T-410', '')
        identity = json.loads((run / 'identity.json').read_text())
        identity['created'] -= 86400
        m.save(run / 'identity.json', identity)
        self.assertTrue(m.run_is_live(run), 'no launcher record and no attempt yet')
        # A launcher this test starts and names itself, not the test's own process.
        token = 'fm-t089-launcher-' + run.name
        launcher = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(600)', token])
        self.addCleanup(lambda: (launcher.kill(), launcher.wait()))
        alive = dict(identity, pid=launcher.pid, token=token)
        m.save(run / 'process.json', alive)
        self.assertTrue(m.run_is_live(run), 'its launcher is alive')
        dead = subprocess.Popen(['true']); dead.wait()
        m.save(run / 'process.json', dict(identity, pid=dead.pid, token='no-such-command-token'))
        self.assertFalse(m.run_is_live(run), 'launcher gone, no attempt')
        attempt = run / 'codex-attempt'; attempt.mkdir()
        m.reserve_execution(attempt)
        self.assertTrue(m.run_is_live(run), 'launcher gone, an attempt reserved but not started')
        m.save(attempt / 'execution.json', dict(started=True))
        with m.locked(attempt / 'execution.lock', blocking=False):
            self.assertTrue(m.run_is_live(run), 'launcher gone, an attempt still running')
        self.assertFalse(m.run_is_live(run), 'launcher gone, every attempt ended')
        (run / 'process.json').unlink()
        self.assertFalse(m.run_is_live(run), 'no launcher record, every attempt ended')
        m.save(run / 'process.json', alive)
        self.assertTrue(m.run_is_live(run), 'its launcher is alive again')
        self.finish(run)
        self.assertFalse(m.run_is_live(run), 'an orchestration result ends it whatever else is alive')
    def test_actor_stays_within_32_when_the_counter_gains_a_digit(self):
        import hashlib, io, contextlib
        task = 'T-LONGTASKID'
        slug = 'tlon' + hashlib.sha256(task.encode()).hexdigest()[:5]
        runs = self.root / 'state/runs'
        def at_the_boundary(taken):
            # r99999 is taken, so the retry lands on r100000: room 6, then 5.
            m.save(runs / 'counter.json', dict(number=99998))
            (runs / f'reviewer-{taken}-{slug}-r99999').mkdir(exist_ok=True)
        # A reused name that still fits is reported and recorded whole.
        (self.root / 'config.yaml').write_text('roster:\n  - ada\n')
        m.allocate(self.root, 'worker', 'T-700', '')  # ada is live
        at_the_boundary('ada2')
        said = io.StringIO()
        with contextlib.redirect_stderr(said):
            run = m.allocate(self.root, 'reviewer', task, '')
        self.assertEqual(f'reviewer-ada2-{slug}-r100000', run.name)
        self.assertLessEqual(len(run.name), 32)
        self.assertIn('every roster name is live (1); reusing ada as ada2', said.getvalue())
        identity = json.loads((run / 'identity.json').read_text())
        self.assertEqual(('ada2', 'ada'), (identity['name'], identity['reused']))
        # A name with no room is refused, never cut into a label that is not
        # the live holder's: sophia is live, so sophi would be her in disguise.
        (self.root / 'config.yaml').write_text('roster:\n  - sophia\n  - sophie\n')
        m.allocate(self.root, 'worker', 'T-701', '')  # sophia is live
        at_the_boundary('sophie')
        with self.assertRaisesRegex(RuntimeError, 'crew name sophie does not fit'):
            m.allocate(self.root, 'reviewer', task, '')
        # The alias path, straight at r100000 (room 5): a live alias is refused
        # although only its first five letters would fit, and an alias with
        # no room is refused, not cut.
        m.allocate(self.root, 'worker', 'T-702', 'Abcdef')  # abcdef is live
        for alias, refusal in (('Abcdef', 'abcdef is live'), ('Uvwxyz', 'uvwxyz does not fit')):
            with self.subTest(alias=alias):
                m.save(runs / 'counter.json', dict(number=99999))
                with self.assertRaisesRegex(RuntimeError, refusal):
                    m.allocate(self.root, 'reviewer', task, alias)
        names = {json.loads(p.read_text())['name'] for p in runs.glob('*/identity.json')}
        self.assertEqual({'ada', 'ada2', 'sophia', 'abcdef'}, names)
        self.assertEqual([], [p.name for p in runs.glob('*') if len(p.name) > 32])
    def test_exhausted_roster_is_reported_and_names_the_reused_name(self):
        (self.root / 'config.yaml').write_text('vendor: claude\nroster:\n  - Ada\n  - Bo  # short\nconcurrency: 3\n')
        a = m.allocate(self.root, 'worker', 'T-500', '')
        b = m.allocate(self.root, 'reviewer', 'T-501', '')
        self.assertEqual(['ada', 'bo'], sorted([self.name(a), self.name(b)]))
        import io, contextlib
        said = io.StringIO()
        with contextlib.redirect_stderr(said):
            c = m.allocate(self.root, 'worker', 'T-502', '')
        self.assertEqual('ada2', self.name(c))
        self.assertRegex(c.name, r'^worker-ada2-t502-r[0-9]+$')
        self.assertIn('every roster name is live', said.getvalue())
        self.assertIn('reusing ada as ada2', said.getvalue())
        identity = json.loads((c / 'identity.json').read_text())
        self.assertEqual('ada', identity['reused'])
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual('ada3', self.name(m.allocate(self.root, 'worker', 'T-503', '')))
    def test_a_run_from_before_the_roster_holds_the_name_in_its_actor(self):
        # identity.json from before T-089: no `name`, only the actor.
        legacy = self.root / 'state/runs/worker-mira-t035-r5'; legacy.mkdir(parents=True)
        m.save(legacy / 'identity.json', dict(actor=legacy.name, role='worker', task='T-035',
                                              requested_alias='', run=str(legacy), created=1.0))
        self.assertEqual('mira', m.crew_name(json.loads((legacy / 'identity.json').read_text())))
        fresh = m.allocate(self.root, 'worker', 'T-800', '')
        self.assertEqual(m.DEFAULT_ROSTER[1], self.name(fresh))
        with self.assertRaisesRegex(RuntimeError, 'mira is live'):
            m.allocate(self.root, 'reviewer', 'T-801', 'mira')
    def test_live_alias_is_refused(self):
        first = m.allocate(self.root, 'worker', 'T-600', 'Juno')
        self.assertEqual('juno', self.name(first))
        with self.assertRaisesRegex(RuntimeError, 'juno is live'):
            m.allocate(self.root, 'reviewer', 'T-601', 'juno')
        with self.assertRaisesRegex(RuntimeError, 'juno is live'):
            m.allocate(self.root, 'worker', 'T-600', 'worker-Juno')
        self.finish(first)
        self.assertEqual('juno', self.name(m.allocate(self.root, 'reviewer', 'T-601', 'juno')))
    def test_roster_config_is_validated(self):
        (self.root / 'config.yaml').write_text('roster: [Ada, bo]\n')
        self.assertEqual(['ada', 'bo'], m.fleet_roster(self.root))
        (self.root / 'config.yaml').write_text('roster:\n  - ada\n  - ADA\n')
        with self.assertRaisesRegex(ValueError, 'more than once'):
            m.fleet_roster(self.root)
        (self.root / 'config.yaml').write_text('roster:\n  - mary-jane\n')
        with self.assertRaisesRegex(ValueError, 'roster'):
            m.fleet_roster(self.root)
        (self.root / 'config.yaml').write_text('vendor: claude\n')
        self.assertEqual(list(m.DEFAULT_ROSTER), m.fleet_roster(self.root))
        # An empty roster is refused like any other invalid one, not defaulted.
        for empty in ('roster:\nvendor: claude\n', 'roster: []\n', 'roster:\n'):
            with self.subTest(empty=empty):
                (self.root / 'config.yaml').write_text(empty)
                with self.assertRaisesRegex(ValueError, 'roster is empty'):
                    m.fleet_roster(self.root)

class Entrypoints(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        shutil.copytree(root / 'bin', self.repo / 'bin')
        shutil.copytree(root / 'skills', self.repo / 'skills')
        (self.repo / 'design').mkdir()
        (self.repo / 'design/tasks.json').write_text(json.dumps({'tasks':[dict(id='T-035',title='test',scope=['src/**'],depends_on=[],acceptance=['works'])]}))
        (self.repo / 'design/design.md').write_text('## 6. Gates\nEvidence\n## 8. Board\n')
        (self.repo / 'config.yaml').write_text('vendor: codex\nconcurrency: 2\n')
        self.fake = self.repo / 'fakebin'; self.fake.mkdir()
        self.env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        # The fake git below answers `config` with nothing, so the identity a
        # commit needs is the fixture's own: a worker whose commit fails stops.
        self.env.update(PATH=str(self.fake)+os.pathsep+os.environ['PATH'], HERDR_ENV='1', HERDR_PANE_ID='caller',
                        FM_ROOT=str(self.repo), FM_TEST_ROOT=str(self.repo), FM_HERDR_TIMEOUT=str(WAIT),
                        FM_GIT_NAME='t', FM_GIT_EMAIL='a@b.c')
        self.executable('herdr', r'''
import json, os, pathlib, subprocess, sys, uuid
r=pathlib.Path(os.environ['FM_TEST_ROOT']); a=sys.argv[1:]
with (r/'controls').open('a') as f: f.write(json.dumps(a)+'\n')
# A temp name that glob('pane-*') / glob('tab-*') can match is a half-written
# file the next `api snapshot` parses: concurrent launches went red at random
# on a JSONDecodeError inside the double. The dot keeps it out of both globs.
def inflight(p): return p.with_name('.'+p.name+'.tmp')
def save(p,v):
 t=inflight(p); t.write_text(json.dumps(v)); t.replace(p)
def pane(p):
 if p=='caller': return dict(pane_id=p, terminal_id='caller-terminal',tab_id='caller-tab',workspace_id='workspace')
 return json.loads((r/p).read_text())
result={}
if a[:2]==['tab','create']:
 assert '--no-focus' in a and '--focus' not in a
 assert a[a.index('--workspace')+1]=='workspace'
 p='pane-'+uuid.uuid4().hex
 t='tab-'+uuid.uuid4().hex
 v=dict(pane_id=p,terminal_id=p+'-terminal',tab_id=t,workspace_id='workspace',label='',tokens={},agent_status='idle')
 tab=dict(tab_id=t,workspace_id='workspace',label=a[a.index('--label')+1],pane_count=1)
 save(r/p,v); save(r/t,tab); result={'root_pane':v,'tab':tab}
 if os.environ.get('FM_TEST_FOCUS')=='changed': (r/'focus-changed').touch()
elif a==['api','snapshot']:
 panes=[pane(p.name) for p in r.glob('pane-*')]
 tabs=[json.loads(p.read_text()) for p in r.glob('tab-*')]
 layouts=[dict(tab_id=t['tab_id'],workspace_id='workspace',panes=[dict(pane_id=p['pane_id']) for p in panes if p['tab_id']==t['tab_id']],splits=[]) for t in tabs]
 focus='other' if (r/'focus-changed').exists() else 'caller'
 result={'snapshot':dict(panes=panes,tabs=tabs,layouts=layouts,focused_pane_id=focus,focused_tab_id='caller-tab',focused_workspace_id='workspace')}
 if (r/'malformed').exists(): result['snapshot']['layouts']=None
elif a[:2]==['pane','get']: result={'pane':pane(a[2])}
elif a[:2]==['pane','list']: result={'panes':[]}
# Leave a save() half-written, through the same naming save() uses, so the
# snapshot assertion cannot go stale by hand-spelling the temp name.
elif a[:2]==['test','inflight']: inflight(r/a[2]).write_text('{"pane_id": "half')
elif a[:2]==['pane','process-info']:
 shell=42
 if os.environ.get('FM_TEST_CHANGE')=='late-shell' and list(pathlib.Path(os.environ['FM_RUN_DIR']).glob('codex-*')):
  count=r/('count-'+a[3]); n=int(count.read_text())+1 if count.exists() else 1; count.write_text(str(n))
  if n>=2: shell=43
 # Derive foreground from the command this fake was asked to run, not only from
 # an injected busy flag — otherwise shell_only assertions are vacuous.
 fg=shell
 runner=r/'mock-runner.pid'
 if runner.exists():
  try:
   rpid=int(runner.read_text().strip())
   os.kill(rpid,0)
   fg=rpid
  except (ValueError, ProcessLookupError, OSError):
   pass
 if pane(a[3]).get('busy'):
  fg=99
 result={'process_info':dict(pane_id=a[3],shell_pid=shell,foreground_processes=[dict(pid=fg)])}
elif a[:2]==['pane','rename']:
 v=pane(a[2]); v['label']=a[3]; save(r/a[2],v)
elif a[:2]==['pane','report-metadata']:
 v=pane(a[2]); v['tokens']={a[i+1].split('=',1)[0]:a[i+1].split('=',1)[1] for i in range(len(a)-1) if a[i]=='--token'}; save(r/a[2],v)
elif a[:2]==['pane','report-agent']:
 # Observed on real Herdr (2026-09-23/24): once a pane has been 'working',
 # `pane list` keeps saying 'working' after the agent exits and the shell is
 # idle again, whatever state is reported afterwards.
 v=pane(a[2]); state=a[a.index('--state')+1]
 if v.get('agent_status')!='working': v['agent_status']=state
 save(r/a[2],v)
elif a[:2]==['agent','rename']:
 assert a[3]==pane(a[2])['label']
elif a[:2]==['pane','run']:
 assert a[2]!='caller'
 # Apply resource mutations before the child runs so ownership-safe close
 # (pane-child or transport) observes them. Mutating after a synchronous
 # child returns left autoclose racing a post-run fixture edit.
 v=pane(a[2]); change=os.environ.get('FM_TEST_CHANGE')
 if change=='moved': v['tab_id']='caller-tab'
 if change=='reused': v['terminal_id']='new-terminal'
 if change=='identity': v['tokens']['fm_actor']='other'
 if change=='busy': v['busy']=True
 if change=='unknown': v['tab_id']=None
 if change=='malformed': (r/'malformed').touch()
 if change=='shared':
  tab=json.loads((r/v['tab_id']).read_text()); tab['pane_count']=2; save(r/v['tab_id'],tab)
 if change=='added':
  save(r/('pane-user-'+a[2]),dict(pane_id='user',tab_id=v['tab_id'],workspace_id='workspace'))
 save(r/a[2],v)
 if os.environ.get('FM_TEST_ASYNC')=='1':
  import shlex
  child=subprocess.Popen(shlex.split(a[3]),stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
  (r/'mock-runner.pid').write_text(str(child.pid))
 else:
  subprocess.run(a[3],shell=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False)
elif a[:2]==['pane','close']:
 v=pane(a[2]); token=v['tokens']['fm_run']; run=pathlib.Path(token)
 if not run.is_absolute():
  matches=list(pathlib.Path(os.environ['FM_TEST_ROOT']).glob('state/runs/*/'+token))
  assert matches, token; run=matches[0]
 assert json.loads((run/'result.json').read_text())['status']=='completed'
 assert (run/'final.txt').stat().st_size and (run/'cli.log').stat().st_size
 (r/'closed').write_text(a[2])
else: raise SystemExit('unsupported fake Herdr command '+str(a))
print(json.dumps({'result':result}))
''')
        self.executable('codex', r'''
import os,pathlib,sys,time
r=pathlib.Path(os.environ['FM_TEST_ROOT']); prompt=sys.stdin.read()
actor=os.environ['FM_ACTOR']; role=os.environ['FM_ROLE']; task=os.environ['FM_TASK']
(r/(actor+'.prompt')).write_text(prompt)
assert actor in prompt and ('explicitly dispatched '+role) in prompt
if os.environ.get('FM_TEST_ASYNC')=='1':
 pathlib.Path('surviving-work').write_text(actor)
 pathlib.Path('.fm-say.md').write_text('retained evidence')
 (r/'model.pid').write_text(str(os.getpid()))
 while not (r/'release-model').exists(): time.sleep(.02)
# held until the test says so, rather than for a number of seconds a loaded
# machine can spend before the test has looked; T-089's same-name retirement
# test holds all three runs live here until it touches `release`
if os.environ.get('FM_TEST_HOLD'):
 while not (r/os.environ['FM_TEST_HOLD']).exists(): time.sleep(.02)
time.sleep(float(os.environ.get('FM_TEST_DELAY','0')))
marker=role.upper()+'_'+os.environ.get('FM_TEST_STATUS','COMPLETE')+':'+task
verdict=os.environ.get('FM_TEST_VERDICT','APPROVE')
final=(verdict+':'+task+'\n' if role=='reviewer' else 'Implemented\n')+marker+'\n'
if os.environ.get('FM_TEST_EMPTY')!='1':
 pathlib.Path(sys.argv[sys.argv.index('--output-last-message')+1]).write_text(final)
 print(final)
if role=='worker': pathlib.Path('work.txt').write_text('done')
raise SystemExit(int(os.environ.get('FM_TEST_EXIT','0')))
''')
        self.executable('git', r'''
import json,os,pathlib,sys
r=pathlib.Path(os.environ['FM_TEST_ROOT']); a=sys.argv[1:]
if a[0]=='show': print((r/'design/tasks.json').read_text())
elif a[0] in ('show-ref','ls-remote'): sys.exit(1)
elif a[:2]==['worktree','add']:
 pathlib.Path(a[-2]).mkdir(parents=True,exist_ok=True)
elif 'status' in a:
 p=pathlib.Path(a[a.index('-C')+1]); print('?? work.txt' if (p/'work.txt').exists() else '')
elif a[0]=='diff': print('diff --git a/test b/test\n+change')
elif a[0]=='branch': print('t-035-test')
''')
        self.executable('gh', "import sys\nprint('https://example.invalid/pull/35' if 'create' in sys.argv else '[]')\n")
    def executable(self, name, content):
        p=self.fake/name; p.write_text('#!'+sys.executable+'\n'+content); p.chmod(0o755)
    def invoke(self, script, args=(), **env):
        return subprocess.run(['bash',str(self.repo/'bin'/script),*args,'--repo',str(self.repo)],
                              env=dict(self.env,**env),capture_output=True,text=True,timeout=WAIT)
    def results(self): return list((self.repo/'state/runs').glob('*/last-result.json'))
    def wait_for(self, predicate):
        value=eventually(predicate)
        if value: return value
        self.fail('asynchronous process did not reach expected state')
    def no_live_runs(self):
        # In-process inspection must never inherit a developer's real Herdr.
        with patch.dict(os.environ, {'FM_TRANSPORT':'direct', 'FM_ALLOW_DIRECT':'1'}):
            return not any(r['live'] for r in m.inspect(self.repo)['runs'])
    def test_retained_worker_survives_timeout_interrupt_and_launcher_death(self):
        for ending in ('timeout', 'term', 'kill', 'runner-kill', 'direct-runner-kill'):
            with self.subTest(ending=ending):
                for name in ('release-model','model.pid','mock-runner.pid'):
                    (self.repo/name).unlink(missing_ok=True)
                env=dict(self.env,FM_TEST_ASYNC='1',FM_HERDR_TIMEOUT='.3' if ending=='timeout' else str(WAIT))
                if ending=='direct-runner-kill':
                    env['FM_TRANSPORT']='direct'
                    env['FM_ALLOW_DIRECT']='1'
                with tempfile.TemporaryFile(mode='w+') as output:
                    launcher=subprocess.Popen(['bash',str(self.repo/'bin/fm-worker.sh'),'--task','T-035'],
                        env=env,stdout=output,stderr=output,start_new_session=True)
                    runner=None; model=None
                    try:
                        self.wait_for(lambda:(self.repo/'model.pid').exists())
                        model=int((self.repo/'model.pid').read_text())
                        tree=self.repo/'state/worktrees/T-035'
                        actor=(tree/'surviving-work').read_text()
                        execution=next((self.repo/'state/runs'/actor).glob('*/execution.json'))
                        runner=json.loads(execution.read_text())['runner_pid']
                        if ending=='direct-runner-kill':
                            os.kill(launcher.pid,signal.SIGKILL)
                        elif ending!='timeout':
                            os.killpg(launcher.pid,signal.SIGTERM if ending=='term' else signal.SIGKILL)
                        launcher.wait(timeout=WAIT)
                        if ending in ('runner-kill','direct-runner-kill'): os.kill(runner,signal.SIGKILL)
                        status=self.invoke('fm-session.sh',['status'])
                        self.assertEqual(0,status.returncode,status.stderr)
                        run=next(r for r in json.loads(status.stdout)['runs'] if r['actor']==actor)
                        self.assertTrue(run['live'],run)
                        retry=self.invoke('fm-worker.sh',['--task','T-035'])
                        self.assertEqual(70,retry.returncode,retry.stderr)
                        self.assertEqual(actor,(tree/'surviving-work').read_text())
                        self.assertEqual('retained evidence',(tree/'.fm-say.md').read_text())
                    finally:
                        (self.repo/'release-model').touch()
                        if launcher.poll() is None:
                            os.killpg(launcher.pid,signal.SIGKILL); launcher.wait(timeout=5)
                        if model:
                            self.wait_for(lambda:not m.process_matches(dict(pid=model,token=str(self.fake/'codex'))))
                        if runner:
                            self.wait_for(lambda:not m.process_matches(dict(pid=runner,token=str(self.repo/'state/snapshots'))))
                            # A killed runner can leave the adapter alive; wait for its
                            # inherited lifetime lock to drain before the next retry.
                            self.wait_for(self.no_live_runs)
                    retry=self.invoke('fm-worker.sh',['--task','T-035'])
                    self.assertEqual(0,retry.returncode,retry.stderr)
                    self.assertNotEqual(actor,json.loads(max(self.results(),key=lambda p:p.stat().st_mtime_ns).read_text())['actor'])
    def test_relative_paths_through_all_frozen_entrypoints(self):
        subprocess.run([str(self.repo/'bin/fm-emit.sh'),'--actor','captain','--type','greenlit'],
                       env=self.env,check=True,capture_output=True)
        entries=[('fm-session.sh',['status']),('fm-worker.sh',['--task','T-035']),
                 ('fm-review.sh',['--task','T-035','--branch','work']),
                 ('fm-dispatch.sh',['--dry-run']),('fm-run.sh',['once'])]
        (self.repo/'bin/fm-gate.sh').write_text('#!/usr/bin/env bash\nexit 1\n')
        for script,args in entries:
            for source in ('repo-argument','environment','relative-script-argument','relative-script-environment'):
                with self.subTest(script=script,source=source):
                    env=dict(self.env,FM_TRANSPORT='direct',FM_ALLOW_DIRECT='1',FM_ROOT=self.repo.name)
                    entry=self.repo/'bin'/script
                    if source.startswith('relative-script'): entry=entry.relative_to(self.repo.parent)
                    argv=['bash',str(entry),*args]
                    if source.endswith('argument'): argv+=['--repo',self.repo.name]
                    result=subprocess.run(argv,cwd=self.repo.parent,env=env,capture_output=True,text=True,timeout=WAIT)
                    self.assertEqual(0,result.returncode,result.stderr)
                    self.assertNotIn('No such file or directory',result.stderr)
                    self.assertFalse((self.repo/self.repo.name).exists())
    def test_builtin_failure_then_custom_fallback_uses_current_output_and_receipt(self):
        self.executable('claude', "print('Authentication required.')\nraise SystemExit(2)\n")
        custom=self.repo/'bin/adapters/custom.sh'
        custom.write_text('#!/usr/bin/env bash\nprintf "REJECT:T-035 current custom verdict\\n" >> "$4"\n')
        custom.chmod(0o755)
        for vendor in ('custom','mock'):
            for transport in ('direct','herdr'):
                with self.subTest(vendor=vendor,transport=transport):
                    (self.repo/'config.yaml').write_text('vendor: claude\nfallback:\n  - '+vendor+'\n')
                    extra=dict(FM_TRANSPORT=transport,FM_MOCK_BODY='REJECT:T-035 current mock verdict')
                    if transport=='direct': extra['FM_ALLOW_DIRECT']='1'
                    answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'], **extra)
                    self.assertEqual(0,answer.returncode,answer.stderr)
                    self.assertIn('REJECT:T-035 current '+vendor+' verdict',answer.stdout)
                    path=max((self.repo/'state/runs').glob('*/orchestration-result.json'),key=lambda p:p.stat().st_mtime_ns)
                    receipt=json.loads(path.read_text())
                    self.assertEqual(vendor,receipt['adapter_result']['vendor'])
                    self.assertEqual('unknown',receipt['adapter_result']['status'])
                    self.assertNotIn('attempt',receipt['adapter_result'])
                    old=json.loads((path.parent/'last-result.json').read_text())
                    self.assertNotEqual(old['chain_attempt'],receipt['adapter_result']['chain_attempt'])
    def test_pending_launch_cannot_recreate_tree_or_claim_termination(self):
        run=m.allocate(self.repo,'worker','T-035','pending')
        attempt=run/'pending-attempt'; attempt.mkdir()
        m.reserve_execution(attempt)
        tree=self.repo/'state/worktrees/T-035'; tree.mkdir(parents=True)
        (tree/'sentinel').write_text('preserved')
        retry=self.invoke('fm-worker.sh',['--task','T-035'])
        self.assertEqual(70,retry.returncode,retry.stderr)
        self.assertEqual('preserved',(tree/'sentinel').read_text())
        status=self.invoke('fm-session.sh',['status'])
        record=next(r for r in json.loads(status.stdout)['runs'] if r['actor']==run.name)
        self.assertTrue(record['uncertain'])
        self.assertFalse(record['live'])
    def test_legacy_unfinished_attempt_is_uncertain_and_excluded(self):
        run=m.allocate(self.repo,'worker','T-035','legacy')
        attempt=run/'old-attempt'; attempt.mkdir()
        m.save(attempt/'invocation.json',dict(role='worker',task='T-035'))
        retry=self.invoke('fm-worker.sh',['--task','T-035'])
        self.assertEqual(70,retry.returncode,retry.stderr)
        status=self.invoke('fm-session.sh',['status'])
        record=next(r for r in json.loads(status.stdout)['runs'] if r['actor']==run.name)
        self.assertTrue(record['uncertain'])
        self.assertFalse(record['live'])
    def test_duplicate_task_options_lock_the_effective_task(self):
        run=m.allocate(self.repo,'worker','T-035','pending')
        attempt=run/'pending-attempt'; attempt.mkdir(); m.reserve_execution(attempt)
        reply=self.invoke('fm-worker.sh',['--task','T-unused','--task','T-035'])
        self.assertEqual(70,reply.returncode,reply.stderr)
        self.assertIn('already has a live worker',reply.stderr)
    def test_entrypoints_refuse_a_live_alias_in_one_line(self):
        live=m.allocate(self.repo,'worker','T-900','Juno')  # starting: no launcher record yet
        for script,args in (('fm-worker.sh',['--task','T-035','--name','juno']),
                            ('fm-review.sh',['--task','T-035','--branch','work','--name','Juno'])):
            with self.subTest(script=script):
                answer=self.invoke(script,args)
                self.assertEqual(70,answer.returncode,answer.stderr)
                self.assertIn('crew name juno is live in another run',answer.stderr)
                self.assertNotIn('Traceback',answer.stderr)
        self.assertEqual([live.name],[p.name for p in (self.repo/'state/runs').glob('*-juno-*')])
    def test_entrypoints_report_an_exhausted_roster(self):
        (self.repo/'config.yaml').write_text('vendor: codex\nconcurrency: 2\nroster:\n  - ada\n')
        m.allocate(self.repo,'worker','T-900','')  # ada is live
        answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'])
        self.assertEqual(0,answer.returncode,answer.stderr)
        self.assertIn('every roster name is live (1); reusing ada as ada2',answer.stderr)
        self.assertRegex(json.loads(self.results()[0].read_text())['actor'],r'^reviewer-ada2-t035-r[0-9]+$')
    def test_entrypoints_refuse_a_bad_roster_in_one_line(self):
        for roster,said in (('roster:\n  - mary-jane\n',"config.yaml roster: 'mary-jane' is not a short given name"),
                            ('roster: []\n','config.yaml roster is empty')):
            with self.subTest(roster=roster):
                (self.repo/'config.yaml').write_text('vendor: codex\n'+roster)
                answer=self.invoke('fm-worker.sh',['--task','T-035'])
                self.assertEqual(70,answer.returncode,answer.stderr)
                self.assertIn(said,answer.stderr)
                self.assertNotIn('Traceback',answer.stderr)
        self.assertEqual([],list((self.repo/'state/runs').glob('*/identity.json')))
    def test_real_reviewer_entrypoint_identity_and_final_provenance(self):
        answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work','--name','Noah'],
                           FM_TEST_VERDICT='REJECT')
        self.assertEqual(0,answer.returncode,answer.stderr)
        result=json.loads(self.results()[0].read_text()); actor=result['actor']
        self.assertRegex(actor,r'^reviewer-noah-t035-r[0-9]+$')
        events=[json.loads(s) for s in (self.repo/'state/events.jsonl').read_text().splitlines()]
        self.assertEqual({actor},{e['actor'] for e in events})
        self.assertEqual(1,len([e for e in events if e['type']=='agent_finished']))
        rejected=[e for e in events if e['type']=='review_failed']
        self.assertEqual(1,len(rejected))
        self.assertEqual('rejected',rejected[0]['data']['review_outcome'])
        self.assertEqual('reviewer',rejected[0]['data']['role'])
        self.assertEqual(actor,rejected[0]['data']['crew_name'])
        self.assertEqual({'en':'Work description unavailable','zh-TW':'尚無工作說明'},
                         rejected[0]['data']['activity'])
        self.assertIn(actor,(self.repo/(actor+'.prompt')).read_text())
        calls=[json.loads(s) for s in (self.repo/'controls').read_text().splitlines()]
        self.assertIn(actor,next(c for c in calls if c[:2]==['agent','rename']))
        self.assertTrue((self.repo/'closed').exists())
    def test_dedicated_tab_mapping_and_focus_for_each_role(self):
        for role in ('worker','review'):
            args=['--task','T-035'] + (['--branch','work'] if role=='review' else [])
            answer=self.invoke('fm-'+role+'.sh',args)
            self.assertEqual(0,answer.returncode,answer.stderr)
        calls=[json.loads(s) for s in (self.repo/'controls').read_text().splitlines()]
        creates=[c for c in calls if c[:2]==['tab','create']]
        self.assertEqual(2,len(creates))
        self.assertFalse(any(c[:2] in (['pane','split'],['tab','close'],['tab','focus'],['pane','focus']) for c in calls))
        for path in self.results():
            result=json.loads(path.read_text()); attempt=Path(result['attempt'])
            owner=json.loads((attempt/'owner.json').read_text())
            tab=json.loads((self.repo/owner['tab_id']).read_text())
            pane=json.loads((self.repo/owner['pane_id']).read_text())
            self.assertEqual(result['actor'],tab['label'])
            self.assertEqual(owner['tab_id'],pane['tab_id'])
            self.assertEqual(result['actor'],pane['label'])
            environment=json.loads((attempt/'environment.json').read_text())
            self.assertEqual(owner['pane_id'],environment['HERDR_PANE_ID'])
            self.assertEqual(owner['tab_id'],environment['HERDR_TAB_ID'])
            self.assertEqual(result['actor'],environment['FM_ACTOR'])
            self.assertEqual('caller-tab',owner['caller_tab'])
            self.assertEqual('caller',owner['focus_before']['focused_pane_id'])
            self.assertEqual(owner['focus_before'],owner['focus_after'])
            self.assertEqual(1,tab['pane_count'])
            create=next(c for c in creates if result['actor'] in c)
            self.assertIn('--no-focus',create)
    def test_changed_focus_refuses_launch(self):
        answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'],FM_TEST_FOCUS='changed')
        self.assertNotEqual(0,answer.returncode)
        calls=[json.loads(s) for s in (self.repo/'controls').read_text().splitlines()]
        self.assertFalse(any(c[:2] in (['pane','run'],['pane','close'],['tab','close']) for c in calls))
    def test_changed_resources_retained_through_real_entrypoint(self):
        for change in ('added','moved','shared','reused','busy','identity','unknown','malformed'):
            with self.subTest(change=change):
                answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'],FM_TEST_CHANGE=change)
                self.assertEqual(0,answer.returncode,answer.stderr)
                self.assertFalse((self.repo/'closed').exists())
                result=json.loads(self.results()[-1].read_text())
                self.assertEqual('completed',result['status'])
        calls=[json.loads(s) for s in (self.repo/'controls').read_text().splitlines()]
        self.assertFalse(any(c[:2] in (['pane','close'],['tab','close']) for c in calls))
    def test_real_worker_and_default_nonmanaged_optout(self):
        # Outside Herdr, in-process adapters are the default. Inside Herdr,
        # FM_TRANSPORT=direct is refused unless FM_ALLOW_DIRECT=1 (tests only).
        answer=self.invoke('fm-worker.sh',['--task','T-035'],HERDR_ENV='0')
        self.assertEqual(0,answer.returncode,answer.stderr)
        refused=self.invoke('fm-worker.sh',['--task','T-035'],FM_TRANSPORT='direct')
        self.assertEqual(70,refused.returncode,refused.stderr)
        self.assertIn('FM_TRANSPORT=direct is refused',refused.stderr)
        allowed=self.invoke('fm-worker.sh',['--task','T-035'],FM_TRANSPORT='direct',FM_ALLOW_DIRECT='1')
        self.assertEqual(0,allowed.returncode,allowed.stderr)
        self.assertFalse((self.repo/'controls').exists())
        self.assertEqual(2,len(self.results()))
        self.assertEqual(2,len({json.loads(p.read_text())['actor'] for p in self.results()}))
    def test_herdr_session_refuses_direct_for_worker_and_reviewer(self):
        worker=self.invoke('fm-worker.sh',['--task','T-035'],FM_TRANSPORT='direct')
        self.assertEqual(70,worker.returncode,worker.stderr)
        self.assertIn('FM_TRANSPORT=direct is refused',worker.stderr)
        review=self.invoke('fm-review.sh',['--task','T-035','--branch','work'],FM_TRANSPORT='direct')
        self.assertEqual(70,review.returncode,review.stderr)
        self.assertIn('FM_TRANSPORT=direct is refused',review.stderr)
        self.assertFalse((self.repo/'controls').exists())
        self.assertEqual([],self.results())
    def test_blocked_empty_failed_and_autoclose_optout(self):
        for extra in ({'FM_TEST_STATUS':'BLOCKED'}, {'FM_TEST_STATUS':'INCOMPLETE'},
                      {'FM_TEST_EMPTY':'1'}, {'FM_TEST_EXIT':'1'}, {'FM_AUTOCLOSE':'0'}):
            answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'],**extra)
            self.assertFalse((self.repo/'closed').exists(),answer.stderr)
    def test_snapshot_ignores_a_save_still_in_flight(self):
        # What the concurrent test hit at random, deterministically: one launch
        # saving a pane while another takes a snapshot.
        launch=self.invoke('fm-review.sh',['--task','T-035','--branch','work'])
        self.assertEqual(0,launch.returncode,launch.stderr)
        stub=str(self.fake/'herdr')
        subprocess.run([stub,'test','inflight','pane-inflight'],env=self.env,check=True)
        snapshot=subprocess.run([stub,'api','snapshot'],env=self.env,capture_output=True,text=True)
        self.assertEqual(0,snapshot.returncode,snapshot.stderr)
        panes=json.loads(snapshot.stdout)['result']['snapshot']['panes']
        self.assertTrue(panes)
        self.assertNotIn('pane-inflight',{p['pane_id'] for p in panes})
    def test_concurrent_same_task_reviewers_and_worker_retire_exact_actor(self):
        # A live alias is refused (T-089), so three live runs cannot share
        # `--name same`. A one-name roster keeps them as close as they can be:
        # same, same2, same3, where one actor's name is a prefix of the others.
        (self.repo/'config.yaml').write_text('vendor: codex\nconcurrency: 2\nroster:\n  - same\n')
        def launch(role):
            args=['--task','T-035']
            if role=='review': args += ['--branch','work']
            return self.invoke('fm-'+role+'.sh',args,FM_TEST_HOLD='release')
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            futures=[pool.submit(launch,role) for role in ['review','review','worker']]
            # All three are allocated while all three are live, then released.
            self.wait_for(lambda:len(list((self.repo/'state/runs').glob('*-t035-r*/identity.json')))>=3)
            (self.repo/'release').touch()
            answers=[future.result() for future in futures]
        for answer in answers: self.assertEqual(0,answer.returncode,answer.stderr)
        events=[json.loads(s) for s in (self.repo/'state/events.jsonl').read_text().splitlines()]
        started={e['actor'] for e in events if e['type'] in ('dispatched','review_opened')}
        ended=[e['actor'] for e in events if e['type']=='agent_finished']
        self.assertEqual(3,len(started)); self.assertEqual(started,set(ended)); self.assertEqual(3,len(ended))
        self.assertEqual({'same','same2','same3'},{a.split('-')[1] for a in started})
    def test_transport_failure_stops_worker_before_success(self):
        self.executable('herdr','raise SystemExit(7)')
        answer=self.invoke('fm-worker.sh',['--task','T-035'])
        self.assertEqual(70,answer.returncode,answer.stderr)
        self.assertNotIn('pr_opened',(self.repo/'state/events.jsonl').read_text())
    def test_new_role_resets_inherited_adapter_guard(self):
        answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'],
                           FM_CONTEXT_READY='1',FM_ATTEMPT_DIR='/unused-parent',FM_FINAL_PATH='/unused-parent/final')
        self.assertEqual(0,answer.returncode,answer.stderr)
        self.assertTrue((self.repo/'controls').exists())
        self.assertEqual(1,len(self.results()))
    def test_unknown_adapter_remains_configuration_error(self):
        answer=self.invoke('fm-worker.sh',['--task','T-035','--vendor','unknown'])
        self.assertEqual(65,answer.returncode,answer.stderr)
        self.assertFalse((self.repo/'controls').exists())
    def test_fallback_keeps_one_actor_and_owned_pane(self):
        self.executable('claude', "print('Authentication required.')\nraise SystemExit(2)\n")
        (self.repo/'config.yaml').write_text('vendor: claude\nfallback:\n  - codex\n')
        answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'])
        self.assertEqual(0,answer.returncode,answer.stderr)
        calls=[json.loads(s) for s in (self.repo/'controls').read_text().splitlines()]
        self.assertEqual(1,len([c for c in calls if c[:2]==['tab','create']]))
        names={c[3] for c in calls if c[:2]==['agent','rename']}
        self.assertEqual(1,len(names))
        result=json.loads(self.results()[0].read_text())
        self.assertEqual(names,{result['actor']})
        self.assertEqual(2,len(list(self.results()[0].parent.glob('*/result.json'))))
    def test_fallback_refuses_changed_owned_resources(self):
        self.executable('claude', "print('Authentication required.')\nraise SystemExit(2)\n")
        (self.repo/'config.yaml').write_text('vendor: claude\nfallback:\n  - codex\n')
        for change in ('added','moved','shared','reused','busy','identity','unknown','late-shell'):
            with self.subTest(change=change):
                answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'],FM_TEST_CHANGE=change)
                self.assertNotEqual(0,answer.returncode,answer.stderr)
        calls=[json.loads(s) for s in (self.repo/'controls').read_text().splitlines()]
        self.assertEqual(8,len([c for c in calls if c[:2]==['tab','create']]))
        self.assertEqual(8,len([c for c in calls if c[:2]==['pane','run']]))
        self.assertFalse(list(self.repo.glob('reviewer-*.prompt')), 'fallback model must not start')
        self.assertFalse(any(c[:2] in (['pane','close'],['tab','close']) for c in calls))
    def test_all_supported_cli_formats_inject_roles_and_keep_final(self):
        for vendor in ('claude','cursor-agent','gemini'):
            self.executable(vendor, r'''
import json,os,sys
prompt=sys.stdin.read(); assert os.environ['FM_ACTOR'] in prompt
assert 'explicitly dispatched reviewer' in prompt
assert '--output-format' in sys.argv and 'json' in sys.argv
final='REJECT:T-035\nREVIEWER_COMPLETE:T-035'
print(json.dumps({'type':'result','result':final,'response':final}))
''')
            answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work','--vendor',vendor])
            self.assertEqual(0,answer.returncode,answer.stderr)
            self.assertIn('REJECT:T-035',answer.stdout)
        self.assertEqual(3,len(self.results()))
        self.assertEqual({'completed'},{json.loads(p.read_text())['status'] for p in self.results()})
    def test_real_dispatch_and_run_paths_use_managed_adapters(self):
        # Production dispatch launches the production worker; only git/gh/model
        # boundaries are fake. No captain decision or external account is used.
        subprocess.run([str(self.repo/'bin/fm-emit.sh'),'--actor','captain','--type','greenlit'],
                       env=self.env,check=True,capture_output=True)
        answer=self.invoke('fm-dispatch.sh')
        self.assertEqual(0,answer.returncode,answer.stderr)
        paths=eventually(lambda:list((self.repo/'state/runs').glob('*/orchestration-result.json')))
        self.assertTrue(paths)
        self.assertEqual(0,json.loads(paths[0].read_text())['process_exit'])
        # Gate 7 requests a reviewer; gate execution itself is outside this test.
        (self.repo/'bin/fm-gate.sh').write_text('#!/usr/bin/env bash\nexit 7\n')
        answer=self.invoke('fm-run.sh',['once'])
        self.assertEqual(0,answer.returncode,answer.stderr)
        self.assertEqual({'worker','reviewer'},{json.loads(p.read_text())['role'] for p in self.results()})
    def test_running_adapter_uses_snapshot_after_source_edit(self):
        self.executable('codex',r'''
import os,pathlib,sys
r=pathlib.Path(os.environ['FM_TEST_ROOT'])
(r/'bin/adapters/codex.sh').write_text('#!/usr/bin/env bash\nexit 99\n')
pathlib.Path(sys.argv[sys.argv.index('--output-last-message')+1]).write_text('APPROVE:T-035\nREVIEWER_COMPLETE:T-035')
print('One invocation completed')
''')
        answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'])
        self.assertEqual(0,answer.returncode,answer.stderr)
        self.assertEqual(1,len(self.results()))
        record=json.loads(next((self.repo/'state/runs').glob('*/process.json')).read_text())
        self.assertNotEqual((self.repo/'bin/adapters/codex.sh').read_text(),
                            (Path(record['snapshot'])/'bin/adapters/codex.sh').read_text())
    def test_second_worker_cannot_recreate_live_task_tree(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            # the first worker's model is held until the second has been
            # refused, so "still live" is a fact of the fixture and not a
            # one-second head start the second run has to win
            first=pool.submit(self.invoke,'fm-worker.sh',['--task','T-035'],FM_TEST_HOLD='release-first')
            try:
                eventually(lambda:list(self.repo.glob('worker-*.prompt')))
                self.assertTrue(list(self.repo.glob('worker-*.prompt')))
                second=self.invoke('fm-worker.sh',['--task','T-035'])
            finally:
                (self.repo/'release-first').touch()
            self.assertEqual(70,second.returncode,second.stderr)
            self.assertIn('already has a live worker',second.stderr)
            self.assertEqual(0,first.result().returncode)
        self.assertEqual(1,len(self.results()))
    def test_managed_handoff_survives_transport_sighup(self):
        for name in ('release-model','model.pid','mock-runner.pid','closed'):
            (self.repo/name).unlink(missing_ok=True)
        env=dict(self.env,FM_TEST_ASYNC='1',FM_HERDR_TIMEOUT=str(WAIT),FM_TEST_DELAY='0')
        with tempfile.TemporaryFile(mode='w+') as output:
            launcher=subprocess.Popen(['bash',str(self.repo/'bin/fm-worker.sh'),'--task','T-035'],
                env=env,stdout=output,stderr=output,start_new_session=True)
            try:
                self.wait_for(lambda:(self.repo/'model.pid').exists())
                # Hangup the orchestrator only — not the pane-child adapter/model.
                # Stock entrypoints trap HUP; transport also ignores it.
                tree=subprocess.run(['ps','-ax','-o','pid=,ppid=,command='],
                                    capture_output=True,text=True,check=True)
                targets={launcher.pid}
                for line in tree.stdout.splitlines():
                    parts=line.split(None,2)
                    if len(parts)<3: continue
                    pid,ppid,cmd=int(parts[0]),int(parts[1]),parts[2]
                    if ppid in targets and ('fm-herdr.py' in cmd or 'fm-worker' in cmd or 'bash' in cmd):
                        targets.add(pid)
                for pid in targets:
                    try: os.kill(pid,signal.SIGHUP)
                    except ProcessLookupError: pass
                time.sleep(.3)
                self.assertIsNone(launcher.poll(),'managed wait must ignore SIGHUP')
                (self.repo/'release-model').touch()
                rc=launcher.wait(timeout=WAIT)
                # 73 is fm-worker's "had something to say, no PR" after the async
                # fixture writes .fm-say.md; handoff still completed.
                self.assertNotEqual(129,rc,'must not die from SIGHUP')
                self.assertIn(rc,(0,73),rc)
                self.assertEqual(1,len(self.results()))
                self.assertEqual('completed',json.loads(self.results()[0].read_text())['status'])
                self.assertTrue((self.repo/'closed').exists())
                closes=list((self.repo/'state/runs').glob('*/*/close.json'))
                self.assertTrue(closes)
                self.assertEqual('closed',json.loads(closes[0].read_text())['status'])
            finally:
                (self.repo/'release-model').touch()
                if launcher.poll() is None:
                    os.killpg(launcher.pid,signal.SIGKILL); launcher.wait(timeout=5)
    def test_pane_child_handoff_when_transport_killed(self):
        """Transport waiter death must not orphan last-result / owned close."""
        for name in ('release-model','model.pid','mock-runner.pid','closed'):
            (self.repo/name).unlink(missing_ok=True)
        env=dict(self.env,FM_TEST_ASYNC='1',FM_HERDR_TIMEOUT=str(WAIT),FM_TEST_DELAY='0')
        with tempfile.TemporaryFile(mode='w+') as output:
            launcher=subprocess.Popen(['bash',str(self.repo/'bin/fm-worker.sh'),'--task','T-035'],
                env=env,stdout=output,stderr=output,start_new_session=True)
            try:
                self.wait_for(lambda:(self.repo/'model.pid').exists())
                tree=subprocess.run(['ps','-ax','-o','pid=,ppid=,command='],
                                    capture_output=True,text=True,check=True)
                transports=[]
                repo_s=str(self.repo)
                for line in tree.stdout.splitlines():
                    parts=line.split(None,2)
                    if len(parts)<3: continue
                    pid,cmd=int(parts[0]),parts[2]
                    # Match only this fixture's waiter — ambient pane-child/transport
                    # processes from other runs must not absorb the SIGKILL.
                    if 'fm-herdr.py' in cmd and ' transport ' in cmd and repo_s in cmd:
                        transports.append(pid)
                self.assertTrue(transports,'managed transport process must be running')
                for pid in transports:
                    try: os.kill(pid,signal.SIGKILL)
                    except ProcessLookupError: pass
                def gone(pid):
                    try: os.kill(pid,0); return False
                    except ProcessLookupError: return True
                for pid in transports:
                    if not eventually(lambda:gone(pid)):
                        self.fail(f'transport {pid} survived SIGKILL')
                (self.repo/'release-model').touch()
                # Pane-child continues after the waiter dies; close may lag publish.
                self.wait_for(lambda:len(self.results())==1)
                def closed_by_child():
                    closes=list((self.repo/'state/runs').glob('*/*/close.json'))
                    if not closes: return False
                    close=json.loads(closes[0].read_text())
                    return close.get('status')=='closed' and close.get('source')=='pane-child'
                self.wait_for(closed_by_child)
                last=json.loads(self.results()[0].read_text())
                self.assertEqual('completed',last['status'])
                closes=list((self.repo/'state/runs').glob('*/*/close.json'))
                self.assertTrue(closes)
                close=json.loads(closes[0].read_text())
                self.assertEqual('closed',close['status'])
                self.assertEqual('pane-child',close.get('source'))
                self.assertTrue((self.repo/'closed').exists())
                # Launcher may exit non-zero after losing transport; that is not
                # success of the orchestrator path — only child durability.
                try: launcher.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(launcher.pid,signal.SIGKILL); launcher.wait(timeout=5)
            finally:
                (self.repo/'release-model').touch()
                if launcher.poll() is None:
                    os.killpg(launcher.pid,signal.SIGKILL); launcher.wait(timeout=5)


class EmitStatus(unittest.TestCase):
    """T-036: mid-run activity goes through emit-status → fm-emit.sh only."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root/'bin').mkdir(); (self.root/'state').mkdir()
        shutil.copy(root/'bin/fm-emit.sh', self.root/'bin/fm-emit.sh')
        shutil.copy(root/'bin/fm-herdr.py', self.root/'bin/fm-herdr.py')

    def events(self):
        path = self.root/'state/events.jsonl'
        if not path.exists(): return []
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def test_heartbeat_without_progress(self):
        rc = m.main(['emit-status','--root',str(self.root),'--actor','worker-h',
                     '--task','T-H','--role','worker','--en','still running','--tw','仍在跑'])
        self.assertEqual(0, rc)
        ev = self.events(); self.assertEqual(1, len(ev))
        self.assertEqual('crew_status', ev[0]['type'])
        self.assertEqual('still running', ev[0]['data']['activity']['en'])
        self.assertEqual('仍在跑', ev[0]['data']['activity']['zh-TW'])
        self.assertNotIn('progress', ev[0].get('data', {}))

    def test_bounded_progress_and_refusals(self):
        self.assertEqual(0, m.main(['emit-status','--root',str(self.root),'--actor','worker-h',
            '--task','T-H','--role','worker','--en','gates 3/7','--tw','關卡 3/7','--done','3','--total','7']))
        ev = self.events(); self.assertEqual({'done':3,'total':7}, ev[-1]['data']['progress'])
        with self.assertRaises(ValueError):
            m.main(['emit-status','--root',str(self.root),'--actor','worker-h',
                    '--task','T-H','--en','x','--tw','y','--done','1'])
        with self.assertRaises(ValueError):
            m.emit_status(self.root, 'worker-h', 'T-H', 'x', 'y', done=9, total=3)


unittest.main(argv=['herdr', *os.environ.get('FM_TEST_CASES','').split()], verbosity=2)
PY
