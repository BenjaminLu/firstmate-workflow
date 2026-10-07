"""External PR formatting and CI checklist regression cases (T-247)."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

os.environ['HERDR_ENV'] = '0'

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'bin/lib'), str(ROOT / 'tests/lib')]
from crew_blocks import section
import fm_conventions as conventions
import fm_onboard as onboard
from fm_public_text import validate
from fm_spec_preflight import prompt

FORMAT = dict(pr_title='conventional', pr_sections=['Summary', 'Changes', 'Testing', 'AI 参与度'], pr_language='en')
SPEC = dict(id='T-051', title='Private plan', scope=['widget'], acceptance=['Private reason'],
            public_title='fix(api): deduct the fee', public_summary='Deduct the fee.',
            public_changes=['Add a fee check.'])
POLICY = dict(repository='fixture/app', base='main', land='card', review='fm', post='local',
              merge_method='squash', stacking='hold', confirmed=True, policy_confirmed=True,
              delete_branch=True, force_with_lease=False, required_checks=['CI'], analysers=[],
              captain='fixture', intent='Use this policy', product='fixture', confirmed_at='2026-10-07',
              watch_seconds=60, debounce_seconds=60, reinspect_seconds=60,
              available_merge_methods=['squash'], protection={'status': 'known'}, reviewers=[],
              commit_examples=[], posting_languages=['en'], bootstrap_authorized=False)


def policy_text(policy):
    return '---\n' + ''.join(k + ': ' + json.dumps(v) + '\n' for k, v in policy.items()) + '---\n'


class FormatTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
        self.env['PYTHONDONTWRITEBYTECODE'] = '1'

    def render(self, spec=None, fmt=None, checks=None, mode='diff', unrunnable=False):
        from fm_pr_format import render
        return render(SPEC if spec is None else spec, FORMAT if fmt is None else fmt,
                      ['CI', 'Lint'] if checks is None else checks, mode, unrunnable)

    def test_exact_public_sections(self):
        result = self.render()
        self.assertEqual(result, dict(title=SPEC['public_title'], body='''## Summary

- Deduct the fee.

## Changes

- Add a fee check.

## Testing

<!-- fm:testing -->
- [ ] CI: pending
- [ ] Lint: pending
<!-- /fm:testing -->

## AI 参与度

- [x] 🤖 AI-Generated
- [ ] 🤝 AI-Assisted
- [ ] 👤 Human-Written'''))
        self.assertNotIn('T-051', result['title'])
        self.assertNotIn('retained privately', result['body'])

    def test_classes_omissions_and_local_lines(self):
        spec = dict(SPEC); spec.pop('public_changes')
        self.assertEqual(self.render(spec, dict(pr_sections=['Unknown', 'Changes']))['body'], '')
        self.assertEqual(self.render(spec, dict(pr_sections=[]))['body'], SPEC['public_summary'])
        spec.pop('public_summary')
        self.assertEqual(self.render(spec, dict(pr_sections=[]))['body'], '')
        result = self.render(mode='run', unrunnable=True)['body']
        self.assertIn('- [ ] Local tests: run in the firstmate review', result)
        self.assertIn('- [ ] Local tests: not run on this machine', result)
        self.assertNotIn('Private', result)
        for heading in ['AI participation summary', 'AI involvement', 'AI 參與', '概要', '摘要', '测试', '測試', '改动', '变更', '變更']:
            self.assertIn('## ' + heading, self.render(fmt=dict(pr_sections=[heading]))['body'])
        result = self.render(dict(SPEC, public_summary='Deduct the fee.\n\n- Add a check.'))
        self.assertIn('- Deduct the fee.\n- Add a check.', result['body'])

    def test_title_styles_and_ste_parity(self):
        for title in ['fix(validator): deduct the fee', '[ABC-12] feat: add x', 'Deduct the fee']:
            self.assertEqual(validate(title, None, style='plain'), [])
            problems = validate(title, None, style='conventional')
            self.assertEqual(bool(problems), title == 'Deduct the fee')
        title = 'fix(api): the fee is deducted'
        self.assertEqual(validate(title, None, 'plain'), [])
        self.assertEqual(validate(title, None, 'conventional'), [])
        spec = dict(SPEC, public_title=title)
        with patch.dict(os.environ, FM_EXTERNAL='1', FM_PR_TITLE='conventional'):
            prompt('T-051', json.dumps(spec).encode(), 'base')
            self.assertEqual(self.render(spec)['title'], title)

    def test_public_changes_validation(self):
        for changes in ['text', [], ['x'] * 11, [''], ['x' * 201], ['Add\na check'], ['藍'],
                        ['Read path/file'], ['Utilize the widget'], [3], ['x\t']]:
            with self.subTest(changes=changes):
                self.assertTrue(any('public_changes' in x for x in validate('Deduct the fee', None, changes=changes)))
                self.assertIsNone(self.render(dict(SPEC, public_changes=changes)))
        self.assertEqual(validate('Deduct the fee', None, changes=['Add a check.']), [])

    def test_refresh_only_marked_ci_lines(self):
        from fm_pr_format import refresh_testing
        body = 'CI outside\n<!-- fm:testing -->\n- [ ] CI: pending\n- [x] Lint: passed\n- [x] Audit: passed\n- [x] Local tests: passed\nkeep\n<!-- /fm:testing -->\n- [ ] CI: pending\n'
        result = refresh_testing(body, {'CI': 'passed', 'Lint': 'failed', 'Audit': 'pending', 'Local tests': 'failed'})
        self.assertEqual(result, body.replace('- [ ] CI: pending\n- [x] Lint: passed\n- [x] Audit: passed', '- [x] CI: passed\n- [ ] Lint: failed\n- [ ] Audit: pending'))
        for missing in ['plain', '<!-- fm:testing -->', '<!-- /fm:testing -->']:
            self.assertIsNone(refresh_testing(missing, {}))

    def test_policy_format_validation(self):
        bad = {'pr_title': ['fancy', [], None], 'pr_language': ['fr', [], None],
               'pr_sections': ['Summary', [''], [' '], ['a\nb'], ['a\rb'], ['a\u2028'], ['#a'], ['x' * 81], ['a', 'a'], list(map(str, range(13))), [3]]}
        for field, values in bad.items():
            for value in values:
                with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, field):
                    conventions.validate(dict(POLICY, **{field: value}))
        self.assertEqual(conventions.validate(dict(POLICY, **FORMAT))['pr_sections'], FORMAT['pr_sections'])
        path = self.home / 'CONVENTIONS.md'; path.write_text(policy_text(dict(POLICY, pr_title='fancy')))
        p = self.cli('fm_conventions.py', str(path))
        self.assertEqual(p.returncode, 65); self.assertIn('pr_title', p.stderr)

    def test_owner_precedence_layout_cli_and_refusals(self):
        path = self.home / 'projects/app/CONVENTIONS.md'; path.parent.mkdir(parents=True)
        path.write_text(policy_text(POLICY))
        owner = self.home / 'owners/fixture.yaml'; owner.parent.mkdir()
        defaults = dict(pr_title='plain', pr_sections=[], pr_language='en')
        self.assertEqual(conventions.pr_format(POLICY, path), defaults)
        owner.write_text('# private defaults\n\npr_title: conventional\npr_language: "zh-CN"\npr_sections: ["Summary"]\n')
        expected = dict(pr_title='conventional', pr_language='zh-CN', pr_sections=['Summary'])
        self.assertEqual(conventions.pr_format(POLICY, path), expected)
        self.assertEqual(json.loads(self.cli('fm_conventions.py', str(path), '--field', 'pr_format').stdout), expected)
        self.assertEqual(conventions.pr_format(dict(POLICY, pr_title='plain', pr_sections=[]), path), dict(expected, pr_title='plain', pr_sections=[]))
        self.assertEqual(conventions.pr_format(POLICY, self.home / 'CONVENTIONS.md'), defaults)
        for text in ['pr_language: zh-CN\n', 'unknown: plain\n', 'pr_title: fancy\n', 'pr_title: plain\npr_title: plain\n']:
            owner.write_text(text)
            self.assertEqual(conventions.read_policy(path), POLICY)  # owner defaults are lazy
            with self.assertRaises(ValueError) as caught: conventions.pr_format(POLICY, path)
            if 'zh-CN' in text: self.assertIn('quote conventions string as JSON', str(caught.exception))
        owner.write_text('pr_title: plain\n'); owner.chmod(0)
        with self.assertRaises(ValueError): conventions.pr_format(POLICY, path)
        owner.chmod(0o600); owner.unlink(); owner.symlink_to(path)
        with self.assertRaisesRegex(ValueError, 'symlink'): conventions.pr_format(POLICY, path)
        owner.unlink(); owner.symlink_to(self.home / 'missing')
        with self.assertRaises(ValueError): conventions.pr_format(POLICY, path)

    def cli(self, name, *args, env=None):
        return subprocess.run([sys.executable, str(ROOT / 'bin/lib' / name), *args],
                              env=self.env if env is None else env, capture_output=True, text=True, timeout=10)

    def test_cli_and_prompt_style_and_changes(self):
        spec = dict(SPEC, public_title='Deduct the fee')
        path = self.home / 'spec.json'; path.write_text(json.dumps(spec))
        self.assertEqual(self.cli('fm_public_text.py', 'check', str(path)).returncode, 0)
        self.assertEqual(self.cli('fm_public_text.py', 'check', str(path), env=dict(self.env, FM_PR_TITLE='conventional')).returncode, 65)
        with patch.dict(os.environ, FM_EXTERNAL='1', FM_PR_TITLE='conventional'):
            with self.assertRaisesRegex(ValueError, 'conventional'): prompt('T-051', path.read_bytes(), 'base')
        with patch.dict(os.environ, FM_EXTERNAL='0', FM_PR_TITLE='conventional'):
            prompt('T-051', path.read_bytes(), 'base')
        path.write_text(json.dumps(dict(spec, public_changes=[])))
        self.assertEqual(self.cli('fm_public_text.py', 'check', str(path)).returncode, 65)
        path.write_text(json.dumps(SPEC))
        p = self.cli('fm_pr_format.py', 'render', '--spec', str(path), '--format', json.dumps(FORMAT), '--required-checks', '["CI", "Lint"]')
        self.assertEqual(p.returncode, 0, p.stderr); self.assertEqual(json.loads(p.stdout), self.render())

    def test_onboard_explicit_format_fields_only(self):
        path = self.home / 'CONVENTIONS.md'; path.write_text(policy_text(POLICY))
        onboard.edit(self.home, FORMAT, 'fixture', 'Use this format')
        self.assertEqual(conventions.read_policy(path)['pr_sections'], FORMAT['pr_sections'])
        evidence = dict(source='github', repository='fixture/app', base='main', commits=['a'])
        answers = dict(confirmed=True, policy_confirmed=True, contract={'check': 'true'})
        with patch.object(onboard, 'infer', return_value={'available_merge_methods': ['squash']}):
            for fields in ({}, FORMAT):
                result = onboard.approve(self.home, evidence, POLICY, dict(answers, **fields))
                self.assertEqual({k: result[k] for k in FORMAT if k in result}, fields)
            result = onboard.approve(self.home, evidence, dict(POLICY, **FORMAT), answers)
            self.assertFalse(set(FORMAT) & set(result))

    def worker(self, spec=SPEC, fmt=FORMAT, prefix=''):
        worker = ROOT / 'bin/fm-worker.sh'
        block = section(worker, 'commit_msg="$TASK:', 'fm_private_stage "$tree"')
        publication = section(worker, '  pr_body="Dispatched by firstmate', '  url="$(fm_github pr create')
        script = ('set -eu\nTASK=T-051; FM_EXTERNAL=1\nFM_CODE_ROOT=' + shlex.quote(str(ROOT)) + '\n'
                  'spec=' + shlex.quote(json.dumps(spec)) + '\n'
                  'FM_SPEC_PIN_JSON=\'{}\'\n'
                  'fm_conventions() { if [ "$1" = pr_format ]; then printf "%s" ' + shlex.quote(json.dumps(fmt)) + '; else printf \'["CI"]\'; fi; }\n'
                  'fm_project() { :; }; fm_project_reviewer_mode() { :; }; fm_cfg_in() { :; }\n' + prefix + '\n' + block + publication +
                  '\nprintf "%s\\n%s\\n%s" "$commit_msg" "$pr_title" "$pr_body"')
        return subprocess.run(['bash', '-c', script], env=self.env, capture_output=True, text=True, timeout=10)

    def test_worker_render_warning_pin_and_mode_chain(self):
        p = self.worker(); self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.splitlines()[:2], [SPEC['public_title']] * 2)
        self.assertIn('## Testing', p.stdout); self.assertEqual(p.stderr, '')
        p = self.worker(dict(SPEC, public_title='Deduct the fee'))
        self.assertEqual(p.stdout.splitlines()[:2], ['Deduct the fee'] * 2)
        self.assertEqual(p.stderr, 'fm-worker: public_title does not follow the conventional style\n')
        for prefix, run, unavailable in [
            ('FM_SPEC_PIN_JSON=\' {"contract":{"unrunnable":"private reason"}}\'; fm_cfg_in() { echo run; }', True, True),
            ('FM_SPEC_PIN_JSON=; fm_cfg_in() { echo run; }', True, False),
            ('FM_SPEC_PIN_JSON=bad; fm_project_reviewer_mode() { echo diff; }; fm_cfg_in() { echo run; }', False, False),
            ('fm_project_reviewer_mode() { echo run; }; fm_cfg_in() { echo diff; }', True, False),
        ]:
            p = self.worker(prefix=prefix); self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual('run in the firstmate review' in p.stdout, run)
            self.assertEqual('not run on this machine' in p.stdout, unavailable)
            self.assertNotIn('private reason', p.stdout)
        p = self.worker(prefix='fm_conventions() { return 65; }')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stderr, 'fm-worker: cannot read the PR format; using the generic title\n')
        self.assertEqual(p.stdout, 'T-051: project work\nT-051: project work\nTask T-051. Captain acceptance and evidence are retained privately.')

    def test_shell_preflight_format_failure_and_self_guard(self):
        source = (ROOT / 'bin/lib/fm-spec-preflight.sh').read_text()
        block = source[source.index('if [ "${FM_EXTERNAL:-0}" = 1 ]; then'):source.index('python3 "$preflight_py" prompt')]
        self.assertIn('export FM_PR_TITLE', block)
        for external in (0, 1):
            p = subprocess.run(['bash', '-c', 'set -eu\nFM_EXTERNAL=' + str(external) + '\nfm_conventions() { echo called >&2; return 65; }\n' + block],
                               env=self.env, capture_output=True, text=True, timeout=10)
            self.assertEqual(p.returncode, 65 if external else 0)
            self.assertEqual('cannot read the PR format' in p.stderr, bool(external))
            if not external: self.assertEqual(p.stderr, '')
        p = subprocess.run(['bash', '-c', '''set -eu
FM_EXTERNAL=1
fm_conventions() { echo '{"pr_title":"conventional"}'; }
''' + block +
                            '\n[ "$FM_PR_TITLE" = conventional ]'], env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(p.returncode, 0, p.stderr)


class TestingRefreshCases:
    """Mixed into the existing autopilot fixture; no live processes or network."""
    def test_external_testing_checklist_refresh(self):
        import fm_autopilot as A
        from autopilot_branch_fixture import response
        self.external_pilot()
        p = self.pilot
        p.policy.update(required_checks=['CI'], analysers=['Lint'])
        p.task = lambda pr: 'T-001'; p.landed = lambda *a: False
        p.verdict = lambda task: {}; p.adoptions = lambda: ({}, {})
        p.start_job = lambda *a, **kw: self.calls.append(('gate', a))
        p.authoritative_head = lambda task, pr: pr['head']['sha']; p.base_tip = lambda: 'b' * 40
        p.api = lambda path: {}
        p.branch_failure = lambda *a, **kw: self.calls.append(('failure', a))
        p.probe = lambda argv: (self.calls.append(argv) or response('200 OK'))
        pr = dict(number=12, state='open', head=dict(sha='a' * 40, ref='t-001-work'), base=dict(ref='main', sha='b' * 40),
                  body='prefix\n<!-- fm:testing -->\n- [ ] CI: pending\n- [ ] Lint: pending\n- [x] Local tests: passed\n<!-- /fm:testing -->\nsuffix')
        runs = [dict(id=i, name=name, head_sha=pr['head']['sha'], status='completed', conclusion='success') for i, name in enumerate(['CI', 'Lint'])]
        def advance(runs=runs, statuses=None):
            A.Pilot.advance(p, pr, runs, statuses or [])
        def patches():
            return [x for x in self.calls if isinstance(x, list) and x[1:4] == ['api', '-X', 'PATCH']]
        with patch('fm_concurrent.live_rounds', return_value=[]), patch('fm_concurrent.merge_blocker', return_value=None):
            advance(); self.assertEqual(len(patches()), 1)
            self.assertEqual(patches()[0], ['gh', 'api', '-X', 'PATCH', 'repos/owner/repo/pulls/12', '-f',
                'body=' + pr['body'].replace('- [ ] CI: pending', '- [x] CI: passed').replace('- [ ] Lint: pending', '- [x] Lint: passed'), '--include'])
            advance(); self.assertEqual(len(patches()), 1)
            self.assertTrue(any(x[0] == 'gate' for x in self.calls))
            p.data['testing'].clear(); self.calls.clear(); p.adoptions = lambda: ({12: 'T-001'}, {})
            advance(); self.assertEqual(patches(), [])
            p.adoptions = lambda: ({}, {12: ['T-001', 'T-002']})
            advance(); self.assertEqual(patches(), [])
            p.adoptions = lambda: ({}, {}); body = pr['body']; pr['body'] = 'unmarked'
            advance(); self.assertEqual(patches(), [])
            pr['body'] = body; advance(runs=[]); self.assertEqual(patches(), [])
            pr['body'] = body.replace('- [ ] CI: pending', '- [x] CI: passed'); pr['head']['sha'] = 'c' * 40
            advance(runs=[]); self.assertEqual(len(patches()), 1)
            self.assertIn('- [ ] CI: pending', patches()[0][-2]); self.assertIn('- [x] Local tests: passed', patches()[0][-2])
            advance(runs=[]); self.assertEqual(len(patches()), 1)
            self.calls.clear(); pr['head']['sha'] = 'a' * 40; pr['body'] = body
            advance(statuses=[dict(id=9, context='CI', state='failure')])
            self.assertIn('- [ ] CI: failed', patches()[0][-2])
            for conclusion, expected in [('success', 'passed'), ('neutral', 'passed'), ('skipped', 'passed'),
                                         ('failure', 'failed'), ('error', 'failed'), ('cancelled', 'failed'),
                                         ('timed_out', 'failed'), ('action_required', 'failed'), ('unknown', 'pending')]:
                self.calls.clear(); p.data['testing'].clear()
                rows = [('CI', 'check', 1, 'success'), ('CI', 'status', 2, conclusion), ('Lint', 'check', 3, 'success')]
                with patch.object(p, 'settled_checks', return_value=rows): advance()
                self.assertIn('CI: ' + expected, patches()[0][-2])
            for post in ('local', 'summary', 'check', 'threads', 'comments'):
                self.calls.clear(); p.data['testing'].clear(); p.policy['post'] = post
                advance(); self.assertEqual(len(patches()), 1)
            for answer in (response('500 Error'), response('202 Accepted'), OSError('offline')):
                self.calls.clear(); p.data['testing'].clear(); p.data['advanced'].clear()
                def fail(argv):
                    self.calls.append(argv)
                    if isinstance(answer, Exception): raise answer
                    return answer
                p.probe = fail
                advance()
                self.assertEqual(len([x for x in self.calls if x[0] == 'failure' and x[1][0] == 'testing-refresh']), 1)
                self.assertTrue(any(x[0] == 'gate' for x in self.calls))
                self.assertNotIn('12', p.data['testing'])


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]], verbosity=2)
