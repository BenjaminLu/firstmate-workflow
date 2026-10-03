"""Stack selection and operator-driven restacking; no automatic landing."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from fm_binding import command, git, github, remote_head, sha
from fm_conventions import read_policy


def deletable(repository, branch):
    try:
        rows = github(repository, 'pr', 'list', '--repo', repository,
                      '--state', 'open', '--base', branch, '--json', 'number')
        return isinstance(rows, list) and not rows
    except (ValueError, OSError):
        return False


def select_base(repository, base, dependencies, merged, allowed):
    pending = [dep for dep in dependencies if dep not in merged]
    if not pending:
        return {'name': base}
    if not allowed or len(pending) != 1:
        raise ValueError('task waits for dependencies; stacking needs one unmerged dependency and allowed policy')
    dep = pending[0].lower()
    prs = github(repository, 'pr', 'list', '--repo', repository, '--state', 'open',
                 '--limit', '1000', '--json', 'number,headRefName,headRefOid,isCrossRepository')
    if not isinstance(prs, list) or len(prs) >= 1000:
        raise ValueError('open PR list is incomplete or invalid')
    matches = [pr for pr in prs if re.match(r'^' + re.escape(dep) + r'(?:-|$)', pr['headRefName'].lower())]
    if len(matches) != 1 or matches[0].get('isCrossRepository') is not False:
        raise ValueError('dependency has no unique same-repository open PR')
    pr = matches[0]
    return {'name': pr['headRefName'], 'head': sha(pr['headRefOid']), 'pr': pr['number']}


def pr_base(root, repository, pr):
    view = remote_head(repository, pr)
    name = view['baseRefName']
    git(root, 'check-ref-format', 'refs/heads/' + name)
    if name.startswith('-') or git(root, 'rev-parse', 'refs/heads/' + name) != view['baseRefOid']:
        raise ValueError('PR base is stale locally; synchronize before gates/review')
    return name


def release_parent(root, repository, branch, expected, policy):
    if not policy.get('delete_branch') or not deletable(repository, branch):
        return
    if branch in ('main', 'master', policy['base']) or not re.match(r'^(?:t|sk)-\d+(?:-|$)', branch, re.I):
        raise ValueError('refusing protected/non-task parent deletion')
    from urllib.parse import quote
    info = github(repository, 'api', 'repos/' + repository + '/branches/' + quote(branch, safe=''))
    if info.get('protected') is not False:
        raise ValueError('parent protection unknown or protected; retained')
    # A final downstream check immediately precedes the expected-head deletion.
    if not deletable(repository, branch):
        return
    git(root, 'push', '--force-with-lease=refs/heads/' + branch + ':' + sha(expected),
        'https://github.com/' + repository + '.git', ':refs/heads/' + branch)
    worktrees = git(root, 'worktree', 'list', '--porcelain')
    if 'branch refs/heads/' + branch + '\n' not in worktrees + '\n':
        # update-ref's old value check preserves unpublished local work.
        git(root, 'update-ref', '-d', 'refs/heads/' + branch, expected)


def restack(root, repository, pr, parent, expected, policy, scratch):
    if policy.get('force_with_lease') is not True or policy.get('stacking') != 'allowed':
        raise ValueError('restack requires confirmed stacking and force-with-lease policy')
    sha(expected)
    child = remote_head(repository, pr)
    branch = child['headRefName']
    if branch in ('main', 'master', 'HEAD', policy['base']) or not re.match(r'^(?:t|sk)-\d+(?:-|$)', branch, re.I):
        raise ValueError('protected or non-task branch cannot be restacked')
    git(root, 'check-ref-format', 'refs/heads/' + branch)
    if child['headRefOid'] != expected or git(root, 'rev-parse', 'refs/heads/' + branch) != expected:
        raise ValueError('task head changed; synchronize before restacking')
    parent_view = github(repository, 'pr', 'view', str(parent), '--repo', repository,
                         '--json', 'state,headRefName,headRefOid,baseRefName')
    if parent_view['state'] != 'MERGED' or child['baseRefName'] != parent_view['headRefName']:
        raise ValueError('parent must be the merged PR for the child base')
    target = parent_view['baseRefName']
    git(root, 'check-ref-format', 'refs/heads/' + target)
    if target.startswith('-') or target == branch:
        raise ValueError('invalid restack target')
    # Refuse unknown protection rather than treating private/404 as permission.
    from urllib.parse import quote
    info = github(repository, 'api', 'repos/' + repository + '/branches/' + quote(branch, safe=''))
    if info.get('protected') is not False:
        raise ValueError('task branch protection is unknown or protected')
    old_base = sha(parent_view['headRefOid'])
    url = 'https://github.com/' + repository + '.git'
    git(root, 'fetch', '--no-tags', url, 'refs/heads/' + target)
    new_base = sha(git(root, 'rev-parse', 'FETCH_HEAD'))
    git(root, 'fetch', '--no-tags', url, 'refs/pull/' + str(parent) + '/head')
    if git(root, 'rev-parse', 'FETCH_HEAD') != old_base:
        raise ValueError('merged parent head changed')
    # Never replay the parent's squash-merged commits onto its replacement.
    boundary = git(root, 'merge-base', old_base, expected)
    Path(scratch).mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='restack-', dir=scratch) as directory:
        tree = str(Path(directory) / 'tree')
        git(root, 'worktree', 'add', '--detach', tree, expected)
        try:
            git(tree, '-c', 'core.hooksPath=/dev/null', 'rebase', '--onto', new_base, boundary)
            head = sha(git(tree, 'rev-parse', 'HEAD'))
            current = remote_head(repository, pr)
            if current != child:
                raise ValueError('child moved during restack; nothing published')
            # A managed task worktree may stay, but never discard dirty work.
            attached = None
            for entry in git(root, 'worktree', 'list', '--porcelain').split('\n\n'):
                if 'branch refs/heads/' + branch in entry.splitlines():
                    attached = entry.splitlines()[0].removeprefix('worktree ')
                    owned_root = os.environ.get('FM_WORKTREES')
                    if not owned_root or Path(attached).resolve().parent != Path(owned_root).resolve():
                        raise ValueError('task branch checked out outside managed worktrees')
                    if git(attached, 'status', '--porcelain'):
                        raise ValueError('task worktree is dirty; retained without publication')
            # Publish first: if the push loses its lease, PR metadata is untouched.
            git(tree, 'push', '--force-with-lease=refs/heads/' + branch + ':' + expected,
                url, 'HEAD:refs/heads/' + branch)
            try:
                command([os.environ.get('FM_GH', 'gh'), 'pr', 'edit', str(pr), '--repo', repository, '--base', target])
            except (ValueError, OSError) as error:
                raise ValueError('task head published as ' + head + '; retarget to ' + target +
                                 ' failed; synchronize and finish retarget before review: ' + str(error)) from error
            now = remote_head(repository, pr)
            if now['headRefOid'] != head or now['baseRefName'] != target or now['baseRefOid'] != new_base:
                raise ValueError('remote moved after publication; synchronize and revalidate')
            if attached:
                if git(attached, 'status', '--porcelain') or git(attached, 'rev-parse', 'HEAD') != expected:
                    raise ValueError('remote updated but local tree changed; retained, synchronize before review')
                git(attached, 'checkout', '--detach', expected)
            git(root, 'update-ref', 'refs/heads/' + branch, head, expected)
            if attached:
                git(attached, 'checkout', branch)
            # Update only the tracking ref; never overwrite a local base's work.
            git(root, 'fetch', '--no-tags', url,
                'refs/heads/' + target + ':refs/remotes/origin/' + target)
            release = 'retained by policy or open dependents'
            try:
                release_parent(root, repository, parent_view['headRefName'], old_base, policy)
                release = 'retention policy applied'
            except (ValueError, OSError) as error:
                release = 'cleanup deferred: ' + str(error)
            return {'head': head, 'base': target, 'base_head': new_base, 'parent_cleanup': release,
                    'requires': 'synchronize local base; fresh review binding, CI and six gates'}
        finally:
            git(root, 'worktree', 'remove', '--force', tree)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['select', 'base', 'restack'])
    parser.add_argument('--task')
    parser.add_argument('--pr', type=int)
    parser.add_argument('--parent', type=int)
    parser.add_argument('--expected-head')
    args = parser.parse_args()
    root = os.environ['FM_TARGET_ROOT']
    repo = os.environ['FM_STACK_REPOSITORY']
    base = os.environ.get('FM_BASE', 'main')
    external = os.environ.get('FM_EXTERNAL') == '1'
    policy_path = Path(os.environ['FM_STATE_DIR']).parent / 'CONVENTIONS.md' if external else Path(root) / 'CONVENTIONS.md'
    policy = read_policy(policy_path, repo, base) if external or (policy_path.exists() and policy_path.stat().st_size) else {'stacking': 'hold', 'base': base}
    if args.action == 'base':
        print(pr_base(root, repo, args.pr))
    elif args.action == 'select':
        if not args.task or not re.fullmatch(r'(T|SK)-[0-9]+', args.task):
            raise ValueError('valid task required')
        task = json.loads((Path(os.environ['FM_TASKS_DIR']) / (args.task + '.json')).read_text())
        log = Path(os.environ['FM_STATE_DIR']) / 'events.jsonl'
        merged = set()
        if log.exists():
            for line in log.read_text().splitlines():
                row = json.loads(line)
                if row.get('type') == 'merged' and row.get('project', os.environ.get('FM_PROJECT')) == os.environ.get('FM_PROJECT'):
                    merged.add(row.get('task'))
        print(json.dumps(select_base(repo, base, task.get('depends_on', []), merged, policy['stacking'] == 'allowed')))
    else:
        if not args.pr or not args.parent or not args.expected_head:
            raise ValueError('restack requires --pr --parent --expected-head')
        child = remote_head(repo, args.pr)
        match = re.match(r'^((?:t|sk)-[0-9]+)(?:-|$)', child['headRefName'], re.I)
        if not match:
            raise ValueError('restack requires a task branch')
        state = Path(os.environ['FM_STATE_DIR'])
        (state / 'runs').mkdir(parents=True, exist_ok=True)
        # Same exclusion as fm-worker and cleanup. Kernel ownership ends on exit.
        with (state / 'runs' / ('.worker-' + match[1].upper() + '.lock')).open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise ValueError('task has a live worker; restack held') from error
            print(json.dumps(restack(root, repo, args.pr, args.parent, args.expected_head,
                                     policy, str(state / 'tmp'))))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print('fm-stack: ' + str(error), file=sys.stderr)
        sys.exit(65)
