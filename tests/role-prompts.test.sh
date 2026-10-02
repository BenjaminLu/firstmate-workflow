#!/usr/bin/env bash
# T-052 portable launcher context. Shared blocks: tests/lib/crew_blocks.py
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib.sh"
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
sys.dont_write_bytecode = True
root = Path(sys.argv[1])
sys.path.insert(0, str(root / 'tests/lib'))
from crew_blocks import function

class Prompts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('FM_', 'HERDR_', 'GIT_'))}
        self.pin = {'project': 'private-app', 'task': 'T-052', 'version': 1,
                    'contract': {'setup': 'approved setup', 'check': 'approved check',
                                 'check_env': {'LIMIT': '600'}, 'tests': ['tests/**'],
                                 'test': 'approved test', 'docs': ['docs/**'],
                                 'future_field': {'keep': True}},
                    'snapshots': {'design': {'text': 'design'},
                                  'conventions': {'text': 'whole conventions\n'}}}

    def shell(self, body):
        (self.path/'pin.json').write_text(json.dumps(self.pin))
        return subprocess.run(['bash', '-uc', '. "$1/bin/fm-config.sh"\n'
                               'FM_SPEC_PIN_JSON="$(cat "$2/pin.json")"\n' + body,
                               '_', str(root), str(self.path)], env=self.env,
                              capture_output=True, text=True, timeout=30)

    def test_design_is_bounded_without_trimming_contract_or_conventions(self):
        self.pin['snapshots']['design']['text'] = '船' * 40000 + 'DESIGN_END'
        conventions = 'conventions whole\n' * 7000 + 'CONVENTIONS_END'
        self.pin['snapshots']['conventions']['text'] = conventions
        result = self.shell('fm_pin_prompt')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Design cap: 48000 UTF-8 bytes', result.stdout)
        self.assertIn('TRIMMED', result.stdout)
        self.assertNotIn('DESIGN_END', result.stdout)
        self.assertIn(conventions, result.stdout)
        self.assertIn('future_field', result.stdout)
        self.assertIn('approved check', result.stdout)
        design = result.stdout.split('# Approved design\n\n')[1].split('# Approved CONVENTIONS.md')[0]
        self.assertLess(len(design.encode()), 49000)
        self.assertNotIn('\ufffd', design)

    def test_small_design_and_legacy_design_use_same_cap(self):
        result = self.shell('fm_pin_prompt')
        self.assertIn('design', result.stdout)
        self.assertNotIn('TRIMMED', result.stdout)
        (self.path/'design.md').write_text('plain project design without engine headings')
        result = self.shell('fm_prompt_design "$2/design.md"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('plain project design without engine headings', result.stdout)
        self.assertIn('48000 UTF-8 bytes', result.stdout)

    def test_run_mode_contract_uses_pin_over_target_config(self):
        (self.path/'config.yaml').write_text('project:\n  check: MUTABLE_BRANCH_CHECK\n')
        body = function(root/'bin/fm-review.sh', 'contract_line')
        result = self.shell('CHECKOUT="$2"\n' + body + '\ncontract_line check')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('approved check', result.stdout)
        self.assertNotIn('MUTABLE_BRANCH_CHECK', result.stdout)

    def test_context_identity_for_self_default_explicit_and_external(self):
        for project in ('', 'firstmate-workflow', 'private-app'):
            result = self.shell('FM_PROJECT=' + project + '; BASE=trunk; TASK=T-052\n'
                                'fm_prompt_identity worker abc123 def456')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(project or 'firstmate-workflow', result.stdout)
            for value in ('T-052', 'trunk', 'abc123', 'def456'):
                self.assertIn(value, result.stdout)
            self.assertIn('explicitly dispatched worker', result.stdout)

    def test_real_fetched_remote_update_branch_refuses_stale_local_ref(self):
        # Real object/ref transport; GitHub's JSON is the only stand-in.
        def git(*args):
            return subprocess.check_output(['git', '-C', str(self.path), *args],
                                           env=self.env, stderr=subprocess.DEVNULL,
                                           text=True).strip()
        git('init', '-q', '-b', 'main')
        commit = ['-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Fixture',
                  '-c', 'user.email=fixture@example.invalid', 'commit', '-qm']
        git(*commit, 'base', '--allow-empty')
        base = git('rev-parse', 'HEAD')
        git('checkout', '-qb', 'task')
        (self.path/'feature').write_text('original')
        git('add', 'feature'); git(*commit, 'task change')
        stale = git('rev-parse', 'HEAD')
        git('checkout', '-qb', 'updated')
        (self.path/'feature').write_text('updated by remote')
        git('add', 'feature'); git(*commit, 'remote update-branch')
        remote = git('rev-parse', 'HEAD')
        git('update-ref', 'refs/pull/9/head', remote)
        git('checkout', '-q', 'main')
        git('config', 'url.' + str(self.path) + '.insteadOf',
            'https://github.com/fixture/project.git')
        payload = dict(state='OPEN', headRefOid=remote, baseRefOid=base,
                       baseRefName='main', headRefName='task')
        (self.path/'remote.json').write_text(json.dumps(payload))
        gh = self.path/'gh'
        gh.write_text('#!/bin/sh\ncat "' + str(self.path/'remote.json') + '"\n')
        gh.chmod(0o755)
        body = function(root/'bin/fm-review.sh', 'verify_review_head')
        result = self.shell('export FM_TARGET_ROOT="$2" FM_GH="$2/gh"; '
                            'GH_REPO=fixture/project; FM_EXTERNAL=1; '
                            'PR=9; TASK=T-052; BRANCH=task; R_HEAD=' + stale + '\n' +
                            body + '\nverify_review_head || exit 65\n'
                            'printf adapter-started > "$2/adapter-started"')
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertIn('authoritative PR head differs', result.stderr)
        self.assertFalse((self.path/'adapter-started').exists())
        self.assertEqual(git('rev-parse', 'task'), stale)
        self.assertEqual(git('rev-parse', 'FETCH_HEAD'), remote)

    def test_external_remote_update_branch_refused_before_review(self):
        body = function(root/'bin/fm-review.sh', 'verify_review_head')
        # GitHub has advanced; the local ref still names the previous head.
        for external in ('1',):
            for binding in ('printf updated_remote_head', 'return 1'):
                result = self.shell('FM_EXTERNAL=' + external + '; PR=9; TASK=T-052; '
                                    'BRANCH=task; R_HEAD=stale_local_head\n'
                                    'fm_binding() { ' + binding + '; }\n' + body +
                                    '\nverify_review_head')
                self.assertNotEqual(result.returncode, 0)

unittest.main(argv=['role-prompts'], verbosity=2)
PY
assert_eq 0 "$?" 'portable prompts bound design and preserve approved authority'
finish
