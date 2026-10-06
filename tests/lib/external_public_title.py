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

sys.dont_write_bytecode = True
ROOT = Path(sys.argv.pop(1))
sys.path[:0] = [str(ROOT / 'tests/lib'), str(ROOT / 'bin/lib')]
from crew_blocks import section
from fm_spec_preflight import prompt

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

    def test_prompt_external_refusal_and_self_compatibility(self):
        with patch.dict(os.environ, FM_EXTERNAL='1'):
            with self.assertRaisesRegex(ValueError, 'external spec needs a valid public_title:'):
                prompt('T-051', json.dumps(self.spec).encode(), 'base')
            valid = dict(self.spec, public_title=TITLE)
            self.assertIn('SPEC-OK:T-051', prompt('T-051', json.dumps(valid).encode(), 'base'))
        with patch.dict(os.environ, FM_EXTERNAL='0'):
            self.assertIn('SPEC-OK:T-051', prompt('T-051', json.dumps(self.spec).encode(), 'base'))

    def shell(self, fields=None, external=1, prefix='', tail=''):
        spec = dict(self.spec, **(fields or {}))
        commit = section(WORKER, 'commit_msg="$TASK:', 'fm_private_stage "$tree"')
        publication = section(WORKER, '  pr_body="Dispatched by firstmate',
                              '  url="$(fm_github pr create')
        script = ('set -eu\nTASK=T-051; branch=t-051-work; num=9\n'
                  f'FM_EXTERNAL={external}; FM_CODE_ROOT={shlex.quote(str(ROOT))}\n'
                  'spec=' + shlex.quote(json.dumps(spec)) + '\n' + prefix + '\n' +
                  commit + publication + tail)
        return subprocess.run(['bash', '-c', script], capture_output=True,
                              text=True, env=self.env, timeout=10)

    def test_commit_and_pr_share_validated_text(self):
        for fields, external, title, body in (
            ({'public_title': TITLE, 'public_summary': SUMMARY}, 1, TITLE, SUMMARY + '\n\n' + FOOTER),
            ({'public_title': TITLE}, 1, TITLE, FOOTER),
            ({}, 1, 'project work', 'Task T-051. ' + FOOTER),
            ({'public_title': 'Utilize the widget'}, 1, 'project work', 'Task T-051. ' + FOOTER),
            ({}, 0, 'Private launch strategy', 'Dispatched by firstmate for T-051. Acceptance is in design/tasks/T-051.json.')
        ):
            with self.subTest(fields=fields, external=external):
                p = self.shell(fields, external, tail='printf "%s\\n%s\\n%s" "$commit_msg" "$pr_title" "$pr_body"')
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(p.stdout, f'T-051: {title}\nT-051: {title}\n{body}')
                if external:
                    self.assertNotIn('Private launch strategy', p.stdout)

    def test_helper_failure_and_empty_spec_fall_back_silently(self):
        for prefix in ('spec=', 'unset spec FM_CODE_ROOT', 'FM_CODE_ROOT=/missing',
                       'python3() { echo broken >&2; return 42; }'):
            with self.subTest(prefix=prefix):
                p = self.shell({'public_title': TITLE}, prefix=prefix,
                               tail='printf "%s\\n%s\\n%s" "$commit_msg" "$pr_title" "$pr_body"')
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(p.stderr, '')
                self.assertEqual(p.stdout, 'T-051: project work\nT-051: project work\nTask T-051. ' + FOOTER)

    def test_later_round_retitles_only_matching_generic_pr(self):
        block = section(WORKER, '  # Upgrade only the untouched external fallback title.',
                        '  emit_status "Pushed another round')
        for external, current, branch, view_rc, edit_rc, edits in (
            (1, 'T-051: project work', 't-051-work', 0, 0, 1),
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
                    self.assertIn('T-051: ' + TITLE, recorded)
                    self.assertIn(SUMMARY + '\n\n' + FOOTER, recorded)
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
        # A consumer may copy the preflight module without public-text or STE.
        for name in ('fm_spec_preflight.py', 'fm_public_text.py'):
            shutil.copy(ROOT / 'bin/lib' / name, self.home / name)
        (self.home / 'fm_evidence.py').write_text('Store = None\nunquoted = None\n')
        p = subprocess.run([sys.executable, '-c',
            'import fm_spec_preflight, fm_public_text; '
            'fm_spec_preflight.prompt("T-051", ' + repr(json.dumps(self.spec).encode()) + ', "base")'],
            cwd=self.home, env=dict(self.env, FM_EXTERNAL='0'), capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        (self.home / 'fm_public_text.py').unlink()
        p = subprocess.run([sys.executable, '-c',
            'import fm_spec_preflight; fm_spec_preflight.prompt("T-051", ' +
            repr(json.dumps(self.spec).encode()) + ', "base")'], cwd=self.home,
            env=dict(self.env, FM_EXTERNAL='0'), capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
