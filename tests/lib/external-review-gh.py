#!/usr/bin/env python3
"""Constructed GitHub review/check shapes; refuses unqualified repository calls."""
import json, os, re, sys
from pathlib import Path
args=sys.argv[1:]
p=json.loads(Path(os.environ['EXTERNAL_PAYLOAD']).read_text())
method=args[args.index('--method')+1] if '--method' in args else 'GET'
endpoint=args[1] if args[0]=='api' else 'pr view'
body=json.loads(sys.stdin.read()) if '--input' in args else None
with open(os.environ['EXTERNAL_LOG'],'a') as f:
    f.write(json.dumps(dict(method=method,endpoint=endpoint,body=body,args=args))+'\n')
if args[:2]==['pr','view']:
    assert args[args.index('--repo')+1]=='org/app'
    result=dict(state='OPEN',headRefOid=p['head'],baseRefOid=p['base'],baseRefName='main',headRefName='task',mergeStateStatus='CLEAN')
elif endpoint=='graphql':
    assert 'owner=org' in args and 'name=app' in args
    result={'data':{'repository':{'pullRequest':{'reviewThreads':{'nodes':p['threads'],'pageInfo':{'hasNextPage':False}}}}}}
else:
    assert endpoint.startswith('repos/org/app/')
    if method in ('POST','PATCH'):
        if p.get('fail_write'): sys.exit(1)
        if endpoint.endswith('/check-runs') and not p.get('app_credential'):
            print('GitHub App credential required for check-run creation',file=sys.stderr)
            sys.exit(1)
        if endpoint.endswith('/replies'):
            roots={str(t['comments']['nodes'][0]['databaseId']) for t in p['threads'] if t['comments']['nodes']}
            if endpoint.split('/')[-2] not in roots:
                print('Replies must target the root review comment',file=sys.stderr)
                sys.exit(1)
        elif '/statuses/' in endpoint:
            assert method=='POST' and endpoint.endswith('/'+p['head'])
            assert body['state'] in ('error','failure','pending','success')
            assert len(body.get('description','')) <= 140
        elif endpoint.endswith('/check-runs'):
            assert method=='POST' and body['head_sha']==p['head']
        else:
            assert ((method=='POST' and endpoint=='repos/org/app/issues/9/comments') or
                    (method=='PATCH' and endpoint=='repos/org/app/issues/comments/42'))
            assert isinstance(body['body'],str)
        result={'id':42,'html_url':'https://github.com/org/app/pull/9#issuecomment-42'}
    elif '/protection/' in endpoint: result={'contexts':['drone'],'checks':[]}
    elif '/reviews?' in endpoint:
        page=int(endpoint.split('page=')[-1])
        pages=p.get('review_pages',[p['reviews']])
        result=pages[page-1] if page<=len(pages) else []
    elif '/issues/9/comments?' in endpoint: result=p['comments']
    elif '/check-runs?' in endpoint: result={'total_count':len(p['checks']),'check_runs':p['checks']}
    elif '/status?' in endpoint: result={'sha':p['head'],'statuses':p['statuses'],'total_count':len(p['statuses'])}
    else: raise AssertionError(args)
print(json.dumps(result))
