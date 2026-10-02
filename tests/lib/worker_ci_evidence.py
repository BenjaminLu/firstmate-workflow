"""Vendor-shaped required-check responses shared by worker prompt fixtures.

Exit 64 means this helper does not own the command; the shell stub handles it.
"""
import json
from pathlib import Path
import subprocess
import sys

link = Path(sys.argv[1]).read_text().strip()
args = sys.argv[2:]
head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
if args[:2] == ['pr', 'checks']:
    row = dict(name='ci', state='FAILURE', bucket='fail', link=link,
               workflow='CI', startedAt='2026-10-02T00:00:00Z',
               completedAt='2026-10-02T00:01:00Z', description='', event='pull_request')
    fields = args[args.index('--json') + 1].split(',')
    print(json.dumps([{key: row[key] for key in fields}]))
    sys.exit(1)
elif args[:2] == ['pr', 'view'] and '--json' in args and 'headRefOid' in args[-1]:
    print(json.dumps(dict(headRefOid=head, baseRefName='main', mergeStateStatus='CLEAN')))
elif args[:1] == ['api'] and '/protection/' in args[1]:
    print('HTTP 404: Not Found', file=sys.stderr)
    sys.exit(1)
elif args[:1] == ['api'] and '/check-runs?' in args[1]:
    print(json.dumps(dict(total_count=1, check_runs=[dict(id=999, name='ci',
        head_sha=head, status='completed', conclusion='failure', details_url=link)])))
elif args[:1] == ['api'] and '/status?' in args[1]:
    print(json.dumps(dict(sha=head, statuses=[])))
else:
    sys.exit(64)
