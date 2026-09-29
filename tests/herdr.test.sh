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
            self.assertRegex(p.name, r'^(worker|reviewer)-mira[0-9]+-long-t035-r[0-9]+[a-z]*$')
            self.assertLessEqual(len(p.name), 32)
            self.assertEqual(p.name, json.loads((p / 'identity.json').read_text())['actor'])
        # The same alias again, once its holder has finished: the attempt
        # mark still tells the runs apart (T-116).
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
    """T-104: each installation draws 24 worker and 24 reviewer names, and a
    name always means one role. T-089 gave every crew member a name."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        seeded = patch.dict(os.environ, {'FM_ROSTER_SEED': 't104'})
        seeded.start(); self.addCleanup(seeded.stop)
        # the round and the project are the run's own (T-116), never the shell's
        for key in ('FM_ROUND', 'FM_PROJECT'): os.environ.pop(key, None)
    def name(self, run):
        return json.loads((run / 'identity.json').read_text())['name']
    def finish(self, run):
        # What fm_record_end writes when a run's orchestration ends.
        m.save(run / 'orchestration-result.json', dict(process_exit=0))
    def crew(self):
        return json.loads((self.root / 'state/crew/rosters.json').read_text())
    def pin(self, text):
        (self.root / 'config.yaml').write_text(text)
    def quiet(self, call, *args):
        import io, contextlib
        said = io.StringIO()
        with contextlib.redirect_stderr(said): value = call(*args)
        return value, said.getvalue()
    def runs(self):
        return sorted(p.parent.name for p in (self.root / 'state/runs').glob('*/identity.json'))
    def test_the_pool_holds_at_least_200_short_distinct_given_names(self):
        self.assertGreaterEqual(len(m.POOL), 200)
        self.assertEqual(len(m.POOL), len(set(m.POOL)))
        for name in m.POOL: self.assertRegex(name, r'^[a-z]{1,6}$')
    def test_the_draw_is_24_workers_and_24_reviewers_from_the_pool(self):
        crew, drawn = m.draw_rosters(self.root)
        self.assertTrue(drawn)
        self.assertEqual(crew, self.crew())
        self.assertEqual((24, 24), (len(crew['workers']), len(crew['reviewers'])))
        self.assertEqual(48, len(set(crew['workers']) | set(crew['reviewers'])))
        self.assertLessEqual(set(crew['workers']) | set(crew['reviewers']), set(m.POOL))
        self.assertRegex(crew['drawn_at'], r'^[0-9]{4}-[0-9]{2}-[0-9]{2}T')
        # The seed only makes the draw repeatable for tests; another seed, or
        # none, draws another crew.
        other = self.root / 'other'
        self.assertEqual(crew['workers'], m.draw_rosters(other)[0]['workers'])
        with patch.dict(os.environ, {'FM_ROSTER_SEED': 'another'}):
            self.assertNotEqual(crew['workers'], m.draw_rosters(other, redraw=True)[0]['workers'])
        with patch.dict(os.environ):
            del os.environ['FM_ROSTER_SEED']
            unseeded = m.draw_rosters(other, redraw=True)[0]
            self.assertNotEqual(unseeded['workers'], m.draw_rosters(other, redraw=True)[0]['workers'])
    def test_a_second_draw_keeps_the_crew_and_redraw_replaces_it(self):
        first, _ = m.draw_rosters(self.root)
        with patch.dict(os.environ, {'FM_ROSTER_SEED': 'another'}):
            again, drawn = m.draw_rosters(self.root)
            self.assertFalse(drawn)
            self.assertEqual(first, again)
            run = m.allocate(self.root, 'worker', 'T-100', '')
            self.assertEqual(first, self.crew())
            self.assertIn(self.name(run), first['workers'])
            redrawn, drawn = m.draw_rosters(self.root, redraw=True)
        self.assertTrue(drawn)
        self.assertNotEqual(first['workers'], redrawn['workers'])
        self.assertEqual(redrawn, self.crew())
    def test_a_run_draws_the_crew_when_there_is_none(self):
        self.assertFalse((self.root / 'state/crew/rosters.json').exists())
        reviewer = m.allocate(self.root, 'reviewer', 'T-100', '')
        self.assertEqual(self.crew()['reviewers'][0], self.name(reviewer))
    def test_a_broken_crew_is_refused_not_quietly_redrawn(self):
        path = self.root / 'state/crew/rosters.json'
        path.parent.mkdir(parents=True)
        path.write_text('{"workers": ["ada"], "reviewers": ["ada"]}\n')
        with self.assertRaisesRegex(ValueError, 'roster init --redraw'):
            m.allocate(self.root, 'worker', 'T-100', '')
        self.assertEqual('{"workers": ["ada"], "reviewers": ["ada"]}\n', path.read_text())
    def test_two_workers_and_a_reviewer_at_once_take_names_from_their_own_rosters(self):
        jobs = [('worker', 'T-101'), ('worker', 'T-102'), ('reviewer', 'T-101')]
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            runs = list(pool.map(lambda job: m.allocate(self.root, job[0], job[1], ''), jobs))
        crew = self.crew()
        names = [self.name(run) for run in runs]
        self.assertEqual(3, len(set(names)), names)
        self.assertIn(names[0], crew['workers'])
        self.assertIn(names[1], crew['workers'])
        self.assertIn(names[2], crew['reviewers'])
        for run, (role, task) in zip(runs, jobs):
            self.assertRegex(run.name, '^' + role + '-' + self.name(run) + '-' + task.lower().replace('-', '') + '-r[0-9]+[a-z]*$')
    def test_concurrent_workers_get_different_names(self):
        def new(i): return m.allocate(self.root, 'worker', f'T-{100 + i}', '')
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            runs = list(pool.map(new, range(6)))
        names = [self.name(run) for run in runs]
        self.assertEqual(6, len(set(names)), names)
        self.assertLessEqual(set(names), set(self.crew()['workers']))
    def test_a_name_is_never_used_for_the_other_role(self):
        crew, _ = m.draw_rosters(self.root)
        with self.assertRaisesRegex(RuntimeError, 'crew name ' + crew['reviewers'][0] + ' is on the reviewer roster'):
            m.allocate(self.root, 'worker', 'T-110', crew['reviewers'][0])
        with self.assertRaisesRegex(RuntimeError, 'crew name ' + crew['workers'][0] + ' is on the worker roster'):
            m.allocate(self.root, 'reviewer', 'T-110', crew['workers'][0])
        # Every worker is busy: the next worker is refused, never handed a
        # reviewer's name, although all 24 reviewers are free.
        for i in range(24): m.allocate(self.root, 'worker', f'T-2{i:02d}', '')
        with self.assertRaisesRegex(RuntimeError, r'the worker roster ran out: none of its 24 names is free \(24 live\)'):
            m.allocate(self.root, 'worker', 'T-300', '')
        self.assertEqual(24, len(self.runs()))
    def test_an_exhausted_reviewer_roster_fails_without_borrowing_a_worker_name(self):
        self.pin('rosters:\n  workers:\n    - bo\n  reviewers: [ada]\n')
        first = m.allocate(self.root, 'reviewer', 'T-500', '')
        self.assertEqual('ada', self.name(first))
        with self.assertRaisesRegex(RuntimeError, r'the reviewer roster ran out: none of its 1 names is free \(1 live\)'
                                                  r', and a name of the other role is never borrowed'):
            m.allocate(self.root, 'reviewer', 'T-501', '')
        self.assertEqual([first.name], self.runs())
        # bo was free all along; it is a worker's name.
        self.assertEqual('bo', self.name(m.allocate(self.root, 'worker', 'T-501', '')))
    def test_a_name_in_both_config_lists_is_refused(self):
        self.pin('rosters:\n  workers: [ada, bo]\n  reviewers:\n    - cy\n    - Bo\n')
        with self.assertRaisesRegex(ValueError, 'config.yaml rosters: bo is in both workers and reviewers'):
            m.allocate(self.root, 'worker', 'T-510', '')
        self.assertEqual([], self.runs())
    def test_pinned_rosters_override_the_drawn_crew(self):
        crew, _ = m.draw_rosters(self.root)
        self.pin('rosters:\n  reviewers: [' + crew['workers'][0] + ']\n')
        rosters = m.crew_rosters(self.root)
        self.assertEqual([crew['workers'][0]], rosters['reviewers'])
        # Pinned to the reviewers, so gone from the drawn workers.
        self.assertEqual(crew['workers'][1:], rosters['workers'])
        self.assertEqual(crew['workers'][0], self.name(m.allocate(self.root, 'reviewer', 'T-520', '')))
        self.assertEqual(crew['workers'][1], self.name(m.allocate(self.root, 'worker', 'T-521', '')))
    def test_the_old_roster_key_still_names_workers_with_one_warning(self):
        crew, _ = m.draw_rosters(self.root)
        self.pin('vendor: claude\nroster:\n  - Zed\n  - ' + crew['reviewers'][0] + '  # short\nconcurrency: 3\n')
        run, said = self.quiet(m.allocate, self.root, 'worker', 'T-530', '')
        self.assertEqual('zed', self.name(run))
        self.assertEqual(1, len(said.splitlines()), said)
        self.assertIn('config.yaml roster: is the old single roster', said)
        rosters, _ = self.quiet(m.crew_rosters, self.root)
        self.assertEqual(['zed', crew['reviewers'][0]], rosters['workers'])
        self.assertEqual(crew['reviewers'][1:], rosters['reviewers'])
        reviewer, _ = self.quiet(m.allocate, self.root, 'reviewer', 'T-531', '')
        self.assertEqual(crew['reviewers'][1], self.name(reviewer))
    def test_a_tasks_other_role_alias_is_refused(self):
        # A run under the one-role rule would refuse zed for its role first;
        # a run from before it binds no role, so only the task refuses it.
        self.history('worker', 'zed', 'T-230', 1)
        with self.assertRaisesRegex(RuntimeError, "zed is this task's other role"):
            m.allocate(self.root, 'reviewer', 'T-230', 'zed')
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
        self.assertEqual(self.name(first), self.name(m.allocate(self.root, 'worker', 'T-401', '')))
    def test_record_model_merges_what_the_round_ran_on(self):
        """T-127: vendor, model, model_requested, cli_version and
        model_mismatch join identity.json once the round has run - never at
        allocation, since none of it is known before then - beside the six
        fields T-116 already put there, and nothing already there is lost."""
        run = m.allocate(self.root, 'worker', 'T-600', '')
        before = json.loads((run / 'identity.json').read_text())
        identity = m.record_model(run, 'claude', 'claude-opus-5-5', 'claude-sonnet-5', '2.1.0')
        self.assertEqual('claude', identity['vendor'])
        self.assertEqual('claude-opus-5-5', identity['model_requested'])
        self.assertEqual('claude-sonnet-5', identity['model'])
        self.assertEqual('2.1.0', identity['cli_version'])
        self.assertTrue(identity['model_mismatch'])
        for k, v in before.items(): self.assertEqual(v, identity[k], k)
        on_disk = json.loads((run / 'identity.json').read_text())
        self.assertEqual(identity, on_disk)
        # requested and actual agree: no mismatch
        agree = m.record_model(run, 'claude', 'claude-opus-5-5', 'claude-opus-5-5', '2.1.0')
        self.assertFalse(agree['model_mismatch'])
        # the vendor said nothing: unknown, never guessed, and never a mismatch
        silent = m.record_model(run, 'claude', 'claude-opus-5-5', '', '2.1.0')
        self.assertEqual('unknown', silent['model'])
        self.assertFalse(silent['model_mismatch'])
        # no model configured at all: nothing to compare against, so no mismatch
        unset = m.record_model(run, 'claude', '', 'claude-sonnet-5', '2.1.0')
        self.assertFalse(unset['model_mismatch'])
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
    def test_actor_stays_within_32_when_a_retry_adds_its_attempt_mark(self):
        import hashlib
        task = 'T-LONGTASKID'
        slug = 'tlon' + hashlib.sha256(task.encode()).hexdigest()[:5]
        runs = self.root / 'state/runs'
        def at_the_boundary(taken):
            # r99999 is taken, so the retry lands on r99999b: room 6, then 5.
            os.environ['FM_ROUND'] = '99999'
            (runs / f'reviewer-{taken}-{slug}-r99999').mkdir(parents=True, exist_ok=True)
        # A name with no room is refused, never cut into a label that is not
        # the crew member's own.
        self.pin('rosters:\n  workers: [sophia]\n  reviewers: [sophie]\n')
        m.allocate(self.root, 'worker', 'T-701', '')  # sophia is live
        at_the_boundary('sophie')
        with self.assertRaisesRegex(RuntimeError, 'crew name sophie does not fit'):
            m.allocate(self.root, 'reviewer', task, '')
        # The alias path, straight at r100000 (room 5): a live alias is refused
        # although only its first five letters would fit, and an alias with
        # no room is refused, not cut.
        os.environ.pop('FM_ROUND')
        m.allocate(self.root, 'reviewer', 'T-702', 'Abcdef')  # abcdef is live, as a reviewer
        for alias, refusal in (('Abcdef', 'abcdef is live'), ('Uvwxyz', 'uvwxyz does not fit')):
            with self.subTest(alias=alias):
                os.environ['FM_ROUND'] = '100000'
                with self.assertRaisesRegex(RuntimeError, refusal):
                    m.allocate(self.root, 'reviewer', task, alias)
        names = {json.loads(p.read_text())['name'] for p in runs.glob('*/identity.json')}
        self.assertEqual({'sophia', 'abcdef'}, names)
        self.assertEqual([], [p.name for p in runs.glob('*') if len(p.name) > 32])
    # --- T-116: the identity is separate fields, and the actor's r<n> is the round
    def review_opened(self, task, times, project=None):
        log = self.root / 'state/events.jsonl'; log.parent.mkdir(parents=True, exist_ok=True)
        with log.open('a') as out:
            for _ in range(times):
                event = dict(type='review_opened', task=task, actor='reviewer-x-t0-r1')
                if project: event['project'] = project
                out.write(json.dumps(event) + '\n')
    def identity(self, run):
        return json.loads((run / 'identity.json').read_text())
    def test_identity_json_carries_name_role_project_task_round_and_attempt(self):
        self.pin('default_project: alpha\n')
        # a counter far along, so a counter-numbered actor could not end in r1
        (self.root / 'state/runs').mkdir(parents=True, exist_ok=True)
        m.save(self.root / 'state/runs/counter.json', dict(number=472))
        run = m.allocate(self.root, 'worker', 'T-900', '')
        record = self.identity(run)
        for key in ('name', 'role', 'project', 'task', 'round', 'attempt'): self.assertIn(key, record)
        self.assertEqual(('worker', 'alpha', 'T-900', 1, 1),
                         (record['role'], record['project'], record['task'], record['round'], record['attempt']))
        self.assertEqual(run.name, 'worker-' + record['name'] + '-t900-r1')
        # the project a run is for: FM_PROJECT over the default
        with patch.dict(os.environ, {'FM_PROJECT': 'beta'}):
            self.assertEqual('beta', self.identity(m.allocate(self.root, 'reviewer', 'T-901', ''))['project'])
        # and none named anywhere is the one default, recorded as such
        self.pin('')
        self.assertIsNone(self.identity(m.allocate(self.root, 'worker', 'T-902', ''))['project'])
    def test_the_actors_round_is_the_tasks_review_round_not_a_global_counter(self):
        # the global counter is far along; it must not reach the actor
        (self.root / 'state/runs').mkdir(parents=True)
        m.save(self.root / 'state/runs/counter.json', dict(number=472))
        first = m.allocate(self.root, 'worker', 'T-910', '')
        self.assertTrue(first.name.endswith('-t910-r1'), first.name)
        self.finish(first)
        # two review rounds opened: the worker answering them is on round 3,
        # and so is the reviewer that follows before its review_opened
        self.review_opened('T-910', 2)
        # another project's rounds and another task's are not this task's
        self.review_opened('T-910', 5, project='elsewhere')
        self.review_opened('T-911', 4)
        worker = m.allocate(self.root, 'worker', 'T-910', '')
        self.assertEqual(3, self.identity(worker)['round'])
        self.assertTrue(worker.name.endswith('-t910-r3'), worker.name)
        reviewer = m.allocate(self.root, 'reviewer', 'T-910', '')
        self.assertTrue(reviewer.name.endswith('-t910-r3'), reviewer.name)
        # a caller that knows the round (fm-review.sh --round) says it
        with patch.dict(os.environ, {'FM_ROUND': '12'}):
            told = m.allocate(self.root, 'reviewer', 'T-912', '')
        self.assertEqual((12, 1), (self.identity(told)['round'], self.identity(told)['attempt']))
        self.assertTrue(told.name.endswith('-t912-r12'), told.name)
        self.assertNotIn('472', ''.join(p.name for p in (first, worker, reviewer, told)))
    def test_a_retry_of_the_same_round_gets_its_own_attempt_mark_within_32(self):
        with patch.dict(os.environ, {'FM_ROUND': '12'}):
            runs = []
            for _ in range(3):
                runs.append(m.allocate(self.root, 'reviewer', 'T-LONGTASKID', ''))
                self.finish(runs[-1])
        self.assertEqual([1, 2, 3], [self.identity(p)['attempt'] for p in runs])
        self.assertEqual([12, 12, 12], [self.identity(p)['round'] for p in runs])
        self.assertEqual(['r12', 'r12b', 'r12c'], [p.name.rsplit('-', 1)[1] for p in runs])
        self.assertEqual(3, len({p.name for p in runs}))
        for p in runs: self.assertLessEqual(len(p.name), 32)
        # the other role's run of that round is its own first attempt
        with patch.dict(os.environ, {'FM_ROUND': '12'}):
            self.assertEqual(1, self.identity(m.allocate(self.root, 'worker', 'T-LONGTASKID', ''))['attempt'])
        self.assertEqual('', m.attempt_mark(1))
        self.assertEqual(['b', 'z', 'aa', 'ab'], [m.attempt_mark(n) for n in (2, 26, 27, 28)])
    def test_every_actor_reader_takes_both_the_old_and_the_new_form(self):
        for actor, name in (('worker-shira-sk001-r465', 'shira'), ('worker-shira-sk001-r12', 'shira'),
                            ('reviewer-mira-t116-r12b', 'mira'), ('worker-ada-lee-t035-r3c', 'ada-lee')):
            with self.subTest(actor=actor):
                self.assertEqual(name, m.crew_name(dict(actor=actor)))
    def test_a_run_from_before_the_roster_holds_the_name_in_its_actor(self):
        # identity.json from before T-089: no `name`, only the actor.
        self.pin('rosters:\n  workers: [mira, noah]\n')
        legacy = self.root / 'state/runs/worker-mira-t035-r5'; legacy.mkdir(parents=True)
        m.save(legacy / 'identity.json', dict(actor=legacy.name, role='worker', task='T-035',
                                              requested_alias='', run=str(legacy), created=1.0))
        self.assertEqual('mira', m.crew_name(json.loads((legacy / 'identity.json').read_text())))
        fresh = m.allocate(self.root, 'worker', 'T-800', '')
        self.assertEqual('noah', self.name(fresh))
        with self.assertRaisesRegex(RuntimeError, 'mira is live'):
            m.allocate(self.root, 'worker', 'T-801', 'mira')
    def test_live_alias_is_refused(self):
        first = m.allocate(self.root, 'worker', 'T-600', 'Zed')
        self.assertEqual('zed', self.name(first))
        # Live and a worker's name: the reviewer is told the refusal that
        # never lifts, not the one that lifts when the worker finishes.
        with self.assertRaisesRegex(RuntimeError, 'crew name zed has served as a worker'):
            m.allocate(self.root, 'reviewer', 'T-601', 'zed')
        with self.assertRaisesRegex(RuntimeError, 'zed is live'):
            m.allocate(self.root, 'worker', 'T-600', 'worker-Zed')
        self.finish(first)
        # Free again, but still a worker's name.
        self.assertEqual('zed', self.name(m.allocate(self.root, 'worker', 'T-602', 'zed')))
    def test_a_finished_workers_alias_is_refused_as_another_tasks_reviewer(self):
        # zed is on neither roster; its first run makes it a worker for good.
        worker = m.allocate(self.root, 'worker', 'T-610', 'zed')
        self.finish(worker)
        with self.assertRaisesRegex(RuntimeError, 'crew name zed has served as a worker and a name belongs to one role'):
            m.allocate(self.root, 'reviewer', 'T-611', 'Zed')
        reviewer = m.allocate(self.root, 'reviewer', 'T-612', 'quinn')
        self.finish(reviewer)
        with self.assertRaisesRegex(RuntimeError, 'crew name quinn has served as a reviewer'):
            m.allocate(self.root, 'worker', 'T-613', 'quinn')
        self.assertEqual(2, len(self.runs()))
    def test_a_redraw_never_gives_a_name_to_the_other_role(self):
        # Every name has served: the first 24 of the pool as workers, the rest
        # as reviewers. Any redraw that ignored them would cross a name.
        runs = self.root / 'state/runs'
        for i, name in enumerate(m.POOL):
            role = 'worker' if i < 24 else 'reviewer'
            run = runs / f'{role}-{name}-t9-r{i}'; run.mkdir(parents=True)
            m.save(run / 'identity.json', dict(actor=run.name, role=role, task='T-9', name=name,
                                               one_role=True, requested_alias='', run=str(run), created=1.0))
            self.finish(run)
        for seed in ('a', 'b', 'c'):
            with patch.dict(os.environ, {'FM_ROSTER_SEED': seed}):
                crew, _ = m.draw_rosters(self.root, redraw=True)
            self.assertEqual(set(m.POOL[:24]), set(crew['workers']))
            self.assertLessEqual(set(crew['reviewers']), set(m.POOL[24:]))
    def test_a_name_moved_to_the_other_role_in_config_is_not_used(self):
        self.pin('rosters:\n  workers: [bo, cy]\n  reviewers: [ada]\n')
        self.finish(m.allocate(self.root, 'worker', 'T-620', ''))  # bo served as a worker
        self.pin('rosters:\n  workers: [cy]\n  reviewers: [bo]\n')
        with self.assertRaisesRegex(RuntimeError, r'the reviewer roster ran out: none of its 1 names is free'
                                                  r' \(0 live, bo already served the other role\)'):
            m.allocate(self.root, 'reviewer', 'T-621', '')
        with self.assertRaisesRegex(RuntimeError, 'crew name bo has served as a worker'):
            m.allocate(self.root, 'reviewer', 'T-621', 'bo')
    def history(self, role, name, task, created, one_role=False):
        run = self.root / 'state/runs' / f'{role}-{name}-{task.lower().replace("-", "")}-r{created}'
        run.mkdir(parents=True)
        record = dict(actor=run.name, role=role, task=task, name=name, requested_alias='',
                      run=str(run), created=float(created))
        if one_role: record['one_role'] = True
        m.save(run / 'identity.json', record)
        self.finish(run)
    def test_history_from_before_the_one_role_rule_bars_no_name(self):
        # T-089 let one name serve both roles. Those runs were not written
        # under T-104's rule, so they bind no name to a role.
        for role, name, task, created in (('worker', 'ada', 'T-1', 1), ('reviewer', 'bo', 'T-1', 2),
                                          ('worker', 'bo', 'T-2', 3), ('reviewer', 'ada', 'T-2', 4)):
            self.history(role, name, task, created)
        self.pin('roster: [ada, bo]\n')
        first, said = self.quiet(m.allocate, self.root, 'worker', 'T-3', '')
        self.assertEqual('ada', self.name(first))
        self.assertEqual(1, len(said.splitlines()), said)
        self.assertEqual('bo', self.name(self.quiet(m.allocate, self.root, 'worker', 'T-4', '')[0]))
        # ada's first run under the rule was as a worker (T-3): that is its role now.
        self.finish(first)
        self.pin('rosters:\n  workers: [dee]\n  reviewers: [eli]\n')
        with self.assertRaisesRegex(RuntimeError, 'crew name ada has served as a worker'):
            m.allocate(self.root, 'reviewer', 'T-7', 'ada')
        self.assertEqual('ada', self.name(m.allocate(self.root, 'worker', 'T-7', 'ada')))
    def test_a_pinned_name_with_both_old_roles_serves_its_pinned_role(self):
        self.history('worker', 'bo', 'T-1', 1)
        self.history('reviewer', 'bo', 'T-2', 2)
        self.pin('rosters:\n  workers: [ada]\n  reviewers: [bo]\n')
        self.assertEqual('bo', self.name(m.allocate(self.root, 'reviewer', 'T-3', '')))
        # A --name with both old roles serves too, and is then bound.
        self.history('reviewer', 'cy', 'T-4', 3)
        self.history('worker', 'cy', 'T-5', 4)
        self.assertEqual('cy', self.name(m.allocate(self.root, 'worker', 'T-6', 'cy')))
    def test_a_name_keeps_the_role_of_its_first_record(self):
        # Two records under the rule that disagree (a hand-edited state/):
        # the earlier one decides, and the name still works in that role.
        self.history('reviewer', 'cy', 'T-11', 2, one_role=True)
        self.history('worker', 'cy', 'T-10', 1, one_role=True)
        self.assertEqual({'cy': 'worker'}, m.served_roles(self.root))
        worker = m.allocate(self.root, 'worker', 'T-12', 'cy')
        self.assertEqual('cy', self.name(worker))
        # Finished, so only the role can refuse it, and it does.
        self.finish(worker)
        with self.assertRaisesRegex(RuntimeError, 'crew name cy has served as a worker'):
            m.allocate(self.root, 'reviewer', 'T-13', 'cy')
        self.assertEqual('cy', self.name(m.allocate(self.root, 'worker', 'T-14', 'cy')))
    def test_every_run_is_recorded_under_the_one_role_rule(self):
        run = m.allocate(self.root, 'worker', 'T-14', '')
        self.assertIs(True, json.loads((run / 'identity.json').read_text())['one_role'])
    def test_pinned_names_are_validated(self):
        self.pin('rosters:\n  workers: [Ada, bo]\n')
        self.assertEqual({'workers': ['ada', 'bo']}, m.pinned_rosters(self.root))
        self.pin('rosters:\n  workers:\n  - ada\n  reviewers: [bo]\n')
        self.assertEqual({'workers': ['ada'], 'reviewers': ['bo']}, m.pinned_rosters(self.root))
        self.pin('roster: [Ada, bo]\n')
        self.assertEqual({'workers': ['ada', 'bo']}, self.quiet(m.pinned_rosters, self.root)[0])
        for text, refusal in (
                ('roster:\n  - ada\n  - ADA\n', 'config.yaml roster names ada more than once'),
                ('roster:\n  - mary-jane\n', "config.yaml roster: 'mary-jane' is not a short given name"),
                ('rosters:\n  reviewers:\n    - mary-jane\n', "config.yaml rosters.reviewers: 'mary-jane'"),
                ('rosters:\n  workers: [ada, Ada]\n', 'config.yaml rosters.workers names ada more than once'),
                ('rosters:\n  workers: []\n', 'config.yaml rosters.workers is empty'),
                ('rosters:\nvendor: claude\n', 'rosters must hold a workers: or reviewers: list'),
                # Every key under rosters: is checked, not only looked up.
                ('rosters:\n  workers: [ada]\n  reviewer: [bo]\n', 'config.yaml rosters: reviewer is not workers: or reviewers:'),
                ('rosters:\n  - ada\n', 'config.yaml rosters: - ada is not workers: or reviewers:'),
                ('rosters: {workers: [ada]}\n', 'config.yaml rosters must be a block holding workers: and/or'
                                                ' reviewers: lists, not an inline value'),
                ('roster: [a]\nrosters:\n  workers: [b]\n', 'both roster: and rosters:'),
                # An empty roster is refused like any other invalid one, not defaulted.
                ('roster:\nvendor: claude\n', 'config.yaml roster is empty'),
                ('roster: []\n', 'config.yaml roster is empty'),
                ('roster:\n', 'config.yaml roster is empty')):
            with self.subTest(text=text):
                self.pin(text)
                with self.assertRaisesRegex(ValueError, refusal):
                    self.quiet(m.pinned_rosters, self.root)
        self.pin('vendor: claude\n# rosters:\n#   workers: [ada]\n')
        self.assertEqual({}, m.pinned_rosters(self.root))

class Entrypoints(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        shutil.copytree(root / 'bin', self.repo / 'bin')
        shutil.copytree(root / 'skills', self.repo / 'skills')
        (self.repo / 'design/tasks').mkdir(parents=True)
        (self.repo / 'design/tasks/T-035.json').write_text(json.dumps(dict(id='T-035',title='test',scope=['src/**'],depends_on=[],acceptance=['works'])))
        (self.repo / 'design/design.md').write_text('## 6. Gates\nEvidence\n## 8. Board\n')
        (self.repo / 'config.yaml').write_text('vendor: codex\nconcurrency: 2\n')
        self.fake = self.repo / 'fakebin'; self.fake.mkdir()
        # no ambient terminal host: a developer's own tmux or cmux is not the fixture's
        self.env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_', 'TMUX', 'CMUX_'))}
        # The fake git below answers `config` with nothing, so the identity a
        # commit needs is the fixture's own: a worker whose commit fails stops.
        self.env.update(PATH=str(self.fake)+os.pathsep+os.environ['PATH'], HERDR_ENV='1', HERDR_PANE_ID='caller',
                        FM_ROOT=str(self.repo), FM_TEST_ROOT=str(self.repo), FM_HERDR_TIMEOUT=str(WAIT),
                        FM_GIT_NAME='t', FM_GIT_EMAIL='a@b.c')
        # Every vendor round runs behind bin/fm-sandbox.sh (T-105), and a host
        # with no OS sandbox refuses every vendor. A runner cannot be relied on
        # to have one, so the sandbox binary is a stand-in, as in
        # tests/adapter-contract.test.sh: it records what it was handed and
        # runs the command. It lives outside fakebin, so nothing on PATH is it.
        tool=self.repo/'sandbox-tool'; tool.mkdir()
        (tool/'bwrap').write_text('#!/usr/bin/env bash\n'
                                  'printf "%s\\n" "$@" >> "$FM_TEST_ROOT/sandboxed"\n'
                                  'while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done\n'
                                  'shift\nexec "$@"\n')
        (tool/'bwrap').chmod(0o755)
        self.env.update(FM_SANDBOX_OS='linux', FM_SANDBOX_TOOL=str(tool/'bwrap'))
        # Every vendor's round is handed the operator's login (T-117) and
        # refused without one. These say one is already in the environment,
        # so the runner's own keychain and home are never read.
        self.env.update(CLAUDE_CODE_OAUTH_TOKEN='fm-suite-token', CURSOR_API_KEY='fm-suite-key',
                        CODEX_API_KEY='fm-suite-key', GEMINI_API_KEY='fm-suite-key')
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
# A Herdr command that fails exits non-zero, as the real one does: the pane
# run, or only the report that the pane is working, so the idle one still lands.
fail=os.environ.get('FM_TEST_HERDR_FAIL')
if (fail=='pane-run' and a[:2]==['pane','run']) or (
        fail=='report-working' and a[:2]==['pane','report-agent'] and a[a.index('--state')+1]=='working'):
 print('error: '+' '.join(a[:2])+' failed',file=sys.stderr); raise SystemExit(1)
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
 # what runs in the pane is the follower `pane run` was given, and the pane is
 # idle again the moment it ends; one file per pane, as runs share a fixture
 runner=r/('follower-'+a[3]+'.pid')
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
 # Real `pane run` types the command into the pane's shell and returns at
 # once; the round is not in that pane, so nothing here may wait for it.
 # The pane's output is what the follower prints, kept where a test can read it.
 import shlex
 shown=open(r/('shown-'+a[2]),'ab')
 child=subprocess.Popen(shlex.split(a[3]),stdin=subprocess.DEVNULL,stdout=shown,stderr=subprocess.STDOUT,start_new_session=True)
 (r/('follower-'+a[2]+'.pid')).write_text(str(child.pid))
 (r/'mock-runner.pid').write_text(str(child.pid))
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
if a[0]=='show':
 p=r/a[-1].split(':',1)[-1]
 if not p.is_file(): sys.exit(128)
 print(p.read_text())
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
        with patch.dict(os.environ, {'FM_TRANSPORT':'direct'}):
            return not any(r['live'] for r in m.inspect(self.repo)['runs'])
    def test_retained_worker_survives_timeout_interrupt_and_launcher_death(self):
        for ending in ('timeout', 'term', 'kill', 'runner-kill', 'direct-runner-kill'):
            with self.subTest(ending=ending):
                for name in ('release-model','model.pid','mock-runner.pid'):
                    (self.repo/name).unlink(missing_ok=True)
                env=dict(self.env,FM_TEST_ASYNC='1',FM_HERDR_TIMEOUT='.3' if ending=='timeout' else str(WAIT))
                if ending=='direct-runner-kill':
                    env['FM_TRANSPORT']='direct'
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
                        if ending in ('runner-kill','direct-runner-kill'):
                            # the runner is gone but its adapter runs on: the
                            # round is still live, so a window keeps following
                            # it and the one stop path still stops it
                            cli=json.loads(execution.read_text())
                            follower=subprocess.Popen([sys.executable,str(self.repo/'bin/fm-herdr.py'),'follow',str(execution.parent)],
                                                      env=self.env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                            try:
                                time.sleep(1)
                                self.assertIsNone(follower.poll(),'follow ended while the adapter still ran')
                                if ending=='runner-kill':
                                    argv=['bash',str(self.repo/'bin/fm.sh'),'stop',actor,'--repo',str(self.repo)]
                                else:
                                    argv=['bash',str(self.repo/'bin/fm.sh'),'stop','--task','T-035','--repo',str(self.repo)]
                                stopped=subprocess.run(argv,env=self.env,capture_output=True,text=True,timeout=WAIT)
                                self.assertEqual(0,stopped.returncode,stopped.stderr)
                                said=json.loads(stopped.stdout)
                                self.assertIn(f'{actor} {runner} (runner gone)',said['stopped'])
                                self.assertEqual([],said['failed'])
                                self.wait_for(lambda:not m.process_matches(dict(pid=cli['pid'],token=cli['token'])))
                                self.wait_for(lambda:not m.process_matches(dict(pid=model,token=str(self.fake/'codex'))))
                                self.assertEqual(0,follower.wait(timeout=WAIT))
                            finally:
                                if follower.poll() is None: follower.kill(); follower.wait(timeout=5)
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
                    env=dict(self.env,FM_TRANSPORT='direct',FM_ROOT=self.repo.name)
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
        # zed is in no roster; while it is live, no run of either role takes it.
        # A worker is told it is live; a reviewer that it is a worker's name,
        # the refusal that outlasts the live run.
        live=m.allocate(self.repo,'worker','T-900','Zed')  # starting: no launcher record yet
        for script,args,refusal in (('fm-worker.sh',['--task','T-035','--name','zed'],
                                     'crew name zed is live in another run'),
                                    ('fm-review.sh',['--task','T-035','--branch','work','--name','Zed'],
                                     'crew name zed has served as a worker')):
            with self.subTest(script=script):
                answer=self.invoke(script,args)
                self.assertEqual(70,answer.returncode,answer.stderr)
                self.assertIn(refusal,answer.stderr)
                self.assertNotIn('Traceback',answer.stderr)
        self.assertEqual([live.name],[p.name for p in (self.repo/'state/runs').glob('*-zed-*')])
    def test_entrypoints_draw_the_crew_and_take_each_role_from_its_own_roster(self):
        self.assertFalse((self.repo/'state/crew/rosters.json').exists())
        for script,args in (('fm-worker.sh',['--task','T-035']),('fm-review.sh',['--task','T-035','--branch','work'])):
            answer=self.invoke(script,args,FM_ROSTER_SEED='entry')
            self.assertEqual(0,answer.returncode,answer.stderr)
        crew=json.loads((self.repo/'state/crew/rosters.json').read_text())
        names={json.loads(p.read_text())['role']:json.loads(p.read_text())['name']
               for p in (self.repo/'state/runs').glob('*/identity.json')}
        self.assertIn(names['worker'],crew['workers'])
        self.assertIn(names['reviewer'],crew['reviewers'])
    def test_entrypoints_fail_an_exhausted_roster_without_borrowing(self):
        (self.repo/'config.yaml').write_text('vendor: codex\nconcurrency: 2\nrosters:\n  workers: [bo]\n  reviewers: [ada]\n')
        m.allocate(self.repo,'reviewer','T-900','')  # ada is live
        answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'])
        self.assertEqual(70,answer.returncode,answer.stderr)
        self.assertIn('the reviewer roster ran out',answer.stderr)
        self.assertIn('a name of the other role is never borrowed',answer.stderr)
        self.assertNotIn('Traceback',answer.stderr)
        self.assertEqual([],self.results())
        self.assertEqual([],list((self.repo/'state/runs').glob('*-bo-*')))
    def test_entrypoints_refuse_a_bad_roster_in_one_line(self):
        for roster,said in (('roster:\n  - mary-jane\n',"config.yaml roster: 'mary-jane' is not a short given name"),
                            ('roster: []\n','config.yaml roster is empty'),
                            ('rosters:\n  workers: [ada]\n  reviewers: [ada]\n','config.yaml rosters: ada is in both')):
            with self.subTest(roster=roster):
                (self.repo/'config.yaml').write_text('vendor: codex\n'+roster)
                answer=self.invoke('fm-worker.sh',['--task','T-035'])
                self.assertEqual(70,answer.returncode,answer.stderr)
                self.assertIn(said,answer.stderr)
                self.assertNotIn('Traceback',answer.stderr)
        self.assertEqual([],list((self.repo/'state/runs').glob('*/identity.json')))
    def test_real_reviewer_entrypoint_identity_and_final_provenance(self):
        answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work','--name','Quinn'],
                           FM_TEST_VERDICT='REJECT')
        self.assertEqual(0,answer.returncode,answer.stderr)
        result=json.loads(self.results()[0].read_text()); actor=result['actor']
        self.assertRegex(actor,r'^reviewer-quinn-t035-r[0-9]+[a-z]*$')
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
    def test_changed_focus_opens_no_window_and_the_round_still_runs(self):
        # A tab that moved the caller's focus is not one fm will run anything
        # in or close. It was only ever a window: the round runs without it.
        answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'],FM_TEST_FOCUS='changed')
        self.assertEqual(0,answer.returncode,answer.stderr)
        calls=[json.loads(s) for s in (self.repo/'controls').read_text().splitlines()]
        self.assertFalse(any(c[:2] in (['pane','run'],['pane','close'],['tab','close']) for c in calls))
        self.assertEqual('completed',json.loads(self.results()[0].read_text())['status'])
        window=json.loads(next((self.repo/'state/runs').glob('*/*/window.json')).read_text())
        self.assertEqual('none',window['status'])
        self.assertIn('focus changed',window['reason'])
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
        # Without Herdr a round runs headless, and so does one that asks for
        # no window inside Herdr: neither is refused, and neither touches it.
        answer=self.invoke('fm-worker.sh',['--task','T-035'],HERDR_ENV='0')
        self.assertEqual(0,answer.returncode,answer.stderr)
        direct=self.invoke('fm-worker.sh',['--task','T-035'],FM_TRANSPORT='direct')
        self.assertEqual(0,direct.returncode,direct.stderr)
        self.assertNotIn('refused',direct.stderr)
        self.assertFalse((self.repo/'controls').exists())
        self.assertEqual(2,len(self.results()))
        self.assertEqual(2,len({json.loads(p.read_text())['actor'] for p in self.results()}))
    def test_a_round_with_no_terminal_host_at_all_is_headless_and_supervised(self):
        answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'],HERDR_ENV='0')
        self.assertEqual(0,answer.returncode,answer.stderr)
        self.assertFalse((self.repo/'controls').exists())
        result=json.loads(self.results()[0].read_text()); attempt=Path(result['attempt'])
        self.assertEqual('completed',result['status'])
        # the supervision receipts: pid and exit files, and the stream in the run's log
        self.assertRegex((attempt/'runner.pid').read_text(),r'^[0-9]+$')
        self.assertEqual('0',(attempt/'runner.exit').read_text().strip())
        self.assertIn('finished exit=0',(attempt/'run.log').read_text())
        # no window is recorded as none, never inferred from a missing file
        window=json.loads((attempt/'window.json').read_text())
        self.assertEqual(('none','none'),(window['host'],window['status']))
        events=[json.loads(s) for s in (self.repo/'state/events.jsonl').read_text().splitlines()]
        self.assertTrue([e for e in events if e['type']=='agent_finished' and e['actor']==result['actor']])
    def test_the_board_sees_a_headless_round_as_it_sees_a_pane_round(self):
        # the events a round leaves are the same whatever hosted it
        shapes=[]
        for env in (dict(HERDR_ENV='0'),dict()):
            answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'],**env)
            self.assertEqual(0,answer.returncode,answer.stderr)
            actor=json.loads(max(self.results(),key=lambda p:p.stat().st_mtime_ns).read_text())['actor']
            log=[json.loads(s) for s in (self.repo/'state/events.jsonl').read_text().splitlines()]
            mine=[e for e in log if e['actor']==actor]
            self.assertTrue(mine)
            shapes.append([(e['type'],(e.get('data') or {}).get('role')) for e in mine])
        self.assertEqual(shapes[0],shapes[1])
    def test_a_closed_pane_never_kills_the_round_and_the_pane_follows_the_stream(self):
        for name in ('release-model','model.pid','mock-runner.pid','closed'):
            (self.repo/name).unlink(missing_ok=True)
        env=dict(self.env,FM_TEST_ASYNC='1',FM_HERDR_TIMEOUT=str(WAIT),FM_TEST_DELAY='0')
        with tempfile.TemporaryFile(mode='w+') as output:
            launcher=subprocess.Popen(['bash',str(self.repo/'bin/fm-worker.sh'),'--task','T-035'],
                env=env,stdout=output,stderr=output,start_new_session=True)
            try:
                self.wait_for(lambda:(self.repo/'model.pid').exists())
                model=int((self.repo/'model.pid').read_text())
                actor=(self.repo/'state/worktrees/T-035/surviving-work').read_text()
                calls=[json.loads(s) for s in (self.repo/'controls').read_text().splitlines()]
                # its own labelled tab, opened as the round started
                create=next(c for c in calls if c[:2]==['tab','create'])
                self.assertEqual(actor,create[create.index('--label')+1])
                run=next(c for c in calls if c[:2]==['pane','run'])
                self.assertIn(' follow ',run[3])
                pane=run[2]
                # the pane shows the round's live stream, followed from the run's log
                shown=self.repo/('shown-'+pane)
                self.wait_for(lambda:shown.exists() and 'started on T-035' in shown.read_text())
                attempt=next((self.repo/'state/runs'/actor).glob('*/runner.pid')).parent
                self.assertIn('started on T-035',(attempt/'run.log').read_text())
                runner=int((attempt/'runner.pid').read_text())
                self.assertEqual(runner,os.getpgid(runner),'the round is a process group of its own')
                # the user closes the pane: its foreground process dies with it
                follower=int((self.repo/('follower-'+pane+'.pid')).read_text())
                os.kill(follower,signal.SIGKILL)
                self.wait_for(lambda:not m.process_matches(dict(pid=follower,token='follow')))
                time.sleep(.5)
                os.kill(runner,0); os.kill(model,0)  # both still there
                self.assertIsNone(launcher.poll())
                (self.repo/'release-model').touch()
                rc=launcher.wait(timeout=WAIT)
                self.assertIn(rc,(0,73),rc)
                self.assertEqual('completed',json.loads(self.results()[0].read_text())['status'])
                self.assertEqual('0',(attempt/'runner.exit').read_text().strip())
            finally:
                (self.repo/'release-model').touch()
                if launcher.poll() is None:
                    os.killpg(launcher.pid,signal.SIGKILL); launcher.wait(timeout=5)
    def test_a_round_that_ends_closes_its_pane_and_a_pane_that_fails_costs_nothing(self):
        answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'])
        self.assertEqual(0,answer.returncode,answer.stderr)
        self.assertTrue((self.repo/'closed').exists())
        (self.repo/'closed').unlink()
        # a Herdr that cannot open a tab: the round still runs, with no window
        (self.repo/'fakebin/herdr').write_text('#!/bin/sh\necho "herdr: no server" >&2\nexit 1\n')
        answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'])
        self.assertEqual(0,answer.returncode,answer.stderr)
        self.assertFalse((self.repo/'closed').exists())
        self.assertEqual(2,len(self.results()))
        self.assertEqual({'completed'},{json.loads(p.read_text())['status'] for p in self.results()})
    def test_stop_ends_the_process_group_and_the_lost_round_says_so(self):
        # one stop path, reached by an actor (fm-herdr.py stop), by a task
        # (fm.sh stop --task, which the board's park and drop also run)
        for way in ('actor','task'):
            with self.subTest(way=way):
                for name in ('release-model','model.pid'):
                    (self.repo/name).unlink(missing_ok=True)
                env=dict(self.env,FM_TEST_ASYNC='1',FM_HERDR_TIMEOUT=str(WAIT),HERDR_ENV='0')
                with tempfile.TemporaryFile(mode='w+') as output:
                    launcher=subprocess.Popen(['bash',str(self.repo/'bin/fm-worker.sh'),'--task','T-035'],
                        env=env,stdout=output,stderr=output,start_new_session=True)
                    try:
                        self.wait_for(lambda:(self.repo/'model.pid').exists())
                        model=int((self.repo/'model.pid').read_text())
                        actor=(self.repo/'state/worktrees/T-035/surviving-work').read_text()
                        runner=int(next((self.repo/'state/runs'/actor).glob('*/runner.pid')).read_text())
                        if way=='actor':
                            argv=[sys.executable,str(self.repo/'bin/fm-herdr.py'),'stop',str(self.repo),actor]
                        else:
                            argv=['bash',str(self.repo/'bin/fm.sh'),'stop','--task','T-035','--repo',str(self.repo)]
                        stopped=subprocess.run(argv,env=self.env,capture_output=True,text=True,timeout=WAIT)
                        self.assertEqual(0,stopped.returncode,stopped.stderr)
                        said=json.loads(stopped.stdout)
                        self.assertIn(f'{actor} {runner}',said['stopped'])
                        self.assertEqual([],said['failed'])
                        self.wait_for(lambda:not m.process_matches(dict(pid=model,token=str(self.fake/'codex'))))
                        launcher.wait(timeout=WAIT)
                        # stopped by task, the worker script is TERMed too, and
                        # may end before the supervisor has recorded the loss
                        path=self.repo/'state/runs'/actor/'last-result.json'
                        last=self.wait_for(lambda:path.is_file() and json.loads(path.read_text()))
                        self.assertEqual('lost',last['status'])
                        self.assertNotEqual(0,last['exit_code'])
                    finally:
                        (self.repo/'release-model').touch()
                        if launcher.poll() is None:
                            os.killpg(launcher.pid,signal.SIGKILL); launcher.wait(timeout=5)
                        self.wait_for(self.no_live_runs)
    def test_fm_follow_shows_an_actors_latest_round(self):
        answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'],HERDR_ENV='0')
        self.assertEqual(0,answer.returncode,answer.stderr)
        actor=json.loads(self.results()[0].read_text())['actor']
        shown=subprocess.run(['bash',str(self.repo/'bin/fm.sh'),'follow',actor,'--repo',str(self.repo)],
                             env=self.env,capture_output=True,text=True,timeout=WAIT)
        self.assertEqual(0,shown.returncode,shown.stderr)
        self.assertIn('started on T-035',shown.stdout)
        self.assertIn('finished exit=0',shown.stdout)
        nobody=subprocess.run(['bash',str(self.repo/'bin/fm.sh'),'follow','worker-nobody-t1-r1','--repo',str(self.repo)],
                              env=self.env,capture_output=True,text=True,timeout=WAIT)
        self.assertNotEqual(0,nobody.returncode)
        self.assertIn('no round of worker-nobody-t1-r1',nobody.stderr)
    # The tmux and cmux stand-ins take exactly the flags the real tools take
    # and refuse any other, as the real tools do, so a call the real tool
    # would reject is rejected here too.
    TMUX_STUB = r'''
import json,os,pathlib,shlex,subprocess,sys
r=pathlib.Path(os.environ['FM_TEST_ROOT']); a=sys.argv[1:]
with (r/'tmux-calls').open('a') as f: f.write(json.dumps(a)+'\n')
# tmux(1): new-window [-abdkPS] [-c start-directory] [-e environment]
#   [-F format] [-n window-name] [-t target-window] [shell-command [argument ...]]
#   "-P prints information about the new window after it has been created. By
#   default, it uses the format '#{session_name}:#{window_index}' but a
#   different format may be specified with -F." #{window_id} is "@N".
#   "-d: the session does not make the new window the current window."
if a[:1]!=['new-window']: sys.exit('unknown command: '+(a[0] if a else ''))
flags,valued,i={},set('ceFnt'),1
while i<len(a) and a[i].startswith('-') and len(a[i])>1:
 for j,c in enumerate(a[i][1:]):
  if c in valued:
   v=a[i][j+2:] or a[i+1]; i+=0 if a[i][j+2:] else 1; flags[c]=v; break
  if c not in 'abdkPS': sys.exit('new-window: unknown option -- '+c)
  flags[c]=True
 i+=1
command=a[i:]
n=7+len((r/'tmux-calls').read_text().splitlines())
if command:
 subprocess.Popen(shlex.split(command[0]) if len(command)==1 else command,stdin=subprocess.DEVNULL,
  stdout=open(r/'tmux-shown','ab'),stderr=subprocess.STDOUT,start_new_session=True)
if flags.get('P'):
 print(flags.get('F','#{session_name}:#{window_index}').replace('#{window_id}','@%d'%n)
       .replace('#{session_name}','0').replace('#{window_index}',str(n)))
'''
    CMUX_STUB = r'''
import json,os,pathlib,shlex,subprocess,sys
r=pathlib.Path(os.environ['FM_TEST_ROOT']); a=sys.argv[1:]
with (r/'cmux-calls').open('a') as f: f.write(json.dumps(a)+'\n')
# cmux <command> --help, from the installed cmux (checked 2026-09-29):
#   new-workspace [--cwd <path>] [--command <text>]
#     --command <text>  Send text+Enter to the new workspace after creation
#   rename-workspace [--workspace <id|ref|index>] [--] <title>
#   close-workspace --workspace <id|ref|index>   (required)
#   "Output defaults to refs (window:1/workspace:2/pane:3/surface:4)"
def options(rest,known):
 got,pos,i={},[],0
 while i<len(rest):
  if rest[i]=='--': pos+=rest[i+1:]; break
  if rest[i].startswith('--'):
   if rest[i] not in known: sys.exit('Error: Unknown flag '+rest[i])
   got[rest[i]]=rest[i+1]; i+=2; continue
  pos.append(rest[i]); i+=1
 return got,pos
count=r/'cmux-workspaces'
if a[:1]==['new-workspace']:
 got,pos=options(a[1:],{'--cwd','--command'})
 if pos: sys.exit('Error: unexpected argument '+pos[0])
 n=int(count.read_text())+1 if count.exists() else 7; count.write_text(str(n))
 if '--command' in got:
  subprocess.Popen(shlex.split(got['--command']),stdin=subprocess.DEVNULL,stdout=open(r/'cmux-shown','ab'),
   stderr=subprocess.STDOUT,start_new_session=True)
 print('OK workspace:%d'%n)
elif a[:1]==['rename-workspace']:
 got,pos=options(a[1:],{'--workspace'})
 if len(pos)!=1: sys.exit('Error: rename-workspace requires a title')
 (r/('cmux-title-'+got.get('--workspace','current').replace(':','-'))).write_text(pos[0]); print('OK')
elif a[:1]==['close-workspace']:
 got,pos=options(a[1:],{'--workspace'})
 if '--workspace' not in got or pos: sys.exit('Error: close-workspace requires --workspace')
 print('OK')
else: sys.exit('Error: Unknown command '+(a[0] if a else ''))
'''
    def test_tmux_and_cmux_get_the_same_window_where_they_are_the_host(self):
        self.executable('tmux', self.TMUX_STUB)
        self.executable('cmux', self.CMUX_STUB)
        for host,marker in (('tmux',dict(TMUX='/tmp/tmux-0/default,1,0')),('cmux',dict(CMUX_WORKSPACE_ID='workspace:1'))):
            with self.subTest(host=host):
                answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'],HERDR_ENV='0',**marker)
                self.assertEqual(0,answer.returncode,answer.stderr)
                calls=[json.loads(s) for s in (self.repo/(host+'-calls')).read_text().splitlines()]
                result=json.loads(max(self.results(),key=lambda p:p.stat().st_mtime_ns).read_text())
                actor=result['actor']
                window=json.loads((Path(result['attempt'])/'window.json').read_text())
                self.wait_for(lambda:'started on T-035' in (self.repo/(host+'-shown')).read_text())
                if host=='tmux':
                    self.assertEqual(actor,calls[0][calls[0].index('-n')+1])
                    self.assertIn(' follow ',calls[0][-1])
                    self.assertEqual('@8',window['ref'])
                else:
                    # opened, then labelled by the ref cmux answered with, then closed by it
                    self.assertEqual(['new-workspace','--cwd'],calls[0][:2])
                    self.assertIn(' follow ',calls[0][calls[0].index('--command')+1])
                    self.assertEqual(['rename-workspace','--workspace','workspace:7',actor],calls[1])
                    self.assertEqual(actor,(self.repo/'cmux-title-workspace-7').read_text())
                    self.assertEqual(['close-workspace','--workspace','workspace:7'],calls[-1])
                    self.assertEqual('closed',window['status'])
                self.assertFalse((self.repo/'controls').exists())
    def test_a_cmux_workspace_that_cannot_be_labelled_is_still_closed(self):
        self.executable('cmux', self.CMUX_STUB.replace("elif a[:1]==['rename-workspace']:",
                                                       "elif a[:1]==['rename-workspace']:\n sys.exit('Error: denied')\nelif False:"))
        answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'],HERDR_ENV='0',CMUX_WORKSPACE_ID='workspace:1')
        self.assertEqual(0,answer.returncode,answer.stderr)
        calls=[json.loads(s) for s in (self.repo/'cmux-calls').read_text().splitlines()]
        self.assertEqual(['close-workspace','--workspace','workspace:7'],calls[-1])
        result=json.loads(self.results()[0].read_text())
        self.assertEqual('completed',result['status'])
        window=json.loads((Path(result['attempt'])/'window.json').read_text())
        self.assertIn('rename-workspace',window['reason'])
    def test_the_stand_ins_refuse_what_the_real_tools_refuse(self):
        # A fixture test: it guards "stand-ins answer as the real tools do" and is not fail-first evidence for T-144.
        # the round-1 call, cmux new-workspace --name, is one real cmux does not have
        self.executable('tmux', self.TMUX_STUB); self.executable('cmux', self.CMUX_STUB)
        env=dict(self.env)
        run=lambda *a:subprocess.run([str(self.fake/a[0]),*a[1:]],env=env,capture_output=True,text=True)
        self.assertNotEqual(0,run('cmux','new-workspace','--name','x','--command','true').returncode)
        self.assertNotEqual(0,run('cmux','close-workspace').returncode)
        self.assertNotEqual(0,run('tmux','new-window','-Z').returncode)
        self.assertEqual('OK workspace:7',run('cmux','new-workspace','--cwd','.').stdout.strip())
        self.assertRegex(run('tmux','new-window','-d','-P','-F','#{window_id}','-n','x').stdout.strip(),r'^@[0-9]+$')
    def test_host_choice_is_config_then_environment_and_never_carries_the_round(self):
        config=self.repo/'config.yaml'
        def host(text='',**env):
            config.write_text('vendor: codex\n'+text)
            with patch.dict(os.environ,dict({k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','TMUX','CMUX'))},**env),clear=True):
                return m.window_host(self.repo)
        self.assertEqual('none',host())
        self.assertEqual('herdr',host(HERDR_ENV='1'))
        self.assertEqual('tmux',host(TMUX='/tmp/x,1,0'))
        self.assertEqual('cmux',host(CMUX_WORKSPACE_ID='w'))
        self.assertEqual('none',host('host: none\n',HERDR_ENV='1'))
        self.assertEqual('tmux',host('host: tmux  # a window\n'))
        self.assertEqual('herdr',host('host: herdr\n'))
        self.assertEqual('none',host('host: screen\n',HERDR_ENV='1'))
        self.assertEqual('none',host('',HERDR_ENV='1',FM_TRANSPORT='direct'))
        self.assertEqual('none',host('host: herdr\n',FM_HOST='none'))
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
        # `--name same`. Pinned rosters keep them as close as they can be:
        # sam, samx, samxy, where one actor's name is a prefix of the others.
        (self.repo/'config.yaml').write_text('vendor: codex\nconcurrency: 2\n'
                                             'rosters:\n  workers: [sam]\n  reviewers: [samx, samxy]\n')
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
        self.assertEqual({'sam','samx','samxy'},{a.split('-')[1] for a in started})
    def test_a_herdr_that_fails_costs_the_worker_its_window_and_nothing_else(self):
        # Herdr only ever gave the round a window (T-144): a Herdr that fails
        # every command leaves the worker running headless to its end, and
        # the failure is said and recorded, not raised.
        self.executable('herdr','raise SystemExit(7)')
        answer=self.invoke('fm-worker.sh',['--task','T-035'])
        self.assertEqual(0,answer.returncode,answer.stderr)
        self.assertIn('no herdr window (Herdr command failed: pane get caller); the round runs without one',answer.stderr)
        result=json.loads(self.results()[0].read_text()); attempt=Path(result['attempt'])
        self.assertEqual('completed',result['status'])
        window=json.loads((attempt/'window.json').read_text())
        self.assertEqual(('herdr','none'),(window['host'],window['status']))
        self.assertIn('Herdr command failed',window['reason'])
        self.assertEqual('0',(attempt/'runner.exit').read_text().strip())
    def test_a_herdr_window_that_fails_late_gives_its_pane_back(self):
        # A window that fails after the round was handed its pane: the round
        # runs headless with the caller's Herdr context again, and the pane
        # fm disowned is reported idle, not left working for ever.
        for fail in ('pane-run','report-working'):
            with self.subTest(fail=fail):
                (self.repo/'controls').unlink(missing_ok=True)
                answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'],FM_TEST_HERDR_FAIL=fail)
                self.assertEqual(0,answer.returncode,answer.stderr)
                latest=max(self.results(),key=lambda p:p.stat().st_mtime_ns)
                result=json.loads(latest.read_text()); attempt=Path(result['attempt'])
                self.assertEqual('completed',result['status'])
                window=json.loads((attempt/'window.json').read_text())
                self.assertEqual(('herdr','none'),(window['host'],window['status']))
                self.assertTrue((attempt/'runner.exit').is_file())
                environment=json.loads((attempt/'environment.json').read_text())
                self.assertEqual('caller',environment['HERDR_PANE_ID'])
                self.assertNotIn('HERDR_TAB_ID',environment)
                self.assertNotIn('HERDR_WORKSPACE_ID',environment)
                pane=json.loads((attempt/'owner.failed.json').read_text())['pane_id']
                calls=[json.loads(s) for s in (self.repo/'controls').read_text().splitlines()]
                states=[c[c.index('--state')+1] for c in calls if c[:3]==['pane','report-agent',pane]]
                self.assertEqual(['working','idle'],states)
                self.assertFalse(any(c[:2] in (['pane','close'],['tab','close']) for c in calls))
    def test_new_role_resets_inherited_adapter_guard(self):
        answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'],
                           FM_CONTEXT_READY='1',FM_ATTEMPT_DIR='/unused-parent',FM_FINAL_PATH='/unused-parent/final')
        self.assertEqual(0,answer.returncode,answer.stderr)
        self.assertTrue((self.repo/'controls').exists())
        self.assertEqual(1,len(self.results()))
    def test_managed_rounds_run_inside_the_os_sandbox(self):
        # T-105: a worker and a reviewer each start their CLI inside the OS
        # sandbox, confined to their own tree with no network of their own
        for script,args in (('fm-worker.sh',['--task','T-035']),
                            ('fm-review.sh',['--task','T-035','--branch','work'])):
            with self.subTest(script=script):
                (self.repo/'sandboxed').unlink(missing_ok=True)
                answer=self.invoke(script,args)
                self.assertEqual(0,answer.returncode,answer.stderr)
                handed=(self.repo/'sandboxed').read_text().splitlines()
                self.assertIn('--unshare-net',handed)
                self.assertIn('--',handed)
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
    def test_fallback_never_reuses_changed_owned_resources_but_still_runs(self):
        self.executable('claude', "print('Authentication required.')\nraise SystemExit(2)\n")
        (self.repo/'config.yaml').write_text('vendor: claude\nfallback:\n  - codex\n')
        for change in ('added','moved','shared','reused','busy','identity','unknown','late-shell'):
            with self.subTest(change=change):
                answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'],FM_TEST_CHANGE=change)
                self.assertEqual(0,answer.returncode,answer.stderr)
        calls=[json.loads(s) for s in (self.repo/'controls').read_text().splitlines()]
        self.assertEqual(8,len([c for c in calls if c[:2]==['tab','create']]))
        # the fallback attempt found the pane no longer its own and ran with no window
        self.assertEqual(8,len([c for c in calls if c[:2]==['pane','run']]))
        self.assertEqual(8,len(list(self.repo.glob('reviewer-*.prompt'))), 'the fallback model still starts')
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
        # boundaries are fake. No external account is used; the only captain
        # decision is the fixture's A on T-035's readiness card, without which
        # the dispatcher holds the task (T-059).
        subprocess.run([str(self.repo/'bin/fm-emit.sh'),'--actor','captain','--type','greenlit'],
                       env=self.env,check=True,capture_output=True)
        subprocess.run(['bash',str(self.repo/'bin/fm-ready.sh'),'judged','--task','T-035',
                        '--decision','D-1000','--repo',str(self.repo)],
                       env=self.env,check=True,capture_output=True)
        (self.repo/'state/decisions').mkdir(parents=True,exist_ok=True)
        (self.repo/'state/decisions/D-1000.json').write_text('{"id":"D-1000","task":"T-035","kind":"choice","chosen":"A"}\n')
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

    def test_a_status_carries_the_runs_identity_fields(self):
        # T-116: the board reads name, project and round from the payload,
        # never out of the actor
        run = self.root/'state/runs/worker-shira-t116-r3b'; run.mkdir(parents=True)
        m.save(run/'identity.json', dict(actor=run.name, name='shira', role='worker', project='alpha',
                                         task='T-116', round=3, attempt=2, one_role=True))
        self.assertEqual(0, m.main(['emit-status','--root',str(self.root),'--actor',run.name,
                                    '--task','T-116','--role','worker','--en','x','--tw','y']))
        self.assertEqual(dict(name='shira', role='worker', project='alpha', task='T-116', round=3, attempt=2),
                         self.events()[-1]['data']['identity'])
        # a run from before T-116 has no such fields, and none are invented
        old = self.root/'state/runs/worker-mira-t035-r465'; old.mkdir(parents=True)
        m.save(old/'identity.json', dict(actor=old.name, name='mira', role='worker', task='T-035'))
        m.main(['emit-status','--root',str(self.root),'--actor',old.name,
                '--task','T-035','--role','worker','--en','x','--tw','y'])
        self.assertNotIn('identity', self.events()[-1]['data'])

    def test_bounded_progress_and_refusals(self):
        self.assertEqual(0, m.main(['emit-status','--root',str(self.root),'--actor','worker-h',
            '--task','T-H','--role','worker','--en','gates 3/7','--tw','關卡 3/7','--done','3','--total','7']))
        ev = self.events(); self.assertEqual({'done':3,'total':7}, ev[-1]['data']['progress'])
        with self.assertRaises(ValueError):
            m.main(['emit-status','--root',str(self.root),'--actor','worker-h',
                    '--task','T-H','--en','x','--tw','y','--done','1'])
        with self.assertRaises(ValueError):
            m.emit_status(self.root, 'worker-h', 'T-H', 'x', 'y', done=9, total=3)


class AgentLost(unittest.TestCase):
    """T-118: a run whose recorded process is gone and that never said
    agent_finished gets one agent_lost, from the launcher side's deck
    reconcile through fm-emit, never from the model; a live run gets none."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root/'bin').mkdir(); (self.root/'state/runs').mkdir(parents=True)
        shutil.copy(root/'bin/fm-emit.sh', self.root/'bin/fm-emit.sh')
        self.log = self.root/'state/events.jsonl'
        # a pid that existed and is gone: its own child, started and reaped
        gone = subprocess.Popen(['true']); gone.wait(); self.dead = gone.pid

    def say(self, actor, type_, task='T-118', data=None):
        line = dict(ts='2026-09-26T10:00:00Z', actor=actor, type=type_, task=task,
                    data=data or {'role': 'worker'}, summary={'en': type_, 'zh-TW': type_})
        with self.log.open('a') as f: f.write(json.dumps(line) + '\n')

    def events(self):
        return [json.loads(l) for l in self.log.read_text().splitlines() if l.strip()]

    def recorded(self, actor, pid, token):
        run = self.root/'state/runs'/actor; run.mkdir()
        m.save(run/'process.json', dict(actor=actor, role='worker', task='T-118', pid=pid, token=token))

    def test_a_vanished_pid_is_lost_once_and_a_live_one_is_kept(self):
        ghost, live, done = 'worker-ghost-t118-r1', 'worker-live-t118-r2', 'worker-done-t118-r1'
        for actor in (ghost, live, done): self.say(actor, 'dispatched')
        self.say(done, 'agent_finished')
        token = 'fm-live-' + live
        holder = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)', token],
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: (holder.kill(), holder.wait()))
        self.recorded(ghost, self.dead, 'fm-worker.sh')
        self.recorded(live, holder.pid, token)
        first = m.retire_dead_crew(self.root)
        self.assertEqual([ghost], first['lost'])
        self.assertEqual([live], first['kept'])
        after = self.events()
        lost = [e for e in after if e['type'] == 'agent_lost']
        self.assertEqual([ghost], [e['actor'] for e in lost], 'only the vanished run is lost, and once')
        self.assertEqual('T-118', lost[0]['task'])
        self.assertIn('lost', lost[0]['summary']['en'])
        self.assertIn('失聯', lost[0]['summary']['zh-TW'])
        # the close that has always followed a ghost still follows it
        self.assertEqual(['agent_lost', 'agent_finished'], [e['type'] for e in after if e['actor'] == ghost][1:])
        # read again, nothing more is written: the run is already off the deck
        second = m.retire_dead_crew(self.root)
        self.assertEqual([], second['lost'])
        self.assertEqual(after, self.events())

    def test_a_loss_already_written_is_not_written_again(self):
        ghost = 'worker-half-t118-r1'
        self.say(ghost, 'dispatched'); self.say(ghost, 'agent_lost')
        self.recorded(ghost, self.dead, 'fm-worker.sh')
        result = m.retire_dead_crew(self.root)
        self.assertEqual([], result['lost'])
        self.assertEqual([ghost], result['retired'])
        self.assertEqual(['dispatched', 'agent_lost', 'agent_finished'], [e['type'] for e in self.events()])


unittest.main(argv=['herdr', *os.environ.get('FM_TEST_CASES','').split()], verbosity=2)
PY
