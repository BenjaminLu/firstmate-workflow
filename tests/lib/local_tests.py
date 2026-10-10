"""Fixtures and named checks for tests/local-tests.test.sh (T-275).

    local_tests.py runner <root> <runner.py>   the runner's own behaviour
    local_tests.py blocks <root>               external note delivery blocks
    local_tests.py uid-guard <root>            a folder another user owns
    local_tests.py zh-cn <root> <text>         the board's zh-CN conversion
    local_tests.py sample <name>               a captured refusal text

The runner under test is the copy a real worker round's prompt named
(tests/local-tests.test.sh's test adapter copies it out of the round), never
bin/lib/fm_local_tests.py read directly. Every fixture suite is generated in
a temporary directory here; none is committed under tests/. Each check
prints one line in tests/lib.sh's format.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

# --- refusal texts captured inside real round sandboxes ----------------------
# Each was printed by the real tool inside a worker round on macOS 15 (Darwin
# 24.6), under `bin/fm-sandbox.sh run` with the worker policy, and is kept
# verbatim. tests/sandbox-kernel.test.sh re-checks the ps and pseudo-terminal
# samples live where a real sandbox can run.
SAMPLES = {
    # bash -c 'ps -o pid= -p $$'
    'ps': 'bash: /bin/ps: Operation not permitted',
    # python3 -c 'import os; os.openpty()'
    'pty': ('Traceback (most recent call last):\n'
            '  File "<string>", line 1, in <module>\n'
            '    import os; os.openpty()\n'
            '               ~~~~~~~~~~^^\n'
            'PermissionError: [Errno 1] Operation not permitted'),
    # sandbox-exec -p '(version 1)(allow default)' true
    'sandbox': 'sandbox-exec: sandbox_apply: Operation not permitted',
    # docker info (its stderr)
    'docker': 'permission denied while trying to connect to the docker API at unix:///var/run/docker.sock',
    # curl -sS --noproxy '*' https://example.com
    'resolve': 'curl: (6) Could not resolve host: example.com',
    # git ls-remote https://example.com/x.git (through the round's proxy)
    'git-proxy': "fatal: unable to access 'https://example.com/x.git/': CONNECT tunnel failed, response 403",
    # curl -sS https://example.com (through the round's proxy): names no host
    'proxy': 'curl: (56) CONNECT tunnel failed, response 403',
}
TEMPLATE = 'case {file} in *.test.sh) bash {file} ;; esac'
CAP_REASON = 'more than 3 suites name a changed file; CI runs them'

failures = 0


def check(name, ok, why=''):
    global failures
    line = '    %-52s' % name
    if ok:
        print(line + 'ok')
    else:
        failures += 1
        print(line + 'FAIL\n      ' + str(why).replace('\n', '\n      '))
    sys.stdout.flush()


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # a zombie this process does not own still answers; ps says otherwise
    try:
        state = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True,
                               text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return True
    return bool(state) and not state.startswith('Z')


def gone(pids, wait=8):
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if not any(alive(p) for p in pids):
            return True
        time.sleep(0.1)
    return not any(alive(p) for p in pids)


# --- a fixture worktree and a round folder ----------------------------------
def suite(name, body='', exit_code=0, lines=('a check passes',)):
    """A generated fixture suite: records that it ran, prints assertion lines
    in tests/lib.sh's shape, then runs <body>."""
    out = ['#!/usr/bin/env bash', 'printf "%s\\n" "' + name + '" >> "$LTX_RAN"']
    for line in lines:
        out.append("printf '    %%-52s%%s\\n' %s ok" % json.dumps(line))
    out.append(body)
    out.append('exit %d' % exit_code)
    return '\n'.join(out) + '\n'


class Case:
    def __init__(self, base, runner, files, plan=None):
        self.dir = Path(tempfile.mkdtemp(prefix='lt-case.', dir=base))
        self.repo = self.dir / 'repo'
        self.folder = self.dir / 'run' / 'local-tests'
        self.folder.mkdir(parents=True)
        self.stubs = self.dir / 'stubs'
        self.stubs.mkdir()
        self.ran = self.dir / 'ran'
        self.ran.write_text('')
        shutil.copy(runner, self.folder / 'runner.py')
        self.repo.mkdir()
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.email', 'a@b.c')
        self.git('config', 'user.name', 't')
        for path, text in files.items():
            self.write(path, text)
        self.git('add', '-A')
        self.git('commit', '-qm', 'base', '--allow-empty')
        self.base = self.git('rev-parse', 'HEAD').strip()
        self.plan(**(plan or {}))
        for name in ('ps', 'sandbox-exec', 'bwrap', 'docker'):
            self.stub(name, 'exit 0')

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.repo)] + list(args), check=True,
                              capture_output=True, text=True).stdout

    def write(self, path, text):
        full = self.repo / path
        full.parent.mkdir(parents=True, exist_ok=True)
        full.write_text(text)

    def plan(self, **over):
        plan = dict(schema=1, base=self.base, tests=['tests/**', '*.test.*', '*.spec.*'],
                    test=TEMPLATE, check_env={}, docs=['design/**', 'README.md'], unrunnable=None,
                    budget_seconds=900, network=[], suite_seconds=300, jobs=1)
        plan.update(over)
        (self.folder / 'plan.json').write_text(json.dumps(plan))

    def stub(self, name, body):
        path = self.stubs / name
        path.write_text('#!/usr/bin/env bash\n' + body + '\n')
        path.chmod(0o755)

    def env(self, extra=None):
        env = dict(os.environ)
        env['PATH'] = str(self.stubs) + os.pathsep + env.get('PATH', '')
        env['LTX_RAN'] = str(self.ran)
        env.pop('FM_LOCAL_TESTS_NO_PTY', None)
        env.update(extra or {})
        return env

    def popen(self, *args, extra=None):
        return subprocess.Popen([sys.executable, str(self.folder / 'runner.py'), 'run'] + list(args),
                                cwd=self.repo, env=self.env(extra), stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def run(self, *args, extra=None):
        p = self.popen(*args, extra=extra)
        out, err = p.communicate(timeout=240)
        self.rc, self.out, self.err = p.returncode, out, err
        return self

    def ran_list(self):
        return [x for x in self.ran.read_text().splitlines() if x]

    def say(self):
        path = self.repo / '.fm-say.md'
        return path.read_text() if path.exists() else None

    def rows(self):
        """{suite: (result, seconds, detail)} and the row order, from the block."""
        text = self.say() or ''
        rows, order = {}, []
        for line in text.splitlines():
            if not line.startswith('| ') or line.startswith('| Suite ') or line.startswith('| ---'):
                continue
            cells = [c.strip() for c in split_cells(line)]
            rows[cells[0]] = (cells[1], cells[2], cells[3])
            order.append(cells[0])
        return rows, order

    def summary(self):
        p = subprocess.run([sys.executable, str(self.folder / 'runner.py'), 'summary',
                            str(self.repo / '.fm-say.md')], capture_output=True, text=True)
        return p.returncode, p.stdout


def split_cells(line):
    cells, cur, i = [], '', 1
    body = line.strip()
    while i < len(body) - 1:
        if body[i] == '\\' and body[i + 1] == '|':
            cur += '\\|'
            i += 2
            continue
        if body[i] == '|':
            cells.append(cur)
            cur = ''
        else:
            cur += body[i]
        i += 1
    cells.append(cur)
    return cells


# --- the runner's own behaviour ----------------------------------------------
def runner_checks(base, runner):
    impl = {'src/impl.py': 'print(1)\n', 'src/other.txt': 'x\n'}

    # the long run first, in the background: a probe that never answers and a
    # budget that runs out
    long = Case(base, runner, dict(impl, **{
        'tests/hang.test.sh': suite('hang', '(sleep 300 & echo $! > "$LTX_DIR/child"); sleep 300'),
        'tests/late.test.sh': suite('late'),
    }), plan=dict(budget_seconds=60))
    long.stub('docker', 'echo $$ > "$LTX_DIR/docker"; sleep 300')
    long.write('tests/hang.test.sh', suite('hang', '(sleep 300 & echo $! > "$LTX_DIR/child"); sleep 300') + '\n')
    long.write('tests/late.test.sh', suite('late') + '\n')
    long_p = long.popen(extra=dict(LTX_DIR=str(long.dir)))
    long_started = time.monotonic()

    # selection: a changed suite
    c = Case(base, runner, dict(impl, **{'tests/a.test.sh': suite('a'), 'tests/z.test.sh': suite('z')}))
    c.write('tests/a.test.sh', suite('a') + '# changed\n')
    c.run()
    rows, _ = c.rows()
    check('a changed suite is selected and passes', rows.get('tests/a.test.sh', ('',))[0] == 'passed', rows)
    check('no suite outside the selection rules runs', c.ran_list() == ['a'], c.ran_list())
    code, got = c.summary()
    check('summary reads back the numbers run wrote', code == 0 and json.loads(got) == dict(
        passed=1, failed=0, timed_out=0, not_runnable=0, not_run=0, budget_seconds=900,
        used_seconds=json.loads(got)['used_seconds'] if code == 0 else -1, changed_files=1), (code, got))
    check('run exits 0 when nothing failed', c.rc == 0, (c.rc, c.err))
    check('run prints the table', '| tests/a.test.sh | passed |' in c.out, c.out)

    # a suite that names a changed implementation file
    c = Case(base, runner, dict(impl, **{'tests/b.test.sh': suite('b') + '# covers src/impl.py\n',
                                         'tests/z.test.sh': suite('z')}))
    c.write('src/impl.py', 'print(2)\n')
    c.run()
    rows, _ = c.rows()
    check('a suite naming a changed implementation file runs', 'tests/b.test.sh' in rows
          and c.ran_list() == ['b'], (rows, c.ran_list()))

    # --suite
    c = Case(base, runner, dict(impl, **{'tests/c.test.sh': suite('c'), 'tests/z.test.sh': suite('z')}))
    c.write('src/other.txt', 'y\n')
    c.run('--suite', 'tests/c.test.sh')
    rows, _ = c.rows()
    check('a --suite suite is selected', rows.get('tests/c.test.sh', ('',))[0] == 'passed'
          and c.ran_list() == ['c'], (rows, c.ran_list()))

    # the cap of 3
    many = {'tests/n%d.test.sh' % i: suite('n%d' % i) + '# impl.py\n' for i in range(4)}
    c = Case(base, runner, dict(impl, **many))
    c.write('src/impl.py', 'print(2)\n')
    c.run()
    rows, _ = c.rows()
    check('4 suites naming a changed file are all not run',
          len(rows) == 4 and all(r[0] == 'not run' and r[2] == CAP_REASON for r in rows.values())
          and c.ran_list() == [], (rows, c.ran_list()))
    three = {k: v for k, v in list(many.items())[:3]}
    c = Case(base, runner, dict(impl, **three))
    c.write('src/impl.py', 'print(2)\n')
    c.run()
    rows, _ = c.rows()
    check('3 suites naming a changed file all run', len(rows) == 3
          and all(r[0] == 'passed' for r in rows.values()) and len(c.ran_list()) == 3, rows)
    # a changed suite that also names a changed file is not counted
    c = Case(base, runner, dict(impl, **many))
    c.write('src/impl.py', 'print(2)\n')
    c.write('tests/n0.test.sh', many['tests/n0.test.sh'] + '# changed\n')
    c.run()
    rows, order = c.rows()
    check('a changed suite naming a changed file skips the cap',
          len(rows) == 4 and all(r[0] == 'passed' for r in rows.values())
          and order.count('tests/n0.test.sh') == 1 and order[0] == 'tests/n0.test.sh', (order, rows))

    # --case
    c = Case(base, runner, dict(impl, **{'tests/c.test.sh': suite('c'), 'tests/d.test.sh': suite('d')}))
    c.write('tests/d.test.sh', suite('d') + '# changed\n')
    c.run('--case', 'loose one', '--suite', 'tests/c.test.sh', '--case', 'named one', '--case', 'named two')
    rows, _ = c.rows()
    check('--case after --suite runs the whole suite',
          rows.get('tests/c.test.sh', ('', '', ''))[2].startswith('case filter not supported: named one, named two')
          and rows['tests/c.test.sh'][0] == 'passed' and 'c' in c.ran_list(), rows)
    check('--case without --suite applies to changed suites',
          rows.get('tests/d.test.sh', ('', '', ''))[2].startswith('case filter not supported: loose one'), rows)
    c = Case(base, runner, dict(impl, **{'tests/b.test.sh': suite('b') + '# impl.py\n'}))
    c.write('src/impl.py', 'print(2)\n')
    c.run('--case', 'nobody')
    rows, _ = c.rows()
    check('--case with no suite to apply to matches none',
          '--case names matched no suite' in c.out and list(rows) == ['tests/b.test.sh']
          and 'case filter' not in rows['tests/b.test.sh'][2] and c.rc == 0, (c.out, rows, c.rc))

    # docs
    c = Case(base, runner, dict(impl, **{'design/notes.md': 'x\n', 'tests/e.test.sh': suite('e') + '# notes.md\n'}))
    c.write('design/notes.md', 'y\n')
    c.run()
    rows, _ = c.rows()
    check('a docs-only change selects no suite', rows == {} and c.ran_list() == [], rows)

    # order
    files = dict(impl, **{
        'tests/zz.test.sh': suite('zz') + '# impl.py other.txt\n',
        'tests/bb.test.sh': suite('bb') + '# impl.py\n' + '#' * 400 + '\n',
        'tests/aa.test.sh': suite('aa') + '# impl.py\n' + '#' * 400 + '\n',
        'tests/cc.test.sh': suite('cc') + '# other.txt\n',
        'tests/x2.test.sh': suite('x2'), 'tests/x1.test.sh': suite('x1')})
    c = Case(base, runner, files)
    c.write('src/impl.py', 'print(2)\n')
    c.write('src/other.txt', 'y\n')
    c.write('tests/x2.test.sh', files['tests/x2.test.sh'] + '# changed\n')
    c.write('tests/x1.test.sh', files['tests/x1.test.sh'] + '# changed\n')
    c.run('--suite', 'tests/zz.test.sh')
    rows, order = c.rows()
    check('order: --suite, changed by path, then most names',
          order == ['tests/zz.test.sh', 'tests/x1.test.sh', 'tests/x2.test.sh', 'tests/cc.test.sh',
                    'tests/aa.test.sh', 'tests/bb.test.sh'], order)
    # two --suite paths out of order, and one of them named a second way
    c = Case(base, runner, dict(impl, **{'tests/p2.test.sh': suite('p2'), 'tests/p1.test.sh': suite('p1')}))
    c.write('src/impl.py', 'print(2)\n')
    c.run('--suite', 'tests/p2.test.sh', '--case', 'first', '--suite', 'tests/p1.test.sh',
          '--suite', './tests/p2.test.sh', '--case', 'second')
    rows, order = c.rows()
    check('order: --suite suites sorted by path, one named twice selected once',
          order == ['tests/p1.test.sh', 'tests/p2.test.sh'] and sorted(c.ran_list()) == ['p1', 'p2'], (order, c.ran_list()))
    check('order: the cases of a suite named twice are kept together',
          rows.get('tests/p2.test.sh', ('', '', ''))[2].startswith('case filter not supported: first, second'), rows)

    # results
    c = Case(base, runner, dict(impl, **{
        'tests/f.test.sh': suite('f', exit_code=1, lines=['first fine']) + '\n',
        'tests/lib/helper.py': 'x = 1\n'}))
    body = ''.join("printf '    %%-52s%%s\\n' 'broken %d' FAIL\n" % i for i in range(7))
    c.write('tests/f.test.sh', suite('f', body, exit_code=1, lines=['first fine']))
    c.write('tests/lib/helper.py', 'x = 2\n')
    c.run()
    rows, _ = c.rows()
    detail = rows.get('tests/f.test.sh', ('', '', ''))[2]
    check('failed with up to 5 failing assertion names', rows.get('tests/f.test.sh', ('',))[0] == 'failed'
          and 'broken 0, broken 1, broken 2, broken 3, broken 4' in detail and 'broken 5' not in detail, detail)
    check('a helper file the template skips is not a suite',
          rows.get('tests/lib/helper.py', ('',))[0] == 'not a suite', rows)
    code, got = c.summary()
    check('not a suite rows are not counted', code == 0 and json.loads(got)['failed'] == 1
          and json.loads(got)['passed'] == 0, got)
    check('run exits 1 when a suite failed', c.rc == 1, c.rc)

    # descendants, environment, stdin
    c = Case(base, runner, dict(impl, **{'tests/g.test.sh': suite('g')}),
             plan=dict(check_env={'LTX_FROM_CONTRACT': 'contract value'}))
    c.write('tests/g.test.sh', suite('g', '\n'.join([
        '(sleep 300 & echo $! > "$LTX_DIR/child")',
        'python3 -c "import os,sys; print(os.getpgid(0))" > "$LTX_DIR/pgid"',
        'printf "%s|%s|%s|%s|%s|%s\\n" "$FIRSTMATE_CI_SESSION" "$FM_SESSION_PID" "$FM_ROOT" '
        '"$LC_MESSAGES" "$LTX_FROM_CONTRACT" "${LC_ALL-unset}" > "$LTX_DIR/env"',
        'wc -c < /dev/stdin | tr -d " " > "$LTX_DIR/stdin"'])))
    c.run(extra=dict(LTX_DIR=str(c.dir)))
    child = int((c.dir / 'child').read_text())
    check('a descendant a suite leaves is ended after it exits', gone([child]), child)
    session, pid, root, messages, contract, lc_all = (c.dir / 'env').read_text().strip().split('|')
    pgid = (c.dir / 'pgid').read_text().strip()
    check('the suite shell is its session and process group', session == pid == pgid, (session, pid, pgid))
    check('suite env: FM_ROOT, LC_MESSAGES and check_env',
          root == str(c.repo.resolve()) and messages == 'C' and contract == 'contract value'
          and lc_all == '', (root, messages, contract, lc_all))
    check('the suite reads empty standard input', (c.dir / 'stdin').read_text().strip() == '0')

    # at most `jobs` suites at once
    timed = {'tests/j%d.test.sh' % i: suite('j%d' % i, 'python3 -c "import time; print(\'start\', time.time())" '
             '>> "$LTX_DIR/times.%d"; sleep 1; python3 -c "import time; print(\'end\', time.time())" '
             '>> "$LTX_DIR/times.%d"' % (i, i)) for i in range(4)}
    c = Case(base, runner, dict(impl, **timed), plan=dict(jobs=2))
    for path, text in timed.items():
        c.write(path, text + '# changed\n')
    c.run(extra=dict(LTX_DIR=str(c.dir)))
    spans = []
    for i in range(4):
        got = dict(line.split() for line in (c.dir / ('times.%d' % i)).read_text().splitlines())
        spans.append((float(got['start']), float(got['end'])))
    peak = max(sum(1 for s, e in spans if s <= t < e) for t, _ in spans)
    check('at most jobs suites run at once', peak == 2, spans)

    # unrunnable, no template, wrong arguments, a plan that does not read
    c = Case(base, runner, dict(impl, **{'tests/a.test.sh': suite('a')}), plan=dict(unrunnable='needs a GPU'))
    c.write('tests/a.test.sh', suite('a') + '# changed\n')
    c.run()
    rows, _ = c.rows()
    check('a contract unrunnable reason runs nothing',
          rows.get('tests/a.test.sh', ('', '', ''))[0] == 'not runnable here'
          and 'needs a GPU' in rows['tests/a.test.sh'][2] and c.ran_list() == [], rows)
    c = Case(base, runner, dict(impl, **{'tests/a.test.sh': suite('a')}), plan=dict(test=None))
    c.write('tests/a.test.sh', suite('a') + '# changed\n')
    c.run()
    rows, _ = c.rows()
    code, got = c.summary()
    check('no test template: one uncounted row and zero counts',
          list(rows.values()) == [('-', '0', 'no test template declared')] and c.ran_list() == []
          and code == 0 and sum(json.loads(got)[k] for k in ('passed', 'failed', 'timed_out',
                                                             'not_runnable', 'not_run')) == 0, (rows, got))
    c.run('--full')
    check('--full is refused as an unknown option', c.rc == 64, (c.rc, c.err))
    c.run('--bogus')
    check('an unknown option exits 64', c.rc == 64, (c.rc, c.err))
    (c.folder / 'plan.json').unlink()
    c.run()
    check('a missing plan exits 70', c.rc == 70, (c.rc, c.err))
    c.plan(check='bin/ci.sh')
    c.run()
    check('a plan of the wrong shape exits 70', c.rc == 70, (c.rc, c.err))

    # the block: replacement, no change, cleanup
    c = Case(base, runner, dict(impl, **{'tests/a.test.sh': suite('a')}))
    c.write('tests/a.test.sh', suite('a') + '# changed\n')
    note = b'ASK-PASS-CRITERIA:T-Z\nwhat does done mean?\n'
    (c.repo / '.fm-say.md').write_bytes(note)
    c.run()
    c.run()
    data = (c.repo / '.fm-say.md').read_bytes()
    check('a rerun replaces the block, keeps the ASK- marker',
          data.startswith(note) and data.count(b'<!-- fm-local-tests v1 -->') == 1
          and data.count(b'<!-- /fm-local-tests -->') == 1, data)
    c = Case(base, runner, dict(impl, **{'tests/a.test.sh': suite('a')}))
    c.run('--suite', 'tests/a.test.sh')
    check('no changed file: nothing runs or is written',
          c.say() is None and c.ran_list() == [] and 'No file changed' in c.out and c.rc == 0, (c.out, c.say()))
    c = Case(base, runner, dict(impl, **{'tests/h.test.sh': suite('h')}))
    home = os.path.expanduser('~')
    name = '\x1b[31m' + str(c.dir / 'run') + '/x\x07 | ' + home + '/y ' + 'w' * 300
    c.write('tests/h.test.sh', suite('h', "printf '    %%-52s%%s\\n' %s FAIL" % json.dumps(name), exit_code=1))
    c.run()
    rows, _ = c.rows()
    detail = rows.get('tests/h.test.sh', ('', '', ''))[2]
    check('paths and control characters are cleaned',
          '<round>/x' in detail and '\\|' in detail and '~/y' in detail and '\x1b' not in detail
          and '\x07' not in detail and str(c.dir) not in (c.say() or '') and len(detail.replace('\\|', '|')) <= 200,
          detail)

    # the changed files: union, and an unknown base
    c = Case(base, runner, dict(impl, **{'src/staged.txt': 'a\n', 'src/unstaged.txt': 'a\n'}))
    c.write('src/staged.txt', 'b\n')
    c.git('add', 'src/staged.txt')
    c.write('src/unstaged.txt', 'b\n')
    c.write('src/untracked.txt', 'b\n')
    c.run()
    code, got = c.summary()
    check('changed files: staged, unstaged and untracked', code == 0 and json.loads(got)['changed_files'] == 3, got)
    c = Case(base, runner, dict(impl, **{'tests/a.test.sh': suite('a'), 'tests/k.test.sh': suite('k')}))
    c.write('tests/k.test.sh', suite('k') + '# committed\n')
    c.git('commit', '-qam', 'committed on the branch')
    c.write('tests/a.test.sh', suite('a') + '# uncommitted\n')
    c.plan(base=None)
    c.run()
    rows, _ = c.rows()
    check('an unknown base counts only uncommitted changes',
          list(rows) == ['tests/a.test.sh'] and 'only uncommitted changes were counted' in (c.say() or ''), rows)

    # probes and the not-runnable rule
    probe_cases(base, runner, impl)

    # a ps that answers after 7 seconds still works
    c = Case(base, runner, dict(impl, **{'tests/a.test.sh': suite('a')}))
    c.write('tests/a.test.sh', suite('a') + '# changed\n')
    c.stub('ps', 'sleep 7; echo $$')
    c.run()
    check('a ps answering after 7 seconds counts as working', 'ps works' in (c.say() or ''), c.say())

    # SIGTERM while a suite runs, and while a probe runs
    c = Case(base, runner, dict(impl, **{'tests/s.test.sh': suite('s')}))
    c.write('tests/s.test.sh', suite('s', 'echo $$ > "$LTX_DIR/suite"; (sleep 300 & echo $! > "$LTX_DIR/child"); sleep 300'))
    p = c.popen(extra=dict(LTX_DIR=str(c.dir)))
    stopped = wait_for(c.dir / 'child') and wait_for(c.dir / 'suite')
    p.send_signal(signal.SIGTERM)
    p.communicate(timeout=30)
    pids = [int((c.dir / n).read_text()) for n in ('suite', 'child') if (c.dir / n).exists()]
    check('SIGTERM ends every suite and writes no block', stopped and p.returncode == 143
          and gone(pids) and c.say() is None, (p.returncode, pids, c.say()))
    c = Case(base, runner, dict(impl, **{'tests/s.test.sh': suite('s')}))
    c.write('tests/s.test.sh', suite('s') + '# changed\n')
    c.stub('docker', 'echo $$ > "$LTX_DIR/docker"; sleep 300')
    p = c.popen(extra=dict(LTX_DIR=str(c.dir)))
    stopped = wait_for(c.dir / 'docker')
    p.send_signal(signal.SIGTERM)
    p.communicate(timeout=30)
    pid = int((c.dir / 'docker').read_text()) if (c.dir / 'docker').exists() else -1
    check('SIGTERM ends a running probe and writes no block', stopped and p.returncode == 143
          and gone([pid]) and c.say() is None and c.ran_list() == [], (p.returncode, c.say()))

    # the long run
    out, err = long_p.communicate(timeout=240)
    elapsed = time.monotonic() - long_started
    rows, _ = long.rows()
    code, got = long.summary()
    say = long.say() or ''
    check('a hanging probe is ended after 10 seconds', 'docker missing (no answer in 10 seconds)' in say
          and gone([int((long.dir / 'docker').read_text())]), say)
    check('probe time counts against the budget', code == 0 and json.loads(got)['used_seconds'] >= 59
          and elapsed < 120, (got, elapsed))
    child = int((long.dir / 'child').read_text()) if (long.dir / 'child').exists() else -1
    check('a suite past its limit is timed out, its group gone',
          rows.get('tests/hang.test.sh', ('',))[0] == 'timed out' and gone([child]), rows)
    check('a suite never started is not run: budget used up',
          rows.get('tests/late.test.sh', ('', '', ''))[0] == 'not run'
          and 'budget' in rows['tests/late.test.sh'][2], rows)


def wait_for(path, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if path.exists() and path.read_text().strip():
            return True
        time.sleep(0.05)
    return False


def pty_here():
    try:
        a, b = os.openpty()
    except OSError:
        return False
    os.close(a)
    os.close(b)
    return True


def probe_cases(base, runner, impl):
    def one(sample, stub=None, failing=None, exit_code=1, network=(), pty=True):
        c = Case(base, runner, dict(impl, **{'tests/p.test.sh': suite('p')}), plan=dict(network=list(network)))
        text = SAMPLES[sample]
        c.write('tests/p.test.sh', suite('p', 'cat <<\'SAMPLE\'\n' + text + '\nSAMPLE', exit_code=exit_code))
        if stub:
            c.stub(stub, 'cat <<\'SAMPLE\'\n' + SAMPLES[failing or sample] + '\nSAMPLE\nexit 1')
        c.run(extra=None if pty else dict(FM_LOCAL_TESTS_NO_PTY='1'))
        rows, _ = c.rows()
        return rows.get('tests/p.test.sh', ('', '', ''))
    for label, sample, stubs in (('pseudo-terminal', 'pty', None), ('ps', 'ps', ['ps']),
                                 ('nested sandbox', 'sandbox', ['sandbox-exec', 'bwrap']),
                                 ('docker', 'docker', ['docker'])):
        if stubs is None:
            row = one(sample, pty=False)
        else:
            c = Case(base, runner, dict(impl, **{'tests/p.test.sh': suite('p')}))
            c.write('tests/p.test.sh', suite('p', 'cat <<\'SAMPLE\'\n' + SAMPLES[sample] + '\nSAMPLE', exit_code=1))
            for name in stubs:
                c.stub(name, 'cat <<\'SAMPLE\'\n' + SAMPLES[sample] + '\nSAMPLE\nexit 1')
            c.run()
            row = c.rows()[0].get('tests/p.test.sh', ('', '', ''))
        check('%s: matching line, failed probe' % label,
              row[0] == 'not runnable here' and row[2].startswith(label + ':'), row)
        if label == 'pseudo-terminal' and not pty_here():
            print('    (skipped: no pseudo-terminal here, so a working pty probe cannot be shown)')
            continue
        row = one(sample)
        check('%s: matching line, working probe' % label, row[0] == 'failed', row)
    row = one('docker', stub='docker', exit_code=0)
    check('a passing suite with a matching line passes', row[0] == 'passed', row)
    row = one('proxy', stub='docker', failing='docker')
    check('a failed probe without a matching line is failed', row[0] == 'failed', row)
    row = one('resolve')
    check('an undeclared host is not runnable here', row[0] == 'not runnable here'
          and row[2].startswith('network: example.com'), row)
    row = one('git-proxy')
    check('a proxy refusal naming a host is not runnable here', row[0] == 'not runnable here', row)
    row = one('resolve', network=['example.com'])
    check('a declared host that does not resolve is failed', row[0] == 'failed', row)
    row = one('proxy')
    check('a refusal line that names no host is failed', row[0] == 'failed', row)


def summary_checks(base, runner):
    """summary and strip, run as the launcher runs them, outside the round."""
    d = Path(tempfile.mkdtemp(prefix='lt-blocks.', dir=base))

    def summary(text):
        (d / 'say.md').write_bytes(text.encode())
        p = subprocess.run([sys.executable, runner, 'summary', str(d / 'say.md')], capture_output=True, text=True)
        return p.returncode, p.stdout

    def strip(data):
        (d / 'say.md').write_bytes(data)
        p = subprocess.run([sys.executable, runner, 'strip', str(d / 'say.md')], capture_output=True)
        return p.returncode, p.stdout
    good = dict(passed=1, failed=0, timed_out=0, not_runnable=0, not_run=0, budget_seconds=900,
                used_seconds=3, changed_files=2)
    block = lambda s, start='<!-- fm-local-tests v1 -->': (start + '\n<!-- fm-local-tests-summary ' + s
                                                           + ' -->\n## Local tests\n| sentinel-suite | passed | 1 | |\n'
                                                           '<!-- /fm-local-tests -->\n')
    code, out = summary('before\n' + block(json.dumps(good)) + 'after\n')
    check('summary exits 0 and prints the validated counts', code == 0 and json.loads(out) == good, (code, out))
    code, out = summary('no block here\n')
    check('summary exits 3 with no block', code == 3 and out == '', (code, out))
    bad = {
        'an extra path-bearing key': json.dumps(dict(good, path='/private/sentinel-path')),
        'a string count': json.dumps(dict(good, passed='1')),
        'a negative count': json.dumps(dict(good, failed=-1)),
        'a count past its range': json.dumps(dict(good, budget_seconds=7201)),
    }
    for label, text in bad.items():
        code, out = summary(block(text))
        check('summary refuses %s' % label, code == 65 and out == '', (code, out))
    code, out = summary(block(json.dumps(good)) + block(json.dumps(good)))
    check('summary refuses a second block', code == 65 and out == '', (code, out))
    code, out = summary(block(json.dumps(good)).replace('<!-- /fm-local-tests -->\n', ''))
    check('summary refuses a missing end marker', code == 65 and out == '', (code, out))
    code, out = summary(block(json.dumps(good), '<!-- fm-local-tests v2 -->'))
    check('summary refuses a v2 start marker', code == 65 and out == '', (code, out))

    one = block(json.dumps(good)).encode()
    plain = b'ASK-PASS-CRITERIA:T-Z\r\nno block\n\ttrailing \x0c bytes'
    code, out = strip(plain)
    check('strip leaves a file with no block byte-identical', code == 0 and out == plain, out)
    code, out = strip(one)
    check('strip of a block-only file is empty', code == 0 and out == b'', out)
    code, out = strip(b'before\n' + one + b'middle\n' + one + b'after')
    check('strip removes two blocks, keeps text around them', code == 0 and out == b'before\nmiddle\nafter', out)
    code, out = strip(b'kept\n' + one.replace(b'<!-- /fm-local-tests -->\n', b''))
    check('strip refuses a truncated block, printing nothing', code == 65 and out == b'', (code, out))
    code, out = strip(b'x\n' + block(json.dumps(good), '<!-- fm-local-tests v2 -->').encode() + b'y\n')
    check('strip removes a v2 block too', code == 0 and out == b'x\ny\n' and b'sentinel-suite' not in out, out)
    os.chmod(d / 'say.md', 0)
    p = subprocess.run([sys.executable, runner, 'strip', str(d / 'say.md')], capture_output=True)
    readable = os.access(d / 'say.md', os.R_OK)
    check('strip of an unreadable file exits 65', readable or (p.returncode == 65 and p.stdout == b''), p)
    os.chmod(d / 'say.md', 0o600)


# --- external note delivery, through the launcher's own blocks --------------
def block_checks(root):
    sys.path[:0] = [str(root / 'tests/lib'), str(root / 'bin/lib')]
    from crew_blocks import function, section, shell
    from fm_onboard import infer, approve
    worker = root / 'bin/fm-worker.sh'
    tmp = Path(tempfile.mkdtemp(prefix='lt-ext.'))
    evidence = dict(repository='owner/app', base='main', source='github', pulls=[], commits=[],
                    repository_info={'allow_squash_merge': True, 'allow_merge_commit': False,
                                     'allow_rebase_merge': False, 'delete_branch_on_merge': False},
                    protection={'status': 'unknown'})
    approve(tmp, evidence, infer(evidence), dict(confirmed=True, policy_confirmed=True, captain='captain',
            intent='Private intent', product='Private product', required_checks=['ci'],
            contract={'check': 'true'}, review='external', post='summary'))
    results = ('<!-- fm-local-tests v1 -->\n<!-- fm-local-tests-summary {"passed":1,"failed":1,"timed_out":0,'
               '"not_runnable":0,"not_run":0,"budget_seconds":900,"used_seconds":4,"changed_files":2} -->\n'
               '## Local tests\n\n| Suite | Result | Seconds | Detail |\n| --- | --- | --- | --- |\n'
               '| tests/private-sentinel-suite.test.sh | failed | 2 | exit 1; failing: private-sentinel-assertion |\n'
               '<!-- /fm-local-tests -->\n')
    notes = lambda: '\n'.join(p.read_text() for p in (tmp / 'state').rglob('*.md'))

    def clear():
        for name in ('comments', 'events', 'calls', 'log'):
            (tmp / name).unlink(missing_ok=True)
        for p in (tmp / 'state').rglob('*.md'):
            p.unlink()
    post = function(worker, 'note_landed') + function(worker, 'post_note')
    for mode in ('comments', 'summary', 'check', 'threads', 'local'):
        clear()
        (tmp / 'note').write_text('Worker words for the reviewer.\n\n' + results)
        p = shell(root, tmp, post + 'post_note "$work/note" 9; echo "rc=$? spoke=$spoke"',
                  'projection=%s; spoke=0; log="$work/log"; fm_external() { echo "$*" >> "$work/calls"; }' % mode)
        comments = (tmp / 'comments').read_text() if (tmp / 'comments').exists() else ''
        bodies = comment_bodies(comments)
        check('external %s: block kept privately' % mode,
              'private-sentinel-suite' in notes() and 'rc=0 spoke=1' in p.stdout, (p.stdout, p.stderr))
        check('external %s: no comment names a suite' % mode,
              'private-sentinel' not in comments + bodies, comments + bodies)
        if mode == 'comments':
            check('external comments: the worker words are posted', 'Worker words for the reviewer.' in bodies, bodies)
    # The plain-writing lint reads the note without its block: a glued
    # sentinel in a Detail cell never reaches the log, one in the words does.
    lint_log = tmp / 'state/runtime/plain-writing.jsonl'
    clear()
    lint_log.unlink(missing_ok=True)
    (tmp / 'note').write_text('Worker words kept7sentinel here.\n\n'
                              + results.replace('private-sentinel-assertion', 'leak7sentinel'))
    p = shell(root, tmp, post + 'post_note "$work/note" 9; echo "rc=$? spoke=$spoke"',
              'projection=comments; spoke=0; log="$work/log"')
    logged = lint_log.read_text() if lint_log.exists() else ''
    check('lint: the results block stays out of the plain-writing log (external comments)',
          'kept7sentinel' in logged and 'leak7sentinel' not in logged, (logged, p.stdout, p.stderr))
    clear()
    lint_log.unlink(missing_ok=True)
    (tmp / 'note').write_text('Worker words kept7sentinel here.\n\n'
                              + results.replace('<!-- /fm-local-tests -->\n', ''))
    p = shell(root, tmp, post + 'post_note "$work/note" 9; echo "rc=$? spoke=$spoke"',
              'projection=comments; spoke=0; log="$work/log"')
    log = (tmp / 'log').read_text() if (tmp / 'log').exists() else ''
    check('lint: a truncated block skips the lint (external comments)',
          'fm-worker: plain-writing lint skipped: the results block does not read' in log
          and not lint_log.exists(), (log, p.stdout, p.stderr))
    clear()
    (tmp / 'note').write_text(results)
    p = shell(root, tmp, post + 'post_note "$work/note" 9; echo "rc=$? spoke=$spoke"',
              'projection=comments; spoke=0; log="$work/log"')
    check('external block-only note posts no comment', not (tmp / 'comments').exists()
          and 'private-sentinel-suite' in notes(), p.stdout + p.stderr)
    truncated = 'Worker words beside a broken block.\n' + results.replace('<!-- /fm-local-tests -->\n', '')
    for pr in ('9', ''):
        clear()
        (tmp / 'note').write_text(truncated)
        retention = section(worker, 'asked=0\n', "# gh's own words")
        delivery = (section(worker, 'question_draft=0\n', "held=''\n")
                    + section(worker, 'if [ "$projection" = comments ] && [ "$asked" = 1 ] && [ -z "$PR" ]',
                              '\n# asking IS the work'))
        functions = ''.join(optional(function, worker, n) for n in (
            'say_has_words', 'note_landed', 'post_note', 'save_unsent', 'keep_unsent', 'note_refused',
            'note_unsent', 'local_tests_record'))
        p = shell(root, tmp, functions + 'local_tests_record\n' + retention + delivery
                  + 'echo "asked=$asked spoke=$spoke"',
                  'projection=comments; PR="%s"; held=""; rebuilt=0; round_number=1; NAME=worker; spoke=0;\n'
                  'say="$work/note"; log="$work/log"; rebuild_publishes() { return 1; }; '
                  'first_round_question() { return 1; };\n' % pr + EMIT_DATA)
        label = 'with PR' if pr else 'no PR'
        invalid_event(tmp, 'external truncated, %s' % label)
        check('external truncated, %s: asked, no comment' % label,
              'asked=1 spoke=1' in p.stdout and not (tmp / 'comments').exists(), (p.stdout, p.stderr))
        check('external truncated, %s: full private record' % label,
              'Worker words beside a broken block.' in notes() and 'private-sentinel-suite' in notes(), notes())
    for pr in ('9', ''):
        clear()
        (tmp / 'note').write_text('Worker words.\n' + results)
        os.chmod(tmp / 'note', 0)
        if os.access(tmp / 'note', os.R_OK):
            os.chmod(tmp / 'note', 0o600)
            check('external unreadable note: skipped as root', True)
            continue
        p = shell(root, tmp, functions + 'local_tests_record\n' + retention + delivery
                  + 'echo "continued asked=$asked"',
                  'projection=comments; PR="%s"; held=""; rebuilt=0; round_number=1; NAME=worker; spoke=0;\n'
                  'say="$work/note"; log="$work/log"; rebuild_publishes() { return 1; }; '
                  'first_round_question() { return 1; }; worker_changed_files() { return 1; };\n' % pr
                  + EMIT_DATA)
        os.chmod(tmp / 'note', 0o600)
        label = 'with PR' if pr else 'no PR'
        invalid_event(tmp, 'external unreadable note, %s' % label)
        expected = 73 if pr else 65
        check('external unreadable note, %s: no comment' % label, not (tmp / 'comments').exists(),
              (p.returncode, p.stdout, p.stderr))
        check('external unreadable note, %s: exits %d' % (label, expected), p.returncode == expected,
              (p.returncode, p.stdout, p.stderr))
    shutil.rmtree(tmp, ignore_errors=True)


# The launcher's emit, recording only the event data, one line per event.
EMIT_DATA = ('emit() { while [ $# -gt 0 ]; do [ "$1" != --data ] || printf \'%s\\n\' "$2" >> "$work/events"; '
             'shift; done; }\n')
INVALID = '{"evidence_event":"local_tests","local_tests":{"valid":false}}'


def invalid_event(tmp, label):
    """Exactly one valid:false local_tests event, and nothing of the report."""
    events = (tmp / 'events').read_text() if (tmp / 'events').exists() else ''
    check('%s: one valid:false event' % label, events.splitlines().count(INVALID) == 1, events)
    check('%s: nothing of the report in an event' % label, 'private-sentinel' not in events, events)


def optional(function, path, name):
    """A launcher function, or nothing on a launcher that has none."""
    try:
        return function(path, name)
    except AssertionError:
        return ''


def comment_bodies(calls):
    """The bodies a comment projection was handed (--body-file <path>)."""
    out = []
    for line in calls.splitlines():
        words = line.split()
        if '--body-file' in words:
            path = Path(words[words.index('--body-file') + 1])
            if path.exists():
                out.append(path.read_text())
    return '\n'.join(out)


# --- a folder another user owns ----------------------------------------------
def uid_guard(root, folder, run):
    sys.path.insert(0, str(root / 'bin/lib'))
    import fm_sandbox_policy as policy
    from unittest import mock
    grant = getattr(policy, 'local_tests_of', None)
    if grant is None:
        check('guard: a folder of another user is refused', False, 'the sandbox policy has no local tests grant')
        return
    with mock.patch.dict(os.environ, {'FM_LOCAL_TESTS_DIR': folder, 'FM_RUN_DIR': run}):
        accepted = grant() == folder
        with mock.patch.object(policy.os, 'getuid', return_value=os.getuid() + 1):
            try:
                grant()
                refused = False
            except ValueError:
                refused = True
    check('guard: a folder of another user is refused', accepted and refused, (accepted, refused))


def zh_cn(root, text):
    table = {}
    for line in (root / 'i18n/tw2cn.tsv').read_text().splitlines():
        if '\t' in line and not line.startswith('#'):
            tw, cn = line.split('\t')[:2]
            table[tw] = cn
    longest = max(map(len, table)) if table else 1
    out, i = '', 0
    while i < len(text):
        for n in range(min(longest, len(text) - i), 0, -1):
            if text[i:i + n] in table:
                out += table[text[i:i + n]]
                i += n
                break
        else:
            out += text[i]
            i += 1
    return out


def main(argv):
    command = argv[0]
    root = Path(argv[1]).resolve() if len(argv) > 1 else None
    if command == 'sample':
        print(SAMPLES[argv[1]])
        return 0
    if command == 'zh-cn':
        print(zh_cn(root, argv[2]))
        return 0
    if command == 'uid-guard':
        uid_guard(root, argv[2], argv[3])
    elif command == 'blocks':
        block_checks(root)
    elif command == 'runner':
        runner = argv[2]
        if not os.path.isfile(runner):
            check('the round prompt named a local test runner', False, 'no runner was copied out of the round')
            return 1
        base = tempfile.mkdtemp(prefix='lt-runner.')
        try:
            summary_checks(base, runner)
            runner_checks(base, runner)
        finally:
            shutil.rmtree(base, ignore_errors=True)
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
