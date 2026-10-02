"""Normalize real commit statuses for required-head review evidence."""
import json
import os
import subprocess
import sys


def status_runs(payload, sha):
    if payload.get('sha') != sha:
        return []
    latest = {}
    for status in payload.get('statuses', []):
        context = status['context']
        # GitHub returns descending updates; first is the latest for context.
        if context in latest:
            continue
        state = status['state']
        latest[context] = dict(id=status.get('id', 0), name=context, head_sha=sha,
                               status='in_progress' if state == 'pending' else 'completed',
                               conclusion=None if state == 'pending' else state,
                               details_url=status.get('target_url'), source='commit status')
    return list(latest.values())


def main():
    repository, sha, query = sys.argv[1:]
    gh = os.environ.get('FM_GH', 'gh')
    def get(endpoint):
        p = subprocess.run([gh, 'api', 'repos/' + repository + '/commits/' + sha + '/' + endpoint],
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=45)
        if p.returncode: raise ValueError('GitHub evidence unavailable: ' + p.stderr.strip())
        return json.loads(p.stdout)
    errors=[]
    try:
        runs=get('check-runs?'+query)['check_runs']
    except (ValueError,KeyError,OSError,subprocess.TimeoutExpired) as error:
        errors.append(str(error)); runs=[]
    try:
        runs.extend(status_runs(get('status?per_page=100'),sha))
    except (ValueError,KeyError,OSError,subprocess.TimeoutExpired) as error:
        errors.append(str(error))
    # An unreadable source is unknown, not a fabricated missing result.
    if errors and not runs:
        print('; '.join(errors),file=sys.stderr); return 1
    print(json.dumps({'check_runs':runs,'unavailable_sources':errors}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
