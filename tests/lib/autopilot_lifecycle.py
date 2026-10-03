"""Real owned service lifecycle; fake gh has REST headers and payload shapes."""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

# Disable inherited Herdr routing before any fixture can launch a shell.
os.environ['HERDR_ENV'] = '0'
sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_autopilot as A
import fm_lifeline as life


class Lifecycle(unittest.TestCase):
    def test_crash_releases_lock_and_next_ensure_restarts_owned_service(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root/'design/tasks').mkdir(parents=True)
            (root/'config.yaml').write_text('project:\n  check: "true"\n')
            gh = root/'gh'
            gh.write_text('#!/bin/sh\nprintf \'HTTP/2.0 200 OK\\nETag: "empty"\\n\\n[]\\n\'\n')
            gh.chmod(0o755)
            env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
            env.update(FM_AUTOPILOT_TEST_ENABLE='1', FM_ENGINE_ROOT=str(root), FM_ROOT=str(root), FM_STATE_DIR=str(root/'state'),
                       FM_TARGET_ROOT=str(root), FM_TASKS_DIR=str(root/'design/tasks'), FM_EXTERNAL='0',
                       FM_AUTOPILOT_REPOSITORY='owner/repo', FM_EVIDENCE_PROJECT='self', FM_BASE='main',
                       FM_GH=str(gh), GH_REPO='owner/repo', FM_CODE_ROOT=str(ROOT), FM_CONFIG=str(root/'config.yaml'))
            # The test owns an explicit owner process, which owns the service.
            # Closing its stdin ends it without a PID-poll loop.
            owner = life.start([sys.executable, '-c', 'import sys; sys.stdin.buffer.read()'],
                               owner=os.getpid(), stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
            service_pid = None
            try:
                env['FM_SESSION_PID'] = str(owner.pid)
                def shell(script, *args):
                    result = subprocess.run(['bash', str(ROOT/'bin'/script), *args, '--repo', str(root)],
                                            env=env, capture_output=True, text=True, timeout=60)
                    self.assertEqual(result.returncode, 0, result.stderr)
                with patch.dict(os.environ, env, clear=True):
                    shell('fm-autopilot.sh', 'ensure', '--all')
                    directory = root/'state/autopilot'
                    service_pid = json.loads((directory/'owner.json').read_text())['pid']
                    self.assertTrue(A.live(directory))
                    shell('fm-autopilot.sh', 'ensure', '--all', '--resume')
                    self.assertEqual(service_pid, json.loads((directory/'owner.json').read_text())['pid'])
                    with_exit = life.ProcessExit(service_pid)
                    try:
                        os.kill(service_pid, signal.SIGKILL)
                        self.assertTrue(select.select([with_exit.fileno()], [], [], 15)[0])
                    finally: with_exit.close()
                    self.assertFalse(A.live(directory))
                    shell('fm.sh', 'help')
                    service_pid = json.loads((directory/'owner.json').read_text())['pid']
                    self.assertTrue(A.live(directory))
                    with_exit = life.ProcessExit(service_pid)
                    try:
                        owner.stdin.close()
                        owner.wait(timeout=15)
                        self.assertTrue(select.select([with_exit.fileno()], [], [], 15)[0], 'owner exit must end service')
                    finally: with_exit.close()
                    self.assertFalse(A.live(directory))
                    service_pid = None
            finally:
                if owner.stdin and not owner.stdin.closed: owner.stdin.close()
                owner.wait(timeout=15)
                if service_pid:
                    try:
                        exit_event = life.ProcessExit(service_pid)
                    except life.OwnerGone: pass
                    else:
                        try:
                            os.kill(service_pid, signal.SIGTERM)
                            select.select([exit_event.fileno()], [], [], 15)
                        finally: exit_event.close()

    def test_emit_rings_owned_fifo_after_durable_append(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root/'config.yaml').write_text('project:\n  check: "true"\n')
            env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
            env['FM_ROOT'] = str(root)
            with patch.dict(os.environ, env, clear=True), life.Doorbell(root, channel='autopilot.d') as bell, life.Doorbell(root) as firstmate:
                result = subprocess.run(['bash', str(ROOT/'bin/fm-emit.sh'), '--actor', 'fixture',
                                         '--type', 'agent_lost', '--task', 'T-001'], env=env,
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(bell.wait(0), 'local writer must push its event notification')
                self.assertFalse(firstmate.wait(0), 'ordinary events must not ring firstmate')
                self.assertEqual(json.loads((root/'state/events.jsonl').read_text())['type'], 'agent_lost')


if __name__ == '__main__': unittest.main()
