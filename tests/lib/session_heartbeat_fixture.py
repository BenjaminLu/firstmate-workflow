"""Bounded real-child handshake for the execute_child heartbeat case only."""

import contextlib
import io
import os
from pathlib import Path
import select
import shlex
import subprocess
import sys
from unittest.mock import patch


# This runs in the adapter process created by production execute_child. The
# deadline is a failure bound, never the mechanism that orders the heartbeat.
CHILD_SOURCE = '''
import os
from pathlib import Path
import sys
import time

ready_fd = int(sys.argv[1])
release = Path(sys.argv[2])
transcript = Path(sys.argv[3])
deadline = time.monotonic() + 10
os.write(ready_fd, b'R')
os.close(ready_fd)
while not release.exists():
    if time.monotonic() >= deadline:
        print('heartbeat fixture deadline: no release received', file=sys.stderr)
        sys.exit(73)
    time.sleep(0.01)
with transcript.open('a') as stream:
    stream.write('done\\n')
'''


class HeartbeatOutput(io.StringIO):
    def __init__(self, release):
        super().__init__()
        self.release = release
        self.releases = 0

    def write(self, text):
        count = super().write(text)
        if not self.releases and '[fm] worker-hb-t035-r1 still running (' in self.getvalue():
            self.release.write_text('heartbeat observed\n')
            self.releases += 1
        return count


class HeartbeatFixture(contextlib.ExitStack):
    def __init__(self, module, attempt, adapter):
        super().__init__()
        self.module, self.attempt, self.adapter = module, attempt, adapter
        self.children = []
        self.ready_count = 0
        self.output = HeartbeatOutput(attempt / 'heartbeat.release')

    def __enter__(self):
        super().__enter__()
        try:
            ready_read, ready_write = os.pipe()
            self.callback(os.close, ready_read)
            self.callback(os.close, ready_write)
            source = self.attempt / 'heartbeat_child.py'
            source.write_text(CHILD_SOURCE)
            self.adapter.write_text('#!/bin/sh\nexec ' + ' '.join(map(shlex.quote, (
                str(Path(sys.executable).resolve()), str(source), str(ready_write),
                str(self.output.release), str(self.attempt / 'cli.log')))) + '\n')
            self.adapter.chmod(0o755)
            original_popen, original_save = self.module.subprocess.Popen, self.module.save

            def capture(args, **kwargs):
                if args[0] != str(self.adapter):
                    return original_popen(args, **kwargs)
                kwargs['pass_fds'] = (*kwargs.get('pass_fds', ()), ready_write)
                child = original_popen(args, **kwargs)
                self.children.append(child)
                return child

            def save_ready(path, value):
                result = original_save(path, value)
                if Path(path) == self.attempt / 'execution.json':
                    if not select.select([ready_read], [], [], 5)[0]:
                        raise AssertionError('heartbeat fixture readiness deadline expired')
                    if os.read(ready_read, 1) != b'R':
                        raise AssertionError('heartbeat fixture readiness signal missing')
                    self.ready_count += 1
                return result

            self.enter_context(patch.object(self.module.subprocess, 'Popen', side_effect=capture))
            self.saved = self.enter_context(patch.object(self.module, 'save', side_effect=save_ready))
            self.enter_context(contextlib.redirect_stdout(self.output))
            # Registered last: reap before restoring patches or closing ready fds.
            self.callback(self.reap)
            return self
        except BaseException:
            self.close()
            raise

    def reap(self):
        for child in self.children:
            try:
                child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                child.terminate()
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=2)

    def verify_completed(self, case):
        case.assertEqual(1, self.output.getvalue().count('finished exit='))
        case.assertEqual(1, self.output.releases)
        case.assertEqual(1, self.ready_count)
        case.assertEqual(1, len(self.children))
        child = self.children[0]
        case.assertEqual(child.pid, self.module.read(self.attempt / 'execution.json')['pid'])
        case.assertEqual(0, self.module.read(self.attempt / 'result.json')['exit_code'])
        case.assertEqual(1, sum(Path(c.args[0]) == self.attempt / 'result.json'
                                for c in self.saved.call_args_list))
        case.assertEqual('done\n', (self.attempt / 'cli.log').read_text())
        case.assertEqual(0, child.poll(), 'fixture child must be exited and reaped')
