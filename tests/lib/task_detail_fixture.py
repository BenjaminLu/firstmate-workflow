"""Task detail HTTP fixtures; store APIs write authentic evidence."""
import json
from pathlib import Path
import sys
from ste_cases import card
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'bin/lib'))
from fm_evidence import Store
root, state, project = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
external = project != 'self'
tasks = state.parent/'tasks' if external else root/'design/tasks'
tasks.mkdir(parents=True, exist_ok=True)
fields = ('intent','why','done','scope_in','scope_out','notes','before_nodes','after_nodes')
explain = {lang:{k:v for k,v in loc.items() if k in fields} for lang,loc in card().items()}
for task in ('T-001','T-002','T-003','SK-001'):
    spec = dict(id=task,title='Plan: The task works.',milestone='M2',depends_on=[],scope=['tests/plan.test.sh','test/other.test.sh'],acceptance=['tests/plan.test.sh proves it.'])
    if task in ('T-001','T-003'): spec['explain'] = explain
    (tasks/(task+'.json')).write_text(json.dumps(spec))
for folder in ('pending','decisions'): (state/folder).mkdir(exist_ok=True,parents=True)
id1 = 'D-beta-T001-1' if external else 'D-1'
id2 = 'D-beta-T002-1' if external else 'D-2'
(state/'pending'/f'{id1}.json').write_text(json.dumps(dict(id=id1,task='T-001',project=project if external else None,kind='choice',purpose='dispatch',title='The task works.',details=card(),ste={'ok':True},ts='2026-10-01T01:00:00Z')))
(state/'decisions'/f'{id2}.json').write_text(json.dumps(dict(id=id2,task='T-002',project=project if external else None,kind='merge',chosen='A',ts='2026-10-01T01:00:00Z')))
events=[]
for round_number,role,event_type in [(1,'worker','dispatched'),(1,'reviewer','review_opened'),(2,'worker','commit_pushed')]:
    events.append(dict(task='T-002',project=project if external else None,actor=role+'-'+project,type=event_type,ts='2026-10-01T01:00:00Z',data={'identity':dict(round=round_number,role=role,vendor='codex'), 'head':'f'*40}))
events.append(dict(task='T-002',project=project if external else None,actor='github',type='merged',pr=7,ts='2026-10-01T02:00:00Z'))
(state/'events.jsonl').write_text(''.join(json.dumps(e)+'\n' for e in events))
store=Store(state,project,'T-002',external=external)
store.append('brief',1,'firstmate','a'*40,'Brief headline'+(' beta' if external else '')+'\nBEGIN PRIVATE BRIEF')
store.append('worker-report',1,'worker-'+project,'b'*40,'BEGIN PRIVATE REPORT')
store.append('verdict',1,'reviewer-'+project,'a'*40,'BEGIN PRIVATE VERDICT',verdict='APPROVE',provenance={'level':'legacy'})
store.append('readiness',1,'firstmate','a'*40,'',gate_base='c'*40,gates=[1,2,4,5,6,7],checks=[{'name':'ci','conclusion':'SUCCESS'}],review={'text':'BEGIN PRIVATE REVIEW'})

archive = state/'runtime/archived-pending'
archive.mkdir(parents=True, exist_ok=True)
(archive/'D-999.json').write_text(json.dumps(dict(id='D-999', task='T-001', kind='choice', purpose='dispatch', details=card())))

# T-232: the same projection for a new name-list record on the pending task.
Store(state,project,'T-001',external=external).append('readiness',1,'firstmate','a'*40,'',gate_base='c'*40,gates=['branch','rebase','scope','fail-first','ci','approval'],checks=[{'name':'ci','conclusion':'SUCCESS'}])
