"""T-281: a settled stale job no longer holds the self queue's drain."""
import unittest

import autopilot_queue as fixture

H = fixture.H


class StaleJobDrain(unittest.TestCase):
    # Reuse fixture helpers without inheriting the queue suite.
    setUp = fixture.QueueTests.setUp
    api = fixture.QueueTests.api
    authorize = fixture.QueueTests.authorize

    def test_settled_job_without_binding_no_longer_holds_the_drain(self):
        for pr in self.prs.values(): pr['mergeable_state'] = 'clean'
        # An unlabelled legacy job keeps activation observing; it is never settled.
        self.pilot.data['jobs'] = {'legacy': dict(task='T-002', state='uncertain', path='')}
        self.pilot.poll()
        self.assertIsNone(self.pilot.data['self_queue']['front'])
        self.policy['enabled'] = False; self.authorize()
        self.pilot.refresh_queue()
        self.assertEqual(self.pilot.queue_mode, 'drain')
        stale = dict(kind='gate', task='T-001', number=1, head='c' * 40, state='uncertain', path='')
        self.pilot.data['jobs'] = {'stale': stale}
        self.pilot.refresh_queue()
        self.assertEqual(self.pilot.queue_mode, 'drain', 'the stale job alone holds the drain')
        self.pilot.poll()
        self.assertEqual(stale['state'], 'superseded')
        self.assertEqual(stale['superseded_by'], H)
        self.assertNotIn('queue_binding', stale)
        self.pilot.poll()
        self.assertEqual(self.pilot.queue_mode, 'off', 'a settled job must not hold the drain on the next poll')


if __name__ == '__main__': unittest.main()
