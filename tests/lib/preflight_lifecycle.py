"""Preflight identity, loss and neutral-consumer regressions (T-191)."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

os.environ['HERDR_ENV'] = '0'
sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_autopilot as A
import fm_watch as W
import fm_lifeline as life
import fm_merge_authorization as M
from fm_evidence import Store
import fm_spec_preflight as P
spec = importlib.util.spec_from_file_location('herdr', ROOT / 'bin/fm-herdr.py')
H = importlib.util.module_from_spec(spec)
spec.loader.exec_module(H)


class PreflightLifecycle(unittest.TestCase):
    def setUp(self):
        clean = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        clean['HERDR_ENV'] = '0'
        env = patch.dict(os.environ, clean, clear=True)
        env.start(); self.addCleanup(env.stop)
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        shutil.copytree(ROOT / 'bin', self.root / 'bin')
        shutil.copytree(ROOT / 'i18n', self.root / 'i18n')
        self.state = self.root / 'state'; self.state.mkdir()
        self.tasks = self.root / 'design/tasks'; self.tasks.mkdir(parents=True)
        (self.tasks / 'T-191.json').write_text(json.dumps(dict(id='T-191',title='fixture',depends_on=[])))
        (self.root / 'config.yaml').write_text('vendor: mock\nrosters:\n  workers: [aya]\n  reviewers: [nikhil, imani, zain]\n')
        os.environ['FM_ROOT'] = str(self.root)
        self.ctx = dict(engine=str(self.root),state=str(self.state),target=str(self.root),
                        project='self',repository='org/repo',base='main',evidence_project='self',
                        external=False,tasks=str(self.tasks))

    def rows(self):
        return [json.loads(line) for line in (self.state / 'events.jsonl').read_text().splitlines()]

    def emit(self, actor, kind, data):
        subprocess.run(['bash',str(self.root / 'bin/fm-emit.sh'),'--actor',actor,'--task','T-191',
                        '--type',kind,'--data',json.dumps(data),'--en','Fixture event','--tw','測試事件'],
                       check=True,capture_output=True)

    def allocate(self, preflight, alias):
        with patch.dict(os.environ, FM_SPEC_PREFLIGHT_MODE='1' if preflight else '0'):
            run = H.allocate(self.root, 'reviewer', 'T-191', alias)
        return run, json.loads((run / 'identity.json').read_text())

    def killed_process(self, run):
        # A real owned process dies without a launcher EXIT event. The keeper
        # reaps it; no background child survives this test, including failures.
        child = life.start([sys.executable, '-c',
            'import os,signal,sys; print("ready",flush=True); sys.stdin.readline(); os.kill(os.getpid(),signal.SIGKILL)'],
            owner=os.getpid(), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(), 'ready')
            (run / 'process.json').write_text(json.dumps(dict(pid=child.pid,token='fm_lifeline.py')))
            self.assertTrue(H.actor_is_live(self.root,run.name))
            child.communicate('die\n',timeout=15)
        finally:
            if child.poll() is None:
                child.terminate(); child.wait(timeout=15)
            for stream in (child.stdin,child.stdout,child.stderr):
                if stream and not stream.closed: stream.close()

    def test_warning_and_death_carry_mode_but_never_wake(self):
        run, who = self.allocate(True, 'nikhil')
        actor = who['actor']
        self.emit(actor, 'crew_status',dict(role='reviewer',phase='review',mode='spec-preflight',identity=who))
        self.assertIn(actor, W.inflight(self.root)[0])
        H.emit_status(self.root, actor, 'T-191', 'Sandbox warning', '沙箱警告',role='reviewer')
        self.assertEqual(self.rows()[-1]['data']['mode'], 'spec-preflight')
        self.killed_process(run)
        H.retire_dead_crew(self.root)
        endings = self.rows()[-2:]
        self.assertEqual([e['type'] for e in endings], ['agent_lost','agent_finished'])
        self.assertTrue(all(e['data'].get('mode') == 'spec-preflight' for e in endings))
        self.assertNotIn(actor, W.inflight(self.root)[0])
        wake = self.state / 'session/wake.jsonl'
        self.assertFalse(wake.exists() and 'lost:' in wake.read_text())
        # Restart after the first events were consumed: classify from full history.
        pilot = A.Pilot(self.ctx)
        for n,e in enumerate(endings): pilot.event(e, str(n))
        self.assertEqual(pilot.data['wakes'], {})
        self.assertEqual(H.review_round(self.root,'T-191',None), 1)
        self.assertEqual(M.inventory(pilot), ([],[],[]))
        self.assertEqual(Store(self.state,'self','T-191').verdicts(), [])
        # fm-review.sh --name passes this alias through fm_identity to
        # H.allocate; aliases need not be letters-only roster entries.
        review, identity = self.allocate(False, 'zain-sp')
        self.assertEqual(identity['requested_alias'], 'zain-sp')
        self.assertEqual(identity['actor'], 'reviewer-zain-sp-t191-r1')
        self.assertNotIn('mode', identity)
        self.assertEqual((identity['round'], identity['attempt']), (1,1))
        ordinary = identity['actor']
        self.emit(ordinary,'review_opened',dict(role='reviewer',identity=identity))
        self.killed_process(review)
        H.retire_dead_crew(self.root)
        self.assertIn('lost: T-191 ' + ordinary, wake.read_text())
        for n,e in enumerate(self.rows()[-2:]): pilot.event(e, 'ordinary-'+str(n))
        self.assertTrue(any('Round lost' in w['line'] for w in pilot.data['wakes'].values()))
        self.assertNotIn('mode', self.rows()[-2]['data'])

    def test_neutral_events_leave_all_review_consumers_unchanged(self):
        run, who = self.allocate(True,'imani')
        actor = who['actor']
        store = Store(self.state,'self','T-191')
        data = (self.tasks / 'T-191.json').read_bytes()
        P.retain(store,data,'a'*40,actor,1,'1. Checked.\nSPEC-OK:T-191',dict(level='legacy'))
        self.emit(actor,'crew_status',dict(role='reviewer',mode='spec-preflight'))
        pilot = A.Pilot(self.ctx)
        self.assertEqual(M.inventory(pilot),([],[],[]), 'preflight is not an implementation review in merge reminders')
        self.assertEqual(store.verdicts(),[], 'gate 6 has no implementation verdict from a preflight receipt')
        self.assertEqual(pilot.verdict('T-191'),{})
        self.emit(actor,'agent_finished',dict(role='reviewer',mode='spec-preflight',result='ok'))
        calls=[]
        pilot.task=lambda pr: 'T-191'
        pilot.authoritative_head=lambda task,pr: pr['head']['sha']
        pilot.base_tip=lambda: 'b'*40
        pilot.settled_checks=lambda *args: [('ci','check',1,'success')]
        pilot.start_job=lambda kind,task,pr,argv,**extra: calls.append((kind,extra['round']))
        pr=dict(number=1,state='open',head=dict(sha='a'*40,ref='t-191-fixture'),base=dict(sha='b'*40,ref='main'))
        pilot.advance(pr,[],[])
        self.assertEqual(calls,[('gate',1)], 'autopilot schedules the first real review as round one')
        self.assertEqual(H.review_round(self.root,'T-191',None),1)
        self.assertEqual(M.inventory(pilot)[2],[])
        for kind in ('crew_status','agent_finished','agent_lost'):
            result = subprocess.run(['bash',str(self.root/'bin/fm-diagram.sh'),'--event',kind],capture_output=True)
            self.assertEqual(result.returncode,0,kind+' is a routine diagram event')

    def test_outcome_matches_actor_and_exact_spec_before_exit_status(self):
        store=Store(self.state,'self','T-191')
        data=(self.tasks/'T-191.json').read_bytes()
        sha=hashlib.sha256(data).hexdigest()
        P.retain(store,data,'a'*40,'preflight-a',1,'1. Checked.\nSPEC-GAPS:T-191',dict(level='legacy'))
        self.assertEqual(P.outcome(store,'preflight-a',sha,65,1),'spec-gaps')
        self.assertEqual(P.outcome(store,'preflight-a',sha,143,1),'spec-gaps')
        self.assertEqual(P.outcome(store,'other',sha,65,1),'failed')
        self.assertEqual(P.outcome(store,'preflight-a','b'*64,65,1),'failed')
        for rc in (129,130,143):
            self.assertEqual(P.outcome(store,'other',sha,rc,0),'interrupted')
        self.assertEqual(P.outcome(store,'other',sha,65,0),'refused')

    def test_untagged_failure_of_known_preflight_is_neutral(self):
        _, who = self.allocate(True,'imani')
        actor=who['actor']
        self.emit(actor,'crew_status',dict(role='reviewer',mode='spec-preflight'))
        before=subprocess.check_output(['bash',str(self.root / 'bin/fm-ready.sh'),'list'],text=True)
        for outcome in ('refused','failed','interrupted','spec-gaps','spec-ok'):
            self.emit(actor,'agent_finished',dict(role='reviewer',preflight_outcome=outcome,result='failed'))
            pilot=A.Pilot(self.ctx)
            pilot.event(self.rows()[-1],outcome)
            self.assertEqual(pilot.data['wakes'], {})
        self.assertNotIn(actor,W.inflight(self.root)[0])
        after=subprocess.check_output(['bash',str(self.root / 'bin/fm-ready.sh'),'list'],text=True)
        self.assertEqual(before,after)
        self.assertEqual(H.review_round(self.root,'T-191',None),1)


if __name__ == '__main__': unittest.main()
