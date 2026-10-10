"""Project-local preparation, global owned capacity and project merge turns.

Slow registry/verification/readiness work precedes the short allocation lock.
Only routing and live identity metadata cross project boundaries in memory.
"""
import argparse
from collections import Counter
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
CODE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('concurrent_managed', CODE / 'fm-herdr.py')
managed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(managed)
merge_spec = importlib.util.spec_from_file_location('fm_merge_outcome', CODE / 'lib/fm_merge_outcome.py')
merge_records = importlib.util.module_from_spec(merge_spec)
merge_spec.loader.exec_module(merge_records)


def shell(root, script, project='', *args):
    env = dict(os.environ, FM_ROOT=str(root), FM_PROJECT=project)
    # A prior project's resolved paths are not routing authority.
    for key in ('FM_EXTERNAL', 'FM_STATE_DIR', 'FM_TARGET_ROOT', 'FM_BASE'):
        env.pop(key, None)
    out = subprocess.run(['bash', '-c', '. "$1/fm-config.sh"; cd "$2" || exit 65; '
                          + script, '_', str(CODE), str(root), *args],
                         env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if out.returncode:
        raise ValueError(out.stderr.strip() or out.stdout.strip() or 'project preparation failed')
    return out.stdout


def routes(root):
    names = shell(root, 'fm_projects "$2/config.yaml"').splitlines() or ['']
    result = []
    for name in names:
        data = shell(root, '''fm_storage_init "$2" || exit 65
jq -n --arg name "${FM_PROJECT:-}" --arg state "$FM_STATE_DIR" \
 --arg tasks "$FM_TASKS_DIR" --arg target "$FM_TARGET_ROOT" --arg external "$FM_EXTERNAL" \
 --arg engine "$FM_ENGINE_ROOT" --arg design "$FM_DESIGN" --arg base "${FM_BASE:-main}" \
 '{name:$name,state:$state,tasks:$tasks,target:$target,external:$external,engine:$engine,design:$design,base:$base}' ''', name)
        result.append(json.loads(data))
    return result


def project_events(events, name, default):
    return [e for e in events if (e.get('project') or default) == name]


def read_events(route, default):
    path = Path(route['state']) / 'events.jsonl'
    if not path.exists():
        return []
    return project_events([json.loads(line) for line in path.read_text().splitlines() if line.strip()],
                          route['name'], default)


def live_rounds(projects):
    """Receipts bridge spawn to identity allocation, then the owned run wins.

    Completed launcher receipts never reserve capacity. No event or PR count
    appears here. More than one actual round of a task counts more than once.
    """
    result = []
    for project in projects:
        state = Path(project['state'])
        seen = set()
        allocated = {}
        for identity in sorted((state / 'runs').glob('*/identity.json')):
            item = managed.read(identity)
            if item.get('role') not in ('worker', 'reviewer'):
                continue
            allocated[item['task']] = max(allocated.get(item['task'], -1), item.get('created', -1))
            process = identity.parent / 'process.json'
            launcher_live = process.is_file() and managed.process_matches(managed.read(process))
            if ((launcher_live and not (identity.parent / 'orchestration-result.json').exists())
                    or any(a['live'] for a in managed.executions(identity.parent))):
                item = dict(item, project=project['name'])
                result.append(item); seen.add(item['task'])
        for receipt in sorted((state / 'dispatch').glob('*.json')):
            item = managed.read(receipt)
            if item.get('task') in seen or allocated.get(item.get('task'), -1) >= receipt.stat().st_mtime:
                continue
            if managed.lifeline().owner_record_live(receipt.with_suffix('.owner')):
                result.append(dict(item, project=project['name']))
    return result


def fair_fill(queues, live, limit, admit=None):
    queues = {name: list(tasks) for name, tasks in queues.items()}
    busy = {(r['project'], r['task']) for r in live}
    counts = Counter(r['project'] for r in live)
    chosen = []
    while len(chosen) < max(0, limit - len(live)):
        available = {p: [t for t in ts if (p, t) not in busy] for p, ts in queues.items()}
        names = [p for p, ts in available.items() if ts]
        if not names:
            break
        name = min(names, key=lambda p: (counts[p], p))
        task = available[name][0]
        # A refused candidate takes no slot; the next one is offered instead.
        if admit is not None and not admit(name, task):
            queues[name].remove(task)
            continue
        chosen.append((name, task)); busy.add((name, task)); counts[name] += 1
    return chosen


def stack_library():
    here = str(Path(__file__).resolve().parent)
    if here not in sys.path:
        sys.path.insert(0, here)
    import fm_stack
    return fm_stack


def scope_env(route):
    """The pin reader's view of one self route; nothing here reads GitHub."""
    return dict(os.environ, FM_ENGINE_ROOT=route['engine'], FM_TARGET_ROOT=route['target'],
                FM_STATE_DIR=route['state'], FM_TASKS_DIR=route['tasks'], FM_DESIGN=route['design'],
                FM_PROJECT=route['name'], FM_EXTERNAL='0', FM_BASE=route.get('base') or 'main')


def overlap_check(route, task, dependencies, events, allowed, reserved=()):
    """(members, reason) for one self candidate; members None means no overlap."""
    stack = stack_library()
    if not stack.in_flight(events, exclude=task) and not [r for r in reserved if r != task]:
        return None, ''
    try:
        members = stack.overlap_members(scope_env(route), task, dependencies, events, reserved)
    except stack.ScopeUnavailable as error:
        return None, str(error)
    if members is None:
        return None, ''
    return members, stack.overlap_hold(members, allowed()) or ''


def prepare(root, route, default, ordered, notes=None):
    name = route['name']
    notes = {} if notes is None else notes
    notes.update(deps={}, stacked={}, allowed=None)
    def allowed():
        if notes['allowed'] is None:
            notes['allowed'] = shell(root, '''fm_storage_init "$2" || exit 65
. "$1/lib/fm-stack.sh"
fm_stack_policy stacking''', name).strip() == 'allowed'
        return notes['allowed']
    # Verification, task reads and greenlight are deliberately outside the lock.
    tasks = shell(root, '''fm_storage_init "$2" || exit 65
fm_external_prepare >&2 || exit 65
fm_tasks "$FM_TASKS_DIR"''', name)
    tasks = [json.loads(line) for line in tasks.splitlines() if line.strip()]
    if ordered and not any(t['id'] == ordered for t in tasks):
        raise ValueError('--task ' + ordered + ' has no file in ' + route['tasks'])
    events = read_events(route, default)
    greenlit = any(e.get('type') == 'greenlit' for e in events)
    carded = set()
    if not greenlit:
        # File-path imports of this coordinator need no pin dependencies until
        # dispatch actually checks card authority.
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from fm_spec_pins import readiness_card_approval
        carded = {t['id'] for t in tasks if readiness_card_approval(
            events, Path(route['state']), name or 'firstmate-workflow', t['id'])}
    if not greenlit and not carded:
        raise ValueError('no greenlit event - nothing is dispatched for ' + (name or 'self'))
    done = {e.get('task') for e in events if e.get('type') == 'merged'}
    closed = {e.get('task') for e in events if e.get('type') == 'closed'}
    # Historical work prevents automatic redispatch, but consumes no capacity.
    touched = {e.get('task') for e in events if e.get('type') in ('dispatched', 'pr_opened')}
    parks = {}
    for event in events:
        if event.get('type') in ('parked', 'unparked'):
            parks[event.get('task')] = event['type'] == 'parked'
    cleared = set()
    if not ordered:
        cleared = set(shell(root, '"$1/fm-ready.sh" cleared --repo "$2" ${FM_PROJECT:+--project "$FM_PROJECT"}', name).splitlines())
    eligible = []
    for task in tasks:
        task_id = task['id']
        if ordered and task_id != ordered:
            continue
        why = ''
        if task_id in done: why = 'is already merged'
        elif task_id in closed: why = 'is closed'
        elif task_id in touched: why = 'is already in flight'
        elif parks.get(task_id): why = 'is parked'
        elif not greenlit and task_id not in carded:
            why = 'has no greenlit event and no captain A card'
        else:
            unmet = [d for d in task.get('depends_on', []) if d not in done]
            members = None
            notes['deps'][task_id] = list(task.get('depends_on', []))
            # T-278: approved-scope overlap with self work in flight, no GitHub read.
            if route.get('external') != '1' and (ordered or task_id in cleared):
                members, why = overlap_check(route, task_id, notes['deps'][task_id], events, allowed)
                if members is not None and not why:
                    try:
                        shell(root, '''fm_storage_init "$2" || exit 65
. "$1/lib/fm-stack.sh"
fm_stack select --task "$3" >/dev/null''', name, task_id)
                    except ValueError as error:
                        why = str(error).splitlines()[-1].removeprefix('fm-stack: ')
                    else:
                        notes['stacked'][task_id] = members
                if why:
                    print('fm-dispatch: ' + task_id + ' ' + why, file=sys.stderr)
                    continue
            if unmet and members is None:
                try:
                    shell(root, '''fm_storage_init "$2" || exit 65
. "$1/lib/fm-stack.sh"
[ "$(fm_stack_policy stacking)" = allowed ] && fm_stack select --task "$3" >/dev/null''', name, task_id)
                except ValueError:
                    why = 'waits on ' + unmet[0]
            if not why and not ordered and task_id not in cleared:
                why = 'is ready but the captain has not cleared it'
        if why:
            if ordered or 'cleared' in why:
                print('fm-dispatch: ' + task_id + ' ' + why, file=sys.stderr)
        else:
            eligible.append(task_id)
    return eligible


def dispatch(root, selected, ordered, dry, limit):
    projects = routes(root)
    default = shell(root, 'fm_cfg default_project "$2/config.yaml"').strip()
    if not default:
        default = next((p['name'] for p in projects if p['external'] == '0'), '')
    if selected == 'firstmate-workflow' and projects[0]['name'] == '':
        selected = ''  # pre-registry explicit self compatibility
    names = {p['name'] for p in projects}
    if selected and selected not in names:
        raise ValueError('unknown project ' + selected)
    if ordered and not selected:
        selected = default
    queues = {}
    notes = {}
    for project in projects:
        if selected and project['name'] != selected:
            continue
        try:
            notes[project['name']] = {}
            queues[project['name']] = prepare(root, project, default, ordered, notes[project['name']])
        except ValueError as error:
            if selected or len(projects) == 1:
                raise
            print('fm-dispatch: ' + str(error), file=sys.stderr)
    limit = int(limit or shell(root, 'fm_cfg concurrency "$2/config.yaml"').strip() or 3)
    if limit < 1:
        raise ValueError('limit must be a positive integer')
    by_name = {p['name']: p for p in projects}
    # Allocation uses this same lock before its per-project identity lock.
    with managed.locked(Path(root) / 'state/dispatch.lock'):
        live = live_rounds(projects)
        locked_events = {}
        # Another dispatch may have reserved/started these while we prepared.
        for name in queues:
            locked_events[name] = read_events(by_name[name], default)
            touched = {e.get('task') for e in locked_events[name]
                       if e.get('type') in ('dispatched', 'pr_opened', 'merged', 'closed')}
            queues[name] = [task for task in queues[name] if task not in touched]
        reserved = {}
        def admit(name, task):
            # Recheck overlap against the locked log plus this run's earlier picks.
            route, note = by_name[name], notes.get(name, {})
            if route.get('external') == '1':
                return True
            earlier = reserved.setdefault(name, [])
            members, why = overlap_check(route, task, note.get('deps', {}).get(task, []),
                                         locked_events[name], lambda: bool(note.get('allowed')), earlier)
            if members is not None and not why and note.get('stacked', {}).get(task) != members:
                why = 'overlaps ' + stack_library().describe(members)
            if why:
                print('fm-dispatch: ' + task + ' ' + why, file=sys.stderr)
                return False
            earlier.append(task)
            return True
        selected_tasks = fair_fill(queues, live, limit, admit)
        if ordered and not selected_tasks and len(live) >= limit:
            print(f'fm-dispatch: {ordered} waits for a slot: {len(live)} in flight, limit {limit}', file=sys.stderr)
        for name, task in selected_tasks:
            if not dry:
                state = Path(by_name[name]['state'])
                (state / 'dispatch').mkdir(parents=True, exist_ok=True)
                owner = managed.lifeline().session_owner()
                env = dict(os.environ, FM_ROOT=str(root), FM_PROJECT=name)
                command = [str(CODE / 'fm-worker.sh'), '--task', task, '--repo', str(root)]
                if name: command += ['--project', name]
                receipt = state / 'dispatch' / (task + '.json')
                with (state / 'dispatch' / (task + '.log')).open('ab') as log:
                    keeper = managed.lifeline().start(command, owner=owner,
                        owner_record=receipt.with_suffix('.owner'), env=env,
                        stdin=subprocess.DEVNULL, stdout=log, stderr=log).pid
                # Keep the public four-key receipt and its observable atomic
                # rename boundary. Ownership lives in the keeper-held sidecar.
                fd, temporary = tempfile.mkstemp(prefix=task + '.', suffix='.json', dir=receipt.parent)
                try:
                    with os.fdopen(fd, 'w') as output:
                        json.dump(dict(project=name, task=task, owner=owner, keeper=keeper), output)
                        output.flush(); os.fsync(output.fileno())
                    subprocess.run(['mv', temporary, str(receipt)], check=True)
                finally:
                    Path(temporary).unlink(missing_ok=True)
                emit = [str(CODE / 'fm-emit.sh'), '--actor', 'firstmate',
                        '--type', 'dispatched', '--task', task,
                        '--en', 'Reserved a worker slot', '--tw', '已保留工作執行名額']
                if name: emit += ['--project', name]
                subprocess.run(emit, env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, check=True)
                # This is a short reservation, not the worker's canonical
                # lifecycle. Close its actor; the worker brackets its own run.
                emit[emit.index('dispatched')] = 'agent_finished'
                emit[emit.index('Reserved a worker slot')] = 'Worker slot handed to its owner'
                emit[emit.index('已保留工作執行名額')] = '工作執行名額已交由擁有者管理'
                subprocess.run(emit, env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, check=True)
            print(task, flush=True)
        if not selected_tasks:
            print('fm-dispatch: nothing is ready')
    return 0


def merge_blocker(state, project):
    state = Path(state)
    for folder in ('pending', 'decisions'):
        for path in sorted((state / folder).glob('*.json')):
            item = managed.read(path)
            if item.get('kind') not in ('merge', 'merge-untracked'):
                continue
            if item.get('project', project) != project:
                continue
            if folder == 'pending':
                return 'pending merge ' + item.get('id', path.stem)
            if item.get('chosen') == 'A' and merge_records.merge_outcome(item) not in ('merged', 'failed'):
                return 'running merge ' + item.get('id', path.stem)
    return ''


def merge_turn(args):
    # The child performs only card allocation/request; no gate runs in this lock.
    with managed.locked(Path(args.state) / 'merge-turn.lock'):
        current = subprocess.check_output(['git', '-C', args.target, 'rev-parse',
                                           args.base + '^{commit}'], text=True).strip()
        if current != args.expected_base:
            print('  ' + args.task + ': waits for a regate on the new base')
            return 0
        blocker = merge_blocker(args.state, args.project)
        if blocker:
            waiting = 'waiting on the captain; waits for ' if blocker.startswith('pending') else 'waits for '
            print('  ' + args.task + ': ' + waiting + blocker)
            return 0
        return subprocess.call(args.command, stdin=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='mode', required=True)
    d = sub.add_parser('dispatch')
    d.add_argument('--repo', required=True); d.add_argument('--project', default='')
    d.add_argument('--task', default=''); d.add_argument('--limit', default='')
    d.add_argument('--dry-run', action='store_true')
    m = sub.add_parser('merge-turn')
    for key in ('state', 'project', 'target', 'base', 'expected-base', 'task'):
        m.add_argument('--' + key, required=True)
    m.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.mode == 'dispatch':
        return dispatch(Path(args.repo).resolve(), args.project, args.task, args.dry_run, args.limit)
    if args.command[:1] == ['--']: args.command.pop(0)
    return merge_turn(args)


if __name__ == '__main__':
    try: sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print('fm-concurrent: ' + str(error), file=sys.stderr)
        sys.exit(65)
