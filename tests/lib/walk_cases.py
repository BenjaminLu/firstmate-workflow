"""Scene and retained-walk behavior. New helper absence is setup, not red."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop(1))
sys.path[:0] = [str(ROOT / 'bin/lib'), str(ROOT / 'tests/lib')]
from ste_cases import card
import fm_ste
import fm_spec_preflight


def scene():
    return dict(lanes=[dict(label='Flow')], nodes=[
        dict(id='input', label='Input', lane=0, kind='input', state='same'),
        dict(id='output', label='Output', lane=0, kind='step', state='same')],
        edges=[dict(id='path', **{'from': 'input', 'to': 'output'}, state='same')],
        tokens=dict(before=['path'], after=['path']),
        changes=[dict(id='c1', text='The path carries the input.', intents=[1])])


def spec():
    fields = ('intent', 'why', 'scope_in', 'scope_out', 'done', 'notes', 'before_nodes', 'after_nodes')
    explain = {lang: {k: v for k, v in loc.items() if k in fields} for lang, loc in card().items()}
    for loc in explain.values():
        loc['scene'] = scene()
    return dict(id='T-001', title='The task works.', scope=['tests/walk.test.sh'],
                acceptance=['The path works.'], explain=explain)


class Scene(unittest.TestCase):
    def test_scene_cli_accepts(self):
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / 'spec.json'
            path.write_text(json.dumps(spec()))
            result = subprocess.run([sys.executable, str(ROOT / 'bin/lib/fm_ste.py'),
                                     'check-explain', str(path)], capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stderr)

    def test_scene_preflight_accepts(self):
        fm_spec_preflight.prompt('T-001', json.dumps(spec()), 'a' * 40)

    def test_field_errors(self):
        cases = [
            ('lane', lambda s: s['nodes'][0].update(lane=1)),
            ('id', lambda s: s['edges'][0].update(id='input')),
            ('changes', lambda s: s['changes'][0].update(id='c2')),
            ('change', lambda s: s['nodes'][0].update(state='gone')),
            ('change', lambda s: s['nodes'][0].update(change='c1')),
            ('from', lambda s: s['edges'][0].update(**{'from': 'missing'})),
            ('tokens', lambda s: s['tokens'].update(before=['path', 'path'])),
            ('intents', lambda s: s['changes'][0].update(intents=[999])),
            ('label', lambda s: s['lanes'][0].update(label='one two three four five six seven')),
            ('text', lambda s: s['changes'][0].update(text='The path works. The input moves.')),
            ('counter', lambda s: s.update(counter=dict(label='Count', before='', after='1'))),
        ]
        for field, mutate in cases:
            with self.subTest(field=field):
                value = spec()
                mutate(value['explain']['en']['scene'])
                with self.assertRaisesRegex(ValueError, field):
                    fm_ste.check_explain(value['explain'])


@unittest.skipUnless((ROOT / 'bin/lib/fm_walk.py').is_file(),
                     'setup: fm_walk.py absent; helper cases are not behavioral base failures')
class Walk(unittest.TestCase):
    def setUp(self):
        import fm_walk
        self.walk = fm_walk
        self.value = spec()
        for loc in self.value['explain'].values():
            loc.pop('scene')
        self.diff = 'diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -1 +1 @@\n-old\n+new\n'
        self.block = dict(hunk='a.py#R1-1', kind='code', note=dict(en='The path works.', **{'zh-TW': '路徑有效。'}))

    def check(self, blocks=None):
        text = '```walk\n' + json.dumps(dict(intents=[dict(intent=1, key=blocks or [self.block])])) + '\n```'
        return self.walk.check(text, self.value, self.diff, 'owner/repo', 1)

    def test_valid_rows(self):
        result = self.check()
        self.assertEqual('valid', result['status'])
        self.assertEqual(['del', 'add'], [r['type'] for r in result['intents'][0]['key'][0]['rows']])
        self.assertEqual([], result['other'])

    def test_unknown_and_duplicate(self):
        self.block['hunk'] = 'unknown'
        self.assertEqual('unknown hunk id', self.check()['reason'])
        self.block['hunk'] = 'a.py#R1-1'
        self.assertEqual('duplicate key hunk', self.check([self.block, self.block])['reason'])

    def test_absent_duplicate_fence(self):
        self.assertEqual('absent', self.walk.check('APPROVE:T-001', self.value, self.diff)['status'])
        self.assertEqual('duplicate walk', self.walk.check('```walk\n{}\n```\n```walk\n{}\n```', self.value, self.diff)['reason'])

if __name__ == '__main__':
    unittest.main()
