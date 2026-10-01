from herdr import *

class Roster(RosterFixture):
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

    def test_record_requested_names_the_vendor_and_model_from_the_start(self):
        """T-146: the vendor a round is on and the model config.yaml names
        for it join identity.json as the attempt starts; a fallback vendor
        replaces them and clears what the previous vendor reported, so a
        model is never shown against a vendor that did not run it."""
        run = m.allocate(self.root, 'worker', 'T-601', '')
        before = json.loads((run / 'identity.json').read_text())
        identity = m.record_requested(run, 'codex', 'gpt-6-astra')
        self.assertEqual(('codex', 'gpt-6-astra'), (identity['vendor'], identity['model_requested']))
        self.assertNotIn('model', identity)
        for k, v in before.items(): self.assertEqual(v, identity[k], k)
        self.assertEqual(identity, json.loads((run / 'identity.json').read_text()))
        m.record_model(run, 'codex', 'gpt-6-astra', 'gpt-6-astra', '1.0')
        moved = m.record_requested(run, 'claude', 'claude-opus-5-5')
        self.assertEqual(('claude', 'claude-opus-5-5'), (moved['vendor'], moved['model_requested']))
        for k in ('model', 'cli_version', 'model_mismatch'): self.assertNotIn(k, moved)
        # a vendor with no model named: its CLI's default, requested as nothing
        self.assertEqual('', m.record_requested(run, 'gemini', '')['model_requested'])

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

unittest.main(argv=['herdr', *os.environ.get('FM_TEST_CASES','').split()], verbosity=2)
