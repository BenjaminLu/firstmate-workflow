"""T-282: the self queue still blocks and wakes on a pending gate 5 result."""
import unittest

import autopilot_queue as fixture


class GateCiPendingQueue(unittest.TestCase):
    # Reuse fixture helpers without inheriting the unrelated queue tests.
    setUp = fixture.QueueTests.setUp
    api = fixture.QueueTests.api
    authorize = fixture.QueueTests.authorize
    prepared_result = fixture.QueueTests.prepared_result

    def test_self_queue_pending_gate_5_blocks_and_wakes(self):
        result = self.prepared_result(5)
        self.assertEqual(self.pilot.queue_mode, 'enabled')
        self.assertEqual(self.pilot.data['self_queue']['front'], '1')
        result['output'] = 'fm-binding: required check/status pending: ci'
        self.pilot.job_completed(result)
        self.assertEqual(self.pilot.data['self_queue']['members']['1']['state'], 'blocked')
        wakes = [w for w in self.pilot.data['wakes'].values() if 'stopped at gate 5' in w['line']]
        self.assertEqual([w['line'] for w in wakes], ['T-001: stopped at gate 5 (ci)'])


if __name__ == '__main__': unittest.main()
