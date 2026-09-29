#!/usr/bin/env bash
# T-137: firstmate is woken for every event that needs it, whatever harness
# it runs in. The writer pushes the wake (bin/lib/fm_lifeline.py push); a
# single-flight watch (bin/fm-watch-arm.sh, bin/fm-watch.sh,
# bin/lib/fm_watch.py) takes it once and hands it to the harness's hook.
#
# Each harness is a stub here, answering as that harness's hook
# documentation says it does: its payload on standard input, its answer
# on stdout or stderr and in the exit code (docs/verification/supervision.md
# names the source of each shape).
#
# Every process this suite starts ends with it: each watch is owned by a
# stand-in session the test starts and ends, and the lifeline ends what that
# session owned (bin/ci.sh turns a survivor red, T-151).
set -uo pipefail
exec < /dev/null
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

python3 - "$ROOT" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
root = Path(sys.argv[1])
ARM, GUARD, FM = root / 'bin/fm-watch-arm.sh', root / 'bin/fm-turnend-guard.sh', root / 'bin/fm.sh'
LIFELINE, EMIT = root / 'bin/lib/fm_lifeline.py', root / 'bin/fm-emit.sh'
spec = importlib.util.spec_from_file_location('fm_watch', root / 'bin/lib/fm_watch.py')
W = importlib.util.module_from_spec(spec); spec.loader.exec_module(W)
spec = importlib.util.spec_from_file_location('fm_herdr', root / 'bin/fm-herdr.py')
H = importlib.util.module_from_spec(spec); spec.loader.exec_module(H)
HOOKS = root / 'bin/lib/fm_hooks.py'


def until(check, within=15):
    """Test-side only: wait, bounded, for what the code under test does."""
    deadline = time.monotonic() + within
    while time.monotonic() < deadline:
        if check():
            return True
        time.sleep(.05)
    return bool(check())


def stop(p):
    if p.poll() is None:
        p.kill()
    p.wait()
    # every pipe the test opened is closed with it
    for f in (p.stdin, p.stdout, p.stderr):
        if f is not None and not f.closed:
            f.close()


def gone(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return False


class Watch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve() / 'repo'
        (self.root / 'state').mkdir(parents=True)
        # after every owner below is ended, its cycles end with it
        self.addCleanup(self.settle)
        self.owner = self.stand_in()

    def settle(self):
        for place in [self.root, *getattr(self, 'others', [])]:
            if (place / 'state/watch').is_dir():
                until(lambda: not W.cycle_live(place))
                # the lifeline's own helper that saw the cycle out ends a
                # moment after the cycle's lock is released
                time.sleep(.3)

    def stand_in(self):
        """A stand-in harness session: what owns the watch and the hooks."""
        p = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(300)'], stdin=subprocess.DEVNULL)
        self.addCleanup(stop, p)
        return p

    def env(self, owner=None, **extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        env.update(FM_SESSION_PID=str(owner if isinstance(owner, int) else (owner or self.owner).pid),
                   FM_LIFELINE_GRACE='1')
        env.update(extra)
        return env

    def run_(self, script, *args, stdin='', owner=None, where=None, **extra):
        where = where or self.root
        return subprocess.run(['bash', str(script), '--repo', str(where), *args], input=stdin,
                              capture_output=True, text=True, env=self.env(owner, **extra), cwd=where, timeout=60)

    def park(self, *args, payload=None, owner=None, where=None, **extra):
        """An arm left running, as a harness leaves its hook."""
        where = where or self.root
        # the payload is a file the hook reads to its end, as a harness's
        # pipe is: no stdin pipe is left for communicate() to flush
        given = Path(tempfile.mkstemp(dir=self.tmp.name, suffix='.json')[1])
        given.write_text(json.dumps(payload) if payload is not None else '')
        with given.open('rb') as said:
            p = subprocess.Popen(['bash', str(ARM), '--repo', str(where), *args],
                                 stdin=said, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, env=self.env(owner, **extra), cwd=where)
        self.addCleanup(stop, p)
        return p

    def push(self, ident, reason, line, where=None):
        subprocess.run([sys.executable, str(LIFELINE), 'push', str(where or self.root), ident, reason, line],
                       check=True, capture_output=True, stdin=subprocess.DEVNULL)

    def board_push(self, ident, reason, decision):
        """What board/server.ts writes for a card answered or a merge settled."""
        queue = self.root / 'state/session/wake.jsonl'
        queue.parent.mkdir(parents=True, exist_ok=True)
        with queue.open('a') as f:
            f.write(json.dumps(dict(id=ident, reason=reason, decision=decision, woken=time.time())) + '\n')
        subprocess.run([sys.executable, str(LIFELINE), 'ring', str(self.root), ident],
                       check=True, capture_output=True, stdin=subprocess.DEVNULL)

    def journal(self):
        path = self.root / 'state/watch/journal'
        return [l.split(' ', 1)[1] for l in path.read_text().splitlines()] if path.exists() else []

    def generation(self):
        return int((self.root / 'state/watch/generation').read_text())

    def aboard(self, actor='worker-a-t1-r1', type_='dispatched'):
        with (self.root / 'state/events.jsonl').open('a') as f:
            f.write(json.dumps(dict(ts='2026-09-29T10:00:00Z', actor=actor, type=type_, task='T-1',
                                    data={'role': 'worker'})) + '\n')


class Wakes(Watch):
    def test_each_kind_wakes_exactly_once_with_its_line(self):
        self.assertEqual(0, self.run_(ARM, '--ensure').returncode)
        self.assertTrue(W.cycle_live(self.root), 'a cycle holds the watch')
        pushed = [('worker-a-t1-r1', 'round_end', 'finished: T-1 worker-a-t1-r1 ok #9'),
                  ('worker-b-t1-r2', 'round_end', 'failed: T-1 worker-b-t1-r2 exit 1'),
                  ('reviewer-c-t1-r1', 'verdict', 'review: T-1 APPROVE 4ea1ec2 #9'),
                  ('reviewer-d-t1-r2', 'verdict', 'review: T-1 REJECT 4ea1ec2 #9'),
                  ('worker-e-t1-r3', 'lost', 'lost: T-1 worker-e-t1-r3'),
                  ('gate-T1-1', 'gate', 'gate: T-1 failed gate 6 #9')]
        for item in pushed:
            self.push(*item)
        # the board's own items carry their decision, and the line is read from it
        self.board_push('D-51', 'answered', {'chosen': 'A'})
        self.board_push('D-52', 'merge_settled', {'merge': 'merged'})
        self.board_push('D-53', 'merge_settled', {'merge': 'failed'})
        want = [line for _, _, line in pushed] + ['card: D-51 answered A', 'merge: D-52 merged', 'merge: D-53 failed']
        seen = []
        for _ in want:
            woke = self.run_(ARM, '--max-wait', '10')
            self.assertEqual(0, woke.returncode, woke.stderr)
            seen += woke.stdout.splitlines()
            if len(seen) >= len(want):
                break
        self.assertEqual(sorted(want), sorted(seen), 'every kind wakes, each exactly once')
        again = self.run_(ARM, '--max-wait', '1')
        self.assertEqual((1, ''), (again.returncode, again.stdout), 'and none of them a second time')

    def test_progress_is_absorbed(self):
        self.run_(ARM, '--ensure')
        for n in (1, 2):
            subprocess.run(['bash', str(EMIT), '--actor', 'worker-a-t1-r1', '--type', 'crew_status', '--task', 'T-1',
                            '--data', json.dumps({'progress': {'done': n, 'total': 3}}), '--en', 'working', '--tw', '工作中'],
                           env=dict(self.env(), FM_ROOT=str(self.root)), check=True, capture_output=True)
        self.push('worker-a-t1-r1', 'round_end', 'finished: T-1 worker-a-t1-r1 ok')
        woke = self.run_(ARM, '--max-wait', '10')
        self.assertEqual('finished: T-1 worker-a-t1-r1 ok', woke.stdout.strip(),
                         "a round's progress never wakes firstmate; its end does")


class OneRecord(Watch):
    """Every reader of the wake queue counts delivery by one record, so a
    wake the watch handed to the hook is not handed over again by
    `fm-session.sh wait` or listed by its status, and the reverse."""

    def session_wait(self):
        return subprocess.run([sys.executable, str(root / 'bin/fm-herdr.py'), 'session', 'wait', str(self.root), 'all', '1'],
                              capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=30)

    def test_a_wake_the_watch_delivered_is_not_delivered_again_by_the_session(self):
        self.run_(ARM, '--pending')          # the watch starts from here
        self.push('worker-a-t1-r1', 'round_end', 'finished: T-1 worker-a-t1-r1 ok')
        # the control: before the watch delivers it, the session sees it
        self.assertIn('worker-a-t1-r1 finished: T-1 worker-a-t1-r1 ok', H.pending_summary(H.unacknowledged(self.root)))
        self.assertEqual(1, W.waiting(self.root))
        got = self.run_(ARM, '--pending')
        self.assertEqual('finished: T-1 worker-a-t1-r1 ok', got.stdout.strip(), 'the watch delivers it')
        self.assertEqual('fm-session: no unacknowledged captain decisions', H.pending_summary(H.unacknowledged(self.root)),
                         'and the session no longer lists it')
        waited = self.session_wait()
        self.assertEqual((1, []), (waited.returncode, json.loads(waited.stdout)), 'nor does fm-session.sh wait return for it')
        self.assertEqual(0, W.waiting(self.root), 'and nothing is counted as waiting')

    def test_a_wake_the_session_acknowledged_is_not_delivered_again_by_the_watch(self):
        self.run_(ARM, '--pending')
        self.push('reviewer-c-t1-r1', 'verdict', 'review: T-1 APPROVE 4ea1ec2')
        self.push('worker-a-t1-r2', 'round_end', 'finished: T-1 worker-a-t1-r2 ok')
        waited = self.session_wait()
        self.assertEqual(0, waited.returncode, 'the session is given both')
        H.acknowledge(self.root, 'reviewer-c-t1-r1')
        got = self.run_(ARM, '--pending')
        self.assertEqual('finished: T-1 worker-a-t1-r2 ok', got.stdout.strip(),
                         'the watch hands over only what was not acknowledged')


class SingleFlight(Watch):
    def test_two_arms_attach_to_one_watcher(self):
        a, b = self.park('--max-wait', '30'), self.park('--max-wait', '30')
        self.assertTrue(until(lambda: 'cycle 1 live' in self.journal()
                              and any(l.startswith('attach 1 by ') for l in self.journal())))
        self.assertEqual(1, self.generation(), 'two arms, one watcher')
        self.assertEqual([None, None], [a.poll(), b.poll()], 'both parked')
        self.push('worker-a-t1-r1', 'round_end', 'finished: T-1 worker-a-t1-r1 ok')
        self.assertTrue(until(lambda: a.poll() is not None or b.poll() is not None))
        time.sleep(.5)
        done = [p for p in (a, b) if p.poll() is not None]
        self.assertEqual(1, len(done), 'the wake goes to exactly one arm')
        self.assertEqual('finished: T-1 worker-a-t1-r1 ok', done[0].stdout.read().strip())

    def test_the_successor_holds_the_watch_before_the_wake_is_out(self):
        arm = self.park('--max-wait', '30')
        self.assertTrue(until(lambda: 'cycle 1 live' in self.journal()))
        self.push('reviewer-c-t1-r1', 'verdict', 'review: T-1 APPROVE 4ea1ec2')
        out, _ = arm.communicate(timeout=20)
        self.assertEqual('review: T-1 APPROVE 4ea1ec2', out.strip())
        steps = self.journal()
        self.assertLess(steps.index('cycle 2 live'), steps.index('wake 1 written: review: T-1 APPROVE 4ea1ec2'),
                        'the successor holds the watch before the wake is written')
        self.assertTrue(any(s.startswith('claimed 1 by ') for s in steps))
        self.assertTrue(W.cycle_live(self.root), 'and it still holds it while firstmate handles the wake')
        self.assertEqual(2, json.loads((self.root / 'state/watch/owner.json').read_text())['gen'])

    def test_a_dead_watcher_is_superseded(self):
        self.run_(ARM, '--ensure')
        self.run_(ARM, '--ensure')
        self.assertEqual(1, self.generation(), 'a live watcher is attached to, not replaced')
        self.assertIn('attach 1 by', ' '.join(self.journal()))
        pid = json.loads((self.root / 'state/watch/owner.json').read_text())['pid']
        os.kill(pid, signal.SIGKILL)
        self.assertTrue(until(lambda: not W.cycle_live(self.root)), 'the kernel releases a dead watcher\'s lock')
        self.run_(ARM, '--ensure')
        self.assertEqual(2, self.generation())
        self.assertIn('supersede 1: its watcher is gone', self.journal())
        self.assertTrue(W.cycle_live(self.root))

    def test_an_owner_that_dies_takes_its_park_with_it_and_steals_nothing(self):
        """Measured on Claude Code 2.1.284: a plain blocking hook, orphaned when
        claude was SIGKILLed, went on reading and stole the next wake."""
        hook = self.park('--hook', 'claude', payload={'hook_event_name': 'Stop', 'stop_hook_active': False})
        self.assertTrue(until(lambda: W.cycle_live(self.root)))
        self.owner.send_signal(signal.SIGKILL); self.owner.wait()
        self.assertEqual(0, hook.wait(timeout=15), 'the hook exits 0 when its owner dies')
        self.assertEqual('', hook.stderr.read(), 'and wakes nothing')
        self.assertTrue(until(lambda: not W.cycle_live(self.root)), 'the watcher goes with its owner')
        self.push('worker-a-t1-r1', 'round_end', 'finished: T-1 worker-a-t1-r1 ok')
        # the next session's arm is the one that is told
        after = self.run_(ARM, '--max-wait', '10', owner=self.stand_in())
        self.assertEqual('finished: T-1 worker-a-t1-r1 ok', after.stdout.strip(), 'nothing took the wake meanwhile')


class Harnesses(Watch):
    STOP = {'session_id': 's-1', 'transcript_path': '/dev/null', 'hook_event_name': 'Stop', 'stop_hook_active': False}

    def test_claude_async_hook_wakes_with_exit_2_and_the_reason_on_stderr(self):
        hook = self.park('--hook', 'claude', payload=dict(self.STOP, cwd=str(self.root)))
        self.assertTrue(until(lambda: W.cycle_live(self.root)))
        self.assertIsNone(hook.poll(), 'it parks while nothing needs firstmate')
        self.push('reviewer-c-t1-r1', 'verdict', 'review: T-1 APPROVE 4ea1ec2')
        out, err = hook.communicate(timeout=20)
        self.assertEqual(2, hook.returncode)
        self.assertEqual(W.wake_text(['review: T-1 APPROVE 4ea1ec2']) + '\n', err)
        self.assertEqual('', out)

    def test_claude_guard_refuses_a_blind_turn_end(self):
        self.aboard()
        dead = subprocess.Popen(['true']); dead.wait()
        # no owner to hand a watcher to: the turn would end blind
        blind = self.run_(GUARD, '--hook', 'claude', stdin=json.dumps(self.STOP), owner=dead.pid)
        self.assertEqual(2, blind.returncode)
        self.assertIn('bin/fm-watch-arm.sh --max-wait', blind.stderr)
        # a stop that is already a hook's continuation is never refused
        again = self.run_(GUARD, '--hook', 'claude', stdin=json.dumps(dict(self.STOP, stop_hook_active=True)), owner=dead.pid)
        self.assertEqual((0, ''), (again.returncode, again.stderr))
        # with an owner, the guard makes sure of a watcher and lets the turn end
        watched = self.run_(GUARD, '--hook', 'claude', stdin=json.dumps(self.STOP))
        self.assertEqual(0, watched.returncode, watched.stderr)
        self.assertTrue(W.cycle_live(self.root))
        # and with nothing in flight, nothing is refused
        self.aboard(type_='agent_finished')
        idle = self.run_(GUARD, '--hook', 'claude', stdin=json.dumps(self.STOP), owner=dead.pid)
        self.assertEqual(0, idle.returncode)

    def test_codex_stop_hook_blocks_with_the_wake_or_the_order_to_park(self):
        self.aboard()
        self.run_(ARM, '--pending')          # the watch starts from here
        self.push('worker-a-t1-r1', 'round_end', 'finished: T-1 worker-a-t1-r1 ok')
        woke = self.run_(GUARD, '--hook', 'codex', stdin=json.dumps(dict(self.STOP, cwd=str(self.root))))
        self.assertEqual({'decision': 'block', 'reason': W.wake_text(['finished: T-1 worker-a-t1-r1 ok'])},
                         json.loads(woke.stdout))
        park = self.run_(GUARD, '--hook', 'codex', stdin=json.dumps(self.STOP))
        self.assertEqual({'decision': 'block', 'reason': W.park_text()}, json.loads(park.stdout),
                         'nothing waits and work is in flight: park on the arm in the foreground')
        loop = self.run_(GUARD, '--hook', 'codex', stdin=json.dumps(dict(self.STOP, stop_hook_active=True)))
        self.assertEqual((0, ''), (loop.returncode, loop.stdout), "a hook's own continuation may end")
        self.aboard(type_='agent_finished')
        idle = self.run_(GUARD, '--hook', 'codex', stdin=json.dumps(self.STOP))
        self.assertEqual((0, ''), (idle.returncode, idle.stdout), 'nothing in flight, nothing said')

    def test_turn_start_adds_what_waits_to_the_context(self):
        self.run_(ARM, '--pending')
        self.push('reviewer-c-t1-r1', 'verdict', 'review: T-1 REJECT 4ea1ec2')
        for harness in ('codex', 'claude'):
            said = self.run_(ARM, '--turn-start', harness,
                             stdin=json.dumps({'hook_event_name': 'UserPromptSubmit', 'prompt': 'go'}))
            if harness == 'codex':
                self.assertEqual({'hookSpecificOutput': {'hookEventName': 'UserPromptSubmit',
                                                         'additionalContext': W.wake_text(['review: T-1 REJECT 4ea1ec2'])}},
                                 json.loads(said.stdout))
            else:
                self.assertEqual('', said.stdout, 'and it is delivered once')

    def test_cursor_stop_hook_returns_a_followup(self):
        self.aboard()
        self.run_(ARM, '--pending')
        self.push('worker-a-t1-r1', 'round_end', 'failed: T-1 worker-a-t1-r1 exit 1')
        payload = {'conversation_id': 'c-1', 'generation_id': 'g-1', 'hook_event_name': 'stop',
                   'workspace_roots': [str(self.root)], 'loop_count': 0}
        aborted = self.run_(GUARD, '--hook', 'cursor', stdin=json.dumps(dict(payload, status='aborted')))
        self.assertEqual('', aborted.stdout, 'an aborted stop is left alone')
        woke = self.run_(GUARD, '--hook', 'cursor', stdin=json.dumps(dict(payload, status='completed')))
        self.assertEqual({'followup_message': W.wake_text(['failed: T-1 worker-a-t1-r1 exit 1'])}, json.loads(woke.stdout),
                         'and the wake it left waiting goes out on the completed one')


class OnlyThePrimary(Watch):
    def test_a_crew_round_never_arms(self):
        refused = self.run_(ARM, '--ensure', FM_IN_ROUND='1')
        self.assertIn('standing down: a crew round', refused.stderr)
        self.assertFalse(W.cycle_live(self.root))
        self.run_(ARM, '--ensure')
        self.assertTrue(W.cycle_live(self.root), 'the same arm, outside a round, arms')

    def test_a_crew_worktree_never_arms_or_wakes(self):
        tree = Path(self.tmp.name).resolve() / 'fleet/state/worktrees/T-1'
        (tree / 'state').mkdir(parents=True)
        self.others = [tree]
        for where in (self.root, tree):
            self.run_(ARM, '--pending', where=where)
            self.push('worker-a-t1-r1', 'round_end', 'finished: T-1 worker-a-t1-r1 ok', where=where)
        primary = self.run_(GUARD, '--hook', 'codex', stdin=json.dumps({'stop_hook_active': False}))
        self.assertIn('finished: T-1', primary.stdout, 'the primary is woken')
        crew = self.run_(GUARD, '--hook', 'codex', stdin=json.dumps({'stop_hook_active': False}), where=tree)
        self.assertEqual('', crew.stdout, 'a crew worktree is not')
        hook = subprocess.run(['bash', str(ARM), '--repo', str(tree), '--hook', 'claude'], input='{}',
                              capture_output=True, text=True, env=self.env(), cwd=tree, timeout=30)
        self.assertEqual((0, ''), (hook.returncode, hook.stderr), 'and its hook stands down at once')
        self.assertFalse(W.cycle_live(tree))

    def test_a_linked_git_worktree_never_arms(self):
        self.run_(ARM, '--ensure')
        self.assertTrue(W.cycle_live(self.root))
        linked = Path(self.tmp.name).resolve() / 'linked'
        (linked / 'state').mkdir(parents=True)
        (linked / '.git').write_text('gitdir: /elsewhere/.git/worktrees/linked\n')
        self.others = [linked]
        said = self.run_(ARM, '--ensure', where=linked)
        self.assertIn('standing down: a git worktree', said.stderr)
        self.assertFalse(W.cycle_live(linked))

    def test_an_away_captain_stands_the_hooks_down(self):
        (self.root / 'state/away').write_text('')
        hook = self.run_(ARM, '--hook', 'claude', stdin='{}')
        self.assertEqual((0, ''), (hook.returncode, hook.stderr))
        self.assertFalse(W.cycle_live(self.root))
        (self.root / 'state/away').unlink()
        parked = self.park('--hook', 'claude', payload={})
        self.assertTrue(until(lambda: W.cycle_live(self.root)), 'back from away, the hook parks again')
        self.assertIsNone(parked.poll())


class Install(Watch):
    def setUp(self):
        super().setUp()
        (self.root / 'bin').mkdir()
        (self.root / 'bin/fm-watch-arm.sh').write_text('')

    def hooks(self, *args, **extra):
        return subprocess.run(['bash', str(FM), 'hooks', *args, '--repo', str(self.root)], capture_output=True,
                              text=True, env=self.env(**extra), cwd=self.root, timeout=30)

    def test_install_merges_changes_nothing_twice_and_uninstall_restores(self):
        mine = {'permissions': {'allow': ['Bash(ls)']},
                'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'echo mine'}]}]}}
        settings = self.root / '.claude/settings.local.json'
        settings.parent.mkdir()
        settings.write_text(json.dumps(mine))
        first = self.hooks('install', '--harness', 'claude')
        self.assertIn('.claude/settings.local.json: installed Stop, UserPromptSubmit', first.stdout)
        got = json.loads(settings.read_text())
        self.assertEqual(mine['permissions'], got['permissions'])
        self.assertEqual({'type': 'command', 'command': 'echo mine'}, got['hooks']['Stop'][0]['hooks'][0])
        ours = got['hooks']['Stop'][1]['hooks']
        arm = f"{self.root}/bin/fm-watch-arm.sh --hook claude"
        self.assertEqual([{'type': 'command', 'command': f'{self.root}/bin/fm-turnend-guard.sh --hook claude', 'timeout': 30},
                          {'type': 'command', 'command': arm, 'asyncRewake': True, 'timeout': W.CLAUDE_TIMEOUT}], ours)
        # the arm's wait ends before Claude Code's timeout would kill it
        self.assertLess(W.CLAUDE_TIMEOUT - 60, ours[1]['timeout'])
        self.assertEqual(f'{self.root}/bin/fm-watch-arm.sh --turn-start claude',
                         got['hooks']['UserPromptSubmit'][0]['hooks'][0]['command'])
        before = settings.read_bytes()
        second = self.hooks('install', '--harness', 'claude')
        self.assertIn('nothing to change (already installed)', second.stdout)
        self.assertEqual(before, settings.read_bytes())
        self.hooks('uninstall', '--harness', 'claude')
        self.assertEqual(mine, json.loads(settings.read_text()), 'uninstall removes exactly ours')

    def test_codex_and_cursor_get_their_own_local_files(self):
        said = self.hooks('install')
        codex = json.loads((self.root / '.codex/hooks.json').read_text())
        self.assertEqual(f'{self.root}/bin/fm-turnend-guard.sh --hook codex', codex['hooks']['Stop'][0]['hooks'][0]['command'])
        self.assertEqual(f'{self.root}/bin/fm-watch-arm.sh --turn-start codex',
                         codex['hooks']['UserPromptSubmit'][0]['hooks'][0]['command'])
        cursor = json.loads((self.root / '.cursor/hooks.json').read_text())
        self.assertEqual({'version': 1, 'hooks': {'stop': [{'command': f'{self.root}/bin/fm-turnend-guard.sh --hook cursor',
                                                            'timeout': 60, 'loop_limit': 5}]}}, cursor)
        self.assertIn('.cursor/hooks.json: installed stop', said.stdout)
        self.hooks('uninstall')
        for rel in ('.claude', '.codex', '.cursor'):
            self.assertFalse((self.root / rel).exists(), f'{rel}: what install made, uninstall takes away')

    def test_session_start_installs_for_the_harness_it_detects_and_never_in_a_round(self):
        detect = [sys.executable, str(HOOKS), 'install', '--detect', '--repo', str(self.root)]
        subprocess.run(detect, env=self.env(FM_HARNESS='cursor', FM_IN_ROUND='1'), cwd=self.root, capture_output=True)
        self.assertFalse((self.root / '.cursor').exists(), 'a crew round installs nothing')
        subprocess.run(detect, env=self.env(FM_HARNESS='cursor'), cwd=self.root, capture_output=True)
        self.assertTrue((self.root / '.cursor/hooks.json').exists(), 'the primary installs its harness')
        self.assertFalse((self.root / '.claude').exists(), 'and only that one')
        session = (root / 'bin/fm-session.sh').read_text()
        self.assertIn('fm_hooks.py" install --detect --repo "$REPO"', session,
                      'bin/fm-session.sh start runs that install')


class Fallback(Watch):
    def test_a_pane_follows_through_the_lifeline_and_notifies(self):
        told = self.root / 'told'
        stub = self.root / 'notify.sh'
        stub.write_text(f'#!/usr/bin/env bash\nprintf "%s\\n" "${{@: -1}}" >> "{told}"\n'); stub.chmod(0o755)
        pane = self.stand_in()
        keeper = int(self.run_(ARM, '--follow', '--background', owner=pane, FM_NOTIFY=str(stub)).stdout.strip())
        self.assertTrue(until(lambda: W.cycle_live(self.root)))
        self.push('worker-a-t1-r1', 'round_end', 'finished: T-1 worker-a-t1-r1 ok')
        self.assertTrue(until(lambda: told.exists() and 'finished: T-1' in told.read_text()),
                        'the wake is printed and notified')
        self.assertFalse(gone(keeper), 'and it follows on')
        stop(pane)
        self.assertTrue(until(lambda: gone(keeper)), 'it ends with its owner')


class NoPolling(unittest.TestCase):
    PATTERN = re.compile(r'time\.sleep|os\.kill\(|st_mtime|getmtime|\bgh\b|setsid|start_new_session|nohup|disown'
                         r'|kill -0|sleep [0-9]|&\s*$', re.M)

    def code(self, path):
        text = path.read_text()
        # comments and docstrings are prose
        text = re.sub(r'(?s)""".*?"""', '', text)
        return '\n'.join(re.sub(r'(^|\s)#.*$', '', line) for line in text.splitlines())

    def test_nothing_in_the_watch_polls_or_detaches(self):
        for rel in ('bin/lib/fm_watch.py', 'bin/lib/fm_hooks.py', 'bin/fm-watch.sh', 'bin/fm-watch-arm.sh', 'bin/fm-turnend-guard.sh'):
            self.assertEqual([], self.PATTERN.findall(self.code(root / rel)), rel)

    def test_the_sweep_sees_what_it_looks_for(self):
        with tempfile.TemporaryDirectory() as d:
            plant = Path(d) / 'plant.py'
            for bad in ('time.sleep(1)', 'os.kill(pid, 0)', 'p.stat().st_mtime', "run(['gh', 'pr'])", 'sleep 5', 'job &'):
                plant.write_text(bad + '\n')
                self.assertNotEqual([], self.PATTERN.findall(self.code(plant)), bad)
            plant.write_text('# time.sleep(1) in a comment is prose\n')
            self.assertEqual([], self.PATTERN.findall(self.code(plant)))


unittest.main(argv=['watch'], verbosity=2)
PY
[ $? -eq 0 ] || _fails=$((_fails + 1))
finish
