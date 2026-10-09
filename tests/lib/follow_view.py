"""T-271: the formatted round view and the live-round dashboard.

Every case drives the existing entry points, `bin/fm-herdr.py follow` and
`bin/fm.sh follow`, and reads what they print; nothing imports the view.
On the base those print the raw log (or refuse --raw / --all), so each
formatting assertion is a behavioural failure there, not a setup error.
Cases named `regression` hold behaviour the base already has.

Terminal cases run in a pseudo-terminal. Where the host has none (an OS
sandbox can refuse it), they are skipped as setup, never passed.
"""
import ast
import fcntl
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

# Never notify a live Herdr from a fixture that runs fm.sh.
os.environ['HERDR_ENV'] = '0'
sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1)).resolve()
HERDR = ROOT / 'bin/fm-herdr.py'
FM = ROOT / 'bin/fm.sh'
VIEW = ROOT / 'bin/lib/fm_follow_view.py'
FIXTURES = ROOT / 'tests/fixtures/follow-view'
BASE_COMMIT = 'd9cba7a935333bdc963f399a91a0b38547d90e80'  # the base T-271 was cut from
ACTOR = 'worker-mira-t035-r1'
WAIT = 60
ANSI = re.compile(rb'\x1b\[[0-9;?]*[A-Za-z]|\x1b[78]')


def pty_available():
    try: master, slave = os.openpty()
    except OSError: return False
    os.close(master); os.close(slave)
    return True


PTY = pty_available()
PTY_SKIP = 'setup: no pseudo-terminal on this host; terminal cases not run (not behavioural)'


def visible(text):
    """The screen lines a terminal shows, with escape sequences removed."""
    return re.sub(r'\x1b\[[0-9;?]*[A-Za-z]|\x1b[78]', '\n', text).replace('\r', '\n').split('\n')


def jline(value):
    return json.dumps(value, separators=(',', ':'))


def codex_item(kind, ident, **fields):
    return jline({'type': 'item.completed', 'item': dict(id=ident, type=kind, **fields)})


def changes(*paths):
    return codex_item('file_change', 'fc-' + '-'.join(Path(p).name for p in paths),
                      changes=[dict(path=p, kind='update') for p in paths], status='completed')


def message(ident, text):
    return codex_item('agent_message', ident, text=text)


def heartbeat(seconds, actor=ACTOR):
    return f'[fm] {actor} still running ({seconds}s); vendor may buffer until complete'


def tree_state(*roots):
    """Every path under the roots with its kind, size, mode and mtime."""
    seen = {}
    for top in roots:
        top = Path(top)
        if not top.exists(): continue
        for path in [top, *sorted(top.rglob('*'))]:
            info = path.lstat()
            seen[str(path)] = (stat.S_IFMT(info.st_mode), info.st_size, info.st_mode, info.st_mtime_ns)
    return seen


class Pty:
    """A command on a pseudo-terminal of a set size; its output as bytes."""

    def __init__(self, argv, env, columns=80, rows=24):
        import pty
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            try:
                fcntl.ioctl(1, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
                os.execve(argv[0], argv, env)
            finally: os._exit(127)
        self.out, self.status = b'', None

    def pump(self, timeout=.1):
        ready, _, _ = select.select([self.fd], [], [], timeout)
        if not ready: return True
        try: chunk = os.read(self.fd, 65536)
        except OSError: chunk = b''
        self.out += chunk
        return bool(chunk)

    def until(self, predicate, timeout=WAIT):
        end = time.monotonic() + timeout
        while not predicate(self.text()):
            if time.monotonic() > end or not self.pump():
                raise AssertionError('not seen; output so far: %r' % self.out[-3000:])
        return self.text()

    def text(self):
        return self.out.decode('utf-8', 'replace')

    def resize(self, columns, rows=24):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
        os.kill(self.pid, signal.SIGWINCH)

    def wait(self, timeout=WAIT):
        end = time.monotonic() + timeout
        while self.status is None:
            self.pump()
            done, status = os.waitpid(self.pid, os.WNOHANG)
            if done: self.status = os.waitstatus_to_exitcode(status)
            elif time.monotonic() > end: raise AssertionError('still running: %r' % self.out[-2000:])
        while self.pump(.05) and select.select([self.fd], [], [], 0)[0]: pass
        return self.status

    def close(self):
        if self.status is None:
            try: os.kill(self.pid, signal.SIGKILL); os.waitpid(self.pid, 0)
            except OSError: pass
        os.close(self.fd)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='follow-view-')).resolve()
        self.addCleanup(self.remove_tmp)
        self.root = self.tmp / 'engine'
        (self.root / 'state/runs').mkdir(parents=True)
        (self.root / 'config.yaml').write_text('default_project: alpha\n')
        (self.tmp / 'home/.cache').mkdir(parents=True)
        (self.tmp / 'gitconfig').write_text('[user]\n\tname = t\n\temail = t@example.invalid\n[init]\n\tdefaultBranch = main\n')
        drop = ('FM_', 'GIT_', 'HERDR_', 'CMUX_', 'TMUX')
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(drop) and k not in ('NO_COLOR', 'COLUMNS', 'LINES')}
        self.env.update(HOME=str(self.tmp / 'home'), XDG_CACHE_HOME=str(self.tmp / 'home/.cache'),
                        FM_IN_ROUND='1', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=str(self.tmp / 'gitconfig'),
                        TERM='xterm', PYTHONDONTWRITEBYTECODE='1', GIT_CEILING_DIRECTORIES=str(self.tmp),
                        HERDR_ENV='0')

    def remove_tmp(self):
        for path in [self.tmp, *self.tmp.rglob('*')]:
            if path.is_dir() and not path.is_symlink(): path.chmod(0o755)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def attempt(self, log='', actor=ACTOR, vendor='codex', task='T-035', project='alpha', round_=1,
                finished=True, tree=None, identity=True, invocation=True, root=None):
        run = (root or self.root) / 'state/runs' / actor
        run.mkdir(parents=True, exist_ok=True)
        if identity:
            (run / 'identity.json').write_text(json.dumps(dict(
                actor=actor, role=actor.split('-')[0], task=task, name='mira', project=project,
                round=round_, attempt=1)))
        attempt = Path(tempfile.mkdtemp(prefix=vendor + '-', dir=run))
        if invocation is True:
            invocation = dict(adapter=f'/code/bin/adapters/{vendor}.sh', prompt=str(attempt / 'prompt.md'),
                              tree=str(tree or self.tmp / 'tree'), actor=actor, role='worker', task=task,
                              lifetime_tracking=True)
        if invocation: (attempt / 'invocation.json').write_text(json.dumps(invocation))
        (attempt / 'run.log').write_bytes(log if isinstance(log, bytes) else log.encode())
        if finished: (attempt / 'result.json').write_text('{"exit_code": 0}')
        return attempt

    def fixture(self, vendor):
        return (FIXTURES / (vendor + '.run.log')).read_text()

    def follow(self, attempt, *extra, env=None, code=HERDR):
        return subprocess.run([sys.executable, str(code), 'follow', str(attempt), *extra],
                              env=env or self.env, capture_output=True, timeout=WAIT)

    def fm(self, *args, env=None, root=None):
        return subprocess.run(['bash', str(FM), 'follow', *args, '--repo', str(root or self.root)],
                              env=env or self.env, capture_output=True, timeout=WAIT)

    def shown(self, done):
        self.assertEqual(0, done.returncode, done.stderr.decode())
        return done.stdout.decode()

    def runner(self):
        """A live process the liveness check takes for a round's runner."""
        proc = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(300)', 'fm-herdr.py'],
                                stdin=subprocess.DEVNULL)
        self.addCleanup(lambda: proc.poll() is None and (proc.kill(), proc.wait()))
        return proc

    def live(self, log='', **kw):
        attempt = self.attempt(log, finished=False, **kw)
        (attempt / 'runner.pid').write_text(f'{self.runner().pid}\n')
        return attempt

    def dead_pid(self):
        proc = subprocess.Popen(['true']); proc.wait()
        return proc.pid

    def start(self, attempt, env=None):
        out = open(self.tmp / ('follow-%d.out' % time.monotonic_ns()), 'w+b')
        self.addCleanup(out.close)
        proc = subprocess.Popen([sys.executable, str(HERDR), 'follow', str(attempt)], env=env or self.env,
                                stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT)
        self.addCleanup(lambda: proc.poll() is None and (proc.kill(), proc.wait()))
        return proc, Path(out.name)

    def eventually(self, predicate, timeout=WAIT, why=''):
        end = time.monotonic() + timeout
        while not predicate():
            if time.monotonic() > end: self.fail('timed out waiting: ' + why)
            time.sleep(.05)

    def append(self, path, text):
        with open(path, 'a') as out: out.write(text)

    def events(self, *events, root=None):
        log = (root or self.root) / 'state/events.jsonl'
        log.parent.mkdir(parents=True, exist_ok=True)
        self.append(log, ''.join(jline(dict({'ts': '2026-10-09T12:00:00Z'}, **e)) + '\n' for e in events))

    def git(self, tree, *args):
        return subprocess.run(['git', '-C', str(tree), *args], env=self.env, check=True, capture_output=True)

    def repo(self):
        """A worktree with one change of each kind against its last commit."""
        tree = self.tmp / 'tree'
        tree.mkdir()
        self.git(tree, 'init', '-q')
        for name, body in (('staged.py', 'value = 1\n'), ('unstaged.ts', 'let value = 1;\n'),
                           ('gone.txt', 'gone line\n'), ('old.txt', 'moved line\n'), ('same.md', '# same\n')):
            (tree / name).write_text(body)
        (tree / 'image.bin').write_bytes(b'\x00\x01\x02binary')
        self.git(tree, 'add', '-A'); self.git(tree, 'commit', '-qm', 'base')
        (tree / 'staged.py').write_text('value = 2\n'); self.git(tree, 'add', 'staged.py')
        (tree / 'unstaged.ts').write_text('let value = 2;\n')
        (tree / 'fresh.json').write_text('{"fresh": true}\n')
        (tree / 'gone.txt').unlink()
        self.git(tree, 'mv', 'old.txt', 'renamed.txt')
        (tree / 'image.bin').write_bytes(b'\x00\x03\x04binary')
        return tree

    def in_pty(self, argv, env=None, columns=80, rows=24):
        session = Pty(argv, env or self.env, columns, rows)
        self.addCleanup(session.close)
        return session

    def lines(self, text):
        return text.splitlines()

    def at(self, lines, line):
        """Where `line` is, as an assertion: on the base it is not there at all."""
        self.assertIn(line, lines)
        return lines.index(line)

    def find(self, lines, prefix):
        found = [line for line in lines if line.startswith(prefix)]
        self.assertTrue(found, f'no line starting {prefix!r} in {lines!r}')
        return found[0]


class FormattedLog(Fixture):
    def test_command_is_one_dollar_line(self):
        out = self.shown(self.follow(self.attempt(self.fixture('codex'))))
        self.assertIn("$ /bin/zsh -lc ls", self.lines(out))
        self.assertEqual(1, self.lines(out).count("$ /bin/zsh -lc ls"), 'started and completed: one line')
        self.assertNotIn('"type":"item.started"', out)

    def test_exit_code_marker(self):
        out = self.lines(self.shown(self.follow(self.attempt(self.fixture('codex')))))
        self.assertIn('  exit 0', out)
        self.assertIn('  exit 1', out)
        self.assertEqual("$ /bin/zsh -lc 'test -f missing'", out[self.at(out, '  exit 1') - 1])

    def test_collapsed_output_with_hidden_line_count(self):
        out = self.lines(self.shown(self.follow(self.attempt(self.fixture('codex')))))
        at = self.at(out, "$ /bin/zsh -lc 'seq 1 30'")
        self.assertEqual(['  1', '  2', '  3', '  4', '  5', '  ... 20 lines hidden ...',
                          '  26', '  27', '  28', '  29', '  30', '  exit 0'], out[at + 1:at + 13])
        at = self.at(out, "$ /bin/zsh -lc 'seq 1 10'")  # 2N lines are shown whole
        self.assertEqual(['  %d' % n for n in range(1, 11)] + ['  exit 0'], out[at + 1:at + 12])

    def test_follow_lines_limits_and_invalid_values(self):
        log = self.fixture('codex')
        out = self.lines(self.shown(self.follow(self.attempt(log), env=dict(self.env, FM_FOLLOW_LINES='1'))))
        at = self.at(out, "$ /bin/zsh -lc 'seq 1 30'")
        self.assertEqual(['  1', '  ... 28 lines hidden ...', '  30'], out[at + 1:at + 4])
        out = self.shown(self.follow(self.attempt(log), env=dict(self.env, FM_FOLLOW_LINES='200')))
        self.assertNotIn('lines hidden', out)
        for bad in ('0', '201', 'abc', '2.5', '-3', ' 7'):
            with self.subTest(value=bad):
                out = self.shown(self.follow(self.attempt(log), env=dict(self.env, FM_FOLLOW_LINES=bad)))
                self.assertEqual(1, out.count('FM_FOLLOW_LINES must be a whole number from 1 to 200'), out)
                self.assertIn('  ... 20 lines hidden ...', out)

    def test_message_marker(self):
        out = self.lines(self.shown(self.follow(self.attempt(self.fixture('codex')))))
        self.assertIn('> I read the task and listed the tree; the change is ready for review.', out)

    def test_web_search_is_one_line(self):
        out = self.lines(self.shown(self.follow(self.attempt(self.fixture('codex')))))
        self.assertEqual(['search: python pty window resize'], [l for l in out if l.startswith('search:')])

    def test_every_adapters_final_object_is_a_message(self):
        for vendor, said in (('claude', 'Claude finished: the follower test passes.'),
                             ('cursor-agent', 'Cursor finished: two files changed.'),
                             ('gemini', 'Gemini finished: the header shows the pull request.')):
            with self.subTest(vendor=vendor):
                out = self.shown(self.follow(self.attempt(self.fixture(vendor), vendor=vendor)))
                self.assertIn('> ' + said, self.lines(out))
                self.assertNotIn('"session_id"', out)
                self.assertNotIn('"stats"', out)

    def test_mock_and_plain_text_pass_through(self):
        out = self.lines(self.shown(self.follow(self.attempt(self.fixture('mock'), vendor='mock'))))
        for line in ('mock adapter', 'prompt: 2048 bytes', 'exit: 0'):
            self.assertIn(line, out)
        self.assertIn('== [fm] worker-dora-t035-r1 worker started on T-035 (pid 8181)', out)

    def test_regression_unparseable_lines_print_as_plain_text(self):
        out = self.lines(self.shown(self.follow(self.attempt(self.fixture('codex')))))
        self.assertIn('Reconnecting... 1/5 (stream disconnected before completion)', out)
        self.assertIn('{not json at all', out)

    def test_status_lines_keep_their_words(self):
        out = self.shown(self.follow(self.attempt(self.fixture('codex'))))
        self.assertIn('== [fm] worker-mira-t035-r1 worker started on T-035 (pid 4242)', self.lines(out))
        self.assertIn('finished exit=0', out)
        self.assertIn('!! fm-sandbox: macos profile, network limited to the declared registries', self.lines(out))
        self.assertNotIn('thread.started', out)
        self.assertNotIn('turn.completed', out)

    def test_plain_heartbeat_at_most_once_a_minute(self):
        out = self.shown(self.follow(self.attempt(self.fixture('claude'), vendor='claude')))
        self.assertEqual(1, out.count('still running ('), out)

    def test_control_sequences_are_removed(self):
        evil = '\x1b[2J\x1b]0;owned\x07\x1b[31mred\x1b[0m\x07\x08\r'
        log = '\n'.join(['plain ' + evil, message('m', 'said ' + evil),
                         codex_item('command_execution', 'c', command='echo ' + evil,
                                    aggregated_output='out ' + evil + '\n', exit_code=0)]) + '\n'
        out = self.shown(self.follow(self.attempt(log)))
        self.assertNotIn('\x1b', out)
        self.assertNotIn('\x07', out)
        self.assertNotIn('\r', out)
        for line in ('plain red', '> said red', '$ echo red', '  out red'):
            self.assertIn(line, self.lines(out))

    def test_partial_last_line_is_printed_once(self):
        out = self.shown(self.follow(self.attempt('first\nheld without newline')))
        self.assertEqual(1, out.count('held without newline'))
        self.assertIn('held without newline', self.lines(out))
        # a record cut mid-line by the writer is read whole, once
        record = message('m', 'one whole message') + '\n'
        attempt = self.live('first\n' + record[:30])
        proc, shown = self.start(attempt)
        self.eventually(lambda: 'first' in shown.read_text(), why='first line')
        time.sleep(.5)
        self.append(attempt / 'run.log', record[30:])
        (attempt / 'result.json').write_text('{}')
        self.assertEqual(0, proc.wait(timeout=WAIT))
        self.assertEqual(['> one whole message'], [l for l in self.lines(shown.read_text()) if 'whole message' in l])


class Header(Fixture):
    def head(self, attempt, env=None, code=HERDR):
        return (self.lines(self.shown(self.follow(attempt, env=env, code=code))) + ['', ''])[:2]

    def test_header_names_actor_task_round_pr_elapsed_and_activity(self):
        first, now = self.head(self.attempt(self.fixture('codex'), round_=3))
        self.assertRegex(first, r'^worker-mira-t035-r1  T-035  round 3  no PR yet  [0-9]+s$')
        self.assertTrue(now.startswith('now: '), now)
        self.assertIn('vendor silence: unknown', now)

    def test_header_pr_with_same_task_in_two_projects(self):
        attempt = self.attempt(self.fixture('mock'), vendor='mock', task='T-9')
        self.events(dict(actor='x', type='pr_opened', project='alpha', task='T-9', pr=41),
                    dict(actor='x', type='pr_opened', project='beta', task='T-9', pr=50),
                    dict(actor='x', type='crew_status', project='alpha', task='T-10', pr=60))
        self.assertIn('  PR #41  ', self.head(attempt)[0])

    def test_header_pr_from_a_legacy_event_without_project(self):
        mine = self.attempt('x\n', task='T-9')
        theirs = self.attempt('x\n', actor='worker-ada-t9-r1', task='T-9', project='beta')
        self.events(dict(actor='x', type='pr_opened', task='T-9', pr=33))
        self.assertIn('  PR #33  ', self.head(mine)[0])
        self.assertIn('  no PR yet  ', self.head(theirs)[0])

    def test_elapsed_counts_from_this_attempts_invocation(self):
        first = self.attempt('x\n')
        second = self.attempt('x\n')
        now = time.time()
        os.utime(first / 'invocation.json', (now - 7300, now - 7300))
        os.utime(second / 'invocation.json', (now - 3700, now - 3700))
        self.assertTrue(self.head(first)[0].endswith('  2h01m'), self.head(first))
        self.assertTrue(self.head(second)[0].endswith('  1h01m'), self.head(second))

    def test_legacy_attempt_with_missing_metadata_shows_unknown(self):
        attempt = self.attempt('legacy line\n', identity=False, invocation=dict(adapter='/c/codex.sh'))
        first, now = self.head(attempt)
        self.assertRegex(first, r'^worker-mira-t035-r1  unknown  round unknown  no PR yet  [0-9]+s$')
        attempt = self.attempt('older\n', actor='worker-ada-t1-r1', identity=False, invocation=False)
        first, now = self.head(attempt)
        self.assertEqual('worker-ada-t1-r1  unknown  round unknown  no PR yet  unknown', first)
        self.assertIn('waiting for unknown', now)


class Diffs(Fixture):
    def section(self, out, path):
        lines = self.lines(out)
        at = self.at(lines, f'diff of {path} against HEAD, as the file is now')
        end = next((n for n in range(at + 1, len(lines)) if lines[n].startswith(('diff of ', 'binary file', 'diff unavailable'))), len(lines))
        return lines[at + 1:end]

    def view(self, *paths, env=None, tree=None):
        tree = tree or self.tmp / 'tree'
        return self.shown(self.follow(self.attempt(changes(*paths) + '\n', tree=tree), env=env))

    def test_diff_staged_change(self):
        self.repo()
        body = self.section(self.view('staged.py'), 'staged.py')
        self.assertIn('-value = 1', body); self.assertIn('+value = 2', body)

    def test_diff_unstaged_change(self):
        self.repo()
        body = self.section(self.view('unstaged.ts'), 'unstaged.ts')
        self.assertIn('-let value = 1;', body); self.assertIn('+let value = 2;', body)

    def test_diff_new_untracked_file_is_all_added(self):
        tree = self.repo()
        body = self.section(self.view(str(tree / 'fresh.json')), 'fresh.json')
        self.assertIn('--- /dev/null', body); self.assertIn('+{"fresh": true}', body)
        self.assertFalse([l for l in body if l.startswith('-') and not l.startswith('---')])

    def test_diff_deleted_file_is_all_removed(self):
        self.repo()
        body = self.section(self.view('gone.txt'), 'gone.txt')
        self.assertIn('-gone line', body); self.assertIn('+++ /dev/null', body)

    def test_diff_rename_is_a_deletion_plus_an_addition(self):
        tree = self.repo()
        for renames in ('false', 'true'):
            with self.subTest(configured=renames):
                self.git(tree, 'config', 'diff.renames', renames)
                out = self.view('old.txt', 'renamed.txt')
                self.assertNotIn('rename from', out)
                self.assertIn('-moved line', self.section(out, 'old.txt'))
                self.assertIn('+moved line', self.section(out, 'renamed.txt'))

    def test_diff_binary_file_is_one_line(self):
        self.repo()
        out = self.view('image.bin')
        self.assertIn('binary file changed: image.bin', self.lines(out))
        self.assertNotIn('diff of image.bin', out)

    def test_diff_unavailable_path_and_worktree(self):
        self.repo()
        out = self.lines(self.view('missing.txt', '/etc/hosts'))
        self.assertIn('diff unavailable: missing.txt no longer exists', out)
        self.assertIn('diff unavailable: /etc/hosts is outside the worktree', out)
        out = self.lines(self.view('staged.py', tree=self.tmp / 'gone-tree'))
        self.assertIn(f'diff unavailable: worktree {self.tmp / "gone-tree"} no longer exists', out)
        (self.tmp / 'not-a-repo').mkdir()
        out = self.view('x.py', tree=self.tmp / 'not-a-repo')
        self.assertRegex(out, r'diff unavailable: git exited [0-9]+: \S')

    def test_hostile_git_configuration_starts_nothing(self):
        tree = self.repo()
        marks = self.tmp / 'marks'; marks.mkdir()
        for name in ('external', 'textconv', 'fsmonitor', 'pager', 'command'):
            script = self.tmp / f'evil-{name}'
            script.write_text(f'#!/bin/sh\ntouch {marks}/{name}\ncat >/dev/null 2>&1\n'); script.chmod(0o755)
        (tree / '.gitattributes').write_text('* diff=evil\n')
        for key, name in (('diff.external', 'external'), ('diff.evil.textconv', 'textconv'),
                          ('diff.evil.command', 'command'), ('core.fsmonitor', 'fsmonitor'),
                          ('core.pager', 'pager'), ('pager.diff', 'pager')):
            self.git(tree, 'config', key, str(self.tmp / f'evil-{name}'))
        out = self.view('staged.py', 'unstaged.ts', 'fresh.json', 'same.md')
        self.assertIn('+value = 2', self.section(out, 'staged.py'))
        self.assertIn('+{"fresh": true}', self.section(out, 'fresh.json'))
        self.assertIn('no change against HEAD: same.md', self.lines(out))
        self.assertEqual([], sorted(p.name for p in marks.iterdir()))

    def test_only_git_and_ps_run_with_the_safe_arguments(self):
        tree = self.repo()
        stubs, marks, calls = self.tmp / 'stubs', self.tmp / 'marks', self.tmp / 'calls'
        stubs.mkdir(); marks.mkdir()
        for name in ('git', 'ps'):
            real = shutil.which(name, path=self.env['PATH'])
            (stubs / name).write_text(
                '#!/bin/sh\n'
                f'printf "%s\\n" "{name} $*" >> {calls}\n'
                + (f'printf "env GIT_PAGER=%s GIT_TERMINAL_PROMPT=%s GIT_NO_LAZY_FETCH=%s GIT_ALLOW_PROTOCOL=%s:%s\\n" '
                   f'"$GIT_PAGER" "$GIT_TERMINAL_PROMPT" "$GIT_NO_LAZY_FETCH" "${{GIT_ALLOW_PROTOCOL+set}}" "$GIT_ALLOW_PROTOCOL" >> {calls}\n'
                   if name == 'git' else '')
                + f'exec {real} "$@"\n')
        for name in ('delta', 'bat', 'gh', 'curl'):
            (stubs / name).write_text(f'#!/bin/sh\ntouch {marks}/{name}\n')
        for path in stubs.iterdir(): path.chmod(0o755)
        attempt = self.attempt(changes('staged.py', 'fresh.json') + '\n', finished=False, tree=tree)
        pid = self.dead_pid()
        (attempt / 'runner.pid').write_text(f'{pid}\n')
        out = self.shown(self.follow(attempt, env=dict(self.env, PATH=f'{stubs}:{self.env["PATH"]}')))
        self.assertIn('diff of staged.py against HEAD, as the file is now', out)
        said = calls.read_text().splitlines()
        programs = {line.split(' ', 1)[0] for line in said}
        self.assertEqual({'git', 'ps', 'env'}, programs)
        safe = f'git --no-optional-locks -c core.fsmonitor=false -c core.pager=cat -c diff.renames=false -C {tree} '
        for line in said:
            if line.startswith('git '): self.assertTrue(line.startswith(safe), line)
            if line.startswith('env '):
                self.assertEqual('env GIT_PAGER=cat GIT_TERMINAL_PROMPT=0 GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL=set:', line)
        self.assertIn(safe + 'diff --no-ext-diff --no-textconv --no-color HEAD -- staged.py', said)
        self.assertIn(safe + 'diff --no-ext-diff --no-textconv --no-color --no-index -- /dev/null fresh.json', said)
        self.assertIn(f'ps -p {pid} -o command=', said)
        self.assertEqual([], sorted(p.name for p in marks.iterdir()))

    @unittest.skipUnless(PTY, PTY_SKIP)
    def test_built_in_highlighting_by_file_type(self):
        tree = self.tmp / 'tree'; tree.mkdir()
        self.git(tree, 'init', '-q'); (tree / 'seed').write_text('x\n')
        self.git(tree, 'add', '-A'); self.git(tree, 'commit', '-qm', 'base')
        bodies = {'h.py': ('def run(): return "text" + str(42)  # note\n', 'def', '"text"', '# note'),
                  'h.sh': ('if true; then echo "text" 42; fi  # note\n', 'then', '"text"', '# note'),
                  'h.ts': ('const value = "text" + 42; // note\n', 'const', '"text"', '// note'),
                  'h.js': ('let value = "text" + 42; // note\n', 'let', '"text"', '// note'),
                  'h.json': ('{"key": "text", "n": 42, "ok": true}\n', 'true', '"text"', None),
                  'h.md': ('# Title\nuse `code` here\n<!-- note -->\nstep 42\n', '# Title', '`code`', '<!-- note -->')}
        for name, (body, *_rest) in bodies.items(): (tree / name).write_text(body)
        (tree / 'h.txt').write_text('def run(): return "text" 42  # note\n')
        attempt = self.attempt(changes(*bodies, 'h.txt') + '\n', tree=tree)
        session = self.in_pty([sys.executable, str(HERDR), 'follow', str(attempt)], columns=120)
        self.assertEqual(0, session.wait())
        parts = re.split(r'diff of (\S+) against HEAD', session.text())
        found = dict(zip(parts[1::2], parts[2::2]))
        self.assertEqual(sorted([*bodies, 'h.txt']), sorted(found))
        for name, (_body, keyword, string, comment) in bodies.items():
            with self.subTest(file=name):
                text = found[name]
                self.assertIn('\x1b[35m' + keyword + '\x1b[0m', text)
                self.assertIn('\x1b[33m' + string + '\x1b[0m', text)
                self.assertIn('\x1b[36m42\x1b[0m', text)
                if comment: self.assertIn('\x1b[90m' + comment, text)
        added = [l for l in found['h.txt'].splitlines() if 'def run()' in l]
        self.assertEqual(1, len(added), found['h.txt'])
        self.assertIn('\x1b[32m+\x1b[0m', added[0])
        for code in ('\x1b[35m', '\x1b[33m', '\x1b[36m', '\x1b[90m'):
            self.assertNotIn(code, added[0])


class LiveRounds(Fixture):
    def test_buffering_line_after_quiet_with_and_without_heartbeats(self):
        for beats in (True, False):
            with self.subTest(heartbeats=beats):
                attempt = self.live('[fm] worker-mira-t035-r1 worker started on T-035 (pid 1)\n' + heartbeat(15) + '\n',
                                    vendor='claude')
                proc, shown = self.start(attempt, env=dict(self.env, FM_FOLLOW_QUIET='1'))
                self.eventually(lambda: 'vendor silence:' in shown.read_text(), why='header')
                self.assertIn('vendor silence: unknown', shown.read_text())
                end = time.monotonic() + WAIT
                # the header already says `now: waiting for claude`; wait for the body line itself
                while 'waiting for claude: it sends' not in shown.read_text() and time.monotonic() < end:
                    if beats: self.append(attempt / 'run.log', heartbeat(30) + '\n')
                    time.sleep(.3)
                self.assertRegex(shown.read_text(), r'waiting for claude: it sends its output when it finishes \([0-9]+s\)')
                (attempt / 'result.json').write_text('{}')
                self.assertEqual(0, proc.wait(timeout=WAIT))
        attempt = self.live('quiet\n', vendor='claude')
        proc, shown = self.start(attempt)  # FM_FOLLOW_QUIET defaults to 30 seconds
        time.sleep(2)
        (attempt / 'result.json').write_text('{}')
        self.assertEqual(0, proc.wait(timeout=WAIT))
        self.assertNotIn('waiting for claude:', shown.read_text())

    def test_regression_ending_rules(self):
        for ending in ('result.json', 'runner.exit'):
            with self.subTest(ending=ending):
                attempt = self.live('x\n')
                proc, _ = self.start(attempt)
                time.sleep(.5)
                self.assertIsNone(proc.poll())
                (attempt / ending).write_text('0\n')
                self.assertEqual(0, proc.wait(timeout=WAIT))
        attempt = self.attempt('x\n', finished=False)
        (attempt / 'runner.pid').write_text(f'{self.dead_pid()}\n')
        self.assertEqual(0, self.follow(attempt).returncode)  # nothing of the round is left
        attempt = self.attempt('x\n', finished=False)
        started = time.monotonic()
        self.assertEqual(0, self.follow(attempt, env=dict(self.env, FM_FOLLOW_GRACE='1')).returncode)
        self.assertGreaterEqual(time.monotonic() - started, 1)  # the start grace, then over
        # a killed runner whose group survives is still the round
        leader = subprocess.Popen([sys.executable, '-c', 'import subprocess; subprocess.Popen(["sleep", "120"])'],
                                  start_new_session=True)
        leader.wait()
        self.addCleanup(self.end_group, leader.pid)
        attempt = self.attempt('x\n', finished=False)
        (attempt / 'runner.pid').write_text(f'{leader.pid}\n')
        proc, _ = self.start(attempt)
        time.sleep(1.5)
        self.assertIsNone(proc.poll(), 'follow ended while the group still ran')
        os.killpg(leader.pid, signal.SIGKILL)
        self.assertEqual(0, proc.wait(timeout=WAIT))

    def end_group(self, pgid):
        try: os.killpg(pgid, signal.SIGKILL)
        except OSError: pass

    def test_read_only_with_a_missing_lock_file(self):
        code = self.tmp / 'code'
        shutil.copytree(ROOT / 'bin', code / 'bin', ignore=shutil.ignore_patterns('__pycache__'))
        attempt = self.attempt(self.fixture('codex'), finished=False)
        (attempt / 'execution.json').write_text('{"started": true, "runner_pid": 1}')
        (attempt / 'runner.pid').write_text(f'{self.dead_pid()}\n')
        before = tree_state(attempt.parent, self.root / 'state')
        env = dict(self.env); env.pop('PYTHONDONTWRITEBYTECODE')  # as a real window runs it
        out = self.shown(self.follow(attempt, env=env, code=code / 'bin/fm-herdr.py'))
        self.assertIn('$ /bin/zsh -lc ls', out)
        self.assertFalse((attempt / 'execution.lock').exists())
        self.assertEqual(before, tree_state(attempt.parent, self.root / 'state'))
        self.assertEqual([], [str(p) for p in code.rglob('__pycache__')])

    def test_read_only_attempt_directory(self):
        attempt = self.attempt(self.fixture('codex'), finished=False)
        (attempt / 'execution.json').write_text('{"started": true}')
        (attempt / 'runner.pid').write_text(f'{self.dead_pid()}\n')
        attempt.chmod(0o555)
        before = tree_state(attempt.parent)
        out = self.shown(self.follow(attempt))
        self.assertIn('$ /bin/zsh -lc ls', out)
        self.assertEqual(before, tree_state(attempt.parent))

    def test_events_end_with_the_window_and_a_later_follow_shows_them_all(self):
        attempt = self.live('[fm] worker-mira-t035-r1 worker started on T-035 (pid 1)\n')
        self.events(dict(actor=ACTOR, type='dispatched', project='alpha', task='T-035',
                         summary={'en': 'picked up T-035', 'zh-TW': 'x'}),
                    dict(actor='worker-ada-t1-r1', type='crew_status', project='alpha', task='T-1',
                         summary={'en': 'not this actor', 'zh-TW': 'x'}))
        proc, shown = self.start(attempt)
        self.eventually(lambda: '** dispatched: picked up T-035' in shown.read_text(), why='actor event')
        self.append(attempt / 'run.log', '[fm] worker-mira-t035-r1 finished exit=0 after 3s\n')
        (attempt / 'result.json').write_text('{}')
        self.assertEqual(0, proc.wait(timeout=WAIT))
        self.events(dict(actor=ACTOR, type='commit_pushed', project='alpha', task='T-035', pr=12,
                         summary={'en': 'committed on t-035', 'zh-TW': 'x'}))
        window = shown.read_text()
        self.assertNotIn('commit_pushed', window)
        self.assertNotIn('not this actor', window)
        later = self.shown(self.fm(ACTOR))
        self.assertIn('** commit_pushed (PR #12): committed on t-035', self.lines(later))
        self.assertIn('** dispatched: picked up T-035', later)
        self.assertLess(later.index('finished exit=0'), later.index('** dispatched: picked up T-035'))
        self.assertIn('  PR #12  ', self.lines(later)[0])


class Raw(Fixture):
    LOG = b'{"type":"turn.started"}\n\x1b[31mred\x1b[0m\r\nplain\npartial'

    def test_raw_option_is_accepted_and_copies_the_log(self):
        self.attempt(self.LOG)
        done = self.fm(ACTOR, '--raw')
        self.assertEqual(0, done.returncode, done.stderr)
        self.assertEqual(self.LOG, done.stdout)

    def test_raw_option_and_env_copy_byte_for_byte(self):
        attempt = self.attempt(self.LOG)
        self.assertEqual(self.LOG, self.follow(attempt, '--raw').stdout)
        self.assertEqual(self.LOG, self.follow(attempt, env=dict(self.env, FM_FOLLOW_RAW='1')).stdout)

    def test_regression_missing_module_falls_back_to_raw(self):
        solo = self.tmp / 'solo/bin'; solo.mkdir(parents=True)
        shutil.copy(HERDR, solo / 'fm-herdr.py')
        attempt = self.attempt(self.LOG)
        self.assertEqual(self.LOG, self.follow(attempt, code=solo / 'fm-herdr.py').stdout)

    def test_rollout_base_code_shows_raw_and_current_code_formatted(self):
        base = self.tmp / 'base'
        base.mkdir()
        have = subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', BASE_COMMIT + '^{commit}'],
                              env=self.env, capture_output=True).returncode == 0
        if have:
            archive = subprocess.run(['git', '-C', str(ROOT), 'archive', BASE_COMMIT, 'bin'],
                                     env=self.env, capture_output=True, check=True).stdout
            subprocess.run(['tar', '-x', '-C', str(base)], input=archive, check=True)
        else:  # a frozen snapshot from before T-271 carries no view module
            (base / 'bin').mkdir(); shutil.copy(HERDR, base / 'bin/fm-herdr.py')
        log = self.fixture('codex').encode()
        attempt = self.attempt(log)
        before = tree_state(self.root)
        self.assertEqual(log, self.follow(attempt, code=base / 'bin/fm-herdr.py').stdout)
        now = self.shown(self.follow(attempt))
        self.assertIn('$ /bin/zsh -lc ls', self.lines(now))
        self.assertNotEqual(log.decode(), now)
        self.assertEqual(before, tree_state(self.root))


class Dashboard(Fixture):
    def test_dashboard_snapshot_line_and_all_accepted(self):
        running = jline({'type': 'item.started', 'item': {'id': 'i', 'type': 'command_execution',
                                                          'command': 'bun test', 'status': 'in_progress'}})
        old = self.attempt('x\n', actor='worker-ada-t1-r1', task='T-1')
        live = self.live(running + '\n', actor='worker-ada-t1-r1', task='T-1')
        now = time.time()
        os.utime(old / 'invocation.json', (now - 60, now - 60))
        stale_live = self.live('x\n', actor='worker-bea-t2-r1', task='T-2')
        self.attempt('x\n', actor='worker-bea-t2-r1', task='T-2')  # its latest attempt is finished
        os.utime(stale_live / 'invocation.json', (now - 60, now - 60))
        self.attempt('x\n', actor='reviewer-cora-t3-r1', task='T-3', finished=False)  # starting
        late = self.attempt('x\n', actor='worker-dora-t4-r1', task='T-4', finished=False)
        os.utime(late / 'invocation.json', (now - 1000, now - 1000))  # never started, past the grace
        out = self.lines(self.shown(self.fm('--all', env=dict(self.env, FM_FOLLOW_STUCK='0'))))
        self.assertRegex(out[0], r'^ACTOR +TASK +ELAPSED +NOW +LOG AGE +VENDOR SILENCE$')
        ada = self.find(out, 'worker-ada-t1-r1')
        self.assertRegex(ada, r'^worker-ada-t1-r1 +T-1 +[0-9]+s +running a command: bun test +[0-9]+s +unknown$')
        cora = self.find(out, 'reviewer-cora-t3-r1')
        self.assertRegex(cora, r' +T-3 +[0-9]+s +starting +[0-9]+s +unknown$')
        self.assertEqual(3, len(out), out)
        self.assertNotIn('possibly stuck', '\n'.join(out))
        self.assertTrue(live.exists())

    def test_dashboard_with_no_live_round(self):
        self.attempt('x\n')
        self.assertEqual(['no live rounds'], self.lines(self.shown(self.fm('--all'))))
        for wrong in (('--all', ACTOR), ('--all', '--raw')):
            self.assertEqual(64, self.fm(*wrong).returncode)

    @unittest.skipUnless(PTY, PTY_SKIP)
    def test_dashboard_refreshes_marks_stuck_and_ctrl_c_ends_it(self):
        self.live(heartbeat(15) + '\n', actor='worker-ada-t1-r1', task='T-1')
        env = dict(self.env, FM_FOLLOW_STUCK='1', FM_FOLLOW_QUIET='0')
        session = self.in_pty(['/bin/bash', str(FM), 'follow', '--all', '--repo', str(self.root)], env)
        session.until(lambda text: 'worker-ada-t1-r1' in text)
        self.assertNotIn('possibly stuck', session.text())
        # an 80-column screen still shows the label on the row it marks
        session.until(lambda text: any('worker-ada-t1-r1' in line and 'possibly stuck' in line and len(line) <= 80
                                       for line in visible(text)))
        self.assertGreaterEqual(session.text().count('\x1b[H'), 2)
        os.write(session.fd, b'\x03')
        self.assertEqual(0, session.wait())
        self.assertNotIn('Traceback', session.text())


@unittest.skipUnless(PTY, PTY_SKIP)
class Terminal(Fixture):
    def view(self, attempt, columns=80, **env):
        return self.in_pty([sys.executable, str(HERDR), 'follow', str(attempt)], dict(self.env, **env), columns)

    def test_header_stays_on_top_and_refreshes(self):
        attempt = self.live('x\n')
        session = self.view(attempt)
        session.until(lambda text: 'worker-mira-t035-r1  T-035' in text)
        self.assertIn('\x1b[3;24r', session.text())  # the log scrolls below the header
        time.sleep(2.5)
        (attempt / 'result.json').write_text('{}')
        self.assertEqual(0, session.wait())
        self.assertGreaterEqual(session.text().count('\x1b7\x1b[1;1H'), 3, 'drawn, then once a second')
        self.assertIn('\x1b[r', session.text())

    def test_heartbeat_updates_one_line_in_place(self):
        session = self.view(self.attempt(self.fixture('claude'), vendor='claude'))
        self.assertEqual(0, session.wait())
        text = session.text()
        self.assertIn('still running (30s)', text)
        between = text[text.index('still running (15s)'):text.index('still running (30s)')]
        self.assertNotIn('\n', between)
        self.assertIn('\r\x1b[2K', between)

    def test_messages_wrap_and_rewrap_after_a_resize(self):
        words = ' '.join('word%02d' % n for n in range(40))
        attempt = self.live(message('a', 'first ' + words) + '\n')
        session = self.view(attempt, columns=40)
        session.until(lambda text: 'word39' in text)
        first = [l for l in ANSI.sub(b'', session.out).decode().splitlines() if l.startswith('> ')]
        self.assertGreaterEqual(len(first), 6)
        self.assertTrue(all(len(l.rstrip('\r')) <= 40 for l in first), first)
        mark = len(session.out)
        session.resize(90)
        time.sleep(.5)
        self.append(attempt / 'run.log', message('b', 'second ' + words.replace('word', 'term')) + '\n')
        session.until(lambda text: 'term39' in text)
        (attempt / 'result.json').write_text('{}')
        self.assertEqual(0, session.wait())
        second = [l.rstrip('\r') for l in ANSI.sub(b'', session.out[mark:]).decode().splitlines() if l.startswith('> ')]
        self.assertTrue(second and max(len(l) for l in second) > 40, second)
        self.assertTrue(all(len(l) <= 90 for l in second), second)

    def test_colour_only_without_no_color(self):
        attempt = self.attempt(self.fixture('codex'))
        session = self.view(attempt)
        self.assertEqual(0, session.wait())
        self.assertIn('\x1b[32mexit 0\x1b[0m', session.text())
        self.assertIn('\x1b[31mexit 1\x1b[0m', session.text())
        session = self.view(attempt, NO_COLOR='1')
        self.assertEqual(0, session.wait())
        self.assertIn('exit 1', session.text())
        self.assertNotIn('\x1b', session.text())


class External(Fixture):
    def test_external_round_reads_only_its_own_records(self):
        (self.root / 'config.yaml').write_text('vendor: mock\nprojects:\n  app:\n    github: owner/app\n'
                                               '    base: trunk\n    required_check: ci\n')
        home = self.tmp / 'fmhome'
        storage = home / 'projects/app'
        tree = storage / 'worktrees/T-7'
        tree.mkdir(parents=True)
        self.git(tree, 'init', '-q'); (tree / 'a.py').write_text('a = 1\n')
        self.git(tree, 'add', '-A'); self.git(tree, 'commit', '-qm', 'base')
        (tree / 'a.py').write_text('a = 2\n')
        actor = 'worker-ada-t7-r1'
        attempt = self.live(changes('a.py') + '\n', actor=actor, task='T-7', project='app', tree=tree, root=storage)
        self.events(dict(actor=actor, type='pr_opened', project='app', task='T-7', pr=9,
                         summary={'en': 'opened #9', 'zh-TW': 'x'}), root=storage)
        self.events(dict(actor='x', type='pr_opened', task='T-7', pr=99))  # the engine's own log
        stubs, marks = self.tmp / 'stubs', self.tmp / 'marks'
        stubs.mkdir(); marks.mkdir()
        for name in ('gh', 'curl', 'ssh', 'git-remote-http', 'git-remote-https'):
            (stubs / name).write_text(f'#!/bin/sh\ntouch {marks}/{name}\nexit 1\n'); (stubs / name).chmod(0o755)
        env = dict(self.env, FM_HOME=str(home), FM_EXTERNAL='1', PATH=f'{stubs}:{self.env["PATH"]}')
        watched = (storage, self.tmp / 'home')
        before = tree_state(*watched)
        dash = self.lines(self.shown(self.fm('--all', '--project', 'app', env=env)))
        self.assertTrue(any(l.startswith(actor + ' ') and ' T-7 ' in l for l in dash), dash)
        self.assertEqual(before, tree_state(*watched))
        (attempt / 'result.json').write_text('{}')
        before = tree_state(*watched)
        out = self.shown(self.fm(actor, '--project', 'app', env=env))
        self.assertIn('  PR #9  ', self.lines(out)[0])
        self.assertIn('+a = 2', out)
        self.assertIn('** pr_opened (PR #9): opened #9', self.lines(out))
        self.assertEqual(before, tree_state(*watched))
        self.assertEqual([], sorted(p.name for p in marks.iterdir()))


class Language(Fixture):
    def test_every_label_comes_from_the_fixed_english_table(self):
        self.assertTrue(VIEW.is_file(), 'no view module: every label would be missing')
        source = VIEW.read_text()  # read, never imported
        tree = ast.parse(source)
        tables = {}
        for node in tree.body:
            if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name) and node.targets[0].id in ('LABELS', 'KEYWORDS'):
                tables[node.targets[0].id] = node
        labels = ast.literal_eval(tables['LABELS'].value)
        self.assertTrue(labels and all(isinstance(v, str) and v.isascii() for v in labels.values()))
        exempt = {id(n) for table in tables.values() for n in ast.walk(table)}
        for node in ast.walk(tree):
            body = getattr(node, 'body', None)
            if isinstance(body, list) and body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant):
                exempt.add(id(body[0].value))  # docstrings
            if isinstance(node, ast.Call) and getattr(node.func, 'attr', '') == 'compile':
                exempt.update(id(n) for n in ast.walk(node))  # patterns that read logs, not words shown
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and getattr(node.func, 'id', '') == 'say':
                self.assertIsInstance(node.args[0], ast.Constant)
                self.assertIn(node.args[0].value, labels)
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in exempt:
                self.assertNotRegex(node.value, r'[A-Za-z]{2,} [A-Za-z]{2,}',
                                    'words outside LABELS at line %d' % node.lineno)
        shown = self.shown(self.follow(self.attempt(self.fixture('codex'))))
        self.assertIn(labels['no_pr'], shown)
        self.assertIn(labels['hidden'].format(count=20), shown)


class NamedTestResult(unittest.TextTestResult):
    """Expose behavioral outcomes in the fail-first collector's line format."""
    def startTest(self, test):
        self._fm_failed = False
        self._fm_skipped = False
        super().startTest(test)

    def addFailure(self, test, err):
        self._fm_failed = True
        super().addFailure(test, err)

    def addError(self, test, err):
        self._fm_failed = True
        super().addError(test, err)

    def addSubTest(self, test, subtest, err):
        if err is not None:
            self._fm_failed = True
        super().addSubTest(test, subtest, err)

    def addSkip(self, test, reason):
        self._fm_skipped = True
        super().addSkip(test, reason)

    def stopTest(self, test):
        super().stopTest(test)
        if not self._fm_skipped:
            name = '%s.%s' % (type(test).__name__, test._testMethodName)
            sys.stdout.write('    %-52s %s\n' % (name, 'FAIL' if self._fm_failed else 'ok'))
            sys.stdout.flush()


if __name__ == '__main__':
    suite = unittest.TestLoader().loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(verbosity=2, resultclass=NamedTestResult).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
