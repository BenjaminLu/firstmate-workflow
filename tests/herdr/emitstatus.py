from herdr import *

class EmitStatus(EmitStatusFixture):
    def test_heartbeat_without_progress(self):
        rc = m.main(['emit-status','--root',str(self.root),'--actor','worker-h',
                     '--task','T-H','--role','worker','--en','still running','--tw','仍在跑'])
        self.assertEqual(0, rc)
        ev = self.events(); self.assertEqual(1, len(ev))
        self.assertEqual('crew_status', ev[0]['type'])
        self.assertEqual('still running', ev[0]['data']['activity']['en'])
        self.assertEqual('仍在跑', ev[0]['data']['activity']['zh-TW'])
        self.assertNotIn('progress', ev[0].get('data', {}))

    def test_a_status_carries_the_runs_identity_fields(self):
        # T-116: the board reads name, project and round from the payload,
        # never out of the actor
        run = self.root/'state/runs/worker-shira-t116-r3b'; run.mkdir(parents=True)
        m.save(run/'identity.json', dict(actor=run.name, name='shira', role='worker', project='alpha',
                                         task='T-116', round=3, attempt=2, one_role=True))
        self.assertEqual(0, m.main(['emit-status','--root',str(self.root),'--actor',run.name,
                                    '--task','T-116','--role','worker','--en','x','--tw','y']))
        # (T-146: with vendor and model beside them, null while unrecorded)
        self.assertEqual(dict(name='shira', role='worker', project='alpha', task='T-116', round=3, attempt=2,
                              vendor=None, model_requested=None, model=None, cli_version=None,
                              model_mismatch=None),
                         self.events()[-1]['data']['identity'])
        # a run from before T-116 has no such fields, and none are invented
        old = self.root/'state/runs/worker-mira-t035-r465'; old.mkdir(parents=True)
        m.save(old/'identity.json', dict(actor=old.name, name='mira', role='worker', task='T-035'))
        m.main(['emit-status','--root',str(self.root),'--actor',old.name,
                '--task','T-035','--role','worker','--en','x','--tw','y'])
        self.assertNotIn('identity', self.events()[-1]['data'])

    def test_a_status_carries_the_vendor_and_model_too(self):
        # T-146: on 2026-09-29 every crewman's vendor, model and CLI were
        # blank on the board, because a Herdr round's crew_status - its
        # latest event - carried T-116's six fields only. It carries every
        # field fm-worker.sh and fm-review.sh send, as identity.json has them.
        run = self.root/'state/runs/worker-imani-t146-r1'; run.mkdir(parents=True)
        m.save(run/'identity.json', dict(actor=run.name, name='imani', role='worker', project='alpha',
                                         task='T-146', round=1, attempt=1))
        m.record_requested(run, 'codex', 'gpt-6-astra')
        m.main(['emit-status','--root',str(self.root),'--actor',run.name,
                '--task','T-146','--role','worker','--en','x','--tw','y'])
        said = self.events()[-1]['data']['identity']
        self.assertEqual(('codex', 'gpt-6-astra', None), (said['vendor'], said['model_requested'], said['model']))
        m.record_model(run, 'codex', 'gpt-6-astra', 'gpt-6-astra', 'codex 1.2.3')
        m.main(['emit-status','--root',str(self.root),'--actor',run.name,
                '--task','T-146','--role','worker','--en','x','--tw','y'])
        said = self.events()[-1]['data']['identity']
        self.assertEqual(dict(name='imani', role='worker', project='alpha', task='T-146', round=1, attempt=1,
                              vendor='codex', model_requested='gpt-6-astra', model='gpt-6-astra',
                              cli_version='codex 1.2.3', model_mismatch=False), said)

    def test_bounded_progress_and_refusals(self):
        self.assertEqual(0, m.main(['emit-status','--root',str(self.root),'--actor','worker-h',
            '--task','T-H','--role','worker','--en','gates 3/7','--tw','關卡 3/7','--done','3','--total','7']))
        ev = self.events(); self.assertEqual({'done':3,'total':7}, ev[-1]['data']['progress'])
        with self.assertRaises(ValueError):
            m.main(['emit-status','--root',str(self.root),'--actor','worker-h',
                    '--task','T-H','--en','x','--tw','y','--done','1'])
        with self.assertRaises(ValueError):
            m.emit_status(self.root, 'worker-h', 'T-H', 'x', 'y', done=9, total=3)

unittest.main(argv=['herdr', *os.environ.get('FM_TEST_CASES','').split()], verbosity=2)
