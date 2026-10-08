#!/usr/bin/env python3
"""REST fixture boundary: a failed gh api still writes GitHub JSON to stdout.

Payloads use placeholder ids, heads and URLs; they are not verbatim captures.
"""
import json
import os
from pathlib import Path
import sys
root = Path(__file__).parent
assert sys.argv[1] == 'api', sys.argv
endpoint = sys.argv[2]
assert endpoint.startswith('repos/example-org/example-repo'), endpoint
with open(os.environ['ONBOARD_GH_LOG'], 'a') as log:
    log.write(endpoint + '\n')
def payload(name):
    return json.loads((root / (name + '.json')).read_text())
if endpoint == 'repos/example-org/example-repo':
    result = payload('repository')
    if os.environ.get('ONBOARD_DRIFT'): result['delete_branch_on_merge'] = True
elif '/protection' in endpoint or '/contents/' in endpoint:
    print('{"message":"Not Found","status":"404"}')
    print('gh: Not Found (HTTP 404)', file=sys.stderr)
    sys.exit(1)
elif '/pulls?' in endpoint: result = payload('pulls')
elif endpoint.endswith('/reviews?per_page=100'): result = payload('reviews')
elif endpoint.endswith('/pulls/164'): result = dict(payload('pulls')[0], merged_by={'login':'maintainer','type':'User'}, comments=3, review_comments=2)
elif '/status?' in endpoint: result = payload('status')
elif '/check-runs?' in endpoint: result = {'check_runs': []}
elif '/comments?' in endpoint: result = []
elif endpoint.endswith('/languages'): result = {'TypeScript':100}
else: raise AssertionError(endpoint)
print(json.dumps(result))
