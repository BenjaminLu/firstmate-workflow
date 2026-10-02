#!/usr/bin/env bash
# The pure assembler uses the same five components as the stock launcher.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HELPER = Path(sys.argv.pop()) / 'bin/lib/fm_review_context.py'

class Context(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "checkout/.git").mkdir(parents=True)
        self.parts = dict(intro='Reviewer instructions\nTask acceptance\n',
                          history='', evidence='Head SHA: ' + 'a'*40 + '\n',
                          diff='\n---\n\n# The diff under review\n\n```diff\nsmall\n```\n', outro='Run mode\n')
        self.pins = dict(head='a'*40, base='b'*40, patch='c'*40, files=['src/large.txt'])

    def compose(self, mode='run'):
        for key, value in self.parts.items():
            (self.root / (key + '.md')).write_text(value)
        (self.root / 'pins.json').write_text(json.dumps(self.pins))
        return subprocess.run([sys.executable, str(HELPER), str(self.root), mode,
                               str(self.root / 'checkout')], capture_output=True, text=True)

    def comment(self, number, body):
        return (f'\n## Closed list {number} of 80, verbatim from the pull request\n\n'
                f'----- begin comment abcd1234 -----\n{body}\n'
                '----- end comment abcd1234 -----\n')

    def test_small_is_byte_identical(self):
        result = self.compose()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root/'prompt.md').read_text(), ''.join(self.parts.values()))

    def local_history(self, bodies):
        # Consume the writer's actual framing, including per-record nonces.
        # Shared implementation: bin/lib/fm_evidence.py
        sys.path.insert(0, str(HELPER.parent))
        from fm_evidence import Store
        store = Store(self.root / 'state', 'self', 'T-130')
        for number, body in enumerate(bodies, 1):
            store.append('verdict', number, 'reviewer-fixture', 'a' * 40,
                         body, verdict='REJECT', provenance={'level': 'legacy'})
        return store.history(reviewer=True)

    def test_local_history_repeats_compact_without_losing_identity_or_criteria(self):
        original = '1. open ORIGINAL acceptance\nCRITERIA-COMPLETE:T-130\nREJECT:T-130'
        later = '1. done ORIGINAL acceptance\n2. open NEW-GROUND:T-130 new detail\nCRITERIA-COMPLETE:T-130\nREJECT:T-130'
        self.parts['history'] = self.local_history([original, later, original, later, original])
        self.parts['diff'] = '+oversized\n' * 100000
        result = self.compose()
        self.assertEqual(0, result.returncode, result.stderr)
        prompt = (self.root / 'prompt.md').read_text()
        self.assertIn('exact repeat', prompt)
        self.assertEqual(2, prompt.count(original))
        self.assertEqual(2, prompt.count(later))
        for number in range(1, 6):
            self.assertIn(f'Local review round {number}, head ' + 'a' * 40, prompt)
        self.assertEqual(5, prompt.count('reviewer reviewer-fixture, provenance legacy'))
        archive = Path((self.root / 'evidence-path.txt').read_text())
        self.assertEqual(self.parts['history'], (archive / 'history.md').read_text())

    def test_distinct_local_criteria_are_never_trimmed_to_fit(self):
        self.parts['history'] = self.local_history([
            '1. ' + 'criterion ' * 70000 + '\nCRITERIA-COMPLETE:T-130\nREJECT:T-130'])
        result = self.compose()
        self.assertEqual(65, result.returncode, result.stderr)
        self.assertFalse((self.root / 'prompt.md').exists())

    def test_t130_oversize_repeats_stale_lists_and_ci(self):
        original = '1. ORIGINAL acceptance\n2. Preserve evidence\nCRITERIA-COMPLETE:T-130\nREJECT:T-130'
        later = '1. **done** ORIGINAL acceptance\n2. **open** Preserve evidence\n3. REGRESSION:T-130 new detail\n  continuation must survive\nCRITERIA-COMPLETE:T-130\nREJECT:T-130'
        self.parts['history'] = self.comment(1, original)
        self.parts['history'] += ''.join(self.comment(i, later if i % 2 == 0 else original) for i in range(2,81))
        self.parts['evidence'] += ('----- begin log deadbeef -----\n' + 'assert FAIL\n'*10000
                                   + '----- end log deadbeef -----\n')
        # Observed stock T-130 request: 2,719,034 characters; reproduce its size
        # and source classes, without pretending this synthetic fixture is a log.
        remaining = 2719034 - sum(len(x) for k,x in self.parts.items() if k != 'diff')
        self.parts['diff'] = '+x\n'*(remaining//3) + 'x'*(remaining%3)
        self.assertEqual(sum(map(len,self.parts.values())),2719034)
        result = self.compose()
        self.assertEqual(result.returncode,0,result.stderr)
        prompt = (self.root/'prompt.md').read_text()
        self.assertLessEqual(len(prompt.encode()),512*1024)
        self.assertIn(original,prompt)
        self.assertIn(later,prompt)
        self.assertIn('REJECT:T-130',prompt)
        self.assertIn('exact repeat',prompt)
        self.assertIn('OMITTED',prompt)
        self.assertIn('git diff',prompt)
        for value in (self.pins['head'],self.pins['base'],self.pins['patch']):
            self.assertIn(value,prompt)
        self.assertIn('src/large.txt',prompt)
        self.assertTrue((self.root/'evidence.md').read_text().endswith('----- end log deadbeef -----\n'))
        self.assertEqual(self.compose('diff').returncode,65)
        self.assertFalse((self.root/'prompt.md').exists())

    def test_archive_refuses_redirected_git_directory(self):
        self.parts['diff'] = '+oversized\n' * 100000
        git_dir = self.root / 'checkout/.git'
        git_dir.rmdir()
        outside = self.root / 'outside'
        outside.mkdir()
        git_dir.symlink_to(outside, target_is_directory=True)
        result = self.compose()
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertFalse((self.root / 'prompt.md').exists())
        self.assertEqual(list(outside.iterdir()), [])

    def test_distinct_criteria_are_never_trimmed_to_fit(self):
        self.parts['history'] = self.comment(1,'1. ' + 'criterion '*70000 + '\nCRITERIA-COMPLETE:T-130\nREJECT:T-130')
        result = self.compose()
        self.assertEqual(result.returncode,65,result.stderr)
        self.assertIn('cannot represent',result.stderr)
        self.assertFalse((self.root/'prompt.md').exists())

    def test_unicode_byte_cap_and_no_ci_fence_corruption(self):
        self.parts['evidence'] += '----- begin fail-first report 1234abcd -----\n' + '失敗\n'*200000 + '----- end fail-first report 1234abcd -----\n'
        result = self.compose()
        self.assertEqual(result.returncode,0,result.stderr)
        prompt = (self.root/'prompt.md').read_text()
        self.assertLessEqual(len(prompt.encode()),512*1024)
        self.assertIn('----- end fail-first report 1234abcd -----',prompt)
        self.assertIn('sha256=',prompt)

unittest.main()
PY
