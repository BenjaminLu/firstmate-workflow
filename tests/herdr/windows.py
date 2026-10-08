from herdr import *
import contextlib
import io
import threading


class ProjectWorkspaces(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        self.clone = self.home/'demo/repo'; self.clone.mkdir(parents=True)
        self.logical = self.home/'round'; self.logical.mkdir()
        self.attempt = self.logical/'attempt'; self.attempt.mkdir()
        self.env = dict(FM_EXTERNAL='1', FM_PROJECT='demo', FM_TARGET_ROOT=str(self.clone))

    def open(self, control, env=None, attempt=None):
        with patch.dict(os.environ, dict(HERDR_PANE_ID='caller', FM_HERDR_SHELL_WAIT='0'), clear=True), \
                patch.object(m, 'Herdr', return_value=control):
            owner, _ = m.open_herdr_window(attempt or self.attempt, self.logical, self.clone,
                'worker-test', 'T-249', dict(self.env if env is None else env), 'follow')
        return owner

    def assert_target(self, control, target):
        owner = self.open(control)
        create = next(c for c in control.calls if c[:2] == ('tab', 'create'))
        self.assertEqual(target, create[create.index('--workspace')+1])
        self.assertEqual(target, owner['workspace_id'])
        self.assertEqual(target, json.loads((self.attempt/'owner.json').read_text())['workspace_id'])
        self.assertEqual(owner['focus_before'], owner['focus_after'])
        self.assertEqual([('pane', 'get', 'caller'), ('api', 'snapshot')], control.calls[:2])

    def test_external_round_reuses_hand_made_workspace(self):
        control = ProjectWorkspaceControl([workspace_row()])
        self.assert_target(control, 'w-demo')
        self.assertFalse(any(c[:2] == ('workspace', 'create') for c in control.calls))

    def test_external_round_creates_missing_workspace_without_focus(self):
        control = ProjectWorkspaceControl([workspace_row('other', 'w-other')])
        self.assert_target(control, 'w-demo')
        self.assertEqual([('workspace', 'create', '--cwd', str(self.clone.resolve()),
                          '--label', 'demo', '--no-focus')],
                         [c for c in control.calls if c[:2] == ('workspace', 'create')])
        self.assertTrue((self.clone.parent/'state/herdr-workspace.lock').is_file())

    def test_duplicate_labels_use_lowest_number(self):
        control = ProjectWorkspaceControl([workspace_row(number=5), workspace_row(workspace_id='older', number=3)])
        self.assert_target(control, 'older')
        self.assertFalse(any(c[:2] == ('workspace', 'create') for c in control.calls))

    def test_workspace_failure_falls_back_and_logs_reason(self):
        cases = [(ProjectWorkspaceControl(created_label='wrong'), 'label'),
                 (ProjectWorkspaceControl(failure=subprocess.TimeoutExpired('workspace list', 15)), 'timed out'),
                 (ProjectWorkspaceControl(rows=None), 'NoneType'),
                 (ProjectWorkspaceControl(rows=[None]), 'NoneType')]
        for control, reason in cases:
            with self.subTest(reason=reason):
                (self.logical/'pane.json').unlink(missing_ok=True)
                (self.attempt/'herdr.log').unlink(missing_ok=True)
                self.assert_target(control, 'workspace')
                lines = (self.attempt/'herdr.log').read_text().splitlines()
                self.assertEqual(1, len(lines))
                self.assertIn('project workspace unavailable:', lines[0])
                self.assertIn(reason, lines[0])

    def test_lock_failure_falls_back_without_workspace_calls(self):
        control = ProjectWorkspaceControl()
        with patch.object(m.fcntl, 'flock', side_effect=OSError('lock unavailable')):
            self.assert_target(control, 'workspace')
        self.assertFalse(any(c[0] == 'workspace' for c in control.calls))
        self.assertIn('lock unavailable', (self.attempt/'herdr.log').read_text())

    def test_self_or_incomplete_env_does_not_look_up_workspace(self):
        for env in ({}, dict(self.env, FM_EXTERNAL='0'), dict(self.env, FM_PROJECT=''),
                    dict(self.env, FM_TARGET_ROOT=''), dict(self.env, FM_TARGET_ROOT=str(self.home/'missing'))):
            with self.subTest(env=env):
                (self.logical/'pane.json').unlink(missing_ok=True)
                control = ProjectWorkspaceControl()
                self.assertEqual('workspace', self.open(control, env)['workspace_id'])
                self.assertFalse(any(c[0] == 'workspace' for c in control.calls))

    def test_recorded_project_pane_keeps_its_workspace(self):
        control = ProjectWorkspaceControl([workspace_row()])
        self.assertEqual('w-demo', self.open(control)['workspace_id'])
        control.calls.clear(); control.failure = RuntimeError('must not look up on reuse')
        attempt = self.logical/'second'; attempt.mkdir()
        self.assertEqual('w-demo', self.open(control, attempt=attempt)['workspace_id'])
        self.assertFalse(any(c[0] == 'workspace' or c[:2] == ('tab', 'create') for c in control.calls))

    def test_recorded_caller_pane_is_not_migrated_to_project_workspace(self):
        control = ProjectWorkspaceControl()
        self.assertEqual('workspace', self.open(control, env={})['workspace_id'])
        control.calls.clear(); control.failure = RuntimeError('must not look up on reuse')
        attempt = self.logical/'second'; attempt.mkdir()
        self.assertEqual('workspace', self.open(control, attempt=attempt)['workspace_id'])
        self.assertFalse(any(c[0] == 'workspace' or c[:2] == ('tab', 'create') for c in control.calls))

    def test_invalid_created_workspace_is_refused(self):
        for workspace in (None, {}, dict(label='demo', workspace_id=''),
                          dict(label='other', workspace_id='wrong')):
            with self.subTest(workspace=workspace):
                def control(*args):
                    if args == ('workspace', 'list'): return dict(workspaces=[])
                    return dict(workspace=workspace)
                with self.assertRaisesRegex(RuntimeError, 'workspace'):
                    m.project_workspace(control, 'demo', self.clone)

    def test_exclusive_project_lock_covers_list_and_create(self):
        control = ProjectWorkspaceControl()
        def locked_control(*args):
            with (self.clone.parent/'state/herdr-workspace.lock').open('a') as contender:
                with self.assertRaises(BlockingIOError):
                    m.fcntl.flock(contender, m.fcntl.LOCK_EX | m.fcntl.LOCK_NB)
            return control(*args)
        self.assertEqual('w-demo', m.project_workspace(locked_control, 'demo', self.clone))
        self.assertEqual([('workspace', 'list'), ('workspace', 'create')],
                         [c[:2] for c in control.calls])

    def test_concurrent_first_rounds_create_one_workspace(self):
        control = ProjectWorkspaceControl()
        barrier = threading.Barrier(2)
        def slow_control(*args):
            result = control(*args)
            if args == ('workspace', 'list'):
                time.sleep(.05)  # Yield after observing absence, before create.
            return result
        def lookup():
            barrier.wait(timeout=WAIT)
            return m.project_workspace(slow_control, 'demo', self.clone)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(lookup) for _ in range(2)]
            self.assertEqual(['w-demo', 'w-demo'], [f.result(timeout=WAIT) for f in futures])
        self.assertEqual(1, sum(c[:2] == ('workspace', 'create') for c in control.calls))

    def test_ensure_workspace_best_effort_and_temporary_logs(self):
        control = ProjectWorkspaceControl(); log_dirs = []
        def factory(directory):
            directory = Path(directory); log_dirs.append(directory)
            (directory/'herdr.log').write_text('temporary control log')
            return control
        def invoke():
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = m.main(['ensure-workspace', str(self.home), 'demo', str(self.clone)])
            self.assertEqual(0, code)
            return output.getvalue().strip()
        with patch.dict(os.environ, dict(FM_HOST='herdr', HERDR_PANE_ID='caller'), clear=True), \
                patch.object(m, 'Herdr', side_effect=factory):
            self.assertEqual('w-demo', invoke())
            self.assertEqual('w-demo', invoke())
            control.failure = RuntimeError('server unavailable')
            self.assertEqual('skip: server unavailable', invoke())
            # Even an exception outside the launch path's normal catch set is best effort.
            with patch.object(m, 'window_host', side_effect=Exception('host unavailable')):
                self.assertEqual('skip: host unavailable', invoke())
        self.assertEqual(1, sum(c[:2] == ('workspace', 'create') for c in control.calls))
        self.assertTrue(log_dirs)
        self.assertTrue(all(not p.exists() for p in log_dirs))
        self.assertFalse((self.home/'herdr.log').exists())
        self.assertFalse((self.clone/'herdr.log').exists())

    def test_ensure_workspace_cli_without_caller_skips(self):
        env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_', 'CMUX_', 'TMUX'))}
        env['FM_HOST'] = 'herdr'
        result = subprocess.run([sys.executable, str(root/'bin/fm-herdr.py'), 'ensure-workspace',
                                 str(self.home), 'demo', str(self.clone)], env=env,
                                cwd=self.clone, text=True, capture_output=True, timeout=15)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(result.stdout.startswith('skip:'), result.stdout)
        self.assertFalse((self.clone/'herdr.log').exists())

class CallerContext(unittest.TestCase):
    def test_complete_supplied_context_is_checked_before_creation_or_reuse(self):
        expected = dict(pane_id='caller', tab_id='caller-tab', workspace_id='workspace')
        context = dict(HERDR_PANE_ID='caller', HERDR_TAB_ID='caller-tab',
                       HERDR_WORKSPACE_ID='workspace')
        with tempfile.TemporaryDirectory() as tmp:
            logical = Path(tmp); attempt = logical/'attempt'; attempt.mkdir()
            for reuse in (False, True):
                if reuse: m.save(logical/'pane.json', {'pane_id':'old-owned'})
                for field in expected:
                    for bad in ('other', '', None):
                        with self.subTest(reuse=reuse, field=field, bad=bad):
                            observed = dict(expected, **{field:bad}); calls = []
                            def control(*args):
                                calls.append(args)
                                if args == ('pane', 'get', 'caller'): return dict(pane=observed)
                                raise AssertionError('caller validation must precede ' + repr(args))
                            with patch.dict(os.environ, context, clear=True), patch.object(m, 'Herdr', return_value=control):
                                with self.assertRaisesRegex(RuntimeError, 'caller'):
                                    m.open_herdr_window(attempt, logical, logical, 'worker-test', 'T-162', {}, 'follow')
                            self.assertEqual([('pane', 'get', 'caller')], calls)
    def test_matching_or_unspecified_membership_reaches_focus_read(self):
        # Legacy pane-only detection remains valid; supplied membership is never ignored.
        for extra in ({}, dict(HERDR_TAB_ID='caller-tab', HERDR_WORKSPACE_ID='workspace')):
            calls = []
            def control(*args):
                calls.append(args)
                if args == ('pane', 'get', 'caller'):
                    return dict(pane=dict(pane_id='caller', tab_id='caller-tab', workspace_id='workspace'))
                if args == ('api', 'snapshot'): raise RuntimeError('focus sentinel')
                raise AssertionError(args)
            with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, dict(HERDR_PANE_ID='caller', **extra), clear=True), patch.object(m, 'Herdr', return_value=control):
                with self.assertRaisesRegex(RuntimeError, 'focus sentinel'):
                    m.open_herdr_window(Path(tmp), Path(tmp), Path(tmp), 'worker-test', 'T-162', {}, 'follow')
            self.assertEqual([('pane', 'get', 'caller'), ('api', 'snapshot')], calls)

class Entrypoints(EntrypointsFixture):
    def test_project_sync_ensures_workspace_and_honors_opt_out(self):
        # Keep the existing fake Herdr first on PATH, but use real Git with a
        # local remote so this exercises sync's actual shell wiring.
        (self.fake/'git').unlink()
        storage = tempfile.TemporaryDirectory(); self.addCleanup(storage.cleanup)
        env = {k:v for k,v in self.env.items() if not k.startswith('GIT_')}
        env.update(FM_HOST='herdr', FM_HOME=storage.name,
                   FM_GITHUB_URL=str(self.repo/'remotes'),
                   GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)
        (self.repo/'.githooks').mkdir()
        (self.repo/'remotes/owner').mkdir(parents=True)
        (self.repo/'config.yaml').write_text(
            'projects:\n  demo:\n    github: owner/demo\n    base: main\n    required_check: ci\n')
        remote = self.repo/'remotes/owner/demo.git'
        seed = self.repo/'seed'
        for args in (['init', '-q', '-b', 'main', str(seed)],
                     ['-C', str(seed), '-c', 'core.hooksPath=/dev/null',
                      '-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid',
                      'commit', '-qm', 'base', '--allow-empty'],
                     ['clone', '-q', '--bare', str(seed), str(remote)]):
            result = subprocess.run(['git', *args], env=env, cwd=self.repo,
                                    capture_output=True, text=True, timeout=WAIT)
            self.assertEqual(0, result.returncode, result.stderr)
        command = [str(self.repo/'bin/fm-project.sh'), 'sync', 'demo', '--repo', str(self.repo)]
        without_herdr = dict(env, HERDR_ENV='0')
        without_herdr.pop('HERDR_PANE_ID')
        # Establish the clone and capture the normal repeat-sync result.
        for _ in range(2):
            baseline = subprocess.run(command, env=without_herdr, cwd=self.repo,
                                      capture_output=True, text=True, timeout=WAIT)
            self.assertEqual(0, baseline.returncode, baseline.stderr)
        controls = self.repo/'controls'
        self.assertFalse(controls.exists())
        disabled = subprocess.run(command, env=dict(env, FM_HERDR_WORKSPACE='0'),
                                  cwd=self.repo, capture_output=True, text=True, timeout=WAIT)
        self.assertEqual((baseline.returncode, baseline.stdout),
                         (disabled.returncode, disabled.stdout), disabled.stderr)
        # Gate 4: removing sync's != 0 guard makes this assertion fail.
        self.assertFalse(controls.exists(), 'disabled sync must make no Herdr call')
        clone = Path(storage.name)/'projects/demo/repo'
        for count in (1, 2):
            result = subprocess.run(command, env=env, cwd=self.repo,
                                    capture_output=True, text=True, timeout=WAIT)
            self.assertEqual((baseline.returncode, baseline.stdout),
                             (result.returncode, result.stdout), result.stderr)
            calls = [json.loads(line) for line in controls.read_text().splitlines()] if controls.exists() else []
            # Gate 4: removing the sync ensure step leaves no create call.
            self.assertEqual([['workspace', 'create', '--cwd', str(clone.resolve()),
                               '--label', 'demo', '--no-focus']],
                             [c for c in calls if c[:2] == ['workspace', 'create']])
            self.assertEqual(count, calls.count(['workspace', 'list']))
            self.assertEqual(1, len(list(self.repo.glob('ws-*'))))

    def test_external_prepare_disables_workspace_during_sync(self):
        code = self.repo/'recording-code/bin'; code.mkdir(parents=True)
        service = code/'fm-project.sh'
        service.write_text('#!/bin/sh\n'
                           'printf "%s:%s\\n" "$1" "${FM_HERDR_WORKSPACE-unset}" >> "$FM_TEST_CALLS"\n')
        service.chmod(0o755)
        calls = self.repo/'prepare-calls'
        result = subprocess.run(['bash', '-uc', '''
. "$1/bin/fm-config.sh"
fm_target_validate() { return 0; }
fm_external_prepare
''', 'prepare', str(self.repo)], cwd=self.repo,
            env=dict(self.env, FM_EXTERNAL='1', FM_PROJECT='demo',
                     FM_ENGINE_ROOT=str(self.repo), FM_CODE_ROOT=str(code.parent),
                     FM_TEST_CALLS=str(calls), FM_HERDR_WORKSPACE='1'),
            capture_output=True, text=True, timeout=WAIT)
        self.assertEqual(0, result.returncode, result.stderr)
        # Gate 4: removing the sync prefix records sync:1 instead of sync:0.
        self.assertEqual(['sync:0', 'verify:1'], calls.read_text().splitlines())

    def test_ensure_workspace_cli_creates_reuses_and_swallows_failure(self):
        clone = self.repo/'projects/demo/repo'; clone.mkdir(parents=True)
        command = [sys.executable, str(self.repo/'bin/fm-herdr.py'), 'ensure-workspace',
                   str(self.repo), 'demo', str(clone)]
        def invoke():
            result = subprocess.run(command, env=dict(self.env, FM_HOST='herdr'),
                                    cwd=self.fake, capture_output=True, text=True, timeout=15)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertFalse((self.repo/'herdr.log').exists())
            self.assertFalse((self.fake/'herdr.log').exists())
            self.assertFalse((clone/'herdr.log').exists())
            return result.stdout.strip()
        workspace = invoke()
        self.assertTrue(workspace.startswith('ws-'), workspace)
        self.assertEqual(workspace, invoke())
        calls = [json.loads(line) for line in (self.repo/'controls').read_text().splitlines()]
        self.assertEqual(1, sum(c[:2] == ['workspace', 'create'] for c in calls))
        (self.fake/'herdr').write_text('#!/bin/sh\nexit 1\n')
        self.assertTrue(invoke().startswith('skip:'))

    def test_verified_nested_herdr_ignores_outer_cmux_and_requires_no_password(self):
        # Explicit, independently verified context wins even without HERDR_ENV.
        # cmux must never be invoked for this deployment.
        (self.fake/'cmux').write_text('#!/bin/sh\necho unexpected-cmux >&2\nexit 99\n')
        (self.fake/'cmux').chmod(0o755)
        answer=self.invoke('fm-worker.sh',['--task','T-035'], FM_HOST='herdr',
                           HERDR_ENV='0', HERDR_PANE_ID='caller',
                           HERDR_TAB_ID='caller-tab', HERDR_WORKSPACE_ID='workspace',
                           CMUX_WORKSPACE_ID='workspace:9', CMUX_SOCKET_PASSWORD='')
        self.assertEqual(0,answer.returncode,answer.stderr)
        result=json.loads(self.results()[0].read_text()); attempt=Path(result['attempt'])
        host=json.loads((attempt/'host.json').read_text())
        self.assertEqual('herdr',host['host'])
        self.assertEqual('FM_HOST',host['source'])
        self.assertTrue(host['inherited_cmux_context_ignored'])
        self.assertEqual('caller',host['caller'])
        owner=json.loads((attempt/'owner.json').read_text())
        self.assertEqual(owner['focus_before'],owner['focus_after'])
        pane=json.loads((self.repo/owner['pane_id']).read_text())
        self.assertEqual(result['actor'],pane['label'])
        window=json.loads((attempt/'window.json').read_text())
        self.assertEqual('herdr',window['host'])
        self.assertEqual(owner['pane_id'],window['pane'])
        self.assertTrue((self.repo/'closed').exists())
        self.assertEqual('completed',result['status'])

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
        for host,marker in (('tmux',dict(TMUX='/tmp/tmux-0/default,1,0')),('cmux',dict(FM_HOST='cmux',FM_CMUX_CALLER_WORKSPACE='workspace:1'))):
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
                    created=next(c for c in calls if c[0]=='new-workspace')
                    self.assertEqual(['new-workspace','--cwd'],created[:2])
                    self.assertIn(' follow ',created[created.index('--command')+1])
                    self.assertIn(['rename-workspace','--workspace','workspace:7',actor],calls)
                    self.assertEqual('workspace:1',(self.repo/'cmux-focus').read_text())
                    self.assertEqual(actor,(self.repo/'cmux-title-workspace-7').read_text())
                    self.assertEqual(['close-workspace','--workspace','workspace:7'],calls[-1])
                    self.assertEqual('closed',window['status'])
                self.assertFalse((self.repo/'controls').exists())

    def test_a_cmux_workspace_that_cannot_be_labelled_is_retained_and_not_reported_open(self):
        self.executable('cmux', self.CMUX_STUB.replace("elif a[:1]==['rename-workspace']:",
                                                       "elif a[:1]==['rename-workspace']:\n sys.exit('Error: denied')\nelif False:"))
        answer=self.invoke('fm-review.sh',['--task','T-035','--branch','work'],HERDR_ENV='0',FM_HOST='cmux',FM_CMUX_CALLER_WORKSPACE='workspace:1')
        self.assertEqual(0,answer.returncode,answer.stderr)
        calls=[json.loads(s) for s in (self.repo/'cmux-calls').read_text().splitlines()]
        self.assertFalse(any(c[0]=='close-workspace' for c in calls))
        self.assertEqual('workspace:1',(self.repo/'cmux-focus').read_text())
        result=json.loads(self.results()[0].read_text())
        self.assertEqual('completed',result['status'])
        window=json.loads((Path(result['attempt'])/'window.json').read_text())
        self.assertIn('rename-workspace',window['reason'])
        self.assertIn('Error: denied',window['reason'])
        self.assertEqual('none',window['status'])
        self.assertEqual('workspace:7',window['ref'])

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
        self.assertEqual('none',host(CMUX_WORKSPACE_ID='w'))
        self.assertEqual('cmux',host(FM_HOST='cmux',CMUX_WORKSPACE_ID='w'))
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
        self.seed_self_authoring()
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
