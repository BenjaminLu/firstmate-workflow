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
fifo=root/'carry-owned.fifo';os.mkfifo(fifo)
fd=os.open(fifo,os.O_RDWR|os.O_NONBLOCK)
(root/'.fixture-carry-notify').write_text(str(fifo))
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_'))}
env.update(FM_ROOT=str(root),FM_GH=str(root/'stub/gh'),
           FM_MERGE_CARRY_SECONDS='10',FM_MERGE_CARRY_POLL='1')
child=start(['bash',str(root/'bin/fm-merge.sh'),'--pr','9','--task','T-009',
    '--expected-head','a'*40,'--bound-signature','c'*64],owner=os.getpid(),env=env,
    stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
try:
    assert select.select([fd],[],[],8)[0], 'helper did not enter full carry wait'
    os.read(fd,4096)
    view=json.loads((root/'pr.json').read_text())
    view.update(state='MERGED',headRefName='t-010-other')
    (root/'pr.next').write_text(json.dumps(view));(root/'pr.next').replace(root/'pr.json')
    output=child.communicate(timeout=10)[0].decode()
    assert child.returncode==1,output
    assert "not T-009's" in output and 'already merged' not in output,output
    assert 'pr merge' not in (root/'ghcalls').read_text()
finally:
    if child.poll() is None: child.terminate();child.wait(timeout=20)
    os.close(fd)
