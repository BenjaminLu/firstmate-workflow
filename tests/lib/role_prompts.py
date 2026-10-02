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
from crew_blocks import function, section

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
        (self.path/'config.yaml').write_text('default_project: private-app\nprojects:\n  private-app:\n    github: fixture/project\n    base: main\n    required_check: ci\n  firstmate-workflow:\n    repo: .\n    github: fixture/engine\n    base: main\n    required_check: ci\n')
        for project in ('', 'firstmate-workflow', 'private-app'):
            result = self.shell('FM_CONFIG="$2/config.yaml"; FM_PROJECT=' + project + '; BASE=trunk; TASK=T-052\n'
                                'fm_prompt_identity worker abc123 def456')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(project or 'private-app', result.stdout)
            for value in ('T-052', 'trunk', 'abc123', 'def456'):
                self.assertIn(value, result.stdout)
            self.assertIn('explicitly dispatched worker', result.stdout)

    def test_binding_delegates_without_unneeded_repository_lookup(self):
        body = function(root/'bin/fm-review.sh', 'verify_review_head')
        for external in ('0', '1'):
            result = self.shell('unset GH_REPO FM_PROJECT; FM_EXTERNAL=' + external + '; '
                                'PR=9; TASK=T-052; BRANCH=task; R_HEAD=reviewed\n'
                                'gh() { echo unexpected-repository-lookup >&2; return 99; }\n'
                                'fm_binding() { printf reviewed; }\n' + body + '\nverify_review_head')
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertNotIn('unexpected-repository-lookup', result.stderr)

    def test_unpinned_intro_does_not_require_pin_rendering(self):
        for role in ('worker', 'reviewer'):
            intro = section(root/('bin/fm-' + ('review' if role == 'reviewer' else role) + '.sh'),
                            '  cat "${FM_CODE_ROOT:-$REPO}/skills/' + role + '/SKILL.md"',
                            "  printf '\\n---\\n\\n#")
            result = self.shell('unset FM_SPEC_PIN_JSON; FM_EXTERNAL=0; REPO="$1"\n'
                                'fm_pin_prompt() { echo unexpected-pin-rendering >&2; return 65; }\n' + intro)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertNotIn('unexpected-pin-rendering', result.stderr)

    def test_absent_pin_is_optional_but_invalid_pin_refuses(self):
        result = self.shell('unset FM_SPEC_PIN_JSON; fm_pin_prompt worker')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('', result.stdout)
        result = self.shell("FM_SPEC_PIN_JSON='{'; fm_pin_prompt worker")
        self.assertEqual(65, result.returncode, result.stderr)

    def fetched_update(self, external, legacy=False):
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
        git('config', 'remote.origin.url', 'https://github.com/fixture/project.git')
        git('config', 'url.' + str(self.path) + '.insteadOf',
            'https://github.com/fixture/project.git')
        payload = dict(state='OPEN', headRefOid=remote, baseRefOid=base,
                       baseRefName='main', headRefName='task')
        (self.path/'remote.json').write_text(json.dumps(payload))
        gh = self.path/'gh'
        gh.write_text('#!/bin/sh\nif [ "$1 $2" = "repo view" ]; then echo fixture/project; exit 0; fi\ncat "' + str(self.path/'remote.json') + '"\n')
        gh.chmod(0o755)
        body = function(root/'bin/fm-review.sh', 'verify_review_head')
        result = self.shell('export FM_TARGET_ROOT="$2" FM_GH="$2/gh"; '
                            'GH_REPO=' + ('' if legacy else 'fixture/project') + '; FM_EXTERNAL=' + external + '; '
                            'PR=9; TASK=T-052; BRANCH=task; R_HEAD=' + stale + '\n' +
                            body + '\nverify_review_head || exit 65\n'
                            'printf adapter-started > "$2/adapter-started"')
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertIn('authoritative PR head differs', result.stderr)
        self.assertFalse((self.path/'adapter-started').exists())
        self.assertEqual(git('rev-parse', 'task'), stale)
        self.assertEqual(git('rev-parse', 'FETCH_HEAD'), remote)

    def test_external_fetched_update_refuses_stale_ref(self):
        self.fetched_update('1')

    def test_self_fetched_update_refuses_stale_ref(self):
        self.fetched_update('0')

    def test_legacy_binding_resolves_repository(self):
        self.fetched_update('0', legacy=True)

    def test_self_unknown_remote_refused_before_review(self):
        body = function(root/'bin/fm-review.sh', 'verify_review_head')
        # GitHub has advanced; the local ref still names the previous head.
        for external in ('0',):
            for binding in ('printf updated_remote_head', 'return 1'):
                result = self.shell('GH_REPO=fixture/project; FM_EXTERNAL=' + external + '; PR=9; TASK=T-052; '
                                    'BRANCH=task; R_HEAD=stale_local_head\n'
                                    'fm_binding() { ' + binding + '; }\n' + body +
                                    '\nverify_review_head')
                self.assertNotEqual(result.returncode, 0)

    def required_design(self, pinned):
        text = ('## 1. Introduction\n' + 'unrelated ' * 7000 +
                '\n## 6. Gates\nMANDATORY_GATES\n## 7. Standing list\nMANDATORY_LIST\n'
                '## 8. Board\n' + 'board detail ' * 7000 +
                '\n## Project features\n### T-052 task detail\nTASK_CONTEXT\n## Worker guidance\nWORKER_CONTEXT\n'
                '## Reviewer guidance\nREVIEWER_CONTEXT\n')
        self.pin['snapshots']['design']['text'] = text
        (self.path/'design.md').write_text(text)
        for role in ('worker', 'reviewer'):
            command = 'fm_pin_prompt ' + role if pinned else 'fm_prompt_design "$2/design.md" ' + role
            result = self.shell('TASK=T-052\n' + command)
            self.assertEqual(result.returncode, 0, result.stderr)
            for required in ('MANDATORY_GATES', 'MANDATORY_LIST', '## 8. Board',
                             'TASK_CONTEXT', role.upper() + '_CONTEXT', 'TRIMMED', 'sha256='):
                self.assertIn(required, result.stdout)

    def test_pinned_design_keeps_required_sections(self):
        self.required_design(True)

    def test_legacy_design_keeps_required_sections(self):
        self.required_design(False)

    def test_required_sections_over_cap_refuse_instead_of_trimming(self):
        text = '## 6. Gates\n' + 'mandatory ' * 5000 + '\n## 7. List\nKeep all rules\n'
        self.pin['snapshots']['design']['text'] = text
        result = self.shell('fm_pin_prompt worker')
        self.assertEqual(65, result.returncode, result.stderr)
        self.assertIn('required design sections exceed the cap', result.stderr)

if __name__ == '__main__':
    unittest.main(argv=['role-prompts', sys.argv[2]], verbosity=2)
