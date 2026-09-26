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
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import call, patch

sys.dont_write_bytecode = True  # Import production code without dirtying the checkout.
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('managed', root / 'bin/fm-herdr.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class Session(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        shutil.copytree(root / 'bin', self.repo / 'bin')
        shutil.copytree(root / 'skills', self.repo / 'skills')
    def test_role_context_reaches_supported_launchers(self):
        for role in ['worker', 'reviewer', 'firstmate']:
            result = m.role_context(self.repo, role, 'T-035', 'worker-mira-t035-r2', 'payload')
            self.assertIn('explicitly dispatched ' + role, result)
            self.assertIn('payload', result)
            self.assertIn('worker-mira-t035-r2', result)
            self.assertIn((self.repo / 'skills' / role / 'SKILL.md').read_text(), result)
    def test_board_verifies_root_with_relative_nonce(self):
        seen = []
        def request(url):
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
    def test_watch_is_live_reused_observable_durable_and_cancellable(self):
        first = m.watch_start(self.repo, 'D-test')
        try:
            self.assertTrue(m.process_matches(first))
            self.assertEqual(first['pid'], m.watch_start(self.repo, 'D-test')['pid'])
            decisions = self.repo / 'state/decisions'; decisions.mkdir(parents=True, exist_ok=True)
            (decisions / 'D-test.json').write_text('{"id":"D-test","chosen":"B"}')
            result = Path(first['directory']) / 'result.json'
            for _ in range(80):
                if result.exists(): break
                time.sleep(.05)
            self.assertEqual('B', json.loads(result.read_text())['decision']['chosen'])
            self.assertEqual('observed', json.loads(result.read_text())['status'])
        finally: m.watch_stop(self.repo, 'D-test')
        second = m.watch_start(self.repo, 'D-cancel')
        m.watch_stop(self.repo, 'D-cancel')
        self.assertFalse(m.process_matches(second))
        self.assertEqual('stopped', json.loads((Path(second['directory']) / 'result.json').read_text())['status'])
    def test_board_reuse_does_not_spawn_and_wrong_root_is_refused(self):
        with patch.object(m,'board_matches',return_value=True), patch.object(m,'http_get',return_value=b'page'), \
             patch.object(m.shutil,'which',return_value=None), patch.object(m.subprocess,'Popen') as spawn:
            reply=m.board_start(self.repo)
            self.assertTrue(reply['reused']); self.assertTrue(reply['page_http_verified'])
            self.assertFalse(reply['opener_invoked']); self.assertFalse(reply['browser_navigation_verified'])
            self.assertFalse(spawn.called)
        with patch.object(m,'board_matches',return_value=False), patch.object(m,'http_get',return_value=b'foreign'), \
             patch.object(m.subprocess,'Popen') as spawn:
            with self.assertRaisesRegex(RuntimeError,'unverified root'): m.board_start(self.repo)
            self.assertFalse(spawn.called)
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
    def test_continuous_watch_restart_preserves_observation(self):
        pending=self.repo/'state/pending'; pending.mkdir(parents=True)
        decisions=self.repo/'state/decisions'; decisions.mkdir(parents=True)
        events=self.repo/'state/events.jsonl'; events.write_text('')
        (pending/'D-saved.json').write_text('{"id":"D-saved"}')
        (decisions/'D-saved.json').write_text('{"id":"D-saved","chosen":"B"}')
        first=m.watch_start(self.repo)
        receipt=self.repo/'state/session/observed/D-saved.json'
        try:
            for _ in range(80):
                if receipt.exists(): break
                time.sleep(.05)
            saved=receipt.read_bytes()
            self.assertTrue(receipt.exists(), 'watch must observe existing decisions without fm-decide --await')
            self.assertTrue(m.process_matches(first))
            self.assertEqual(b'', events.read_bytes(), 'watch observation must not rewrite events.jsonl')
        finally: m.watch_stop(self.repo)
        second=m.watch_start(self.repo)
        try:
            time.sleep(.3)
            self.assertTrue(m.process_matches(second))
            self.assertEqual(saved,receipt.read_bytes())
            self.assertEqual(b'', events.read_bytes())
        finally: m.watch_stop(self.repo)
    def test_actual_board_start_and_correct_root_reuse(self):
        bun=shutil.which('bun')
        if not bun: self.skipTest('Bun unavailable: actual HTTP board startup not verified')
        try:
            with socket.socket() as probe:
                probe.bind(('127.0.0.1',0)); port=probe.getsockname()[1]
        except PermissionError as error:
            self.skipTest('loopback bind prohibited: '+str(error))
        shutil.copytree(root/'board',self.repo/'board')
        children=[]; original=m.subprocess.Popen
        def spawn(*args,**kwargs):
            child=original(*args,**kwargs); children.append(child); return child
        # T-122: the board's secret goes under XDG_CONFIG_HOME, here a directory
        # of this test's own outside the fixture root, never the operator's home
        config=tempfile.TemporaryDirectory(); self.addCleanup(config.cleanup)
        opened=[]
        def browser(address):
            opened.append(address); return True
        try:
            with patch.dict(os.environ,{'FM_PORT':str(port),'XDG_CONFIG_HOME':config.name}), \
                 patch.object(m.shutil,'which',side_effect=lambda name: bun if name=='bun' else '/usr/bin/'+name if name=='xdg-open' else None), \
                 patch.object(m.sys,'platform','linux'), \
                 patch.object(m,'open_address',side_effect=browser), \
                 patch.object(m.subprocess,'Popen',side_effect=spawn):
                first=m.board_start(self.repo)
                self.assertFalse(first['reused']); self.assertTrue(first['page_http_verified'])
                second=m.board_start(self.repo)
                self.assertTrue(second['reused']); self.assertEqual(1,len(children))
                other=self.repo/'other'; other.mkdir()
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
        # Gate 5: without retire_dead_crew the ghost stays aboard in the fold.
        events.write_text(before)
        self.assertEqual('dispatched', m.crew_last_events(self.repo)[ghost]['type'])
    def test_execute_child_prints_heartbeat_while_adapter_runs(self):
        attempt = self.repo / 'state/runs/worker-hb-t035-r1/cursor-agent-hb'
        attempt.mkdir(parents=True)
        adapter = self.repo / 'bin/adapters/slow.sh'
        adapter.parent.mkdir(parents=True, exist_ok=True)
        adapter.write_text('#!/usr/bin/env bash\nsleep 0.45\necho done >> "$4"\n')
        adapter.chmod(0o755)
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
            import io, contextlib
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = m.execute_child(attempt, fd)
        self.assertEqual(0, rc)
        text = buf.getvalue()
        self.assertIn('worker-hb-t035-r1 worker started on T-035', text)
        self.assertIn('still running', text)
        self.assertRegex(text, r'finished exit=0 after \d+s')

    def session_cli(self, *args):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        return subprocess.run(['bash', str(self.repo / 'bin/fm-session.sh'), *args, '--repo', str(self.repo)],
                              cwd=self.repo, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    def decision_files(self):
        state = self.repo / 'state'
        return {str(p.relative_to(state)): p.read_bytes()
                for folder in ('pending', 'decisions', 'session/observed')
                for p in sorted((state / folder).glob('*.json'))} | {'events.jsonl': (state / 'events.jsonl').read_bytes()}
    def test_unacknowledged_observed_decision_is_reported_until_ack(self):
        """T-041: a watcher only writes to disk; status must surface what firstmate has not acted on."""
        state = self.repo / 'state'
        for folder in ('pending', 'decisions', 'session/observed'): (state / folder).mkdir(parents=True, exist_ok=True)
        (state / 'events.jsonl').write_text('{"type":"decision_made","data":{"decision":"D-047"}}\n')
        (state / 'pending/D-047.json').write_text('{"id":"D-047","task":"T-041","kind":"choice"}')
        answer = dict(id='D-047', chosen='custom', text='hold until Friday', task='T-041', kind='choice',
                      ts='2026-09-23T08:00:00.000Z', identity='decision:D-047')
        (state / 'decisions/D-047.json').write_text(json.dumps(answer))
        m.save(state / 'session/observed/D-047.json',
               dict(status='observed', decision=answer, id='D-047', observed=1790000000.0))
        # Answered but never observed: not firstmate's acknowledgement backlog.
        (state / 'decisions/D-048.json').write_text('{"id":"D-048","chosen":"A","task":"T-040","kind":"merge"}')
        before = self.decision_files()

        status = self.session_cli('status')
        self.assertEqual(0, status.returncode, status.stderr)
        report = json.loads(status.stdout)
        self.assertEqual([dict(id='D-047', task='T-041', kind='choice', chosen='custom',
                               text='hold until Friday', ts='2026-09-23T08:00:00.000Z',
                               observed=1790000000.0)], report['unacknowledged'])
        self.assertRegex(status.stderr, r'(?s)1 captain decision.*D-047.*T-041.*custom.*hold until Friday')
        self.assertEqual(before, self.decision_files(), 'status must not consume or rewrite decisions')

        refused = self.session_cli('ack', '--decision', 'D-999')
        self.assertNotEqual(0, refused.returncode)
        self.assertIn('no observation for D-999', refused.stderr)
        self.assertFalse((state / 'session/acknowledged/D-999.json').exists())
        self.assertNotEqual(0, self.session_cli('ack').returncode, 'ack requires an explicit decision id')
        unobserved = self.session_cli('ack', '--decision', 'D-048')
        self.assertNotEqual(0, unobserved.returncode)
        self.assertIn('no observation for D-048', unobserved.stderr)

        acked = self.session_cli('ack', '--decision', 'D-047')
        self.assertEqual(0, acked.returncode, acked.stderr)
        receipt = state / 'session/acknowledged/D-047.json'
        self.assertEqual('D-047', json.loads(receipt.read_text())['id'])
        saved = receipt.read_bytes()
        self.assertEqual(before, self.decision_files(), 'ack must not delete observation, decision or event')
        again = self.session_cli('ack', '--decision', 'D-047')
        self.assertEqual(0, again.returncode, again.stderr)
        self.assertEqual(saved, receipt.read_bytes(), 'ack is idempotent')

        after = self.session_cli('status')
        self.assertEqual(0, after.returncode, after.stderr)
        self.assertEqual([], json.loads(after.stdout)['unacknowledged'])
        self.assertIn('no unacknowledged captain decisions', after.stderr)
        self.assertEqual(before, self.decision_files())
    def test_an_owned_decision_id_is_observed_listed_and_acknowledged(self):
        """T-047: an id naming its owner, D-<project>-<task>-<n>, wakes firstmate like D-<digits> does."""
        owned = 'D-firstmate-workflow-T047-1'
        state = self.repo / 'state'
        for folder in ('pending', 'decisions'): (state / folder).mkdir(parents=True, exist_ok=True)
        (state / 'events.jsonl').write_text('')
        (state / ('pending/%s.json' % owned)).write_text(json.dumps(
            dict(id=owned, task='T-047', kind='merge', pr=77, project='firstmate-workflow')))
        answer = dict(id=owned, chosen='A', task='T-047', kind='merge', pr=77, project='firstmate-workflow',
                      ts='2026-09-24T08:00:00.000Z', identity='decision:' + owned)
        (state / ('decisions/%s.json' % owned)).write_text(json.dumps(answer))
        # the continuous watcher firstmate starts: it finds the answer under the owned id
        first = m.watch_start(self.repo)
        receipt = state / ('session/observed/%s.json' % owned)
        try:
            for _ in range(80):
                if receipt.exists(): break
                time.sleep(.05)
            self.assertTrue(receipt.exists(), 'the watcher must observe an answer under an owned id')
            self.assertEqual(owned, json.loads(receipt.read_text())['id'])
            self.assertEqual('A', json.loads(receipt.read_text())['decision']['chosen'])
        finally: m.watch_stop(self.repo)
        # the per-decision watcher fm-decide.sh --await starts, keyed by the owned id
        one = m.watch_start(self.repo, owned)
        try:
            result = Path(one['directory']) / 'result.json'
            for _ in range(80):
                if result.exists(): break
                time.sleep(.05)
            self.assertEqual('observed', json.loads(result.read_text())['status'])
            self.assertEqual(owned, json.loads(result.read_text())['decision']['id'])
        finally: m.watch_stop(self.repo, owned)

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
    def start_with(self, config):
        """T-043: session start against a fixture that declares its own project contract."""
        import io, contextlib
        (self.repo / 'config.yaml').write_text(config)
        out = io.StringIO()
        with patch.object(m, 'board_start', return_value=dict(stub=True)) as board, \
             patch.dict(os.environ, {'FM_WATCH': '0'}), \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            rc = m.main(['session', 'start', str(self.repo)])
        return rc, json.loads(out.getvalue()), board
    def test_start_runs_declared_setup_once_and_reports_it(self):
        rc, report, board = self.start_with(
            'vendor: mock\nproject:\n  setup: echo ran >> setup-count && echo "it\'s done"\n  check: make test\n')
        self.assertEqual(0, rc)
        self.assertEqual('ran\n', (self.repo / 'setup-count').read_text(), 'setup runs exactly once, in the checkout')
        project = report['project']
        self.assertEqual(['setup', 'check'], project['declared'])
        self.assertEqual(0, project['setup']['exit'])
        self.assertTrue(project['ready'])
        self.assertTrue(board.called)
    def test_failed_setup_is_not_ready_and_never_aborts_startup(self):
        rc, report, board = self.start_with(
            'project:\n  setup: echo "lockfile is out of date" >&2; exit 4\n  check: make test\n')
        self.assertEqual(0, rc, 'a failed setup is reported, not fatal')
        self.assertTrue(board.called, 'the rest of startup still runs')
        self.assertEqual(dict(stub=True), report['board'])
        project = report['project']
        self.assertEqual(4, project['setup']['exit'])
        self.assertIn('lockfile is out of date', project['setup']['error'])
        self.assertFalse(project['ready'])
    def test_start_without_setup_runs_nothing(self):
        rc, report, _ = self.start_with('project:\n  check: make test\n')
        self.assertEqual(0, rc)
        self.assertEqual(['check'], report['project']['declared'])
        self.assertIsNone(report['project']['setup'])
        self.assertTrue(report['project']['ready'])
        self.assertFalse((self.repo / 'state/session/project-setup.log').exists())
    def test_start_without_check_is_not_ready(self):
        rc, report, _ = self.start_with('vendor: mock\n')
        self.assertEqual(0, rc)
        self.assertEqual([], report['project']['declared'])
        self.assertFalse(report['project']['ready'])
        self.assertIn('declares no project.check', report['project']['error'])
    def test_status_reports_contract_and_never_runs_setup(self):
        (self.repo / 'config.yaml').write_text('project:\n  setup: touch setup-ran\n  check: make test\n  tests:\n    - "*_test.go"\n')
        status = self.session_cli('status')
        self.assertEqual(0, status.returncode, status.stderr)
        project = json.loads(status.stdout)['project']
        self.assertEqual(['setup', 'check', 'tests'], project['declared'])
        self.assertIsNone(project['setup'], 'status reports; it does not run')
        self.assertFalse((self.repo / 'setup-ran').exists(), 'status never runs setup')
        self.assertFalse((self.repo / 'state/crew/rosters.json').exists(), 'status never draws a crew')
    def test_start_draws_the_crew_once_and_a_second_start_keeps_it(self):
        """T-104: the installation's crew is drawn the first time firstmate runs."""
        crew = self.repo / 'state/crew/rosters.json'
        with patch.dict(os.environ, {'FM_ROSTER_SEED': 'first'}):
            rc, report, _ = self.start_with('vendor: mock\n')
        self.assertEqual(0, rc)
        self.assertTrue(report['crew']['drawn_now'])
        drawn = json.loads(crew.read_text())
        self.assertEqual((24, 24), (len(drawn['workers']), len(drawn['reviewers'])))
        self.assertEqual([], [n for n in drawn['workers'] if n in drawn['reviewers']])
        self.assertEqual(drawn['workers'], report['crew']['workers'])
        saved = crew.read_bytes()
        with patch.dict(os.environ, {'FM_ROSTER_SEED': 'second'}):
            rc, report, _ = self.start_with('vendor: mock\n')
        self.assertEqual(0, rc)
        self.assertFalse(report['crew']['drawn_now'])
        self.assertEqual(saved, crew.read_bytes(), 'a second start keeps the same crew')
    def roster_cli(self, *args, seed='cli'):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        env['FM_ROSTER_SEED'] = seed
        return subprocess.run(['bash', str(self.repo / 'bin/fm.sh'), 'roster', *args, '--repo', str(self.repo)],
                              cwd=self.repo, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    def test_fm_roster_prints_draws_once_and_redraws_only_when_asked(self):
        crew = self.repo / 'state/crew/rosters.json'
        none = self.roster_cli()
        self.assertEqual(1, none.returncode, none.stderr)
        self.assertIn('no crew drawn yet; roster init draws one', none.stderr)
        self.assertFalse(crew.exists())
        init = self.roster_cli('init')
        self.assertEqual(0, init.returncode, init.stderr)
        drawn = json.loads(crew.read_text())
        self.assertIn('workers (24, drawn ' + drawn['drawn_at'] + '): ' + ' '.join(drawn['workers']), init.stdout)
        self.assertIn('reviewers (24, drawn ' + drawn['drawn_at'] + '): ' + ' '.join(drawn['reviewers']), init.stdout)
        saved = crew.read_bytes()
        again = self.roster_cli('init', seed='other')
        self.assertEqual(1, again.returncode, again.stderr)
        self.assertIn('already has a crew', again.stderr)
        self.assertIn('never redrawn unless you ask with --redraw', again.stderr)
        self.assertEqual(saved, crew.read_bytes())
        shown = self.roster_cli(seed='other')
        self.assertEqual(0, shown.returncode, shown.stderr)
        self.assertIn(' '.join(drawn['reviewers']), shown.stdout)
        self.assertEqual(saved, crew.read_bytes())
        redraw = self.roster_cli('init', '--redraw', seed='other')
        self.assertEqual(0, redraw.returncode, redraw.stderr)
        self.assertIn('Ranks and service records keyed by the old names stay with the old names', redraw.stdout)
        redrawn = json.loads(crew.read_text())
        self.assertNotEqual(drawn['workers'], redrawn['workers'])
        self.assertIn(' '.join(redrawn['workers']), redraw.stdout)
    def test_emit_status_is_board_path_not_pane_heartbeat(self):
        """T-036: pane text is board activity only after emit-status."""
        d = Path(tempfile.mkdtemp()); self.addCleanup(lambda: shutil.rmtree(d, ignore_errors=True))
        (d/'bin').mkdir(); (d/'state').mkdir()
        shutil.copy(root/'bin/fm-emit.sh', d/'bin/fm-emit.sh')
        shutil.copy(root/'bin/fm-herdr.py', d/'bin/fm-herdr.py')
        self.assertEqual(0, m.main(['emit-status','--root',str(d),'--actor','session-h',
            '--task','T-S','--role','worker','--en','pane heartbeat','--tw','窗格心跳']))
        ev = json.loads((d/'state/events.jsonl').read_text().splitlines()[0])
        self.assertEqual('crew_status', ev['type'])
        self.assertEqual('pane heartbeat', ev['data']['activity']['en'])
        self.assertNotIn('progress', ev.get('data', {}))
    def reviewer_report(self, config, mode='start'):
        """T-066: fm-session.sh itself, with the session engine stubbed out.

        `exec` keeps the pid, so the frozen-entry check passes without a
        snapshot, and the stub stands in for everything after the report."""
        (self.repo / 'bin/fm-herdr.py').write_text('import sys\nprint("stub " + " ".join(sys.argv[1:3]))\n')
        (self.repo / 'config.yaml').write_text(config)
        env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        return subprocess.run(
            ['bash', '-c', 'export FM_ENTRY_PID=$$ FM_ENTRY_SCRIPT=fm-session.sh; exec "$0" "$@"',
             str(self.repo / 'bin/fm-session.sh'), mode, '--repo', str(self.repo)],
            env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
    def test_start_reports_a_project_that_names_no_reviewer(self):
        for config, missing in [('vendor: claude\n', 'vendor and model'),
                                ('vendor: claude\nreviewer:\n  vendor: claude\n', 'model'),
                                ('reviewer:\n  model: opus-5\n', 'vendor')]:
            result = self.reviewer_report(config)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIn('stub session start', result.stdout, 'startup carries on after the report')
            self.assertIn('config.yaml names no reviewer ' + missing + ';', result.stderr, config)
            self.assertIn("the reviewer is the captain's choice", result.stderr)
            self.assertIn('installed adapters:', result.stderr)
    def test_start_is_quiet_when_the_reviewer_is_named(self):
        result = self.reviewer_report('reviewer:\n  vendor: claude\n  model: opus-5\n')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('stub session start', result.stdout)
        self.assertNotIn('names no reviewer', result.stderr)
        # and this repository names its own: claude and opus-5, the captain's choice
        result = self.reviewer_report((root / 'config.yaml').read_text())
        self.assertNotIn('names no reviewer', result.stderr)
    def test_status_does_not_repeat_the_reviewer_report(self):
        result = self.reviewer_report('vendor: claude\n', mode='status')
        self.assertIn('stub session status', result.stdout)
        self.assertNotIn('names no reviewer', result.stderr)

unittest.main(argv=['session'], verbosity=2)
PY
