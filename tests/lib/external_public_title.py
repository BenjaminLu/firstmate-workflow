"""Public text validation and unchanged worker publication blocks."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
os.environ['HERDR_ENV'] = '0'   # T-305: it runs fm-worker.sh, which can raise a door card

sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1))
sys.path[:0] = [str(ROOT / 'tests/lib'), str(ROOT / 'bin/lib')]
from crew_blocks import section
from fm_spec_pins import SpecRefused, spec_check

WORKER = ROOT / 'bin/fm-worker.sh'
TITLE = 'Draw the fixture widget in blue'
SUMMARY = 'The fixture widget uses blue.'
FOOTER = 'Captain acceptance and evidence are retained privately.'


class PublicText(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.spec = dict(id='T-051', title='Private launch strategy',
                         scope=['widget'], acceptance=['Private criteria'])
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('FM_', 'HERDR_'))}
        self.env['PYTHONDONTWRITEBYTECODE'] = '1'

    def check(self, **fields):
        path = self.home / 'spec.json'
        path.write_text(json.dumps(dict(self.spec, **fields)))
        return subprocess.run([sys.executable, str(ROOT / 'bin/lib/fm_public_text.py'),
                               'check', str(path)], capture_output=True, text=True,
                              env=self.env, timeout=10)

    def test_cli_accepts_valid_public_text(self):
        p = self.check(public_title='  ' + TITLE + '  ', public_summary=SUMMARY)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(p.stdout, '')
        self.assertEqual(self.check(public_title=TITLE).returncode, 0)

    def test_cli_rejects_each_invalid_class(self):
        cases = [({}, 'public_title: expected a string'),
                 ({'public_title': 'Read design/file'}, 'path-like'),
                 ({'public_title': 'Draw the 藍 widget'}, 'printable ASCII'),
                 ({'public_title': 'T-051: Draw a widget'}, 'task id'),
                 ({'public_title': TITLE, 'public_summary': 'x' * 601}, '1-600'),
                 ({'public_title': 'Utilize the widget'}, 'STE'),
                 ({'public_title': 'short'}, '8-80'),
                 ({'public_title': 'x' * 81}, '8-80'),
                 ({'public_title': 'Draw a widget\n'}, 'one line'),
                 ({'public_title': TITLE, 'public_summary': ''}, '1-600'),
                 ({'public_title': TITLE, 'public_summary': 3}, 'expected a string'),
                 ({'public_title': TITLE, 'public_summary': 'Use FM_HOME'}, 'path-like'),
                 ({'public_title': TITLE, 'public_summary': 'We will draw it.'}, 'STE'),
                 ({'public_title': TITLE, 'public_summary': 'Blue\twidget'}, 'printable ASCII')]
        for fields, message in cases:
            with self.subTest(fields=fields):
                p = self.check(**fields)
                self.assertEqual(p.returncode, 65, p.stdout + p.stderr)
                self.assertIn(message, p.stdout)
        for token in ('/', '\\', '.json', '.md', 'FM_HOME', '~/', 'design/', 'tasks/', 'state/'):
            for field in ('public_title', 'public_summary'):
                with self.subTest(token=token, field=field):
                    fields = dict(public_title=TITLE)
                    fields[field] = 'Read the ' + token + ' widget'
                    self.assertIn('path-like', self.check(**fields).stdout)

    def test_plain_checks_block_pin_but_not_a_publishing_round(self):
        # T-270 Change 15: glued numbers and slash chains in public fields are
        # refused at pin time (T-297); an approved pin still publishes unchanged.
        glued = dict(self.spec, public_title=TITLE, public_summary='The widget shows All13 rows.')
        p = self.check(public_title=TITLE, public_summary='The widget shows All13 rows.')
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        from fm_public_text import plain_problems
        self.assertEqual(['public_summary: glued-number "All13"'],
                         plain_problems(glued['public_title'], glued['public_summary']))
        with patch.dict(os.environ, FM_EXTERNAL='1'):
            with self.assertRaisesRegex(SpecRefused, 'glued-number "All13"'):
                spec_check('T-051', json.dumps(glued))
        shell = self.shell({'public_title': TITLE, 'public_summary': 'The widget shows All13 rows.'},
                           tail='printf "%s\\n%s" "$commit_msg" "$pr_body"')
        self.assertEqual(shell.returncode, 0, shell.stderr)
        self.assertEqual(shell.stdout.splitlines()[0], TITLE)
        self.assertIn('All13', shell.stdout)

    def test_pin_external_refusal_and_self_compatibility(self):
        with patch.dict(os.environ, FM_EXTERNAL='1'):
            with self.assertRaisesRegex(SpecRefused, 'external spec needs a valid public_title:'):
                spec_check('T-051', json.dumps(self.spec))
            spec_check('T-051', json.dumps(dict(self.spec, public_title=TITLE)))
            with patch.dict(os.environ, FM_PR_TITLE='conventional'):
                with self.assertRaisesRegex(SpecRefused, 'conventional subject'):
                    spec_check('T-051', json.dumps(dict(self.spec, public_title=TITLE)))
        with patch.dict(os.environ, FM_EXTERNAL='0'):
            spec_check('T-051', json.dumps(self.spec))

    def test_pin_checks_the_pinned_project_not_the_process(self):
        # T-297: the pin-time check follows the environment the pin store was
        # opened with, so an in-process external pin is checked like the CLI.
        from fm_spec_pins import Pins
        (self.home / 'state').mkdir()
        (self.home / 'tasks').mkdir()
        (self.home / 'design.md').write_text('Private design\n')
        (self.home / 'state/events.jsonl').write_text(json.dumps(dict(
            type='greenlit', actor='captain', project='client', ts='2026-10-02T00:00:00Z', data={})) + '\n')
        root = str(self.home)
        env = dict(FM_ENGINE_ROOT=root, FM_TARGET_ROOT=root, FM_STATE_DIR=root + '/state',
                   FM_TASKS_DIR=root + '/tasks', FM_DESIGN=root + '/design.md',
                   FM_EXTERNAL='1', FM_PROJECT='client')
        spec = self.home / 'tasks/T-051.json'
        with patch.dict(os.environ, FM_EXTERNAL='0', FM_PR_TITLE='plain'):
            spec.write_text(json.dumps(self.spec))
            with self.assertRaisesRegex(SpecRefused, 'external spec needs a valid public_title:'):
                Pins(env, 'T-051').check()
            spec.write_text(json.dumps(dict(self.spec, public_title=TITLE)))
            Pins(env, 'T-051').check()
            with self.assertRaisesRegex(SpecRefused, 'conventional subject'):
                Pins(dict(env, FM_PR_TITLE='conventional'), 'T-051').check()

    def shell(self, fields=None, external=1, prefix='', tail=''):
        spec = dict(self.spec, **(fields or {}))
        commit = section(WORKER, 'commit_msg="$TASK:', 'fm_private_stage "$tree"')
        publication = section(WORKER, '  pr_body="Dispatched by firstmate',
                              '  url="$(fm_github pr create') if external else ''
        script = ('set -eu\nTASK=T-051; branch=t-051-work; num=9\n'
                  f'FM_EXTERNAL={external}; FM_CODE_ROOT={shlex.quote(str(ROOT))}\n'
                  '''fm_conventions() { if [ "$1" = pr_format ]; then echo '{"pr_title":"plain","pr_sections":[],"pr_language":"en"}'; else echo '[]'; fi; }
fm_project() { :; }; fm_project_reviewer_mode() { :; }; fm_cfg_in() { :; }; FM_SPEC_PIN_JSON='{}'
''' + 'spec=' + shlex.quote(json.dumps(spec)) + '\n' + prefix + '\n' +
                  commit + publication + tail)
        return subprocess.run(['bash', '-c', script], capture_output=True,
                              text=True, env=self.env, timeout=10)

    def test_commit_and_pr_share_validated_text(self):
        for fields, external, title, body in (
            ({'public_title': TITLE, 'public_summary': SUMMARY}, 1, TITLE, SUMMARY),
            ({'public_title': TITLE}, 1, TITLE, ''),
            ({}, 1, "Save the round's changes", 'Task T-051. ' + FOOTER),
            ({'public_title': 'Utilize the widget'}, 1, "Save the round's changes", 'Task T-051. ' + FOOTER)
        ):
            with self.subTest(fields=fields, external=external):
                p = self.shell(fields, external, tail='printf "%s\\n%s\\n%s" "$commit_msg" "$pr_title" "$pr_body"')
                self.assertEqual(p.returncode, 0, p.stderr)
                expected = title if external and fields.get('public_title') == TITLE else 'T-051: ' + title
                self.assertEqual(p.stdout, f'{expected}\n{expected}\n{body}')
                if external:
                    self.assertNotIn('Private launch strategy', p.stdout)

    def test_self_subject_is_authored_without_changing_commit_title(self):
        from fm_self_pr import render
        draft = dict(subject='Show the approved fixture result', size='small',
                     problem='The former body omitted context.', expected_result='Readers can assess intent.',
                     approach='Render the approved purpose.', intent_notes=[dict(index=0, note='Explain intent.')])
        envelope = dict(draft=draft, mode='pin-backed', dispatch_reference=None)
        result = render(envelope, self.spec, 'a'*40, ['widget'])
        self.assertEqual(result['title'], 'T-051: Show the approved fixture result')
        self.assertIn('Readers can assess intent.', result['body'])
        self.assertIn('Required CI: pending', result['body'])
        self.assertNotIn('Acceptance is in', result['body'])

    def test_helper_failure_and_empty_spec_fall_back_silently(self):
        for prefix in ('spec=', 'unset spec FM_CODE_ROOT', 'FM_CODE_ROOT=/missing',
                       'python3() { echo broken >&2; return 42; }'):
            with self.subTest(prefix=prefix):
                p = self.shell({'public_title': TITLE}, prefix=prefix,
                               tail='printf "%s\\n%s\\n%s" "$commit_msg" "$pr_title" "$pr_body"')
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(p.stderr, '')
                self.assertEqual(p.stdout, "T-051: Save the round's changes\nT-051: Save the round's changes\nTask T-051. " + FOOTER)

    def test_later_round_retitles_only_matching_generic_pr(self):
        block = section(WORKER, '  # Upgrade only the untouched external fallback title.',
                        '  emit_status "Pushed another round')
        for external, current, branch, view_rc, edit_rc, edits in (
            (1, 'T-051: project work', 't-051-work', 0, 0, 1),
            (1, "T-051: Save the round's changes", 't-051-work', 0, 0, 1),
            (1, "T-051: Save the round's changes", 'other', 0, 0, 0),
            (1, 'Captain chose a title', 't-051-work', 0, 0, 0),
            (1, 'T-051: ' + TITLE, 't-051-work', 0, 0, 0),
            (1, 'T-051: project work', 'other', 0, 0, 0),
            (0, 'T-051: project work', 't-051-work', 0, 0, 0),
            (1, 'T-051: project work', 't-051-work', 1, 0, 0),
            (1, 'T-051: project work', 't-051-work', 0, 42, 1),
        ):
            with self.subTest(external=external, current=current, branch=branch,
                              view_rc=view_rc, edit_rc=edit_rc):
                calls = self.home / 'edit-args'
                calls.unlink(missing_ok=True)
                response = shlex.quote(json.dumps(dict(title=current, headRefName=branch)))
                stub = '''\nfm_github() {
  if [ "$2" = view ]; then
    printf '%s' RESPONSE; return VIEW_RC
  fi
  printf '%s\\n' "$@" >> CALLS
  return EDIT_RC
}
'''.replace('RESPONSE', response).replace('VIEW_RC', str(view_rc)).replace('EDIT_RC', str(edit_rc)).replace('CALLS', shlex.quote(str(calls)))
                p = self.shell({'public_title': TITLE, 'public_summary': SUMMARY}, external,
                               tail=stub + block + '\nexit 17')
                self.assertEqual(p.returncode, 17, p.stderr)
                recorded = calls.read_text() if calls.exists() else ''
                self.assertEqual(recorded.splitlines().count('edit'), edits)
                if edits:
                    self.assertIn('\n' + TITLE + '\n', recorded)
                    self.assertIn(SUMMARY, recorded)
                    self.assertNotIn(FOOTER, recorded)
                if view_rc or edit_rc:
                    self.assertIn('fm-worker:', p.stderr)
                    self.assertTrue(any(ord(c) > 127 for c in p.stderr))

    def test_legacy_later_round_does_not_read_or_edit_pr(self):
        block = section(WORKER, '  # Upgrade only the untouched external fallback title.',
                        '  emit_status "Pushed another round')
        p = self.shell(tail='fm_github() { echo unexpected-call; return 99; }\n' + block)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, '')
        self.assertEqual(p.stderr, '')

    def test_imports_do_not_load_optional_modules(self):
        # A consumer may copy the spec check module without the evidence
        # store, public-text or STE modules; a self spec needs none of them.
        lib = self.home / 'bin/lib'
        lib.mkdir(parents=True)
        shutil.copy(ROOT / 'bin/lib/fm_spec_preflight.py', lib / 'fm_spec_preflight.py')
        call = ('import fm_spec_preflight; '
                'fm_spec_preflight.check("T-051", ' + repr(json.dumps(self.spec).encode()) + ')')
        p = subprocess.run([sys.executable, '-c', call], cwd=lib,
                           env=dict(self.env, FM_EXTERNAL='0'), capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        p = subprocess.run([sys.executable, '-c', call], cwd=lib,
                           env=dict(self.env, FM_EXTERNAL='1'), capture_output=True, text=True)
        self.assertNotEqual(p.returncode, 0, 'an external spec needs the public text check')
        self.assertIn('fm_public_text', p.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
