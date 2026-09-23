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
from unittest.mock import patch

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
        try:
            with patch.dict(os.environ,{'FM_PORT':str(port)}), \
                 patch.object(m.shutil,'which',side_effect=lambda name: bun if name=='bun' else None), \
                 patch.object(m.subprocess,'Popen',side_effect=spawn):
                first=m.board_start(self.repo)
                self.assertFalse(first['reused']); self.assertTrue(first['page_http_verified'])
                second=m.board_start(self.repo)
                self.assertTrue(second['reused']); self.assertEqual(1,len(children))
                other=self.repo/'other'; other.mkdir()
                with self.assertRaisesRegex(RuntimeError,'unverified root'): m.board_start(other)
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

unittest.main(argv=['session'], verbosity=2)
PY
