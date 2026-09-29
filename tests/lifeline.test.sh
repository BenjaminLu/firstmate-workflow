#!/usr/bin/env bash
# T-151: no process fm starts can outlive its owner. Every background start
# goes through bin/lib/fm_lifeline.py, which ties the process to an owner
# the kernel reports the death of - a pipe's EOF, kqueue NOTE_EXIT, a pidfd -
# and nothing is ever decided by polling a pid or a directory.
#
# Every process this suite starts is stopped by it, or ended with the owner
# it names: bin/ci.sh runs it with a scope marker and turns it red for any
# process still carrying it when it ends.
set -uo pipefail
exec < /dev/null
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=bin/fm-config.sh
. "$ROOT/bin/fm-config.sh"   # fm_strip_comments

# --- one way to start in the background ------------------------------------
# A grep, over the code of bin/, board/ and the skills: no start_new_session,
# setsid, nohup, disown or `detached: true` outside the primitive itself.
# Comments are taken off first, so prose that names a forbidden word is not
# a start; in the skills, a command line in a code block is.
code_of() {   # code_of <file>: its code, without comments
  case "$1" in
    *.ts) sed -e 's#^[[:space:]]*//.*$##' -e 's#[[:space:]]//.*$##' "$1" ;;
    *.py) sed -e 's/^[[:space:]]*#.*$//' "$1" ;;
    *.md) awk '/^[[:space:]]*```/ { fenced = !fenced; next } fenced' "$1" ;;   # its command lines
    *) fm_strip_comments "$1" ;;
  esac
}
detached=''
while IFS= read -r f; do
  case "$f" in "$ROOT/bin/lib/"*) continue ;; esac
  hits="$(code_of "$f" | grep -nE 'start_new_session|os\.setsid|(^|[;&|(`]|&&|\|\|)[[:space:]]*(setsid|nohup|disown)([[:space:]]|$)|detached:[[:space:]]*true' || true)"
  [ -z "$hits" ] || detached="$detached${f#"$ROOT/"}: $hits
"
done < <(find "$ROOT/bin" "$ROOT/board" "$ROOT/skills" -type f \
           \( -name '*.sh' -o -name '*.py' -o -name '*.ts' -o -name '*.md' \) | sort)
assert_eq "" "$detached" "nothing starts a detached process except bin/lib/fm_lifeline.py"
# and the sweep sees what it is looking for: a planted start of each kind
plant="$(safe_tmpdir)"
printf 'x = subprocess.Popen(a, start_new_session=True)\n' > "$plant/a.py"
printf 'setsid bin/fm-worker.sh &\n' > "$plant/b.sh"
printf 'run && nohup thing &\n' > "$plant/c.sh"
printf 'const c = spawn(x, [], { detached: true });\n' > "$plant/d.ts"
printf 'long_job & disown\n' > "$plant/e.sh"
printf '# setsid in a comment is prose\n' > "$plant/f.sh"
printf 'Never `setsid` or `detached: true` in prose.\n\n```bash\nsetsid bin/fm-review.sh &\n```\n' > "$plant/g.md"
for f in a.py b.sh c.sh d.ts e.sh g.md; do
  assert_ne "" "$(code_of "$plant/$f" | grep -nE 'start_new_session|os\.setsid|(^|[;&|(`]|&&|\|\|)[[:space:]]*(setsid|nohup|disown)([[:space:]]|$)|detached:[[:space:]]*true' || true)" \
    "the sweep catches a planted $f"
done
assert_lacks "$(code_of "$plant/g.md")" "in prose" "a skill's code blocks are read, not its prose"
assert_eq "" "$(code_of "$plant/f.sh" | grep -nE '(^|[;&|(`]|&&|\|\|)[[:space:]]*(setsid|nohup|disown)([[:space:]]|$)' || true)" \
  "and passes a comment that only names one"
safe_rm_rf "$plant"

# --- no watcher -------------------------------------------------------------
# The decision watch is deleted: the writer pushes the wake. Nothing in bin/
# or the board polls state/decisions, and there is no watch-child to start.
assert_eq "" "$(grep -rnE 'watch-child|watch_child|(^|[^A-Za-z_])watch_start' "$ROOT/bin" "$ROOT/board" 2>/dev/null | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)" \
  "no decision watcher is left to start"
assert_eq "" "$(code_of "$ROOT/bin/fm-decide.sh" | grep -n 'watch-decisions\|sleep 1' || true)" \
  "fm-decide.sh --await neither watches nor polls the decisions directory"

python3 - "$ROOT" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.dont_write_bytecode = True
root = Path(sys.argv[1])
LIB = root / 'bin/lib/fm_lifeline.py'
WRAPPER = root / 'bin/lib/fm-lifeline.sh'
spec = importlib.util.spec_from_file_location('fm_lifeline', LIB)
life = importlib.util.module_from_spec(spec); spec.loader.exec_module(life)


def gone(pid, within):
    """Whether pid has exited within the time given. Test-side only: the
    code under test never asks this way."""
    deadline = time.monotonic() + within
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(.05)
    return False


def command_of(pid):
    """pid's command line, test-side: /proc, else the kernel list the
    library reads (not ps, which a sandbox refuses)."""
    try:
        with open(f'/proc/{pid}/cmdline', 'rb') as f:
            return f.read().replace(b'\0', b' ').decode(errors='replace')
    except OSError:
        return next((command for p, command, _ in life._darwin_processes() if p == pid), '')


def stop(pid):
    try: os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError): pass
    try: os.kill(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError): pass


class Lifeline(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

    def program(self, name):
        """A program that writes its pid, then sleeps: the process a start is for."""
        pidfile = self.dir / (name + '.pid')
        argv = [sys.executable, '-c',
                'import os, sys, time; open(sys.argv[1], "w").write(str(os.getpid())); time.sleep(300)',
                str(pidfile)]
        return argv, pidfile

    def pid_of(self, pidfile):
        for _ in range(200):
            if pidfile.exists() and pidfile.read_text():
                pid = int(pidfile.read_text()); self.addCleanup(stop, pid); return pid
            time.sleep(.05)
        self.fail('the program never started')

    def test_a_pipe_owner_killed_takes_its_child_across_setsid(self):
        argv, pidfile = self.program('child')
        owner = subprocess.Popen([sys.executable, '-c', '''
import importlib.util, subprocess, sys, time
spec = importlib.util.spec_from_file_location("l", sys.argv[1]); l = importlib.util.module_from_spec(spec); spec.loader.exec_module(l)
keeper = l.start(sys.argv[2:], stdin=subprocess.DEVNULL)
print(keeper.pid, flush=True)
time.sleep(300)
''', str(LIB), *argv], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: (owner.poll() is None and owner.kill(), owner.wait()))
        keeper = int(owner.stdout.readline()); self.addCleanup(stop, keeper)
        child = self.pid_of(pidfile)
        self.assertNotEqual(os.getsid(owner.pid), os.getsid(child), 'the child is in a session of its own')
        self.assertFalse(gone(child, .3), 'and lives while its owner does')
        owner.kill(); owner.wait()   # SIGKILL: no handler of the owner's runs
        self.assertTrue(gone(child, 5), 'the kernel closed the lifeline and the child ended with its owner')
        self.assertTrue(gone(keeper, 5), 'and so did its keeper')

    def test_a_pid_owner_that_exits_takes_its_child(self):
        argv, pidfile = self.program('pid-owned')
        owner = subprocess.Popen(['sleep', '300'], stdin=subprocess.DEVNULL)
        self.addCleanup(lambda: (owner.poll() is None and owner.kill(), owner.wait()))
        run = subprocess.run(['bash', str(WRAPPER), '--owner-pid', str(owner.pid), '--', *argv],
                             stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        self.assertEqual(0, run.returncode, run.stderr)
        keeper = int(run.stdout); self.addCleanup(stop, keeper)
        child = self.pid_of(pidfile)
        self.assertFalse(gone(child, .3), 'the child lives while its owner does')
        owner.kill(); owner.wait()
        self.assertTrue(gone(child, 5), 'the kernel reported the owner\'s exit and the child ended')
        self.assertTrue(gone(keeper, 5))

    def test_the_session_is_the_default_owner_and_a_gone_owner_starts_nothing(self):
        argv, pidfile = self.program('session-owned')
        session = subprocess.Popen(['sleep', '300'], stdin=subprocess.DEVNULL)
        self.addCleanup(lambda: (session.poll() is None and session.kill(), session.wait()))
        env = dict(os.environ, FM_SESSION_PID=str(session.pid))
        owner = subprocess.run([sys.executable, str(LIB), 'session-owner'], env=env, capture_output=True, text=True)
        self.assertEqual(str(session.pid), owner.stdout.strip())
        run = subprocess.run(['bash', str(WRAPPER), '--session', '--', *argv], env=env,
                             stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        self.assertEqual(0, run.returncode, run.stderr)
        self.addCleanup(stop, int(run.stdout))
        child = self.pid_of(pidfile)
        session.kill(); session.wait()
        self.assertTrue(gone(child, 5), 'owned by the session, it ends with the session')
        # an owner already gone is refused at once, and nothing is started
        argv, pidfile = self.program('orphan')
        refused = subprocess.run(['bash', str(WRAPPER), '--owner-pid', str(session.pid), '--', *argv],
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(0, refused.returncode)
        self.assertIn('already gone', refused.stderr)
        time.sleep(.5)
        self.assertFalse(pidfile.exists(), 'nothing was started for an owner that is gone')

    def test_the_ci_session_stands_in_for_a_scrubbed_fm_session_pid(self):
        # suites scrub FM_*, and bin/ci.sh names their session again under a
        # name they keep (T-151 review round 2); FM_SESSION_PID still wins
        with mock.patch.dict(os.environ):
            os.environ.pop('FM_SESSION_PID', None)
            os.environ['FIRSTMATE_CI_SESSION'] = '4242'
            self.assertEqual(4242, life.session_owner(), 'the gate\'s session, not an ancestor')
            os.environ['FM_SESSION_PID'] = '4343'
            self.assertEqual(4343, life.session_owner(), 'a session named by FM_SESSION_PID comes first')

    def test_an_owner_that_cannot_be_found_is_refused_never_guessed(self):
        # every way the walk can fail raises; none returns getppid(), the
        # short-lived launcher a long-lived process would then die with
        cases = {
            'the parent cannot be read': lambda pid: (None, ''),
            'the walk reaches pid 1': lambda pid: (1, 'bash'),
            'the walk runs out of hops': lambda pid: (pid + 1, 'bash'),
        }
        for why, parent_of in cases.items():
            with self.subTest(why), mock.patch.dict(os.environ), \
                    mock.patch.object(life, '_parent_of', parent_of):
                os.environ.pop('FM_SESSION_PID', None); os.environ.pop('FIRSTMATE_CI_SESSION', None)
                with self.assertRaises(RuntimeError, msg=why):
                    life.session_owner()
        # and the command line says so and starts nothing: exit 70
        env = {k: v for k, v in os.environ.items() if k not in ('FM_SESSION_PID', 'FIRSTMATE_CI_SESSION')}
        refused = subprocess.run([sys.executable, '-c', '''
import importlib.util, sys
spec = importlib.util.spec_from_file_location("l", sys.argv[1]); l = importlib.util.module_from_spec(spec); spec.loader.exec_module(l)
l._parent_of = lambda pid: (None, "")
sys.argv[1:] = ["session-owner"]
try: sys.exit(l.main(sys.argv[1:]))
except RuntimeError as e: print("fm-lifeline: " + str(e), file=sys.stderr); sys.exit(70)
''', str(LIB)], env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        self.assertEqual(70, refused.returncode, refused.stdout + refused.stderr)
        self.assertEqual('', refused.stdout, 'no pid is printed for an owner nobody named')
        self.assertIn('cannot be read', refused.stderr)

    def test_the_session_is_read_from_the_kernel_without_ps(self):
        # xargs is not a launcher, so it is the session of what runs under
        # it; ps is refused. On macOS (uname Darwin) the parent comes from
        # libproc, and this is red for a walk that needs ps; on Linux it
        # comes from /proc either way, so there it checks the walk only.
        stub = self.dir / 'stub'; stub.mkdir()
        (stub / 'ps').write_text('#!/bin/sh\necho "ps: operation not permitted" >&2\nexit 1\n')
        (stub / 'ps').chmod(0o755)
        env = {k: v for k, v in os.environ.items() if k not in ('FM_SESSION_PID', 'FIRSTMATE_CI_SESSION')}
        env['PATH'] = f'{stub}:{env.get("PATH", "")}'
        got = subprocess.run(['xargs', '-I{}', 'bash', '-c', 'echo "$PPID"; "$0" "$1" session-owner; true',
                              sys.executable, str(LIB)],
                             input='x\n', env=env, capture_output=True, text=True, timeout=30)
        lines = got.stdout.split()
        self.assertEqual(2, len(lines), got.stdout + got.stderr)
        self.assertEqual(lines[0], lines[1],
                         f'on {os.uname().sysname} the session is the nearest non-launcher (xargs), '
                         'not the shell that ran the command, with ps refused')

    def test_the_documented_launch_recipe_logs_and_prints_the_keeper(self):
        # dispatch-crew starts every round with `fm-lifeline.sh --log <file>`:
        # the program's stdout and stderr both land in the file, and the pid
        # printed is the keeper's, which holds the lifeline, not the program's
        pidfile = self.dir / 'logged.pid'; log = self.dir / 'round.log'
        owner = subprocess.Popen(['sleep', '300'], stdin=subprocess.DEVNULL)
        self.addCleanup(lambda: (owner.poll() is None and owner.kill(), owner.wait()))
        program = ('import os, sys, time\n'
                   'open(sys.argv[2], "w").write(str(os.getppid()))\n'
                   'open(sys.argv[1], "w").write(str(os.getpid()))\n'
                   'print("to stdout", flush=True); print("to stderr", file=sys.stderr, flush=True)\n'
                   'time.sleep(300)\n')
        run = subprocess.run(['bash', str(WRAPPER), '--owner-pid', str(owner.pid), '--log', str(log), '--',
                              sys.executable, '-c', program, str(pidfile), str(self.dir / 'parent')],
                             stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        self.assertEqual(0, run.returncode, run.stderr)
        keeper = int(run.stdout); self.addCleanup(stop, keeper)
        child = self.pid_of(pidfile)
        for _ in range(100):
            said = log.read_text() if log.exists() else ''
            if 'to stdout' in said and 'to stderr' in said: break
            time.sleep(.05)
        self.assertIn('to stdout', said, 'the program\'s stdout is in --log\'s file')
        self.assertIn('to stderr', said, 'and so is its stderr')
        self.assertNotEqual(child, keeper, 'the pid printed is not the program\'s')
        self.assertIn('keep', command_of(keeper), 'it is the keeper\'s, which holds the lifeline')
        self.assertEqual(str(keeper), (self.dir / 'parent').read_text(), 'and the program runs under it')
        owner.kill(); owner.wait()
        self.assertTrue(gone(child, 5), 'the program ends with its owner')
        self.assertTrue(gone(keeper, 5), 'and so does the keeper the recipe printed')

    def test_the_keeper_exits_with_its_program_and_takes_what_it_left(self):
        left = self.dir / 'left.pid'
        script = ('import os, subprocess, sys\n'
                  'p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)"])\n'
                  'open(sys.argv[1], "w").write(str(p.pid)); os._exit(3)\n')
        keeper = life.start([sys.executable, '-c', script, str(left)], stdin=subprocess.DEVNULL)
        self.addCleanup(stop, keeper.pid)
        self.assertEqual(3, keeper.wait(timeout=30), 'the keeper exits with its program\'s status')
        self.addCleanup(stop, int(left.read_text()))
        self.assertTrue(gone(int(left.read_text()), 5), 'what the program left in its group has no owner, and goes')

    def test_a_forked_child_reads_eof_when_its_parent_dies(self):
        report = self.dir / 'eof'
        owner = subprocess.Popen([sys.executable, '-c', '''
import importlib.util, os, sys, time
spec = importlib.util.spec_from_file_location("l", sys.argv[1]); l = importlib.util.module_from_spec(spec); spec.loader.exec_module(l)
pid, fd = l.fork()
if pid == 0:
    started = time.monotonic()
    ended = l.wait_owner(fd, 60)
    open(sys.argv[2], "w").write("%s %s %s" % (ended, os.getsid(0) == os.getpid(), round(time.monotonic() - started, 2)))
    os._exit(0)
print(pid, flush=True)
time.sleep(300)
''', str(LIB), str(report)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: (owner.poll() is None and owner.kill(), owner.wait()))
        forked = int(owner.stdout.readline()); self.addCleanup(stop, forked)
        time.sleep(.3)
        self.assertFalse(report.exists(), 'the forked child waits while its parent lives')
        owner.kill(); owner.wait()
        self.assertTrue(gone(forked, 5))
        ended, leader, _ = report.read_text().split()
        self.assertEqual(('True', 'True'), (ended, leader), 'it read EOF, in a session of its own')

    HOLDER = '''
import importlib.util, os, signal, subprocess, sys, time
spec = importlib.util.spec_from_file_location("l", sys.argv[1]); l = importlib.util.module_from_spec(spec); spec.loader.exec_module(l)
try:
    l.hold()
except RuntimeError as error:
    open(sys.argv[2], "w").write("refused " + str(error)); sys.exit(70)
# a child in the same group that shrugs off SIGTERM: only the SIGKILL after
# the grace ends it
c = subprocess.Popen([sys.executable, "-c", "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(300)"])
open(sys.argv[2], "w").write("%d %d %d" % (os.getpid(), os.getpgrp(), c.pid))
c.wait()
'''

    def holder_pids(self, report):
        for _ in range(200):
            if report.exists() and report.read_text():
                break
            time.sleep(.05)
        text = report.read_text()
        if text.startswith('refused'):
            return text
        pid, group, child = (int(x) for x in text.split())
        self.addCleanup(stop, pid); self.addCleanup(stop, child)
        return pid, group, child

    def test_fm_s_own_python_holds_its_line_itself(self):
        """The round runner's start (T-144's spawn_runner): no keeper between,
        so its pid and group are the program's, and it ends its whole group -
        a child that ignores SIGTERM included - when its session ends."""
        report = self.dir / 'held'
        session = subprocess.Popen(['sleep', '300'], stdin=subprocess.DEVNULL)
        self.addCleanup(lambda: (session.poll() is None and session.kill(), session.wait()))
        env = dict(os.environ, FM_LIFELINE_GRACE='1')
        started = life.start([sys.executable, '-c', self.HOLDER, str(LIB), str(report)], owner=session.pid,
                             direct=True, env=env, stdin=subprocess.DEVNULL)
        self.addCleanup(lambda: (started.poll() is None and started.kill(), started.wait()))
        pid, group, child = self.holder_pids(report)
        self.assertEqual((started.pid, started.pid), (pid, group), 'the started pid is the program, leading its own group')
        self.assertFalse(gone(child, .3), 'it runs while its session lives')
        session.kill(); session.wait()
        self.assertIsNotNone(started.wait(timeout=10), 'the session gone, the program ends')
        self.assertTrue(gone(child, 10), 'and so does its group, SIGKILLed after the grace')

    def test_fm_s_own_python_owned_by_a_pipe_ends_when_its_owner_is_killed(self):
        report = self.dir / 'piped'
        owner = subprocess.Popen([sys.executable, '-c', '''
import importlib.util, subprocess, sys, time
spec = importlib.util.spec_from_file_location("l", sys.argv[1]); l = importlib.util.module_from_spec(spec); spec.loader.exec_module(l)
l.start([sys.executable, "-c", sys.argv[3], sys.argv[1], sys.argv[2]], direct=True, stdin=subprocess.DEVNULL)
time.sleep(300)
''', str(LIB), str(report), self.HOLDER], stdin=subprocess.DEVNULL, env=dict(os.environ, FM_LIFELINE_GRACE='1'))
        self.addCleanup(lambda: (owner.poll() is None and owner.kill(), owner.wait()))
        pid, _, child = self.holder_pids(report)
        owner.kill(); owner.wait()
        self.assertTrue(gone(pid, 10), 'its owner SIGKILLed, the program read EOF and ended')
        self.assertTrue(gone(child, 10), 'with its group')

    def test_fm_s_own_python_refuses_to_run_without_a_line(self):
        report = self.dir / 'unheld'
        env = {k: v for k, v in os.environ.items() if not k.startswith('FM_LIFELINE_')}
        run = subprocess.run([sys.executable, '-c', self.HOLDER, str(LIB), str(report)], env=env,
                             stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
        self.assertEqual(70, run.returncode)
        self.assertIn('without a lifeline', report.read_text())

    def test_every_doorbell_is_rung_and_a_dead_one_is_cleared(self):
        """The wake: a FIFO hands each line to one reader, so each waiter has
        a bell of its own and a ring reaches all of them (T-151 review 1)."""
        repo = self.dir / 'repo'
        with life.Doorbell(repo) as first, life.Doorbell(repo) as second:
            bells = repo / life.WAKE_DIR
            self.assertEqual(2, len(list(bells.glob('*.fifo'))))
            os.mkfifo(bells / '1-dead.fifo')   # a waiter killed outright
            started = time.monotonic()
            self.assertEqual(2, life.ring(repo, 'D-1'))
            self.assertLess(time.monotonic() - started, 2, 'a ring never blocks')
            self.assertFalse((bells / '1-dead.fifo').exists(), 'a bell nobody holds is removed')
            self.assertTrue(first.wait(1), 'the first waiter heard it')
            self.assertTrue(second.wait(1), 'and so did the second')
            self.assertFalse(first.wait(.2), 'once')
        self.assertEqual([], list(bells.glob('*.fifo')), 'each bell goes with its waiter')
        self.assertEqual(0, life.ring(repo, 'D-2'), 'nobody waiting: nothing rung, nothing blocked')

    def test_scope_survivors_names_and_kills_what_carries_the_marker(self):
        marker = 'lifeline-test-%d-%d' % (os.getpid(), time.time_ns())
        argv, pidfile = self.program('scoped')
        env = dict(os.environ, FIRSTMATE_CI_SCOPE=marker)
        scoped = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, start_new_session=True)
        self.addCleanup(lambda: (scoped.poll() is None and scoped.kill(), scoped.wait()))
        self.pid_of(pidfile)
        found = subprocess.run([sys.executable, str(LIB), 'scope-survivors', '--kill', marker],
                               capture_output=True, text=True, timeout=60)
        self.assertEqual(1, found.returncode, found.stderr)
        self.assertIn(str(scoped.pid), found.stdout)
        self.assertEqual(-signal.SIGKILL, scoped.wait(timeout=10), 'and it is killed')
        clean = subprocess.run([sys.executable, str(LIB), 'scope-survivors', marker],
                               capture_output=True, text=True, timeout=60)
        self.assertEqual((0, ''), (clean.returncode, clean.stdout))


class Closer(unittest.TestCase):
    """The pane-child's closer (bin/fm-herdr.py close_from_child) runs once
    the pane-child has exited. It learns that from its lifeline, never from
    kill(pid, 0) - which a zombie answers as alive."""

    def test_the_closer_closes_when_its_owner_exits_even_unreaped(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        attempt = Path(tmp.name) / 'attempt'; attempt.mkdir()
        owner = subprocess.Popen([sys.executable, '-c', '''
import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.shell_only = lambda *a: True
m.close_owned = lambda attempt, owner, control: "closed"
owner = dict(actor="worker-x", pane_id="p1", shell_pid=1)
result = dict(exit_code=0, status="completed")
print(m.close_from_child(sys.argv[2], owner, result, control=lambda *a: {"process_info": {}}), flush=True)
''', str(root / 'bin/fm-herdr.py'), str(attempt)],
            env=dict(os.environ, FM_HERDR_SHELL_WAIT='30'), stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, text=True)
        self.assertEqual('scheduled', owner.stdout.readline().strip())
        # the owner exits and is left unreaped: a zombie, which kill(pid, 0)
        # still reports as alive for as long as nobody waits for it
        close = attempt / 'close.json'
        for _ in range(100):
            if close.exists(): break
            time.sleep(.05)
        self.assertTrue(close.exists(), 'the closer ran once its owner exited, reaped or not')
        self.assertEqual('closed', json.loads(close.read_text())['status'])
        owner.stdout.close(); owner.wait()


unittest.main(argv=['lifeline'], verbosity=2)
PY
[ $? -eq 0 ] || _fails=$((_fails + 1))
finish
