"""Head-only task discovery and evidence freshness at real git/gh boundaries."""
import copy
import datetime
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
from fm_evidence import Store

HEAD, BASE = 'a' * 40, 'b' * 40
PR = dict(number=168, title='T-179: new task', state='open', draft=False,
          head=dict(ref='t-179-new-task', sha=HEAD), base=dict(ref='main', sha=BASE))


class TaskResolution(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.ctx = dict(engine=str(self.root), target=str(self.root), state=str(self.root / 'state'),
                        tasks=str(self.root / 'design/tasks'), project='firstmate-workflow',
                        evidence_project='firstmate-workflow', external=False, repository='owner/repo', base='main')
        stub = self.root / 'git'
        stub.write_text('''#!/usr/bin/env python3
import json, pathlib, sys
root = pathlib.Path(__file__).resolve().parent
args = sys.argv[1:]
with (root / 'git-calls').open('a') as out: out.write(json.dumps(args) + '\\n')
assert args[:2] == ['-C', str(root)], args
if args[2] == 'show':
    assert args[3] == 'a'*40 + ':design/tasks/T-179.json', args
    path = root / 'head-spec'
    if not path.exists(): sys.exit(128)
    print(path.read_text())
elif args[2] == 'cat-file': sys.exit(1 if (root / 'missing-object').exists() else 0)
elif args[2] == 'fetch':
    assert args[3:5] == ['--no-tags', 'https://github.com/owner/repo.git'], args
    assert args[5].startswith('+refs/pull/168/head:refs/fm/fetch/'), args
    (root / 'missing-object').unlink(missing_ok=True)
elif args[2] == 'update-ref':
    assert args[3] == '-d' and args[4].startswith('refs/fm/fetch/'), args
elif args[2] == 'rev-parse':
    print(('c' if (root / 'moved-head').exists() else 'a')*40 if args[3].startswith('refs/fm/fetch/') else 'b'*40)
else: raise AssertionError(args)
''')
        stub.chmod(0o755)
        gh = self.root / 'gh'
        gh.write_text('''#!/usr/bin/env python3
import json, sys
assert sys.argv[1:] == ['api', 'repos/owner/repo/branches/main/protection/required_status_checks', '--include'], sys.argv
print('HTTP/2.0 200 OK\\n\\n' + json.dumps(dict(contexts=['ci'], checks=[])))
''')
        gh.chmod(0o755)
        env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        env.update(PATH=str(self.root) + os.pathsep + os.environ['PATH'], FM_GH=str(gh), HERDR_ENV='0')
        p = patch.dict(os.environ, env, clear=True); p.start(); self.addCleanup(p.stop)
        (self.root / 'head-spec').write_text('{"id":"T-179"}')
        self.jobs = []
        self.pilot = self.start(1000)
        self.store = Store(self.ctx['state'], 'firstmate-workflow', 'T-179', external=False)

    def start(self, now):
        pilot = A.Pilot(self.ctx, clock=lambda: now)
        pilot.authoritative_head = lambda task, pr: pr['head']['sha']
        pilot.start_job = lambda *a, **kw: self.jobs.append(a)
        return pilot

    def record(self, kind, timestamp, head=HEAD, **fields):
        stamp = datetime.datetime.fromtimestamp(timestamp, datetime.timezone.utc).isoformat()
        record = dict(project='firstmate-workflow', task='T-179', kind=kind, time=stamp,
                      actor='firstmate' if kind == 'brief' else 'worker', head=head, round=1,
                      text='ASK-SCOPE:T-179\nNeed scope', **fields)
        self.store.directory.mkdir(parents=True, exist_ok=True)
        n = len(list(self.store.directory.glob('*.json'))) + 1
        (self.store.directory / f'{n:08d}.json').write_text(json.dumps(record))

    def draft(self):
        pr = copy.deepcopy(PR); pr['draft'] = True
        self.pilot.advance(pr, [], [])

    def test_head_only_spec_gates_and_failed_ci_wakes_once(self):
        self.assertFalse(Path(self.ctx['tasks']).exists())
        checks = [dict(id=1, name='ci', head_sha=HEAD, status='completed', conclusion='failure')]
        self.pilot.pull(PR, [], [], checks, [])
        self.pilot.pull(PR, [], [], checks, [])
        self.assertEqual([j[0] for j in self.jobs], ['gate'], 'head-only task must reach gates')
        self.assertEqual(len(self.pilot.data['wakes']), 1, 'failed CI must wake once')
        self.assertEqual(self.pilot.data['pulls']['168']['task'], 'T-179')
        self.assertIn(HEAD + ':design/tasks/T-179.json', (self.root / 'git-calls').read_text())

    def test_missing_head_fetches_private_ref_and_checks_observed_sha(self):
        (self.root / 'missing-object').touch()
        self.assertEqual(self.pilot.task(PR), 'T-179')
        calls = [json.loads(line) for line in (self.root / 'git-calls').read_text().splitlines()]
        self.assertEqual([a[2] for a in calls], ['cat-file', 'fetch', 'rev-parse', 'update-ref', 'show'])
        (self.root / 'missing-object').touch()
        (self.root / 'moved-head').touch()
        self.assertEqual(self.pilot.task(PR), '')
        self.assertIn('head moved', self.pilot.data['pulls']['168']['reason'])

    def test_committed_spec_precedes_pin(self):
        from fm_spec_pins import Pins
        with patch.object(Pins, 'resolve', side_effect=AssertionError('head must resolve first')):
            self.assertEqual(self.pilot.task(PR), 'T-179')

    def test_boundary_and_missing_timestamp_do_not_wake(self):
        self.record('ask', 1000)
        self.draft()
        self.assertEqual(self.pilot.data['wakes'], {})
        path = next(self.store.directory.glob('*.json'))
        record = json.loads(path.read_text()); record.pop('time')
        path.write_text(json.dumps(record))
        self.draft()
        self.assertEqual(self.pilot.data['wakes'], {})

    def test_restart_ignores_old_ask_on_draft_and_new_ask_wakes_once(self):
        self.record('ask', 999)
        self.pilot = self.start(1100)
        self.draft()
        self.assertEqual(self.pilot.data['wakes'], {}, 'old draft ASK must not replay')
        self.record('ask', 1101)
        self.draft(); self.draft()
        self.assertEqual(len(self.pilot.data['wakes']), 1, 'new ASK must wake once')
        self.pilot = self.start(1200); self.draft()
        self.assertEqual(len(self.pilot.data['wakes']), 1)

    def test_later_brief_answers_ask_and_next_ask_same_head_wakes(self):
        self.record('ask', 1001); self.draft()
        self.record('brief', 1002, head=BASE, authorized=True)
        self.draft()
        self.assertEqual(len(self.pilot.data['wakes']), 1)
        self.record('ask', 1003); self.draft(); self.draft()
        self.assertEqual(len(self.pilot.data['wakes']), 2, 'distinct unanswered ASK needs its own wake')

    def test_answered_ask_and_wrong_head_never_wake(self):
        self.record('ask', 1001)
        self.record('brief', 1002, head=BASE, authorized=True)
        self.record('ask', 1003, head=BASE)
        self.draft()
        self.assertEqual(self.pilot.data['wakes'], {})

    def test_unresolvable_reason_persisted_once_and_retried(self):
        (self.root / 'head-spec').write_text('{"id":"T-999"}')
        self.pilot.pull(PR, [], [], [], [])
        before = copy.deepcopy(self.pilot.data['pulls'])
        self.pilot.pull(PR, [], [], [], [])
        self.assertEqual(self.pilot.data['pulls'], before)
        self.assertIn('reason', before['168'])
        self.assertEqual(self.pilot.data['wakes'], {})
        (self.root / 'head-spec').write_text('{"id":"T-179"}')
        self.assertEqual(self.pilot.task(PR), 'T-179')

    def test_local_event_tracks_new_task_without_checkout_spec(self):
        self.pilot.event(dict(type='pr_opened', project='firstmate-workflow', task='T-179', pr=168), 'open')
        self.assertEqual(self.pilot.data['pulls']['168']['task'], 'T-179')

    def test_latest_authorized_pin_is_fallback(self):
        from fm_spec_pins import Pins
        (self.root / 'head-spec').unlink()
        pin = dict(snapshots=dict(spec=dict(text='{"id":"T-179"}')))
        with patch.object(Pins, 'resolve', return_value=pin) as resolve:
            self.assertEqual(self.pilot.task(PR), 'T-179')
            resolve.assert_called_once_with(if_present=True)
        with patch.object(Pins, 'resolve', side_effect=ValueError('pin approval provenance mismatch')):
            self.assertEqual(self.pilot.task(PR), '')
        self.assertIn('pin approval', self.pilot.data['pulls']['168']['reason'])


if __name__ == '__main__': unittest.main()
