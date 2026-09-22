#!/usr/bin/env python3
"""Managed run artifacts, checked Herdr transport and observable session services.

Only documented CLI operations are used. Checked close is not atomic with an
unrelated client's pane operations; uncertainty always retains the pane.
"""
import contextlib
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid

_children = []  # Keep Popen objects until a status/stop operation can reap them.


def save(path, value):
    """Publish durable complete JSON; never expose a partially written receipt."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.' + uuid.uuid4().hex)
    with temp.open('x') as out:
        json.dump(value, out, indent=2); out.write('\n'); out.flush(); os.fsync(out.fileno())
    os.replace(temp, path)
    fd = os.open(path.parent, os.O_RDONLY)
    try: os.fsync(fd)
    finally: os.close(fd)


def read(path):
    return json.loads(Path(path).read_text())


@contextlib.contextmanager
def locked(path, blocking=True):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        yield lock


def allocate(root, role, task, alias):
    if role not in ('worker', 'reviewer', 'firstmate'):
        raise ValueError('unsupported role')
    if not re.fullmatch(r'[A-Za-z0-9_-]+', task):
        raise ValueError('invalid task identity')
    directory = Path(root).resolve() / 'state/runs'
    with locked(directory / '.identity.lock'):
        counter = directory / 'counter.json'
        number = read(counter)['number'] + 1 if counter.exists() else 1
        stem = re.sub('[^a-z0-9]+', '-', alias.lower()).strip('-') if alias else ('mira' if role == 'worker' else 'noah')
        stem = re.sub(r'^(worker|reviewer|firstmate)-', '', stem) or 'crew'
        task_slug = re.sub('[^a-z0-9]', '', task.lower())
        # Long task IDs keep a digest so truncation cannot hide their mapping.
        if len(task_slug) > 9:
            task_slug = task_slug[:4] + hashlib.sha256(task.encode()).hexdigest()[:5]
        while True:
            suffix = f'-{task_slug}-r{number}'
            actor = role + '-' + stem[:32-len(role)-1-len(suffix)].rstrip('-') + suffix
            run = directory / actor
            try: run.mkdir(); break
            except FileExistsError: number += 1
        save(counter, dict(number=number))
        save(run / 'identity.json', dict(actor=actor, role=role, task=task,
             requested_alias=alias, run=str(run), created=time.time()))
    return run


def snapshot(root):
    root = Path(root).resolve()
    base = root / 'state/snapshots'; base.mkdir(parents=True, exist_ok=True)
    dest = Path(tempfile.mkdtemp(prefix='code-', dir=base))
    def inventory(where):
        return {str(p.relative_to(where)): hashlib.sha256(p.read_bytes()).hexdigest()
                for folder in ('bin', 'skills') for p in (where / folder).rglob('*')
                if p.is_file() and '__pycache__' not in p.parts}
    before = inventory(root)
    for folder in ('bin', 'skills'):
        if (root / folder).exists():
            shutil.copytree(root / folder, dest / folder, ignore=shutil.ignore_patterns('__pycache__'))
    if before != inventory(dest) or before != inventory(root):
        raise RuntimeError('source changed during snapshot; retry before dispatch')
    save(dest / 'manifest.json', before)
    return dest


def role_context(root, role, task, actor, prompt):
    skill = (Path(root) / 'skills' / role / 'SKILL.md').read_text()
    return (f'You are explicitly dispatched {role}. Canonical crew identity: {actor}. '
            f'Task: {task}. This explicit role wins over native startup routing.\n\n'
            + skill + '\n\n' + prompt + '\n\n'
            + (f'End the final assistant answer with the standalone line {role.upper()}_COMPLETE:{task} '
               f'only when this role task is complete; otherwise {role.upper()}_BLOCKED:{task}. '
               'Process success is not PR acceptance.\n' if role != 'firstmate' else ''))


def completion(role, task, final):
    lines = final.strip().splitlines()
    markers = [line for line in lines if re.fullmatch(r'(WORKER|REVIEWER)_(COMPLETE|BLOCKED|FAILED|INCOMPLETE):\S+', line)]
    if len(markers) != 1 or not lines or lines[-1] != markers[0]: return 'unknown'
    for suffix, status in [('COMPLETE', 'completed'), ('BLOCKED', 'blocked'), ('FAILED', 'failed'), ('INCOMPLETE', 'incomplete')]:
        if markers[0] == f'{role.upper()}_{suffix}:{task}': return status
    return 'unknown'


def shell_only(info, pane, shell=None):
    pid = info.get('shell_pid')
    foreground = info.get('foreground_processes')
    return (info.get('pane_id') == pane and isinstance(pid, int) and pid > 0
            and (shell is None or pid == shell) and bool(foreground)
            and all(p.get('pid') == pid for p in foreground))


def focus(snapshot):
    keys = ('focused_workspace_id', 'focused_tab_id', 'focused_pane_id')
    result = {key: snapshot[key] for key in keys}
    if not all(isinstance(value, str) and value for value in result.values()):
        raise RuntimeError('unknown caller focus')
    return result


def owned_tab(owner, control):
    """One unchanged root pane in the created tab; unknown topology refuses use."""
    snapshot = control('api', 'snapshot')['snapshot']
    tab_id = owner['tab_id']; pane_id = owner['pane_id']
    if (not tab_id or not owner['caller_tab'] or tab_id == owner['caller_tab']
            or pane_id == owner['caller']):
        return False
    tabs = [t for t in snapshot['tabs'] if t['tab_id'] == tab_id]
    panes = [p for p in snapshot['panes'] if p['tab_id'] == tab_id]
    layouts = [v for v in snapshot['layouts'] if v['tab_id'] == tab_id]
    return (len(tabs) == len(panes) == len(layouts) == 1
            and tabs[0]['workspace_id'] == owner['workspace_id']
            and tabs[0]['label'] == owner['actor'] and tabs[0]['pane_count'] == 1
            and panes[0]['pane_id'] == pane_id
            and panes[0]['workspace_id'] == owner['workspace_id']
            and panes[0]['terminal_id'] == owner['terminal_id']
            and layouts[0]['workspace_id'] == owner['workspace_id']
            and [p['pane_id'] for p in layouts[0]['panes']] == [pane_id]
            and layouts[0]['splits'] == [])


def close_owned(run, owner, control):
    """Immediately recheck observations, then close. Not a conditional server API."""
    run = Path(run)
    try:
        result = read(run / 'result.json')
        if result.get('exit_code') != 0 or result.get('status') != 'completed': return 'retained: incomplete result'
        if any(not (run / name).is_file() or not (run / name).stat().st_size
               for name in ('final.txt', 'cli.log')): return 'retained: missing evidence'
        if (run / 'owner.json').is_symlink() or read(run / 'owner.json') != owner: return 'retained: ownership changed'
        pane = owner['pane_id']
        if (owner.get('owned') is not True or not owner.get('caller') or pane == owner['caller']
                or owner.get('run') != str(run) or owner.get('actor') != result.get('actor')
                or owner.get('task') != result.get('task')): return 'retained: not owned'
        status = control('pane', 'get', pane)['pane']
        tokens = status.get('tokens', {})
        if (status.get('pane_id') != pane or status.get('terminal_id') != owner['terminal_id']
                or status.get('tab_id') != owner['tab_id']
                or status.get('workspace_id') != owner['workspace_id']
                or status.get('label') != owner['actor'] or status.get('agent_status') not in ('idle', 'done')
                or any(tokens.get(key) != owner[value] for key, value in
                       [('fm_actor', 'actor'), ('fm_task', 'task'), ('fm_run', 'run')])):
            return 'retained: pane identity or state changed'
        info = control('pane', 'process-info', '--pane', pane)['process_info']
        if not shell_only(info, pane, owner['shell_pid']): return 'retained: busy or shell changed'
        if not owned_tab(owner, control): return 'retained: tab ownership or layout changed'
        control('pane', 'close', pane)
        return 'closed'
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError, subprocess.SubprocessError) as error:
        return 'retained: uncertain observation: ' + str(error)


class Herdr:
    def __init__(self, run):
        self.run = Path(run)
        self.binary = shutil.which('herdr')
        if not self.binary: raise RuntimeError('HERDR_ENV=1 but herdr is unavailable; use FM_TRANSPORT=direct to opt out')

    def __call__(self, *args):
        result = subprocess.run([self.binary, *args], capture_output=True, timeout=15)
        with (self.run / 'herdr.log').open('ab') as out:
            out.write((shlex.join(args) + '\n').encode() + result.stdout + result.stderr)
            out.flush(); os.fsync(out.fileno())
        if result.returncode: raise RuntimeError('Herdr command failed: ' + shlex.join(args))
        return json.loads(result.stdout)['result']


def managed():
    return os.environ.get('HERDR_ENV') == '1' and os.environ.get('FM_TRANSPORT', 'herdr') != 'direct'


def transport(adapter, prompt, tree, log):
    """A whole adapter executes in the pane, preserving normal verdict/fallback."""
    root = Path(os.environ.get('FM_ROOT', Path(adapter).resolve().parents[2])).resolve()
    code = Path(os.environ['FM_CODE_ROOT']) if os.environ.get('FM_CODE_ROOT') else snapshot(root)
    adapter = str(code / 'bin/adapters' / Path(adapter).name)
    role = os.environ.get('FM_ROLE', 'worker'); task = os.environ.get('FM_TASK', 'T-adapter')
    logical = Path(os.environ['FM_RUN_DIR']) if os.environ.get('FM_RUN_DIR') else allocate(root, role, task, '')
    # Vendor fallback keeps the logical actor and verified tab/pane; artifacts differ.
    attempt = Path(tempfile.mkdtemp(prefix=Path(adapter).stem + '-', dir=logical))
    actor = logical.name
    (attempt / 'prompt.md').write_text(role_context(code, role, task, actor, Path(prompt).read_text()))
    env = dict(os.environ, FM_ROLE=role, FM_TASK=task,
               FM_ACTOR=actor, FM_FINAL_PATH=str(attempt / 'final.txt'),
               FM_ATTEMPT_DIR=str(attempt), FM_CONTEXT_READY='1')
    # A spawned pane does not necessarily inherit the launcher's environment.
    # Keep its explicit environment private and do not print credentials.
    save(attempt / 'environment.json', env); (attempt / 'environment.json').chmod(0o600)
    payload = dict(adapter=str(Path(adapter).resolve()), prompt=str(attempt / 'prompt.md'),
                   tree=str(Path(tree).resolve()), actor=actor, role=role, task=task,
                   lifetime_tracking=True)
    save(attempt / 'invocation.json', payload)
    if not managed():
        reserve_execution(attempt)
        rc = pane_child(attempt)
        with Path(log).open('ab') as out: out.write((attempt / 'cli.log').read_bytes())
        save(logical / 'last-result.json', dict(read(attempt / 'result.json'), attempt=str(attempt)))
        return rc
    control = Herdr(attempt)
    timeout = float(os.environ.get('FM_HERDR_TIMEOUT', '21600'))
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError('FM_HERDR_TIMEOUT must be positive finite seconds')
    caller = os.environ.get('HERDR_PANE_ID')
    if not caller: raise RuntimeError('managed transport requires a known caller HERDR_PANE_ID')
    # Read caller membership and UI focus separately: dispatch may itself be unfocused.
    current = control('pane', 'get', caller)['pane']
    if (current.get('pane_id') != caller or not current.get('tab_id')
            or not current.get('workspace_id')): raise RuntimeError('cannot verify caller pane')
    focus_before = focus(control('api', 'snapshot')['snapshot'])
    previous = logical / 'pane.json'
    if previous.exists():
        old = read(previous); pane = old['pane_id']
        observed = control('pane', 'get', pane)['pane']
        live = control('pane', 'process-info', '--pane', pane)['process_info']
        if (previous.is_symlink() or (Path(old['run']) / 'owner.json').is_symlink()
                or old.get('owned') is not True or old['caller'] != caller
                or old.get('caller_tab') != current['tab_id'] or old.get('actor') != actor
                or old.get('task') != task
                or read(Path(old['run']) / 'owner.json') != old
                or not owned_tab(old, control) or observed.get('terminal_id') != old['terminal_id']
                or observed.get('label') != actor or observed.get('tokens', {}).get('fm_run') != old['run']
                or observed.get('tokens', {}).get('fm_task') != task
                or observed.get('tokens', {}).get('fm_actor') != actor
                or not shell_only(live, pane, old['shell_pid'])):
            raise RuntimeError('fallback pane ownership uncertain; retained')
    else:
        created = control('tab', 'create', '--workspace', current['workspace_id'],
                          '--cwd', str(Path(tree).resolve()), '--label', actor, '--no-focus')
        save(attempt / 'creation.json', created)
        pane = created['root_pane']['pane_id']
    if pane == caller: raise RuntimeError('creation returned caller; refusing to use it')
    status = control('pane', 'get', pane)['pane']
    info = control('pane', 'process-info', '--pane', pane)['process_info']
    expected_terminal = old['terminal_id'] if previous.exists() else created['root_pane'].get('terminal_id')
    expected_shell = old['shell_pid'] if previous.exists() else None
    if (status.get('terminal_id') != expected_terminal
            or not shell_only(info, pane, expected_shell)):
        raise RuntimeError('pane identity changed before ownership; retained')
    if status.get('pane_id') != pane or not status.get('terminal_id') or not shell_only(info, pane):
        raise RuntimeError('new pane is not an observed shell; retained')
    owner = dict(owned=True, actor=actor, task=task, run=str(attempt), pane_id=pane,
                 caller=caller, caller_tab=current['tab_id'], workspace_id=current['workspace_id'],
                 tab_id=old['tab_id'] if previous.exists() else created['tab']['tab_id'],
                 terminal_id=status['terminal_id'], shell_pid=info['shell_pid'],
                 focus_before=focus_before, focus_after=focus(control('api', 'snapshot')['snapshot']))
    save(attempt / 'owner.json', owner)
    if owner['focus_before'] != owner['focus_after']:
        raise RuntimeError('caller focus changed during tab creation; retained without launch')
    if not owned_tab(owner, control):
        raise RuntimeError('new tab ownership or layout uncertain; retained')
    save(previous, owner)
    # Override inherited caller context for the process executing in the owned pane.
    env.update(HERDR_PANE_ID=pane, HERDR_TAB_ID=owner['tab_id'],
               HERDR_WORKSPACE_ID=owner['workspace_id'])
    save(attempt / 'environment.json', env); (attempt / 'environment.json').chmod(0o600)
    control('pane', 'rename', pane, actor)
    control('pane', 'report-metadata', pane, '--source', 'firstmate',
            '--token', 'fm_actor=' + actor, '--token', 'fm_task=' + task, '--token', 'fm_run=' + str(attempt))
    control('pane', 'report-agent', pane, '--source', 'firstmate', '--agent', actor,
            '--state', 'working', '--agent-session-id', actor, '--message', task)
    control('agent', 'rename', pane, actor)
    # Reporting names/state does not reserve the foreground. Recheck before input.
    live = control('pane', 'process-info', '--pane', pane)['process_info']
    observed = control('pane', 'get', pane)['pane']
    if (not shell_only(live, pane, owner['shell_pid']) or observed.get('terminal_id') != owner['terminal_id']
            or observed.get('pane_id') != pane or observed.get('tab_id') != owner['tab_id']
            or observed.get('workspace_id') != owner['workspace_id']
            or observed.get('label') != actor
            or any(observed.get('tokens', {}).get(key) != value for key, value in
                   [('fm_run', str(attempt)), ('fm_task', task), ('fm_actor', actor)])
            or not owned_tab(owner, control)):
        raise RuntimeError('pane changed before launch; retained')
    command = shlex.join([sys.executable, str(Path(__file__).resolve()), 'pane-child', str(attempt)])
    # Persist before sending input: a lost reply may still have launched work.
    reserve_execution(attempt)
    control('pane', 'run', pane, command)
    deadline = time.monotonic() + timeout
    while not (attempt / 'result.json').exists():
        if time.monotonic() >= deadline:
            save(attempt / 'transport.json', dict(status='timed-out', actor=actor, pane=pane))
            raise RuntimeError('pane run timed out; process and artifacts retained at ' + str(attempt))
        time.sleep(.1)
    result = read(attempt / 'result.json')
    with Path(log).open('ab') as out:
        out.write((attempt / 'cli.log').read_bytes()); out.flush(); os.fsync(out.fileno())
    save(logical / 'last-result.json', dict(result, attempt=str(attempt)))
    close = 'retained: auto-close disabled'
    if os.environ.get('FM_AUTOCLOSE', '1') != '0':
        try:
            # Let the runner leave the foreground; never report idle on a busy pane.
            for _ in range(20):
                info = control('pane', 'process-info', '--pane', pane)['process_info']
                if shell_only(info, pane, owner['shell_pid']): break
                time.sleep(.1)
            close = close_owned(attempt, owner, control)
        except (OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError, subprocess.SubprocessError) as error:
            close = 'retained: cleanup observation failed: ' + str(error)
    save(attempt / 'close.json', dict(actor=actor, pane=pane, status=close))
    print(f'{actor}: {close}; artifacts {attempt}', file=sys.stderr)
    return result['exit_code']


def execution_state(attempt):
    """A reservation survives launch uncertainty; an inherited lock covers descendants."""
    attempt = Path(attempt)
    receipt = attempt / 'execution.json'
    if not receipt.exists():
        invocation = attempt / 'invocation.json'
        if not invocation.exists() or read(invocation).get('lifetime_tracking'): return None
        # Older frozen launchers cannot publish lifetime locks. An unfinished
        # legacy invocation is uncertainty, never permission to destroy its tree.
        state = 'terminated' if (attempt / 'result.json').exists() else 'uncertain'
        return dict(state=state, live=False, attempt=str(attempt), legacy=True)
    record = read(receipt)
    try:
        with locked(attempt / 'execution.lock', blocking=False):
            state = 'terminated' if record.get('started') else 'uncertain'
    except BlockingIOError:
        state = 'live'
    return dict(record, state=state, live=state == 'live', attempt=str(attempt))


def executions(run):
    attempts = {path.parent for name in ('execution.json', 'invocation.json')
                for path in Path(run).glob('*/' + name)}
    return [state for attempt in sorted(attempts)
            if (state := execution_state(attempt)) is not None]


def reserve_execution(attempt):
    save(Path(attempt) / 'execution.json', dict(started=False, reserved=time.time()))


def pane_child(attempt):
    attempt = Path(attempt)
    # This lock is independent of the launcher: a Herdr pane is not its child.
    # Pass it into the adapter and its CLI descendants, even if this runner dies.
    with locked(attempt / 'execution.lock', blocking=False) as lifetime:
        receipt = attempt / 'execution.json'
        if receipt.exists() and read(receipt).get('started'):
            raise RuntimeError('attempt already started; refusing duplicate execution')
        save(receipt, dict(started=True, runner_pid=os.getpid()))
        return execute_child(attempt, lifetime.fileno())


def execute_child(attempt, lifetime_fd):
    attempt = Path(attempt); invocation = read(attempt / 'invocation.json')
    env = read(attempt / 'environment.json')
    rc = 1
    with (attempt / 'cli.log').open('ab') as log:
        # stdout remains on the real terminal; adapters tee their CLI transcript.
        try:
            child = subprocess.Popen([invocation['adapter'], 'run', invocation['prompt'],
                                      invocation['tree'], str(attempt / 'cli.log')], env=env,
                                     stdin=subprocess.DEVNULL, pass_fds=(lifetime_fd,))
            save(attempt / 'execution.json', dict(started=True, runner_pid=os.getpid(),
                 pid=child.pid, token=invocation['adapter']))
            rc = child.wait()
        finally:
            log.flush(); os.fsync(log.fileno())
    final = attempt / 'final.txt'
    vendor = Path(invocation['adapter']).stem
    if vendor in ('claude', 'cursor-agent', 'gemini'):
        # Only a complete CLI result object establishes final-answer provenance.
        # Mixed/partial output stays in cli.log and cannot authorize a close.
        try:
            response = json.loads((attempt / 'cli.log').read_text())
            value = response.get('response') if vendor == 'gemini' else response.get('result')
            valid = vendor == 'gemini' or response.get('type') == 'result'
            if valid and not response.get('is_error') and not response.get('error') and isinstance(value, str):
                final.write_text(value)
        except (ValueError, AttributeError): pass
    status = completion(invocation['role'], invocation['task'], final.read_text()) if final.exists() else 'unknown'
    if final.exists():
        with final.open('rb') as source: os.fsync(source.fileno())
    result = dict(actor=invocation['actor'], task=invocation['task'], role=invocation['role'],
                  exit_code=rc, status=status, pid=os.getpid(),
                  chain_attempt=env.get('FM_CHAIN_ATTEMPT', ''))
    raw = attempt / 'cli-exit-code'
    result['cli_exit_code'] = int(raw.read_text()) if raw.exists() else None
    # Retain evidence before lifecycle reporting or any close operation.
    save(attempt / 'result.json', result)
    if not (attempt / 'owner.json').exists(): return rc
    owner = read(attempt / 'owner.json')
    try:
        Herdr(attempt)('pane', 'report-agent', owner['pane_id'], '--source', 'firstmate',
                       '--agent', invocation['actor'], '--state', 'idle' if status == 'completed' else 'blocked',
                       '--agent-session-id', invocation['actor'], '--message', invocation['task'] + ': ' + status)
    except (RuntimeError, ValueError, subprocess.SubprocessError): pass
    return rc


def process_matches(record):
    try:
        pid = int(record['pid'])
        result = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True)
        return result.returncode == 0 and record['token'] in result.stdout
    except (KeyError, ValueError, OSError): return False


def watch_start(root, decision='all'):
    root = Path(root).resolve()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', decision): raise ValueError('invalid decision ID')
    base = root / 'state/session'; base.mkdir(parents=True, exist_ok=True)
    registry = base / ('watch-' + decision + '.json')
    with locked(base / '.watch.lock'):
        if registry.exists() and process_matches(read(registry)): return read(registry)
        directory = Path(tempfile.mkdtemp(prefix='watch-', dir=base))
        code = snapshot(root)
        token = str(directory)
        with (directory / 'log').open('ab') as log:
            child = subprocess.Popen([sys.executable, str(code / 'bin/fm-herdr.py'), 'watch-child',
                                      str(root), decision, token], stdin=subprocess.DEVNULL,
                                     stdout=log, stderr=log, start_new_session=True)
        _children.append(child)
        record = dict(pid=child.pid, token=token, directory=token, root=str(root), decision=decision)
        save(registry, record)
        return record


def watch_stop(root, decision='all'):
    if not re.fullmatch(r'[A-Za-z0-9_-]+', decision): raise ValueError('invalid decision ID')
    registry = Path(root) / 'state/session' / ('watch-' + decision + '.json')
    if not registry.exists(): return
    with locked(registry.parent / '.watch.lock'):
        record = read(registry)
        if process_matches(record):
            os.killpg(record['pid'], signal.SIGTERM)
            for _ in range(50):
                if not process_matches(record): break
                time.sleep(.02)
        result = Path(record['directory']) / 'result.json'
        if not result.exists(): save(result, dict(status='stopped'))
        for child in _children:
            if child.pid == record['pid']:
                try: child.wait(timeout=2)
                except subprocess.TimeoutExpired: pass


def watch_child(root, decision, directory):
    root = Path(root); directory = Path(directory)
    result = directory / 'result.json'
    def stop(_signum, _frame):
        save(result, dict(status='stopped')); raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    save(directory / 'status.json', dict(status='live', pid=os.getpid(), decision=decision))
    observed = root / 'state/session/observed' if decision == 'all' else directory / 'observed'
    observed.mkdir(parents=True, exist_ok=True)
    script = Path(__file__).parent / 'fm-decide.sh'
    # fm-decide's existing watcher (Bun fs.watch or shell poll) performs waits.
    # One bounded wait permits newly pending decisions to be discovered as well.
    try:
        while True:
            ids = [decision] if decision != 'all' else sorted({p.stem for name in ('pending', 'decisions')
                    for p in (root / 'state' / name).glob('*.json')})
            for ident in ids:
                if (observed / (ident + '.json')).exists(): continue
                reply = subprocess.run(['bash', str(script), '--await', ident, '--timeout', '1', '--repo', str(root)],
                                       stdin=subprocess.DEVNULL, capture_output=True, text=True)
                if reply.returncode == 0:
                    answer = json.loads(reply.stdout)
                    receipt = dict(status='observed', decision=answer, id=ident, observed=time.time())
                    save(observed / (ident + '.json'), receipt)
                    if decision != 'all': save(result, receipt); return 0
                elif (root / 'state/decisions' / (ident + '.json')).exists():
                    raise RuntimeError('decision exists but watcher failed: ' + reply.stderr)
            time.sleep(.2)
    except Exception as error:
        save(result, dict(status='failed', error=str(error))); return 1


def http_get(url):
    try:
        with urllib.request.urlopen(url, timeout=2) as response: return response.read()
    except urllib.error.HTTPError as error:
        error.close()
        raise


def board_matches(root, url):
    root = Path(root)
    directory = root / 'state/session'; directory.mkdir(parents=True, exist_ok=True)
    relative = Path('state/session') / ('probe-' + uuid.uuid4().hex)
    nonce = uuid.uuid4().hex.encode(); (root / relative).write_bytes(nonce)
    try:
        return http_get(url + '/file?path=' + urllib.parse.quote(str(relative))) == nonce
    except (OSError, ValueError): return False
    finally: (root / relative).unlink()


def board_start(root):
    root = Path(root).resolve(); port = int(os.environ.get('FM_PORT', '4173'))
    url = f'http://127.0.0.1:{port}'
    base = root / 'state/session'; base.mkdir(parents=True, exist_ok=True)
    with locked(base / '.board.lock'):
        reused = board_matches(root, url)
        if not reused:
            # Any response means a different/unverifiable listener, never reuse it.
            try: http_get(url); occupied = True
            except urllib.error.HTTPError: occupied = True
            except OSError: occupied = False
            if occupied: raise RuntimeError('board port belongs to an unverified root: ' + url)
            bun = shutil.which('bun')
            if not bun: raise RuntimeError('board requires Bun')
            with (base / 'board.log').open('ab') as log:
                child = subprocess.Popen([bun, 'run', str(root / 'board/server.ts')], cwd=root,
                        env=dict(os.environ, FM_ROOT=str(root), FM_PORT=str(port)),
                        stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
            for _ in range(50):
                if child.poll() is not None: break
                if board_matches(root, url): break
                time.sleep(.1)
            if not board_matches(root, url): raise RuntimeError('board did not verify; inspect state/session/board.log')
        page = bool(http_get(url))
        opener = shutil.which('open') or shutil.which('xdg-open')
        opened = subprocess.call([opener, url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0 if opener else False
        record = dict(root=str(root), url=url, reused=reused, page_http_verified=page,
                      opener_invoked=opened, browser_navigation_verified=False)
        save(base / 'board.json', record)
        return record


def inspect(root):
    root = Path(root).resolve()
    runs = []
    for file in (root / 'state/runs').glob('*/identity.json'):
        process = file.parent / 'process.json'
        record = read(process) if process.exists() else read(file)
        active = executions(file.parent)
        launcher_live = process_matches(record)
        runs.append(dict(record, orchestration_live=launcher_live, executions=active,
                         live=launcher_live or any(item['live'] for item in active),
                         uncertain=any(item['state'] == 'uncertain' for item in active)))
    watches = []
    for file in (root / 'state/session').glob('watch-*.json'):
        record = read(file); result = Path(record['directory']) / 'result.json'
        watches.append(dict(record, live=process_matches(record), result=read(result) if result.exists() else None))
    report = dict(root=str(root), runs=runs, watches=watches,
                  pending=[p.name for p in (root / 'state/pending').glob('*.json')],
                  worktrees=[p.name for p in (root / 'state/worktrees').glob('*') if p.is_dir()])
    events = root / 'state/events.jsonl'
    report['events'] = [json.loads(line) for line in events.read_text().splitlines() if line.strip()] if events.exists() else []
    config = root / 'config.yaml'
    report['configuration'] = config.read_text() if config.exists() else None
    if managed():
        base = root / 'state/session'; base.mkdir(parents=True, exist_ok=True)
        report['panes'] = Herdr(base)('pane', 'list')
    return report


def launch(script, root, args):
    root = Path(root).resolve(); script = Path(script).resolve()
    supplied = os.environ.get('FM_CODE_ROOT')
    code = Path(supplied) if supplied and script.is_relative_to(Path(supplied)) else snapshot(root)
    # The shell has already resolved root in the caller's cwd. Replay that one
    # canonical value for every occurrence, including inherited relative FM_ROOT.
    args = list(args)
    task = None
    index = 0
    while index < len(args):
        value = args[index]
        # All validated long options in these five entrypoints take one value,
        # except --dry-run. Skip values so an alias is never read as an option.
        if value.startswith('--') and value != '--dry-run':
            if value == '--repo': args[index + 1] = str(root)
            if value == '--task': task = args[index + 1]
            index += 2
        else:
            index += 1
    env = dict(os.environ, FM_ROOT=str(root), FM_CODE_ROOT=str(code),
               FM_ENTRY_PID=str(os.getpid()), FM_ENTRY_SCRIPT=script.name)
    # A worker owns its task worktree for the entire orchestration, including
    # commits. Competing callers must not recreate a live worker's directory.
    if script.name == 'fm-worker.sh' and task is not None:
        if not re.fullmatch(r'[A-Za-z0-9_-]+', task): raise ValueError('invalid task')
        lock_path = root / 'state/runs' / ('.worker-' + task + '.lock')
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise RuntimeError('task already has a live worker; resume it: ' + task)
        # Inspect while holding task exclusion, before any worktree mutation.
        # Pending launches fail closed: absence of a PID is not proof of death.
        for identity_file in (root / 'state/runs').glob('*/identity.json'):
            identity = read(identity_file)
            if identity.get('role') == 'worker' and identity.get('task') == task:
                if any(item['state'] != 'terminated' for item in executions(identity_file.parent)):
                    raise RuntimeError('task already has a live worker or uncertain launch; resume it: ' + task)
        os.set_inheritable(fd, True)
        # Publish the fd so the worker can drop it in the adapter subshell.
        # The parent orchestration process keeps its copy for exclusion; a
        # surviving adapter after SIGKILL of the published PID must not keep
        # the lock or recovery relaunch blocks forever.
        env['FM_WORKER_TASK_LOCK_FD'] = str(fd)
    os.execve('/bin/bash', ['bash', str(code / 'bin' / script.name), *args], env)


def main(args):
    mode, *args = args
    if mode == 'allocate': print(allocate(Path(args[0]), *args[1:])); return 0
    if mode == 'launch': launch(args[0], args[1], args[2:])
    if mode == 'transport': return transport(*args)
    if mode == 'pane-child': return pane_child(*args)
    if mode == 'watch-child': return watch_child(*args)
    if mode == 'context':
        root, role, task, actor, prompt, target = args
        Path(target).write_text(role_context(root, role, task, actor, Path(prompt).read_text())); return 0
    if mode == 'session':
        action, root, *rest = args; decision = rest[0] if rest else 'all'
        if action == 'status': print(json.dumps(inspect(root), indent=2))
        elif action == 'watch': print(json.dumps(watch_start(root, decision)))
        elif action == 'stop': watch_stop(root, decision)
        elif action == 'start':
            report = inspect(root); report['board'] = board_start(root)
            if os.environ.get('FM_WATCH', '1') != '0': report['watch'] = watch_start(root)
            print(json.dumps(report, indent=2))
        else: raise ValueError('unknown session action')
        return 0
    raise ValueError('unknown managed action')


if __name__ == '__main__':
    try: sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError, subprocess.SubprocessError) as error:
        print('fm-managed: ' + str(error), file=sys.stderr); sys.exit(70)
