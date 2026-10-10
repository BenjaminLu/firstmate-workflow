"""Read-only estimate of branch updates and CI runs per merged self PR (T-278).

Reads GitHub only and prints JSON lines; writes nothing under state/ and
changes nothing on GitHub. A value GitHub cannot provide is null, never guessed.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import quote

sys.dont_write_bytecode = True
PAGE = 100
TASK = re.compile(r'^(?:[A-Za-z0-9._-]+/)?((?:t|sk)-[0-9]+)(?:-|$)', re.I)
UPDATE = re.compile(r"^Merge branch 'main' into ")


class Unavailable(ValueError):
    """GitHub did not answer this read completely."""


def api(endpoint):
    out = subprocess.run([os.environ.get('FM_GH', 'gh'), 'api', endpoint], stdin=subprocess.DEVNULL,
                         capture_output=True, text=True, timeout=120)
    if out.returncode:
        raise Unavailable(endpoint)
    try:
        return json.loads(out.stdout)
    except ValueError as error:
        raise Unavailable(endpoint) from error


def pages(endpoint, field=None):
    """Every page of a list endpoint; an incomplete read raises Unavailable."""
    rows, page = [], 1
    joiner = '&' if '?' in endpoint else '?'
    while True:
        data = api(f'{endpoint}{joiner}per_page={PAGE}&page={page}')
        chunk = data.get(field) if field and isinstance(data, dict) else data
        if not isinstance(chunk, list) or not all(isinstance(row, dict) for row in chunk):
            raise Unavailable(endpoint)
        rows.extend(chunk)
        if len(chunk) < PAGE:
            return rows
        page += 1


def merged_pulls(repository, last):
    """The newest `last` merged PRs by merged_at. merged_at <= updated_at, so once a
    page of updated-desc closed PRs is older than the last kept merge, none newer remain."""
    found, page = [], 1
    while True:
        chunk = api(f'repos/{repository}/pulls?state=closed&sort=updated&direction=desc'
                    f'&per_page={PAGE}&page={page}')
        if not isinstance(chunk, list) or not all(isinstance(row, dict) for row in chunk):
            raise Unavailable('merged PR list')
        found.extend(row for row in chunk if row.get('merged_at'))
        found.sort(key=lambda row: row['merged_at'], reverse=True)
        oldest = min((row.get('updated_at') or '' for row in chunk), default='')
        if len(chunk) < PAGE or (len(found) >= last and oldest < found[last - 1]['merged_at']):
            return found[:last]
        page += 1


def branch_updates(repository, number):
    try:
        commits = pages(f'repos/{repository}/pulls/{number}/commits')
    except Unavailable:
        return None
    if len(commits) >= 250:
        return None  # GitHub lists at most 250 PR commits; the count is unknown
    return sum(1 for row in commits
               if UPDATE.match(str((row.get('commit') or {}).get('message', '')).split('\n', 1)[0]))


def ci_runs(repository, branch):
    try:
        runs = pages(f'repos/{repository}/actions/runs?branch={quote(branch, safe="")}', 'workflow_runs')
    except Unavailable:
        return None, None
    unique = {}
    for run in runs:
        if run.get('head_branch') == branch and run.get('id') is not None:
            unique[run['id']] = run
    attempts = [run.get('run_attempt') for run in unique.values()]
    if not all(type(value) is int and value >= 1 for value in attempts):
        return len(unique), None
    return len(unique), sum(value - 1 for value in attempts)


def stacked(repository, pr, base):
    if (pr.get('base') or {}).get('ref') not in (None, base):
        return True
    try:
        timeline = pages(f'repos/{repository}/issues/{pr["number"]}/timeline')
    except Unavailable:
        return None
    return any(row.get('event') == 'base_ref_changed' for row in timeline)


def report(repository, last, base):
    for pr in merged_pulls(repository, last):
        branch = (pr.get('head') or {}).get('ref') or ''
        match = TASK.match(branch)
        runs, reruns = ci_runs(repository, branch) if branch else (None, None)
        print(json.dumps(dict(pr=pr['number'], task=match[1].upper() if match else None,
                              merged_at=pr['merged_at'],
                              branch_updates=branch_updates(repository, pr['number']),
                              ci_runs=runs, ci_reruns=reruns, stacked=stacked(repository, pr, base),
                              source='github-estimate')), flush=True)


def self_repository():
    """The self checkout's own origin; routed project settings are never consulted."""
    root = os.environ.get('FM_ROOT') or str(Path(__file__).resolve().parents[2])
    out = subprocess.run(['git', '-C', root, 'config', '--get', 'remote.origin.url'],
                         stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
    match = re.fullmatch(r'(?:https://github\.com/|git@github\.com:)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?',
                         out.stdout.strip())
    if out.returncode or not match:
        raise ValueError('self GitHub repository unavailable')
    return match[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['report'])
    parser.add_argument('--last', type=int, required=True)
    args = parser.parse_args()
    if os.environ.get('FM_EXTERNAL') == '1':
        raise ValueError('the merge report reads the self project only')
    if args.last < 1:
        raise ValueError('--last must be a positive integer')
    report(self_repository(), args.last, 'main')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print('fm-merge-metrics: ' + str(error), file=sys.stderr)
        sys.exit(65)
