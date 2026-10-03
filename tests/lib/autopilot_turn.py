"""Drive production PR advancement synchronously at fixture command boundaries.

The daemon's owned asynchronous receipts are covered by autopilot lifecycle
coverage. This driver keeps real gates, review launchers and decision validation
in the end-to-end and credential fixtures, without a resident process.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

os.environ['HERDR_ENV'] = '0'
sys.dont_write_bytecode = True
engine = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(engine / 'bin/lib'))
import fm_autopilot as A

result = subprocess.run(['bash', str(engine / 'bin/fm-autopilot.sh'), 'context', '--repo', str(engine)],
                        env=dict(os.environ, FM_AUTOPILOT_TEST_ENABLE='1'),
                        stdin=subprocess.DEVNULL, capture_output=True, text=True, check=True)
ctx = json.loads(result.stdout)
for name, field in [('FM_ENGINE_ROOT','engine'), ('FM_STATE_DIR','state'), ('FM_TARGET_ROOT','target'),
                    ('FM_TASKS_DIR','tasks'), ('FM_PROJECT','project'), ('FM_EVIDENCE_PROJECT','evidence_project')]:
    os.environ[name] = ctx[field]
os.environ['FM_EXTERNAL'] = '1' if ctx['external'] else '0'
pilot = A.Pilot(ctx)

def execute(kind, task, pr, argv, **extra):
    result = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    print(result.stdout + result.stderr)
    if kind == 'review': print('sending it to review')
    pilot.job_completed(dict(kind=kind, task=task, pr=pr, code=result.returncode,
                             output=result.stdout + result.stderr, **extra))

pilot.start_job = execute
pilot.local()
for event in pilot.rows():
    if event.get('type') != 'pr_opened': continue
    if any(r.get('type') in ('merged','closed') and r.get('pr') == event['pr'] for r in pilot.rows()): continue
    task = event['task']
    branch = subprocess.check_output(['git', '-C', ctx['target'], 'branch', '--list',
        task.lower() + '-*', '--format=%(refname:short)'], text=True).splitlines()[0]
    head = subprocess.check_output(['git', '-C', ctx['target'], 'rev-parse', branch + '^{commit}'], text=True).strip()
    base = pilot.base_tip()
    pr = dict(number=event['pr'], state='open', title=task + ': fixture', head=dict(ref=branch, sha=head),
              base=dict(ref=ctx['base'], sha=base), draft=False)
    pilot.advance(pr, [], [])
for wake in pilot.data['wakes'].values(): print(wake['line'])
