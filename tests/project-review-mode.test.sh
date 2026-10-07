#!/usr/bin/env bash
# T-240: private review mode through real selection and checkout blocks.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# Literal shared dependency: tests/lib/crew_blocks.py
python3 - "$ROOT" <<'PY'
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
sys.dont_write_bytecode = True
root = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(root / 'tests/lib'))
from crew_blocks import function, section, shell
review = root / 'bin/fm-review.sh'

class ProjectReviewMode(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        (self.home / 'state').mkdir()
        self.private = self.home / 'state/config.yaml'
        self.repo = self.home / 'target'
        self.repo.mkdir()
        def git(*args):
            return subprocess.check_output(['git', '-C', str(self.repo), *args], text=True).strip()
        git('init', '-q', '-b', 'main')
        git('config', 'user.name', 'Fixture')
        git('config', 'user.email', 'fixture@example.invalid')
        (self.repo / 'value').write_text('base')
        git('add', '.'); git('commit', '-qm', 'base')
        self.base = git('rev-parse', 'HEAD')
        (self.repo / 'value').write_text('head')
        git('commit', '-qam', 'head')
        self.head = git('rev-parse', 'HEAD')
        (self.home / 'policy.json').write_text('{"network":[]}')
        (self.home / 'adapter').write_text('#!/bin/sh\nprintf "mode=%s\\ncheckout=%s\\n" "${FM_RUN_REVIEW:-}" "${FM_REVIEW_CHECKOUT:-}"\n')

    def run_mode(self, engine, private, external=True):
        (self.home / 'config.yaml').write_text('reviewer:\n  mode: ' + engine + '\n')
        self.private.write_text('project:\n  setup: touch should-not-run\n  check: touch should-not-run\n  test: touch should-not-run {file}\n' +
                                ('reviewer:\n  mode: ' + private + '\n' if private is not None else ''))
        if private == '__missing__':
            self.private.unlink()
        body = section(review, '# Read from the checkout running the round', "# The round's permission policy")
        body += function(review, 'build_checkout')
        body += section(review, 'if [ "$REVIEW_MODE" = run ]; then\n  emit_status "Preparing', '\n# A round that produced nothing')
        body += '\nbash "$work/adapter"\n'
        prefix = ('FM_EXTERNAL=' + ('1' if external else '0') + '; BRANCH=task; '
                  'FM_TARGET_ROOT="$work/target"; REVIEW_TMP="$work"; FM_RUN_DIR="$work"; '
                  'policy_file="$work/policy.json"; R_HEAD=' + self.head + '; R_BASE=' + self.base + '; R_PATCH=patch; '
                  'export FM_RUN_REVIEW=stale FM_REVIEW_CHECKOUT=stale; sweep_checkouts() { :; };\n')
        return shell(root, self.home, body, prefix)

    def test_private_diff_overrides_engine_run_without_checkout_or_commands(self):
        result = self.run_mode('run', 'diff')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('mode=\ncheckout=\n', result.stdout)
        self.assertEqual([], list(self.home.glob('fm-review.*')))
        self.assertEqual([], list(self.home.rglob('should-not-run')))

    def test_private_run_overrides_engine_diff_with_pinned_checkout(self):
        result = self.run_mode('diff', 'run')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('mode=1\n', result.stdout)
        checkout = Path(result.stdout.split('checkout=', 1)[1].strip())
        self.assertEqual('head', (checkout / 'value').read_text())
        self.assertEqual(self.head, subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip())

    def test_invalid_private_names_its_file(self):
        result = self.run_mode('diff', 'invalid')
        self.assertEqual(65, result.returncode)
        self.assertIn(str(self.private), result.stderr)
        self.assertIn('must be diff or run', result.stderr)

    def test_missing_private_mode_uses_engine_and_self_ignores_private(self):
        for private, external in [(None, True), ('', True), ('__missing__', True), ('run', False)]:
            result = self.run_mode('diff', private, external)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual('mode=\ncheckout=\n', result.stdout)

unittest.main(argv=['project-review-mode'], verbosity=2)
PY
assert_eq 0 "$?" 'private review mode selects diff/run, fallback and precise refusal'
finish
