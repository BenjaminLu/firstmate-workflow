"""Pinned ownership and safety checks for a single external human PR."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from fm_spec_pins import Pins
import fm_binding as binding


def validate(value):
    if not isinstance(value, dict) or set(value) != {'pr', 'head', 'base'}:
        raise ValueError('adopt requires exactly pr, head and base')
    if type(value['pr']) is not int or value['pr'] <= 0:
        raise ValueError('adopt.pr must be a positive integer')
    if not isinstance(value['head'], str) or not re.fullmatch(r'[0-9a-fA-F]{40}|[0-9a-fA-F]{64}', value['head']):
        raise ValueError('adopt.head must be a full 40- or 64-hex commit')
    base = value['base']
    if (not isinstance(base, str) or not base or base.startswith('-')
            or any(c.isspace() for c in base) or any(c in base for c in ('..', '~', '^', ':', '\\'))):
        raise ValueError('adopt.base must be a valid branch name')
    return value


def authorized_spec(env, task):
    if env.get('FM_EXTERNAL') != '1' or not env.get('FM_TASKS_DIR') or not task:
        return None
    pin = Pins(env, task).resolve(if_present=True)
    if pin is not None:
        text = pin['snapshots']['spec']['text']
    else:
        try:
            text = (Path(env['FM_TASKS_DIR']) / (task + '.json')).read_text()
        except FileNotFoundError:
            return None
    spec = json.loads(text)
    if not isinstance(spec, dict):
        raise ValueError('adoption task spec must be an object')
    return spec


def adoption(env, task):
    if env.get('FM_EXTERNAL') != '1' or not env.get('FM_TASKS_DIR') or not task:
        return None
    spec = authorized_spec(env, task)
    return validate(spec['adopt']) if spec is not None and 'adopt' in spec else None


def scan(env):
    single, duplicates, errors, owners = {}, {}, {}, {}
    if env.get('FM_EXTERNAL') != '1' or not env.get('FM_TASKS_DIR'):
        return single, duplicates, errors
    for path in sorted(Path(env['FM_TASKS_DIR']).glob('*.json')):
        task = path.stem
        try:
            adopted = adoption(env, task)
            if adopted:
                owners.setdefault(adopted['pr'], []).append(task)
        except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
            errors[task] = str(error)
            # A broken pin must not silently release the PR named by the draft.
            try:
                raw = json.loads(path.read_text()).get('adopt', {})
                pr = raw.get('pr')
                if type(pr) is int and pr > 0:
                    duplicates.setdefault(pr, []).append('adoption unreadable for ' + task)
            except (ValueError, OSError, AttributeError, TypeError):
                pass
    for pr, tasks in owners.items():
        if pr in duplicates or len(tasks) > 1:
            duplicates.setdefault(pr, []).extend(tasks)
        else:
            single[pr] = tasks[0]
    return single, duplicates, errors


def duplicate_reason(tasks):
    return 'adopted by two tasks: ' + ', '.join(tasks)


def base_matches(view, adopt):
    if view.get('baseRefName') != adopt['base']:
        raise ValueError(f"adopted PR base changed from {adopt['base']} to {view.get('baseRefName')}; a new spec and A card are needed")


def pushed(rows, task, pr):
    return any(row.get('type') == 'commit_pushed' and row.get('task') == task
               and (row.get('data') or {}).get('adopt_pr') == pr for row in rows)


def check(view, adopt, task, env, git_root, pushed, open_heads):
    validate(adopt)
    if env.get('FM_EXTERNAL') != '1':
        raise ValueError('adopt is only supported for external projects')
    if view.get('state') != 'OPEN':
        raise ValueError('adopted PR must be open')
    if view.get('isCrossRepository') is not False:
        raise ValueError('fork PR adoption is refused')
    base_matches(view, adopt)
    if any(row.get('number') != adopt['pr'] and row.get('isCrossRepository') is False
           and row.get('headRefName') == adopt['base'] for row in open_heads):
        raise ValueError('stacked PR: adoption of a stacked PR is T-239')
    branch = view.get('headRefName')
    if not isinstance(branch, str) or not branch or branch in (adopt['base'], env.get('FM_BASE', 'main'), 'main', 'master'):
        raise ValueError('adopted PR head is a protected base branch')
    # Check both independently: a matching branch must not mask a wrong title.
    script = Path(__file__).resolve().parents[1] / 'fm-emit.sh'
    for head, title in ((branch, ''), ('', view.get('title', ''))):
        result = subprocess.run(['bash', '-c', '. "$1"; fm_task_of_pr "$2" "$3" || true',
                                 '_', str(script), head, title], env=env,
                                capture_output=True, text=True, timeout=120, check=True)
        owner = result.stdout.strip()
        if owner and owner != task:
            raise ValueError('adopted PR branch or title names another task: ' + owner)
    _, duplicates, _ = scan(env)
    if adopt['pr'] in duplicates:
        raise ValueError(duplicate_reason(duplicates[adopt['pr']]))
    if not pushed:
        try:
            binding.git(git_root, 'merge-base', '--is-ancestor', adopt['head'], binding.sha(view.get('headRefOid')))
        except ValueError as error:
            raise ValueError('approved adoption head is no longer an ancestor of the PR head') from error


def sync_base(root, repository, base):
    if base == (os.environ.get('FM_BASE') or 'main'):
        return
    remote = binding.fetch_ref(root, 'https://github.com/' + repository + '.git', 'refs/heads/' + base)
    ref = 'refs/heads/' + base
    found = subprocess.run(['git', '-C', str(root), 'rev-parse', '--verify', '--quiet', ref],
                           capture_output=True, text=True, timeout=120)
    if found.returncode not in (0, 1):
        raise ValueError('cannot read adopted base ref: ' + found.stderr.strip())
    old = found.stdout.strip() if found.returncode == 0 else ''
    if old == remote:
        return
    if old:
        try:
            binding.git(root, 'merge-base', '--is-ancestor', old, remote)
        except ValueError as error:
            raise ValueError('adopted base has unpublished local commits; synchronize by hand') from error
    binding.git(root, 'update-ref', ref, remote, old)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('task-of', 'check', 'pushed'))
    parser.add_argument('--pr', required=True, type=int)
    parser.add_argument('--task')
    parser.add_argument('--root')
    parser.add_argument('--pushed', action='store_true')
    args = parser.parse_args()
    if args.mode == 'task-of':
        single, duplicates, _ = scan(os.environ)
        if args.pr in duplicates:
            raise ValueError(duplicate_reason(duplicates[args.pr]))
        if args.pr in single:
            print(single[args.pr])
        return
    if args.mode == 'pushed':
        path = Path(os.environ['FM_STATE_DIR']) / 'events.jsonl'
        rows = []
        if path.exists():
            for line in path.read_text().splitlines():
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict) and row.get('project', 'firstmate-workflow') == os.environ.get('FM_PROJECT'):
                    rows.append(row)
        sys.exit(0 if pushed(rows, args.task, args.pr) else 1)
    adopt = adoption(os.environ, args.task)
    if not adopt or adopt['pr'] != args.pr:
        raise ValueError('PR does not match authorized adoption')
    repo = binding.repository(args.root)
    view = binding.github(repo, 'pr', 'view', str(args.pr), '--repo', repo, '--json',
                          'state,isCrossRepository,headRefName,headRefOid,baseRefName,title')
    open_heads = binding.github(repo, 'pr', 'list', '--repo', repo, '--state', 'open',
                               '--json', 'number,headRefName,isCrossRepository', '--limit', '1000')
    if len(open_heads) >= 1000:
        raise ValueError('complete open PR list required for adoption')
    check(view, adopt, args.task, dict(os.environ), args.root, args.pushed, open_heads)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print('fm-adopt: ' + str(error), file=sys.stderr)
        sys.exit(1)
