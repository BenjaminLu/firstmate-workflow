#!/usr/bin/env python3
"""The one way fm starts a background process (T-151).

A process fm starts exists only while an owner that needs it lives. Every
background start names that owner and holds a lifeline to it, and the
kernel, not a poll, says when the owner is gone:

  * an owner fm starts itself keeps the write end of a pipe; the child
    holds the read end and reads EOF when every holder of the write end
    has died - SIGKILL included, and across setsid, because the kernel
    closes a dead process's descriptors whatever killed it;
  * an owner fm did not start (the harness's session, which the board and
    a merge the captain clicked belong to) is watched by its pid: kqueue
    EVFILT_PROC NOTE_EXIT on macOS, a pidfd on Linux. Both block until
    the kernel reports the exit; neither is a loop over kill(pid, 0).

No liveness is ever decided by polling a pid or a directory.

A process that is not fm's own Python cannot watch a descriptor, so the
started program runs under a keeper: this file, `keep`, in a session of
its own (so a closing terminal or pane does not take it), with the
program in a process group of its own below it. The keeper blocks on the
lifeline and on the program's exit together. When the owner goes, it
sends the group SIGTERM, then SIGKILL after FM_LIFELINE_GRACE seconds
(default 5), and exits; when the program exits first, whatever it left
in its group is ended the same way and the keeper exits with the
program's status. The keeper's pid stands for the program: it lives
exactly as long.

An optional FM_LIFELINE_SCOPE directory lets a fixture drain every keeper,
including detached descendants, with close_scope(directory). Scoped keepers
register before detaching, serialize child creation against scope closure,
and confirm every group member's exit before recording successful drainage.

  from bin/lib/fm_lifeline import start, fork, session_owner
  start(argv, owner=None)        this process owns it, by a pipe
  start(argv, owner=<pid>)       that pid owns it, by kqueue/pidfd
  start(argv, owner, direct=True)
                                 fm's own Python, which calls hold() as it
                                 starts and holds its lifeline itself
  fork()                         a forked Python child in its own session
                                 that reads EOF on its lifeline when the
                                 forking process dies

  fm_lifeline.py keep --fd N -- argv...     keeper, owner at the other end of fd N
  fm_lifeline.py keep --pid P -- argv...    keeper, owner is pid P
  fm_lifeline.py spawn [--owner-pid P|--session] [--log F] -- argv...
                                 start a keeper under P (default: the
                                 session) and print its pid
  fm_lifeline.py session-owner   print the pid `--session` resolves to
  fm_lifeline.py ring-events <root> <line>
                                 Notify only session/autopilot.d.
  fm_lifeline.py ring <root> <line>
                                 ring every waiter's doorbell under
                                 <root>/state/session/wake.d; print how many
  fm_lifeline.py push <root> <id> <reason> <line> [json]
                                 append a wake to the queue, then ring (T-137)
  fm_lifeline.py await <root> <file> [seconds]
                                 register a doorbell, then wait until <file>
                                 exists (0) or the seconds run out (1)
  fm_lifeline.py scope-survivors [--kill] [--root DIR]... <marker>
                                 every process still carrying
                                 FIRSTMATE_CI_SCOPE=<marker>, or naming a DIR
                                 in its command line, as "pid command"

The session is FM_SESSION_PID when it is set; else FIRSTMATE_CI_SESSION,
which bin/ci.sh sets to each suite's own runner under a name the suites
do not scrub; otherwise the nearest ancestor that is not a shell or an
interpreter running one of fm's scripts, read from the kernel (/proc,
libproc). When no ancestor can be read, it refuses (exit 70) rather than
guessing. A keeper watching a pid exports it as FM_SESSION_PID, so what it
starts (the board) hands the same owner to what it starts in turn (a
merge). A test names its own owner through FM_SESSION_PID or the gate's
FIRSTMATE_CI_SESSION and never depends on the operator's real session.
"""
import errno
import os
import re
import select
import signal
import stat
import subprocess
import sys
import time

HERE = os.path.abspath(__file__)
SCOPE = 'FIRSTMATE_CI_SCOPE'
# the write ends this process holds for the children it owns; never closed
# on purpose - the kernel closes them when this process dies, which is the
# whole signal
_held = []


class OwnerGone(RuntimeError):
    """The owner had already exited when its watch was set up."""
    def __init__(self, pid):
        super().__init__(f'owner {pid} is already gone; nothing started for it')


_project_paths = None

def record_root(root):
    global _project_paths
    import importlib.util
    from pathlib import Path
    if _project_paths is None:
        spec = importlib.util.spec_from_file_location('fm_project_paths', Path(__file__).with_name('fm_project_paths.py'))
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        _project_paths = module
    return str(_project_paths.record_root(root))


def _grace():
    try:
        value = float(os.environ.get('FM_LIFELINE_GRACE', '5'))
    except ValueError:
        value = 5.0
    return value if value >= 0 else 5.0


class ProcessExit:
    """A descriptor that turns readable when pid exits, set up by the kernel.

    macOS: a kqueue holding EVFILT_PROC NOTE_EXIT on the pid; Linux: a
    pidfd. Either works for a process that is not our child. Raises
    OwnerGone when the pid is already gone, RuntimeError when neither
    mechanism exists (then nothing is started: there is no fallback to a
    poll)."""

    def __init__(self, pid):
        self.pid = int(pid)
        self._kq = None
        self._fd = None
        self._gone = False
        if hasattr(select, 'kqueue'):
            self._kq = select.kqueue()
            event = select.kevent(self.pid, filter=select.KQ_FILTER_PROC,
                                  flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                  fflags=select.KQ_NOTE_EXIT)
            try:
                self._kq.control([event], 0, 0)
            except ProcessLookupError:
                self._kq.close()
                raise OwnerGone(self.pid)
        elif hasattr(os, 'pidfd_open'):
            try:
                self._fd = os.pidfd_open(self.pid)
            except ProcessLookupError:
                raise OwnerGone(self.pid)
        else:
            raise RuntimeError('no kqueue and no pidfd: an owner pid cannot be watched here')

    def close(self):
        if self._kq is not None: self._kq.close()
        elif self._fd is not None: os.close(self._fd)

    def fileno(self):
        return self._kq.fileno() if self._kq is not None else self._fd

    def gone(self):
        """True once the kernel has reported the exit; never blocks."""
        if not self._gone:
            if self._kq is not None:
                self._gone = bool(self._kq.control(None, 1, 0))
            else:
                ready, _, _ = select.select([self._fd], [], [], 0)
                self._gone = bool(ready)
        return self._gone


def _is_launcher(command):
    """A shell, or an interpreter/wrapper standing between the owner and fm.
    Any case: macOS names a framework Python `Python`."""
    name = os.path.basename(command.strip().split(' ')[0] if command.strip() else '').lstrip('-')
    return bool(re.fullmatch(r'(ba|z|da|k|c|tc|fi)?sh|env|timeout|nice|sudo|sandbox-exec|bwrap|'
                             r'perl[0-9.]*|python[0-9.]*', name, re.IGNORECASE))


def _darwin_parent_of(pid):
    """(parent pid, command) of pid from the kernel: libproc's
    proc_pidinfo(PROC_PIDTBSDINFO), struct proc_bsdinfo. Not ps, which is
    setuid on macOS and which a sandboxed round may not run."""
    import ctypes
    class BsdInfo(ctypes.Structure):
        _fields_ = [('pbi_flags', ctypes.c_uint32), ('pbi_status', ctypes.c_uint32),
                    ('pbi_xstatus', ctypes.c_uint32), ('pbi_pid', ctypes.c_uint32),
                    ('pbi_ppid', ctypes.c_uint32), ('pbi_uid', ctypes.c_uint32),
                    ('pbi_gid', ctypes.c_uint32), ('pbi_ruid', ctypes.c_uint32),
                    ('pbi_rgid', ctypes.c_uint32), ('pbi_svuid', ctypes.c_uint32),
                    ('pbi_svgid', ctypes.c_uint32), ('rfu_1', ctypes.c_uint32),
                    ('pbi_comm', ctypes.c_char * 16), ('pbi_name', ctypes.c_char * 32),
                    ('pbi_nfiles', ctypes.c_uint32), ('pbi_pgid', ctypes.c_uint32),
                    ('pbi_pjobc', ctypes.c_uint32), ('e_tdev', ctypes.c_uint32),
                    ('e_tpgid', ctypes.c_uint32), ('pbi_nice', ctypes.c_int32),
                    ('pbi_start_tvsec', ctypes.c_uint64), ('pbi_start_tvusec', ctypes.c_uint64)]
    try:
        libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
    except OSError:
        return None, ''
    info = BsdInfo()
    PROC_PIDTBSDINFO = 3
    got = libproc.proc_pidinfo(int(pid), PROC_PIDTBSDINFO, ctypes.c_uint64(0),
                               ctypes.byref(info), ctypes.sizeof(info))
    if got != ctypes.sizeof(info):
        return None, ''
    name = (info.pbi_name or info.pbi_comm).decode(errors='replace')
    return int(info.pbi_ppid), name


def _parent_of(pid):
    """(parent pid, command) of pid, or (None, '') when it cannot be read.
    From the kernel: /proc on Linux, libproc on macOS; ps only where there
    is neither."""
    try:
        with open(f'/proc/{pid}/stat', 'rb') as f:
            stat_line = f.read().decode(errors='replace')
        with open(f'/proc/{pid}/cmdline', 'rb') as f:
            command = f.read().split(b'\0')[0].decode(errors='replace')
        return int(stat_line[stat_line.rindex(')') + 2:].split()[1]), command
    except (OSError, ValueError, IndexError):
        pass
    if sys.platform == 'darwin':
        return _darwin_parent_of(pid)
    try:
        out = subprocess.run(['ps', '-o', 'ppid=', '-o', 'comm=', '-p', str(pid)],
                             stdin=subprocess.DEVNULL, capture_output=True, text=True)
    except OSError:
        return None, ''
    fields = out.stdout.strip().split(None, 1)
    if out.returncode != 0 or len(fields) != 2:
        return None, ''
    return int(fields[0]), fields[1]


# the session a suite of bin/ci.sh belongs to: not an FM_* name, because
# suites scrub FM_* before they start, and a suite that lost FM_SESSION_PID
# would otherwise walk up to the operator's own harness
CI_SESSION = 'FIRSTMATE_CI_SESSION'


def session_owner():
    """The pid of the session fm's long-lived processes belong to:
    FM_SESSION_PID, else FIRSTMATE_CI_SESSION, else the nearest ancestor
    that is not a launcher. Never a guess: when the walk cannot read a
    parent, reaches pid 1 or runs out of hops, it raises RuntimeError and
    nothing is started for an owner nobody named."""
    for key in ('FM_SESSION_PID', CI_SESSION):
        given = os.environ.get(key, '')
        if given:
            if not re.fullmatch(r'[1-9][0-9]*', given):
                raise ValueError(f'{key} must be a pid')
            return int(given)
    pid = os.getppid()
    for _ in range(64):
        if pid <= 1:
            raise RuntimeError('no session found: every ancestor up to pid 1 is a launcher; '
                               'name one with FM_SESSION_PID')
        parent, command = _parent_of(pid)
        if parent is None:
            raise RuntimeError(f'no session found: the parent of {pid} cannot be read; '
                               'name one with FM_SESSION_PID')
        if not _is_launcher(command):
            return pid
        pid = parent
    raise RuntimeError('no session found within 64 ancestors; name one with FM_SESSION_PID')


def _keeper_argv(argv, fd=None, pid=None, name=None):
    how = ['--fd', str(fd)] if fd is not None else ['--pid', str(pid)]
    return [sys.executable, HERE, 'keep', *how, *(['--name', name] if name else []), '--', *argv]


def owner_record_live(path):
    """Read the keeper's kernel-held ownership record, never a PID probe."""
    import fcntl
    try:
        with open(path, 'rb') as record:
            try: fcntl.flock(record, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError: return True
            return False
    except FileNotFoundError:
        return False


def start(argv, owner=None, name=None, direct=False, owner_record=None, **popen):
    """Start argv under a keeper; return the keeper's Popen.

    owner=None: this process owns it through a pipe it keeps open for its
    whole life. owner=<pid>: that process owns it, watched by the kernel.
    The keeper starts in its own session before Popen returns, so a
    short-lived caller can safely exit and clean up its own process group.

    direct=True: argv is fm's own Python, which calls hold() itself as it
    starts, so no keeper stands between: it is started in a session of its
    own, and its pid and process group are the program's. The lifeline is
    handed over in FM_LIFELINE_FD (a pipe) or FM_LIFELINE_PID (an owner
    pid), and hold() refuses to run without one."""
    for refused in ('start_new_session', 'preexec_fn', 'process_group', 'pass_fds'):
        if refused in popen:
            raise ValueError(refused + ' belongs to the lifeline, not to the caller')
    if owner_record is not None:
        if direct or owner is None:
            raise ValueError('an ownership record requires a keeper and an explicit owner')
        import fcntl
        # Acquire before spawn so the reservation has no unowned startup gap.
        # Only the keeper inherits this descriptor, never its child. Kernel
        # close releases it on every exit, including SIGKILL.
        ProcessExit(owner).close()
        with open(owner_record, 'a+b') as record:
            fcntl.flock(record, fcntl.LOCK_EX | fcntl.LOCK_NB)
            env = dict(popen.pop('env', None) or os.environ)
            env['FM_LAUNCH_OWNER_RECORD'] = os.path.abspath(owner_record)
            return subprocess.Popen(_keeper_argv(argv, pid=int(owner), name=name),
                env=env, pass_fds=(record.fileno(),), start_new_session=True, **popen)
    if direct:
        env = dict(popen.pop('env', None) or os.environ)
        env.pop('FM_LIFELINE_FD', None); env.pop('FM_LIFELINE_PID', None)
        if owner is not None:
            ProcessExit(owner).close()
            env['FM_LIFELINE_PID'] = str(int(owner))
            return subprocess.Popen(argv, env=env, start_new_session=True, **popen)
        read_end, write_end = os.pipe()
        env['FM_LIFELINE_FD'] = str(read_end)
        try:
            child = subprocess.Popen(argv, env=env, pass_fds=(read_end,), start_new_session=True, **popen)
        except BaseException:
            os.close(write_end)
            raise
        finally:
            os.close(read_end)
        _held.append(write_end)
        return child
    if owner is None:
        read_end, write_end = os.pipe()
        try:
            child = subprocess.Popen(_keeper_argv(argv, fd=read_end, name=name), pass_fds=(read_end,), start_new_session=True, **popen)
        except BaseException:
            os.close(write_end)
            raise
        finally:
            os.close(read_end)
        _held.append(write_end)
        return child
    # said now, to the caller, rather than by a keeper that exits at once
    ProcessExit(owner).close()
    return subprocess.Popen(_keeper_argv(argv, pid=int(owner), name=name), start_new_session=True, **popen)


def fork():
    """Fork a Python child in a session of its own, owned by this process.

    Returns (pid, None) in the parent and (0, lifeline_fd) in the child. The
    child reads EOF on lifeline_fd when the parent - and every process the
    parent handed the write end to - has died. The child closes every
    write end the parent held for other children, so it keeps none of them
    alive."""
    read_end, write_end = os.pipe()
    pid = os.fork()
    if pid:
        os.close(read_end)
        _held.append(write_end)
        return pid, None
    os.close(write_end)
    for fd in _held:
        try:
            os.close(fd)
        except OSError:
            pass
    _held.clear()
    try:
        os.setsid()
    except OSError:
        pass
    return 0, read_end


def wait_owner(fd, timeout=None):
    """Block until the owner at the other end of fd is gone; False on timeout."""
    deadline = None if timeout is None else time.monotonic() + timeout
    while True:
        left = None if deadline is None else max(0.0, deadline - time.monotonic())
        ready, _, _ = select.select([fd], [], [], left)
        if not ready:
            return False
        if os.read(fd, 4096) == b'':
            return True


def hold():
    """The other end of start(direct=True), called by the started program
    as it begins: a thread blocks on the lifeline it was handed and, when
    the owner is gone, ends this process's group - SIGTERM, then SIGKILL
    after FM_LIFELINE_GRACE - from a helper outside the group, so the
    SIGTERM that ends this process does not also end the one that must
    follow it with SIGKILL. Returns the owner it holds to; raises
    RuntimeError when nothing was handed over (started some other way) and
    OwnerGone when the owner has already exited."""
    import threading
    fd = os.environ.pop('FM_LIFELINE_FD', '')
    pid = os.environ.pop('FM_LIFELINE_PID', '')
    if fd:
        watch = int(fd)
        os.set_inheritable(watch, False)
        def gone():
            wait_owner(watch)
        owner = 'pipe'
    elif pid:
        exit_of = ProcessExit(int(pid))
        def gone():
            while True:
                select.select([exit_of.fileno()], [], [])
                if exit_of.gone():
                    return
        owner = int(pid)
    else:
        raise RuntimeError('started without a lifeline; start it through bin/lib/fm_lifeline.py')
    def watch_owner():
        gone()
        _end_group_from_outside(os.getpgrp())
    threading.Thread(target=watch_owner, name='fm-lifeline', daemon=True).start()
    return owner


def _end_group_from_outside(pgid):
    """SIGTERM a group, and SIGKILL what is left of it after the grace, from
    a forked helper in a session of its own, which the signals miss. The
    helper is bounded by the grace and holds nothing."""
    try:
        helper = os.fork()
    except OSError:
        _signal_group(pgid, signal.SIGKILL)
        return
    if helper:
        # this process is in the group; the helper's TERM is what ends it
        return
    try:
        os.setsid()
        _signal_group(pgid, signal.SIGTERM)
        deadline = time.monotonic() + _grace()
        while _group_alive(pgid) and time.monotonic() < deadline:
            time.sleep(0.05)
        _signal_group(pgid, signal.SIGKILL)
    finally:
        os._exit(0)


# --- The wake: one doorbell per waiter (T-151) -------------------------------
# A FIFO hands each line to exactly one reader, so one shared FIFO loses a
# wake as soon as two waiters hold it. Each waiter registers a doorbell of
# its own under state/session/wake.d/, and a writer rings every one. The
# bell is only a hint to look again: the durable state - the answer file,
# the wake queue - is the truth, and a waiter checks it once after it has
# registered (so a write in between is found) and again on every ring.
WAKE_DIR = 'state/session/wake.d'


class Doorbell:
    """A waiter's own FIFO, registered for as long as it is open.

    Made under a name no ringer reads, opened O_RDWR (so no closing writer
    is ever an end-of-file), and only then renamed into place, so a ringer
    never finds a registered bell with nobody holding it. Removed on close;
    a bell whose waiter was SIGKILLed is removed by the next ring."""

    def __init__(self, root, channel='wake.d'):
        if channel not in ('wake.d', 'autopilot.d'):
            raise ValueError('unknown notification channel')
        base = os.path.join(record_root(root), 'state/session', channel)
        os.makedirs(base, exist_ok=True)
        name = f'{os.getpid()}-{os.urandom(6).hex()}'
        temp = os.path.join(base, '.' + name + '.new')
        self.path = os.path.join(base, name + '.fifo')
        os.mkfifo(temp, 0o600)
        try:
            self.fd = os.open(temp, os.O_RDWR | os.O_NONBLOCK)
            os.rename(temp, self.path)
        except BaseException:
            try: os.unlink(temp)
            except OSError: pass
            raise

    def wait(self, timeout=None):
        """Block until rung (True) or until timeout seconds pass (False)."""
        ready, _, _ = select.select([self.fd], [], [], timeout)
        if not ready:
            return False
        try:
            while os.read(self.fd, 4096):
                pass
        except BlockingIOError:
            pass
        return True

    def close(self):
        if self.fd is None:
            return
        try: os.unlink(self.path)
        except OSError: pass
        os.close(self.fd)
        self.fd = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def ring(root, line):
    """Ring every registered doorbell with one line; returns how many rang.

    Each is opened O_WRONLY|O_NONBLOCK, so ringing never blocks: ENXIO is a
    bell nobody holds any more (a waiter that was killed), unlinked; EAGAIN
    is a pipe already full, a bell already rung. The caller appends to the
    wake queue first: a bell is a hint, the queue is the record."""
    return ring_state(os.path.join(record_root(root), 'state'), line)


def ring_state(state, line):
    """Ring an already resolved project's state (for registry/policy writers).

    Callers must obtain state through the canonical project resolver. This
    avoids changing process-global FM_PROJECT while notifying two projects.
    """
    # A semantic wake also updates autopilot's durable local inputs. It is
    # forwarded one way only: raw autopilot events never ring firstmate.
    ring_events(state, line)
    return _ring_directory(os.path.join(state, 'session/wake.d'), line)


def ring_events(state, line):
    """Notify only the scripted supervisor, using already resolved state."""
    return _ring_directory(os.path.join(state, 'session/autopilot.d'), line)


def _ring_directory(directory, line):
    import glob
    rang = 0
    data = (str(line).replace('\n', ' ') + '\n').encode()
    for path in sorted(glob.glob(os.path.join(glob.escape(directory), '*.fifo'))):
        try:
            fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK | getattr(os, 'O_NOFOLLOW', 0))
        except OSError as error:
            if error.errno == errno.ENXIO:
                try: os.unlink(path)
                except OSError: pass
            continue
        try:
            if not stat.S_ISFIFO(os.fstat(fd).st_mode):
                continue
            os.write(fd, data)
            rang += 1
        except BlockingIOError:
            rang += 1
        except OSError:
            pass
        finally:
            os.close(fd)
    return rang


WAKE_QUEUE = 'state/session/wake.jsonl'


def push(root, ident, reason, line, extra=None):
    """Push one wake (T-137): append it to the wake queue, then ring every
    doorbell. The writer of the event is the one that calls this - a round
    ending (fm-worker.sh, fm-review.sh), a run found lost (fm-herdr.py), a
    gate result (fm-emit.sh) - so nothing ever has to look for it. `line`
    is the short machine-readable reason firstmate is woken with
    (`review: T-134 APPROVE 4ea1ec2`); `extra` is kept on the item.
    Returns how many doorbells rang."""
    import fcntl
    import json
    if not re.fullmatch(r'[A-Za-z0-9_-]+', str(ident)):
        raise ValueError('a wake id is letters, digits, - and _')
    line = ' '.join(str(line).split())
    item = dict(extra or {})
    item.update(id=str(ident), reason=str(reason), line=line, woken=time.time())
    path = os.path.join(record_root(root), WAKE_QUEUE)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.write(fd, (json.dumps(item) + '\n').encode())
    finally:
        os.close(fd)
    return ring(root, line)


# One record of what firstmate has been given (T-137). Every reader of the
# wake queue - the watch that hands a wake to the harness's hook, and
# `fm-session.sh wait/status/start` - counts a wake as delivered by this
# record alone, so a wake one of them delivered is never delivered again by
# the other. `fm-session.sh ack` and the watch's take both write it here.
ACK_DIR = 'state/session/acknowledged'


def _ack_record(root, ident):
    import json
    base = os.path.join(record_root(root), 'state/session')
    try:
        with open(os.path.join(base, '.ack-transaction.json')) as f:
            before = json.load(f)
        if not isinstance(before, dict):
            return None
        if ident in before:
            return before[ident]
    except FileNotFoundError:
        pass
    except (OSError, ValueError, TypeError):
        # Unknown transaction state must never expose tentative watermarks.
        return None
    try:
        with open(os.path.join(record_root(root), ACK_DIR, str(ident) + '.json')) as f:
            return json.load(f)
    except (OSError, ValueError, TypeError):
        return None


def acknowledged_many(root, identifiers, *, blocking=True):
    """One committed snapshot. Busy nonblocking readers conservatively see pending."""
    import fcntl
    import math
    identifiers = list(identifiers)
    if any(not isinstance(ident, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', ident)
           for ident in identifiers):
        raise ValueError('invalid wake id')
    unknown = dict.fromkeys(identifiers)
    base = os.path.join(record_root(root), 'state/session')
    os.makedirs(base, exist_ok=True)
    lock = os.open(os.path.join(base, '.ack.lock'), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_SH | (0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError:
            return unknown
        result = {}
        for ident in identifiers:
            record = _ack_record(root, ident)
            stamp = record.get('acknowledged') if isinstance(record, dict) else None
            result[ident] = (stamp if type(stamp) in (int, float) and
                             math.isfinite(stamp) and stamp >= 0 else None)
        return result
    finally:
        os.close(lock)


def acknowledged(root, ident):
    """Read the committed watermark, hiding an interrupted batch's writes."""
    return acknowledged_many(root, [ident])[ident]


def is_acknowledged(root, ident, woken):
    seen = acknowledged(root, ident)
    return seen is not None and seen >= (woken or 0)


def _write_ack(path, record):
    import json
    temp = f'{path}.{os.getpid()}.new'
    with open(temp, 'w') as out:
        json.dump(record, out, indent=2)
        out.write('\n')
        out.flush()
        os.fsync(out.fileno())
    os.replace(temp, path)


def acknowledge_batch(root, items, *, before_commit=None):
    """Commit watermarks together, with a durable undo journal.

    All writers use .ack.lock. Readers see pre-batch values while the journal
    exists; the next writer rolls an interrupted batch back before proceeding.
    Removing the journal is the commit point. Per-ID files stay compatible
    with the board. As with any claim API, death after commit but before the
    caller receives the return value requires a harness delivery receipt to
    resolve; this transaction protects interruption during acknowledgement.
    An optional before_commit callback may cancel after acquiring the lock
    or before removing the undo journal; cancellation restores the old batch.
    """
    import fcntl
    import json
    base = os.path.join(record_root(root), 'state/session')
    directory = os.path.join(record_root(root), ACK_DIR)
    os.makedirs(directory, exist_ok=True)
    transaction = os.path.join(base, '.ack-transaction.json')
    lock = os.open(os.path.join(base, '.ack.lock'), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(transaction) as f:
                before = json.load(f)
        except FileNotFoundError:
            before = None
        if before is not None:
            for ident, record in before.items():
                path = os.path.join(directory, ident + '.json')
                if record is None:
                    try:
                        os.unlink(path)
                    except FileNotFoundError:
                        pass
                else:
                    _write_ack(path, record)
            os.unlink(transaction)
        if before_commit is not None:
            before_commit()
        before, after = {}, {}
        for item in items:
            ident = str(item['id'])
            if not re.fullmatch(r'[A-Za-z0-9_-]+', ident):
                raise ValueError('a wake id is letters, digits, - and _')
            if ident not in before:
                before[ident] = _ack_record(root, ident)
            old = after.get(ident) or before[ident]
            stamp = item.get('woken') or 0
            if old is None or old['acknowledged'] < stamp:
                after[ident] = dict(id=ident, acknowledged=stamp, wakes=item.get('wakes', 1))
        if after:
            _write_ack(transaction, before)
            for ident, record in after.items():
                _write_ack(os.path.join(directory, ident + '.json'), record)
            if before_commit is not None:
                try:
                    before_commit()
                except BaseException:
                    # The durable journal remains authoritative until commit.
                    # Restore now as well, so a cancelled claimant leaves no
                    # acknowledgement even to readers outside this module.
                    for ident, record in before.items():
                        path = os.path.join(directory, ident + '.json')
                        if record is None:
                            try:
                                os.unlink(path)
                            except FileNotFoundError:
                                pass
                        else:
                            _write_ack(path, record)
                    os.unlink(transaction)
                    raise
            os.unlink(transaction)
        return {ident: after.get(ident) or record for ident, record in before.items()}
    finally:
        os.close(lock)


def acknowledge(root, ident, woken, wakes=1, *, exact_wake=True):
    """Explicit acknowledgement shares batch serialization and recovery."""
    return acknowledge_batch(root, [dict(id=ident, woken=woken, wakes=wakes)])[str(ident)]


def doorbells(root):
    """How many waiters hold a doorbell now (a stale one counts until rung)."""
    import glob
    return len(glob.glob(os.path.join(glob.escape(os.path.join(record_root(root), WAKE_DIR)), '*.fifo')))


def _leave_on_signals():
    """A waiter's SIGTERM, SIGINT or SIGHUP unwinds it, so its doorbell is removed."""
    def leave(signum, _frame):
        raise SystemExit(128 + signum)
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, leave)


def await_file(root, path, timeout=0):
    """Wait for path to exist, woken by rings: True when it does, False when
    the timeout (seconds, 0 for none) ends first."""
    deadline = time.monotonic() + timeout if timeout else None
    with Doorbell(root) as bell:
        while True:
            if os.path.exists(path):
                return True
            left = None if deadline is None else deadline - time.monotonic()
            if left is not None and left <= 0:
                return False
            if not bell.wait(left):
                return os.path.exists(path)


def _signal_group(pgid, signum):
    try:
        os.killpg(pgid, signum)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def _group_alive(pgid):
    # a zero signal to the group asks the kernel whether any member is left;
    # used only for the bounded end of a stop, never to decide the owner
    return _signal_group(pgid, 0)


def group_exits(pgid):
    """Subscribe to the current members before ending a process group.

    Used only for teardown, never to poll an owner's liveness. The group's
    SIGKILL ends every member; the descriptors let us wait for exit, including
    grandchildren which this process cannot reap with waitpid.
    """
    pids = (int(p) for p in os.listdir('/proc') if p.isdigit()) if sys.platform != 'darwin' else (
        pid for pid, _, _ in _darwin_processes())
    watches = []
    for pid in pids:
        try:
            if os.getpgid(pid) == pgid:
                watches.append(ProcessExit(pid))
        except (ProcessLookupError, OwnerGone):
            pass
    return watches


def wait_exits(watches, timeout=15):
    """Drain kernel exit notifications within one deadline; close every fd."""
    deadline = time.monotonic() + timeout
    try:
        pending = [watch for watch in watches if not watch.gone()]
        while pending:
            left = deadline - time.monotonic()
            if left <= 0:
                raise RuntimeError('process teardown did not finish before its deadline')
            ready, _, _ = select.select([w.fileno() for w in pending], [], [], left)
            pending = [w for w in pending if w.fileno() not in ready or not w.gone()]
    finally:
        for watch in watches:
            watch.close()


def close_scope(directory):
    """Close an opt-in keeper scope to new launches and stop its keepers.

    Registration and child creation share the scope lock with closure. A
    keeper arriving after closure cannot start a new writer. Each PID record
    stays kernel-locked for its keeper's lifetime, so stale records are safe.
    """
    import fcntl
    from pathlib import Path
    base = Path(directory)
    base.mkdir(parents=True, exist_ok=True)
    watches = []
    with open(base / 'launch.lock', 'a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        (base / 'closed').touch()
        for path in base.glob('*.keeper'):
            with path.open('rb') as record:
                try:
                    fcntl.flock(record, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    continue
                except BlockingIOError:
                    pass
                pid = int(path.stem)
                try:
                    watches.append(ProcessExit(pid))
                    os.kill(pid, signal.SIGTERM)
                    os.kill(pid, signal.SIGCONT)
                except (ProcessLookupError, OwnerGone):
                    pass
    wait_exits(watches)
    # An exited keeper is not proof of successful drainage if its cleanup
    # raised. Preserve the fixture tree on that failure instead of removing
    # it underneath a process whose exit has not been established.
    for path in base.glob('*.keeper'):
        if path.read_bytes() != b'drained\n':
            raise RuntimeError(f'keeper did not drain its process group: {path.stem}')


def keep(fd, pid, name, argv):
    """The keeper: run argv for exactly as long as the owner lives."""
    scope = os.environ.get('FM_LIFELINE_SCOPE')
    if not scope:
        try:
            os.setsid()
        except OSError:
            pass
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    if fd is not None:
        os.set_blocking(fd, False)
        watch = fd
        owner = None
    else:
        try:
            owner = ProcessExit(pid)
        except OwnerGone:
            print(f'fm-lifeline: owner {pid} is already gone; {name or argv[0]} not started', file=sys.stderr)
            return 75
        watch = owner.fileno()
    wake_r, wake_w = os.pipe()
    os.set_blocking(wake_r, False); os.set_blocking(wake_w, False)
    stop = []
    signal.set_wakeup_fd(wake_w)
    signal.signal(signal.SIGCHLD, lambda *_: None)
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda signum, _frame: stop.append(signum))
    env = dict(os.environ)
    if pid is not None:
        env['FM_SESSION_PID'] = str(pid)
    kwargs = dict(process_group=0) if sys.version_info >= (3, 11) else dict(preexec_fn=os.setpgrp)
    launch_lock = record = child = None
    try:
        if scope:
            import fcntl
            os.makedirs(scope, exist_ok=True)
            launch_lock = open(os.path.join(scope, 'launch.lock'), 'a+b')
            fcntl.flock(launch_lock, fcntl.LOCK_EX)
            if os.path.exists(os.path.join(scope, 'closed')):
                return 0
            record = open(os.path.join(scope, f'{os.getpid()}.keeper'), 'a+b')
            fcntl.flock(record, fcntl.LOCK_EX)
            record.seek(0)
            record.truncate()
            # Register before leaving the board's group: even a keeper
            # interrupted during startup is either in that group or tracked.
            try:
                os.setsid()
            except OSError:
                pass
        child = subprocess.Popen(argv, env=env, close_fds=True, **kwargs)
    except OSError as error:
        print(f'fm-lifeline: cannot start {argv[0]}: {error}', file=sys.stderr)
        return 127
    finally:
        try:
            if record is not None and child is None:
                # No process group exists to drain. Remove registration for
                # every failed startup, including exceptions before Popen,
                # while closure is still excluded by the launch lock.
                try:
                    os.unlink(record.name)
                finally:
                    record.close()
        finally:
            if launch_lock is not None:
                launch_lock.close()
    why = None
    while why is None:
        try:
            ready, _, _ = select.select([watch, wake_r], [], [])
        except InterruptedError:
            ready = []
        if wake_r in ready:
            try:
                while os.read(wake_r, 512):
                    pass
            except BlockingIOError:
                pass
        if child.poll() is not None:
            why = 'exited'
        elif stop:
            why = 'stopped'
        elif watch in ready:
            if owner is not None:
                why = 'owner' if owner.gone() else None
            else:
                try:
                    data = os.read(fd, 4096)
                except BlockingIOError:
                    data = None
                if data == b'':
                    why = 'owner'
    # The owner gone or the keeper stopped: the program and its group are
    # asked to end, and made to after the grace. The program done: whatever
    # it left in its group is a process nobody owns any more, and goes too.
    _signal_group(child.pid, signal.SIGTERM)
    deadline = time.monotonic() + _grace()
    while child.poll() is None and time.monotonic() < deadline:
        try:
            select.select([wake_r], [], [], max(0.0, deadline - time.monotonic()))
            while os.read(wake_r, 512):
                pass
        except (BlockingIOError, InterruptedError):
            pass
    exits = group_exits(child.pid) if scope else []
    if child.poll() is None or _group_alive(child.pid):
        _signal_group(child.pid, signal.SIGKILL)
    if scope:
        # Capture any member forked between subscription and the group
        # signal. This is a second snapshot, not a liveness polling loop.
        exits.extend(group_exits(child.pid))
    code = child.wait()
    wait_exits(exits)
    if record is not None:
        record.write(b'drained\n')
        record.close()
    if why == 'owner':
        print(f'fm-lifeline: the owner of {name or argv[0]} is gone; stopped it', file=sys.stderr)
    return code if code >= 0 else 128 - code


def _darwin_processes():
    """(pid, argv, env) of every process of this user, from the kernel
    (libproc and KERN_PROCARGS2, what ps itself reads). Not ps: ps is
    setuid on macOS, and a sandboxed round may not run it."""
    import ctypes, ctypes.util, struct
    libc = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True)
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
    count = libproc.proc_listallpids(None, 0)
    pids = (ctypes.c_int * (count * 2 + 64))()
    count = libproc.proc_listallpids(pids, ctypes.sizeof(pids))
    if count <= 0:
        raise RuntimeError('the process list could not be read')
    argmax = ctypes.c_int(); size = ctypes.c_size_t(ctypes.sizeof(argmax))
    if libc.sysctl((ctypes.c_int * 2)(1, 8), 2, ctypes.byref(argmax), ctypes.byref(size), None, 0) != 0:
        raise RuntimeError('KERN_ARGMAX could not be read')
    for pid in pids[:count]:
        size = ctypes.c_size_t(argmax.value); raw = ctypes.create_string_buffer(argmax.value)
        if libc.sysctl((ctypes.c_int * 3)(1, 49, pid), 3, raw, ctypes.byref(size), None, 0) != 0:
            continue   # another user's, or gone
        data = raw.raw[:size.value]
        if len(data) < 4:
            continue
        argc = struct.unpack('i', data[:4])[0]
        rest = data[4:]
        at = rest.find(b'\0')          # the executable's path, then padding
        while 0 <= at < len(rest) and rest[at] == 0:
            at += 1
        words = rest[at:].split(b'\0')
        argv = words[:argc]
        env = []
        for word in words[argc:]:
            if not word:
                break
            env.append(word)
        yield pid, b' '.join(argv).decode(errors='replace'), env


def scope_survivors(marker, roots=()):
    """Every process still carrying FIRSTMATE_CI_SCOPE=<marker>, or naming
    one of `roots` (the suite's own temp root) in its command line:
    [(pid, command)]. Read from the kernel: /proc on Linux, libproc on
    macOS. macOS withholds the environment of its platform binaries
    (/bin/bash, /bin/sleep) but not their argv, and every fixture a suite
    starts a process in lives under its root, so the root finds what the
    marker cannot see there; on Linux the marker alone sees everything."""
    want = f'{SCOPE}={marker}'.encode()
    named = [re.compile(re.escape(root.rstrip('/')) + r'(/|\s|$)') for root in roots if root.strip('/')]
    def matches(env, command):
        return want in env or any(pattern.search(command) for pattern in named)
    found = []
    me = os.getpid()
    if os.path.isdir('/proc/self'):
        for entry in os.listdir('/proc'):
            if not entry.isdigit() or int(entry) == me:
                continue
            try:
                with open(f'/proc/{entry}/cmdline', 'rb') as f:
                    command = f.read().replace(b'\0', b' ').decode(errors='replace').strip()
                try:
                    with open(f'/proc/{entry}/environ', 'rb') as f:
                        env = f.read().split(b'\0')
                except PermissionError:
                    env = []
            except OSError:
                continue
            # a zombie has no command line and nothing left to end
            if command and matches(env, command):
                found.append((int(entry), command))
        return found
    if sys.platform == 'darwin':
        return [(pid, command) for pid, command, env in _darwin_processes()
                if pid != me and command and matches(env, command)]
    raise RuntimeError('no /proc and not macOS: processes cannot be listed here')


def _usage():
    print(__doc__.split('\n\n')[-2], file=sys.stderr)
    return 64


def main(args):
    if not args:
        return _usage()
    mode, *args = args
    if mode == 'keep':
        fd = pid = name = None
        while args and args[0] != '--':
            flag, *rest = args
            if not rest:
                return _usage()
            if flag == '--fd': fd = int(rest[0])
            elif flag == '--pid': pid = int(rest[0])
            elif flag == '--name': name = rest[0]
            else: return _usage()
            args = rest[1:]
        argv = args[1:]
        if not argv or (fd is None) == (pid is None):
            return _usage()
        return keep(fd, pid, name, argv)
    if mode == 'spawn':
        owner = log = None
        while args and args[0] != '--':
            flag, *rest = args
            if flag == '--session':
                owner = None; args = rest; continue
            if not rest:
                return _usage()
            if flag == '--owner-pid': owner = int(rest[0])
            elif flag == '--log': log = rest[0]
            else: return _usage()
            args = rest[1:]
        argv = args[1:]
        if not argv:
            return _usage()
        owner = session_owner() if owner is None else owner
        out = open(log, 'ab') if log else subprocess.DEVNULL
        try:
            child = start(argv, owner=owner, stdin=subprocess.DEVNULL, stdout=out, stderr=out)
        finally:
            if log: out.close()
        print(child.pid)
        return 0
    if mode == 'session-owner':
        print(session_owner())
        return 0
    if mode == 'acknowledged':
        if len(args) != 1 or not args[0]:
            return _usage()
        import json
        identifiers = json.load(sys.stdin)
        if not isinstance(identifiers, list):
            raise ValueError('wake ids must be an array')
        print(json.dumps(acknowledged_many(args[0], identifiers, blocking=False)))
        return 0
    if mode == 'ring-events':
        if len(args) != 2 or not args[0]:
            return _usage()
        print(ring_events(os.path.join(record_root(args[0]), 'state'), args[1]))
        return 0
    if mode == 'ring':
        if len(args) != 2 or not args[0]:
            return _usage()
        print(ring(args[0], args[1]))
        return 0
    if mode == 'push':
        if len(args) not in (4, 5) or not args[0]:
            return _usage()
        import json
        extra = json.loads(args[4]) if len(args) == 5 and args[4] else {}
        if not isinstance(extra, dict):
            raise ValueError('the extra fields of a wake are a JSON object')
        print(push(args[0], args[1], args[2], args[3], extra))
        return 0
    if mode == 'await':
        if len(args) not in (2, 3) or not args[0]:
            return _usage()
        timeout = float(args[2]) if len(args) == 3 and args[2] else 0
        _leave_on_signals()
        return 0 if await_file(args[0], args[1], timeout) else 1
    if mode == 'scope-survivors':
        kill = False; roots = []
        while args[:1] in (['--kill'], ['--root']):
            if args[0] == '--kill':
                kill = True; args = args[1:]
            elif len(args) < 2:
                return _usage()
            else:
                roots.append(args[1]); args = args[2:]
        if len(args) != 1 or not args[0]:
            return _usage()
        found = scope_survivors(args[0], roots)
        for pid, command in found:
            print(pid, command)
        if kill and found:
            for pid, _ in found:
                try: os.kill(pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError): pass
        return 1 if found else 0
    return _usage()


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, RuntimeError) as error:
        print('fm-lifeline: ' + str(error), file=sys.stderr)
        sys.exit(70)
