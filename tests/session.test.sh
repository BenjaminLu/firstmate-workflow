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
            # The shared settings reader is a foreground bash subprocess.
            if args[0][0] != 'bash': children.append(child)
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
    def start_with(self, config):
        """T-043: session start against a fixture that declares its own project contract."""
        import io, contextlib
        (self.repo / 'config.yaml').write_text(config)
        out = io.StringIO()
        with patch.object(m, 'board_start', return_value=dict(stub=True)) as board, \
             patch.dict(os.environ, {'FM_SESSION_PID': str(os.getpid())}), \
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
    def test_start_reports_a_model_the_vendor_does_not_accept(self):
        """T-127: a missing model was already reported; an unrecognised one
        is too - opus-5 is not a name claude accepts, only a name it fell
        back to before the model was applied at all."""
        result = self.reviewer_report('reviewer:\n  vendor: claude\n  model: opus-5\n')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("reviewer model 'opus-5' is not one claude is known to accept", result.stderr)
        self.assertNotIn('names no reviewer', result.stderr)
    def test_start_is_quiet_about_a_model_the_vendor_does_accept(self):
        for model in ['claude-opus-5-5', 'opus', 'claude-sonnet-5']:
            result = self.reviewer_report('reviewer:\n  vendor: claude\n  model: ' + model + '\n')
            self.assertNotIn('is not one claude is known to accept', result.stderr, model)
        # this repository's own config names one claude accepts
        result = self.reviewer_report((root / 'config.yaml').read_text())
        self.assertNotIn('is not one claude is known to accept', result.stderr)
    def test_start_reports_the_worker_model_too(self):
        result = self.reviewer_report('vendor: claude\nmodel: opus-5\nreviewer:\n  vendor: claude\n  model: claude-opus-5-5\n')
        self.assertIn("worker model 'opus-5' is not one claude is known to accept", result.stderr)
    def test_start_checks_the_worker_vendor_and_model_that_actually_run(self):
        """T-146: the worker's own vendor, not the top-level one, paired with
        that vendor's model - here claude and models.claude, under a codex
        top level, so the check that used to ask codex (no catalogue, quiet)
        now asks claude about the name claude would be handed."""
        result = self.reviewer_report('vendor: codex\nmodels:\n  claude: opus-5\n  codex: gpt-6-astra\n'
                                      'worker:\n  vendor: claude\n'
                                      'reviewer:\n  vendor: claude\n  model: claude-opus-5-5\n')
        self.assertIn("worker model 'opus-5' is not one claude is known to accept", result.stderr)
    def test_start_is_quiet_about_a_vendor_with_no_offline_catalogue(self):
        """T-127: fm_model_known returns 2 (no catalogue) for a vendor other
        than claude - not 1 (not known) - and a config check that reads that
        as any nonzero code would wrongly warn about every codex/cursor-agent
        /gemini model, however real, that it simply cannot check."""
        for config in ('vendor: codex\nmodel: o1\nreviewer:\n  vendor: claude\n  model: claude-opus-5-5\n',
                       'vendor: claude\nmodel: claude-opus-5-5\nreviewer:\n  vendor: cursor-agent\n  model: gpt-5\n'):
            result = self.reviewer_report(config)
            self.assertNotIn('is not one', result.stderr, config)
    def test_status_does_not_repeat_the_reviewer_report(self):
        result = self.reviewer_report('vendor: claude\n', mode='status')
        self.assertIn('stub session status', result.stdout)
        self.assertNotIn('names no reviewer', result.stderr)

unittest.main(argv=['session'], verbosity=2)
PY
