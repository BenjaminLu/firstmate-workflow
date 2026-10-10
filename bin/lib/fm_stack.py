"""Stack selection and operator-driven restacking; no automatic landing."""
import argparse
import fcntl
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from fm_binding import command, fetch_ref, transfer, git, github, remote_head, sha
from fm_conventions import read_policy
import fm_adopt

SELF_PROJECT = 'firstmate-workflow'
SELF_POLICY_TASK = 'T-278'
SELF_POLICY_KEYS = ('version', 'stacking', 'force_with_lease', 'captain_authorization')
HELD = {'stacking': 'hold', 'force_with_lease': False}
GLOB = re.compile(r'[*?\[]')


class ScopeUnavailable(ValueError):
    """An approved scope could not be read; the candidate is held."""

    def __init__(self, task):
        super().__init__('overlap check unavailable: ' + task)
        self.task = task


def static_prefix(pattern):
    parts = []
    for part in pattern.split('/'):
        if GLOB.search(part):
            break
        parts.append(part)
    return '/'.join(parts)


def entries_overlap(left, right):
    left_glob, right_glob = bool(GLOB.search(left)), bool(GLOB.search(right))
    if not left_glob and not right_glob:
        return left == right
    if left_glob and right_glob:
        short, long = sorted((static_prefix(left), static_prefix(right)), key=len)
        return not short or short == long or long.startswith(short + '/')
    literal, pattern = (left, right) if right_glob else (right, left)
    return fnmatch.fnmatchcase(literal, pattern)


def scopes_overlap(left, right):
    """True when any entry of one approved scope list can name a path of the other."""
    return any(entries_overlap(a, b) for a in left for b in right)


def approved_scope(env, task):
    """The scope of the task's approved spec bytes, never the mutable task file.

    A pin's spec snapshot wins; before the first pin an approval must exist and
    the prospective snapshot is collected. Anything else is unreadable.
    """
    try:
        from fm_spec_pins import Pins
        pins = Pins(env, task)
        pin = pins.resolve(if_present=True)
        if pin:
            text = pin['snapshots']['spec']['text']
        else:
            if pins.approval(None) is None:
                raise ValueError('no approval')
            text = pins.collect()[2]['spec']['text']
        scope = json.loads(text)['scope']
        if not isinstance(scope, list) or not scope or not all(isinstance(s, str) and s for s in scope):
            raise ValueError('invalid approved scope')
        return list(scope)
    except Exception as error:  # Any failure holds; it never widens to the task file.
        raise ScopeUnavailable(task) from error


def task_order(task):
    """Numeric IDs by number first, then any other pin-valid ID in plain string order."""
    match = re.fullmatch(r'[A-Za-z]+-([0-9]+)', task)
    return (0, int(match[1]), task) if match else (1, 0, task)


def in_flight(events, exclude=None):
    """Tasks with a dispatched or pr_opened event and no later merged or closed, with any PR number."""
    flight = {}
    for event in events:
        task, kind = event.get('task'), event.get('type')
        if not isinstance(task, str) or not task or task == exclude:
            continue
        if kind in ('dispatched', 'pr_opened'):
            number = event.get('pr')
            if kind == 'pr_opened' and type(number) is int and number > 0:
                flight[task] = number
            else:
                flight.setdefault(task, None)
        elif kind in ('merged', 'closed'):
            flight.pop(task, None)
    return flight


def merged_tasks(events):
    return {e.get('task') for e in events if e.get('type') == 'merged'}


def overlap_members(env, task, dependencies, events, reserved=()):
    """None when the candidate overlaps nothing in flight; otherwise the sorted set C.

    C is the overlapped in-flight tasks plus the unmerged dependencies, each
    with its PR number from the event log (None: no PR yet). No GitHub call.
    """
    flight = in_flight(events, exclude=task)
    for other in reserved:
        if other != task:
            flight.setdefault(other, None)
    if not flight:
        return None
    mine = approved_scope(env, task)
    overlapped = [other for other in flight if scopes_overlap(mine, approved_scope(env, other))]
    if not overlapped:
        return None
    merged = merged_tasks(events)
    members = set(overlapped) | {dep for dep in dependencies if dep not in merged}
    return [(member, flight.get(member)) for member in sorted(members, key=task_order)]


def describe(members):
    return ', '.join(member + (f' (PR #{number})' if number else ' (no PR yet)') for member, number in members)


def overlap_hold(members, allowed):
    """The hold reason that needs no GitHub read, or None when a parent must be chosen."""
    if not allowed or len(members) != 1 or members[0][1] is None:
        return 'overlaps ' + describe(members)
    return None


def overlap_parent(repository, base, member):
    """The single overlapped member's open PR, when it is based on the base branch."""
    task, number = member
    try:
        prs = github(repository, 'pr', 'list', '--repo', repository, '--state', 'open', '--limit', '1000',
                     '--json', 'number,headRefName,headRefOid,isCrossRepository,baseRefName')
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise ValueError('open PR list unavailable') from error
    if not isinstance(prs, list) or len(prs) >= 1000:
        raise ValueError('open PR list unavailable')
    matches = [pr for pr in prs if isinstance(pr, dict) and pr.get('number') == number]
    branch = re.sub(r'^[A-Za-z0-9._-]+/', '', str((matches or [{}])[0].get('headRefName', '')).lower(), count=1)
    if (len(matches) != 1 or matches[0].get('isCrossRepository') is not False
            or not re.match(r'^' + re.escape(task.lower()) + r'(?:-|$)', branch)):
        raise ValueError(f'overlaps {task} (PR #{number} is not its open same-repository PR)')
    pr = matches[0]
    if pr.get('baseRefName') != base:
        raise ValueError(f'waits for stacked PR #{number} to reach {base}')
    return {'name': pr['headRefName'], 'head': sha(pr['headRefOid']), 'pr': number}


def same_project(event, project):
    mine = project or ''
    theirs = event.get('project') or ''
    return theirs == mine or {theirs, mine} <= {'', SELF_PROJECT}


def self_policy_path(state):
    return Path(state) / 'autopilot' / 'self-stack-policy.json'


# Each problem is (identity, English, Traditional Chinese); no file text is echoed
# beyond a sanitized key name.
def policy_problems(data):
    if not isinstance(data, dict):
        return [('not-object', 'the file is not a JSON object', '檔案不是 JSON 物件')]
    problems = []
    for name in sorted(set(data) - set(SELF_POLICY_KEYS)):
        shown = re.sub(r'[^A-Za-z0-9_-]', '?', str(name))[:40]
        problems.append(('unknown-' + shown, 'unknown key ' + shown, '未知的鍵 ' + shown))
    for name in SELF_POLICY_KEYS:
        if name not in data:
            problems.append(('missing-' + name, 'missing key ' + name, '缺少鍵 ' + name))
    if 'version' in data and not (type(data['version']) is int and data['version'] == 1):
        problems.append(('version', 'version must be the integer 1', 'version 必須是整數 1'))
    if 'stacking' in data and data['stacking'] not in ('allowed', 'hold'):
        problems.append(('stacking', 'stacking must be "allowed" or "hold"', 'stacking 必須是 "allowed" 或 "hold"'))
    if 'force_with_lease' in data and type(data['force_with_lease']) is not bool:
        problems.append(('force_with_lease', 'force_with_lease must be a boolean', 'force_with_lease 必須是布林值'))
    authorization = data.get('captain_authorization')
    if 'captain_authorization' in data and not (isinstance(authorization, str)
                                                and re.fullmatch(r'[A-Za-z0-9_-]+', authorization)):
        problems.append(('captain_authorization', 'captain_authorization must be a decision id string',
                         'captain_authorization 必須是決策編號字串'))
    return problems


def read_self_policy(state):
    """(fields, problems). fields is None when the file is absent (today's behaviour);
    an invalid file yields stacking hold and force_with_lease false with its problems."""
    path = self_policy_path(state)
    if path.is_symlink() or path.parent.is_symlink():
        return dict(HELD), [('symlink', 'the policy file is a symlink', '政策檔是符號連結')]
    if not path.exists():
        return None, []
    try:
        data = json.loads(path.read_bytes().decode('utf-8'))
    except (OSError, ValueError):
        return dict(HELD), [('json', 'the file is not readable JSON', '檔案不是可讀的 JSON')]
    problems = policy_problems(data)
    if problems:
        return dict(HELD), problems
    return {'stacking': data['stacking'], 'force_with_lease': data['force_with_lease']}, []


def self_policy(policy, state):
    """Apply the runtime file to the two fields it governs, and nothing else."""
    fields, problems = read_self_policy(state)
    for _, line, _ in problems:
        print('fm-stack: self stack policy invalid, stacking held: ' + line, file=sys.stderr)
    return dict(policy, **fields) if fields is not None else policy


def write_self_policy(state, events, decision, payload):
    """Write the runtime policy only from an answered captain A naming the payload's digest."""
    try:
        data = json.loads(payload.decode('utf-8'))
    except ValueError as error:
        raise ValueError('payload is not readable JSON') from error
    problems = policy_problems(data)
    if problems:
        raise ValueError('payload refused: ' + '; '.join(line for _, line, _ in problems))
    if data['captain_authorization'] != decision:
        raise ValueError('payload captain_authorization does not name the decision')
    from fm_spec_pins import readiness_card_approval
    state = Path(state)
    approval = readiness_card_approval(events, state, SELF_PROJECT, SELF_POLICY_TASK, decision)
    if approval is None:
        raise ValueError('decision is not an answered captain A choice card for ' + SELF_POLICY_TASK)
    digest = hashlib.sha256(payload).hexdigest()
    if digest not in json.dumps(approval['answer'].get('details'), ensure_ascii=False):
        raise ValueError('card details do not contain the payload SHA-256')
    path = self_policy_path(state)
    for item in (state, path.parent, path):
        if item.is_symlink():
            raise ValueError('refusing a symlinked policy path')
    if path.is_file() and path.read_bytes() == payload:
        return 'unchanged'
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.self-stack-policy.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(payload)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return 'written'


def lazy_repository():
    value = os.environ.get('FM_STACK_REPOSITORY')
    if not value:
        here = Path(__file__).resolve().parent
        out = subprocess.run(['bash', '-c', '. "$1/../fm-config.sh" && . "$1/fm-stack.sh" && fm_stack_repository',
                              '_', str(here)], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
        value = out.stdout.strip() if not out.returncode else ''
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', value or ''):
        raise ValueError('GitHub repository unavailable')
    return value


class RestackConflict(ValueError):
    """The rebase failed before publication."""


class RestackMoved(ValueError):
    """GitHub no longer has the expected child."""


class RestackStaleLocal(ValueError):
    """The local task ref does not match GitHub."""


class RestackPublished(ValueError):
    """The push succeeded but finishing requires reconciliation."""


class RestackPushUnknown(ValueError):
    """A push was attempted; its remote outcome is unknown."""


class RestackHeld(ValueError):
    """A live worker owns the task exclusion."""


def deletable(repository, branch):
    try:
        rows = github(repository, 'pr', 'list', '--repo', repository,
                      '--state', 'open', '--base', branch, '--json', 'number')
        return isinstance(rows, list) and not rows
    except (ValueError, OSError):
        return False


def select_base(repository, base, dependencies, merged, allowed, adopted=None):
    pending = [dep for dep in dependencies if dep not in merged]
    if not pending:
        return {'name': base}
    if not allowed or len(pending) != 1:
        raise ValueError('task waits for dependencies; stacking needs one unmerged dependency and allowed policy')
    if callable(repository):
        # Resolved only once a parent must be read from GitHub (T-278).
        repository = repository()
    dep = pending[0].lower()
    prs = github(repository, 'pr', 'list', '--repo', repository, '--state', 'open',
                 '--limit', '1000', '--json', 'number,headRefName,headRefOid,isCrossRepository')
    if not isinstance(prs, list) or len(prs) >= 1000:
        raise ValueError('open PR list is incomplete or invalid')
    matches = [pr for pr in prs if pr.get('number') == (adopted or {}).get(pending[0])
               and pr.get('isCrossRepository') is False]
    if not matches:
        matches = [pr for pr in prs if re.match(
            r'^' + re.escape(dep) + r'(?:-|$)',
            re.sub(r'^[A-Za-z0-9._-]+/', '', pr['headRefName'].lower(), count=1))]
    if len(matches) != 1 or matches[0].get('isCrossRepository') is not False:
        raise ValueError('dependency has no unique same-repository open PR')
    pr = matches[0]
    return {'name': pr['headRefName'], 'head': sha(pr['headRefOid']), 'pr': pr['number']}


def release_parent(root, repository, branch, expected, policy, adopted_branch=False):
    if not policy.get('delete_branch') or not deletable(repository, branch):
        return
    if branch in ('main', 'master', policy['base']) or (not adopted_branch and not re.match(r'^(?:[A-Za-z0-9._-]+/)?(?:t|sk)-\d+(?:-|$)', branch, re.I)):
        raise ValueError('refusing protected/non-task parent deletion')
    from urllib.parse import quote
    info = github(repository, 'api', 'repos/' + repository + '/branches/' + quote(branch, safe=''))
    if info.get('protected') is not False:
        raise ValueError('parent protection unknown or protected; retained')
    # A final downstream check immediately precedes the expected-head deletion.
    if not deletable(repository, branch):
        return
    transfer(root, 'push', '--force-with-lease=refs/heads/' + branch + ':' + sha(expected),
        'https://github.com/' + repository + '.git', ':refs/heads/' + branch)
    worktrees = git(root, 'worktree', 'list', '--porcelain')
    if 'branch refs/heads/' + branch + '\n' not in worktrees + '\n':
        # update-ref's old value check preserves unpublished local work.
        git(root, 'update-ref', '-d', 'refs/heads/' + branch, expected)


def adopted_child(pr):
    owners, duplicates, _ = fm_adopt.scan(os.environ)
    if pr in duplicates:
        raise ValueError(fm_adopt.duplicate_reason(duplicates[pr]))
    task = owners.get(pr)
    adopt = fm_adopt.pinned_adoption(os.environ, task) if task else None
    if task and not adopt:
        raise ValueError("adoption not pinned; restack needs the captain's A")
    return task, adopt


def child_view(repository, pr, task, adopt):
    if not adopt:
        return remote_head(repository, pr)
    view = github(repository, 'pr', 'view', str(pr), '--repo', repository,
                  '--json', 'headRefOid,baseRefOid,baseRefName,headRefName,state,isCrossRepository,title')
    fm_adopt.safety(view, adopt, task, os.environ)
    sha(view.get('headRefOid'))
    sha(view.get('baseRefOid'))
    return view


def restack(root, repository, pr, parent, expected, policy, scratch):
    if policy.get('force_with_lease') is not True or policy.get('stacking') != 'allowed':
        raise ValueError('restack requires confirmed stacking and force-with-lease policy')
    sha(expected)
    task, adopt = adopted_child(pr)
    child = child_view(repository, pr, task, adopt)
    branch = child['headRefName']
    if branch in ('main', 'master', 'HEAD', policy['base']) or (not adopt and not re.match(r'^(?:[A-Za-z0-9._-]+/)?(?:t|sk)-\d+(?:-|$)', branch, re.I)):
        raise ValueError('protected or non-task branch cannot be restacked')
    git(root, 'check-ref-format', 'refs/heads/' + branch)
    if child['headRefOid'] != expected:
        raise RestackMoved('task head changed on GitHub; synchronize before restacking')
    try:
        local = git(root, 'rev-parse', 'refs/heads/' + branch)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        if not adopt or git(root, 'for-each-ref', '--format=%(refname)', 'refs/heads/' + branch):
            raise RestackStaleLocal('local task ref is not the expected head; synchronize before restacking') from error
        fetched = fetch_ref(root, 'https://github.com/' + repository + '.git', 'refs/pull/' + str(pr) + '/head')
        if fetched != expected:
            raise RestackMoved('fetched child head differs from expected head')
        git(root, 'update-ref', 'refs/heads/' + branch, expected, '')
        local = expected
    if local != expected:
        raise RestackStaleLocal('local task ref is not the expected head; synchronize before restacking')
    parent_view = github(repository, 'pr', 'view', str(parent), '--repo', repository,
                         '--json', 'state,headRefName,headRefOid,baseRefName,isCrossRepository,title')
    if adopt and (parent_view.get('isCrossRepository') is not False or
                  fm_adopt.task_of(dict(parent_view, number=parent), os.environ) not in
                  (fm_adopt.authorized_spec(os.environ, task) or {}).get('depends_on', [])):
        raise ValueError('adopted parent must be a same-repository dependency')
    if adopt and parent_view['headRefName'] != adopt['base']:
        raise ValueError(f'parent #{parent} is not the adopted base')
    if adopt and not fm_adopt.pushed(fm_adopt.event_rows(os.environ), task, pr):
        try:
            git(root, 'merge-base', '--is-ancestor', adopt['head'], expected)
        except ValueError as error:
            raise ValueError('approved adoption head is no longer an ancestor') from error
    if parent_view['state'] != 'MERGED' or (child['baseRefName'] != parent_view['headRefName']
            and not (adopt and child['baseRefName'] == parent_view['baseRefName'])):
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
    new_base = fetch_ref(root, url, 'refs/heads/' + target)
    if fetch_ref(root, url, 'refs/pull/' + str(parent) + '/head') != old_base:
        raise ValueError('merged parent head changed')
    # Never replay the parent's squash-merged commits onto its replacement.
    boundary = git(root, 'merge-base', old_base, expected)
    Path(scratch).mkdir(parents=True, exist_ok=True)
    directory = tempfile.mkdtemp(prefix='restack-', dir=scratch)
    try:
        tree = str(Path(directory) / 'tree')
        git(root, 'worktree', 'add', '--detach', tree, expected)
        push_attempted = False
        result = None
        try:
            rebase = subprocess.run(['git', '-C', tree, '-c', 'core.hooksPath=/dev/null',
                                     'rebase', '--onto', new_base, boundary],
                                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
            if rebase.returncode:
                line = next((line.strip() for line in reversed(rebase.stderr.splitlines()) if line.strip()),
                            'command failed')
                raise RestackConflict('rebase conflict restacking onto ' + target + ': ' + line)
            head = sha(git(tree, 'rev-parse', 'HEAD'))
            current = child_view(repository, pr, task, adopt)
            if current != child:
                raise RestackMoved('child moved during restack; nothing published')
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
            # A failed push is ambiguous: the remote may already have accepted it.
            push_attempted = True
            try:
                transfer(tree, 'push', '--force-with-lease=refs/heads/' + branch + ':' + expected,
                    url, 'HEAD:refs/heads/' + branch)
            except (ValueError, OSError, subprocess.SubprocessError) as error:
                raise RestackPushUnknown('push outcome unknown for ' + branch +
                                         ' (expected old head ' + expected + '): ' + str(error)) from error
            try:
                try:
                    if child['baseRefName'] != target:
                        command([os.environ.get('FM_GH', 'gh'), 'pr', 'edit', str(pr), '--repo', repository, '--base', target])
                except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
                    raise ValueError('retarget to ' + target +
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
                transfer(root, 'fetch', '--no-tags', url,
                    'refs/heads/' + target + ':refs/remotes/origin/' + target)
                release = 'retained by policy or open dependents'
                try:
                    parent_task = fm_adopt.scan(os.environ)[0].get(parent)
                    parent_adopt = fm_adopt.pinned_adoption(os.environ, parent_task) if parent_task else None
                    release_parent(root, repository, parent_view['headRefName'], old_base, policy,
                                   adopted_branch=bool(parent_adopt))
                    release = 'retention policy applied'
                except (ValueError, OSError) as error:
                    release = 'cleanup deferred: ' + str(error)
                result = {'head': head, 'base': target, 'base_head': new_base, 'parent_cleanup': release,
                          'requires': 'synchronize local base; fresh review binding, CI and six gates'}
                if adopt:
                    result.update(task=task, adopt_pr=pr)
                return result
            except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
                raise RestackPublished('task head published as ' + head + '; ' + str(error)) from error
        finally:
            pending = sys.exc_info()[1]
            try:
                git(root, 'worktree', 'remove', '--force', tree)
            except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
                if not push_attempted:
                    raise
                if isinstance(pending, (RestackPublished, RestackPushUnknown)):
                    pending.args = (str(pending) + '; tree cleanup failed: ' + str(error),)
                elif result is not None:
                    result['tree_cleanup'] = str(error)
    finally:
        shutil.rmtree(directory, ignore_errors=True)


def read_events(state):
    log = Path(state) / 'events.jsonl'
    rows = [json.loads(line) for line in log.read_text().splitlines() if line.strip()] if log.exists() else []
    return [row for row in rows if isinstance(row, dict)]


def select(args, base, policy, external):
    # The worker's own task grammar: every self worker without a PR asks (T-278).
    if not args.task or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', args.task):
        raise ValueError('valid task required')
    task = json.loads((Path(os.environ['FM_TASKS_DIR']) / (args.task + '.json')).read_text())
    project = os.environ.get('FM_PROJECT')
    if external:
        events = [row for row in read_events(os.environ['FM_STATE_DIR'])
                  if row.get('project', project) == project]
    else:
        events = [row for row in read_events(os.environ['FM_STATE_DIR']) if same_project(row, project)]
    merged = merged_tasks(events)
    dependencies = task.get('depends_on', [])
    allowed = policy['stacking'] == 'allowed'
    if not external:
        # T-278: an approved-scope overlap with work in flight is held or stacked.
        members = overlap_members(os.environ, args.task, dependencies, events)
        if members is not None:
            reason = overlap_hold(members, allowed)
            if reason:
                raise ValueError(reason)
            return overlap_parent(lazy_repository(), base, members[0])
    return select_base(lazy_repository, base, dependencies, merged, allowed,
                       adopted={task: pr for pr, task in fm_adopt.scan(os.environ)[0].items()})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['select', 'restack', 'policy', 'self-policy'])
    parser.add_argument('--task')
    parser.add_argument('--pr', type=int)
    parser.add_argument('--parent', type=int)
    parser.add_argument('--expected-head')
    parser.add_argument('--field', choices=['stacking', 'force_with_lease'])
    parser.add_argument('--decision')
    parser.add_argument('--payload')
    args = parser.parse_args()
    external = os.environ.get('FM_EXTERNAL') == '1'
    if args.action == 'self-policy':
        if external:
            raise ValueError('self-policy is for the self project only')
        if not args.decision or not args.payload:
            raise ValueError('self-policy requires --decision and --payload')
        engine = os.environ.get('FM_ROOT') or str(Path(__file__).resolve().parents[2])
        state = Path(os.environ.get('FM_STATE_DIR') or Path(engine) / 'state')
        payload = Path(args.payload).read_bytes()
        events = [row for row in read_events(state) if same_project(row, SELF_PROJECT)]
        print('fm-stack: self stack policy ' + write_self_policy(state, events, args.decision, payload))
        return
    if args.action == 'policy':
        if external or not args.field:
            raise ValueError('policy reads a self field: --field stacking|force_with_lease')
        fields = self_policy(dict(HELD), os.environ['FM_STATE_DIR'])
        value = fields[args.field]
        print(str(value).lower() if isinstance(value, bool) else value)
        return
    root = os.environ['FM_TARGET_ROOT']
    base = os.environ.get('FM_BASE') or 'main'
    policy_path = Path(os.environ['FM_STATE_DIR']).parent / 'CONVENTIONS.md' if external else Path(root) / 'CONVENTIONS.md'
    if external or (policy_path.exists() and policy_path.stat().st_size):
        policy = read_policy(policy_path, lazy_repository(), base)
    else:
        policy = {'stacking': 'hold', 'base': base}
    if not external:
        policy = self_policy(policy, os.environ['FM_STATE_DIR'])
    if args.action == 'select':
        print(json.dumps(select(args, base, policy, external)))
    else:
        if policy.get('force_with_lease') is not True or policy.get('stacking') != 'allowed':
            raise ValueError('restack requires confirmed stacking and force-with-lease policy')
        if not args.pr or not args.parent or not args.expected_head:
            raise ValueError('restack requires --pr --parent --expected-head')
        repo = lazy_repository()
        child = remote_head(repo, args.pr)
        match = re.match(r'^(?:[A-Za-z0-9._-]+/)?((?:t|sk)-[0-9]+)(?:-|$)', child['headRefName'], re.I)
        task, adopt = adopted_child(args.pr)
        if not match and not adopt:
            raise ValueError('restack requires a task branch')
        task = task or match[1].upper()
        state = Path(os.environ['FM_STATE_DIR'])
        (state / 'runs').mkdir(parents=True, exist_ok=True)
        # Same exclusion as fm-worker and cleanup. Kernel ownership ends on exit.
        with (state / 'runs' / ('.worker-' + task + '.lock')).open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise RestackHeld('task has a live worker; restack held') from error
            result = restack(root, repo, args.pr, args.parent, args.expected_head,
                             policy, str(state / 'tmp'))
            try:
                print(json.dumps(result), flush=True)
            except OSError as error:
                raise RestackPublished('restack published; result output failed: ' + str(error)) from error


if __name__ == '__main__':
    try:
        main()
    except (RestackConflict, RestackMoved, RestackStaleLocal, RestackPublished,
            RestackPushUnknown, RestackHeld) as error:
        print('fm-stack: ' + str(error), file=sys.stderr)
        sys.exit({RestackConflict: 66, RestackMoved: 67, RestackStaleLocal: 68,
                  RestackPublished: 69, RestackPushUnknown: 71, RestackHeld: 75}[type(error)])
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print('fm-stack: ' + str(error), file=sys.stderr)
        sys.exit(65)
