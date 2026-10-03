from herdr import *

class Entrypoints(EntrypointsFixture):
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
                 ('fm-dispatch.sh',['--dry-run']),('fm-autopilot.sh',['context'])]
        (self.repo/'bin/fm-gate.sh').write_text('#!/usr/bin/env bash\nexit 1\n')
        for script,args in entries:
            # Exercise every wrapper's two root inputs; relative script resolution
            # is shared, so exercise its combinations through session once.
            sources=('repo-argument','environment')
            if script=='fm-session.sh':
                sources+=('relative-script-argument','relative-script-environment')
            for source in sources:
                with self.subTest(script=script,source=source):
                    env=dict(self.env,FM_TRANSPORT='direct',FM_ROOT=self.repo.name,FM_AUTOPILOT_TEST_ENABLE='1')
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

unittest.main(argv=['herdr', *os.environ.get('FM_TEST_CASES','').split()], verbosity=2)
