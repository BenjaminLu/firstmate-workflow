from herdr import *

class AgentLost(AgentLostFixture):
    def test_a_vanished_pid_is_lost_once_and_a_live_one_is_kept(self):
        ghost, live, done = 'worker-ghost-t118-r1', 'worker-live-t118-r2', 'worker-done-t118-r1'
        for actor in (ghost, live, done): self.say(actor, 'dispatched')
        self.say(done, 'agent_finished')
        token = 'fm-live-' + live
        holder = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)', token],
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: (holder.kill(), holder.wait()))
        self.recorded(ghost, self.dead, 'fm-worker.sh')
        self.recorded(live, holder.pid, token)
        first = m.retire_dead_crew(self.root)
        self.assertEqual([ghost], first['lost'])
        self.assertEqual([live], first['kept'])
        after = self.events()
        lost = [e for e in after if e['type'] == 'agent_lost']
        self.assertEqual([ghost], [e['actor'] for e in lost], 'only the vanished run is lost, and once')
        self.assertEqual('T-118', lost[0]['task'])
        self.assertIn('lost', lost[0]['summary']['en'])
        self.assertIn('失聯', lost[0]['summary']['zh-TW'])
        # the close that has always followed a ghost still follows it
        self.assertEqual(['agent_lost', 'agent_finished'], [e['type'] for e in after if e['actor'] == ghost][1:])
        # T-137: the loss wakes firstmate, pushed once by the reconcile that
        # wrote it, with the line firstmate is woken with
        queue = self.root/'state/session/wake.jsonl'
        woken = [(i['id'], i['reason'], i['line']) for i in map(json.loads, queue.read_text().splitlines())]
        self.assertEqual([(ghost, 'lost', f'lost: T-118 {ghost}')], woken)
        # read again, nothing more is written: the run is already off the deck
        second = m.retire_dead_crew(self.root)
        self.assertEqual([], second['lost'])
        self.assertEqual(after, self.events())
        self.assertEqual(1, len(queue.read_text().splitlines()), 'and it wakes firstmate once')

    def test_a_loss_already_written_is_not_written_again(self):
        ghost = 'worker-half-t118-r1'
        self.say(ghost, 'dispatched'); self.say(ghost, 'agent_lost')
        self.recorded(ghost, self.dead, 'fm-worker.sh')
        result = m.retire_dead_crew(self.root)
        self.assertEqual([], result['lost'])
        self.assertEqual([ghost], result['retired'])
        self.assertEqual(['dispatched', 'agent_lost', 'agent_finished'], [e['type'] for e in self.events()])

unittest.main(argv=['herdr', *os.environ.get('FM_TEST_CASES','').split()], verbosity=2)
