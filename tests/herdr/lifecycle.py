from herdr import *

class Lifecycle(LifecycleFixture):
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
        # Codex does not accept another vendor's result-object shape.
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

unittest.main(argv=['herdr', *os.environ.get('FM_TEST_CASES','').split()], verbosity=2)
