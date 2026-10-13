"""An owned carry helper rereads ownership before accepting a terminal PR."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys

code, root = map(Path, sys.argv[1:])
sys.path.insert(0,str(code/'bin/lib'))
from fm_lifeline import start
# The child's own carry deadline, and the most this waits on it (T-306): the
# rewrite below ends the wait, so a slow runner spends time, not the deadline.
CARRY_SECONDS=120
fifo=root/'carry-owned.fifo';os.mkfifo(fifo)
fd=os.open(fifo,os.O_RDWR|os.O_NONBLOCK)
(root/'.fixture-carry-notify').write_text(str(fifo))
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_'))}
env.update(FM_ROOT=str(root),FM_GH=str(root/'stub/gh'),
           FM_MERGE_CARRY_SECONDS=str(CARRY_SECONDS),FM_MERGE_CARRY_POLL='1')
child=start(['bash',str(root/'bin/fm-merge.sh'),'--pr','9','--task','T-009',
    '--expected-head','a'*40,'--bound-signature','c'*64],owner=os.getpid(),env=env,
    stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
try:
    # Wait on the child itself: its signal, or its end, never a fixed 8 s.
    early=b''
    while fd not in select.select([fd,child.stdout],[],[])[0]:
        chunk=os.read(child.stdout.fileno(),4096)
        assert chunk, 'helper ended before its full carry wait: '+(early+child.stdout.read()).decode()
        early+=chunk
    os.read(fd,4096)
    view=json.loads((root/'pr.json').read_text())
    view.update(state='MERGED',headRefName='t-010-other')
    (root/'pr.next').write_text(json.dumps(view));(root/'pr.next').replace(root/'pr.json')
    output=(early+child.communicate(timeout=CARRY_SECONDS)[0]).decode()
    assert child.returncode==1,output
    assert "not T-009's" in output and 'already merged' not in output,output
    assert 'pr merge' not in (root/'ghcalls').read_text()
finally:
    if child.poll() is None: child.terminate();child.wait(timeout=20)
    os.close(fd)
