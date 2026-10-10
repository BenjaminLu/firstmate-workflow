"""The local test runner a worker round runs before it finishes (T-275).

    runner.py run [--suite <path> [--case <name>]...]... [--case <name>]...
    fm_local_tests.py summary <file>
    fm_local_tests.py strip <file>

`run` executes inside the round's sandbox, from the worktree. It reads
plan.json beside itself, selects the suites related to what the round
changed, runs them under the plan's time limits and writes one results block
into the worktree's .fm-say.md. `summary` and `strip` run outside the round,
in the launcher. The launcher copies this file byte for byte into the round's
read-only local-tests folder, where nothing else of firstmate is readable, so
it imports only the Python standard library and opens no network connection.
The results are local evidence; CI and the six gates still decide.
"""
import fnmatch
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time

START = '<!-- fm-local-tests v1 -->'
END = '<!-- /fm-local-tests -->'
START_ANY = re.compile(r'^<!-- fm-local-tests v([0-9]+) -->$')
SUMMARY = re.compile(r'^<!-- fm-local-tests-summary (\{.*\}) -->$')
START_BYTES = re.compile(rb'^<!-- fm-local-tests v[0-9]+ -->\r?$')
END_BYTES = re.compile(rb'^<!-- /fm-local-tests -->\r?$')
# The summary's keys, in order, and the whole numbers each may hold.
KEYS = (('passed', 0, 10000), ('failed', 0, 10000), ('timed_out', 0, 10000),
        ('not_runnable', 0, 10000), ('not_run', 0, 10000),
        ('budget_seconds', 60, 7200), ('used_seconds', 0, 86400),
        ('changed_files', 0, 100000))
PLAN_KEYS = {'schema', 'base', 'tests', 'test', 'check_env', 'docs', 'unrunnable',
             'budget_seconds', 'network', 'suite_seconds', 'jobs'}
# The fail-first report's assertion line (bin/fm-failfirst.sh).
ASSERTION = re.compile(r'^    (.+?) *(ok|FAIL)$')
# What the fail-first selection counts as a suite with no `tests` declared.
DEFAULT_TESTS = ['tests/*', '*.test.*', '*.spec.*']
NOT_SAID = ('.fm-say.md', '.fm-prompt.md')
CAP = 3
CAP_REASON = 'more than 3 suites name a changed file; CI runs them'
BUDGET_REASON = 'the time budget was used up before it started'
PROBE_SECONDS = 10
GRACE = 5
DETAIL_MAX = 200

# The one fixed table of what a missing capability prints. Each pattern is
# matched against one output line; the samples in tests/lib/local_tests.py
# were captured inside real round sandboxes. A line counts only when the
# probe for the same capability failed (network: when it names a host the
# plan does not declare).
PATTERNS = {
    'pseudo-terminal': [
        re.compile(r'\bopenpty\(\)'),
        re.compile(r'\b(?:open|fork)pty\b.*(?:not permitted|denied|failed)', re.I),
        re.compile(r'out of pty devices', re.I),
        re.compile(r'\bposix_openpt\b', re.I),
    ],
    'ps': [
        re.compile(r'(?:^|[\s/])ps: (?:Operation not permitted|Permission denied)'),
        re.compile(r'operation not permitted: ps$'),
    ],
    'nested sandbox': [
        re.compile(r'\bsandbox-exec: sandbox_apply: '),
        re.compile(r'^bwrap: .*(?:namespace|Operation not permitted|Permission denied|No permissions)'),
    ],
    'docker': [
        re.compile(r'permission denied while trying to connect to the docker (?:api|daemon)', re.I),
        re.compile(r'cannot connect to the docker daemon', re.I),
    ],
}
HOST = r'(?P<host>[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)'
NETWORK = [
    # curl, and git through libcurl
    re.compile(r'Could not resolve host: ' + HOST),
    # git through the round's proxy, which refuses an undeclared host
    re.compile(r"unable to access '[a-z+]+://(?:[^@/']*@)?" + HOST
               + r"[^']*': (?:CONNECT tunnel failed|Could not resolve)"),
    # Python's urllib3 (pip, requests)
    re.compile(r"Failed to resolve '" + HOST + r"'"),
    re.compile(r"HTTPS?ConnectionPool\(host='" + HOST + r"'.*(?:ProxyError|NameResolutionError|"
               r"Tunnel connection failed)"),
]

ACTIVE = {}          # pgid -> process, every suite and probe still running
ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b[@-_]')
CONTROL = re.compile(r'[\x00-\x1f\x7f-\x9f]')


class Usage(Exception):
    pass


class PlanError(Exception):
    pass


class Stopped(BaseException):
    def __init__(self, signum):
        BaseException.__init__(self, signum)
        self.signum = signum


# --- the plan -----------------------------------------------------------------
def whole(value, low, high):
    return isinstance(value, int) and not isinstance(value, bool) and low <= value <= high


def strings(value):
    return isinstance(value, list) and all(isinstance(x, str) for x in value)


def read_plan(path):
    try:
        with open(path, encoding='utf-8') as f:
            plan = json.load(f)
    except (OSError, ValueError) as error:
        raise PlanError('the plan at %s does not read: %s' % (path, error))
    ok = (isinstance(plan, dict) and set(plan) == PLAN_KEYS and plan['schema'] == 1
          and not isinstance(plan['schema'], bool)
          and (plan['base'] is None or (isinstance(plan['base'], str) and plan['base']))
          and strings(plan['tests']) and strings(plan['docs']) and strings(plan['network'])
          and (plan['test'] is None or isinstance(plan['test'], str))
          and (plan['unrunnable'] is None or isinstance(plan['unrunnable'], str))
          and isinstance(plan['check_env'], dict)
          and all(isinstance(k, str) and isinstance(v, str) for k, v in plan['check_env'].items())
          and whole(plan['budget_seconds'], 60, 7200)
          and whole(plan['suite_seconds'], 1, 86400) and whole(plan['jobs'], 1, 64))
    if not ok:
        raise PlanError('the plan at %s is not the shape this runner reads' % path)
    return plan


# --- arguments ----------------------------------------------------------------
def parse(argv):
    """-> (suites in order, {suite: [cases]}, cases for every changed suite)."""
    suites, cases, loose = [], {}, []
    last = None
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ('--suite', '--case'):
            if i + 1 >= len(argv) or not argv[i + 1]:
                raise Usage('%s needs a value' % arg)
            value = argv[i + 1]
            i += 2
            if arg == '--suite':
                last = value
                if value not in suites:
                    suites.append(value)
                cases.setdefault(value, [])
            elif last is None:
                loose.append(value)
            else:
                cases[last].append(value)
            continue
        if arg.startswith('-'):
            raise Usage('unknown option %s' % arg)
        raise Usage('unexpected argument %s' % arg)
    return suites, cases, loose


# --- the worktree -------------------------------------------------------------
def git(root, *args):
    got = subprocess.run(['git', '--no-optional-locks'] + list(args), cwd=root,
                         stdin=subprocess.DEVNULL, capture_output=True)
    if got.returncode != 0:
        raise PlanError('git %s failed: %s' % (' '.join(args),
                        got.stderr.decode('utf-8', 'replace').strip()))
    return [p for p in got.stdout.decode('utf-8', 'surrogateescape').split('\0') if p]


def worktree():
    got = subprocess.run(['git', 'rev-parse', '--show-toplevel'], stdin=subprocess.DEVNULL,
                         capture_output=True)
    if got.returncode == 0 and got.stdout.strip():
        return os.path.realpath(got.stdout.decode('utf-8', 'surrogateescape').strip())
    return os.path.realpath(os.getcwd())


def changed_files(root, base):
    ref = base or 'HEAD'
    files = set(git(root, 'diff', '--name-only', '--no-renames', '-z', ref))
    files |= set(git(root, 'ls-files', '--others', '--exclude-standard', '-z'))
    return sorted(f for f in files if f not in NOT_SAID)


def matches(path, globs):
    """bin/fm-failfirst.sh's rule: shell patterns, and a leading **/ also
    matches at the top level."""
    for g in globs:
        if not g:
            continue
        if fnmatch.fnmatchcase(path, g):
            return True
        if g.startswith('**/') and fnmatch.fnmatchcase(path, g[3:]):
            return True
    return False


def is_suite(path, plan):
    return matches(path, plan['tests'] or DEFAULT_TESTS)


def worktree_suites(root, plan):
    files = git(root, 'ls-files', '--cached', '--others', '--exclude-standard', '-z')
    return sorted({f for f in files if is_suite(f, plan)
                   and os.path.isfile(os.path.join(root, f))
                   and not os.path.islink(os.path.join(root, f))})


def select(root, plan, named, changed):
    """-> (rows to run, in order, rows the cap leaves out). A row is a dict."""
    selected, rows = set(), []
    for path in named:
        rows.append(dict(suite=path, group='named'))
        selected.add(path)
    relevant = [f for f in changed if not matches(f, plan['docs'])]
    for path in sorted(f for f in relevant if is_suite(f, plan)
                       and os.path.isfile(os.path.join(root, f)) and f not in selected):
        rows.append(dict(suite=path, group='changed'))
        selected.add(path)
    names = sorted({os.path.basename(f) for f in relevant if os.path.basename(f)})
    found = []
    if names:
        bounds = [(n, re.compile(r'(^|[^A-Za-z0-9._-])' + re.escape(n) + r'([^A-Za-z0-9._-]|$)', re.M))
                  for n in names]
        for path in worktree_suites(root, plan):
            if path in selected:
                continue
            full = os.path.join(root, path)
            try:
                with open(full, 'rb') as f:
                    text = f.read().decode('utf-8', 'replace')
            except OSError:
                continue
            count = sum(1 for _, pattern in bounds if pattern.search(text))
            if count:
                found.append((-count, os.path.getsize(full), path.encode('utf-8', 'surrogateescape'), path))
    found.sort()
    named_rows = [dict(suite=p, group='names') for _, _, _, p in found]
    if len(named_rows) > CAP:
        for row in named_rows:
            row.update(result='not run', detail=CAP_REASON)
        return rows, named_rows
    return rows + named_rows, []


# --- processes ----------------------------------------------------------------
def start(argv, env, cwd, out):
    process = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=out,
                               stderr=subprocess.STDOUT, preexec_fn=os.setpgrp)
    ACTIVE[process.pid] = process
    return process


def signal_group(pgid, signum):
    try:
        os.killpg(pgid, signum)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def group_alive(pgid):
    return signal_group(pgid, 0)


def end_group(pgid, process=None):
    """SIGTERM to the whole group, SIGKILL 5 seconds later for what is left."""
    signal_group(pgid, signal.SIGTERM)
    deadline = time.monotonic() + GRACE
    while time.monotonic() < deadline:
        if process is not None and process.poll() is None:
            time.sleep(0.05)
            continue
        if not group_alive(pgid):
            break
        time.sleep(0.05)
    signal_group(pgid, signal.SIGKILL)
    if process is not None:
        try:
            process.wait(timeout=GRACE)
        except subprocess.TimeoutExpired:
            pass
    ACTIVE.pop(pgid, None)


def end_all():
    for pgid in list(ACTIVE):
        signal_group(pgid, signal.SIGTERM)
    deadline = time.monotonic() + GRACE
    while ACTIVE and time.monotonic() < deadline:
        for pgid, process in list(ACTIVE.items()):
            if process.poll() is not None and not group_alive(pgid):
                ACTIVE.pop(pgid, None)
        time.sleep(0.05)
    for pgid, process in list(ACTIVE.items()):
        signal_group(pgid, signal.SIGKILL)
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
    ACTIVE.clear()


def on_signal(signum, _frame):
    raise Stopped(signum)


# --- what this sandbox gives --------------------------------------------------
def first_line(text):
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return ''


def probe_command(argv):
    """-> (works, reason). Its own group, a 10-second deadline."""
    with tempfile.TemporaryFile() as out:
        try:
            process = start(argv, dict(os.environ), None, out)
        except OSError as error:
            return False, '%s: %s' % (argv[0], error.strerror or error)
        try:
            process.wait(timeout=PROBE_SECONDS)
        except subprocess.TimeoutExpired:
            end_group(process.pid, process)
            return False, 'no answer in %d seconds' % PROBE_SECONDS
        # what the probe left behind does not outlive it either
        end_group(process.pid, process)
        out.seek(0)
        said = first_line(out.read().decode('utf-8', 'replace'))
        if process.returncode == 0:
            return True, ''
        return False, said or 'exit %d' % process.returncode


def probe_pty():
    if os.environ.get('FM_LOCAL_TESTS_NO_PTY') == '1':
        return False, 'turned off by FM_LOCAL_TESTS_NO_PTY'
    try:
        a, b = os.openpty()
    except OSError as error:
        return False, '%s: %s' % (type(error).__name__, error)
    os.close(a)
    os.close(b)
    return True, ''


def probes():
    found = {'pseudo-terminal': probe_pty(),
             'ps': probe_command(['ps', '-o', 'pid=', '-p', str(os.getpid())])}
    if sys.platform == 'darwin':
        found['nested sandbox'] = probe_command(['sandbox-exec', '-p', '(version 1)(allow default)', 'true'])
    else:
        found['nested sandbox'] = probe_command(['bwrap', '--ro-bind', '/', '/', '--unshare-all', 'true'])
    found['docker'] = probe_command(['docker', 'info'])
    return found


def not_runnable(output, found, network):
    """-> the detail when a missing capability explains a failed suite."""
    declared = {h.lower().rstrip('.') for h in network}
    for line in output.splitlines():
        for capability, patterns in PATTERNS.items():
            works, reason = found.get(capability, (True, ''))
            if works:
                continue
            if any(p.search(line) for p in patterns):
                return '%s: probe: %s; output: %s' % (capability, reason, line.strip())
        for pattern in NETWORK:
            got = pattern.search(line)
            if got and got.group('host').lower().rstrip('.') not in declared:
                return 'network: %s is not a declared registry; output: %s' % (
                    got.group('host'), line.strip())
    return None


# --- one suite ----------------------------------------------------------------
# The shell that runs the suite is the session of whatever it starts, as the
# fail-first runner's ONE_SH makes it (bin/fm-failfirst.sh).
WRAP = 'FIRSTMATE_CI_SESSION=$$ FM_SESSION_PID=$$ bash -c "$1" < /dev/null'


def fill(template, path):
    return template.replace('{file}', shlex.quote(path))


def suite_env(root, plan):
    env = dict(os.environ)
    env.update(FM_ROOT=root, LC_ALL='', LC_MESSAGES='C')
    env.update(plan['check_env'])
    return env


def classify(row, rc, output, found, plan):
    lines = output.splitlines()
    if rc == 0:
        row['result'] = 'passed' if output.strip() else 'not a suite'
        return
    why = not_runnable(output, found, plan['network'])
    if why:
        row.update(result='not runnable here', detail=why)
        return
    failing = []
    for line in lines:
        m = ASSERTION.match(line)
        if m and m.group(2) == 'FAIL' and m.group(1).strip() not in failing:
            failing.append(m.group(1).strip())
    detail = 'exit %d' % rc
    if failing:
        detail += '; failing: ' + ', '.join(failing[:5])
    row.update(result='failed', detail=detail)


def run_suites(root, plan, rows, found, started):
    budget, env = plan['budget_seconds'], suite_env(root, plan)
    queue = list(rows)
    running = []     # (row, process, output file, deadline, began)
    while queue or running:
        now = time.monotonic()
        left = budget - (now - started)
        while queue and len(running) < plan['jobs']:
            row = queue[0]
            if left <= 0:
                break
            queue.pop(0)
            out = tempfile.TemporaryFile()
            command = fill(plan['test'], row['suite'])
            try:
                process = start(['bash', '-c', WRAP, 'fm-local-test', command], env, root, out)
            except OSError as error:
                out.close()
                row.update(result='failed', detail='could not start: %s' % (error.strerror or error),
                           seconds=0)
                continue
            running.append((row, process, out, now + min(plan['suite_seconds'], left), now))
        if not running and queue and left <= 0:
            for row in queue:
                row.update(result='not run', detail=BUDGET_REASON)
            break
        still = []
        for row, process, out, deadline, began in running:
            if process.poll() is None and time.monotonic() < deadline:
                still.append((row, process, out, deadline, began))
                continue
            timed_out = process.poll() is None
            end_group(process.pid, process)
            row['seconds'] = time.monotonic() - began
            out.seek(0)
            output = out.read().decode('utf-8', 'replace')
            out.close()
            if timed_out:
                row.update(result='timed out', detail='ran past %d seconds' % round(deadline - began))
            else:
                classify(row, process.returncode, output, found, plan)
        running = still
        if running:
            time.sleep(0.05)


# --- the report ---------------------------------------------------------------
def cleaner(run_dir, root):
    home = os.path.expanduser('~')
    swaps = [(p + '/', '') for p in {root, os.path.realpath(root)} if p and p != '/']
    swaps += [(p, '.') for p in {root, os.path.realpath(root)} if p and p != '/']
    swaps += [(p, '<round>') for p in {run_dir, os.path.realpath(run_dir)} if p and p != '/']
    swaps += [(p, '~') for p in {home, os.path.realpath(home)} if p and p != '/']
    swaps.sort(key=lambda swap: -len(swap[0]))

    def clean(text, limit=None):
        text = ANSI.sub('', text)
        text = CONTROL.sub(' ', text)
        for path, name in swaps:
            text = text.replace(path, name)
        text = text.strip()
        if limit and len(text) > limit:
            text = text[:limit - 3] + '...'
        return text.replace('|', '\\|')
    return clean


def counts(rows):
    c = dict(passed=0, failed=0, timed_out=0, not_runnable=0, not_run=0)
    names = {'passed': 'passed', 'failed': 'failed', 'timed out': 'timed_out',
             'not runnable here': 'not_runnable', 'not run': 'not_run'}
    for row in rows:
        key = names.get(row.get('result'))
        if key and not row.get('uncounted'):
            c[key] += 1
    return c


def render(rows, totals, notes, clean):
    lines = [START, '<!-- fm-local-tests-summary %s -->' % json.dumps(totals, separators=(',', ':')),
             '## Local tests', '']
    lines += [clean(n) for n in notes]
    if notes:
        lines.append('')
    lines += ['| Suite | Result | Seconds | Detail |', '| --- | --- | --- | --- |']
    for row in rows:
        lines.append('| %s | %s | %d | %s |' % (clean(row['suite']), row['result'],
                                              round(row.get('seconds', 0)),
                                              clean(row.get('detail', ''), DETAIL_MAX)))
    lines.append(END)
    return '\n'.join(lines) + '\n'


def write_block(root, block):
    """Replace the block .fm-say.md holds, or add one; other text stays."""
    path = os.path.join(root, '.fm-say.md')
    try:
        with open(path, 'rb') as f:
            data = f.read()
    except FileNotFoundError:
        data = b''
    new = block.encode('utf-8')
    lines = lines_of(data)
    found = blocks(lines) or []
    if found:
        drop = {n for i, j in found for n in range(i, j + 1)}
        out = []
        for n, line in enumerate(lines):
            if n == found[0][0]:
                out.append(new)
            elif n not in drop:
                out.append(line)
        result = b''.join(out)
    elif data:
        result = data + (b'' if data.endswith(b'\n') else b'\n') + b'\n' + new
    else:
        result = new
    with open(path, 'wb') as f:
        f.write(result)


def run(argv):
    try:
        named, cases, loose = parse(argv)
    except Usage as error:
        print('runner: %s' % error, file=sys.stderr)
        print('usage: runner.py run [--suite <path> [--case <name>]...]... [--case <name>]...',
              file=sys.stderr)
        return 64
    folder = os.path.dirname(os.path.realpath(__file__))
    try:
        plan = read_plan(os.path.join(folder, 'plan.json'))
    except PlanError as error:
        print('runner: %s' % error, file=sys.stderr)
        return 70
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, on_signal)
    try:
        return run_plan(plan, named, cases, loose, folder)
    except Stopped as stop:
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)
        end_all()
        print('runner: stopped by signal %d; no results were written' % stop.signum, file=sys.stderr)
        return 128 + stop.signum
    except PlanError as error:
        end_all()
        print('runner: %s' % error, file=sys.stderr)
        return 70


def run_plan(plan, named, cases, loose, folder):
    started = time.monotonic()
    root = worktree()
    clean = cleaner(os.path.dirname(folder), root)
    for path in named:
        rel = os.path.normpath(path)
        full = os.path.join(root, rel)
        if os.path.isabs(path) or rel.startswith('..') or not os.path.isfile(full) or not is_suite(rel, plan):
            print('runner: --suite %s is not a suite in this worktree' % path, file=sys.stderr)
            return 64
    named = [os.path.normpath(p) for p in named]
    cases = {os.path.normpath(k): v for k, v in cases.items()}
    changed = changed_files(root, plan['base'])
    if not changed:
        print('No file changed, so no suite runs and nothing is written to .fm-say.md.')
        return 0
    notes = []
    if plan['base'] is None:
        notes.append('The base of this branch is unknown, so only uncommitted changes were counted.')
    rows, capped = select(root, plan, named, changed)
    changed_suites = {f for f in changed if is_suite(f, plan)}
    if loose and not (changed_suites & {r['suite'] for r in rows}):
        print('--case names matched no suite')
    for row in rows:
        names = list(cases.get(row['suite'], []))
        if row['suite'] in changed_suites:
            names += [n for n in loose if n not in names]
        if names:
            row['cases'] = names
    found = None
    if plan['unrunnable']:
        for row in rows + capped:
            row.update(result='not runnable here', detail='this project: %s' % plan['unrunnable'])
        rows, capped = rows + capped, []
    elif not plan['test']:
        rows = [dict(suite='-', result='-', detail='no test template declared', uncounted=True)]
        capped = []
    elif rows:
        found = probes()
        run_suites(root, plan, rows, found, started)
    for row in rows:
        if row.get('cases'):
            prefix = 'case filter not supported: ' + ', '.join(row['cases'])
            row['detail'] = prefix + ('; ' + row['detail'] if row.get('detail') else '')
    rows = rows + capped
    used = time.monotonic() - started
    totals = counts(rows)
    totals.update(budget_seconds=plan['budget_seconds'], used_seconds=min(86400, round(used)),
                   changed_files=min(100000, len(changed)))
    notes.append('Changed files: %d. Time budget: %d seconds, %d used.'
                 % (len(changed), plan['budget_seconds'], round(used)))
    if found:
        notes.append('Sandbox: ' + '; '.join(
            '%s %s' % (name, 'works' if works else 'missing (%s)' % reason)
            for name, (works, reason) in found.items()) + '.')
    block = render(rows, totals, notes, clean)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    write_block(root, block)
    sys.stdout.write(block[block.index('## Local tests'):block.index(END)])
    return 1 if totals['failed'] or totals['timed_out'] else 0


# --- outside the round --------------------------------------------------------
def summary(path):
    if not os.path.exists(path):
        return 3
    try:
        with open(path, 'rb') as f:
            text = f.read().decode('utf-8', 'surrogateescape')
    except OSError:
        return 65
    lines = text.split('\n')
    starts = [i for i, line in enumerate(lines) if START_ANY.match(line.rstrip('\r'))]
    if not starts:
        return 3
    if len(starts) != 1 or lines[starts[0]].rstrip('\r') != START:
        return 65
    at = starts[0]
    ends = [i for i, line in enumerate(lines) if i > at and line.rstrip('\r') == END]
    if len(ends) != 1 or ends[0] < at + 2:
        return 65
    got = SUMMARY.match(lines[at + 1].rstrip('\r'))
    if not got:
        return 65

    def pairs(items):
        seen = {}
        for key, value in items:
            if key in seen:
                raise ValueError('duplicate key')
            seen[key] = value
        return seen
    try:
        doc = json.loads(got.group(1), object_pairs_hook=pairs)
    except ValueError:
        return 65
    if not isinstance(doc, dict) or set(doc) != {k for k, _, _ in KEYS}:
        return 65
    if not all(whole(doc[k], low, high) for k, low, high in KEYS):
        return 65
    print(json.dumps({k: doc[k] for k, _, _ in KEYS}, separators=(',', ':')))
    return 0


def lines_of(data):
    """Lines of bytes, each with its own newline; never splits on anything else."""
    out, pos = [], 0
    while pos < len(data):
        nl = data.find(b'\n', pos)
        end = len(data) if nl < 0 else nl + 1
        out.append(data[pos:end])
        pos = end
    return out


def blocks(lines):
    """-> [(start, end)] line indices of every block, or None when a start
    marker has no end marker after it."""
    found, i = [], 0
    while i < len(lines):
        if START_BYTES.match(lines[i].rstrip(b'\n')):
            j = i + 1
            while j < len(lines) and not END_BYTES.match(lines[j].rstrip(b'\n')):
                j += 1
            if j == len(lines):
                return None
            found.append((i, j))
            i = j + 1
            continue
        i += 1
    return found


def strip(path):
    """Every block, start line through end line, removed; every other byte
    exactly as it was."""
    try:
        with open(path, 'rb') as f:
            data = f.read()
    except OSError:
        return 65
    lines = lines_of(data)
    found = blocks(lines)
    if found is None:
        return 65
    drop = {n for i, j in found for n in range(i, j + 1)}
    sys.stdout.buffer.write(b''.join(line for n, line in enumerate(lines) if n not in drop))
    return 0


def main(argv):
    if not argv:
        print('usage: fm_local_tests.py run|summary <file>|strip <file>', file=sys.stderr)
        return 64
    command, rest = argv[0], argv[1:]
    if command == 'run':
        return run(rest)
    if command in ('summary', 'strip') and len(rest) == 1:
        return summary(rest[0]) if command == 'summary' else strip(rest[0])
    print('usage: fm_local_tests.py run|summary <file>|strip <file>', file=sys.stderr)
    return 64


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
