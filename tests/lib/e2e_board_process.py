#!/usr/bin/env python3
"""Own a fixture board; EOF drains every keeper before the caller removes it."""
import os
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
root, config, library = sys.argv[1:]
sys.path.insert(0, library)
import fm_lifeline as life

# Adopt orphaned grandchildren on Linux so this controller reaps them too.
# macOS's launchd reaps non-child exits; the scope still waits for each exit.
if sys.platform == 'linux':
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise OSError(ctypes.get_errno(), 'cannot own orphaned board children')

os.environ['FM_LIFELINE_SCOPE'] = str(Path(config) / 'lifelines')
os.environ.pop('FM_SESSION_PID', None)
os.environ['HERDR_ENV'] = '0'
# Pipe ownership means the board also ends if this controller is killed.
board = life.start(['bun', 'run', str(Path(root) / 'board/server.ts')],
                   owner=None, stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    # The runner closes this pipe for both teardown and startup failure. Its
    # own death closes the pipe too; no orphaned fixture keeps running.
    sys.stdin.buffer.read()
finally:
    life.close_scope(os.environ['FM_LIFELINE_SCOPE'])
    board.wait(timeout=15)
    if sys.platform == 'linux':
        while True:
            try:
                os.waitpid(-1, 0)
            except ChildProcessError:
                break
