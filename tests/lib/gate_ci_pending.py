"""T-282: gate 5 results whose only reason is tracked CI still running queue no wake."""
import unittest

import autopilot_loop as fixture

A, PR, HEAD, BASE, CHECKS = fixture.A, fixture.PR, fixture.HEAD, fixture.BASE, fixture.CHECKS

PENDING = 'fm-binding: required check/status pending: ci'
GATE5 = '  x gate 5 (ci): the required GitHub check is green'


class GateCiPending(unittest.TestCase):
    # Reuse fixture helpers without inheriting the unrelated lifecycle tests.
    setUp = fixture.LoopTests.setUp
    record_job = fixture.LoopTests.record_job
    command = fixture.LoopTests.command
    probe = fixture.LoopTests.probe
    branch_setup = fixture.BranchFixture.branch_setup
    branch_probe = fixture.BranchFixture.branch_probe

    def gate_result(self, code, output):
        self.pilot.job_completed(dict(kind='gate', task='T-001', pr=PR, base=BASE,
                                     round=1, code=code, output=output))

    def gate_wakes(self, code, name):
        ident = 'autopilot-' + A.key(['alpha', 'gate-12-' + HEAD])
        wakes = self.pilot.data['wakes']
        self.assertEqual(set(wakes), {ident}, 'exactly one gate wake with the existing identity')
        self.assertEqual(wakes[ident]['line'], f'T-001: stopped at gate {code} ({name})')

    def test_pending_tracked_check_queues_no_wake(self):
        self.gate_result(5, GATE5 + '\n' + PENDING + '\n')
        self.assertEqual(self.pilot.data['wakes'], {}, 'CI still running must not wake firstmate')

    def test_pending_line_only_queues_no_wake(self):
        # The final ready step of bin/fm-gate.sh also exits 5 with only this line.
        self.gate_result(5, PENDING)
        self.assertEqual(self.pilot.data['wakes'], {}, 'a lone pending line must not wake firstmate')

    def test_every_other_exit_5_still_wakes(self):
        for output in ('fm-binding: required check/status failed: ci',
                       'fm-binding: required check/status pending (missing): ci',
                       PENDING + '\nfm-binding: required check/status failed: ci',
                       '',
                       'fm-binding: required check/status pending: lint'):
            with self.subTest(output=output):
                self.pilot.data['wakes'] = {}
                self.gate_result(5, output)
                self.gate_wakes(5, 'ci')

    def test_unknown_check_names_still_wake(self):
        def unreadable(endpoint): raise RuntimeError('protection unreadable')
        self.pilot.api = unreadable
        self.gate_result(5, PENDING)
        self.gate_wakes(5, 'ci')

    def test_exit_4_still_wakes(self):
        self.gate_result(4, PENDING)
        self.gate_wakes(4, 'fail-first')

    def test_check_names_feeds_settled_checks(self):
        self.assertEqual(self.pilot.check_names(PR), {'ci'})
        self.pilot.policy.update(required_checks=['security'], analysers=['lint'])
        self.assertEqual(self.pilot.check_names(PR), {'ci', 'security', 'lint'})
        def unreadable(endpoint): raise RuntimeError('protection unreadable')
        self.pilot.api = unreadable
        self.assertEqual(self.pilot.check_names(PR), {'security', 'lint'})
        self.pilot.policy.update(required_checks=[], analysers=[])
        with self.assertRaises(RuntimeError):
            self.pilot.check_names(PR)
        self.pilot.api = lambda endpoint: dict(contexts=[], checks=[])
        with self.assertRaises(ValueError):
            self.pilot.check_names(PR)
        with self.assertRaises(ValueError):
            self.pilot.settled_checks(PR, CHECKS, [])

    def test_skipped_pending_result_regates_once_ci_settles(self):
        self.pilot.advance(PR, CHECKS, [])
        self.assertEqual(sum(c[0] == 'gate' for c in self.calls), 1)
        self.gate_result(5, PENDING)
        self.assertEqual(self.pilot.data['wakes'], {})
        queued = dict(CHECKS[0], id=2, status='queued', conclusion=None)
        self.pilot.advance(PR, CHECKS + [queued], [])
        self.assertEqual(sum(c[0] == 'gate' for c in self.calls), 1, 'running CI starts no gate')
        done = dict(CHECKS[0], id=2, status='completed', conclusion='success')
        self.pilot.advance(PR, CHECKS + [done], [])
        self.assertEqual(sum(c[0] == 'gate' for c in self.calls), 2, 'settled CI starts the gate again')


if __name__ == '__main__': unittest.main()
