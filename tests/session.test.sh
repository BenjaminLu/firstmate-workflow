#!/usr/bin/env bash
set -euo pipefail
exec < /dev/null
# A live managed worker exports FM_* / HERDR_* into this shell; scrub before
# fixture work so session status/watch binds to the temp tree only.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(sys.argv[1]) / 'tests/lib'))
from session_fixture import *  # tests/lib/session_fixture.py

class Session(SessionFixture):
    def test_role_context_reaches_supported_launchers(self):
        for role in ['worker', 'reviewer', 'firstmate']:
            result = m.role_context(self.repo, role, 'T-035', 'worker-mira-t035-r2', 'payload')
            self.assertIn('explicitly dispatched ' + role, result)
            self.assertIn('payload', result)
            self.assertIn('worker-mira-t035-r2', result)
            self.assertIn((self.repo / 'skills' / role / 'SKILL.md').read_text(), result)
    def test_board_verifies_root_with_relative_nonce(self):
        seen = []
        def request(url, **kw):
            from urllib.parse import urlparse, parse_qs
            seen.append(url)
            name = parse_qs(urlparse(url).query)['path'][0]
            self.assertFalse(Path(name).is_absolute())
            return (self.repo / name).read_bytes()
        with patch.object(m, 'http_get', side_effect=request):
            self.assertTrue(m.board_matches(self.repo, 'http://127.0.0.1:4173'))
        with patch.object(m, 'http_get', return_value=b'wrong root'):
            self.assertFalse(m.board_matches(self.repo, 'http://127.0.0.1:4173'))
        self.assertEqual(1, len(seen))
    def test_board_probe_timeout_budget_and_definite_refusals(self):
        url = 'http://127.0.0.1:4173'
        for failure in (TimeoutError(), m.urllib.error.URLError(TimeoutError())):
            seen = []
            def request(address, **kw):
                seen.append((address, kw.get('timeout')))
                if len(seen) == 1: raise failure
                name = m.urllib.parse.parse_qs(m.urllib.parse.urlparse(address).query)['path'][0]
                return (self.repo / name).read_bytes()
            with patch.object(m, 'http_get', side_effect=request), \
                 patch.object(m.time, 'monotonic', side_effect=[0, 0, 17]):
                self.assertTrue(m.board_matches(self.repo, url))
            self.assertEqual([5, 3], [timeout for _, timeout in seen])
            self.assertEqual(seen[0][0], seen[1][0])
            self.assertEqual([], list((self.repo / 'state/session').glob('probe-*')))
        with patch.object(m, 'http_get', side_effect=TimeoutError()) as get, \
             patch.object(m.time, 'monotonic', side_effect=[0, 0, 17, 20]):
            self.assertFalse(m.board_matches(self.repo, url))
            self.assertEqual([5, 3], [item.kwargs['timeout'] for item in get.call_args_list])
        clock = [0]
        def late_reply(address, **kw):
            clock[0] = 21
            name = m.urllib.parse.parse_qs(m.urllib.parse.urlparse(address).query)['path'][0]
            return (self.repo / name).read_bytes()
        with patch.object(m, 'http_get', side_effect=late_reply) as get, \
             patch.object(m.time, 'monotonic', side_effect=lambda: clock[0]):
            self.assertTrue(m.board_matches(self.repo, url))
            self.assertEqual(1, get.call_count)
        for failure in (ConnectionRefusedError(), ConnectionResetError(), PermissionError(),
                        m.urllib.error.URLError(ConnectionRefusedError()),
                        m.urllib.error.URLError(ConnectionResetError()),
                        m.urllib.error.URLError(PermissionError()), ValueError(),
                        m.urllib.error.HTTPError(url, 503, 'busy', {}, None), b'wrong root'):
            seen = []
            def refused(address, **kw):
                seen.append(address)
                if isinstance(failure, Exception): raise failure
                return failure
            with patch.object(m, 'http_get', side_effect=refused):
                self.assertFalse(m.board_matches(self.repo, url))
            self.assertEqual(1, len(seen))
            self.assertEqual([], list((self.repo / 'state/session').glob('probe-*')))
    def test_board_http_timeout_defaults_and_setup_budget(self):
        url = 'http://127.0.0.1:4173'
        with patch.object(m.urllib.request, 'urlopen') as opened:
            m.http_get(url)
            self.assertEqual(call(url, timeout=2), opened.call_args)
            m.http_get(url, timeout=5)
            self.assertEqual(call(url, timeout=5), opened.call_args)
        with patch.object(m.socket, 'create_connection'), patch.object(m, 'board_matches', return_value=True) as matches:
            m.board_check_port(self.repo, 4173)
            self.assertEqual(call(self.repo.resolve(), url, budget=2), matches.call_args)
            self.assertEqual(1, matches.call_count)
        with patch.object(m, 'http_get', side_effect=TimeoutError()) as get, \
             patch.object(m.time, 'monotonic', side_effect=[0, 0, 2]):
            self.assertFalse(m.board_matches(self.repo, url, budget=2))
            self.assertEqual([2], [item.kwargs['timeout'] for item in get.call_args_list])
    def test_board_busy_matching_code_is_reused_without_starting_child(self):
        url = 'http://127.0.0.1:4173'; seen = []
        code = {'board': 'board-tree', 'i18n': 'i18n-tree', 'dirty': False}
        path = self.repo / 'state/session/board.json'; path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({'code': code, 'owner': 900}))
        def request(address, **kw):
            seen.append((address, kw.get('timeout')))
            if len(seen) == 1: raise TimeoutError()
            if address == url: return b'page'
            name = m.urllib.parse.parse_qs(m.urllib.parse.urlparse(address).query)['path'][0]
            return (self.repo / name).read_bytes()
        with patch.object(m, 'http_get', side_effect=request), patch.object(m.time, 'monotonic', return_value=0), \
             patch.object(m, 'configured_board_port', return_value=4173), patch.object(m, 'board_code_id', return_value=code), \
             patch.object(m, 'board_open', return_value={}), patch.object(m, 'lifeline') as life:
            reply = m.board_start(self.repo)
            self.assertTrue(reply['reused']); self.assertTrue(reply['page_http_verified'])
            self.assertEqual(0, life.return_value.start.call_count)
        self.assertEqual([5, 5, 5], [timeout for _, timeout in seen])
        self.assertEqual(seen[0][0], seen[1][0]); self.assertEqual(url, seen[2][0])
    def push(self, ident, reason='answered', **answer):
        """What the board does when it writes a decision (T-151): one line on
        the wake queue, then a ring of every waiter's doorbell, through the
        same bin/lib/fm_lifeline.py ring the board calls. True when a waiter
        heard it."""
        queue = self.repo / 'state/session/wake.jsonl'; queue.parent.mkdir(parents=True, exist_ok=True)
        with queue.open('a') as out:
            out.write(json.dumps(dict(id=ident, reason=reason, decision=dict(id=ident, **answer), woken=time.time())) + '\n')
        return m.lifeline().ring(self.repo, ident) > 0
    def bells(self):
        return sorted(p.name for p in (self.repo / 'state/session/wake.d').glob('*.fifo'))
    def test_no_watcher_exists_and_the_session_starts_none(self):
        """T-151: the decision watch is deleted; nothing polls state/decisions."""
        for name in ('watch_start', 'watch_stop', 'watch_child'):
            self.assertFalse(hasattr(m, name), name)
        self.assertNotIn('watch-child', (root / 'bin/fm-herdr.py').read_text())
        for action in ('watch', 'stop'):
            gone = self.session_cli(action)
            self.assertEqual(64, gone.returncode, gone.stderr)
            self.assertIn('is gone (T-151)', gone.stderr)
        spawned = []
        with patch.object(m, 'board_start', return_value=dict(stub=True)), \
             patch.object(m.subprocess, 'Popen', side_effect=lambda *a, **k: spawned.append(a)), \
             patch.object(m.os, 'fork', side_effect=AssertionError('forked')):
            import io, contextlib
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(0, m.main(['session', 'start', str(self.repo)]))
        self.assertEqual([], spawned, 'session start starts nothing but the board')
        self.assertFalse((self.repo / 'state/session/wake.fifo').exists(),
                         'no single shared wake FIFO: a FIFO hands each line to one reader')
    def test_wait_blocks_on_the_fifo_until_the_writer_pushes(self):
        """T-151: the wait rings on a doorbell of its own, which the writer
        rings; a timeout gives up."""
        import threading
        started = time.monotonic()
        self.assertEqual([], m.wake_wait(self.repo, 'all', 1))
        self.assertGreaterEqual(time.monotonic() - started, 0.9, 'nothing in the queue: it waits the timeout out')
        pushed = []
        def board():
            time.sleep(.5)
            pushed.append(self.push('D-9', chosen='B', task='T-9', kind='choice', ts='2026-09-29T00:00:00Z'))
        writer = threading.Thread(target=board); writer.start()
        started = time.monotonic()
        items = m.wake_wait(self.repo, 'all', 20)
        writer.join()
        self.assertEqual([True], pushed, 'the writer rang the waiting doorbell')
        self.assertEqual([], self.bells(), 'and the wait took its doorbell with it')
        self.assertLess(time.monotonic() - started, 5)
        self.assertEqual(['D-9'], [item['id'] for item in items])
        self.assertEqual('B', items[0]['chosen'])
        # a wake already queued is found at once, and a wait for another id ignores it
        self.assertEqual(['D-9'], [item['id'] for item in m.wake_wait(self.repo, 'D-9', 1)])
        self.assertEqual([], m.wake_wait(self.repo, 'D-other', 1))
        # the command: exit 0 with the items, 1 on a timeout
        waited = self.session_cli('wait', '--timeout', '1')
        self.assertEqual(0, waited.returncode, waited.stderr)
        self.assertEqual(['D-9'], [item['id'] for item in json.loads(waited.stdout)])
        self.assertEqual(0, self.session_cli('ack', '--decision', 'D-9').returncode)
        waited = self.session_cli('wait', '--timeout', '1')
        self.assertEqual(1, waited.returncode, waited.stderr)
        self.assertEqual([], json.loads(waited.stdout))
        # a merge that settles after the ack wakes firstmate again
        self.push('D-9', reason='merge_settled', chosen='A', task='T-9', kind='merge', merge='merged')
        again = json.loads(self.session_cli('status').stdout)['unacknowledged']
        self.assertEqual([('D-9', 'merged', 'merge_settled')], [(i['id'], i['merge'], i['reason']) for i in again])
    def waiter(self, *args):
        """A real `fm-session.sh wait` in the background, and the doorbell it registered."""
        env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        before = set(self.bells())
        proc = subprocess.Popen(['bash', str(self.repo / 'bin/fm-session.sh'), 'wait', *args, '--repo', str(self.repo)],
                                cwd=self.repo, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: proc.poll() is None and (proc.kill(), proc.wait()))
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and not set(self.bells()) - before:
            time.sleep(.05)
        mine = set(self.bells()) - before
        self.assertEqual(1, len(mine), 'the wait registered a doorbell of its own')
        return proc, mine.pop()
    def test_a_waiter_that_goes_takes_its_doorbell_and_one_killed_outright_is_cleared_by_the_next_ring(self):
        termed, bell = self.waiter('--timeout', '30')
        termed.terminate(); termed.wait(timeout=10)
        self.assertNotIn(bell, self.bells(), 'a TERMed wait removes its doorbell')
        killed, bell = self.waiter('--timeout', '30')
        killed.kill(); killed.wait(timeout=10)
        self.assertIn(bell, self.bells(), 'a SIGKILLed wait cannot remove its own')
        started = time.monotonic()
        self.assertFalse(self.push('D-22', chosen='B'), 'nobody is left to hear it')
        self.assertLess(time.monotonic() - started, 2, 'and the ring does not block on the dead bell')
        self.assertNotIn(bell, self.bells(), 'the ring removes a doorbell nobody holds')
    def test_a_wake_before_the_wait_registers_is_found_with_no_ring(self):
        # queued with nobody waiting: the wait reads the queue once it has
        # registered, so it returns at once, rung or not
        self.push('D-23', chosen='C')
        started = time.monotonic()
        self.assertEqual(['D-23'], [i['id'] for i in m.wake_wait(self.repo, 'D-23', 10)])
        self.assertLess(time.monotonic() - started, 2)
    def test_board_reuse_does_not_spawn_and_wrong_root_is_refused(self):
        with patch.object(m,'board_matches',return_value=True), patch.object(m,'http_get',return_value=b'page'), \
             patch.object(m.shutil,'which',return_value=None), patch.object(m, 'configured_board_port', return_value=4173), \
             patch.object(m.subprocess,'Popen') as spawn:
            reply=m.board_start(self.repo)
            self.assertTrue(reply['reused']); self.assertTrue(reply['page_http_verified'])
            self.assertFalse(reply['opener_invoked']); self.assertFalse(reply['browser_navigation_verified'])
            self.assertFalse(spawn.called)
        with patch.object(m,'board_matches',return_value=False), patch.object(m,'http_get',return_value=b'foreign'), \
             patch.object(m, 'configured_board_port', return_value=4173), \
             patch.object(m.subprocess,'Popen') as spawn:
            with self.assertRaisesRegex(RuntimeError,'unverified root'): m.board_start(self.repo)
            self.assertFalse(spawn.called)
    @patch.object(m, 'board_port_pid', return_value=None)
    def test_board_code_notice_uses_its_own_git_fixture(self, port_pid):
        import contextlib, io
        from unittest.mock import Mock
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary).resolve()
            for folder in ('board', 'i18n'):
                (repo / folder).mkdir()
                (repo / folder / 'fixture').write_text('original')
            def git(*args):
                return subprocess.run(['git', '-C', str(repo), *args], check=True,
                                      capture_output=True, text=True)
            git('init', '-q'); git('config', 'user.name', 'Board fixture')
            git('config', 'user.email', 'board@example.invalid')
            git('add', 'board', 'i18n'); git('commit', '-qm', 'initial')
            with patch.object(m, 'configured_board_port', return_value=4173), \
                 patch.object(m, 'board_open', return_value={}), \
                 patch.object(m, 'board_matches', side_effect=[False, True, True]), \
                 patch.object(m, 'http_get', side_effect=[OSError(), b'page']), \
                 patch.object(m, 'board_listening', return_value=False), \
                 patch.object(m.shutil, 'which', return_value='/fixture/bun'), \
                 patch.object(m, 'lifeline') as life:
                life.return_value.session_owner.return_value = os.getpid()
                life.return_value.start.return_value.poll.return_value = None
                fresh = m.board_start(repo)
                self.assertEqual(m.board_code_id(repo), fresh['code'])
                self.assertEqual(life.return_value.start.call_count, 1)
            original = fresh['code']
            record_path = repo / 'state/session/board.json'
            with patch.object(m, 'configured_board_port', return_value=4173), \
                 patch.object(m, 'board_open', return_value={}), \
                 patch.object(m, 'board_matches', return_value=True), \
                 patch.object(m, 'http_get', return_value=b'page'), \
                 patch.object(m, 'board_drain', return_value=None), \
                 patch.object(m, 'lifeline') as life, patch.object(m.os, 'kill') as kill:
                for _ in range(2):
                    reply = m.board_start(repo)
                    self.assertEqual(original, reply['code'])
                    self.assertNotIn('stale', reply)
                (repo / 'board/fixture').write_text('changed')
                git('add', 'board'); git('commit', '-qm', 'board changed')
                reply = m.board_start(repo)
                self.assertTrue(reply['reused']); self.assertTrue(reply['stale'])
                self.assertEqual(original, reply['code'])
                self.assertEqual({'en', 'zh-TW'}, set(reply['stale_reason']))
                self.assertIn('restart it by hand', reply['stale_reason']['en'])
                self.assertIn('請手動重啟', reply['stale_reason']['zh-TW'])
                self.assertEqual(reply, json.loads(record_path.read_text()))
                out, err = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    self.assertEqual(0, m.main(['board', str(repo)]))
                self.assertEqual(['fm board: ' + reply['stale_reason'][lang] for lang in ('en', 'zh-TW')],
                                 err.getvalue().splitlines())
                git('revert', '--no-edit', 'HEAD')
                reply = m.board_start(repo)
                self.assertNotIn('stale', reply); self.assertNotIn('stale_reason', reply)
                (repo / 'board/fixture').write_text('dirty')
                self.assertNotIn('stale', m.board_start(repo))
                git('checkout', '--', 'board')
                record_path.write_text(json.dumps({'code': dict(original, dirty=True)}))
                self.assertTrue(m.board_start(repo)['stale'])
                for previous in (None, {'root': str(repo)}, {'code': None}):
                    if previous is None: record_path.unlink()
                    else: record_path.write_text(json.dumps(previous))
                    self.assertNotIn('stale', m.board_start(repo))
                self.assertNotIn('stale', m.board_start(self.repo))
                self.assertEqual(life.return_value.start.call_count, 0)
                self.assertEqual(kill.call_count, 0)

    def test_board_drain_replacement_preserves_session_and_waits_for_free_port(self):
        import contextlib, io
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary).resolve()
            for folder in ('board', 'i18n'):
                (repo / folder).mkdir(); (repo / folder / 'fixture').write_text('old')
            def git(*args):
                subprocess.run(['git', '-C', str(repo), *args], check=True, capture_output=True)
            git('init', '-q'); git('config', 'user.name', 'Board fixture')
            git('config', 'user.email', 'board@example.invalid')
            git('add', '.'); git('commit', '-qm', 'old')
            old = m.board_code_id(repo)
            (repo / 'board/fixture').write_text('new')
            git('add', '.'); git('commit', '-qm', 'new')
            current = m.board_code_id(repo)
            path = repo / 'state/session/board.json'; path.parent.mkdir(parents=True)
            for case in ('busy', 'hand', 'replace', 'timeout', 'dead-pid', 'invalid-pid', 'dead-owner', 'http-errors', 'equal', 'dirty', 'unknown', 'unknown-current'):
                with self.subTest(case=case), contextlib.ExitStack() as stack:
                    path.write_text(json.dumps({'code': current if case == 'equal' else None if case == 'unknown' else old, 'owner': 903}))
                    if case == 'dirty': (repo / 'board/fixture').write_text('dirty')
                    def mocked(obj, name, **kw):
                        return stack.enter_context(patch.object(obj, name, **kw))
                    mocked(m, 'configured_board_port', return_value=4173)
                    mocked(m, 'board_matches', return_value=True)
                    mocked(m, 'board_listening', return_value=False)
                    mocked(m, 'board_port_pid', return_value=7373 if case in ('invalid-pid', 'dead-pid') else None)
                    if case == 'unknown-current': mocked(m, 'board_code_id', return_value=None)
                    opened = mocked(m, 'board_open', return_value={})
                    mocked(m.shutil, 'which', return_value='/fixture/bun')
                    life = mocked(m, 'lifeline'); life.return_value.session_owner.return_value = 902
                    life.return_value.start.return_value.poll.return_value = None
                    stopped = []; responses = []; ticks = [0]
                    def kill(pid, sig):
                        if sig == 0 and ((case == 'dead-pid' and pid == 900) or (case == 'dead-owner' and pid == 901)):
                            raise ProcessLookupError()
                        if sig == signal.SIGTERM: stopped.append(pid)
                    killed = mocked(m.os, 'kill', side_effect=kill)
                    def get(url, **kw):
                        if stopped and not life.return_value.start.called and case != 'timeout':
                            responses.append('occupied' if case == 'http-errors' and len(responses) < 3 else 'free')
                            if responses[-1] == 'occupied':
                                raise m.urllib.error.HTTPError(url, 503, 'stopping', {}, None)
                            raise ConnectionRefusedError()
                        return b'page'
                    mocked(m, 'http_get', side_effect=get)
                    def clock():
                        ticks[0] += .1; return ticks[0]
                    mocked(m.time, 'monotonic', side_effect=clock)
                    mocked(m.time, 'sleep')
                    payload = {'status': 409, 'busy': 'merge'} if case == 'busy' else {'session_owned': case != 'hand', 'pid': 900, 'owner': 901}
                    if case == 'invalid-pid': payload['pid'] = True
                    drain = mocked(m, 'board_drain', return_value=payload)
                    result = m.board_start(repo)
                    self.assertEqual(1, opened.call_count)
                    self.assertEqual(result, json.loads(path.read_text()))
                    if case in ('replace', 'dead-owner', 'http-errors'):
                        self.assertFalse(result['reused'])
                        self.assertEqual(current, result['code']); self.assertNotIn('stale', result)
                        self.assertEqual({'from': m.board_short_code(old), 'to': m.board_short_code(current)}, result['replaced'])
                        self.assertEqual([900], stopped)
                        self.assertEqual(1, life.return_value.start.call_count)
                        owner = 902 if case == 'dead-owner' else 901
                        self.assertEqual(owner, life.return_value.start.call_args.kwargs['owner'])
                        self.assertEqual(owner, result['owner'])
                        self.assertTrue(result['page_http_verified'])
                        self.assertEqual(drain.call_count, 1)
                        self.assertEqual(drain.call_args, call('http://127.0.0.1:4173', 4173))
                        if case == 'http-errors': self.assertEqual(['occupied'] * 3 + ['free', 'free'], responses)
                        mocked(m, 'board_start', return_value=result)
                        out, err = io.StringIO(), io.StringIO()
                        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                            self.assertEqual(0, m.main(['board', str(repo)]))
                        change = m.board_short_code(old) + ' -> ' + m.board_short_code(current)
                        self.assertEqual(['fm board: replaced the board: ' + change, 'fm board: 看板已換成新程式：' + change], err.getvalue().splitlines())
                    else:
                        self.assertTrue(result['reused']); self.assertEqual(903, result['owner'])
                        self.assertEqual(life.return_value.start.call_count, 0)
                        if case in ('equal', 'dirty', 'unknown', 'unknown-current'):
                            self.assertEqual(drain.call_count, 0); self.assertNotIn('stale', result)
                        else:
                            self.assertTrue(result['stale'])
                            reason = result['stale_reason']['en']
                            if case == 'busy':
                                self.assertIn('a merge or an answer is in progress', reason)
                                self.assertEqual(1, drain.call_count)
                            else:
                                self.assertEqual(call('http://127.0.0.1:4173', 4173, release=True), drain.call_args)
                                self.assertEqual(2, drain.call_count)
                                self.assertIn('restart it by hand' if case == 'hand' else 'did not stop when asked', reason)
                        if case in ('invalid-pid', 'dead-pid'):
                            for text in result['stale_reason'].values():
                                self.assertIn('kill 7373', text)
                                self.assertNotIn('kill True' if case == 'invalid-pid' else 'kill 900', text)
                        if case == 'timeout': self.assertEqual([900], stopped)
                        else: self.assertEqual([], stopped)
                        if case in ('hand', 'busy', 'equal', 'dirty', 'unknown', 'unknown-current'): self.assertEqual(killed.call_count, 0)
                    git('checkout', '--', 'board')

    def test_board_held_port_refusal_and_free_port_launch(self):
        import contextlib, io
        with contextlib.ExitStack() as stack:
            def mocked(obj, name, **kw): return stack.enter_context(patch.object(obj, name, **kw))
            mocked(m, 'configured_board_port', return_value=4173)
            matches = mocked(m, 'board_matches', return_value=False)
            get = mocked(m, 'http_get', side_effect=TimeoutError())
            listening = mocked(m, 'board_listening', return_value=True)
            pid = mocked(m, 'board_port_pid', return_value=4242)
            mocked(m, 'board_open', return_value={})
            mocked(m.shutil, 'which', return_value='/fixture/bun')
            life = mocked(m, 'lifeline'); life.return_value.session_owner.return_value = 900
            for known in (4242, None):
                pid.return_value = known
                stop_en = 'stop it (kill 4242)' if known else 'stop the process listening on :4173'
                stop_tw = '請停止它（kill 4242）' if known else '請停止佔用 :4173 的程序'
                reason = {'en': 'the board on :4173 runs old code or is not answering and cannot be replaced; ' + stop_en + ' and run fm board',
                          'zh-TW': ':4173 上的看板執行舊程式或沒有回應，無法替換；' + stop_tw + '後再執行 fm board'}
                with self.assertRaises(m.BoardRefusal) as error: m.board_start(self.repo)
                self.assertEqual(reason, error.exception.reason)
                self.assertEqual(reason['en'], str(error.exception))
                out, err = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    self.assertEqual(70, m.main(['board', str(self.repo)]))
                self.assertEqual(['fm board: ' + reason[lang] for lang in ('en', 'zh-TW')], err.getvalue().splitlines())
                self.assertEqual('', out.getvalue())
                self.assertEqual(0, life.return_value.start.call_count)
            listening.return_value = False
            matches.side_effect = [False, True, True]
            get.side_effect = [ConnectionRefusedError(), b'page']
            life.return_value.start.return_value.poll.return_value = None
            get.reset_mock()
            self.assertFalse(m.board_start(self.repo)['reused'])
            self.assertEqual([call('http://127.0.0.1:4173', timeout=5)] * 2, get.call_args_list)
            self.assertEqual(1, life.return_value.start.call_count)
            # A competing listener may acquire the port after the initial check.
            matches.side_effect = None; matches.return_value = False
            get.side_effect = TimeoutError()
            listening.side_effect = [False, True]
            life.return_value.start.return_value.poll.return_value = 1
            with self.assertRaises(m.BoardRefusal): m.board_start(self.repo)
            self.assertEqual(2, life.return_value.start.call_count)

    def test_board_unknown_code_and_manual_restart_pid_notices(self):
        import contextlib, io
        with tempfile.TemporaryDirectory() as temporary, contextlib.ExitStack() as stack:
            repo = Path(temporary).resolve()
            for folder in ('board', 'i18n'):
                (repo / folder).mkdir(); (repo / folder / 'fixture').write_text('old')
            def git(*args):
                subprocess.run(['git', '-C', str(repo), *args], check=True, capture_output=True)
            git('init', '-q'); git('config', 'user.name', 'Board fixture')
            git('config', 'user.email', 'board@example.invalid')
            git('add', '.'); git('commit', '-qm', 'old')
            old = m.board_code_id(repo)
            (repo / 'board/fixture').write_text('new')
            git('add', '.'); git('commit', '-qm', 'new')
            path = repo / 'state/session/board.json'; path.parent.mkdir(parents=True)
            def mocked(obj, name, **kw): return stack.enter_context(patch.object(obj, name, **kw))
            mocked(m, 'configured_board_port', return_value=4173)
            mocked(m, 'board_matches', return_value=True)
            get = mocked(m, 'http_get', return_value=b'page')
            mocked(m, 'board_open', return_value={})
            pid = mocked(m, 'board_port_pid', return_value=4242)
            drain = mocked(m, 'board_drain', return_value=None)
            life = mocked(m, 'lifeline'); killed = mocked(m.os, 'kill')
            for previous in (None, {'root': str(repo)}, {'code': None}):
                if previous is None: path.unlink(missing_ok=True)
                else: path.write_text(json.dumps(previous))
                reply = m.board_start(repo)
                self.assertTrue(reply['reused']); self.assertNotIn('stale', reply)
                reason = reply['code_unknown_reason']
                self.assertEqual({'en', 'zh-TW'}, set(reason))
                for text in reason.values():
                    self.assertIn('kill 4242', text); self.assertIn(':4173', text)
                self.assertEqual(0, drain.call_count)
                self.assertEqual(0, killed.call_count)
                self.assertEqual(0, life.return_value.start.call_count)
                out, err = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    self.assertEqual(0, m.main(['board', str(repo)]))
                self.assertEqual(reply, json.loads(out.getvalue()))
                self.assertEqual(['fm board: ' + reason[lang] for lang in ('en', 'zh-TW')], err.getvalue().splitlines())
            pid.return_value = None
            reply = m.board_start(repo)
            self.assertIn('stop the process listening on :4173', reply['code_unknown_reason']['en'])
            self.assertIn('請停止佔用 :4173 的程序', reply['code_unknown_reason']['zh-TW'])
            for payload, expected in ((None, 4242), ({'session_owned': False, 'pid': 5151}, 5151)):
                path.write_text(json.dumps({'code': old}))
                pid.return_value = 4242; pid.reset_mock(); drain.return_value = payload
                reply = m.board_start(repo)
                self.assertIn('restart it by hand', reply['stale_reason']['en'])
                self.assertIn('請手動重啟', reply['stale_reason']['zh-TW'])
                for text in reply['stale_reason'].values(): self.assertIn('kill ' + str(expected), text)
                self.assertEqual(1 if payload is None else 0, pid.call_count)
            # HTTP silence after SIGTERM never proves that the listener stopped.
            path.write_text(json.dumps({'code': old}))
            drain.return_value = {'session_owned': True, 'pid': 5151, 'owner': 900}
            drain.reset_mock(); pid.reset_mock()
            mocked(m, 'board_listening', return_value=True)
            ticks = iter([0, 1, 11])
            mocked(m.time, 'monotonic', side_effect=lambda: next(ticks))
            mocked(m.time, 'sleep')
            get.side_effect = [TimeoutError(), b'page']
            reply = m.board_start(repo)
            self.assertIn(call(5151, signal.SIGTERM), killed.call_args_list)
            self.assertEqual(0, life.return_value.start.call_count)
            self.assertEqual(call('http://127.0.0.1:4173', 4173, release=True), drain.call_args)
            self.assertIn('did not stop', reply['stale_reason']['en'])
            for text in reply['stale_reason'].values(): self.assertIn('kill 5151', text)
            self.assertEqual(0, pid.call_count)

    def test_board_listening_only_connection_refused_means_free(self):
        for error, expected in ((ConnectionRefusedError(), False), (TimeoutError(), True),
                                (ConnectionResetError(), True), (OSError('unreachable'), True)):
            with patch.object(m.socket, 'create_connection', side_effect=error) as connect:
                self.assertEqual(expected, m.board_listening(4173))
                self.assertEqual(call(('127.0.0.1', 4173), timeout=2), connect.call_args)
        try:
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0)); port = listener.getsockname()[1]
                listener.listen()
                self.assertTrue(m.board_listening(port))
            self.assertFalse(m.board_listening(port))
        except PermissionError as error:
            self.skipTest('loopback bind prohibited: ' + str(error))

    def test_board_port_pid_is_optional_and_never_raises(self):
        with patch.object(m.shutil, 'which', return_value=None), patch.object(m.subprocess, 'run') as run:
            self.assertIsNone(m.board_port_pid(4173)); self.assertEqual(0, run.call_count)
        with patch.object(m.shutil, 'which', return_value='/fixture/lsof'), patch.object(m.subprocess, 'run') as run:
            run.return_value.returncode = 0
            for output, expected in (('4242\n5151\n', 4242), ('', None), ('1\n', None), ('0', None), ('bad', None)):
                run.return_value.stdout = output
                self.assertEqual(expected, m.board_port_pid(4173))
            self.assertEqual(call(['/fixture/lsof', '-nP', '-t', '-iTCP:4173', '-sTCP:LISTEN'],
                                  capture_output=True, text=True, timeout=5, check=True), run.call_args)
            for error in (OSError(), subprocess.TimeoutExpired('lsof', 5), subprocess.CalledProcessError(1, 'lsof')):
                run.side_effect = error
                self.assertIsNone(m.board_port_pid(4173))

    def test_board_drain_http_contract_and_failures(self):
        import io
        from unittest.mock import Mock
        url = 'http://127.0.0.1:4173'
        for release in (False, True):
            response = Mock(status=200)
            response.__enter__ = Mock(return_value=response); response.__exit__ = Mock(return_value=False)
            response.read.return_value = b'{"draining": true}'
            with patch.object(m, 'board_secret', return_value='fixture-secret'), patch.object(m.urllib.request, 'urlopen', return_value=response) as send:
                self.assertEqual({'draining': True}, m.board_drain(url, 4173, release=release))
                request = send.call_args.args[0]
                self.assertEqual(url + '/drain', request.full_url)
                self.assertEqual('POST', request.method)
                self.assertEqual('Bearer fixture-secret', request.get_header('Authorization'))
                self.assertEqual(url, request.get_header('Origin'))
                self.assertEqual('application/json', request.get_header('Content-type'))
                self.assertEqual({'release': True} if release else {}, json.loads(request.data))
                self.assertEqual(5, send.call_args.kwargs['timeout'])
        for status in (409, 404, 403, 503):
            error = m.urllib.error.HTTPError(url, status, 'refused', {}, io.BytesIO(b'{"busy":"merge"}'))
            with patch.object(m, 'board_secret', return_value='fixture-secret'), patch.object(m.urllib.request, 'urlopen', side_effect=error):
                self.assertEqual({'busy': 'merge', 'status': 409} if status == 409 else None, m.board_drain(url, 4173))
        with patch.object(m, 'board_secret', side_effect=FileNotFoundError()), patch.object(m.urllib.request, 'urlopen') as send:
            self.assertIsNone(m.board_drain(url, 4173)); self.assertEqual(send.call_count, 0)
        for error in (OSError(), ValueError()):
            with patch.object(m, 'board_secret', return_value='fixture-secret'), patch.object(m.urllib.request, 'urlopen', side_effect=error):
                self.assertIsNone(m.board_drain(url, 4173))

    def test_one_time_address_never_in_an_argument_list(self):
        # T-122: `ps` shows every process's arguments to every other; on macOS
        # the sign-in address goes to osascript on stdin, not in argv
        calls=[]
        def run(argv, **kwargs):
            calls.append((argv, kwargs.get('input'))); return subprocess.CompletedProcess(argv, 0)
        address='http://127.0.0.1:4173/login#1790000000000.'+'a'*32+'.'+'b'*64
        with patch.object(m.sys,'platform','darwin'), \
             patch.object(m.shutil,'which',side_effect=lambda name: '/usr/bin/'+name), \
             patch.object(m.subprocess,'run',side_effect=run), \
             patch.object(m.subprocess,'call') as call:
            self.assertTrue(m.open_address(address))
        self.assertFalse(call.called)
        self.assertEqual(1,len(calls))
        argv, given = calls[0]
        self.assertEqual(['/usr/bin/osascript'],argv)
        self.assertNotIn('b'*64,' '.join(argv))
        self.assertIn(address.encode(),given)
    def test_login_url_is_signed_by_the_secret(self):
        import hashlib, hmac as mac
        config=tempfile.TemporaryDirectory(); self.addCleanup(config.cleanup)
        with patch.dict(os.environ,{'XDG_CONFIG_HOME':config.name}):
            with self.assertRaises(OSError): m.board_login_url('http://127.0.0.1:4173',4173)
            secret=m.board_secret_file(4173); secret.parent.mkdir(parents=True)
            secret.write_text('c'*64+'\n'); secret.chmod(0o600)
            before=int(time.time()*1000)
            address=m.board_login_url('http://127.0.0.1:4173',4173)
        base, code = address.split('#',1)
        self.assertEqual('http://127.0.0.1:4173/login',base)
        issued, nonce, tag = code.split('.')
        self.assertGreaterEqual(int(issued),before); self.assertEqual(13,len(issued)); self.assertEqual(32,len(nonce))
        want=mac.new(b'c'*64,f'login:http://127.0.0.1:4173:{issued}.{nonce}'.encode(),hashlib.sha256).hexdigest()
        self.assertEqual(want,tag)
        self.assertNotIn('c'*64,address)
    def test_open_address_off_macos_hands_the_address_to_the_desktop_opener(self):
        address='http://127.0.0.1:4173/login#1790000000000.'+'a'*32+'.'+'b'*64
        tools={'xdg-open':'/usr/bin/xdg-open','open':'/usr/bin/open','osascript':'/usr/bin/osascript'}
        for platform, present, want in [('linux',{'xdg-open','open','osascript'},'/usr/bin/xdg-open'),
                                        ('linux',{'open'},'/usr/bin/open'),
                                        ('darwin',{'open'},'/usr/bin/open')]:
            for code, opened in [(0,True),(3,False)]:
                with patch.object(m.sys,'platform',platform), \
                     patch.object(m.shutil,'which',side_effect=lambda name: tools[name] if name in present else None), \
                     patch.object(m.subprocess,'run') as run, \
                     patch.object(m.subprocess,'call',return_value=code) as call:
                    self.assertEqual(opened,m.open_address(address),(platform,present,code))
                self.assertFalse(run.called,'osascript is for macOS, and only when it is there')
                self.assertEqual([want,address],call.call_args.args[0])
        with patch.object(m.sys,'platform','linux'), patch.object(m.shutil,'which',return_value=None), \
             patch.object(m.subprocess,'run') as run, patch.object(m.subprocess,'call') as call:
            self.assertFalse(m.open_address(address),'no opener opens nothing')
        self.assertFalse(run.called); self.assertFalse(call.called)
    def reused_board(self, which, secret=True):
        # board_start on a board already serving this root, with the secret
        # file present or not, and the browser recorded instead of opened
        config=tempfile.TemporaryDirectory(); self.addCleanup(config.cleanup)
        if secret:
            with patch.dict(os.environ,{'XDG_CONFIG_HOME':config.name}):
                path=m.board_secret_file(4173)
            path.parent.mkdir(parents=True); path.write_text('d'*64+'\n'); path.chmod(0o600)
        opened=[]
        with patch.dict(os.environ,{'XDG_CONFIG_HOME':config.name,'FM_PORT':'4173'}), \
             patch.object(m,'board_matches',return_value=True), patch.object(m,'http_get',return_value=b'page'), \
             patch.object(m.sys,'platform','linux'), patch.object(m.shutil,'which',side_effect=which), \
             patch.object(m,'open_address',side_effect=lambda a: opened.append(a) or True), \
             patch.object(m, 'configured_board_port', return_value=4173), \
             patch.object(m.subprocess,'Popen') as spawn:
            record=m.board_start(self.repo)
        self.assertFalse(spawn.called)
        return record, opened, config.name
    def test_board_start_with_no_secret_opens_nothing_and_says_so_without_the_path(self):
        record, opened, config = self.reused_board(lambda name: '/usr/bin/xdg-open' if name=='xdg-open' else None, secret=False)
        self.assertEqual([],opened,'no sign-in address can be made, so the browser is not sent anywhere')
        self.assertFalse(record['opener_invoked'])
        self.assertIn('secret could not be read',record['sign_in_error'])
        saved=(self.repo/'state/session/board.json').read_text()
        self.assertEqual(record['sign_in_error'],json.loads(saved)['sign_in_error'])
        self.assertNotIn(config,saved); self.assertNotIn('.secret',saved); self.assertNotIn('firstmate/board-',saved)
        # the control: with the secret there, the same call signs the tab in
        record, opened, _ = self.reused_board(lambda name: '/usr/bin/xdg-open' if name=='xdg-open' else None)
        self.assertEqual(1,len(opened)); self.assertTrue(opened[0].startswith('http://127.0.0.1:4173/login#'))
        self.assertTrue(record['opener_invoked']); self.assertNotIn('sign_in_error',record)
    def test_board_start_with_no_opener_opens_nothing_and_says_so(self):
        record, opened, _ = self.reused_board(lambda name: None)
        self.assertEqual([],opened); self.assertFalse(record['opener_invoked'])
        self.assertIn('no program to open a browser',record['sign_in_error'])
        self.assertNotIn('login',(self.repo/'state/session/board.json').read_text())
    # --- T-145: one tab ---------------------------------------------------
    ADDRESS='http://127.0.0.1:4173/login#1790000000000.'+'a'*32+'.'+'b'*64
    def macos_board_open(self, running, tabs, opens=True):
        """board_open on macOS with osascript answering as a Mac would: the
        running-browser question with `running`, each browser's tab script
        with tabs[bundle] as (exit, stdout) or an exception. Every osascript
        call is recorded as (argv, script)."""
        calls=[]
        def run(argv, **kwargs):
            script=kwargs.get('input',b'').decode()
            calls.append((argv,script))
            if 'is running' in script: return subprocess.CompletedProcess(argv,0,stdout=running.encode(),stderr=b'')
            bundle=next(b for _, b, _ in m.BOARD_BROWSERS if f'application id "{b}"' in script)
            answer=tabs.get(bundle,(0,''))
            if isinstance(answer,Exception): raise answer
            return subprocess.CompletedProcess(argv,answer[0],stdout=answer[1].encode(),stderr=b'')
        with patch.object(m.sys,'platform','darwin'), \
             patch.object(m.shutil,'which',side_effect=lambda name: '/usr/bin/'+name), \
             patch.object(m.subprocess,'run',side_effect=run), \
             patch.object(m,'board_login_url',return_value=self.ADDRESS), \
             patch.object(m,'board_secret',return_value='f'*64), \
             patch.object(m,'open_address',return_value=opens) as opened:
            said=m.board_open('http://127.0.0.1:4173',4173)
        return said, calls, opened
    def test_a_tab_already_on_the_board_is_reused_and_brought_to_the_front(self):
        said, calls, opened = self.macos_board_open('com.apple.Safari\n',{'com.apple.Safari':(0,'reused\n')})
        self.assertFalse(opened.called,'a reused tab opens no new one')
        self.assertEqual(('reused','Safari',True),(said['tab'],said['browser'],said['opener_invoked']))
        self.assertIn('Safari',said['said']); self.assertNotIn('sign_in_error',said)
        self.assertEqual(2,len(calls),'one question for the running browsers, then Safari alone')
        for argv, _ in calls: self.assertEqual(['/usr/bin/osascript'],argv,'the address is never in an argument list')
        asked, tab = calls[0][1], calls[1][1]
        self.assertIn('if application id (b as text) is running',asked)
        for _, bundle, _ in m.BOARD_BROWSERS: self.assertIn(f'"{bundle}"',asked)
        # a literal id is resolved when the script compiles, and one browser
        # that is not installed failed the whole question
        self.assertNotIn('application id "',asked)
        self.assertNotIn('b'*64,asked,'the question for running browsers carries no code')
        self.assertIn('tell application id "com.apple.Safari"',tab)
        self.assertIn('set URL of t to "'+self.ADDRESS+'"',tab)
        self.assertIn('set current tab of w to t',tab); self.assertIn('set index of w to 1',tab); self.assertIn('activate',tab)
        # the board's address as either host, and nothing on a longer port
        for base in ('http://127.0.0.1:4173','http://localhost:4173'):
            self.assertIn(f'u is "{base}" or u starts with "{base}/"',tab)
        self.assertNotIn('starts with "http://127.0.0.1:4173"',tab,'a bare prefix would match port 41730 too')
        self.assertNotIn('b'*64,json.dumps(said),'what it says holds no code')
    def test_each_browser_speaks_its_own_words_and_one_that_cannot_be_scripted_is_passed_over(self):
        said, calls, opened = self.macos_board_open('com.google.Chrome\ncompany.thebrowser.Browser\ncom.apple.Safari\n',
            {'com.google.Chrome':(1,''),'company.thebrowser.Browser':(0,'reused')})
        self.assertFalse(opened.called)
        self.assertEqual(('reused','Arc'),(said['tab'],said['browser']))
        self.assertEqual(['is running','com.google.Chrome','company.thebrowser.Browser'],
            ['is running' if 'is running' in s else next(b for _, b, _ in m.BOARD_BROWSERS if f'application id "{b}"' in s) for _, s in calls],
            'Chrome refused, so Arc was asked, and Safari never was')
        self.assertIn('set active tab index of w to i',calls[1][1],'Chromium sets the active tab index')
        self.assertIn('tell t to select',calls[2][1],'Arc selects the tab')
        said, calls, _ = self.macos_board_open('com.brave.Browser\n',{'com.brave.Browser':(0,'reused')})
        self.assertEqual('Brave Browser',said['browser'])
        self.assertIn('set active tab index of w to i',calls[1][1])
    def test_with_no_board_tab_or_no_scriptable_browser_a_new_tab_is_opened_and_said(self):
        for running, tabs, asked in [('',{},1),                                          # no browser running
                                     ('com.apple.Safari\n',{'com.apple.Safari':(0,'')},2),  # no tab on the board
                                     ('com.apple.Safari\n',{'com.apple.Safari':(1,'')},2),  # not scriptable (refused)
                                     ('com.apple.Safari\n',{'com.apple.Safari':subprocess.TimeoutExpired('osascript',15)},2)]:
            said, calls, opened = self.macos_board_open(running,tabs)
            self.assertEqual([call(self.ADDRESS)],opened.call_args_list,(running,tabs))
            self.assertEqual(asked,len(calls))
            self.assertEqual(('new',True),(said['tab'],said['opener_invoked']))
            self.assertNotIn('browser',said); self.assertIn('opened a new one',said['said'])
        said, _, _ = self.macos_board_open('',{},opens=False)
        self.assertEqual((None,False),(said['tab'],said['opener_invoked']),'a browser that did not open is not a new tab')
        # off macOS nothing is scripted: the desktop opener opens a new tab
        with patch.object(m.sys,'platform','linux'), \
             patch.object(m.shutil,'which',side_effect=lambda name: '/usr/bin/xdg-open' if name=='xdg-open' else None), \
             patch.object(m.subprocess,'run') as run, \
             patch.object(m,'board_login_url',return_value=self.ADDRESS), \
             patch.object(m,'board_secret',return_value='f'*64), \
             patch.object(m,'open_address',return_value=True) as opened:
            said=m.board_open('http://127.0.0.1:4173',4173)
        self.assertFalse(run.called); self.assertEqual([call(self.ADDRESS)],opened.call_args_list)
        self.assertEqual('new',said['tab'])
    def test_a_slow_browser_still_gets_a_fresh_code_and_the_opener_ends_inside_its_bounds(self):
        """Every browser running and each one slow, as on a first run waiting
        on macOS's Automation prompt: each question uses its whole timeout.
        On a clock the stub advances, every code a browser is handed is minted
        just before the question that carries it, and is younger than the 60
        seconds a code lives when that question ends; the opener's whole run
        ends inside the re-login route's 60."""
        import re
        clock=[1000.0]; minted=[]; asked=[]
        def mint(url, port):
            minted.append(clock[0]); return self.ADDRESS.replace('1790000000000',str(len(minted)).rjust(13,'0'))
        def run(argv, **kwargs):
            script=kwargs['input'].decode(); timeout=kwargs['timeout']
            codes=re.findall(r'/login#([0-9]{13})\.',script)
            asked.append((clock[0],timeout,codes))
            if 'is running' in script:
                clock[0]+=0.1
                return subprocess.CompletedProcess(argv,0,stdout=''.join(b+'\n' for _, b, _ in m.BOARD_BROWSERS).encode(),stderr=b'')
            clock[0]+=timeout
            raise subprocess.TimeoutExpired(argv,timeout)
        opened=[]
        with patch.object(m.sys,'platform','darwin'), \
             patch.object(m.shutil,'which',side_effect=lambda name: '/usr/bin/'+name), \
             patch.object(m.subprocess,'run',side_effect=run), \
             patch.object(m.time,'monotonic',side_effect=lambda: clock[0]), \
             patch.object(m,'board_login_url',side_effect=mint), \
             patch.object(m,'board_secret',return_value='f'*64), \
             patch.object(m,'open_address',side_effect=lambda a, *rest: opened.append((clock[0],a)) or True):
            said=m.board_open('http://127.0.0.1:4173',4173)
        self.assertEqual('new',said['tab'],'every browser timed out, so a new tab is opened')
        self.assertEqual([],asked[0][2],'no code is minted before the search')
        tabs=[a for a in asked if a[2]]
        self.assertTrue(tabs,'the browsers were asked')
        self.assertEqual(len(minted),len(tabs)+1,'one code per question that carries one, and one for the new tab')
        for (at, timeout, codes), made in zip(tabs, minted):
            self.assertEqual(at,made,'a code is minted just before the question that carries it')
            self.assertLess(at+timeout-made,60,'and a browser gets it before it expires')
        self.assertEqual(len(set(c for a in tabs for c in a[2])),len(tabs),'no code is handed to two browsers')
        at, address = opened[0]
        self.assertEqual(minted[-1],at,'the new tab gets a code minted as it is opened, after the search')
        self.assertIn(str(len(minted)).rjust(13,'0'),address)
        self.assertLessEqual(at-1000.0,m.OPENER_BUDGET-m.ASK_OPEN,'the search ends by its deadline')
        self.assertLess(m.OPENER_BUDGET,60,'the whole run, the new tab included, ends inside a code life')
        route=(root/'board/server.ts').read_text()
        self.assertLess(m.OPENER_BUDGET*1000,int(re.search(r'RELOGIN_TIMEOUT_MS = ([0-9_]+)',route).group(1).replace('_','')),
                        'and inside the re-login route timeout')
    def test_board_start_says_which_tab_it_used(self):
        record, opened, _ = self.reused_board(lambda name: '/usr/bin/xdg-open' if name=='xdg-open' else None)
        self.assertEqual('new',record['tab'])
        self.assertEqual('new',json.loads((self.repo/'state/session/board.json').read_text())['tab'])
    def test_board_login_is_the_same_opener_and_prints_no_code(self):
        """What the board's re-login button runs: `board-login <port>`."""
        import contextlib, io
        for said, rc in [(dict(opener_invoked=True,tab='reused',browser='Safari'),0),
                         (dict(opener_invoked=False,tab=None,sign_in_error='the board secret could not be read; restart the board'),69),
                         (dict(opener_invoked=False,tab=None),69)]:
            out=io.StringIO()
            with patch.object(m,'board_open',return_value=said) as run, contextlib.redirect_stdout(out):
                self.assertEqual(rc,m.main(['board-login','4173']))
            self.assertEqual([call('http://127.0.0.1:4173',4173)],run.call_args_list)
            self.assertEqual(said,json.loads(out.getvalue()))
        for bad in ([],['0'],['70000'],['41x'],['4173','4174']):
            err=io.StringIO()
            with patch.object(m,'board_open') as run, contextlib.redirect_stderr(err):
                self.assertEqual(64,m.main(['board-login',*bad]),bad)
            self.assertFalse(run.called)
        # and as a program: the code goes to the browser, and not to stdout or stderr
        fake=self.repo/'fake-browser'; fake.mkdir(); seen=self.repo/'browser'
        for name in ('osascript','xdg-open','open'):
            (fake/name).write_text('#!/usr/bin/env bash\n{ printf "%s\\n" "$*"; cat; } >> '+str(seen)+'\n'); (fake/name).chmod(0o755)
        config=Path(self.tmp.name)/'config'; secret=config/'firstmate/board-4173.secret'
        secret.parent.mkdir(parents=True); secret.write_text('e'*64+'\n'); secret.chmod(0o600)
        env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_'))}
        env.update(PATH=str(fake)+os.pathsep+env.get('PATH',''),XDG_CONFIG_HOME=str(config),PYTHONDONTWRITEBYTECODE='1')
        run=subprocess.run([sys.executable,str(self.repo/'bin/fm-herdr.py'),'board-login','4173'],env=env,
                           stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=60)
        self.assertEqual(0,run.returncode,run.stderr)
        import re
        codes=re.findall(r'/login#([0-9]{13}\.[0-9a-f]{32}\.[0-9a-f]{64})',seen.read_text())
        self.assertEqual(1,len(set(codes)),'the browser was handed one sign-in address')
        self.assertNotIn(codes[0],run.stdout); self.assertNotIn(codes[0],run.stderr)
        self.assertNotIn('/login',run.stdout)
        self.assertEqual('new',json.loads(run.stdout)['tab'])
    def main_board(self, outcome):
        import contextlib, io
        out, err = io.StringIO(), io.StringIO()
        kind = dict(side_effect=outcome) if isinstance(outcome,Exception) else dict(return_value=outcome)
        with patch.object(m,'board_start',**kind) as start, contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc=m.main(['board',str(self.repo)])
        self.assertEqual([call(str(self.repo))],start.call_args_list)
        return rc, out.getvalue(), err.getvalue()
    def test_main_board_mode_reports_in_one_line_never_a_traceback(self):
        for error in (RuntimeError('board requires Bun'), OSError('no space left')):
            rc, out, err = self.main_board(error)
            self.assertNotEqual(0,rc); self.assertEqual('',out)
            self.assertEqual('fm board: '+str(error)+'\n',err)
        rc, out, err = self.main_board(dict(url='http://127.0.0.1:4173',opener_invoked=False,sign_in_error='the board secret could not be read; restart the board'))
        self.assertNotEqual(0,rc,'a tab that could not be signed in is not a success')
        self.assertEqual('fm board: the board secret could not be read; restart the board\n',err)
        self.assertEqual('http://127.0.0.1:4173',json.loads(out)['url'])
        rc, out, err = self.main_board(dict(url='http://127.0.0.1:4173',opener_invoked=True))
        self.assertEqual(0,rc); self.assertEqual('',err); self.assertTrue(json.loads(out)['opener_invoked'])
        # and as a program: a machine with no Bun and nothing on the port
        env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_')) and not k.lower().endswith('_proxy')}
        env.update(PATH='/nonexistent',FM_PORT='1',PYTHONDONTWRITEBYTECODE='1',NO_PROXY='*',no_proxy='*')
        run=subprocess.run([sys.executable,str(self.repo/'bin/fm-herdr.py'),'board',str(self.repo)],
                           env=env,stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=60)
        self.assertNotEqual(0,run.returncode)
        self.assertEqual('fm board: board requires Bun\n',run.stderr)
        self.assertNotIn('Traceback',run.stderr)
    def board_cli(self, *args):
        # bin/fm.sh board, with fm-herdr.py replaced by a recorder of its arguments
        calls=self.repo/'herdr-calls'
        (self.repo/'bin/fm-herdr.py').write_text(
            'import json, sys\nopen(%r,"a").write(json.dumps(sys.argv[1:])+"\\n")\nsys.exit(7)\n' % str(calls))
        env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_'))}
        run=subprocess.run(['bash',str(self.repo/'bin/fm.sh'),'board',*args],cwd=self.repo,env=env,
                           stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=60)
        seen=[json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
        if calls.exists(): calls.unlink()
        return run, seen
    def test_fm_board_hands_the_root_to_fm_herdr_and_refuses_what_it_cannot_use(self):
        real=str(self.repo.resolve())
        run, seen = self.board_cli()
        self.assertEqual([['board',real]],seen,'with no --repo, the checkout fm.sh lives in')
        self.assertEqual(7,run.returncode,'and its exit is fm-herdr.py\'s')
        other=Path(self.tmp.name)/'elsewhere'; other.mkdir()
        run, seen = self.board_cli('--repo',str(other))
        self.assertEqual([['board',str(other.resolve())]],seen,'--repo names the root')
        run, seen = self.board_cli('--sideways')
        self.assertEqual(64,run.returncode); self.assertIn('board: unknown argument --sideways',run.stderr); self.assertEqual([],seen)
        run, seen = self.board_cli('--repo',str(Path(self.tmp.name)/'no-such-dir'))
        self.assertNotEqual(0,run.returncode); self.assertIn('no repo at',run.stderr); self.assertEqual([],seen)
        run, seen = self.board_cli('--repo')
        self.assertNotEqual(0,run.returncode); self.assertEqual([],seen)
    def test_board_start_goes_through_the_lifeline_owned_by_the_session(self):
        """T-151: the board outlives the command that starts it, so it names the
        session as its owner, and is started by the primitive, never detached."""
        started = []
        class Keeper:
            pid = 4242
            def poll(self): return None
        def start(argv, owner=None, **kwargs):
            started.append((argv, owner, kwargs)); return Keeper()
        with patch.dict(os.environ, {'FM_SESSION_PID': '31337', 'FM_PORT': '4173'}), \
             patch.object(m, 'board_matches', side_effect=[False, False, True, True]), \
             patch.object(m, 'http_get', side_effect=[OSError('nothing there'), b'page']), \
             patch.object(m, 'board_listening', return_value=False), \
             patch.object(m.shutil, 'which', side_effect=lambda name: '/usr/bin/bun' if name == 'bun' else None), \
             patch.object(m.lifeline(), 'start', side_effect=start), \
             patch.object(m, 'configured_board_port', return_value=4173), \
             patch.object(m.subprocess, 'Popen', side_effect=AssertionError('started without a lifeline')):
            record = m.board_start(self.repo)
        self.assertEqual(1, len(started))
        argv, owner, kwargs = started[0]
        self.assertEqual(['/usr/bin/bun', 'run', str(self.repo.resolve() / 'board/server.ts')], argv)
        self.assertEqual(31337, owner, 'owned by the session, not by the command that started it')
        self.assertNotIn('start_new_session', kwargs)
        self.assertEqual(31337, record['owner'])
    def test_actual_board_start_and_correct_root_reuse(self):
        bun=shutil.which('bun')
        if not bun: self.skipTest('Bun unavailable: actual HTTP board startup not verified')
        try:
            with socket.socket() as probe:
                probe.bind(('127.0.0.1',0)); port=probe.getsockname()[1]
        except PermissionError as error:
            self.skipTest('loopback bind prohibited: '+str(error))
        shutil.copytree(root/'board',self.repo/'board')
        (self.repo / 'config.yaml').write_text(f'board:\n  port: {port}\n')
        children=[]; original=m.subprocess.Popen
        def spawn(*args,**kwargs):
            child=original(*args,**kwargs)
            # Count board launches by their script, independent of the
            # interpreter used by foreground settings readers.
            if str(self.repo.resolve() / 'board/server.ts') in args[0]: children.append(child)
            return child
        # T-122: the board's secret goes under XDG_CONFIG_HOME, here a directory
        # of this test's own outside the fixture root, never the operator's home
        config=tempfile.TemporaryDirectory(); self.addCleanup(config.cleanup)
        opened=[]
        def browser(address):
            opened.append(address); return True
        # T-151: the session the board belongs to, a process of this test's own
        session=original(['sleep','300'],stdin=subprocess.DEVNULL)
        self.addCleanup(lambda: (session.poll() is None and session.kill(), session.wait()))
        try:
            with patch.dict(os.environ,{'XDG_CONFIG_HOME':config.name,'FM_SESSION_PID':str(session.pid)}), \
                 patch.object(m.shutil,'which',side_effect=lambda name: bun if name=='bun' else '/usr/bin/'+name if name=='xdg-open' else None), \
                 patch.object(m.sys,'platform','linux'), \
                 patch.object(m,'open_address',side_effect=browser), \
                 patch.object(m.subprocess,'Popen',side_effect=spawn):
                first=m.board_start(self.repo)
                self.assertFalse(first['reused']); self.assertTrue(first['page_http_verified'])
                second=m.board_start(self.repo)
                self.assertTrue(second['reused']); self.assertEqual(1,len(children))
                other=self.repo/'other'; other.mkdir()
                (other / 'config.yaml').write_text(f'board:\n  port: {port}\n')
                with self.assertRaisesRegex(RuntimeError,'unverified root'): m.board_start(other)
                # the browser was sent to a one-time sign-in address each time,
                # and the real board takes each code once and only once
                url=f'http://127.0.0.1:{port}'
                self.assertEqual(2,len(opened))
                for address in opened:
                    self.assertTrue(address.startswith(url+'/login#'), address)
                code=opened[0].split('#',1)[1]
                def login(code, origin=url):
                    import urllib.request, urllib.error
                    request=urllib.request.Request(url+'/login',data=json.dumps(dict(code=code)).encode(),method='POST',
                        headers={'content-type':'application/json','origin':origin})
                    try:
                        with urllib.request.urlopen(request,timeout=5) as reply:
                            return reply.status, json.loads(reply.read()).get('token',''), reply.headers.get('set-cookie')
                    except urllib.error.HTTPError as error:
                        error.close(); return error.code, '', None
                # the tab's token comes back in the body, never as a cookie
                status, token, cookie = login(code)
                self.assertEqual(200,status); self.assertRegex(token,'^[0-9a-f]{64}$'); self.assertIsNone(cookie)
                self.assertEqual(403,login(code)[0],'a code is good once')
                self.assertEqual(200,login(opened[1].split('#',1)[1])[0],'each opening mints its own code')
                # the record in state/ holds the board's URL, never a code or the secret's path
                record=(self.repo/'state/session/board.json').read_text()
                self.assertNotIn('#',record); self.assertNotIn('login',record)
                self.assertNotIn(config.name,record); self.assertNotIn('.secret',record)
                secret=m.board_secret_file(port)
                self.assertEqual(0o600,secret.stat().st_mode & 0o777)
                self.assertFalse(str(secret.resolve()).startswith(str(self.repo.resolve())+'/'))
                for path in (self.repo/'state').rglob('*'):
                    if path.is_file():
                        text=path.read_bytes()
                        self.assertNotIn(secret.read_bytes().strip(),text,path)
                        self.assertNotIn(str(secret).encode(),text,path)
                # the session ends, and the board with it: the kernel tells the
                # keeper, which stops the board - no one has to remember to
                self.assertEqual(session.pid,first['owner'])
                session.kill(); session.wait()
                self.assertIsNotNone(children[0].wait(timeout=15),'the board ended with its owner')
                with self.assertRaises(OSError): m.http_get(url)
        finally:
            for child in children:
                if child.poll() is None: os.killpg(child.pid,signal.SIGTERM)
                child.wait(timeout=5)
    def test_retire_dead_crew_closes_ghosts_keeps_live_and_is_idempotent(self):
        # Fail-first class: aboard is actor-event-sourced; dead processes must
        # get agent_finished under that exact actor, not a task-level crash.
        events = self.repo / 'state/events.jsonl'
        events.parent.mkdir(parents=True, exist_ok=True)
        ghost, live = 'worker-ghost-t035-r1', 'worker-live-t035-r2'
        lines = [
            {'ts': '2026-09-22T00:00:00Z', 'actor': ghost, 'type': 'dispatched', 'task': 'T-035', 'pr': 51,
             'data': {'role': 'worker'}, 'summary': {'en': 'ghost boarded', 'zh-TW': '幽靈上船'}},
            {'ts': '2026-09-22T00:00:01Z', 'actor': live, 'type': 'dispatched', 'task': 'T-035', 'pr': 51,
             'data': {'role': 'worker'}, 'summary': {'en': 'live boarded', 'zh-TW': '活人上船'}},
            {'ts': '2026-09-22T00:00:02Z', 'actor': 'firstmate', 'type': 'dispatched', 'task': 'T-035',
             'summary': {'en': 'firstmate stays', 'zh-TW': '大副留下'}},
        ]
        events.write_text(''.join(json.dumps(line) + '\n' for line in lines))
        ghost_run = self.repo / 'state/runs' / ghost
        live_run = self.repo / 'state/runs' / live
        ghost_run.mkdir(parents=True); live_run.mkdir(parents=True)
        live_token = 'live-crew-' + live
        holder = subprocess.Popen(
            [sys.executable, '-c', 'import time; time.sleep(60)', live_token],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True)
        def stop_holder():
            if holder.poll() is None:
                os.killpg(holder.pid, signal.SIGTERM)
            holder.wait(timeout=5)
        self.addCleanup(stop_holder)
        m.save(ghost_run / 'process.json',
               dict(actor=ghost, role='worker', task='T-035', pid=999999999, token='missing-token'))
        m.save(live_run / 'process.json',
               dict(actor=live, role='worker', task='T-035', pid=holder.pid, token=live_token))
        self.assertTrue(m.process_matches(m.read(live_run / 'process.json')))
        before = events.read_text()
        first = m.retire_dead_crew(self.repo)
        self.assertEqual([ghost], first['retired'])
        self.assertEqual([live], first['kept'])
        after = [json.loads(line) for line in events.read_text().splitlines() if line.strip()]
        closing = [e for e in after if e.get('actor') == ghost and e.get('type') == 'agent_finished']
        self.assertEqual(1, len(closing), 'ghost must leave the deck via agent_finished')
        self.assertEqual('process_gone', closing[0]['data']['status'])
        self.assertEqual('dispatched', m.crew_last_events(self.repo)['firstmate']['type'])
        self.assertEqual('agent_finished', m.crew_last_events(self.repo)[ghost]['type'])
        self.assertEqual('dispatched', m.crew_last_events(self.repo)[live]['type'])
        second = m.retire_dead_crew(self.repo)
        self.assertEqual([], second['retired'])
        self.assertEqual([live], second['kept'])
        self.assertEqual(1, sum(1 for line in events.read_text().splitlines()
                                if '"agent_finished"' in line and ghost in line))
        # Gate 4: without retire_dead_crew the ghost stays aboard in the fold.
        events.write_text(before)
        self.assertEqual('dispatched', m.crew_last_events(self.repo)[ghost]['type'])
    def test_execute_child_prints_heartbeat_while_adapter_runs(self):
        from session_heartbeat_fixture import HeartbeatFixture  # tests/lib/session_heartbeat_fixture.py
        attempt = self.repo / 'state/runs/worker-hb-t035-r1/cursor-agent-hb'
        attempt.mkdir(parents=True)
        adapter = self.repo / 'bin/adapters/slow.sh'
        adapter.parent.mkdir(parents=True, exist_ok=True)
        m.save(attempt / 'invocation.json',
               dict(adapter=str(adapter), prompt=str(attempt / 'prompt.md'),
                    tree=str(self.repo), actor='worker-hb-t035-r1', role='worker', task='T-035'))
        (attempt / 'prompt.md').write_text('go\n')
        m.save(attempt / 'environment.json', dict(os.environ, FM_CHAIN_ATTEMPT='hb'))
        (attempt / 'environment.json').chmod(0o600)
        lock = attempt / 'execution.lock'
        lock.write_text('')
        fd = os.open(lock, os.O_RDWR)
        self.addCleanup(lambda: os.close(fd) if fd >= 0 else None)
        with patch.dict(os.environ, {'FM_HEARTBEAT_SECS': '0.15'}):
            with HeartbeatFixture(m, attempt, adapter) as fixture:
                rc = m.execute_child(attempt, fd)
        text = fixture.output.getvalue()
        self.assertIn('worker-hb-t035-r1 worker started on T-035', text)
        self.assertIn('still running', text)
        self.assertEqual(0, rc)
        self.assertRegex(text, r'finished exit=0 after \d+s')
        fixture.assert_completed(self)

    def decision_files(self):
        state = self.repo / 'state'
        return {str(p.relative_to(state)): p.read_bytes()
                for folder in ('pending', 'decisions', 'session/observed')
                for p in sorted((state / folder).glob('*.json'))} | {
                name: (state / name).read_bytes() for name in ('events.jsonl', 'session/wake.jsonl')
                if (state / name).exists()}
    def test_unacknowledged_wake_is_reported_until_ack(self):
        """T-041, T-151: the board pushes a wake onto the queue; status surfaces what firstmate has not acted on."""
        state = self.repo / 'state'
        for folder in ('pending', 'decisions', 'session'): (state / folder).mkdir(parents=True, exist_ok=True)
        (state / 'events.jsonl').write_text('{"type":"decision_made","data":{"decision":"D-047"}}\n')
        (state / 'pending/D-047.json').write_text('{"id":"D-047","task":"T-041","kind":"choice"}')
        answer = dict(id='D-047', chosen='custom', text='hold until Friday', task='T-041', kind='choice',
                      ts='2026-09-23T08:00:00.000Z', identity='decision:D-047')
        (state / 'decisions/D-047.json').write_text(json.dumps(answer))
        (state / 'session/wake.jsonl').write_text(json.dumps(
            dict(id='D-047', reason='answered', decision=answer, woken=1790000000.0)) + '\n')
        # Answered but never pushed: not firstmate's acknowledgement backlog.
        (state / 'decisions/D-048.json').write_text('{"id":"D-048","chosen":"A","task":"T-040","kind":"merge"}')
        before = self.decision_files()

        status = self.session_cli('status')
        self.assertEqual(0, status.returncode, status.stderr)
        report = json.loads(status.stdout)
        self.assertEqual([dict(id='D-047', task='T-041', kind='choice', chosen='custom',
                               text='hold until Friday', ts='2026-09-23T08:00:00.000Z',
                               merge=None, reason='answered', woken=1790000000.0)], report['unacknowledged'])
        self.assertRegex(status.stderr, r'(?s)1 captain decision.*D-047.*T-041.*custom.*hold until Friday')
        self.assertEqual(before, self.decision_files(), 'status must not consume or rewrite decisions')

        refused = self.session_cli('ack', '--decision', 'D-999')
        self.assertNotEqual(0, refused.returncode)
        self.assertIn('no wake for D-999', refused.stderr)
        self.assertFalse((state / 'session/acknowledged/D-999.json').exists())
        self.assertNotEqual(0, self.session_cli('ack').returncode, 'ack requires an explicit decision id')
        unpushed = self.session_cli('ack', '--decision', 'D-048')
        self.assertNotEqual(0, unpushed.returncode)
        self.assertIn('no wake for D-048', unpushed.stderr)

        acked = self.session_cli('ack', '--decision', 'D-047')
        self.assertEqual(0, acked.returncode, acked.stderr)
        receipt = state / 'session/acknowledged/D-047.json'
        self.assertEqual('D-047', json.loads(receipt.read_text())['id'])
        saved = receipt.read_bytes()
        self.assertEqual(before, self.decision_files(), 'ack must not delete the wake, decision or event')
        again = self.session_cli('ack', '--decision', 'D-047')
        self.assertEqual(0, again.returncode, again.stderr)
        self.assertEqual(saved, receipt.read_bytes(), 'ack is idempotent')

        after = self.session_cli('status')
        self.assertEqual(0, after.returncode, after.stderr)
        self.assertEqual([], json.loads(after.stdout)['unacknowledged'])
        self.assertIn('no unacknowledged captain decisions', after.stderr)
        self.assertEqual(before, self.decision_files())
        # an observation the retired watcher wrote before T-151 is still read
        m.save(state / 'session/observed/D-046.json',
               dict(status='observed', decision=dict(answer, id='D-046'), id='D-046', observed=1780000000.0))
        self.assertEqual(['D-046'], [i['id'] for i in json.loads(self.session_cli('status').stdout)['unacknowledged']])
        self.assertEqual(0, self.session_cli('ack', '--decision', 'D-046').returncode)
    def test_legacy_receipts_use_current_decisions_without_writing(self):
        state = self.repo / 'state'
        cases = {
            'settled': dict(task='T-198', chosen='A', kind='merge', merge='merged', merge_settled='now'),
            'terminal': dict(task='T-199', chosen='A', kind='choice'),
            'closed': dict(task='T-200', chosen='A', kind='choice'),
            'reopened': dict(task='T-201', chosen='A', kind='choice'),
            'unanswered': dict(task='T-199', kind='choice', text='current question'),
            'running': dict(task='T-202', chosen='A', kind='merge', merge='running'),
            'failed': dict(task='T-203', chosen='A', kind='merge', merge='failed'),
            'open': dict(task='SK-001', chosen='A', kind='choice'),
        }
        for name, decision in cases.items():
            ident = 'D-' + name
            m.save(state / ('session/observed/' + ident + '.json'),
                   dict(id=ident, observed=1, decision=dict(task='stale', chosen='old', merge='running')))
            m.save(state / ('decisions/' + ident + '.json'), dict(decision, id=ident))
        for name in ('missing', 'unreadable'):
            m.save(state / ('session/observed/D-' + name + '.json'),
                   dict(observed=1, decision=dict(task='legacy')))
        (state / 'decisions/D-unreadable.json').write_text('{invalid')
        events = [dict(type=kind, task=task, actor=actor, data=dict(reason=reason))
                  for kind, task, actor, reason in [
                      ('merged', 'T-199', 'firstmate', ''), ('closed', 'T-200', 'captain', ''),
                      ('reopened', 'T-200', 'firstmate', 'not authorized'),
                      ('reopened', 'T-200', 'captain', '  '),
                      ('merged', 'T-201', 'firstmate', ''),
                      ('reopened', 'T-201', 'captain', 'retry')]]
        (state / 'events.jsonl').write_text('\n'.join(map(json.dumps, events)) + '\n')
        # Wake queue entries are never subject to legacy settlement filtering.
        (state / 'session/wake.jsonl').write_text(json.dumps(dict(
            id='D-wake', woken=2, reason='answered', decision=cases['settled'])) + '\n')
        m.save(state / 'session/acknowledged/D-other.json', dict(id='D-other', acknowledged=0))
        def snapshot():
            return {str(p.relative_to(state)): p.read_bytes()
                    for folder in ('observed', 'acknowledged')
                    for p in (state / 'session' / folder).rglob('*') if p.is_file()}
        before = snapshot()
        result = self.session_cli('status')
        self.assertEqual(0, result.returncode, result.stderr)
        listed = {item['id']: item for item in json.loads(result.stdout)['unacknowledged']}
        self.assertEqual({'D-reopened', 'D-unanswered', 'D-running', 'D-failed', 'D-open',
                          'D-missing', 'D-unreadable', 'D-wake'}, set(listed))
        self.assertEqual('current question', listed['D-unanswered']['text'])
        self.assertIsNone(listed['D-unanswered']['chosen'])
        self.assertEqual('failed', listed['D-failed']['merge'])
        self.assertEqual('legacy', listed['D-missing']['task'])
        self.assertEqual(before, snapshot(), 'status must leave legacy receipts and acknowledgements byte-identical')

    def test_an_owned_decision_id_is_woken_listed_and_acknowledged(self):
        """T-047: an id naming its owner, D-<project>-<task>-<n>, wakes firstmate like D-<digits> does."""
        owned = 'D-firstmate-workflow-T047-1'
        state = self.repo / 'state'
        for folder in ('pending', 'decisions'): (state / folder).mkdir(parents=True, exist_ok=True)
        (state / 'events.jsonl').write_text('')
        (state / ('pending/%s.json' % owned)).write_text(json.dumps(
            dict(id=owned, task='T-047', kind='merge', pr=77, project='firstmate-workflow')))
        answer = dict(chosen='A', task='T-047', kind='merge', pr=77, project='firstmate-workflow',
                      ts='2026-09-24T08:00:00.000Z', identity='decision:' + owned)
        (state / ('decisions/%s.json' % owned)).write_text(json.dumps(dict(answer, id=owned)))
        # the wait fm-session.sh runs, keyed by the owned id, is woken by the push
        import threading
        def board():
            time.sleep(.3); self.push(owned, **answer)
        writer = threading.Thread(target=board); writer.start()
        items = m.wake_wait(self.repo, owned, 20)
        writer.join()
        self.assertEqual([owned], [item['id'] for item in items])
        self.assertEqual('A', items[0]['chosen'])

        status = self.session_cli('status')
        self.assertEqual(0, status.returncode, status.stderr)
        listed = json.loads(status.stdout)['unacknowledged']
        self.assertEqual([owned], [item['id'] for item in listed])
        self.assertEqual('T-047', listed[0]['task'])
        self.assertIn(owned, status.stderr)

        acked = self.session_cli('ack', '--decision', owned)
        self.assertEqual(0, acked.returncode, acked.stderr)
        self.assertEqual(owned, json.loads((state / ('session/acknowledged/%s.json' % owned)).read_text())['id'])
        self.assertEqual([], json.loads(self.session_cli('status').stdout)['unacknowledged'])
        # an id carrying path characters is refused, and nothing is written for it
        for bad in ('D-firstmate-workflow-T047-1/../x', 'D-a.b-T047-1'):
            refused = self.session_cli('ack', '--decision', bad)
            self.assertNotEqual(0, refused.returncode, bad)
        self.assertEqual([owned + '.json'], sorted(p.name for p in (state / 'session/acknowledged').iterdir()))
unittest.main(argv=['session'], verbosity=2)
PY
