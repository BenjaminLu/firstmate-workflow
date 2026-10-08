"""T-220 signed carry evidence; disposable git/gh transport, no network."""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch
code, temporary = map(Path, sys.argv[1:])
sys.path.insert(0, str(code / 'bin/lib'))
import fm_binding as binding
from fm_binding import source_binding
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

store.append('verdict', 1, 'reviewer', head, 'APPROVE:T-138', verdict='APPROVE',
             base=base, patch=bound['patch'], binding=bound, provenance={'level':'legacy'})
git('remote', 'add', 'origin', 'https://github.com/fixture/project.git')
git('config', 'url.' + str(root) + '.insteadOf', 'https://github.com/fixture/project.git')
remote = temporary / 'remote.json'
stub = temporary / 'gh'
stub.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p=Path(os.environ['BINDING_REMOTE'])
r=json.loads(p.read_text())
if sys.argv[1:3] == ['pr','view']: print(json.dumps({k:r.get(k) for k in sys.argv[sys.argv.index('--json')+1].split(',')}))
elif sys.argv[1:3] == ['pr','list']: print('[]')
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

os.environ.update(FM_EVIDENCE_PROJECT='self', FM_BINDING_REPOSITORY='fixture/project')
command = [sys.executable, str(code/'bin/lib/fm_binding.py')]
def view(h, status='BEHIND'):
    git('update-ref', 'refs/pull/9/head', h)
    remote.write_text(json.dumps(dict(state='OPEN',headRefOid=h,headRefName='task',
        baseRefOid=git('rev-parse','main'),baseRefName='main',mergeStateStatus=status)))
def ready(h):
    report=Path(os.environ['FM_STATE_DIR'])/'gates'/('T-138-'+h+'.txt')
    report.parent.mkdir(parents=True,exist_ok=True)
    mapping=binding.gate_list()
    report.write_text('HEAD:'+h+'\nBASE:'+git('rev-parse','main')+'\nGATES:2\n'+
        ''.join(f"  + gate {g['n']} ({g['name']}): fixture\n" for g in mapping['gates']))
    r=subprocess.run(command+['ready','--task','T-138','--pr','9','--head',h,'--gate-report',str(report)],capture_output=True,text=True)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)
view(head)
r0=ready(head)
def carry(status, reason='', signature=None, pre=False):
    r=subprocess.run(command+['carry','--task','T-138','--pr','9','--head',head,
        '--bound-signature', signature or r0['signature']]+(['--pre-sync'] if pre else []),capture_output=True,text=True)
    assert r.returncode == status, (status,r.returncode,r.stdout,r.stderr)
    assert reason in r.stderr, (reason,r.stderr)
    if status == 0: assert r.stderr == '', r.stderr
    return json.loads(r.stdout) if status == 0 else None
# (i) same-head invalidation distinguishes update eligibility from transient reads.
git('checkout','-q','main')
(root/'base-only').write_text('base update\n');git('add','base-only');git('commit','-qm','base update')
new_base=git('rev-parse','HEAD')
for state,status,reason in [('CLEAN',1,'will not be updated'),('DIRTY',1,'will not be updated (DIRTY)'),
                           ('BEHIND',75,'gate base moved'),('UNKNOWN',75,'gate base moved')]:
    view(head,state);carry(status,reason)
view(head,'CLEAN')
os.environ['STATUS_STATE']='pending';carry(75,'required check/status pending')
os.environ['STATUS_STATE']='success'
pre=carry(0,pre=True)
assert pre.get('precheck') is True and 'gates' not in pre and 'signature' not in pre, pre
# (ii) only base merges have been added; fresh readiness is still required.
git('checkout','-q','task');git('merge','--no-ff','-qm','update base','main')
h1=git('rev-parse','HEAD');view(h1);carry(75,'no signed six-gate readiness')
# (iii) live base is read independently of stale local refs.
mirror=temporary/'mirror.git'
subprocess.run(['git','clone','-q','--mirror',str(root),str(mirror)],check=True)
git('config','--unset','url.'+str(root)+'.insteadOf')
git('config','url.'+str(mirror)+'.insteadOf','https://github.com/fixture/project.git')
git('update-ref','refs/heads/main',base);carry(75,'local base is stale')
git('update-ref','refs/heads/main',new_base)
git('config','--unset','url.'+str(mirror)+'.insteadOf')
git('config','url.'+str(root)+'.insteadOf','https://github.com/fixture/project.git')
# (iv) same signed review, new gates/checks, new exact head.
ready(h1)
r1=carry(0)
assert r1['head']==h1 and r1['carried_from']==head, r1
# (v) a card must point at its own signed readiness.
carry(1,'card readiness record not found',signature='0'*64)
# (vi) red checks refuse before new readiness exists.
git('checkout','-q','main');(root/'second-base').write_text('second\n')
git('add','second-base');git('commit','-qm','second base');base2=git('rev-parse','HEAD')
git('checkout','-q','task');git('merge','--no-ff','-qm','second update','main')
h2=git('rev-parse','HEAD');view(h2)
os.environ['STATUS_STATE']='failure';carry(1,'required check failed')
os.environ['STATUS_STATE']='success'
# (vii) own commits cannot carry an answer.
(root/'src/feature').write_text('different\n');git('commit','-qam','own change')
view(git('rev-parse','HEAD'));carry(1,'gained its own commits')
# (viii) native review identity is head-bound.
view(h1)
with patch.object(binding,'review_policy',return_value='external'):
    try: binding.carry(root,'fixture/project','T-138','9',head,r0['signature'])
    except binding.CarryRefused as e: assert 'external review policy' in str(e), str(e)
    else: raise AssertionError('changed external review head must refuse')
# (ix) mutate a signed record (never unsigned legacy evidence).
record=next(p for p in store.directory.glob('*.json') if json.loads(p.read_text()).get('signature'))
saved=record.read_bytes();data=json.loads(saved);data['head']='b'*40;record.write_text(json.dumps(data))
carry(1,'evidence store failed verification');carry(1,'evidence store failed verification',pre=True)
record.write_bytes(saved)
# Real merge-only patch/file changes reach step(d), never the own-commit guard.
# Each branch begins at the card head; resolving a base conflict changes the
# task delta without adding a non-merge task commit.
git('checkout','-q','main')
(root/'src/feature').write_text('base rewrite\n');git('commit','-qam','base conflict')
conflict_base=git('rev-parse','HEAD')
for kind in ('patch','files'):
    git('checkout','-qb','conflict-'+kind,head)
    merge=subprocess.run(['git','-C',str(root),'merge','--no-ff','main'],capture_output=True,text=True)
    assert merge.returncode == 1 and 'CONFLICT' in merge.stdout, merge
    (root/'src/feature').write_text('resolved task change\n' if kind=='patch' else 'new\n')
    git('add','src/feature')
    if kind=='files':
        (root/'new-task-file').write_text('new task file\n');git('add','new-task-file')
    git('commit','-qm','resolve base merge')
    altered_head=git('rev-parse','HEAD');view(altered_head)
    assert git('rev-list','--no-merges',altered_head,'^'+head,'^'+conflict_base)=='', 'merge-only fixture'
    carry(1,'differs from the card: '+kind)
git('checkout','-q','task')
git('update-ref','refs/heads/main',base2)
view(h2)
# External fm-review projects use fresh ancestry even for unprotected CLEAN.
private=temporary/'private'
(private/'state').mkdir(parents=True);(private/'tasks').mkdir()
(private/'tasks/T-138.json').write_text(json.dumps(dict(id='T-138',scope=['*'],
    adopt=dict(pr=9,head=head,base='main'))))
(private/'state/config.yaml').write_text((root/'config.yaml').read_text())
policy=dict(land='card',review='fm',post='local',merge_method='merge',stacking='hold',
    repository='fixture/project',base='main',confirmed=True,policy_confirmed=True,
    delete_branch=False,force_with_lease=False,required_checks=['ci','security'],
    captain='fixture',intent='Carry test',confirmed_at='2026-10-08',product='Fixture',
    watch_seconds=30,debounce_seconds=1,reinspect_seconds=60)
(private/'CONVENTIONS.md').write_text('---\n'+''.join(k+': '+json.dumps(v)+'\n' for k,v in policy.items())+'---\n')
self_r0=r0
with patch.dict(os.environ,FM_EXTERNAL='1',FM_STATE_DIR=str(private/'state'),
                FM_TASKS_DIR=str(private/'tasks'),FM_DESIGN=str(private/'design.md'),
                FM_ENGINE_ROOT=str(code),FM_BASE='main',FM_EVIDENCE_PROJECT='app'):
    # ready() writes its transcript in the selected private state.
    external_store=Store(private/'state','app','T-138',external=True)
    external_bound=source_binding('T-138',head,base,code)
    external_store.append('verdict',1,'reviewer',head,'APPROVE:T-138',verdict='APPROVE',
        base=base,patch=external_bound['patch'],binding=external_bound,provenance={'level':'legacy'})
    git('update-ref','refs/heads/main',base);view(head,'CLEAN')
    r0=ready(head)
    assert carry(0)['head']==head, 'signed authorized adoption accepts readiness'
    git('update-ref','refs/heads/main',base2);view(head,'CLEAN')
    carry(75,'gate base moved')
    view(head,'DIRTY');carry(1,'will not be updated (DIRTY)')
    view(head,'CLEAN')
    # PR authorization cannot be bypassed in either phase.
    specpath=private/'tasks/T-138.json';saved=specpath.read_bytes()
    spec=json.loads(saved);spec['adopt']['pr']=10;specpath.write_text(json.dumps(spec))
    carry(1,'PR does not match authorized adoption');carry(1,'PR does not match authorized adoption',pre=True)
    specpath.write_bytes(saved)
    changed_base=json.loads(remote.read_text());changed_base['baseRefName']='other';remote.write_text(json.dumps(changed_base))
    carry(1,'adopted PR base changed',pre=True)
    view(head,'CLEAN')
    # Independently mutate approved local input bytes, without any commits.
    view(h2)
    for path,key in ((specpath,'spec_sha256'),(private/'state/config.yaml','contract_sha256'),
                     (private/'CONVENTIONS.md','conventions_sha256')):
        saved=path.read_bytes()
        if key=='spec_sha256':
            value=json.loads(saved);value['title']='changed input';path.write_text(json.dumps(value))
        else: path.write_bytes(saved+b'\n# changed approved input\n')
        carry(1,'differs from the card: '+key)
        path.write_bytes(saved)
    # Independent precheck must permit synchronization for head-bound policies.
    # collect() really observes a stale local base; neither phase may hide it.
    import fm_external
    policy['reviewers']=['fixture']
    (temporary/'reviews.json').write_text(json.dumps([dict(id=1,user=dict(login='fixture'),
        state='APPROVED',commit_id=head,submitted_at='2026-10-08',html_url='fixture')]))
    for review_mode in ('external','both'):
        policy['review']=review_mode
        (private/'CONVENTIONS.md').write_text('---\n'+''.join(k+': '+json.dumps(v)+'\n' for k,v in policy.items())+'---\n')
        git('update-ref','refs/heads/main',base);view(head,'CLEAN')
        current_bound=source_binding('T-138',head,base,code)
        external_store.append('verdict',2,'reviewer',head,'APPROVE:T-138',verdict='APPROVE',
            base=base,patch=current_bound['patch'],binding=current_bound,provenance={'level':'legacy'})
        r0=ready(head)
        git('update-ref','refs/heads/main',base2)
        live_mirror=temporary/('external-'+review_mode+'.git')
        subprocess.run(['git','clone','-q','--mirror',str(root),str(live_mirror)],check=True)
        git('update-ref','refs/heads/main',base)
        git('config','--unset','url.'+str(root)+'.insteadOf')
        git('config','url.'+str(live_mirror)+'.insteadOf','https://github.com/fixture/project.git')
        fresh_view=json.loads(remote.read_text());fresh_view['baseRefOid']=base2
        remote.write_text(json.dumps(fresh_view))
        pre=carry(0,pre=True)
        assert pre.get('precheck') is True and 'signature' not in pre and 'gates' not in pre, pre
        carry(75,'local base is stale')
        # Synchronization unblocks full collection; changed remote reviews are
        # re-read even though the independent precheck still passes.
        git('update-ref','refs/heads/main',base2)
        carry(75,'candidate gate base moved; refresh gates')
        reviews=json.loads((temporary/'reviews.json').read_text())
        reviews[0]['id']=2;(temporary/'reviews.json').write_text(json.dumps(reviews))
        carry(0,pre=True);carry(1,'review changed')
        reviews[0]['id']=1;(temporary/'reviews.json').write_text(json.dumps(reviews))
        git('config','--unset','url.'+str(live_mirror)+'.insteadOf')
        git('config','url.'+str(root)+'.insteadOf','https://github.com/fixture/project.git')
        # Post-precheck external identity changes remain an immediate refusal.
        latest=[r for r in external_store.records() if r['kind']=='external-verdict'][-1]
        altered={k:v for k,v in latest.items() if k not in
            ('kind','round','actor','head','text','signature','project','task','seq','created_at')}
        altered['readiness_signature']='c'*64
        external_store.append('external-verdict',2,'firstmate-external',head,'',**altered)
        carry(1,'review changed',pre=True);carry(1,'review changed')
    view(h2)
    # Changed external policy head refuses before stale local base is needed.
    policy['review']='external'
    (private/'CONVENTIONS.md').write_text('---\n'+''.join(k+': '+json.dumps(v)+'\n' for k,v in policy.items())+'---\n')
    carry(1,'external review policy',pre=True)
r0=self_r0
# Same-head transient command errors remain waiting even when CLEAN.
view(head,'CLEAN')
with patch.object(binding,'fetch_ref',side_effect=ValueError('binding command failed: transient fixture')):
    try: binding.carry(root,'fixture/project','T-138','9',head,r0['signature'])
    except binding.CarryWaiting as e: assert 'transient fixture' in str(e)
    else: raise AssertionError('transient read must wait')
# An external signature change cannot be hidden by an unchanged local review.
selected=store.verdicts()[-1]
with patch.object(binding,'selected_review',return_value=(selected,dict(signature='b'*64))):
    try: binding.carry(root,'fixture/project','T-138','9',head,r0['signature'])
    except binding.CarryRefused as e: assert 'review changed' in str(e), str(e)
    else: raise AssertionError('different external signature must refuse')
view(h1)
for unknown in (None, '', 'UNKNOWN', 7, {}):
    unreadable=json.loads(remote.read_text());unreadable['state']=unknown
    remote.write_text(json.dumps(unreadable))
    carry(75,'PR state is unreadable');carry(75,'PR state is unreadable',pre=True)
remote.write_text('{}')
carry(75,'PR state is unreadable');carry(75,'PR state is unreadable',pre=True)
view(h1)
closed=json.loads(remote.read_text());closed['state']='CLOSED';remote.write_text(json.dumps(closed))
carry(1,'PR is not open');carry(1,'PR is not open',pre=True)
view(h1)
# New APPROVE identity supersedes the card, and full carry repeats precheck.
view(h1);carry(0,pre=True)
store.append('verdict',2,'other-reviewer',head,'APPROVE:T-138',verdict='APPROVE',
             base=base,patch=bound['patch'],binding=bound,provenance=dict(level='authenticated',
                 final_source='codex-json-completed-turn',final_sha256=hashlib.sha256(b'APPROVE:T-138').hexdigest(),
                 actor='other-reviewer',task='T-138',role='reviewer'))
carry(1,'review changed');carry(1,'review changed',pre=True)
# (x) final signed rejection wins even with unchanged patch and inputs.
store.append('verdict',3,'reviewer',h1,'REJECT:T-138',verdict='REJECT',
             base=new_base,patch=bound['patch'],binding=bound,provenance={'level':'legacy'})
carry(1,'no current local approval');carry(1,'no current local approval',pre=True)
