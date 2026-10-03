"""Real T-138 reader and source bindings in disposable repositories."""
import json
import os
from pathlib import Path
import subprocess
import sys

os.environ['HERDR_ENV'] = '0'
code, temporary = map(Path, sys.argv[1:])
sys.path.insert(0, str(code / 'bin/lib'))
from fm_binding import authoritative, change, source_binding, required_checks
from fm_evidence import Store

root = temporary / 'repo'
root.mkdir()
def git(*args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
git('init', '-q', '-b', 'main')
git('config', 'user.name', 'Fixture')
git('config', 'user.email', 'fixture@example.invalid')
(root / 'design/tasks').mkdir(parents=True)
(root / 'design/tasks/T-138.json').write_text('{"id":"T-138","scope":["*"]}')
(root / 'config.yaml').write_text('project:\n  check: true\n')
(root / 'src').mkdir()
(root / 'src/feature').write_text('old\n')
git('add', '.'); git('commit', '-qm', 'base')
base = git('rev-parse', 'HEAD')
git('checkout', '-qb', 'task')
(root / 'src/feature').write_text('new\n')
git('commit', '-qam', 'feature')
head = git('rev-parse', 'HEAD')
os.environ.update(FM_EXTERNAL='0', FM_STATE_DIR=str(root / 'state'),
                  FM_TARGET_ROOT=str(root), FM_TASKS_DIR=str(root / 'design/tasks'))
store = Store(root / 'state', 'self', 'T-138')
bound = source_binding('T-138', head, base, code)
launcher_diff = subprocess.check_output(['git','-C',str(root),'diff-tree','-r','-p','--no-renames',base,head])
launcher_patch = subprocess.run(['git','patch-id','--stable'],input=launcher_diff,capture_output=True,check=True).stdout.decode().split()[0]
assert bound['patch'] == launcher_patch, 'nested feature patch must match launcher pin'
assert bound['files'] == ['src/feature']
# The outside-round launcher signs Claude's selected answer as legacy.
from argparse import Namespace
from fm_evidence import retain_verdict
run = temporary/'claude-run'
run.mkdir()
(run/'identity.json').write_text(json.dumps(dict(project=None,task='T-138',role='reviewer',round=1,model='claude')))
(run/'evidence-binding.json').write_text(json.dumps(bound))
(run/'final.txt').write_text('APPROVE:T-138')
os.environ['FM_ACTOR'] = 'reviewer'
receipt = retain_verdict(store, Namespace(run=str(run), head=head, base=base, patch=bound['patch'],
    round=1, vendor='claude', code=str(code), attempt='claude-attempt', file=str(run/'final.txt')))
assert receipt['signature'] and receipt['provenance']['level'] == 'legacy'
assert receipt['vendor'] == 'claude', 'Claude launcher receipt must remain signed legacy'

def gate(current, current_base):
    patch = change(root, current, current_base)['patch']
    return subprocess.run([sys.executable, str(code / 'bin/lib/fm_evidence.py'), 'gate',
        '--state', str(root / 'state'), '--project', 'self', '--task', 'T-138',
        '--head', current, '--base', current_base, '--patch', patch, '--code', str(code)], capture_output=True)
assert gate(head, base).returncode == 0, 'local signed approval must pass without comments'
legacy = dict(store.records()[0])
legacy.pop('signature'); legacy.pop('binding')
(store.directory/'00000002-legacy.json').write_text(json.dumps(legacy))
assert len(store.records()) == 2, 'unsigned T-135 history must remain readable'
assert gate(head, base).returncode != 0, 'unsigned historical approval cannot become merge authority'
store.append('verdict', 2, 'reviewer', head, 'APPROVE:T-138', verdict='APPROVE',
             base=base, patch=bound['patch'], binding=bound, provenance={'level':'legacy'})

git('checkout', '-q', 'main')
(root / 'base-only').write_text('base update\n')
git('add', 'base-only'); git('commit', '-qm', 'base update')
new_base = git('rev-parse', 'HEAD')
git('checkout', '-q', 'task'); git('merge', '-qm', 'update base', 'main')
updated = git('rev-parse', 'HEAD')
assert gate(updated, new_base).returncode == 0, 'unchanged patch after base update must carry approval'
(root / 'src/feature').write_text('changed\n')
git('commit', '-qam', 'one line')
changed = git('rev-parse', 'HEAD')
assert gate(changed, new_base).returncode != 0, 'one-line change must void approval'
# A signed but mismatched source hash is not an approval for this contract.
invalid = dict(bound, spec_sha256='0'*64)
store.append('verdict', 2, 'reviewer', updated, 'APPROVE:T-138', verdict='APPROVE',
             base=new_base, patch=bound['patch'], binding=invalid, provenance={'level':'legacy'})
assert gate(updated, new_base).returncode != 0, 'mismatched signed spec must refuse'
store.append('verdict', 3, 'reviewer', updated,
             '1. open repair it\nCRITERIA-COMPLETE:T-138\nREJECT:T-138',
             verdict='REJECT', base=new_base, patch=bound['patch'], provenance={'level':'legacy'})
assert gate(updated, new_base).returncode != 0, 'later rejection supersedes unchanged patch'
# The transport is local git; gh still returns real PR/check/status JSON.
git('remote', 'add', 'origin', 'https://github.com/fixture/project.git')
git('config', 'url.' + str(root) + '.insteadOf', 'https://github.com/fixture/project.git')
git('update-ref', 'refs/pull/9/head', changed)
remote = temporary / 'remote.json'
remote.write_text(json.dumps(dict(state='OPEN', headRefOid=changed, headRefName='t-138-feature', title='T-138: fixture', baseRefName='main', baseRefOid=new_base, reviewDecision='APPROVED')))
stub = temporary / 'gh'
stub.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p=Path(os.environ['BINDING_REMOTE'])
r=json.loads(p.read_text())
if sys.argv[1:3] == ['pr','view']: print(json.dumps({k:r.get(k) for k in sys.argv[sys.argv.index('--json')+1].split(',')}))
elif sys.argv[2] == 'graphql': print(json.dumps({'data':{'repository':{'pullRequest':{'reviewThreads':{'nodes':[],'pageInfo':{'hasNextPage':False}}}}}}))
elif '/issues/9/comments?' in sys.argv[2]: print('[]')
elif '/reviews?' in sys.argv[2]: print(p.with_name('reviews.json').read_text())
elif '/protection/' in sys.argv[2]: print(json.dumps({'contexts':['ci','security'],'checks':[]}))
elif '/check-runs?' in sys.argv[2]: print(json.dumps({'check_runs':[{'id':1,'name':'ci','head_sha':r['headRefOid'],'status':'completed','conclusion':'success'}]}))
elif '/status?' in sys.argv[2]: print(json.dumps({'sha':r['headRefOid'],'statuses':[{'id':2,'context':'security','state':os.environ.get('STATUS_STATE','success')}]}))
else: sys.exit(1)
''')
stub.chmod(0o755)
os.environ.update(FM_GH=str(stub), BINDING_REMOTE=str(remote))
assert authoritative(root, 'task', 'fixture/project', 9) == changed
checks = required_checks(root, 'fixture/project', 9, changed)
assert {r['name'] for r in checks} == {'ci','security'}, 'required commit status must be included'
os.environ['FM_EVIDENCE_PROJECT'] = 'self'
current_binding = source_binding('T-138', changed, new_base, code)
store.append('verdict', 4, 'reviewer', changed,
             '1. done repair it\nCRITERIA-COMPLETE:T-138\nAPPROVE:T-138',
             verdict='APPROVE', base=new_base, patch=current_binding['patch'],
             binding=current_binding, provenance={'level':'legacy'})
assert gate(changed, new_base).returncode == 0
binding_command = [sys.executable, str(code / 'bin/lib/fm_binding.py')]
assert subprocess.run(binding_command + ['ready','--task','T-138','--pr','9','--head',changed], capture_output=True).returncode != 0, 'no readiness without six-gate transcript'
gate_report=root/'state/gates'/('T-138-'+changed+'.txt')
gate_report.parent.mkdir(parents=True)
gate_report.write_text('HEAD:'+changed+'\n'+''.join('  + gate '+str(n)+': fixture gate passed\n' for n in (1,2,4,5,6,7)))
subprocess.run(binding_command + ['ready', '--task', 'T-138', '--pr', '9', '--head', changed, '--gate-report', str(gate_report)], check=True, capture_output=True)
candidate = subprocess.run(binding_command + ['candidate', '--task', 'T-138', '--pr', '9', '--head', changed], check=True, capture_output=True)
assert json.loads(candidate.stdout)['head'] == changed, 'candidate must keep exact checked head'
# The real card producer must retain the verified SHA and signed evidence.
locale = dict(title='Merge candidate', explanation='Checked candidate', before='Open', after='Merged', outcome='Recorded',
              options={k:dict(description='Choose',pros='Benefit',cons='Cost') for k in 'ABC'})
details = temporary/'details.json'
details.write_text(json.dumps({'en':locale,'zh-TW':locale}))
allocate = ['bash', str(code/'bin/fm-decide.sh'), '--repo', str(root), '--task', 'T-138', '--kind', 'merge']
ident = subprocess.check_output(allocate+['--allocate'],text=True).strip()
card = subprocess.run(allocate+['--request',ident,'--pr','9','--expected-head',changed,'--details',str(details)], capture_output=True,text=True)
assert card.returncode == 0, card.stderr
payload = json.loads((root/'state/pending'/(ident+'.json')).read_text())
assert payload['expected_head'] == changed and payload['binding']['head'] == changed
assert payload['binding']['signature'] and payload['gates'] == [True,True,None,True,True,True,True]
missing_id = subprocess.check_output(allocate+['--allocate'],text=True).strip()
missing = subprocess.run(allocate+['--request',missing_id,'--pr','9','--details',str(details)], capture_output=True)
assert missing.returncode != 0 and not (root/'state/pending'/(missing_id+'.json')).exists()
store.append('verdict', 5, 'reviewer', changed,
             '1. open repair it\nCRITERIA-COMPLETE:T-138\nREJECT:T-138',
             verdict='REJECT', base=new_base, patch=current_binding['patch'], provenance={'level':'legacy'})
assert subprocess.run(binding_command + ['candidate', '--task', 'T-138', '--pr', '9', '--head', changed], capture_output=True).returncode != 0, 'later rejection voids merge candidate'
os.environ['STATUS_STATE'] = 'failure'
try:
    required_checks(root, 'fixture/project', 9, changed)
except ValueError:
    pass
else:
    raise AssertionError('red commit status cannot hide behind green check run')
# The remote moves but the local task ref still names the old reviewed commit.
git('update-ref', 'refs/heads/stale', updated)
try:
    authoritative(root, 'stale', 'fixture/project', 9)
except ValueError:
    pass
else:
    raise AssertionError('green stale local head cannot satisfy remote readiness')

# SK proposals become ordinary committed specs only after captain adoption.
try:
    source_binding('SK-001', changed, new_base, code)
except ValueError as error:
    assert 'approved committed task spec required' in str(error), str(error)
else:
    raise AssertionError('unadopted SK proposal cannot substitute for a committed spec')
(root/'design/tasks/SK-001.json').write_text(json.dumps(dict(id='SK-001',scope=['skills/**'],acceptance=['adopted change'])))
git('add','design/tasks/SK-001.json'); git('commit','-qm','adopt skill proposal')
sk_head = git('rev-parse','HEAD')
sk_bound = source_binding('SK-001', sk_head, new_base, code)
import hashlib
assert sk_bound['spec_sha256'] == hashlib.sha256((root/'design/tasks/SK-001.json').read_bytes()).hexdigest()
# Return remote review fixtures to their already recorded task head.
git('checkout','-q','--detach',changed)

# External local-mode review records never enter engine state or PR comments.
private = temporary/'home/projects/private-app'
(private/'state').mkdir(parents=True,exist_ok=True)
(private/'tasks').mkdir(exist_ok=True)
(private/'tasks/T-138.json').write_text((root/'design/tasks/T-138.json').read_text())
(private/'state/config.yaml').write_text((root/'config.yaml').read_text())
policy = dict(land='card',review='external',post='local',merge_method='merge',stacking='hold',repository='fixture/project',base='main',
              reviewers=['external-reviewer'],confirmed=True,policy_confirmed=True,delete_branch=False,force_with_lease=False,required_checks=['ci','security'],
              captain='fixture',intent='Verify native review',confirmed_at='2026-10-02',product='Fixture',
              watch_seconds=30,debounce_seconds=5,reinspect_seconds=60)
(private/'CONVENTIONS.md').write_text('---\n'+''.join(k+': '+json.dumps(v)+'\n' for k,v in policy.items())+'---\n')
os.environ.update(FM_EXTERNAL='1',FM_STATE_DIR=str(private/'state'),FM_TASKS_DIR=str(private/'tasks'),STATUS_STATE='success')
review = dict(id=44,state='APPROVED',commit_id=changed,submitted_at='2026-10-02T00:00:00Z',body='Reviewed change',html_url='https://github.com/fixture/project/pull/9#pullrequestreview-44',user={'login':'external-reviewer','id':45})
(temporary/'reviews.json').write_text(json.dumps([review]))
from fm_binding import external_review
external_store = Store(private/'state','private-app','T-138')
receipt = external_review(external_store,root,'fixture/project',9,changed)
assert receipt['states']['external-reviewer']['review']['user']['login']=='external-reviewer' and receipt['head']==changed
assert receipt['provenance']['final_source']=='github-review-api'
assert external_store.directory == private/'state/evidence/T-138'
assert not (root/'state/evidence/private-app').exists()
review['state']='CHANGES_REQUESTED'
(temporary/'reviews.json').write_text(json.dumps([review]))
try:
    external_review(external_store,root,'fixture/project',9,changed)
except ValueError:
    pass
else:
    raise AssertionError('native external rejection must refuse')
