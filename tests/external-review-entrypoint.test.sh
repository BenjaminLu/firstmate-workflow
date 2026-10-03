#!/usr/bin/env bash
# T-140 real entrypoint, wrapper and API transport; only storage admission and
# fetch are controlled boundaries. Shared GitHub shapes: tests/lib/external-review-gh.py.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib.sh"
python3 - "$ROOT" <<'PY'
import json, os, shlex, shutil, subprocess, sys, tempfile
from pathlib import Path
sys.dont_write_bytecode=True
code=Path(sys.argv[1]); sys.path.insert(0,str(code/'bin/lib'))
from fm_onboard import infer, approve
from fm_evidence import Store
with tempfile.TemporaryDirectory() as temporary:
    home=Path(temporary); repo=home/'repo'; repo.mkdir()
    env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_')) and k!='GH_REPO'}
    env.update(PYTHONDONTWRITEBYTECODE='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
    def git(*args):
        return subprocess.check_output(['git','-C',str(repo),*args],env=env,text=True).strip()
    git('init','-q','-b','main'); git('config','user.name','Fixture'); git('config','user.email','fixture@example.invalid')
    (repo/'feature').write_text('before\n'); git('add','.'); git('commit','-qm','base')
    base=git('rev-parse','HEAD'); git('checkout','-qb','task')
    (repo/'feature').write_text('after\n'); git('commit','-qam','feature'); head=git('rev-parse','HEAD')
    evidence=dict(repository='org/app',base='main',source='github',pulls=[],commits=[],
        repository_info={'allow_squash_merge':True,'allow_merge_commit':False,'allow_rebase_merge':False,'delete_branch_on_merge':False},protection={'status':'unknown'})
    approve(home,evidence,infer(evidence),dict(confirmed=True,policy_confirmed=True,
        captain='captain',intent='Private intent',product='Product',required_checks=['drone'],
        contract={'check':'true'},review='external',post='check',reviewers=['R2D2-im']))
    (home/'tasks').mkdir(exist_ok=True); (home/'tasks/T-140.json').write_text('{"id":"T-140"}')
    state=home/'state'; state.mkdir(exist_ok=True); (state/'config.yaml').write_text('project:\n  check: true\n')
    payload=dict(head=head,base=base,reviews=[dict(id=1,user={'login':'R2D2-im'},state='APPROVED',
        commit_id=head,submitted_at='2026-10-03T00:00:00Z',body='',html_url='https://github.com/org/app/pull/9#pullrequestreview-1')],
        threads=[],comments=[],checks=[],statuses=[dict(id=1,context='drone',state='success')])
    (home/'payload.json').write_text(json.dumps(payload))
    env.update(FM_EXTERNAL='1',FM_PROJECT='app',FM_STATE_DIR=str(state),FM_TARGET_ROOT=str(repo),
        FM_TASKS_DIR=str(home/'tasks'),FM_CONFIG=str(state/'config.yaml'),GH_REPO='org/app',FM_GH=str(code/'tests/lib/external-review-gh.py'),
        EXTERNAL_PAYLOAD=str(home/'payload.json'),EXTERNAL_LOG=str(home/'calls'))
    # Run the byte-identical entrypoint with real fm_external from fm-config.
    # Admission/fetch are already covered by project/binding suites. Log each
    # admission boundary so a missing call cannot silently satisfy this test.
    entry=home/'bin'; entry.mkdir(); shutil.copyfile(code/'bin/fm-external.sh',entry/'fm-external.sh')
    q=shlex.quote
    (entry/'fm-config.sh').write_text('. '+q(str(code/'bin/fm-config.sh'))+'\n'+
        'fm_default_repo() { printf "%s\\n" "$FM_TARGET_ROOT"; }\n'+
        'fm_storage_init() { echo storage >> '+q(str(home/'boundaries'))+'; }\n'+
        'fm_target_validate() { echo validate >> '+q(str(home/'boundaries'))+'; }\n'+
        'fm_conventions() { echo conventions >> '+q(str(home/'boundaries'))+'; }\n'+
        'fm_binding() { echo "$*" >> '+q(str(home/'boundaries'))+'; echo '+q(head)+'; }\n'+
        'fm_project_get() { printf "%s\\n" '+q(str(home/'CONVENTIONS.md'))+'; }\n'+
        'fm_evidence_project() { echo app; }\n'+
        'python3() { printf "%s\\n" "$@" >> '+q(str(home/'python-args'))+'; command python3 "$@"; }\n')
    for command in ('collect','project'):
        p=subprocess.run(['bash',str(entry/'fm-external.sh'),command,'--project','app','--task','T-140',
            '--pr','9','--branch','task'],env=env,text=True,capture_output=True)
        assert p.returncode==0,p.stderr
        if command=='collect': assert json.loads(p.stdout)['ready'],p.stdout
    args=(home/'python-args').read_text().splitlines()
    for key,value in (('--root',str(repo)),('--repository','org/app'),('--conventions',str(home/'CONVENTIONS.md'))):
        assert args.count(key)==2,(key,args)
        assert all(args[i+1]==value for i,a in enumerate(args) if a==key),(key,args)
    assert (home/'boundaries').read_text().splitlines()==['storage','validate','conventions','head --task T-140 --pr 9 --branch task']*2
    calls=[json.loads(line) for line in (home/'calls').read_text().splitlines()]
    assert any('/reviews?' in c['endpoint'] for c in calls)
    assert any(c['endpoint']=='graphql' for c in calls)
    writes=[c for c in calls if c['method']=='POST']
    assert len(writes)==1 and writes[0]['endpoint']=='repos/org/app/statuses/'+head,writes
    assert writes[0]['body']['context']=='firstmate local progress'
    records=Store(state,'app','T-140',external=True).records()
    assert {r['kind'] for r in records}=={'external-verdict','projection'}
PY
assert_eq 0 "$?" 'external entrypoint collects and projects through repository-bound wrapper'
finish
