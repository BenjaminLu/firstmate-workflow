"""T-185 fail-first assertions; no vendor or ambient repository access."""
import hashlib
import importlib.util
import json
import os
import subprocess
from unittest.mock import patch
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
from fm_evidence import Store
from fm_spec_preflight import require_ok, retain, prompt, decision
loader = importlib.util.spec_from_file_location('managed', ROOT / 'bin/fm-herdr.py')
managed = importlib.util.module_from_spec(loader)
loader.loader.exec_module(managed)


class Preflight(unittest.TestCase):
    def setUp(self):
        clean = patch.dict(os.environ, {'HERDR_ENV': '0'}, clear=True)
        clean.start(); self.addCleanup(clean.stop)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.store = Store(self.root / 'state', 'self', 'T-X', external=False)
        self.spec = b'{"id":"T-X","scope":["src/**"],"acceptance":["works"]}\n'
        self.sha = hashlib.sha256(self.spec).hexdigest()

    def record(self, data=None, verdict='SPEC-OK'):
        data = self.spec if data is None else data
        return retain(self.store, data, 'a' * 40, 'reviewer-noah-tx-r1', 1,
                      '1. Checked each acceptance line.\n' + verdict + ':T-X\n',
                      {'level': 'legacy', 'vendor': 'claude'})

    def test_preflight_does_not_consume_review_attempt(self):
        with patch.dict(os.environ, {'FM_SPEC_PREFLIGHT_MODE': '1'}):
            preflight = managed.allocate_identity(self.root, 'reviewer', 'T-X', '')
            second = managed.allocate_identity(self.root, 'reviewer', 'T-X', '')
        identity = json.loads((preflight / 'identity.json').read_text())
        self.assertEqual('spec-preflight', identity['mode'])
        self.assertEqual(2, json.loads((second / 'identity.json').read_text())['attempt'])
        review = managed.allocate_identity(self.root, 'reviewer', 'T-X', '')
        actual = json.loads((review / 'identity.json').read_text())
        self.assertEqual(1, actual['attempt'])
        self.assertEqual(1, actual['round'])
        self.assertTrue(actual['actor'].endswith('-r1'))

    def test_legacy_preflight_directory_does_not_consume_review_attempt(self):
        old = managed.allocate_identity(self.root, 'reviewer', 'T-X', '')
        (old / 'spec-preflight').mkdir()
        review = managed.allocate_identity(self.root, 'reviewer', 'T-X', '')
        identity = json.loads((review / 'identity.json').read_text())
        self.assertEqual(1, identity['attempt'])
        self.assertTrue(identity['actor'].endswith('-r1'))

    def test_first_round_missing_refuses_and_names_command(self):
        with self.assertRaisesRegex(ValueError, 'fm-review.sh --spec-preflight --task T-X --spec'):
            require_ok(self.store, self.spec)

    def test_other_bytes_refused_exact_bytes_accepted(self):
        self.record(self.spec + b' ')
        with self.assertRaises(ValueError):
            require_ok(self.store, self.spec)
        self.record()
        require_ok(self.store, self.spec)

    def test_require_reads_receipts_without_write_lock_or_directory_creation(self):
        self.record()
        lock = self.store.directory / '.lock'
        lock.unlink()
        lock.mkdir()  # writer fails here; a reader must ignore it
        with patch.object(Path, 'mkdir', side_effect=AssertionError('read attempted mkdir')):
            self.assertEqual('SPEC-OK', require_ok(self.store, self.spec)['verdict'])
        spec = self.root / 'spec.json'
        spec.write_bytes(self.spec)
        result = subprocess.run([sys.executable, str(ROOT / 'bin/lib/fm_spec_preflight.py'),
                                 'require', '--state', str(self.store.state), '--project', 'self',
                                 '--task', 'T-X', '--spec', str(spec)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(0, result.returncode, result.stderr)
        with self.assertRaises(IsADirectoryError):
            self.record()

    def test_repin_and_existing_inflight_pin_need_new_preflight(self):
        # Migration is fail-closed on next dispatch, even for an old pin.
        self.record()
        changed = self.spec + b'\n'
        with self.assertRaises(ValueError):
            require_ok(self.store, changed)
        self.record(changed)
        require_ok(self.store, changed)

    def test_gaps_cannot_be_waived_on_same_bytes(self):
        self.record(verdict='SPEC-GAPS')
        with self.assertRaises(ValueError):
            self.record()
        with self.assertRaises(ValueError):
            require_ok(self.store, self.spec)
        self.record(self.spec + b' ')
        require_ok(self.store, self.spec + b' ')

    def test_prompt_four_checks_and_closing_rule(self):
        body = prompt('T-X', self.spec, 'a' * 40)
        for part in ('declared scope', 'caller, mirror, fixture', 'ids, formats, paths',
                     'already in flight', 'migration', 'test', 'SPEC-OK:T-X', 'SPEC-GAPS:T-X'):
            self.assertIn(part, body)
        context = managed.role_context(ROOT, 'reviewer', 'T-X', 'reviewer-noah', body,
                                       spec_preflight=self.sha)
        self.assertNotIn('REVIEWER_COMPLETE', context)
        self.assertNotIn('APPROVE:T-X', context)
        self.assertIn('SPEC-OK:T-X', context)

    def test_vendor_final_and_strict_mode_separation(self):
        final = '1. Covered.\nSPEC-OK:T-X'
        transcript = self.root / 'cli.log'
        transcript.write_text('\n'.join(json.dumps(row) for row in [
            {'type': 'thread.started', 'thread_id': 't'},
            {'type': 'turn.started'},
            {'type': 'item.completed', 'item': {'id': 'a', 'type': 'agent_message', 'text': final}},
            {'type': 'turn.completed', 'usage': {'input_tokens': 1, 'output_tokens': 1}}]))
        self.assertEqual(final, managed.cli_final('codex', transcript))
        self.assertEqual('completed', managed.completion('reviewer', 'T-X', final, self.sha))
        self.assertEqual('completed', managed.completion('reviewer', 'T-X', final.replace('OK', 'GAPS'), self.sha))
        self.assertEqual('unknown', managed.completion('reviewer', 'T-X', final))
        self.assertEqual('unknown', managed.completion('reviewer', 'T-X', 'REVIEWER_COMPLETE:T-X', self.sha))
        self.assertEqual('completed', managed.completion('reviewer', 'T-X', 'REVIEWER_COMPLETE:T-X'))
        for invalid in ('SPEC-OK:T-X', '1. x\n> SPEC-OK:T-X', '1. x\nSPEC-OK:T-Y',
                        '1. x\nSPEC-OK:T-X\nafter', '1. x\n```\nSPEC-OK:T-X'):
            self.assertIsNone(decision(invalid, 'T-X'))

    def test_readonly_policy_covers_whole_checkout_on_both_platforms(self):
        from fm_sandbox_policy import darwin, linux
        policy = dict(never_read=[], repo_config=[], review_root_readonly=True,
                      review_git_readonly=True)
        roots = [str(self.root / 'checkout'), str(self.root / 'tmp')]
        mac = darwin(policy, roots, [], {}, '', [])
        self.assertIn('(deny file-write* (subpath "' + roots[0] + '"))', mac)
        linux_args = linux(policy, roots, [], {}, '').splitlines()
        at = linux_args.index(roots[0])
        self.assertEqual('--ro-bind', linux_args[at - 1])
        at = linux_args.index(roots[1])
        self.assertEqual('--bind', linux_args[at - 1])
        policy['review_root_readonly'] = False
        ordinary = linux(policy, roots, [], {}, '').splitlines()
        self.assertEqual('--bind', ordinary[ordinary.index(roots[0]) - 1])

    def test_receipt_is_private_to_project_and_signed(self):
        self.record()
        other = Store(self.root / 'state', 'other', 'T-X', external=False)
        with self.assertRaises(ValueError):
            require_ok(other, self.spec)
        path = next(self.store.directory.glob('*.json'))
        record = json.loads(path.read_text()); record['spec_sha256'] = 'b' * 64
        path.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'forged or modified'):
            require_ok(self.store, self.spec)

    def test_authenticated_selector_keeps_provenance_and_mode_binding(self):
        run = self.root / 'run'; attempt = run / 'codex-one'; attempt.mkdir(parents=True)
        answer = '1. Covered.\nSPEC-OK:T-X'
        (attempt / 'final.txt').write_text(answer)
        env = dict(FM_ACTOR='reviewer-noah', FM_TASK='T-X', FM_ROLE='reviewer',
                   FM_SPEC_PREFLIGHT=self.sha)
        invocation = dict(actor=env['FM_ACTOR'], task='T-X', role='reviewer', spec_preflight=self.sha)
        result = dict(invocation, attempt=str(attempt), chain_attempt='one',
                      final_source='codex-json-completed-turn',
                      final_sha256=hashlib.sha256(answer.encode()).hexdigest())
        def write():
            (attempt / 'invocation.json').write_text(json.dumps(invocation))
            (run / 'last-result.json').write_text(json.dumps(result))
        write()
        self.assertEqual(answer, managed.review_final(run, 'one', env))
        self.assertEqual('', managed.review_final(run, 'two', env))
        self.assertEqual('', managed.review_final(run, 'one', dict(env, FM_SPEC_PREFLIGHT='b' * 64)))
        self.assertEqual('', managed.review_final(run, 'one', {k: v for k, v in env.items() if k != 'FM_SPEC_PREFLIGHT'}))
        result['final_source'] = 'file'; write()
        self.assertEqual('', managed.review_final(run, 'one', env))
        result['final_source'] = 'codex-json-completed-turn'; write()
        (attempt / 'final.txt').write_text(answer + '\n')
        self.assertEqual('', managed.review_final(run, 'one', env))


if __name__ == '__main__':
    unittest.main(verbosity=2)
