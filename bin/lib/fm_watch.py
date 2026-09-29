#!/usr/bin/env python3
"""Waking firstmate, whatever harness it runs in (T-137).

The wake is pushed, never watched. Whoever writes an event that needs
firstmate - a round ending (fm-worker.sh, fm-review.sh), a run found lost
(fm-herdr.py), a gate result (fm-emit.sh), a card answered or a merge
settled (the board) - appends one item to the wake queue,
state/session/wake.jsonl, and rings every doorbell under
state/session/wake.d (bin/lib/fm_lifeline.py's push and ring). Nothing
here polls: every wait below blocks on a doorbell, a lock or a process's
exit, each of which the kernel reports.

  the watcher (bin/fm-watch.sh)   one cycle: holds the watch lock, takes
                                  every wake past the cursor, hands the
                                  watch to its successor, then writes the
                                  wake for an arm to claim, and exits
  the arm (bin/fm-watch-arm.sh)   attaches to the live cycle or starts
                                  one (single-flight: a lock and a
                                  generation), then parks until it claims
                                  a wake, its owner dies, or its wait ends
  the guard (bin/fm-turnend-guard.sh)
                                  refuses a turn end that would leave
                                  firstmate blind while work is in flight

Each harness hook is one of these, spoken in that harness's protocol:

  claude  Stop, asyncRewake: `fm-watch-arm.sh --hook claude` parks and
          exits 2 with the wake on stderr, which wakes an idle session;
          it exits 0 when its owning claude exits (kqueue / pidfd).
          Stop, synchronous: `fm-turnend-guard.sh --hook claude`.
          UserPromptSubmit: `fm-watch-arm.sh --turn-start claude`.
  codex   Stop: `fm-turnend-guard.sh --hook codex` answers
          {"decision":"block","reason":...} with any waiting wake, or
          with the order to park on the arm in the foreground.
          UserPromptSubmit: `fm-watch-arm.sh --turn-start codex`.
  cursor  stop: `fm-turnend-guard.sh --hook cursor` answers
          {"followup_message":...} the same way, bounded by loop_limit.

bin/lib/fm_hooks.py writes and removes exactly those entries in each
harness's local, uncommitted config.

Files, all under state/watch/: cycle.lock (held by the live cycle, so
the kernel says whether one lives), arm.lock (who may start a cycle),
generation, owner.json (the live cycle: gen, pid, owner, its doorbell),
cursor (how far into the wake queue the watch has taken), wake/<gen>.json
(a wake waiting to be claimed), last-wake.json, journal.
"""
import errno
import fcntl
import json
import os
import re
import select
import shlex
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
BIN = HERE.parent
sys.path.insert(0, str(HERE))
# no __pycache__ in bin/lib: the tree stays exactly what was committed
sys.dont_write_bytecode = True
import fm_lifeline as life  # noqa: E402

WATCH = 'state/watch'
HARNESSES = ('claude', 'codex', 'cursor')
# Claude Code's asyncRewake hook runs for at most this long; the arm gives
# up a minute before, so its wait always ends before the harness kills it
CLAUDE_TIMEOUT = 86400
PARK_SECS = 3000
MAX_LINES = 20


def now_iso():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def wdir(root):
    path = Path(root) / WATCH
    path.mkdir(parents=True, exist_ok=True)
    return path


def read_json(path):
    try:
        value = json.loads(Path(path).read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def save(path, text):
    path = Path(path)
    temp = path.with_name(f'.{path.name}.{os.getpid()}.new')
    temp.write_text(text)
    os.replace(temp, path)


def save_json(path, value):
    save(path, json.dumps(value) + '\n')


def journal(root, text):
    """One line per step of the watch, oldest first: what the tests and a
    reader follow to see the order things happened in."""
    fd = os.open(wdir(root) / 'journal', os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, f'{now_iso()} {text}\n'.encode())
    finally:
        os.close(fd)


class Locked:
    """An exclusive flock, held for the with-block; the kernel drops it when
    its holder dies, however it dies."""

    def __init__(self, path):
        self.path = path

    def __enter__(self):
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_):
        os.close(self.fd)


# --- The queue and the wake lines -------------------------------------------

def wake_line(item):
    """The short machine-readable reason a queue item wakes firstmate with:
    `review: T-134 APPROVE 4ea1ec2`, `card: D-51 answered A`,
    `merge: D-51 failed`. A writer that knows its line sends it; the
    board's items carry their decision, and the line is read from that."""
    line = item.get('line')
    if isinstance(line, str) and line.strip():
        return ' '.join(line.split())
    ident = item.get('id', '?')
    decision = item.get('decision') if isinstance(item.get('decision'), dict) else {}
    reason = item.get('reason')
    if reason == 'answered':
        return f"card: {ident} answered {decision.get('chosen') or '?'}"
    if reason == 'merge_settled':
        return f"merge: {ident} {decision.get('merge') or 'settled'}"
    return f"{reason or 'wake'}: {ident}"


def _queue_from(root, offset):
    """The complete items after `offset` and where they end."""
    queue = Path(root) / life.WAKE_QUEUE
    try:
        with open(queue, 'rb') as f:
            size = os.fstat(f.fileno()).st_size
            if offset > size:
                offset = 0        # the queue was replaced; read it again
            f.seek(offset)
            data = f.read()
    except FileNotFoundError:
        return [], 0
    end = data.rfind(b'\n') + 1
    items = []
    for raw in data[:end].splitlines():
        try:
            item = json.loads(raw)
        except ValueError:
            continue
        if isinstance(item, dict):
            items.append(item)
    return items, offset + end


def _cursor(root):
    try:
        return int((wdir(root) / 'cursor').read_text().strip())
    except (OSError, ValueError):
        return None


def delivered(root, item):
    """Whether firstmate was already given this item: the one record every
    reader of the queue keeps (bin/lib/fm_lifeline.py acknowledged)."""
    ident = item.get('id')
    if not isinstance(ident, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', ident):
        return False
    return life.is_acknowledged(root, ident, item.get('woken'))


def take(root):
    """Every wake pushed since the cursor and not yet delivered, the cursor
    moved past them under a lock: each is taken once, by whichever taker
    comes first, and acknowledged as it is taken - the same record
    `fm-session.sh ack` writes - so `fm-session.sh wait` and `status` never
    hand it to firstmate a second time. The first time the watch runs, the
    cursor starts at the end of the queue: what was pushed before is
    reported by `fm-session.sh status`, not replayed as a wake."""
    with Locked(wdir(root) / 'cursor.lock'):
        offset = _cursor(root)
        if offset is None:
            queue = Path(root) / life.WAKE_QUEUE
            save(wdir(root) / 'cursor', str(queue.stat().st_size if queue.exists() else 0))
            return []
        items, end = _queue_from(root, offset)
        items = [item for item in items if not delivered(root, item)]
        for item in items:
            if isinstance(item.get('id'), str) and re.fullmatch(r'[A-Za-z0-9_-]+', item['id']):
                life.acknowledge(root, item['id'], item.get('woken') or 0)
        if end != offset:
            save(wdir(root) / 'cursor', str(end))
        return items


def waiting(root):
    """How many wakes wait for firstmate: in the queue and not delivered by
    the one record (the latest item of each id, as `fm-session.sh status`
    reads it), or taken by a cycle and written for an arm, and unclaimed."""
    latest = {}
    for item in _queue_from(root, 0)[0]:
        if isinstance(item.get('id'), str) and re.fullmatch(r'[A-Za-z0-9_-]+', item['id']):
            latest[item['id']] = item
    queued = sum(1 for item in latest.values() if not delivered(root, item))
    written = 0
    for path in (wdir(root) / 'wake').glob('*.json') if (wdir(root) / 'wake').is_dir() else []:
        written += len(read_json(path).get('lines') or [])
    return queued + written


# --- The cycle ----------------------------------------------------------------

def cycle_live(root):
    """Whether a cycle holds the watch: its lock is held. The kernel's answer,
    released the moment the holder dies; never a pid or a file's age."""
    fd = os.open(wdir(root) / 'cycle.lock', os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        if error.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
            return True
        raise
    finally:
        os.close(fd)
    return False


def start_cycle(root, owner):
    """Start a cycle owned by `owner` through the lifeline and wait until it
    holds the watch. The caller holds arm.lock, so no one else starts one."""
    argv = ['bash', str(BIN / 'fm-watch.sh'), str(root)]
    log = open(wdir(root) / 'cycle.log', 'ab')
    try:
        child = life.start(argv, owner=owner, direct=True, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=log)
    finally:
        log.close()
    # the cycle is reaped when it ends, so a long-lived arm keeps no zombie
    threading.Thread(target=child.wait, daemon=True).start()
    ready, _, _ = select.select([child.stdout], [], [], 30)
    said = child.stdout.readline() if ready else b''
    child.stdout.close()
    if not said.startswith(b'ready '):
        raise RuntimeError('the watcher did not take the watch; see state/watch/cycle.log')
    return int(said.split()[1])


def ensure(root, owner):
    """Single-flight: attach to the live cycle, or start one. Returns the
    live cycle's record."""
    with Locked(wdir(root) / 'arm.lock'):
        if cycle_live(root):
            info = read_json(wdir(root) / 'owner.json')
            journal(root, f"attach {info.get('gen')} by {os.getpid()}")
            return info
        before = read_json(wdir(root) / 'owner.json')
        if before and not before.get('ended'):
            # it never said it ended, and the kernel says it no longer
            # holds the watch: it died, and is superseded
            journal(root, f"supersede {before.get('gen')}: its watcher is gone")
        start_cycle(root, owner)
        return read_json(wdir(root) / 'owner.json')


def cycle(root):
    """One watcher cycle; what bin/fm-watch.sh runs, started only by
    start_cycle through the lifeline."""
    root = Path(root).resolve()
    owner = life.hold()
    lock = os.open(wdir(root) / 'cycle.lock', os.O_RDWR | os.O_CREAT, 0o644)
    # the predecessor hands it over as it closes; this blocks until then
    fcntl.flock(lock, fcntl.LOCK_EX)
    gen_path = wdir(root) / 'generation'
    try:
        gen = int(gen_path.read_text().strip()) + 1
    except (OSError, ValueError):
        gen = 1
    save(gen_path, str(gen))

    def leave(signum, _frame):
        raise SystemExit(128 + signum)
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, leave)
    bell = life.Doorbell(root)
    record = dict(gen=gen, pid=os.getpid(), owner=owner, bell=bell.path, started=now_iso())
    try:
        save_json(wdir(root) / 'owner.json', record)
        journal(root, f'cycle {gen} live')
        sys.stdout.write(f'ready {gen}\n')
        sys.stdout.flush()
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, 1)
        os.close(devnull)
        items = take(root)
        while not items:
            bell.wait(None)
            items = take(root)
        lines = [wake_line(item) for item in items]
        # the successor holds the watch before this wake is let out, so a
        # wake pushed while firstmate handles this one is not missed
        with Locked(wdir(root) / 'arm.lock'):
            os.close(lock)
            lock = None
            try:
                start_cycle(root, owner)
            except (life.OwnerGone, RuntimeError, OSError, ValueError) as error:
                journal(root, f'cycle {gen} left no successor: {error}')
        (wdir(root) / 'wake').mkdir(exist_ok=True)
        save_json(wdir(root) / 'wake' / f'{gen}.json', dict(gen=gen, lines=lines, ts=now_iso()))
        journal(root, f'wake {gen} written: ' + '; '.join(lines))
        life.ring(root, f'watch {gen}')
    finally:
        bell.close()
        if lock is not None:
            # ended without handing on (its owner is gone, or it was
            # stopped): said, so the board counts a gap from here
            if read_json(wdir(root) / 'owner.json').get('gen') == gen:
                save_json(wdir(root) / 'owner.json', dict(record, ended=now_iso()))
            journal(root, f'cycle {gen} ended')
    return 0


# --- The arm ------------------------------------------------------------------

def claim(root):
    """Every wake a cycle wrote and no arm has claimed yet, each to exactly
    one claimant: a rename succeeds once."""
    base = wdir(root) / 'wake'
    if not base.is_dir():
        return []
    lines, gens = [], []
    def gen_of(path):
        try:
            return int(path.stem)
        except ValueError:
            return 0
    for path in sorted(base.glob('*.json'), key=gen_of):
        mine = path.with_name(f'{path.stem}.claimed-{os.getpid()}')
        try:
            os.rename(path, mine)
        except FileNotFoundError:
            continue
        record = read_json(mine)
        try:
            mine.unlink()
        except OSError:
            pass
        lines += [str(x) for x in record.get('lines') or []]
        gens.append(record.get('gen'))
    if lines:
        save_json(wdir(root) / 'last-wake.json',
                  dict(ts=now_iso(), reason='; '.join(lines), lines=lines, gen=gens[-1]))
        journal(root, f'claimed {",".join(str(g) for g in gens)} by {os.getpid()}')
    return lines


def pending(root):
    """What waits for firstmate right now, delivered once: every unclaimed
    wake, and every item past the cursor. What a turn start and a harness
    that cannot be woken idle read."""
    lines = claim(root)
    lines += [wake_line(item) for item in take(root)]
    return lines


def arm(root, owner, max_wait=None):
    """Park until a wake is claimed (its lines), the wait ends ([]), or the
    owner exits (None). Blocks on this arm's doorbell, the owner's exit
    and the live cycle's exit together; the kernel reports each."""
    root = Path(root).resolve()
    try:
        owner_exit = life.ProcessExit(owner)
    except life.OwnerGone:
        return None
    deadline = None if not max_wait else time.monotonic() + max_wait
    try:
        with life.Doorbell(root) as bell:
            while True:
                lines = claim(root)
                if lines:
                    return lines
                info = ensure(root, owner)
                try:
                    cycle_exit = life.ProcessExit(int(info.get('pid') or 0))
                except (life.OwnerGone, ValueError, OSError):
                    continue            # it ended since; its wake may be waiting
                try:
                    # a wake written between the look above and the watch
                    lines = claim(root)
                    if lines:
                        return lines
                    left = None if deadline is None else deadline - time.monotonic()
                    if left is not None and left <= 0:
                        return []
                    ready, _, _ = select.select([bell.fd, owner_exit.fileno(), cycle_exit.fileno()], [], [], left)
                    if owner_exit.fileno() in ready and owner_exit.gone():
                        return None
                    if bell.fd in ready:
                        bell.wait(0)
                finally:
                    cycle_exit.close()
    finally:
        owner_exit.close()


# --- Who arms ---------------------------------------------------------------

def standing_down(root, cwd=None):
    """Why this is not the primary's turn to arm, or None. Crew rounds and
    their worktrees never arm or wake; neither does anything while the
    captain is away (state/away; the away mode itself is a later task)."""
    if os.environ.get('FM_IN_ROUND'):
        return 'a crew round (FM_IN_ROUND)'
    root = Path(root).resolve()
    for place in {Path(cwd).resolve() if cwd else Path.cwd().resolve(), root}:
        parts = place.parts
        for i in range(len(parts) - 1):
            if parts[i] == 'state' and parts[i + 1] in ('worktrees', 'projects'):
                return 'a crew worktree'
    if (root / '.git').is_file():
        return 'a git worktree, not the primary checkout'
    if (root / 'state/away').exists():
        return 'the captain is away'
    return None


def inflight(root):
    """What firstmate waits on: crew aboard (a worker or reviewer whose
    last event is not agent_finished) and cards the captain has not
    answered (state/pending)."""
    aboard = {}
    try:
        with open(Path(root) / 'state/events.jsonl', 'rb') as f:
            for raw in f:
                try:
                    event = json.loads(raw)
                except ValueError:
                    continue
                if not isinstance(event, dict) or not event.get('task'):
                    continue
                actor = str(event.get('actor') or '')
                data = event.get('data') if isinstance(event.get('data'), dict) else {}
                if data.get('role') not in ('worker', 'reviewer') and not re.match(r'(worker|reviewer)-', actor):
                    continue
                aboard[actor] = event.get('type') != 'agent_finished'
    except OSError:
        pass
    cards = sorted(p.stem for p in (Path(root) / 'state/pending').glob('*.json'))
    return sorted(actor for actor, on in aboard.items() if on), cards


def status(root):
    root = Path(root).resolve()
    info = read_json(wdir(root) / 'owner.json')
    live = cycle_live(root)
    crew, cards = inflight(root)
    return dict(watched=live, gen=info.get('gen'), owner=info.get('owner') if live else None,
                since=info.get('started') if live else None, ended=None if live else info.get('ended'),
                last_wake=read_json(wdir(root) / 'last-wake.json') or None, waiting=waiting(root),
                crew=crew, cards=cards, standing_down=standing_down(root))


# --- What each harness is told ------------------------------------------------

def wake_text(lines):
    shown = lines[:MAX_LINES]
    more = len(lines) - len(shown)
    return ('firstmate wake:\n' + '\n'.join(shown) + (f'\n(and {more} more)' if more else '')
            + '\nHandle each of these, then end the turn; the watch is already held for the next one.')


def park_text():
    return ('Work is in flight and nothing is watching for it, so ending this turn now would leave you blind. '
            f'Run `bin/fm-watch-arm.sh --max-wait {PARK_SECS}` in the foreground and handle what it prints.')


def payload():
    try:
        value = json.loads(sys.stdin.read() or '{}')
        return value if isinstance(value, dict) else {}
    except (ValueError, OSError):
        return {}


def hook(root, harness):
    """The harness's Stop hook that parks (Claude Code's asyncRewake)."""
    said = payload()
    if standing_down(root, said.get('cwd')):
        return 0
    if harness != 'claude':
        print(f'fm-watch-arm: --hook {harness}: only claude parks at a stop; '
              f'{harness} uses fm-turnend-guard.sh --hook {harness}', file=sys.stderr)
        return 64
    owner = life.session_owner()
    lines = arm(root, owner, CLAUDE_TIMEOUT - 60)
    if lines is None:
        return 0                # its claude is gone: exit, and take nothing
    if not lines:
        crew, cards = inflight(root)
        if not (crew or cards):
            return 0
        print('firstmate: nothing needed you for a day, and work is still in flight; '
              'end this turn and the hook parks again.', file=sys.stderr)
        return 2
    print(wake_text(lines), file=sys.stderr)
    return 2


def turn_start(root, harness):
    """UserPromptSubmit: what waits is added to the turn's context."""
    said = payload()
    if standing_down(root, said.get('cwd')):
        return 0
    lines = pending(root)
    if lines:
        print(json.dumps(dict(hookSpecificOutput=dict(hookEventName='UserPromptSubmit',
                                                      additionalContext=wake_text(lines)))))
    return 0


def guard(root, harness):
    """The turn-end guard. Claude Code: exit 2 refuses the stop, with the
    reason on stderr. Codex: {"decision":"block","reason":...}. Cursor:
    {"followup_message":...}. With no harness: print the status and exit
    2 when a turn ending now would be blind."""
    said = payload() if harness else {}
    if standing_down(root, said.get('cwd')):
        return 0
    if harness in ('codex', 'cursor'):
        if harness == 'cursor' and said.get('status', 'completed') != 'completed':
            return 0
        lines = pending(root)
        text = wake_text(lines) if lines else None
        if not text and not said.get('stop_hook_active'):
            crew, cards = inflight(root)
            text = park_text() if crew or cards else None
        if text:
            answer = dict(decision='block', reason=text) if harness == 'codex' else dict(followup_message=text)
            print(json.dumps(answer))
        return 0
    if said.get('stop_hook_active'):
        return 0
    crew, cards = inflight(root)
    if not (crew or cards):
        return 0
    if not cycle_live(root):
        try:
            ensure(root, life.session_owner())
        except (life.OwnerGone, RuntimeError, OSError, ValueError) as error:
            print(f'fm-turnend-guard: could not start a watcher: {error}', file=sys.stderr)
    if cycle_live(root):
        return 0
    print(f'{len(crew)} round(s) and {len(cards)} card(s) in flight. ' + park_text(), file=sys.stderr)
    return 2


# --- The fallback: a pane that follows ------------------------------------------

def notify(text):
    """A desktop notification: FM_NOTIFY (a command, given the text as its
    last argument) when set, else osascript on macOS, notify-send on Linux."""
    given = os.environ.get('FM_NOTIFY', '')
    if given:
        argv = shlex.split(given) + [text]
    elif sys.platform == 'darwin':
        argv = ['osascript', '-e', f'display notification {json.dumps(text)} with title "firstmate"']
    else:
        argv = ['notify-send', 'firstmate', text]
    try:
        subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=15)
    except (OSError, subprocess.SubprocessError):
        pass


def follow(root, owner, count=0):
    """For a harness with no hooks: arm, print and notify, for ever (or
    `count` wakes), until the owner exits."""
    done = 0
    while True:
        lines = arm(root, owner)
        if lines is None:
            return 0
        text = '\n'.join(lines)
        print(text, flush=True)
        notify(text)
        done += 1
        if count and done >= count:
            return 0


# --- The command line -----------------------------------------------------------

USAGE = '''usage:
  fm-watch-arm.sh [--repo DIR] [--max-wait S]    park until a wake; print it
  fm-watch-arm.sh --ensure | --status | --pending
  fm-watch-arm.sh --follow [--background] [--count N]
  fm-watch-arm.sh --hook claude | --turn-start claude|codex
  fm-turnend-guard.sh [--hook claude|codex|cursor]'''


def options(args, flags, values):
    """A tiny option reader: every flag is refused without its value."""
    got = {}
    rest = list(args)
    while rest:
        flag = rest.pop(0)
        if flag in flags:
            got[flag] = True
        elif flag in values:
            if not rest or rest[0].startswith('--'):
                raise ValueError(f'{flag} needs a value')
            got[flag] = rest.pop(0)
        else:
            raise ValueError(f'unknown argument {flag}')
    return got


def root_of(got):
    return Path(got.get('--repo') or os.environ.get('FM_ROOT') or BIN.parent).resolve()


def main(argv):
    if not argv:
        print(USAGE, file=sys.stderr)
        return 64
    mode, args = argv[0], argv[1:]
    try:
        if mode == 'cycle':
            if len(args) != 1:
                print(USAGE, file=sys.stderr)
                return 64
            return cycle(args[0])
        if mode == 'arm':
            got = options(args, {'--ensure', '--status', '--pending', '--follow', '--background'},
                          {'--repo', '--max-wait', '--count', '--hook', '--turn-start'})
            root = root_of(got)
            if '--hook' in got:
                return hook(root, got['--hook'])
            if '--turn-start' in got:
                return turn_start(root, got['--turn-start'])
            if '--status' in got:
                print(json.dumps(status(root)))
                return 0
            if '--pending' in got:
                for line in pending(root):
                    print(line)
                return 0
            why = standing_down(root)
            if why:
                print(f'fm-watch-arm: standing down: {why}', file=sys.stderr)
                return 0
            if '--ensure' in got:
                ensure(root, life.session_owner())
                print(json.dumps(status(root)))
                return 0
            if '--follow' in got:
                count = int(got.get('--count') or 0)
                if '--background' in got:
                    argv = ['bash', str(BIN / 'fm-watch-arm.sh'), '--follow', '--repo', str(root),
                            *(['--count', str(count)] if count else [])]
                    log = open(wdir(root) / 'follow.log', 'ab')
                    try:
                        child = life.start(argv, owner=life.session_owner(), stdin=subprocess.DEVNULL,
                                           stdout=log, stderr=log)
                    finally:
                        log.close()
                    print(child.pid)
                    return 0
                return follow(root, life.session_owner(), count)
            wait = float(got['--max-wait']) if got.get('--max-wait') else None
            lines = arm(root, life.session_owner(), wait)
            if lines is None:
                return 0
            if not lines:
                print('fm-watch-arm: nothing needed firstmate before the wait ran out', file=sys.stderr)
                return 1
            print('\n'.join(lines))
            return 0
        if mode == 'guard':
            got = options(args, set(), {'--repo', '--hook'})
            root = root_of(got)
            harness = got.get('--hook')
            if harness and harness not in HARNESSES:
                raise ValueError(f'no such harness: {harness}')
            if not harness:
                print(json.dumps(status(root)))
            return guard(root, harness)
    except ValueError as error:
        print(f'fm-watch: {error}', file=sys.stderr)
        return 64
    except (RuntimeError, OSError) as error:
        print(f'fm-watch: {error}', file=sys.stderr)
        return 70
    print(USAGE, file=sys.stderr)
    return 64


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
