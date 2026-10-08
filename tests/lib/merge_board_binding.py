"""Real board -> merge helper refusals, waiting on pushed settlement wakes."""
import json
import os
from pathlib import Path
import re
import select
import shutil
import shlex
import subprocess
import sys
import time
import tempfile
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
auth = tempfile.TemporaryDirectory(prefix='fm-merge-board-auth-')
env.update(FM_ROOT=str(root), FM_PORT='0', FM_GH=str(root / 'stub/gh'),
           XDG_CONFIG_HOME=auth.name)
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
    secret = (Path(auth.name) / ('firstmate/board-' + port + '.secret')).read_text().strip()
    for index, mode in enumerate(('stale', 'atomic', 'missing', 'unavailable', 'carry-refused', 'carry-timeout', 'matching'), 1):
        ident = 'D-' + str(800 + index)
        (root / 'pr.json').write_text(json.dumps(dict(number=9, state='OPEN', headRefName='t-009-board',
            title='T-009: fixture', headRefOid=('b' if mode == 'stale' else 'a')*40)))
        (root / 'move-on-merge').unlink(missing_ok=True)
        (root / 'merged').unlink(missing_ok=True)
        if mode == 'atomic': (root / 'move-on-merge').touch()
        if mode == 'unavailable':
            (root/'bin/lib/fm_lifeline.py').rename(root/'bin/lib/lifeline.saved')
        if mode in ('carry-refused', 'carry-timeout'):
            helper=root/'bin/fm-merge.sh'
            helper.rename(root/'bin/merge.saved')
            message = ("fm-merge: the captain's answer cannot carry to the current head: fixture / 船長的答案無法沿用到目前版本：fixture" if mode=='carry-refused' else
                       "fm-merge: waited 1 min for readiness on the updated head: no signed six-gate readiness for candidate / 已等待 1 分鐘，更新後的版本仍未就緒：fixture")
            helper.write_text("#!/usr/bin/env bash\nprintf '%s\\n' " + shlex.quote(message) + '\nexit 1\n')
            helper.chmod(0o755)
        (root/'ghcalls').write_text('')
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
            summary = failures[0]['summary']
            assert summary['en'] and summary['zh-TW']
            calls = (root/'ghcalls').read_text()
            reasons = dict(stale='PR head changed or is unverifiable', missing='missing verified candidate SHA',
                           atomic='GitHub refused the bound merge', unavailable='Merge helper unavailable',
                           **{'carry-refused':'cannot carry to the current head','carry-timeout':'for readiness on the updated head'})
            assert reasons[mode] in failures[0]['data']['reason'], failures
            translated = dict(stale='PR 版本已變更或無法驗證；請更新審核與關卡',
                              missing='缺少已驗證的候選版本 SHA',
                              atomic='GitHub 拒絕合併指定版本；請重新確認 PR 狀態',
                              unavailable='無法啟動合併程式',
                              **{'carry-refused':'船長的答案無法沿用到目前版本；需要新的合併卡','carry-timeout':'等待更新後版本就緒逾時；需要新的合併卡'})
            assert summary['zh-TW'] == ident + '：合併失敗：' + translated[mode]
            if mode == 'atomic':
                assert sum('pr merge' in line for line in calls.splitlines()) == 1
                assert '--match-head-commit ' + 'a'*40 in calls
            else:
                assert 'pr merge' not in calls
            if mode == 'unavailable':
                assert summary['zh-TW'] == ident + '：合併失敗：無法啟動合併程式'
                (root/'bin/lib/lifeline.saved').rename(root/'bin/lib/fm_lifeline.py')
            if mode in ('carry-refused','carry-timeout'):
                (root/'bin/merge.saved').replace(root/'bin/fm-merge.sh')
            assert not any(e['type']=='merged' for e in events)
    calls = (root/'ghcalls').read_text()
    assert '--match-head-commit ' + 'a'*40 in calls
finally:
    child.terminate()
    child.wait(timeout=20)
    auth.cleanup()
