from herdr import *

class Entrypoints(EntrypointsFixture):
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

    def test_a_round_belongs_to_its_session_and_ends_with_it(self):
        # T-151: a round outlives the fm-worker.sh that launched it on purpose,
        # so it names the longer-lived owner it belongs to - the session - and
        # holds a lifeline to it. The launcher killed outright leaves the round
        # running; the session ending ends it, adapter and model included.
        for name in ('release-model','model.pid'):
            (self.repo/name).unlink(missing_ok=True)
        session=subprocess.Popen(['sleep','300'])
        self.addCleanup(lambda: session.poll() is None and (session.kill(), session.wait()))
        env=dict(self.env,FM_TEST_ASYNC='1',FM_HERDR_TIMEOUT=str(WAIT),HERDR_ENV='0',FM_SESSION_PID=str(session.pid))
        with tempfile.TemporaryFile(mode='w+') as output:
            launcher=subprocess.Popen(['bash',str(self.repo/'bin/fm-worker.sh'),'--task','T-035'],
                env=env,stdout=output,stderr=output,start_new_session=True)
            try:
                self.wait_for(lambda:(self.repo/'model.pid').exists())
                model=int((self.repo/'model.pid').read_text())
                actor=(self.repo/'state/worktrees/T-035/surviving-work').read_text()
                runner=int(next((self.repo/'state/runs'/actor).glob('*/runner.pid')).read_text())
                self.assertEqual(runner,os.getpgid(runner),'the round is still a process group of its own')
                os.killpg(launcher.pid,signal.SIGKILL); launcher.wait(timeout=WAIT)
                time.sleep(.5)
                os.kill(runner,0); os.kill(model,0)  # the launcher's death takes nothing
                session.kill(); session.wait()
                self.wait_for(lambda:not m.process_matches(dict(pid=runner,token='fm-herdr.py')))
                self.wait_for(lambda:not m.process_matches(dict(pid=model,token=str(self.fake/'codex'))))
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

    def test_autoclose_optout(self):
        # Completion/refusal variants are unit-tested by test_rc_zero_is_not_completion.
        answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'],FM_AUTOCLOSE='0')
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

unittest.main(argv=['herdr', *os.environ.get('FM_TEST_CASES','').split()], verbosity=2)
