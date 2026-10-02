#!/usr/bin/env bash
# T-164: hook loading diagnostics and recoverable Codex context output.
set -uo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import call, patch
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(sys.argv[1]) / 'bin/lib'))
import fm_hooks as H
import fm_watch as W

class CodexHooks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='codex hooks ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'bin').mkdir()
        (self.root / 'bin/fm-watch-arm.sh').touch()
        self.env = patch.dict(os.environ, {k:v for k,v in os.environ.items() if not k.startswith('FM_')}, clear=True)
        self.env.start(); self.addCleanup(self.env.stop)

    def push(self, ident='D-T164-1', stamp=1):
        queue = self.root / W.life.WAKE_QUEUE
        queue.parent.mkdir(parents=True, exist_ok=True)
        with queue.open('a') as out:
            out.write(json.dumps(dict(id=ident, woken=stamp, reason='answered', decision={'chosen':'A'})) + '\n')

    def call(self, event='SessionStart', **payload):
        out = io.StringIO()
        with patch.object(W, 'payload', return_value=dict(hook_event_name=event, cwd=str(self.root), **payload)), patch.object(W.life, 'session_owner', return_value=123), patch.object(W, 'ensure') as ensure, contextlib.redirect_stdout(out):
            rc = W.guard(self.root, 'codex') if event == 'Stop' else W.turn_start(self.root, 'codex', event)
        self.assertEqual(0, rc)
        return out.getvalue(), ensure

    def test_install_is_scoped_idempotent_and_preserves_custom_hooks(self):
        path = self.root / '.codex/hooks.json'; path.parent.mkdir()
        custom = {'hooks': {'Stop': [{'hooks': [{'type':'command', 'command':'/other/bin/fm-turnend-guard.sh --hook codex'}]}]}, 'description':'custom'}
        path.write_text(json.dumps(custom))
        config = path.with_name('config.toml'); config.write_text('[features]\nhooks = false\n')
        H.hooks_change(self.root, 'codex', True)
        data = json.loads(path.read_text())
        self.assertIn('SessionStart', data['hooks'])
        self.assertEqual(custom['hooks']['Stop'][0], data['hooks']['Stop'][0])
        self.assertIn('--session-start codex', data['hooks']['SessionStart'][0]['hooks'][0]['command'])
        self.assertTrue(data['hooks']['SessionStart'][0]['hooks'][0]['command'].startswith("'"))
        before = path.read_bytes(); H.hooks_change(self.root, 'codex', True)
        self.assertEqual(before, path.read_bytes())
        H.hooks_change(self.root, 'codex', False)
        self.assertEqual(custom, json.loads(path.read_text()))
        self.assertEqual('[features]\nhooks = false\n', config.read_text())
        H.hooks_change(self.root, 'codex', False)
        self.assertEqual(custom, json.loads(path.read_text()))

    def test_discovery_layer_is_local_and_only_owned_content_is_removed(self):
        import subprocess
        repo = Path(sys.argv[1])
        (self.root / '.gitignore').write_bytes((repo / '.gitignore').read_bytes())
        subprocess.run(['git', 'init', '-q'], cwd=self.root, check=True, capture_output=True)
        ignored = subprocess.run(['git', '-c', 'core.excludesFile=/dev/null',
                                  'check-ignore', '--no-index', '.codex/config.toml'],
                                 cwd=self.root, capture_output=True, text=True)
        self.assertEqual(0, ignored.returncode, 'local operator configuration must remain uncommitted')
        H.hooks_change(self.root, 'codex', True)
        config = self.root / '.codex/config.toml'
        before = config.read_bytes()
        H.hooks_change(self.root, 'codex', True)
        self.assertEqual(before, config.read_bytes())
        H.hooks_change(self.root, 'codex', False)
        self.assertFalse(config.exists())
        H.hooks_change(self.root, 'codex', True)
        config.write_text(config.read_text() + '[features]\nhooks = false\n')
        modified = config.read_bytes()
        H.hooks_change(self.root, 'codex', False)
        self.assertEqual(modified, config.read_bytes())

    def test_capability_probe_distinguishes_disabled_missing_and_unavailable(self):
        import subprocess
        for output, expected in [('hooks stable true', 'enabled'),
                                 ('hooks stable false', 'disabled'), ('other stable true', 'unsupported')]:
            with patch.object(H.subprocess, 'run', side_effect=[
                    subprocess.CompletedProcess([], 0, stdout='codex-cli fixture'),
                    subprocess.CompletedProcess([], 0, stdout=output)]):
                self.assertEqual((expected, 'codex-cli fixture'), H.codex_capability(self.root))
        with patch.object(H.subprocess, 'run', side_effect=OSError('unavailable')):
            self.assertEqual(('unknown', 'unavailable'), H.codex_capability(self.root))

    def test_bounded_batches_do_not_acknowledge_hidden_context(self):
        for n in range(W.MAX_LINES + 1):
            self.push('D-batch-' + str(n), n + 1)
        self.push('D-batch-0', 1)
        first, _ = self.call()
        self.assertFalse(W.life.is_acknowledged(self.root, 'D-batch-' + str(W.MAX_LINES), W.MAX_LINES + 1))
        self.assertEqual(1, first.count('D-batch-0 '))
        second, _ = self.call()
        self.assertIn('D-batch-' + str(W.MAX_LINES), second)
        third, _ = self.call()
        self.assertEqual('', third)

    def test_later_wake_of_same_decision_survives_batch_boundary(self):
        self.push('D-repeat', 1)
        for n in range(W.MAX_LINES - 1):
            self.push('D-fill-' + str(n), n + 2)
        self.push('D-repeat', W.MAX_LINES + 1)
        first, _ = self.call()
        self.assertIn('D-repeat', first)
        self.assertFalse(W.life.is_acknowledged(self.root, 'D-repeat', W.MAX_LINES + 1))
        second, _ = self.call()
        self.assertIn('D-repeat', second)
        self.assertEqual('', self.call()[0])

    def test_shared_acknowledgement_never_covers_a_later_unseen_version(self):
        W.life.acknowledge(self.root, 'D-repeat', 1)
        self.assertFalse(W.life.is_acknowledged(self.root, 'D-repeat', 2))
        W.life.acknowledge(self.root, 'D-repeat', 2)
        W.life.acknowledge(self.root, 'D-repeat', 1)
        self.assertEqual(2, W.life.acknowledged(self.root, 'D-repeat'))

    def test_generations_and_competing_consumers_keep_later_same_id_wakes(self):
        W.save(W.wdir(self.root) / 'cursor', '0')
        self.push('D-repeat', 1)
        W.take(self.root, stage=1)
        self.push('D-repeat', 2)
        W.take(self.root, stage=2)
        base = W.wdir(self.root) / 'wake'
        for gen in (1, 2):
            (base / f'{gen}.staged').rename(base / f'{gen}.json')
        self.push('D-repeat', 3)
        self.assertEqual(2, len(W.claim(self.root)), 'both published generations must be returned')
        self.assertFalse(W.life.is_acknowledged(self.root, 'D-repeat', 3))
        self.assertIn('D-repeat', self.call()[0], 'a competing hook must still receive the queued version')
        self.assertEqual([], W.pending(self.root))
        self.push('D-repeat', 4)
        self.assertEqual(1, len(W.take(self.root)))
        self.push('D-repeat', 5)
        self.assertEqual(1, len(W.pending(self.root)), 'direct take must not acknowledge a future push')

    def test_live_earlier_generation_cannot_be_overtaken(self):
        W.save(W.wdir(self.root) / 'cursor', '0')
        with W.Locked(W.wdir(self.root) / 'handoff-1.lock'):
            self.push('D-repeat', 1)
            W.take(self.root, stage=1)
            self.push('D-repeat', 2)
            W.take(self.root, stage=2)
            base = W.wdir(self.root) / 'wake'
            (base / '2.staged').rename(base / '2.json')
            self.push('D-repeat', 3)
            self.assertEqual([], W.pending(self.root), 'later publication must not suppress the active earlier stage')
            self.assertFalse(W.life.is_acknowledged(self.root, 'D-repeat', 1))
        self.assertEqual(3, len(W.pending(self.root)))
        self.assertEqual([], W.pending(self.root))

    def test_abandoned_stage_recovers_in_legacy_pending_once(self):
        W.save(W.wdir(self.root) / 'cursor', '0')
        self.push()
        W.take(self.root, stage=1)
        with W.Locked(W.wdir(self.root) / 'handoff-1.lock'):
            self.assertEqual([], W.pending(self.root), 'a live publisher retains its stage')
        self.assertEqual(['card: D-T164-1 answered A'], W.pending(self.root),
                         'kernel lock release makes an interrupted stage recoverable')
        self.assertEqual([], W.pending(self.root))
        self.assertEqual(0, W.waiting(self.root))

    def test_failed_claim_ack_keeps_published_handoff_recoverable(self):
        for consumer in ('pending', 'codex', 'take'):
            with self.subTest(consumer=consumer):
                W.save(W.wdir(self.root) / 'cursor', '0')
                self.push('D-first-' + consumer, 1)
                self.push('D-second-' + consumer, 2)
                if consumer != 'take':
                    W.take(self.root, stage=1)
                    self.push('D-third-' + consumer, 3)
                    W.take(self.root, stage=2)
                real = W.life._write_ack
                calls = []
                def fail_later(path, record):
                    calls.append(path)
                    if len(calls) == 3:
                        raise SystemExit('interrupted after first durable acknowledgement')
                    return real(path, record)
                with patch.object(W.life, '_write_ack', side_effect=fail_later):
                    with self.assertRaises(SystemExit):
                        (W.take if consumer == 'take' else W.claim)(self.root)
                self.assertFalse(W.life.is_acknowledged(self.root, 'D-first-' + consumer, 1))
                if consumer == 'codex':
                    output, _ = self.call()
                    for name in ('first', 'second', 'third'):
                        self.assertIn('D-' + name + '-' + consumer, output)
                else:
                    lines = W.pending(self.root)
                    self.assertTrue(any('D-first-' + consumer in line for line in lines))
                    self.assertTrue(any('D-second-' + consumer in line for line in lines))
                    if consumer != 'take':
                        self.assertTrue(any('D-third-' + consumer in line for line in lines))
                self.assertEqual([], W.pending(self.root))

    def test_interrupted_batch_is_pending_in_session_status_and_wait(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('herdr', Path(sys.argv[1]) / 'bin/fm-herdr.py')
        session = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(session)
        self.push('D-first', 1)
        self.push('D-second', 2)
        W.take(self.root, stage=1)
        real = W.life._write_ack
        def interrupt(path, record):
            if str(path).endswith('/D-second.json'):
                raise OSError('interrupted second acknowledgement')
            real(path, record)
        with patch.object(W.life, '_write_ack', side_effect=interrupt):
            with self.assertRaises(OSError): W.claim(self.root)
        output = io.StringIO()
        with patch.object(session, 'window_host', return_value='none'), \
             patch.object(session, 'retire_dead_crew', return_value={}), \
             patch.object(session, 'project_report', return_value={}), \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            session.main(['session', 'status', str(self.root)])
        self.assertEqual(['D-first', 'D-second'],
                         [x['id'] for x in json.loads(output.getvalue())['unacknowledged']])
        self.assertEqual(['D-first'], [x['id'] for x in session.wake_wait(self.root, 'D-first', .01)])
        self.assertEqual(2, W.waiting(self.root))
        self.assertEqual(2, len(W.pending(self.root)))
        self.assertEqual([], session.unacknowledged(self.root))
        self.assertEqual([], session.wake_wait(self.root, 'D-first', .01))

    def test_watermark_snapshot_is_conservative_for_unknown_state(self):
        import fcntl
        W.life.acknowledge(self.root, 'D-first', 1)
        base = self.root / 'state/session'
        for value in ('{', '[]', 'null'):
            (base / '.ack-transaction.json').write_text(value)
            self.assertIsNone(W.life.acknowledged(self.root, 'D-first'))
        (base / '.ack-transaction.json').unlink()
        for value in (True, '1', float('inf'), float('nan'), -1):
            (base / 'acknowledged/D-first.json').write_text(json.dumps({'acknowledged': value}))
            self.assertIsNone(W.life.acknowledged(self.root, 'D-first'))
        with (base / '.ack.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.assertEqual({'D-first': None},
                             W.life.acknowledged_many(self.root, ['D-first'], blocking=False))

    def test_batch_failure_preserves_previous_watermarks_and_explicit_ack(self):
        W.life.acknowledge(self.root, 'D-first', 1)
        self.push('D-first', 2)
        self.push('D-second', 3)
        W.save(W.wdir(self.root) / 'cursor', '0')
        real = W.life._write_ack
        calls = []
        def fail_second(path, record):
            calls.append(path)
            if len(calls) == 3:
                raise OSError('second item failed')
            return real(path, record)
        with patch.object(W.life, '_write_ack', side_effect=fail_second):
            with self.assertRaises(OSError):
                W.pending(self.root)
        self.assertEqual(1, W.life.acknowledged(self.root, 'D-first'))
        W.life.acknowledge(self.root, 'D-unrelated', 4)
        self.assertEqual(1, W.life.acknowledged(self.root, 'D-first'))
        self.assertEqual(2, len(W.pending(self.root)))
        self.assertEqual([], W.pending(self.root))

    def test_legacy_context_does_not_hide_acknowledged_lines(self):
        lines = ['wake: D-' + str(n) for n in range(W.MAX_LINES + 1)]
        self.assertIn(lines[-1], W.wake_text(lines))

    def test_invalid_hooks_are_not_overwritten(self):
        path = self.root / '.codex/hooks.json'; path.parent.mkdir()
        for value in ({'hooks': []}, {'hooks': {'Stop': 'bad'}}):
            path.write_text(json.dumps(value)); before = path.read_bytes()
            with self.assertRaises(ValueError): H.hooks_change(self.root, 'codex', True)
            self.assertEqual(before, path.read_bytes())

    def evidence(self, trust='trusted'):
        _, entries = H.hook_config(self.root, 'codex')
        return {'data':[{'cwd':str(self.root), 'errors':[], 'warnings':[], 'hooks':[
            dict(eventName=event[0].lower()+event[1:], command=group['hooks'][0]['command'],
                 handlerType='command', source='project', sourcePath=str(self.root / '.codex/hooks.json'),
                 trustStatus=trust, enabled=True, currentHash='observed-definition', isManaged=False,
                 timeoutSec=group['hooks'][0]['timeout'], matcher=group.get('matcher'))
            for event, groups in entries.items() for group in groups]}]}

    def test_diagnostics_separate_loading_feature_trust_and_delivery(self):
        for trust in ('trusted', 'untrusted', 'modified'):
            result = H.codex_status(self.root, evidence=self.evidence(trust), feature='enabled', client='app-server')
            self.assertEqual('observed', result['loading'])
            self.assertEqual(trust, result['trust'])
            self.assertEqual(trust == 'trusted', result['ready'])
            self.assertEqual('unverified', result['delivery'])
            self.assertIn('/hooks', result['next_step'])
        result = H.codex_status(self.root, evidence=self.evidence(), feature='disabled', client='cli')
        self.assertFalse(result['ready'])
        self.assertIn('requirements.toml', result['next_step'])
        result = H.codex_status(self.root, evidence=self.evidence(), feature='enabled', client='unsupported')
        self.assertFalse(result['ready'])
        result = H.codex_status(self.root)
        self.assertEqual('unverified', result['loading'])
        self.assertFalse(result['ready'])
        changed = self.evidence(); changed['data'][0]['hooks'][0]['command'] += ' changed'
        self.assertEqual('missing-or-different', H.codex_status(self.root, evidence=changed)['loading'])

    def test_diagnostics_reject_policy_errors_and_disabled_or_different_handlers(self):
        evidence = self.evidence()
        evidence['data'][0]['errors'] = ['managed policy refuses project hooks']
        result = H.codex_status(self.root, evidence=evidence, feature='enabled', client='cli')
        self.assertFalse(result['ready'])
        self.assertIn('managed policy refuses project hooks', result['issues'])
        self.assertIn('allow_managed_hooks_only', result['next_step'])
        for field, value in [('enabled', False), ('timeoutSec', 999), ('async', True),
                             ('eventName', 'sessionEnd'), ('sourcePath', '/another/hooks.json')]:
            evidence = self.evidence()
            evidence['data'][0]['hooks'][0][field] = value
            result = H.codex_status(self.root, evidence=evidence, feature='enabled', client='cli')
            self.assertFalse(result['ready'], field)

    def test_startup_resume_and_turn_inject_queued_context_once(self):
        for source in ('startup', 'resume', 'compact'):
            self.push('D-' + source)
            out, ensure = self.call(source=source)
            self.assertIn('D-' + source, out)
            self.assertEqual('SessionStart', json.loads(out)['hookSpecificOutput']['hookEventName'])
            self.assertEqual([call(self.root, 123)], ensure.call_args_list)
            again, _ = self.call('UserPromptSubmit')
            self.assertEqual('', again)

    def test_stop_active_never_consumes_and_normal_stop_continues(self):
        self.push()
        out, _ = self.call('Stop', stop_hook_active=True)
        self.assertEqual('', out)
        self.assertFalse(W.life.is_acknowledged(self.root, 'D-T164-1', 1))
        out, _ = self.call('Stop', stop_hook_active=False)
        self.assertEqual('block', json.loads(out)['decision'])
        self.assertIn('D-T164-1', json.loads(out)['reason'])
        out, _ = self.call('Stop')
        self.assertEqual('', out)

    def test_failed_output_leaves_wake_recoverable(self):
        self.push()
        class Broken(io.StringIO):
            def flush(self): raise BrokenPipeError('harness disconnected')
        with patch.object(W, 'payload', return_value={'cwd':str(self.root)}), patch.object(W.life, 'session_owner', return_value=123), patch.object(W, 'ensure'), contextlib.redirect_stdout(Broken()):
            with self.assertRaises(BrokenPipeError): W.turn_start(self.root, 'codex', 'SessionStart')
        self.assertFalse(W.life.is_acknowledged(self.root, 'D-T164-1', 1))
        out, _ = self.call()
        self.assertIn('D-T164-1', out)

    def test_writer_stages_without_acknowledging_and_context_recovers(self):
        W.save(W.wdir(self.root) / 'cursor', '0')
        self.push()
        with W.Locked(W.wdir(self.root) / 'handoff-1.lock'):
            W.take(self.root, stage=1)
            self.assertFalse(W.life.is_acknowledged(self.root, 'D-T164-1', 1))
            self.assertEqual([], W.claim(self.root), 'staging must not publish before the successor holds the watch')
        self.assertEqual(1, W.waiting(self.root))
        out, _ = self.call()
        self.assertIn('D-T164-1', out)
        self.assertEqual([], W.pending(self.root), 'a legacy reader must not repeat the hook output')

    def test_cycle_publishes_only_after_successor_and_counts_queue_once(self):
        W.save(W.wdir(self.root) / 'cursor', '0')
        self.push()
        def successor(root, owner):
            self.assertEqual([], W.claim(root), 'a racing arm cannot claim the staged wake')
            self.assertFalse(W.life.is_acknowledged(root, 'D-T164-1', 1))
            W.save_json(W.wdir(root) / 'owner.json', dict(gen=2, owner=owner))
            W.journal(root, 'cycle 2 live')
        with patch.object(W.life, 'hold', return_value=123), patch.object(W, 'start_cycle', side_effect=successor), patch.object(W.os, 'dup2'), patch.object(W.signal, 'signal'), contextlib.redirect_stdout(io.StringIO()):
            W.cycle(self.root)
        records = [json.loads(p.read_text()) for p in (W.wdir(self.root) / 'wake').glob('*.json')]
        self.assertEqual(1, len(records))
        # The real board adds legacy display lines to unacknowledged queue
        # IDs. Structured records must carry only items, or it counts twice.
        self.assertEqual(0, sum(len(r.get('lines', [])) for r in records))
        self.assertEqual(1, W.waiting(self.root))
        self.assertNotIn('ended', W.read_json(W.wdir(self.root) / 'owner.json'))
        steps = (W.wdir(self.root) / 'journal').read_text()
        self.assertLess(steps.index('cycle 2 live'), steps.index('wake 1 written'))
        self.assertEqual(1, len(W.claim(self.root)))
        self.assertEqual(0, W.waiting(self.root))

    def test_owner_exit_during_handoff_records_end_before_beacon_closes(self):
        W.save(W.wdir(self.root) / 'cursor', '0')
        self.push()
        bell = W.life.Doorbell(self.root)
        self.addCleanup(bell.close)
        close = bell.close
        def check_close():
            self.assertIsNotNone(W.read_json(W.wdir(self.root) / 'owner.json').get('ended'),
                                 'the board must see the end time when the beacon closes')
            close()
        with patch.object(W.life, 'hold', return_value=123), patch.object(W.life, 'Doorbell', return_value=bell), patch.object(bell, 'close', side_effect=check_close), patch.object(W, 'start_cycle', side_effect=W.life.OwnerGone('session ended')), patch.object(W.os, 'dup2'), patch.object(W.signal, 'signal'), contextlib.redirect_stdout(io.StringIO()):
            W.cycle(self.root)
        self.assertFalse(W.cycle_live(self.root))
        self.assertIsNotNone(W.status(self.root)['ended'])
        self.assertFalse(W.life.is_acknowledged(self.root, 'D-T164-1', 1))
        self.assertIn('D-T164-1', self.call()[0])

    def test_stand_down_and_watcher_failure_preserve_pending(self):
        self.push()
        with patch.dict(os.environ, {'FM_IN_ROUND':'1'}):
            out, ensure = self.call()
            self.assertEqual('', out); self.assertEqual([], ensure.call_args_list)
        (self.root / 'state/away').touch()
        out, ensure = self.call(); self.assertEqual('', out); self.assertEqual([], ensure.call_args_list)
        (self.root / 'state/away').unlink()
        with patch.object(W, 'payload', return_value={'cwd':str(self.root)}), patch.object(W.life, 'session_owner', return_value=123), patch.object(W, 'ensure', side_effect=RuntimeError('watch timeout')):
            with self.assertRaises(RuntimeError): W.turn_start(self.root, 'codex', 'SessionStart')
        self.assertFalse(W.life.is_acknowledged(self.root, 'D-T164-1', 1))

unittest.main(argv=['codex-hooks'], verbosity=2)
PY
