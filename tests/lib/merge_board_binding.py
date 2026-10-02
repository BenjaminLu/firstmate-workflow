"""Real board -> merge helper refusals, waiting on pushed settlement wakes."""
import json
import os
from pathlib import Path
import re
import select
import shutil
import subprocess
import sys
import time
import urllib.request

code, root = map(Path, sys.argv[1:])
sys.path.insert(0, str(code / 'bin/lib'))
from fm_lifeline import start, Doorbell
for name in ('fm_lifeline.py', 'fm_project_paths.py'):
    shutil.copy(code / 'bin/lib' / name, root / 'bin/lib' / name)
(root / 'board/public').mkdir(parents=True)
shutil.copy(code / 'board/public/index.html', root / 'board/public/index.html')
(root / 'state/pending').mkdir(parents=True, exist_ok=True)
env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
env.update(FM_ROOT=str(root), FM_PORT='0', FM_GH=str(root / 'stub/gh'),
           XDG_CONFIG_HOME=str(root / 'auth'))
child = start(['bun', 'run', str(code / 'board/server.ts')], owner=os.getpid(),
              env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
try:
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        assert select.select([child.stdout], [], [], max(0, deadline-time.monotonic()))[0], 'board startup timeout'
        line = child.stdout.readline().decode()
        assert line, 'board stopped during startup'
        match = re.search(r'board on http://127\.0\.0\.1:(\d+)', line)
        if match:
            port = match[1]; break
    else:
        raise AssertionError('board did not announce its port')
    url = 'http://127.0.0.1:' + port
    secret = (root / ('auth/firstmate/board-' + port + '.secret')).read_text().strip()
    for index, mode in enumerate(('stale', 'atomic', 'missing', 'matching'), 1):
        ident = 'D-' + str(800 + index)
        (root / 'pr.json').write_text(json.dumps(dict(number=9, state='OPEN', headRefName='t-009-board',
            title='T-009: fixture', headRefOid=('b' if mode == 'stale' else 'a')*40)))
        (root / 'move-on-merge').unlink(missing_ok=True)
        (root / 'merged').unlink(missing_ok=True)
        if mode == 'atomic': (root / 'move-on-merge').touch()
        card = dict(id=ident, kind='merge', task='T-009', pr=9, title='Merge verified candidate')
        if mode != 'missing': card['expected_head'] = 'a'*40
        (root / 'state/pending' / (ident + '.json')).write_text(json.dumps(card))
        with Doorbell(str(root)) as bell:
            request = urllib.request.Request(url + '/decisions', json.dumps(dict(id=ident,chosen='A')).encode(),
                headers={'Content-Type':'application/json', 'Origin':url,'Authorization':'Bearer '+secret}, method='POST')
            answer = json.load(urllib.request.urlopen(request, timeout=20))
            assert answer['ok'], answer
            deadline = time.monotonic()+60
            while True:
                decision = json.loads((root/'state/decisions'/(ident+'.json')).read_text())
                if decision['merge'] != 'running': break
                assert bell.wait(max(0, deadline-time.monotonic())), 'settlement wake timeout'
        if mode == 'matching':
            assert decision['merge'] == 'merged'
            assert decision['expected_head'] == 'a'*40
            assert (root/'merged').exists()
        else:
            assert decision['merge'] == 'failed', (mode,decision)
            assert not (root/'merged').exists(), 'refusal must leave PR unmerged'
            events = [json.loads(line) for line in (root/'state/events.jsonl').read_text().splitlines()]
            failures = [e for e in events if e['type']=='decision_made' and e.get('data',{}).get('decision')==ident and e['data'].get('merge')=='failed']
            assert len(failures)==1, (mode,failures)
            assert failures[0]['summary']['en'] and failures[0]['summary']['zh-TW']
            assert not any(e['type']=='merged' for e in events)
    calls = (root/'ghcalls').read_text()
    assert '--match-head-commit ' + 'a'*40 in calls
finally:
    child.terminate()
    child.wait(timeout=20)
