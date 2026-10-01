from herdr import *

class Entrypoints(EntrypointsFixture):
    def test_running_adapter_uses_snapshot_after_source_edit(self):
        self.executable('codex',r'''
import json,os,pathlib,sys
r=pathlib.Path(os.environ['FM_TEST_ROOT'])
(r/'bin/adapters/codex.sh').write_text('#!/usr/bin/env bash\nexit 99\n')
for event in [dict(type='turn.started'),
              dict(type='item.completed',item=dict(id='0',type='agent_message',text='APPROVE:T-035\nREVIEWER_COMPLETE:T-035')),
              dict(type='turn.completed',usage={})]:
 print(json.dumps(event))
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

unittest.main(argv=['herdr', *os.environ.get('FM_TEST_CASES','').split()], verbosity=2)
