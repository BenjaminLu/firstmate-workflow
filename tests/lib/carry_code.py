"""T-220 waits on one immutable engine, through real final worktree cleanup."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys

sys.dont_write_bytecode = True
code = Path(sys.argv[1])
sys.path.insert(0, str(code/'bin/lib'))
from fm_lifeline import start
from external_rebuild import ExternalRebuild

fixture = ExternalRebuild()
child = None
fifo_fd = None
try:
    fixture.setUp()
    engine, home, state = fixture.engine, fixture.home, fixture.state
    target = home/'repo'
    fixture.run_ok('git','clone','-q',str(fixture.remote),str(target))
    # A real adopted human branch exercises the copied ownership resolver.
    spec = json.loads((home/'tasks/T-223.json').read_text())
    spec['adopt'] = dict(pr=9,head=fixture.prev,base='trunk')
    (home/'tasks/T-223.json').write_text(json.dumps(spec))
    tree = home/'worktrees/T-223'
    tree.parent.mkdir(exist_ok=True)
    fixture.run_ok('git','-C',str(target),'worktree','add','-q','-b','human-feature',str(tree),'origin/t-223-work')
    log = fixture.scratch/'code.jsonl'
    fifo = fixture.scratch/'waiting.fifo'; os.mkfifo(fifo)
    fifo_fd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
    release = fixture.scratch/'ready.json'
    merged = fixture.scratch/'merged'
    # Replace only evidence service in the disposable engine. Each executable
    # records its own pathname; mutation after first full try must be harmless.
    binding = engine/'bin/lib/fm_binding.py'
    binding.with_name('fm_binding_real.py').write_text(binding.read_text())
    binding.write_text('''import json, os, sys
from pathlib import Path
from fm_binding_real import fetch_ref, git, github, repository, sha

if __name__ == '__main__':
    with open(os.environ['CARRY_CODE_LOG'],'a') as log:
        log.write(json.dumps(dict(kind='binding',code=__file__,target=os.environ['FM_TARGET_ROOT'],state=os.environ['FM_STATE_DIR']))+'\\n')
    if sys.argv[1]=='carry' and '--pre-sync' in sys.argv:
        print('{"precheck":true}');raise SystemExit(0)
    release=Path(os.environ['CARRY_CODE_RELEASE'])
    if release.exists(): print(release.read_text());raise SystemExit(0)
    if sys.argv[1]=='carry':
        assert '/fm-merge-carry.' in str(Path(__file__).resolve()), 'full carry must use frozen engine'
        with open(os.environ['CARRY_CODE_FIFO'],'w') as fifo: fifo.write('waiting\\n')
    print('no signed six-gate readiness for candidate',file=sys.stderr)
    raise SystemExit(75)
''')
    adoption = engine/'bin/lib/fm_adopt.py'
    adoption.write_text('''import json, os
with open(os.environ['CARRY_CODE_LOG'],'a') as log:
    log.write(json.dumps(dict(kind='adoption',code=__file__,target=os.environ['FM_TARGET_ROOT'],state=os.environ['FM_STATE_DIR']))+'\\n')
'''+adoption.read_text())
    for name, kind in [('fm-emit.sh','emitter'),('fm-cleanup.sh','cleanup')]:
        path=engine/'bin'/name
        body=path.read_text()
        observer='''if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  python3 - "$0" "''' + kind + '''" "$@" <<'OBS'
import json, os, sys
with open(os.environ['CARRY_CODE_LOG'],'a') as log:
    log.write(json.dumps(dict(kind=sys.argv[2],code=sys.argv[1],args=sys.argv[3:],root=os.environ['FM_ROOT']))+'\\n')
OBS
fi
'''
        path.write_text(body.replace('#!/usr/bin/env bash\n','#!/usr/bin/env bash\n'+observer,1))
    gh=Path(fixture.env['FM_GH'])
    gh.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args=sys.argv[1:]
merged=Path(os.environ['CARRY_CODE_MERGED'])
if args[:2]==['pr','list']: print('[]')
elif args[:2]==['pr','merge']:
    assert args[args.index('--match-head-commit')+1]==os.environ['CARRY_CODE_HEAD']
    merged.touch()
elif args[:2]==['pr','view']:
    state='MERGED' if merged.exists() else 'OPEN'
    if '--jq' in args: print(state)
    else: print(json.dumps(dict(state=state,headRefName='human-feature',title='Human feature',
        baseRefName='trunk',headRefOid=os.environ['CARRY_CODE_HEAD'])))
else: raise SystemExit(1)
''');gh.chmod(0o755)
    env=dict(fixture.env, CARRY_CODE_LOG=str(log), CARRY_CODE_FIFO=str(fifo),
             CARRY_CODE_RELEASE=str(release), CARRY_CODE_MERGED=str(merged),
             CARRY_CODE_HEAD=fixture.prev, FM_MERGE_CARRY_SECONDS='15', FM_MERGE_CARRY_POLL='1')
    child=start(['bash',str(engine/'bin/fm-merge.sh'),'--repo',str(engine),'--project','app',
        '--task','T-223','--pr','9','--expected-head','a'*40,'--bound-signature','c'*64],
        owner=os.getpid(),env=env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    assert select.select([fifo_fd],[],[],10)[0], 'carry did not reach full wait'
    assert os.read(fifo_fd,4096) == b'waiting\n', 'full carry wait signal'
    waiting_rows=[json.loads(line) for line in log.read_text().splitlines()]
    assert any(r['kind']=='binding' and '/fm-merge-carry.' in r['code'] for r in waiting_rows), waiting_rows
    for path in (binding,adoption,engine/'bin/fm-emit.sh',engine/'bin/fm-cleanup.sh'):
        path.write_text('raise SystemExit("MUTATED ENGINE")\n' if path.suffix=='.py' else '#!/usr/bin/env bash\necho MUTATED ENGINE >&2\nexit 99\n')
    release.write_text(json.dumps(dict(head=fixture.prev)))
    output=child.communicate(timeout=15)[0].decode()
    assert child.returncode==0, output
    assert 'MUTATED ENGINE' not in output, output
    rows=[json.loads(line) for line in log.read_text().splitlines()]
    copied=[r for r in rows if '/fm-merge-carry.' in r['code']]
    for kind in ('binding','adoption','emitter','cleanup'):
        assert any(r['kind']==kind for r in copied), (kind,rows)
    roots={str(Path(r['code']).parents[2] if r['kind'] in ('binding','adoption') else Path(r['code']).parents[1]) for r in copied}
    assert len(roots)==1, roots
    for r in copied:
        if r['kind'] in ('binding','adoption'):
            assert r['target']==str(target) and r['state']==str(state), r
        else: assert r['root']==str(engine), r
    assert not tree.exists(), 'actual ownership-checked cleanup must delete disposable task worktree'
    events=[json.loads(line) for line in (state/'events.jsonl').read_text().splitlines()]
    assert any(e['type']=='merged' and e['data']['head']==fixture.prev for e in events), events
    assert any(e['type']=='closed' and e['task']=='T-223' for e in events), events
    assert any(r['kind']=='emitter' and '--type' in r['args'] and r['args'][r['args'].index('--type')+1]=='closed' for r in copied), rows
    assert not (engine/'state/events.jsonl').exists(), 'external events remain private'
    operations=[json.loads(line) for line in (fixture.scratch/'git.jsonl').read_text().splitlines()]
    assert any('worktree' in a and 'remove' in a and str(tree) in a for a in operations), operations
    assert not any(any('fm-merge-carry.' in arg for arg in a) for a in operations), 'git never operates on copied engine'
    assert all(not Path(p).exists() for p in roots), 'owned snapshot removed on exit'
finally:
    if child and child.poll() is None:
        child.terminate();child.wait(timeout=20)
    if fifo_fd is not None: os.close(fifo_fd)
    fixture.doCleanups()
