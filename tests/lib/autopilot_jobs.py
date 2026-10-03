"""Real owned job receipts and pushed completion; no polling or live services."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

os.environ['HERDR_ENV'] = '0'
sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_autopilot as A
import fm_lifeline as life


class Jobs(unittest.TestCase):
    def test_child_stdin_is_closed_and_receipt_pushes_completion(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ctx = dict(engine=tmp, state=str(root/'state'), target=tmp, project='alpha',
                       tasks=str(root/'tasks'), evidence_project='alpha', external=False,
                       repository='owner/alpha', base='main')
            env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
            env['HERDR_ENV'] = '0'
            with patch.dict(os.environ, env, clear=True):
                pilot = A.Pilot(ctx)
                received = []
                pilot.job_completed = received.append
                argv = [sys.executable, '-c', 'import sys; assert sys.stdin.read() == ""; print("no verdict; log is at /kept/second.log"); sys.exit(3)']
                with life.Doorbell(root, channel='autopilot.d') as bell:
                    # Keep the caller's stdin open forever: inheriting it
                    # would block the child's read instead of returning EOF.
                    read_fd, write_fd = os.pipe()
                    saved = os.dup(0)
                    try:
                        os.dup2(read_fd, 0)
                        child = pilot.start_job('review', 'T-001', dict(number=12, head={'sha':'a'*40}), argv)
                    finally:
                        os.dup2(saved, 0); os.close(saved); os.close(read_fd)
                    self.addCleanup(os.close, write_fd)
                    self.addCleanup(child.wait, timeout=30)
                    self.assertTrue(bell.wait(30), 'the completion writer must wake the service')
                    pilot.consume_jobs()
                    child.wait(timeout=30)
                self.assertEqual(len(received), 1)
                self.assertEqual(received[0]['code'], 3)
                self.assertIn('log is at /kept/second.log', received[0]['output'])
                restored = A.Pilot(ctx)
                restored.job_completed = received.append
                restored.recover_jobs()
                self.assertEqual(len(received), 1, 'a consumed job never replays after restart')

    def test_ambiguous_child_is_not_restarted(self):
        with tempfile.TemporaryDirectory() as tmp:
            ctx = dict(engine=tmp, state=tmp, target=tmp, project='alpha', tasks=tmp,
                       evidence_project='alpha', external=False, repository='owner/alpha', base='main')
            pilot = A.Pilot(ctx)
            pilot.data['jobs'] = {'old':dict(task='T-001', state='running', path=tmp+'/missing.json')}
            pilot.save()
            restored = A.Pilot(ctx)
            restored.recover_jobs(); restored.recover_jobs()
            self.assertEqual(restored.data['jobs']['old']['state'], 'uncertain')
            self.assertEqual(len(restored.data['wakes']), 1)


if __name__ == '__main__': unittest.main()
