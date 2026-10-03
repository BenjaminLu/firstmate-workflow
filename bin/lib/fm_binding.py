"""Outside-round source and GitHub bindings. Unknown evidence fails closed."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def command(argv, cwd=None):
    result = subprocess.run(argv, cwd=cwd, stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=120)
    if result.returncode:
        raise ValueError('binding command failed: ' + result.stderr.decode(errors='replace')[:500])
    return result.stdout


def git(root, *args):
    return command(['git', '-C', str(root), *args]).decode().strip()


def sha(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', value):
        raise ValueError('missing or invalid full head SHA')
    return value


def digest(data):
    return hashlib.sha256(data).hexdigest()


def change(root, head, base):
    sha(head); sha(base)
    git(root, 'merge-base', '--is-ancestor', base, head)
    diff = command(['git', '-C', str(root), 'diff-tree', '-r', '-p', '--no-renames', base, head])
    patch = subprocess.run(['git', 'patch-id', '--stable'], input=diff, capture_output=True, check=True).stdout.decode().split()
    files = command(['git', '-C', str(root), 'diff-tree', '-r', '--name-only', '-z', '--no-renames', base, head]).decode().split('\0')
    return dict(head=head, base=base, patch=patch[0] if patch else '', files=[f for f in files if f])


def source_binding(task, head, base, code):
    root = Path(os.environ['FM_TARGET_ROOT'])
    result = change(root, head, base)
    external = os.environ.get('FM_EXTERNAL') == '1'
    if external:
        spec = (Path(os.environ['FM_TASKS_DIR']) / (task + '.json')).read_bytes()
        contract = (Path(os.environ['FM_STATE_DIR']) / 'config.yaml').read_bytes()
        conventions = (Path(os.environ['FM_STATE_DIR']).parent / 'CONVENTIONS.md').read_bytes()
    else:
        # SK proposals are adopted into design/tasks by fm self-update --adopt,
        # then committed on the task branch just like T tasks. Never fall back
        # to a mutable state/skill-updates proposal or omit the spec hash.
        try:
            spec = command(['git', '-C', str(root), 'show', head + ':design/tasks/' + task + '.json'])
        except ValueError as error:
            raise ValueError('approved committed task spec required: design/tasks/' + task + '.json') from error
        if json.loads(spec).get('id') != task:
            raise ValueError('committed task spec identity mismatch')
        contract = command(['git', '-C', str(root), 'show', head + ':config.yaml'])
        conventions = b''
    engine = hashlib.sha256()
    for path in sorted((Path(code) / 'bin').rglob('*')):
        if path.is_file() and not path.is_symlink() and '__pycache__' not in path.parts:
            engine.update(str(path.relative_to(code)).encode() + b'\0' + hashlib.sha256(path.read_bytes()).digest())
    result.update(spec_sha256=digest(spec), contract_sha256=digest(contract),
                  conventions_sha256=digest(conventions), engine_sha256=engine.hexdigest())
    return result


def github(repository, *args):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('verified repository identity required')
    return json.loads(command([os.environ.get('FM_GH', 'gh'), *args]))


def remote_head(repository, pr):
    view = github(repository, 'pr', 'view', str(pr), '--repo', repository,
                  '--json', 'headRefOid,baseRefOid,baseRefName,headRefName,state')
    if view.get('state') != 'OPEN':
        raise ValueError('PR is not open')
    sha(view.get('headRefOid'))
    sha(view.get('baseRefOid'))
    return view


def authoritative(root, branch, repository, pr):
    view = remote_head(repository, pr)
    head = view['headRefOid']
    # Fetch the actual PR ref, never a caller-supplied remote/branch expression.
    if not re.fullmatch(r'[1-9][0-9]*', str(pr)):
        raise ValueError('invalid PR number')
    command(['git', '-C', str(root), 'fetch', '--no-tags',
             'https://github.com/' + repository + '.git', 'refs/pull/' + str(pr) + '/head'])
    if git(root, 'rev-parse', 'FETCH_HEAD') != head or git(root, 'rev-parse', branch + '^{commit}') != head:
        raise ValueError('authoritative PR head differs from fetched head or local task ref; refresh before accepting')
    verified_base(view, repository, root)
    now = remote_head(repository, pr)
    if now['headRefOid'] != head or now['baseRefName'] != view['baseRefName']:
        raise ValueError('PR head/base moved while verifying')
    return head


def required_checks(root, repository, pr, head):
    from fm_project_checks import status_runs
    view = remote_head(repository, pr)
    if view['headRefOid'] != head:
        raise ValueError('checks belong to stale head')
    verified_base(view, repository, root)
    if os.environ.get('FM_EXTERNAL') == '1':
        from fm_conventions import read_policy
        policy = read_policy(Path(os.environ['FM_STATE_DIR']).parent / 'CONVENTIONS.md', repository, os.environ.get('FM_BASE') or 'main')
        names = sorted(set(policy['required_checks'] + policy.get('analysers', [])))
    else:
        from urllib.parse import quote
        protection = github(repository, 'api', 'repos/' + repository + '/branches/' + quote(view['baseRefName'], safe='') + '/protection/required_status_checks')
        names = sorted(set(protection.get('contexts', []) + [c['context'] for c in protection.get('checks', [])]))
    if not names:
        raise ValueError('required checks are unknown')
    runs = github(repository, 'api', 'repos/' + repository + '/commits/' + head + '/check-runs?per_page=100')['check_runs']
    statuses = github(repository, 'api', 'repos/' + repository + '/commits/' + head + '/status?per_page=100')
    if statuses.get('sha') != head:
        raise ValueError('commit statuses belong to another head')
    runs += status_runs(statuses, head)
    results = []
    for name in names:
        matches = [r for r in runs if r.get('name') == name and r.get('head_sha') == head]
        # A context present in both APIs must pass in both; neither hides red.
        for source in ('check run', 'commit status'):
            subset = [r for r in matches if r.get('source', 'check run') == source]
            if subset:
                latest = max(subset, key=lambda r: r.get('id', 0))
                if latest.get('status') != 'completed' or latest.get('conclusion') not in ('success', 'neutral', 'skipped'):
                    raise ValueError('required check/status not green: ' + name)
                results.append(latest)
        if not matches:
            raise ValueError('required check/status missing: ' + name)
    if remote_head(repository, pr)['headRefOid'] != head:
        raise ValueError('PR head moved while reading checks')
    return results


def repository(root):
    configured = os.environ.get('FM_BINDING_REPOSITORY') or os.environ.get('GH_REPO')
    if configured:
        return configured
    remote = git(root, 'config', '--get', 'remote.origin.url')
    match = re.fullmatch(r'(?:https://github.com/|git@github.com:)([^/]+/[^/]+?)(?:\.git)?', remote)
    if not match:
        raise ValueError('cannot identify authoritative GitHub repository')
    return match[1]


def review_policy():
    if os.environ.get('FM_EXTERNAL') != '1':
        return 'fm'
    from fm_conventions import read_policy
    return read_policy(Path(os.environ['FM_STATE_DIR']).parent / 'CONVENTIONS.md')['review']


def external_review(store, root, repo, pr, head):
    """All named reviewers and their threads, separately from local fm finals."""
    from fm_conventions import read_policy
    from fm_external import collect
    policy = read_policy(Path(os.environ['FM_STATE_DIR']).parent / 'CONVENTIONS.md', repo)
    record = collect(store, root, repo, pr, head, policy)
    if not record['ready']:
        raise ValueError('external review not ready: ' + '; '.join(record['blockers']))
    return record


def review_identity(record):
    # Full receipts remain signed and verified by Store. Only external evidence
    # uses a decisive subset for readiness; fm final provenance is unchanged.
    if record.get('kind') == 'external-verdict':
        return record.get('readiness_signature', record['signature'])
    return record['signature']


def selected_review(store, root, repo, pr, head):
    policy = review_policy()
    external = external_review(store, root, repo, pr, head) if policy in ('external', 'both') else None
    if policy == 'external':
        return external, external
    records = store.verdicts()
    if not records or records[-1]['verdict'] != 'APPROVE':
        raise ValueError('no current local approval')
    return records[-1], external


def view_base(repo, pr):
    return verified_base(remote_head(repo, pr), repo)


def verified_base(view, repo=None, root=None):
    name = view['baseRefName']
    if not name or name.startswith('-'):
        raise ValueError('invalid authoritative base')
    root = root if root is not None else os.environ['FM_TARGET_ROOT']
    repo = repo or repository(root)
    # The PR's recorded base OID may lag behind its base branch's live tip.
    command(['git', '-C', str(root), 'fetch', '--no-tags',
             'https://github.com/' + repo + '.git', 'refs/heads/' + name])
    live_base = sha(git(root, 'rev-parse', 'FETCH_HEAD'))
    if git(root, 'rev-parse', name + '^{commit}') != live_base:
        raise ValueError('local base is stale; synchronize before accepting')
    return name


def local_gate_base(root, pr, project_base):
    # Individual local gates also work before a PR exists, or without an
    # origin. Full runs and gate 6 keep the strict authoritative binding.
    try:
        repo = repository(root)
        view = remote_head(repo, pr)
    except ValueError:
        return project_base
    if view['baseRefName'] == project_base:
        return project_base
    # Once a stacked PR is known, a stale parent must not fall back to main.
    return verified_base(view, repo)


def main():
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument('mode', choices=['base', 'local-gate-base', 'head', 'checks', 'ready', 'candidate', 'external-review'])
    p.add_argument('--project-base', default='main')
    p.add_argument('--task', required=True)
    p.add_argument('--pr', required=True)
    p.add_argument('--branch', default='')
    p.add_argument('--head', default='')
    p.add_argument('--gate-report', default='')
    args = p.parse_args()
    root = Path(os.environ['FM_TARGET_ROOT'])
    if args.mode == 'local-gate-base':
        print(local_gate_base(root, args.pr, args.project_base)); return
    repo = repository(root)
    if args.mode == 'base':
        print(view_base(repo, args.pr)); return
    if args.mode == 'head':
        print(authoritative(root, args.branch, repo, args.pr)); return
    head = sha(args.head)
    if remote_head(repo, args.pr)['headRefOid'] != head:
        raise ValueError('authoritative PR head moved; candidate is stale')
    from fm_evidence import Store
    store = Store(os.environ['FM_STATE_DIR'], os.environ['FM_EVIDENCE_PROJECT'], args.task)
    if args.mode == 'external-review':
        print(json.dumps(external_review(store, root, repo, args.pr, head))); return
    if args.mode == 'candidate':
        records = [r for r in store.records() if r['kind'] == 'readiness' and r['head'] == head and str(r.get('pr')) == args.pr and r.get('repository') == repo]
        if not records:
            raise ValueError('no signed six-gate readiness for candidate')
        record = records[-1]
        if record.get('gates') != [1,2,4,5,6,7] or not record.get('checks'):
            raise ValueError('candidate lacks all six gates and required checks')
        if required_checks(root, repo, args.pr, head) != record['checks']:
            raise ValueError('required check/status evidence changed; refresh gates')
        selected, external = selected_review(store, root, repo, args.pr, head)
        if review_identity(selected) != record['verdict_signature'] or (external and review_identity(external) != record.get('external_signature')):
            raise ValueError('candidate review superseded')
        reviewed = record['review']
        binding = reviewed.get('binding', {})
        current_base = git(root, 'merge-base', view_base(repo, args.pr), head)
        current = source_binding(args.task, head, current_base, Path(__file__).parents[2])
        for key in ('spec_sha256', 'contract_sha256', 'conventions_sha256', 'patch', 'files'):
            if current[key] != binding.get(key):
                raise ValueError('candidate source/contract changed: ' + key)
        print(json.dumps(record)); return
    checks = required_checks(root, repo, args.pr, head)
    if args.mode == 'checks':
        print(json.dumps(checks)); return
    report_path = Path(args.gate_report).resolve()
    if report_path.parent != (Path(os.environ['FM_STATE_DIR']) / 'gates').resolve():
        raise ValueError('trusted gate transcript required')
    report = report_path.read_text()
    if not report.startswith('HEAD:' + head + '\n') or re.search(r'^  x gate ', report, re.M):
        raise ValueError('gate transcript is red or belongs to another head')
    for number in (1,2,4,5,6,7):
        if not re.search(r'^  \+ gate ' + str(number) + ':', report, re.M):
            raise ValueError('gate transcript lacks gate ' + str(number))
    reviewed, external = selected_review(store, root, repo, args.pr, head)
    bound = reviewed.get('binding', {})
    current_base = git(root, 'merge-base', view_base(repo, args.pr), head)
    current = source_binding(args.task, head, current_base, Path(__file__).parents[2])
    if any(current[k] != bound.get(k) for k in ('patch', 'files', 'spec_sha256', 'contract_sha256', 'conventions_sha256')):
        raise ValueError('review changed after gate 7')
    if reviewed['head'] != head:
        git(root, 'merge-base', '--is-ancestor', reviewed['base'], current_base)
    record = store.append('readiness', reviewed['round'], 'firstmate', head, '',
                         pr=int(args.pr), repository=repo, gates=[1,2,4,5,6,7], checks=checks,
                         gate_report_sha256=digest(report.encode()),
                         verdict_signature=review_identity(reviewed), review=reviewed,
                         external_signature=review_identity(external) if external else None)
    print(json.dumps(record))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        import sys
        print('fm-binding: ' + str(error), file=sys.stderr)
        sys.exit(1)
