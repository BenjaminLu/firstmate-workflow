"""Port of PR synchronization: actual REST command and event-writer boundaries."""
import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

os.environ['HERDR_ENV'] = '0'
sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_autopilot as A


def pull(number, branch, title, state='open', merged=None):
    return dict(number=number, head=dict(ref=branch, sha='a'*40), title=title,
                state=state, merged_at=merged, base=dict(ref='main', sha='b'*40))


class SyncTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.engine = self.root / 'engine'; self.engine.mkdir()
        self.home = self.root / 'home'
        (self.engine / 'config.yaml').write_text('default_project: firstmate-workflow\nprojects:\n'
            '  firstmate-workflow:\n    repo: .\n    github: owner/engine\n    base: main\n    required_check: ci\n'
            '  example-app:\n    github: owner/app\n    base: main\n    required_check: ci\n')
        gh = self.root / 'gh'
        gh.write_text('''#!/usr/bin/env python3
import json, pathlib, sys
from urllib.parse import parse_qs
root = pathlib.Path(__file__).resolve().parent
args = sys.argv[1:]
with (root/'calls').open('a') as out: out.write(json.dumps(args)+'\\n')
assert args[0] == 'api' and '--include' in args, args
repository, endpoint = args[1][6:].split('/', 2)[1:]
value = json.loads((root/(repository+'.json')).read_text())
if value == 'offline': print('unavailable', file=sys.stderr); sys.exit(1)
print('HTTP/2.0 200 OK\\nETag: "fixture"\\n')
if value == 'junk': print('not json'); sys.exit(0)
if endpoint.startswith('pulls?'):
    query = parse_qs(endpoint.split('?', 1)[1])
    rows = [p for p in value if query.get('state', ['all'])[0] in ('all', p['state'])]
    rows.sort(key=lambda p: p.get('updated_at', ''), reverse=True)
    size, page = int(query.get('per_page', ['30'])[0]), int(query.get('page', ['1'])[0])
    answer = rows[(page-1)*size:page*size]
elif endpoint.startswith('pulls/'):
    bits = endpoint.split('/')
    answer = next(p for p in value if str(p['number']) == bits[1]) if len(bits) == 2 else []
elif 'check-runs' in endpoint: answer = dict(total_count=0, check_runs=[])
elif '/status' in endpoint: answer = dict(sha='a'*40, total_count=0, statuses=[])
else: raise ValueError(endpoint)
print(json.dumps(answer))
''')
        gh.chmod(0o755)
        env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        env.update(FM_HOME=str(self.home), FM_ROOT=str(self.engine), FM_GH=str(gh), HERDR_ENV='0')
        environment = patch.dict(os.environ, env, clear=True); environment.start(); self.addCleanup(environment.stop)

    def pilot(self, project='firstmate-workflow'):
        state = self.engine / 'state' if project == 'firstmate-workflow' else self.home / 'projects' / project / 'state'
        state.mkdir(parents=True, exist_ok=True)
        pilot = A.Pilot(dict(engine=str(self.engine), state=str(state), target=str(self.engine),
            tasks=str(self.engine / 'tasks'), project=project, evidence_project=project,
            external=False, repository='owner/' + ('engine' if project == 'firstmate-workflow' else 'app'), base='main'),
            clock=lambda: 1700000000)
        # These event-only fixtures have no committed task spec or authorized pin.
        def missing_spec(pr, task):
            raise ValueError('committed task spec unavailable at PR head')
        pilot.read_head_spec = missing_spec
        return pilot

    def response(self, value, repo='engine'):
        (self.root / (repo + '.json')).write_text(json.dumps(value))

    def events(self, pilot):
        path = pilot.state / 'events.jsonl'
        return [json.loads(l) for l in path.read_text().splitlines()] if path.exists() else []

    def test_open_merge_close_logged_once_with_fields_and_actor(self):
        p = self.pilot()
        p.data['pulls']['8'] = {}
        p.data['pulls']['10'] = {}
        self.response([pull(10,'t-010-end','T-010: end','closed'), pull(8,'t-005-worker','T-005: worker','closed','now'), pull(9,'t-006-review','T-006: reviewer')])
        p.poll(); p.poll()
        rows = self.events(p)
        self.assertEqual([(r['type'], r['task'], r['pr']) for r in rows], [('pr_opened','T-006',9),('closed','T-010',10),('merged','T-005',8)])
        self.assertTrue(all(r['actor'] == 'github' and r['summary']['en'] and r['summary']['zh-TW'] for r in rows))
        self.response([pull(9,'t-006-review','T-006: reviewer','closed','now'), pull(10,'t-010-end','T-010: end','closed')])
        p.poll(); p.poll()
        self.assertEqual(sum(r['type']=='merged' and r['pr']==9 for r in self.events(p)), 1)
        self.assertEqual(sum(r['type']=='closed' and r['pr']==10 for r in self.events(p)), 1)
        self.pilot().poll()
        self.assertEqual(len(self.events(p)), 4, 'restart must not replay a terminal or open event')

    def test_terminal_event_retries_finish_without_restarting_series(self):
        p = self.pilot()
        pr = pull(12, 't-001-work', 'T-001: work', 'closed', '2099-01-01T00:00:00Z')
        p.data['pulls']['12'] = dict(task='T-001', head='a'*40,
            merge_evidence=dict(head='a'*40, approved=True, green=True))
        self.response([pr])
        attempts = []
        error = 'fm-emit: timed out waiting for the event log lock'
        def fail(*args, **kwargs):
            attempts.append(p.data['poll_seq'])
            raise RuntimeError(error)
        p.emit = fail
        token = 'event-merged:12:' + 'a'*40
        for offset in range(8):
            p.poll()
            self.assertTrue(p.data['pulls']['12']['terminal'])
            self.assertEqual(A.merge_authorization.inventory(p)[1], [])
            if offset < 3:
                self.assertEqual(p.data['pulls']['12']['event_pending'], 'merged')
                self.assertEqual(p.data['retries'][token]['count'], 1 if offset == 0 else 2)
            else:
                self.assertNotIn('event_pending', p.data['pulls']['12'])
                self.assertEqual(p.data['retries'], {})
        self.assertEqual(attempts, [1, 2, 4])
        self.assertEqual(len(p.data['wakes']), 1)
        self.assertIn('T-001 #12 event-merged failed after 3 attempts: ' + error, str(p.data['wakes']))
        self.assertEqual(p.data['actions'], {})

    def test_failed_terminal_event_never_leaves_pr_in_merge_ready_inventory(self):
        p = self.pilot()
        pr = pull(12, 't-001-work', 'T-001: work', 'closed', '2099-01-01T00:00:00Z')
        p.data['pulls']['12'] = dict(task='T-001', head='a'*40,
            merge_evidence=dict(head='a'*40, approved=True, green=True))
        self.assertEqual(A.merge_authorization.inventory(p)[1], ['T-001 #12'])
        def fail(*args, **kwargs):
            raise RuntimeError('fm-emit: timed out waiting for the event log lock')
        p.emit = fail
        self.response([pr])
        for _ in range(5):
            p.poll()
            self.assertTrue(p.data['pulls']['12']['terminal'])
            self.assertEqual(A.merge_authorization.inventory(p)[1], [])

    def test_pending_event_retries_after_leaving_recent_list_then_succeeds(self):
        for seen_open in (False, True):
            with self.subTest(seen_open=seen_open):
                p = self.pilot('example-app' if seen_open else 'firstmate-workflow')
                pr = pull(12, 't-001-work', 'T-001: work', 'closed', '2099-01-01T00:00:00Z')
                if seen_open: p.data['pulls']['12'] = dict(head='a'*40)
                recent, fetched, attempts = [pr], [], []
                def api(endpoint):
                    if endpoint.startswith('pulls?state=open'): return []
                    if endpoint.startswith('pulls?state=closed'): return list(recent)
                    if endpoint == 'pulls/12':
                        fetched.append(p.data['poll_seq']); return pr
                    raise AssertionError(endpoint)
                p.api = api
                emit = p.emit
                def flaky(*args, **kwargs):
                    attempts.append(p.data['poll_seq'])
                    if len(attempts) < 3:
                        raise RuntimeError('fm-emit: timed out waiting for the event log lock')
                    return emit(*args, **kwargs)
                p.emit = flaky
                p.poll()
                self.assertTrue(p.data['pulls']['12']['terminal'])
                self.assertEqual(p.data['pulls']['12']['event_pending'], 'merged')
                recent.clear()
                for _ in range(5): p.poll()
                self.assertEqual(attempts, [1, 2, 4])
                self.assertIn(2, fetched); self.assertIn(4, fetched)
                self.assertEqual([r['type'] for r in self.events(p)], ['merged'])
                self.assertNotIn('event_pending', p.data['pulls']['12'])
                self.assertEqual(p.data['retries'], {})
                self.assertEqual(p.data['actions'], {})
                self.assertEqual(p.data['wakes'], {})

    def test_failed_open_event_is_pruned_when_pr_merges(self):
        p = self.pilot()
        pr = pull(12, 't-001-work', 'T-001: work')
        emit = p.emit
        def fail(*args, **kwargs):
            raise RuntimeError('fm-emit: timed out waiting for the event log lock')
        p.emit = fail
        self.response([pr]); p.poll()
        self.assertIn('event-pr_opened:12:' + 'a'*40, p.data['retries'])
        pr.update(state='closed', merged_at='2099-01-01T00:00:00Z')
        p.emit = emit
        self.response([pr]); p.poll()
        self.assertEqual([r['type'] for r in self.events(p)], ['merged'])
        self.assertTrue(p.data['pulls']['12']['terminal'])
        self.assertEqual(p.data['retries'], {})

    def test_same_poll_recent_and_detail_closure_writes_one_row(self):
        p = self.pilot()
        opened = pull(12, 't-001-work', 'T-001: work')
        closed = dict(opened, state='closed', merged_at='2099-01-01T00:00:00Z')
        def api(endpoint):
            if endpoint.startswith('pulls?state=open'): return [opened]
            if endpoint.startswith('pulls?state=closed'): return [closed]
            if endpoint == 'pulls/12': return closed
            raise AssertionError(endpoint)
        p.api = api
        p.poll()
        self.assertEqual([r['type'] for r in self.events(p)], ['pr_opened', 'merged'])

    def test_migration_repairs_missing_terminal_event_on_next_poll(self):
        for existing in (False, True):
            with self.subTest(existing=existing):
                project = 'example-app' if existing else 'firstmate-workflow'
                p = self.pilot(project)
                pr = pull(12, 't-001-work', 'T-001: work', 'closed', 'now')
                p.data['pulls']['12'] = dict(terminal=True, head='a'*40)
                token = A.key(['pr-event', 12, 'merged'])
                p.data['actions'][token] = dict(identity=['pr-event', 12, 'merged'],
                                               state='uncertain', task='T-001')
                p.queue('action-' + token, 'T-001', 'legacy', '舊步驟')
                p.data.pop('migrated_t200', None)
                if existing: p.emit('merged', 'T-001', 'merged', '已合併', 12, actor='github')
                p.save(); p = self.pilot(project)
                self.assertEqual(p.data['pulls']['12']['event_pending'], 'merged')
                self.assertNotIn(token, p.data['actions'])
                self.assertEqual(p.data['wakes'], {})
                p.api = lambda endpoint: pr if endpoint == 'pulls/12' else []
                p.poll(); p.poll()
                self.assertEqual(len(self.events(p)), 1)
                self.assertNotIn('event_pending', p.data['pulls']['12'])
                self.assertEqual(p.data['retries'], {})

    def test_failure_or_invalid_response_writes_no_event(self):
        p = self.pilot()
        for value in ('offline', 'junk'):
            self.response(value); p.poll()
            self.assertGreater(p.data['failures'], 0)
            self.assertEqual(self.events(p), [])

    def test_project_pair_keys_and_legacy_default_event(self):
        first, other = self.pilot(), self.pilot('example-app')
        (first.state / 'events.jsonl').write_text('{"type":"pr_opened","task":"T-004","pr":7}\n')
        self.response([pull(7,'t-004-engine','T-004: engine')])
        self.response([pull(7,'t-004-app','T-004: app','closed','now')], 'app')
        other.data['pulls']['7'] = {}
        first.poll(); other.poll()
        self.assertEqual(len(self.events(first)), 1)
        self.assertEqual(self.events(other)[0]['project'], 'example-app')
        self.assertEqual(self.events(other)[0]['pr'], 7)
        self.response([pull(7,'t-004-app','T-004: app')], 'app')
        other.poll(); other.poll()
        self.assertEqual([r['type'] for r in self.events(other)], ['merged','pr_opened'])
        self.response('offline')
        self.response([pull(7,'t-004-app','T-004: app'), pull(10,'t-010-app','T-010: selected')], 'app')
        first.poll(); other.poll()
        self.assertTrue(any(r['pr']==10 for r in self.events(other)))
        self.assertFalse(any(r['pr']==10 for r in self.events(first)))
        (self.root / 'calls').write_text('')
        other.poll()
        calls = (self.root / 'calls').read_text()
        self.assertIn('repos/owner/app/', calls)
        self.assertNotIn('repos/owner/engine/', calls, 'selected supervisor reads only its repository')

    def test_shared_grammar_branch_title_revert_long_number_and_legacy(self):
        p = self.pilot()
        p.data['pulls']['94'] = {}
        self.response([pull(94,'sk-001-skill-update-firstmate','SK-001: update','closed','now'),
            pull(95,'board-fields','T-116: board'), pull(96,'t-105-revert','T-105: revert'),
            pull(98,'revert-90-t-105','Revert "T-105: sandbox"'), pull(99,'t-1170-other','T-1170: longer'),
            pull(100,'t004-old','other')])
        p.poll()
        self.assertEqual({r['pr']:r.get('task') for r in self.events(p)},
                         {94:'SK-001',95:'T-116',96:'T-105',98:None,99:'T-1170',100:'T-004'})

    def test_first_start_ignores_history_and_reads_log_once(self):
        p = self.pilot()
        tasks = Path(p.ctx['tasks']); tasks.mkdir()
        (tasks / 'T-001.json').write_text('{"id":"T-001"}')
        history = [dict(pull(n, 't-001-old', 'T-001: old', 'closed',
                            '2000-01-01T00:00:00Z' if n % 2 else None),
                        closed_at='2000-01-01T00:00:00Z', updated_at='2099-01-01T00:00:00Z')
                   for n in range(1, 301)]
        self.response(history)
        with patch.object(p, 'rows', wraps=p.rows) as rows:
            p.poll()
        self.assertEqual(p.data['wakes'], {}, 'historical closures must never wake firstmate')
        self.assertEqual(self.events(p), [], 'first start must not replay closed or merged history')
        self.assertEqual(p.data['pulls'], {})
        self.assertEqual(rows.call_count, 1, 'read the event log once per poll')
        calls = [json.loads(line)[1] for line in (self.root / 'calls').read_text().splitlines()]
        self.assertEqual(len(calls), 2, 'one open page and one bounded recent-closure page')
        self.assertFalse(any('state=all' in endpoint for endpoint in calls))
        self.assertTrue(any('state=closed&sort=updated&direction=desc&per_page=50' in endpoint for endpoint in calls))
        self.pilot().poll()
        self.assertEqual(self.events(p), [])

    def test_many_observed_prs_read_event_log_once(self):
        p = self.pilot()
        self.response([pull(n, 't-001-work', 'T-001: work') for n in range(1, 13)])
        log = p.state / 'events.jsonl'
        log.write_text('')
        reads = []
        read_text = Path.read_text
        def read(path, *args, **kwargs):
            if path == log: reads.append(path)
            return read_text(path, *args, **kwargs)
        with patch.object(Path, 'read_text', read):
            p.poll()
        self.assertEqual(len(reads), 1, 'PR observation must share one poll event snapshot')
        self.assertEqual(len(self.events(p)), 12)

    def test_post_start_closure_and_tracked_pr_beyond_recent_page(self):
        p = self.pilot()
        self.response([pull(400, 't-001-new', 'T-001: new')])
        p.poll()
        history = [dict(pull(n, 't-001-old', 'T-001: old', 'closed'),
                        closed_at='2000-01-01T00:00:00Z', updated_at='2099-01-01T00:00:00Z')
                   for n in range(1, 61)]
        tracked = dict(pull(400, 't-001-new', 'T-001: new', 'closed'), closed_at='2000-01-01T00:00:00Z')
        fresh = dict(pull(401, 't-001-new', 'T-001: quick', 'closed', '2099-01-02T00:00:00Z'),
                     closed_at='2099-01-02T00:00:00Z', updated_at='2099-01-02T00:00:00Z')
        self.response(history + [tracked, fresh])
        p.poll(); self.pilot().poll()
        self.assertEqual([(r['pr'], r['type']) for r in self.events(p)],
                         [(400, 'pr_opened'), (401, 'merged'), (400, 'closed')])

    def test_no_registry_records_no_project(self):
        (self.engine / 'config.yaml').write_text('vendor: mock\n')
        p = self.pilot(); p.ctx['project'] = ''
        self.response([pull(3,'t-003-old','T-003: old')])
        p.poll()
        self.assertEqual(self.events(p)[0]['task'], 'T-003')
        self.assertNotIn('project', self.events(p)[0])


if __name__ == '__main__': unittest.main()
