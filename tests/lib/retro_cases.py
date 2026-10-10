"""Retrospective (T-273) cases: tests/retro.test.sh runs this file.

Every project name here is made up. Cases that need bin/lib/fm_retro.py are
skipped, and say so, on a tree that does not have it; the autopilot case
needs only bin/lib/fm_autopilot.py and fails there for a real reason.
"""
import os
os.environ['HERDR_ENV'] = '0'
import fcntl
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(ROOT / 'bin/lib'))
for name in [k for k in os.environ if k.startswith('FM_')]:
    del os.environ[name]
try:
    import fm_retro as R
except ImportError:
    R = None
needs_retro = unittest.skipUnless(R is not None, 'SKIP (not evidence): bin/lib/fm_retro.py is absent on this tree')
FIXTURES = ROOT / 'tests/fixtures/retro'
DAY = 86400
BASE = 1_790_000_000.0


def iso(ts):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(ts))


def item(n, effect='removes', title='Delete the old suite.', carried=None):
    loc = lambda lang: dict(title=title if lang == 'en' else '刪除舊的測試。',
                            why='Another suite covers the same checks.' if lang == 'en' else '另一組測試已涵蓋同樣的檢查。',
                            how='Remove the file.' if lang == 'en' else '移除檔案。',
                            evidence=['tests/a.sh:1'], scope=['tests/old.test.sh'],
                            **({'why_not_removal': 'No file holds this check today.' if lang == 'en' else '目前沒有檔案做這個檢查。'}
                               if effect == 'adds' else {}))
    return {'id': f'R{n}', 'kind': 'cleanup', 'carried_from': carried, 'effect': effect,
            'removes': [] if effect == 'adds' else ['tests/old.test.sh'], 'en': loc('en'), 'zh-TW': loc('zh-TW')}


def report(items, generic=(), schema=1, blocks=1):
    block = '```retro-items\n' + json.dumps(dict(schema=schema, items=items, generic=list(generic))) + '\n```\n'
    return 'Readable report.\n' + block * blocks + 'REVIEWER_COMPLETE:retro\n'


class Fixture(unittest.TestCase):
    """A made-up engine with one external project, quoll-ledger."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='fm-retro-cases.')).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.engine = self.tmp / 'engine'
        self.home = self.tmp / 'home'
        (self.engine / 'state').mkdir(parents=True)
        self.home.mkdir()
        self.write_config()
        self.me = dict(name='selfproj', external=False, ok=True, state=str(self.engine / 'state'),
                       tasks=str(self.engine / 'design/tasks'), github='owner/selfproj', reviewers=[])
        self.ext = dict(name='quoll-ledger', external=True, ok=True, state=str(self.home / 'projects/quoll-ledger/state'),
                        tasks=str(self.home / 'projects/quoll-ledger/tasks'), github='wombatcorp/quoll-ledger',
                        reviewers=['numbat-bot'])
        self.projects = [self.me, self.ext]
        Path(self.ext['state']).mkdir(parents=True)
        if R is not None:
            loader = patch.object(R, 'load_projects', lambda retro: [dict(p) for p in self.projects])
            loader.start()
            self.addCleanup(loader.stop)
            self.retro = R.Retro(self.engine)

    def write_config(self, retro=True, names=('selfproj', 'quoll-ledger')):
        entries = {'selfproj': '  selfproj:\n    repo: .\n    github: owner/selfproj\n    base: main\n    required_check: ci\n',
                   'quoll-ledger': '  quoll-ledger:\n    github: wombatcorp/quoll-ledger\n    base: main\n    required_check: ci\n',
                   'echidna-mart': '  echidna-mart:\n    github: platypus-inc/echidna-mart\n    base: main\n    required_check: ci\n'}
        text = f'home: {self.home}\n'
        if retro:
            text += 'retro:\n  vendor: claude\n  model: claude-opus-5-5\n'
        text += 'default_project: selfproj\nprojects:\n' + ''.join(entries[n] for n in names)
        (self.engine / 'config.yaml').write_text(text)

    def index(self, baseline, last=None, open_run=None):
        self.retro.dir.mkdir(parents=True, exist_ok=True)
        R.write_json(self.retro.index_path, dict(schema=1, baseline_at=iso(baseline), last_completed=last, open_run=open_run))

    def merges(self, state, times, task=None):
        with open(Path(state) / 'events.jsonl', 'a') as out:
            for n, ts in enumerate(times, 1):
                out.write(json.dumps(dict(ts=iso(ts), actor='captain', type='merged', pr=n + 100 * len(times), **({'task': task} if task else {}))) + '\n')

    def run_with(self, rounds, state='reviewed', when=BASE):
        """A run whose rounds already answered: {label: [items]}."""
        run = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime(when)) + '-' + os.urandom(3).hex()
        folder = self.retro.run_dir(run)
        R.write_json(folder / 'private/labels.json', R.labels(self.retro, self.projects))
        names = R.run_labels(self.retro, run)
        for label, items in rounds.items():
            project = next((p for p in self.projects if p['name'] == names.get(label)), None)
            R.write_json(R.private_dir(self.retro, run, label, project) / 'items.json', dict(items=items, generic=[]))
            R.write_json(folder / 'rounds' / f'{label}.json', dict(status='ok', items=len(items), carried=[
                dict(id=i['id'], carried_from=i['carried_from']) for i in items if i.get('carried_from')]))
        R.write_json(folder / 'state.json', dict(schema=1, run_id=run, state=state, started_at=iso(when),
                                                 window=dict(start=iso(when - DAY), end=iso(when)), rounds=list(rounds)))
        index = R.load_index(self.retro) or dict(schema=1, baseline_at=iso(when - 9 * DAY), last_completed=None)
        index['open_run'] = run
        R.write_json(self.retro.index_path, index)
        return run

    def ext_label(self):
        return R.label_for(R.salt(self.retro), 'quoll-ledger')

    def publish(self, run):
        """What fm-decide.sh does with the prepared card, without a shell."""
        prepared = R.card_prepare(self.engine, run)
        details = json.loads(Path(prepared['details']).read_text())
        Path(prepared['details']).unlink()
        payload = dict(id=prepared['id'], kind='choice', purpose='retro', details=details, title=details['en']['title'])
        file = self.tmp / 'payload.json'
        file.write_text(json.dumps(payload))
        R.publish_numeric(self.engine / 'state', prepared['id'], file, run)
        R.card_finish(self.engine, run)
        return prepared['id'], details

    def answer(self, card, chosen, choices=None):
        pending = json.loads((self.engine / 'state/pending' / f'{card}.json').read_text())
        ids = [i['id'] for i in pending['details']['en']['items']]
        record = dict(id=card, chosen=chosen, purpose='retro', details=pending['details'])
        record['item_answers'] = [dict(index=i, id=x, choice=(choices or {}).get(x, 'C' if chosen == 'C' else 'A'))
                                  for i, x in enumerate(ids)]
        (self.engine / 'state/decisions').mkdir(parents=True, exist_ok=True)
        (self.engine / 'state/decisions' / f'{card}.json').write_text(json.dumps(record))
        (self.engine / 'state/pending' / f'{card}.json').unlink()

    def crash_call(self, point, code):
        env = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
        env['FM_RETRO_TEST_CRASH'] = point
        prelude = ('import sys, json; sys.path.insert(0, %r); import fm_retro as R\n'
                   'R.load_projects = lambda retro: json.loads(%r)\n') % (str(ROOT / 'bin/lib'), json.dumps(self.projects))
        return subprocess.run([sys.executable, '-c', prelude + code], env=env, capture_output=True, text=True).returncode


@needs_retro
class Due(Fixture):
    def due(self, now):
        return R.due_state(self.engine, now=now, projects=self.projects)

    def test_due_exactly_seven_days(self):
        self.index(BASE)
        self.assertTrue(self.due(BASE + 7 * DAY)['due'])

    def test_not_due_six_days_23_hours(self):
        self.index(BASE)
        self.assertFalse(self.due(BASE + 7 * DAY - 3600)['due'])

    def test_due_ten_merges_split_across_two_projects(self):
        self.index(BASE)
        self.merges(self.me['state'], [BASE + i for i in range(1, 6)])
        self.merges(self.ext['state'], [BASE + i for i in range(1, 6)])
        state = self.due(BASE + DAY)
        self.assertEqual((state['due'], state['merges']), (True, 10))

    def test_not_due_nine_merges(self):
        self.index(BASE)
        self.merges(self.me['state'], [BASE + i for i in range(1, 5)])
        self.merges(self.ext['state'], [BASE + i for i in range(1, 6)])
        self.assertEqual((self.due(BASE + DAY)['due'], self.due(BASE + DAY)['merges']), (False, 9))

    def test_first_run_after_the_baseline(self):
        self.merges(self.me['state'], [BASE - 10 * DAY] * 12)
        first = self.due(BASE)
        self.assertEqual((first['due'], first['identity'], first['start']), (False, 'retro-due-initial', iso(BASE)))
        self.assertEqual(json.loads(self.retro.index_path.read_text())['baseline_at'], iso(BASE))
        self.assertTrue(self.due(BASE + 7 * DAY)['due'])

    def test_late_answer_moves_the_clock_not_the_merge_window(self):
        last = dict(run_id='20260901T000000Z-aaaaaa', window_end=iso(BASE), completed_at=iso(BASE + 5 * DAY))
        self.index(BASE - 30 * DAY, last=last)
        self.assertFalse(self.due(BASE + 8 * DAY)['due'])
        self.assertTrue(self.due(BASE + 12 * DAY)['due'])
        self.merges(self.me['state'], [BASE + 3600 + i for i in range(10)])
        state = self.due(BASE + 6 * DAY)
        self.assertEqual((state['due'], state['identity']), (True, 'retro-due-20260901T000000Z-aaaaaa'))

    def test_due_count_uses_rows_the_caller_already_read(self):
        # the autopilot passes its one poll read of the self event log (T-273)
        self.index(BASE)
        (Path(self.me['state']) / 'events.jsonl').write_text('')
        rows = [dict(ts=iso(BASE + i), actor='captain', type='merged', pr=i) for i in range(1, 11)]
        given = {str(Path(self.me['state']).resolve()): rows}
        state = R.due_state(self.engine, now=BASE + DAY, projects=self.projects, events=given)
        self.assertEqual((state['due'], state['merges']), (True, 10))
        self.assertEqual(self.due(BASE + DAY)['merges'], 0)

    def test_restart_gives_the_same_answer(self):
        self.index(BASE)
        first, second = self.due(BASE + 8 * DAY), self.due(BASE + 8 * DAY)
        self.assertEqual(first, second)

    def test_open_run_is_never_due(self):
        self.index(BASE, open_run='20260901T000000Z-aaaaaa')
        R.write_json(self.retro.run_dir('20260901T000000Z-aaaaaa') / 'state.json', dict(state='awaiting-answer'))
        self.assertFalse(self.due(BASE + 30 * DAY)['due'])

    def test_config_without_retro_section(self):
        self.write_config(retro=False)
        self.index(BASE)
        self.assertTrue(self.due(BASE + 7 * DAY)['due'])
        with self.assertRaises(R.Refused) as refused:
            R.retro_config(self.retro)
        self.assertEqual(refused.exception.code, 65)
        self.assertIn('retro.vendor', str(refused.exception))


@needs_retro
class Index(Fixture):
    def test_two_concurrent_first_initializations(self):
        code = 'import sys, json; sys.path.insert(0, %r); import fm_retro as R; R.begin(R.Retro(%r), float(sys.argv[1]), json.loads(%r))' % (
            str(ROOT / 'bin/lib'), str(self.engine), json.dumps(self.projects))
        # both children owned through the lifeline by this process (T-151)
        import fm_lifeline
        procs = [fm_lifeline.start([sys.executable, '-c', code, str(BASE + n)]) for n in (1, 2)]
        self.assertEqual([p.wait() for p in procs], [0, 0])
        baseline = json.loads(self.retro.index_path.read_text())['baseline_at']
        self.assertIn(baseline, (iso(BASE + 1), iso(BASE + 2)))
        R.begin(self.retro, BASE + 99, self.projects)
        self.assertEqual(json.loads(self.retro.index_path.read_text())['baseline_at'], baseline)

    def test_window_end_only_moves_forward(self):
        old = dict(schema=1, baseline_at=iso(BASE), open_run=None,
                   last_completed=dict(run_id='x', window_end=iso(BASE + DAY), completed_at=iso(BASE + DAY)))
        back = dict(old, last_completed=dict(run_id='y', window_end=iso(BASE), completed_at=iso(BASE + 2 * DAY)))
        with self.assertRaises(R.Refused):
            R.save_index(self.retro, back, old)

    def test_completion_racing_a_new_run(self):
        run = self.run_with({'self': [item(1)]})
        card, _ = self.publish(run)
        with self.assertRaises(R.Refused) as busy:
            R.start_run(self.retro, BASE + DAY, self.projects)
        self.assertEqual(busy.exception.code, 75)
        self.answer(card, 'A')
        R.record(self.engine, run)
        started, fd = R.start_run(self.retro, BASE + 2 * DAY, self.projects)
        os.close(fd)
        index = json.loads(self.retro.index_path.read_text())
        self.assertEqual((index['open_run'], index['last_completed']['run_id']), (started, run))


@needs_retro
class Labels(Fixture):
    def test_label_survives_reordering(self):
        before = R.labels(self.retro, self.projects)
        self.write_config(names=('quoll-ledger', 'selfproj'))
        self.projects.reverse()
        self.assertEqual(before, R.labels(self.retro, self.projects))
        self.assertRegex(self.ext_label(), r'^P-[0-9a-f]{8}$')

    def test_removed_project_with_card_and_claim_in_flight(self):
        label = self.ext_label()
        run = self.run_with({label: [item(1), item(2)]})
        card, details = self.publish(run)
        self.assertEqual([i['id'] for i in details['en']['items']], [f'{label}/R1', f'{label}/R2'])
        self.answer(card, 'A', {f'{label}/R2': 'C'})
        R.record(self.engine, run)
        R.claim(self.engine, run, f'{label}/R1')
        self.projects.remove(self.ext)
        self.write_config(names=('selfproj',))
        R.status(self.engine)   # the public command repairs it, nothing else
        mine = json.loads((self.retro.run_dir(run) / 'proposals' / f'{label}-R1.json').read_text())
        self.assertEqual(mine, dict(status='refused', reason='project removed'))
        with self.assertRaises(R.Refused) as refused:
            R.link(self.engine, run, f'{label}/R1', 'T-5')
        self.assertIn('project removed', str(refused.exception))
        self.assertEqual(R.carried_items(self.retro, label, self.projects, '99999999T999999Z-ffffff'), ([], []))


@needs_retro
class Entry(Fixture):
    def test_every_entry_point_refuses_an_external_context(self):
        env = dict(os.environ, FM_EXTERNAL='1')
        for argv in (['bash', str(ROOT / 'bin/fm-retro.sh'), 'status'],
                     [sys.executable, str(ROOT / 'bin/lib/fm_retro.py'), 'request', '--engine', str(self.engine)],
                     ['bash', str(ROOT / 'bin/fm-review.sh'), '--retro', '20261001T000000Z-abcdef', '--retro-cross']):
            self.assertEqual(subprocess.run(argv, env=env, capture_output=True, stdin=subprocess.DEVNULL).returncode, 64, argv)

    def test_run_refuses_without_retro_config(self):
        self.write_config(retro=False)
        result = subprocess.run([sys.executable, str(ROOT / 'bin/lib/fm_retro.py'), 'run', '--engine', str(self.engine)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 65)
        self.assertIn('retro.vendor', result.stderr)


@needs_retro
class Runs(Fixture):
    def test_held_run_lock_refuses(self):
        self.retro.dir.mkdir(parents=True)
        fd = os.open(self.retro.run_lock, os.O_RDWR | os.O_CREAT)
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            with self.assertRaises(R.Refused) as refused:
                R.start_run(self.retro, BASE, self.projects)
            self.assertEqual((refused.exception.code, str(refused.exception)), (75, 'a retro is running'))
        finally:
            os.close(fd)

    def test_dead_owner_before_open_run_was_written(self):
        self.index(BASE - 9 * DAY)
        self.assertEqual(self.crash_call('run-before-open', 'R.start_run(R.Retro(%r), %r, json.loads(%r))' % (
            str(self.engine), BASE, json.dumps(self.projects))), 86)
        dead = self.retro.runs()[0]
        R.begin(self.retro, BASE + 1, self.projects)
        self.assertEqual(R.run_state(self.retro, dead)['failure'], 'interrupted')
        self.assertIsNone(R.load_index(self.retro)['open_run'])

    def test_dead_owner_after_open_run_was_written(self):
        self.index(BASE - 9 * DAY)
        self.crash_call('run-after-open', 'R.start_run(R.Retro(%r), %r, json.loads(%r))' % (str(self.engine), BASE, json.dumps(self.projects)))
        dead = self.retro.runs()[0]
        self.assertEqual(R.load_index(self.retro)['open_run'], dead)
        fresh, fd = R.start_run(self.retro, BASE + 1, self.projects)
        os.close(fd)
        self.assertEqual((R.run_state(self.retro, dead)['state'], R.run_state(self.retro, dead)['failure']), ('failed', 'interrupted'))
        self.assertEqual(R.load_index(self.retro)['open_run'], fresh)

    def test_two_starts_within_one_second(self):
        self.index(BASE - 9 * DAY)
        first, fd = R.start_run(self.retro, BASE, self.projects)
        try:
            with self.assertRaises(R.Refused):
                R.start_run(self.retro, BASE, self.projects)
        finally:
            os.close(fd)
        with R.Locked(self.retro):
            R.fail_run(self.retro, first, 'round failed: self')
        second, fd = R.start_run(self.retro, BASE, self.projects)
        os.close(fd)
        self.assertNotEqual(first, second)
        self.assertEqual(first[:16], second[:16])

    def test_retry_after_failure_and_the_board_request(self):
        self.index(BASE - 9 * DAY)
        requested = R.request(self.engine, now=BASE)
        with self.assertRaises(R.Refused) as again:
            R.request(self.engine, now=BASE)
        self.assertEqual(again.exception.code, 75)
        run, fd = R.start_run(self.retro, BASE, self.projects)
        os.close(fd)
        self.assertEqual(json.loads((self.retro.run_dir(run) / 'request.json').read_text())['source'], 'board')
        with R.Locked(self.retro):
            R.fail_run(self.retro, run, 'inputs too large')
        self.assertIsNone(R.load_index(self.retro)['open_run'])
        retry, fd = R.start_run(self.retro, BASE + 5, self.projects)
        os.close(fd)
        self.assertNotEqual(run, retry)
        self.assertTrue(requested['request_id'])


@needs_retro
class Metrics(Fixture):
    def seed(self):
        state = Path(self.me['state'])
        events = [dict(ts=iso(BASE), actor='worker-ada-t1-r1', type='dispatched', task='T-1'),
                  dict(ts=iso(BASE + 100), actor='worker-bo-t1-r2', type='dispatched', task='T-1'),
                  dict(ts=iso(BASE + 50), actor='reviewer-x-t1-r1', type='dispatched', task='T-1'),
                  dict(ts=iso(BASE + 1000), actor='captain', type='merged', task='T-1', pr=7),
                  dict(ts=iso(BASE + 2000), actor='captain', type='merged', pr=9, data=dict(untracked=True)),
                  dict(ts=iso(BASE + 3000), type='merged')]
        (state / 'events.jsonl').write_text(''.join(json.dumps(e) + '\n' for e in events))
        for actor, number in (('worker-ada-t1-r1', 1), ('worker-bo-t1-r2', 2)):
            R.write_json(state / 'runs' / actor / 'identity.json', dict(round=number))
        for n, scope in ((1, ['a']), (2, ['a', 'b']), (10, ['a', 'c'])):
            R.write_json(state / 'pins/T-1' / f'{n}.json', dict(snapshots=dict(spec=dict(text=json.dumps(dict(id='T-1', scope=scope))))))
        from fm_evidence import Store
        store = Store(str(state), 'selfproj', 'T-1', external=False)
        for v in json.loads((FIXTURES / 'verdicts.json').read_text())['readable']:
            store.append('verdict', 1, 'reviewer-x', '', v['text'], verdict=v['verdict'], provenance=dict(level='legacy'))
        store.append('ask', 1, 'worker-ada', 'a' * 40, 'ASK-PASS-CRITERIA:T-1\nWhich list?')
        store.append('ask', 1, 'worker-ada', 'a' * 40, 'WORKER_BLOCKED:T-1 stuck')
        R.write_json(state / 'decisions/D-selfproj-T1-1.json', dict(id='D-selfproj-T1-1', task='T-1', purpose='dispatch', chosen='A'))
        return R.compute_metrics(self.retro, self.me, 'RUN', 'self', iso(BASE - 1), iso(BASE + 5000), BASE + 6000)

    def test_task_row_every_field(self):
        row = self.seed()['prs'][0]
        self.assertEqual(row, dict(
            pr=7, task='T-1', merged_at=iso(BASE + 1000), worker_attempts=2, worker_rounds=2,
            dispatch_to_merge_seconds=1000, spec_versions=3, review_rejections=2, external_findings=None,
            scope_first=['a'], scope_last=['a', 'c'], scope_added=['c'], scope_removed=[],
            standing=[dict(n=1, open_rounds=1), dict(n=2, open_rounds=2), dict(n=4, open_rounds=1)],
            stops={'ASK-PASS-CRITERIA': 1, 'WORKER_BLOCKED': 1},
            cards=[dict(id='D-selfproj-T1-1', purpose='dispatch', chosen='A')],
            ci=None, ci_reason='unreachable', unknown=['external_findings', 'ci']))

    def test_taskless_row_and_old_events(self):
        doc = self.seed()
        self.assertEqual([r['pr'] for r in doc['prs']], [7, 9])
        row = doc['prs'][1]
        self.assertEqual(row['task'], None)
        for field in R.TASK_FIELDS:
            self.assertIsNone(row[field], field)
        self.assertEqual(row['unknown'], ['task', *R.TASK_FIELDS, 'ci'])

    def test_totals_keep_missing_data_visible(self):
        totals = self.seed()['totals']
        self.assertEqual(totals['worker_attempts'], dict(sum=2, known_rows=1))
        self.assertEqual(totals['external_findings'], dict(sum=0, known_rows=0))
        self.assertEqual(totals['stops'], {'ASK-PASS-CRITERIA': dict(sum=1, known_rows=1), 'WORKER_BLOCKED': dict(sum=1, known_rows=1)})
        self.assertEqual(totals['ci']['reruns'], dict(sum=0, known_rows=0))
        self.assertIn('| 7 | "T-1" |', R.metrics_md(self.seed()))

    def test_unreadable_standing_token_gives_null(self):
        records = [dict(kind='verdict', **v) for v in json.loads((FIXTURES / 'verdicts.json').read_text())['unreadable']]
        self.assertIsNone(R.standing(records, 'T-1'))
        self.assertIsNone(R.standing([dict(kind='verdict', text='APPROVE:T-1')], 'T-1'))
        self.assertEqual(R.status_token('  **open — x**'), 'open')

    def test_external_findings_are_distinct(self):
        from fm_evidence import Store
        state = Path(self.ext['state'])
        (state / 'events.jsonl').write_text(json.dumps(dict(ts=iso(BASE + 10), type='merged', task='T-3', pr=4)) + '\n')
        store = Store(str(state), 'quoll-ledger', 'T-3', external=True)
        for ids in ((1, 2), (2, 3)):
            store.append('external-verdict', 1, 'github', 'a' * 40, 'x', findings=[dict(id=i) for i in ids])
        row = R.compute_metrics(self.retro, self.ext, 'RUN', 'P-x', iso(BASE), iso(BASE + 99), BASE)['prs'][0]
        self.assertEqual(row['external_findings'], 3)


@needs_retro
class Ci(unittest.TestCase):
    def api(self, runs, attempts, pages=None, fail=()):
        def call(endpoint):
            if any(f in endpoint for f in fail):
                raise R.Unreachable(endpoint)
            if endpoint.endswith('/pulls/5'):
                return dict(head=dict(ref='t-1-work'))
            if '/attempts/' in endpoint:
                run, k = endpoint.split('/runs/')[1].split('/attempts/')
                return attempts[(int(run), int(k))]
            if 'per_page=1' in endpoint and 'branch' not in endpoint:
                return dict(total_count=0)
            if pages is not None:
                return dict(workflow_runs=pages)
            return dict(workflow_runs=runs)
        return call

    def wf_run(self, rid, wf, head, attempt=1, created='2026-10-01T00:00:00Z', prs=(5,)):
        return dict(id=rid, workflow_id=wf, head_sha=head, run_attempt=attempt, created_at=created,
                    pull_requests=[dict(number=n) for n in prs])

    def ci(self, runs, attempts, **kw):
        return R.ci_metrics(self.api(runs, attempts, **kw), 'o/r', 5)

    def test_real_red_and_an_unrelated_green_workflow(self):
        runs = [self.wf_run(1, 'ci', 'a'), self.wf_run(2, 'lint', 'a', created='2026-10-02'), self.wf_run(3, 'ci', 'b', created='2026-10-03')]
        attempts = {(1, 1): dict(conclusion='failure', head_sha='a'), (2, 1): dict(conclusion='success', head_sha='a'),
                    (3, 1): dict(conclusion='success', head_sha='b')}
        self.assertEqual(self.ci(runs, attempts), (dict(red=dict(real=1, flaky=0, infrastructure=0, unknown=0), reruns=0), None))
        unrelated = runs[:2]
        self.assertEqual(self.ci(unrelated, attempts)[0]['red']['unknown'], 1)

    def test_rewritten_head_is_still_this_pull_request(self):
        runs = [self.wf_run(1, 'ci', 'old'), self.wf_run(2, 'ci', 'new', created='2026-10-05'), self.wf_run(3, 'ci', 'x', prs=(6,))]
        attempts = {(1, 1): dict(conclusion='failure', head_sha='old'), (2, 1): dict(conclusion='success', head_sha='new'),
                    (3, 1): dict(conclusion='failure', head_sha='x')}
        self.assertEqual(self.ci(runs, attempts)[0]['red'], dict(real=1, flaky=0, infrastructure=0, unknown=0))

    def test_repeated_attempts_are_flaky_and_reruns(self):
        runs = [self.wf_run(1, 'ci', 'a', attempt=3)]
        attempts = {(1, 1): dict(conclusion='failure', head_sha='a'), (1, 2): dict(conclusion='failure', head_sha='a'),
                    (1, 3): dict(conclusion='success', head_sha='a')}
        self.assertEqual(self.ci(runs, attempts)[0], dict(red=dict(real=0, flaky=2, infrastructure=0, unknown=0), reruns=2))

    def test_cancellation_then_a_successful_rerun(self):
        runs = [self.wf_run(1, 'ci', 'a', attempt=2)]
        attempts = {(1, 1): dict(conclusion='cancelled', head_sha='a'), (1, 2): dict(conclusion='success', head_sha='a')}
        self.assertEqual(self.ci(runs, attempts)[0], dict(red=dict(real=0, flaky=0, infrastructure=1, unknown=0), reruns=1))

    def test_unreadable_attempt_counts_unknown(self):
        runs = [self.wf_run(1, 'ci', 'a', attempt=2)]
        attempts = {(1, 2): dict(conclusion='success', head_sha='a')}
        self.assertEqual(self.ci(runs, attempts, fail=('/attempts/1',))[0]['red']['unknown'], 1)

    def test_page_cap_truncates(self):
        full = [self.wf_run(i, 'ci', 'a') for i in range(100)]
        self.assertEqual(self.ci([], {}, pages=full), (None, 'truncated'))

    def test_unreachable_and_no_actions_history(self):
        self.assertEqual(self.ci([], {}, fail=('pulls',)), (None, 'unreachable'))
        self.assertEqual(self.ci([], {}), (None, 'no actions history'))


@needs_retro
class Projection(Fixture):
    def test_projection_hides_paths_decision_ids_and_task_ids(self):
        row = dict(pr=7, task='T-77', merged_at=iso(BASE), worker_attempts=1, worker_rounds=1, dispatch_to_merge_seconds=5,
                   spec_versions=2, review_rejections=1, external_findings=3, scope_first=['wombatcorp/secret.py'],
                   scope_last=['wombatcorp/secret.py', 'x'], scope_added=['x'], scope_removed=[],
                   standing=[dict(n=1, open_rounds=2)], stops={'ASK-PASS-CRITERIA': 1, 'ASK-QUOLL-LEDGER': 2},
                   cards=[dict(id='D-quoll-ledger-T77-1', purpose='dispatch', chosen='A'),
                          dict(id='D-9', purpose='quoll-ledger', chosen='A')],
                   ci=dict(red=dict(real=1, flaky=0, infrastructure=0, unknown=0), reruns=1), ci_reason=None)
        check = R.Check(self.retro, self.projects)
        text = json.dumps(R.projection('P-1', dict(prs=[row]), check))
        for secret in ('secret.py', 'D-quoll', 'T-77', 'quoll', '"pr"'):
            self.assertNotIn(secret, text)
        projected = json.loads(text)['rows'][0]
        self.assertEqual((projected['scope_last'], projected['stops'], projected['cards']),
                         (2, {'ASK-PASS-CRITERIA': 1, 'REDACTED': 2}, [dict(purpose='REDACTED', chosen='A', count=1),
                                                                       dict(purpose='dispatch', chosen='A', count=1)]))
        self.assertTrue(check('the quoll-ledger flow') and check('numbat-bot said') and check(self.ext['state'] + '/x'))

    def test_cross_round_runs_for_approved_and_parked_firstmate_items_without_merges(self):
        earlier = self.run_with({'firstmate': [item(1), item(2)]}, when=BASE - 2 * DAY)
        card, _ = self.publish(earlier)
        self.answer(card, 'A', {'firstmate/R2': 'C'})
        R.record(self.engine, earlier)
        R.claim(self.engine, earlier, 'firstmate/R1')
        R.link(self.engine, earlier, 'firstmate/R1', 'T-31')
        run, fd = R.start_run(self.retro, BASE, self.projects)
        os.close(fd)
        with patch.object(R, 'github_api', lambda retro, project: None):
            targets = R.round_targets(self.retro, run, self.projects, BASE)
        self.assertEqual(targets, ['firstmate'])
        prompt = (self.retro.run_dir(run) / 'cross/prompt.txt').read_text()
        self.assertIn(f'{earlier}/firstmate/R1', prompt)
        self.assertIn(f'{earlier}/firstmate/R2', prompt)
        self.assertIn('not yet measurable', prompt)
        self.assertIn('"task": "T-31"', prompt)


@needs_retro
class Prompts(Fixture):
    def test_mandatory_overflow_fails_with_inputs_too_large(self):
        with self.assertRaises(R.TooLarge):
            R.assemble('head', 'x' * (R.CAP + 1), [])

    def test_optional_texts_are_cut_dropped_oldest_last_and_referenced(self):
        optional = [(f'PR #{n} T-{n} 0001.json REJECT', 'y' * 5000) for n in range(200, 0, -1)]
        prompt = R.assemble('head\n', 'mandatory\n', optional)
        self.assertLessEqual(len(prompt), R.CAP)
        self.assertIn('[cut: kept 2000 of 5000 characters]', prompt)
        self.assertIn('### PR #200 T-200', prompt)
        self.assertNotIn('### PR #1 T-1 ', prompt)
        tail = prompt.rsplit('## Left out', 1)[1]
        self.assertRegex(tail, r'Left out: \d+ optional texts\. References: PR #')
        self.assertLessEqual(tail.count('PR #'), 100)

    def test_parked_id_and_follow_up_overflow(self):
        parked = [dict(full_id=f'20260101T000000Z-aaaaaa/self/R{n}', reason='parked', item=item(1)) for n in range(1, 701)]
        follow = [dict(full_id=f'f{n}') for n in range(60)]
        text = R.mandatory_text('{}', follow, parked)
        self.assertIn('Follow-up items not shown: 10.', text)
        self.assertEqual(text.count('"full_id"'), 50 + 50)
        self.assertIn('Older parked items not listed: 150.', text)
        self.assertIn('20260101T000000Z-aaaaaa/self/R550', text)
        self.assertNotIn('20260101T000000Z-aaaaaa/self/R551\n', text)

    def test_project_separation_and_unreadable_state(self):
        label = self.ext_label()
        self.merges(self.me['state'], [BASE - 100], task='T-1')
        self.merges(self.ext['state'], [BASE - 100], task='T-9')
        (Path(self.ext['tasks'])).mkdir(parents=True)
        (Path(self.ext['tasks']) / 'T-9.json').write_text(json.dumps(dict(id='T-9', title='Quoll ledger sync', acceptance=['Wombats pay.'])))
        (self.engine / 'design/tasks').mkdir(parents=True)
        (self.engine / 'design/tasks/T-1.json').write_text(json.dumps(dict(id='T-1', title='Self only text', acceptance=['Self line.'])))
        self.index(BASE - 9 * DAY)
        run, fd = R.start_run(self.retro, BASE, self.projects, dict(base='main', commit='a' * 40))
        os.close(fd)
        with patch.object(R, 'github_api', lambda retro, project: None):
            self.assertEqual(R.round_targets(self.retro, run, self.projects, BASE), ['self', label, 'firstmate'])
        mine = (self.retro.run_dir(run) / 'projects/self/prompt.txt').read_text()
        theirs = (Path(self.ext['state']) / 'retro' / run / 'prompt.txt').read_text()
        cross = (self.retro.run_dir(run) / 'cross/prompt.txt').read_text()
        self.assertIn('Self only text', mine)
        self.assertNotIn('Quoll ledger', mine)
        self.assertIn('Quoll ledger sync', theirs)
        self.assertNotIn('Self only text', theirs)
        for text in ('Quoll', 'quoll', 'T-9', 'T-1', 'Self only'):
            self.assertNotIn(text, cross)
        for question in ('(a)', '(b)', '(c)', '(d)', '(e)'):
            self.assertIn(question, mine)
        info = R.round_info(self.engine, run, 'quoll-ledger', False)
        self.assertEqual(info['label'], label)
        self.assertIn(str(self.engine / 'state'), info['never_read'])
        self.assertIn(self.ext['state'], info['never_read'])
        # a self round's policy is written in the self tree: it names no project
        mine = R.round_info(self.engine, run, 'selfproj', False)['never_read']
        self.assertNotIn('quoll', json.dumps(mine))
        self.assertIn(str(self.home / 'projects'), mine)

    def test_approved_unmerged_external_item_with_zero_merges(self):
        label = self.ext_label()
        earlier = self.run_with({label: [item(1)]}, when=BASE - 2 * DAY)
        card, _ = self.publish(earlier)
        self.answer(card, 'A')
        R.record(self.engine, earlier)
        R.claim(self.engine, earlier, f'{label}/R1')
        R.link(self.engine, earlier, f'{label}/R1', 'T-40')
        run, fd = R.start_run(self.retro, BASE, self.projects)
        os.close(fd)
        with patch.object(R, 'github_api', lambda retro, project: None):
            self.assertIn(label, R.round_targets(self.retro, run, self.projects, BASE))
        theirs = (Path(self.ext['state']) / 'retro' / run / 'prompt.txt').read_text()
        self.assertIn('not yet measurable', theirs)
        self.assertIn('"task": "T-40"', theirs)


@needs_retro
class Parser(unittest.TestCase):
    def refused(self, text, why):
        with self.assertRaises(R.ReportError) as error:
            R.parse_report(text)
        self.assertIn(why, str(error.exception))

    def test_valid_report(self):
        parsed = R.parse_report(report([item(1), item(2, 'net-removal'), item(3, 'adds')], ['Rounds repeat.']))
        self.assertEqual([i['id'] for i in parsed['items']], ['R1', 'R2', 'R3'])
        self.assertEqual(parsed['generic'], ['Rounds repeat.'])

    def test_every_format_error(self):
        self.refused('no block', 'no retro-items block')
        self.refused(report([item(1)], blocks=2), 'more than one')
        self.refused('```retro-items\n{nope\n```', 'invalid JSON')
        self.refused(report([item(1)], schema=2), 'wrong schema')
        self.refused(report([item(1), item(1)]), 'duplicate id')
        broken = item(1); del broken['zh-TW']
        self.refused(report([broken]), 'missing locale zh-TW')
        self.refused(report([item(n) for n in range(1, 22)]), 'more than 20 items')
        self.refused(report([item(1)], ['g'] * 11), 'more than 10 generic')
        adds = item(1, 'adds'); del adds['en']['why_not_removal']
        self.refused(report([adds]), 'needs why_not_removal')
        self.refused(report([item(1, 'adds'), item(2)]), 'removal-first order')
        self.refused(report([item(10), item(2)]), 'removal-first order')


@needs_retro
class Card(Fixture):
    def test_eighty_items_put_sixty_on_the_card_and_park_the_rest(self):
        self.projects.append(dict(self.ext, name='echidna-mart', github='platypus-inc/echidna-mart',
                                  state=str(self.home / 'projects/echidna-mart/state'), reviewers=[]))
        self.write_config(names=('selfproj', 'quoll-ledger', 'echidna-mart'))
        labels = R.labels(self.retro, self.projects)
        external = sorted(l for l in labels if l.startswith('P-'))
        rounds = {'firstmate': [item(n) for n in range(1, 21)], 'self': [item(n, 'adds') for n in range(1, 21)]}
        for label in external:
            rounds[label] = [item(n, 'net-removal') for n in range(1, 21)]
        run = self.run_with(rounds)
        card, details = self.publish(run)
        ids = [i['id'] for i in details['en']['items']]
        self.assertEqual(len(ids), 60)
        self.assertEqual(ids[:21], [f'firstmate/R{n}' for n in range(1, 21)] + [f'{external[0]}/R1'])
        self.assertEqual(ids, [i['id'] for i in details['zh-TW']['items']])
        overflow = json.loads((self.retro.run_dir(run) / 'overflow.json').read_text())
        self.assertEqual((len(overflow['ids']), overflow['reason']), (20, 'card full'))
        self.assertIn('20', details['en']['notes'][0]['text'])
        self.answer(card, 'C')
        R.record(self.engine, run)
        answers = json.loads((self.retro.run_dir(run) / 'answers.json').read_text())
        self.assertEqual(sum(a.get('reason') == 'card full' for a in answers['items']), 20)
        import fm_ste
        self.assertTrue(fm_ste.check_details(details, 'choice')['ok'])

    def test_crash_between_reserving_and_raising_then_a_repeated_card(self):
        run = self.run_with({'self': [item(1)]})
        self.assertEqual(self.crash_call('card-reserved', 'R.card_prepare(%r, %r)' % (str(self.engine), run)), 86)
        reserved = json.loads((self.retro.run_dir(run) / 'card.json').read_text())['id']
        card, _ = self.publish(run)
        self.assertEqual(card, reserved)
        self.assertEqual(R.card_prepare(self.engine, run)['action'], 'none')
        self.assertEqual(sorted(p.name for p in (self.engine / 'state/pending').iterdir()), [card + '.json'])
        self.assertEqual(R.run_state(self.retro, run)['state'], 'awaiting-answer')

    def test_archived_card_fails_the_run(self):
        run = self.run_with({'self': [item(1)]})
        card, _ = self.publish(run)
        archive = self.engine / 'state/runtime/archived-pending'
        archive.mkdir(parents=True)
        (self.engine / 'state/pending' / f'{card}.json').rename(archive / f'{card}.json')
        self.assertEqual(R.card_prepare(self.engine, run)['action'], 'none')
        self.assertEqual((R.run_state(self.retro, run)['state'], R.run_state(self.retro, run)['failure']), ('failed', 'card archived'))
        self.assertIsNone(R.load_index(self.retro)['open_run'])

    def test_crash_after_publication_then_answer_before_recovery(self):
        run = self.run_with({'self': [item(1)]})
        prepared = R.card_prepare(self.engine, run)
        details = json.loads(Path(prepared['details']).read_text())
        (self.tmp / 'p.json').write_text(json.dumps(dict(id=prepared['id'], purpose='retro', details=details)))
        R.publish_numeric(self.engine / 'state', prepared['id'], self.tmp / 'p.json', run)
        self.assertEqual(R.run_state(self.retro, run)['state'], 'reviewed')
        self.answer(prepared['id'], 'A')
        R.due_state(self.engine, now=BASE + DAY, projects=self.projects)
        self.assertEqual(R.run_state(self.retro, run)['state'], 'completed')
        self.assertEqual(R.card_prepare(self.engine, run)['action'], 'none')
        self.assertEqual(len(list((self.engine / 'state/decisions').iterdir())), 1)

    def test_an_ordinary_card_never_takes_a_reserved_number(self):
        run = self.run_with({'self': [item(1)]})
        R.card_prepare(self.engine, run)
        (self.tmp / 'p.json').write_text('{}')
        with self.assertRaises(R.Refused):
            R.publish_numeric(self.engine / 'state', 'D-1000', self.tmp / 'p.json')
        self.assertEqual(R.publish_numeric(self.engine / 'state', 'D-1001', self.tmp / 'p.json').name, 'D-1001.json')


@needs_retro
class Completion(Fixture):
    POINTS = [f'{when}-{n}' for n in range(1, 5) for when in ('before', 'after')]

    def check_done(self, run, zero):
        state = R.run_state(self.retro, run)
        self.assertEqual((state['state'], state['completion_step']), ('completed', 'done'))
        self.assertEqual(R.load_index(self.retro)['last_completed']['run_id'], run)
        self.assertIsNone(R.load_index(self.retro)['open_run'])
        wakes = (self.engine / 'state/session/wake.jsonl')
        lines = [json.loads(l)['id'] for l in wakes.read_text().splitlines()] if wakes.exists() else []
        self.assertEqual(lines.count('retro-complete-' + run), 1 if zero else 0)

    def test_restart_at_every_step_of_a_card_run(self):
        for point in self.POINTS:
            with self.subTest(point=point):
                run = self.run_with({'self': [item(1)]})
                card, _ = self.publish(run)
                self.answer(card, 'A')
                self.assertEqual(self.crash_call(point, 'R.record(%r, %r)' % (str(self.engine), run)), 86)
                R.due_state(self.engine, now=BASE + DAY, projects=self.projects)
                self.check_done(run, False)

    def test_restart_at_every_step_of_a_zero_finding_run(self):
        for point in self.POINTS:
            with self.subTest(point=point):
                run = self.run_with({'self': []})
                code = 'r = R.Retro(%r)\nwith R.Locked(r): R.complete(r, %r, "zero")' % (str(self.engine), run)
                self.assertEqual(self.crash_call(point, code), 86)
                R.due_state(self.engine, now=BASE + DAY, projects=self.projects)
                with R.Locked(self.retro):
                    R.complete(self.retro, run, 'zero')
                self.check_done(run, True)
                self.assertEqual(json.loads((self.retro.run_dir(run) / 'answers.json').read_text())['items'], [])

    def test_repeated_and_differing_record(self):
        run = self.run_with({'self': [item(1), item(2)]})
        card, _ = self.publish(run)
        self.answer(card, 'A', {'self/R2': 'D'})
        R.record(self.engine, run)
        before = (self.retro.run_dir(run) / 'answers.json').read_text()
        R.record(self.engine, run)
        self.assertEqual(before, (self.retro.run_dir(run) / 'answers.json').read_text())
        decision = self.engine / 'state/decisions' / f'{card}.json'
        changed = json.loads(decision.read_text()); changed['item_answers'][1]['choice'] = 'A'
        decision.write_text(json.dumps(changed))
        with self.assertRaises(R.Refused):
            R.record(self.engine, run)
        with self.assertRaises(R.Refused):
            R.record(self.engine, run, 'D-4242')

    def test_supersession_stops_carrying_a_parked_item(self):
        first = self.run_with({'self': [item(1)]}, when=BASE - 3 * DAY)
        card, _ = self.publish(first)
        self.answer(card, 'C')
        R.record(self.engine, first)
        self.assertEqual(len(R.carried_items(self.retro, 'self', self.projects, '99999999T999999Z-ffffff')[1]), 1)
        second = self.run_with({'self': [item(1, carried=f'{first}/self/R1')]}, when=BASE)
        card, _ = self.publish(second)
        self.answer(card, 'A', {'self/R1': 'D'})
        R.record(self.engine, second)
        self.assertEqual(R.carried_items(self.retro, 'self', self.projects, '99999999T999999Z-ffffff')[1], [])


@needs_retro
class Claims(Fixture):
    def approved(self):
        label = self.ext_label()
        run = self.run_with({label: [item(1)], 'firstmate': [item(1)]})
        card, _ = self.publish(run)
        self.answer(card, 'A')
        R.record(self.engine, run)
        return run, label

    def manifests(self, run, label):
        private = Path(self.ext['state']) / 'retro' / run / 'proposals' / 'R1.json'
        mine = self.retro.run_dir(run) / 'proposals' / f'{label}-R1.json'
        return (json.loads(private.read_text()) if private.exists() else None,
                json.loads(mine.read_text()) if mine.exists() else None)

    def test_crash_between_the_two_claim_writes(self):
        run, label = self.approved()
        self.assertEqual(self.crash_call('claim-between', 'R.claim(%r, %r, %r)' % (str(self.engine), run, f'{label}/R1')), 86)
        private, mine = self.manifests(run, label)
        self.assertEqual((private['status'], mine), ('proposing', None))
        R.status(self.engine)   # the public command repairs the mirror
        self.assertEqual(self.manifests(run, label)[1], dict(status='proposing'))
        again = R.claim(self.engine, run, f'{label}/R1')
        self.assertTrue(again['already'])
        self.assertEqual(again['draft'], private['draft'])

    def test_crash_between_the_two_link_writes_and_after_link(self):
        run, label = self.approved()
        R.claim(self.engine, run, f'{label}/R1')
        self.assertEqual(self.crash_call('link-between', 'R.link(%r, %r, %r, "T-12")' % (str(self.engine), run, f'{label}/R1')), 86)
        self.assertEqual([m['status'] for m in self.manifests(run, label)], ['linked', 'proposing'])
        R.status(self.engine)
        self.assertEqual(self.manifests(run, label)[1], dict(status='linked'))
        self.assertEqual(R.claim(self.engine, run, f'{label}/R1')['status'], 'linked')

    def test_removal_during_recovery_leaves_exactly_one_proposal(self):
        run, label = self.approved()
        self.crash_call('claim-between', 'R.claim(%r, %r, %r)' % (str(self.engine), run, f'{label}/R1'))
        self.projects.remove(self.ext)
        R.status(self.engine)
        with self.assertRaises(R.Refused):
            R.claim(self.engine, run, f'{label}/R1')
        proposals = list((Path(self.ext['state']) / 'retro' / run / 'proposals').glob('*.json'))
        self.assertEqual(len(proposals), 1)
        self.assertEqual(self.manifests(run, label)[1]['status'], 'refused')

    def test_no_external_path_or_task_reaches_a_self_manifest(self):
        run, label = self.approved()
        R.claim(self.engine, run, f'{label}/R1')
        R.link(self.engine, run, f'{label}/R1', 'T-8080')
        mine = self.retro.run_dir(run) / 'proposals' / f'{label}-R1.json'
        self.assertEqual(json.loads(mine.read_text()), dict(status='linked'))
        firstmate = R.claim(self.engine, run, 'firstmate/R1')
        self.assertTrue(firstmate['draft'].startswith('design/tasks/'))
        R.link(self.engine, run, 'firstmate/R1', 'T-77')
        for file in self.retro.dir.rglob('*'):
            if file.is_file() and file.name != 'labels.json':
                self.assertNotIn('T-8080', file.read_text(errors='ignore'), file)
                self.assertNotIn(self.ext['state'], file.read_text(errors='ignore'), file)


@needs_retro
class Privacy(Fixture):
    """Every destination outside a project's private state is checked or
    contained before anything is kept there (made-up names only)."""

    def test_self_metrics_and_prompt_are_checked_before_written(self):
        state = Path(self.me['state'])
        self.merges(state, [BASE - 100], task='T-1')
        from fm_evidence import Store
        Store(str(state), 'selfproj', 'T-1', external=False).append('ask', 1, 'worker-a', 'a' * 40, 'ASK-QUOLL-LEDGER:T-1 which?')
        R.write_json(state / 'decisions/D-1.json', dict(id='D-1', task='T-1', purpose='decision', chosen='numbat-bot'))
        (self.engine / 'design/tasks').mkdir(parents=True)
        (self.engine / 'design/tasks/T-1.json').write_text(json.dumps(dict(id='T-1', title='Port quoll-ledger', acceptance=['x'])))
        self.index(BASE - 9 * DAY)
        run, fd = R.start_run(self.retro, BASE, self.projects, dict(base='main', commit='a' * 40))
        os.close(fd)
        with patch.object(R, 'github_api', lambda retro, project: None):
            R.round_targets(self.retro, run, self.projects, BASE)
        folder = self.retro.run_dir(run) / 'projects/self'
        for name in ('metrics.json', 'metrics.md', 'prompt.txt'):
            text = (folder / name).read_text()
            self.assertNotIn('quoll', text.lower(), name)
            self.assertNotIn('numbat', text.lower(), name)
        row = json.loads((folder / 'metrics.json').read_text())['prs'][0]
        self.assertEqual((row['stops'], row['cards'][0]['chosen']), ({'REDACTED': 1}, R.REDACTED))

    def test_card_details_stay_in_the_run_and_leave_once_published(self):
        run = self.run_with({self.ext_label(): [item(1, title='Trim the quoll-ledger flow.')]})
        prepared = R.card_prepare(self.engine, run)
        self.assertEqual(Path(prepared['details']), self.retro.run_dir(run) / 'private/card-details.json')
        file = self.tmp / 'p.json'
        file.write_text(json.dumps(dict(id=prepared['id'], purpose='retro')))
        R.publish_numeric(self.engine / 'state', prepared['id'], file, run)
        R.card_finish(self.engine, run)
        self.assertFalse(Path(prepared['details']).exists())

    def test_transport_copies_of_a_self_answer_are_contained(self):
        run = self.run_with({'self': []})
        transport = self.engine / 'state/runs/reviewer-x-retro-r1'
        R.write_text(transport / 'attempts/1/cli.log', 'raw answer about quoll-ledger\n')
        R.write_text(transport / 'attempts/1/final.txt', 'answer for wombatcorp\n')
        R.write_text(transport / 'identity.json', '{"round": 1}\n')
        self.assertTrue(R.accept(self.engine, run, 'self', report([item(1)]), run_dir=str(transport)))
        for name in ('attempts/1/cli.log', 'attempts/1/final.txt'):
            self.assertIn('withheld', (transport / name).read_text())
        self.assertEqual((transport / 'identity.json').read_text(), '{"round": 1}\n')

    def test_release_keeps_a_live_round_and_frees_an_ended_one(self):
        transport, checkout = self.tmp / 'run', self.tmp / 'checkout'
        (transport / 'a1').mkdir(parents=True); checkout.mkdir()
        R.write_json(transport / 'a1/execution.json', dict(started=True))
        R.write_text(transport / 'a1/cli.log', 'quoll-ledger\n')
        held = os.open(transport / 'a1/execution.lock', os.O_RDWR | os.O_CREAT)
        fcntl.flock(held, fcntl.LOCK_EX)
        self.assertEqual(R.release(self.engine, str(transport), str(checkout), True), dict(released=False, checkout=str(checkout)))
        self.assertTrue(checkout.is_dir())
        self.assertIn('quoll', (transport / 'a1/cli.log').read_text())
        os.close(held)   # the interrupted round's child ends
        self.assertEqual(R.release(self.engine, str(transport), str(checkout), True), dict(released=True))
        self.assertFalse(checkout.exists())
        self.assertIn('withheld', (transport / 'a1/cli.log').read_text())


@needs_retro
class Bookkeeping(Fixture):
    def completed(self, rounds, answers, when):
        run = self.run_with(rounds, when=when)
        R.write_json(self.retro.run_dir(run) / 'answers.json', dict(schema=1, run_id=run, items=answers, supersedes=[]))
        R.write_json(self.retro.run_dir(run) / 'state.json', dict(R.run_state(self.retro, run), state='completed'))
        R.write_json(self.retro.index_path, dict(R.load_index(self.retro), open_run=None))
        return run

    def test_follow_up_overflow_retires_only_what_was_shown(self):
        self.merges(self.me['state'], [BASE - 5 * DAY], task='T-1')
        ids = [f'self/R{n}' for n in range(1, 52)]
        earlier = self.completed({'self': [item(n) for n in range(1, 52)]}, [dict(id=i, choice='A') for i in ids], BASE - 6 * DAY)
        for n in range(1, 52):
            R.write_json(self.retro.run_dir(earlier) / 'proposals' / f'self-R{n}.json', dict(status='linked', task='T-1'))
        run, fd = R.start_run(self.retro, BASE, self.projects, dict(base='main', commit='a' * 40))
        os.close(fd)
        with patch.object(R, 'github_api', lambda retro, project: None):
            R.round_targets(self.retro, run, self.projects, BASE)
        retired = R.followed_now(self.retro, run, ['self'])
        self.assertEqual(len(retired), 50)
        self.assertNotIn(f'{earlier}/self/R51', retired)
        R.write_json(self.retro.run_dir(run) / 'followed.json', dict(ids=retired))
        R.write_json(self.retro.run_dir(run) / 'answers.json', dict(items=[]))
        R.write_json(self.retro.run_dir(run) / 'state.json', dict(R.run_state(self.retro, run), state='completed'))
        follow, _ = R.carried_items(self.retro, 'self', self.projects, '99999999T999999Z-ffffff')
        self.assertEqual([f['full_id'] for f in follow], [f'{earlier}/self/R51'])

    def test_card_full_items_survive_an_archived_card(self):
        self.projects.append(dict(self.ext, name='echidna-mart', github='platypus-inc/echidna-mart',
                                  state=str(self.home / 'projects/echidna-mart/state'), reviewers=[]))
        last = R.label_for(R.salt(self.retro), 'echidna-mart')
        run = self.run_with({'self': [item(n) for n in range(1, 21)], 'firstmate': [item(n) for n in range(1, 21)],
                             self.ext_label(): [item(n) for n in range(1, 21)], last: [item(n, 'adds') for n in range(1, 21)]})
        card, _ = self.publish(run)
        archive = self.engine / 'state/runtime/archived-pending'
        archive.mkdir(parents=True)
        (self.engine / 'state/pending' / f'{card}.json').rename(archive / f'{card}.json')
        R.status(self.engine)
        self.assertEqual(R.run_state(self.retro, run)['failure'], 'card archived')
        parked = R.carried_items(self.retro, last, self.projects, '99999999T999999Z-ffffff')[1]
        self.assertEqual((len(parked), {p['reason'] for p in parked}), (20, {'card full'}))

    def test_carried_from_must_name_a_parked_item_of_the_same_label(self):
        first = self.completed({'self': [item(1)]}, [dict(id='self/R1', choice='C')], BASE - 3 * DAY)
        for carried in (f'{first}/self/R9', f'{first}/firstmate/R1', f'20200101T000000Z-abcdef/self/R1'):
            with self.subTest(carried=carried):
                run = self.run_with({'self': []})
                self.assertFalse(R.accept(self.engine, run, 'self', report([item(1, carried=carried)])))
                self.assertIn('no parked item', json.loads((self.retro.run_dir(run) / 'projects/self/round.json').read_text())['reason'])
                R.write_json(self.retro.index_path, dict(R.load_index(self.retro), open_run=None))
        run = self.run_with({'self': []})
        self.assertTrue(R.accept(self.engine, run, 'self', report([item(1, carried=f'{first}/self/R1')])))

    def test_wording_the_card_refuses_fails_the_round_and_frees_the_next_retro(self):
        bad = item(1)
        bad['en']['why'] = 'The tool should ensure the suite will pass, etc.'
        self.merges(self.me['state'], [BASE - 100], task='T-1')
        self.index(BASE - 9 * DAY)
        accepted = []
        def round_(retro, run, label, names):
            accepted.append(R.accept(self.engine, run, label, report([bad])))
            return 0
        with patch.object(R, 'resolve_base', lambda retro, base: dict(base=base, commit='a' * 40)), \
                patch.object(R, 'github_api', lambda retro, project: None), patch.object(R, 'run_round', round_):
            result = R.run(self.engine, now=BASE)
        self.assertEqual(accepted, [False])
        self.assertEqual((result['state'], result['failure']), ('failed', 'invalid report: self'))
        reason = json.loads((self.retro.run_dir(result['run_id']) / 'projects/self/round.json').read_text())['reason']
        self.assertIn('card sentence rules', reason)
        self.assertEqual(R.run_state(self.retro, result['run_id'])['state'], 'failed')
        self.assertIsNone(R.load_index(self.retro)['open_run'])
        self.assertTrue(R.due_state(self.engine, now=BASE + 1, projects=self.projects)['due'])

    def test_optional_text_never_fails_a_prompt_whose_mandatory_part_fits(self):
        head = 'head\n'
        mandatory = 'm' * (199_976 - len(head) - len(R.drop_line([], 0)))
        self.assertEqual(len(head + mandatory + R.drop_line([], 0)), 199_976)
        prompt = R.assemble(head, mandatory, [('PR #1 T-1 0001.json REJECT', 'y' * 5000)])
        self.assertLessEqual(len(prompt), R.CAP)
        self.assertIn('Left out: 1 optional texts.', prompt)
        mandatory = 'm' * (R.CAP - len(head) - len(R.drop_line(['r'], 0)) - 30)
        prompt = R.assemble(head, mandatory, [('r', 'short')])
        self.assertLessEqual(len(prompt), R.CAP)


@needs_retro
class Completeness(Fixture):
    def test_linked_row_keeps_its_ci_history(self):
        self.merges(self.me['state'], [BASE - 100], task='T-1')
        runs = [dict(id=1, workflow_id='ci', head_sha='a', run_attempt=1, created_at='x', pull_requests=[dict(number=101)])]
        def api(endpoint):
            if '/pulls/' in endpoint: return dict(head=dict(ref='b'))
            if '/attempts/' in endpoint: return dict(conclusion='success', head_sha='a')
            return dict(workflow_runs=runs)
        row = R.linked_row(self.retro, self.me, 'T-1', iso(BASE), BASE, api)
        self.assertEqual((row['ci'], row['ci_reason']), (dict(red=dict(real=0, flaky=0, infrastructure=0, unknown=0), reruns=0), None))

    def test_a_run_listed_twice_counts_once(self):
        listed = dict(id=1, workflow_id='ci', head_sha='a', run_attempt=2, created_at='x', pull_requests=[dict(number=5)])
        api = lambda endpoint: dict(conclusion='failure' if endpoint.endswith('/1') else 'success', head_sha='a')
        self.assertEqual(R.classify(api, 'o/r', 5, [listed, dict(listed)]), dict(red=dict(real=0, flaky=1, infrastructure=0, unknown=0), reruns=1))

    def test_one_unreadable_worker_identity_makes_rounds_unknown(self):
        state = Path(self.me['state'])
        events = [dict(ts=iso(BASE), actor='worker-a-t1-r1', type='dispatched', task='T-1'),
                  dict(ts=iso(BASE + 1), actor='worker-b-t1-r2', type='dispatched', task='T-1'),
                  dict(ts=iso(BASE + 9), actor='captain', type='merged', task='T-1', pr=3)]
        (state / 'events.jsonl').write_text(''.join(json.dumps(e) + '\n' for e in events))
        R.write_json(state / 'runs/worker-a-t1-r1/identity.json', dict(round=1))
        row = R.compute_metrics(self.retro, self.me, 'RUN', 'self', iso(BASE - 1), iso(BASE + 99), BASE)['prs'][0]
        self.assertEqual((row['worker_attempts'], row['worker_rounds']), (2, None))
        self.assertIn('worker_rounds', row['unknown'])


@needs_retro
class Source(Fixture):
    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.engine), '-c', 'user.name=t', '-c', 'user.email=t@t', *args],
                              capture_output=True, text=True, check=True).stdout.strip()

    def test_the_configured_base_binds_prompt_checkout_and_record(self):
        self.git('init', '-q', '-b', 'main')
        self.git('commit', '-q', '--allow-empty', '-m', 'main')
        self.git('switch', '-q', '-c', 'trunk')
        self.git('commit', '-q', '--allow-empty', '-m', 'trunk')
        trunk = self.git('rev-parse', 'HEAD')
        self.git('switch', '-q', '-c', 'elsewhere')
        self.git('commit', '-q', '--allow-empty', '-m', 'head')
        self.assertNotEqual(self.git('rev-parse', 'HEAD'), trunk)
        self.assertEqual(R.resolve_base(self.retro, 'trunk'), dict(base='trunk', commit=trunk))
        with self.assertRaises(R.Refused):
            R.resolve_base(self.retro, 'no-such-branch')
        self.merges(self.me['state'], [BASE - 100], task='T-1')
        self.index(BASE - 9 * DAY)
        run, fd = R.start_run(self.retro, BASE, self.projects, R.resolve_base(self.retro, 'trunk'))
        os.close(fd)
        with patch.object(R, 'github_api', lambda retro, project: None):
            R.round_targets(self.retro, run, self.projects, BASE)
        self.assertIn('engine at commit ' + trunk, (self.retro.run_dir(run) / 'projects/self/prompt.txt').read_text())
        self.assertEqual(R.round_info(self.engine, run, 'selfproj', False)['base_commit'], trunk)
        R.accept(self.engine, run, 'self', report([]))
        self.assertEqual(json.loads((self.retro.run_dir(run) / 'rounds/self.json').read_text())['base_commit'], trunk)


class Autopilot(unittest.TestCase):
    """Fails on a tree whose autopilot never asks whether a retro is due."""

    def setUp(self):
        import fm_autopilot as A
        self.A = A
        self.tmp = Path(tempfile.mkdtemp(prefix='fm-retro-pilot.')).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        (self.tmp / 'state/retro').mkdir(parents=True)
        (self.tmp / 'tasks').mkdir()
        self.ctx = dict(engine=str(self.tmp), state=str(self.tmp / 'state'), target=str(self.tmp), project='self',
                        repository='owner/repo', base='main', evidence_project='self', external=False, tasks=str(self.tmp / 'tasks'))
        self.index(None)
        if R is not None:
            loader = patch.object(R, 'load_projects', lambda retro: [dict(name='', external=False, ok=True, state=str(self.tmp / 'state'))])
            loader.start(); self.addCleanup(loader.stop)

    def index(self, last):
        (self.tmp / 'state/retro/index.json').write_text(json.dumps(dict(schema=1, baseline_at=iso(BASE), last_completed=last, open_run=None)))

    def pilot(self, now):
        pilot = self.A.Pilot(self.ctx, clock=lambda: now)
        def offline(*args, **kwargs):
            raise RuntimeError('offline')
        pilot.pages = pilot.api = offline
        pilot.emit = pilot.notify = lambda *a, **k: None
        pilot.push = lambda *a: None
        return pilot

    def retro_wakes(self, pilot):
        return sorted(ident for ident, wake in pilot.data['wakes'].items() if wake['line'] == 'retro due')

    def test_one_retro_due_wake_per_window(self):
        pilot = self.pilot(BASE + 8 * DAY)
        pilot.poll(); pilot.poll(); pilot.poll()
        first = self.retro_wakes(pilot)
        self.assertEqual(len(first), 1)
        self.assertIsNone(pilot.data['wakes'][first[0]]['task'])
        restarted = self.pilot(BASE + 9 * DAY)
        restarted.poll()
        self.assertEqual(self.retro_wakes(restarted), first)
        self.assertEqual(first[0], 'autopilot-' + self.A.key(['self', 'retro-due-initial']))
        self.index(dict(run_id='20261001T000000Z-abcdef', window_end=iso(BASE + 8 * DAY), completed_at=iso(BASE + 8 * DAY)))
        later = self.pilot(BASE + 16 * DAY)
        later.poll()
        self.assertEqual(len(self.retro_wakes(later)), 2)

    def test_failed_run_keeps_the_identity_and_old_state_loads(self):
        (self.tmp / 'state/autopilot').mkdir(parents=True)
        (self.tmp / 'state/autopilot/state.json').write_text(json.dumps(dict(offset=0, wakes={})))
        pilot = self.pilot(BASE + 8 * DAY)
        pilot.poll()
        (self.tmp / 'state/retro/20261002T000000Z-aaaaaa').mkdir()
        (self.tmp / 'state/retro/20261002T000000Z-aaaaaa/state.json').write_text(json.dumps(dict(state='failed', failure='round failed: self')))
        pilot.poll(); pilot.poll()
        self.assertEqual(len(self.retro_wakes(pilot)), 1)
        self.assertNotIn('retro', json.dumps(sorted(set(pilot.data) - {'wakes'})))

    def test_external_autopilot_never_asks(self):
        self.ctx['external'] = True
        pilot = self.pilot(BASE + 30 * DAY)
        pilot.policy_error = None
        pilot.poll()
        self.assertEqual(self.retro_wakes(pilot), [])


class NamedTestResult(unittest.TextTestResult):
    """One line per test on standard output - ok, FAIL or SKIP with its name -
    so tests/retro.test.sh asserts each by name and a skip is never a pass."""

    def startTest(self, test):
        self._fm_state = 'ok'
        super().startTest(test)

    def addFailure(self, test, err):
        self._fm_state = 'FAIL'
        super().addFailure(test, err)

    def addError(self, test, err):
        self._fm_state = 'FAIL'
        super().addError(test, err)

    def addSubTest(self, test, subtest, err):
        if err is not None:
            self._fm_state = 'FAIL'
        super().addSubTest(test, subtest, err)

    def addSkip(self, test, reason):
        self._fm_state = 'SKIP'
        super().addSkip(test, reason)

    def stopTest(self, test):
        super().stopTest(test)
        sys.stdout.write('%s\t%s.%s\n' % (self._fm_state, type(test).__name__, test._testMethodName))
        sys.stdout.flush()


if __name__ == '__main__':
    suite = unittest.TestLoader().loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(stream=sys.stderr, verbosity=2, resultclass=NamedTestResult).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
