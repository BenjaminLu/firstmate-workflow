"""Config tasks helpers extracted from fm-config.sh."""

import sys


def check():
    import json, sys
    from pathlib import Path

    d = Path(sys.argv[1])
    problems, tasks = [], {}
    legacy = d.parent / (d.name + '.json')
    if legacy.exists():
        problems.append('%s is still here: each entry belongs in its own file under %s/' % (legacy, d))
    if not d.is_dir():
        problems.append('%s is not a directory' % d)
        files = []
    else:
        files = sorted(d.iterdir())
    for f in files:
        # .DS_Store, an interrupted --adopt's scratch: not a task, as fm_tasks says
        if f.name.startswith('.'):
            continue
        if f.suffix != '.json' or not f.is_file():
            problems.append('%s: not a task file (<id>.json)' % f.name); continue
        try:
            task = json.loads(f.read_text())
        except (OSError, ValueError) as error:
            problems.append('%s: does not parse: %s' % (f.name, error)); continue
        if not isinstance(task, dict) or task.get('id') != f.stem:
            problems.append('%s: its id is %s, not %s' % (f.name, json.dumps(task.get('id') if isinstance(task, dict) else None), f.stem))
            continue
        if 'explain' in task:
            try:
                import fm_ste
            except ImportError:
                problems.append('%s: explain: fm_ste unavailable' % f.stem)
            else:
                try:
                    report = fm_ste.check_explain(task['explain'])
                    if not report['ok']:
                        problems.append('%s: explain: STE check failed' % f.stem)
                except ValueError as error:
                    problems.append('%s: explain: %s' % (f.stem, error))
        tasks[f.stem] = task
    deps = {}
    for name, task in tasks.items():
        wants = task.get('depends_on', [])
        if not isinstance(wants, list) or not all(isinstance(x, str) for x in wants):
            problems.append('%s: depends_on is not a list of ids' % name); wants = []
        for dep in wants:
            if dep not in tasks: problems.append('%s: depends on %s, which has no task file' % (name, dep))
        deps[name] = [dep for dep in wants if dep in tasks]
    # a cycle is a task that waits, however indirectly, on itself: nothing in it
    # can ever be dispatched. Each cycle is printed once, from its first task.
    state, seen = {}, set()
    def visit(node, path):
        state[node] = 'open'; path.append(node)
        for dep in deps[node]:
            if state.get(dep) == 'open':
                cycle = path[path.index(dep):] + [dep]
                key = frozenset(cycle)
                if key not in seen:
                    seen.add(key); problems.append('a cycle: ' + ' -> '.join(cycle))
            elif dep not in state:
                visit(dep, path)
        path.pop(); state[node] = 'done'
    for name in sorted(deps):
        if name not in state: visit(name, [])
    for problem in problems: print(problem)
    sys.exit(1 if problems else 0)


def main():
    command = sys.argv.pop(1)
    commands = {
        'check': check,
    }
    commands[command]()


if __name__ == "__main__":
    main()
