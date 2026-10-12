"""T-299: browser-free capture plan orchestration."""
import json
import shlex
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch
import unittest

ROOT = Path(sys.argv.pop(1))
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_design


class CapturePlan(unittest.TestCase):
    def test_served_head_and_file_prototype(self):
        """capture: served mapping leaves the prototype and unlisted pages as files"""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            proto = root / 'prototype'
            proto.mkdir()
            (proto / 'index.html').write_text('<p>prototype</p>')
            spec = root / 'spec.json'
            spec.write_text(json.dumps({'design': {'pages': [{'path': 'index.html'}, {'path': 'other.html'}]}}))
            args = SimpleNamespace(spec=spec, config='', project='', prototype=str(proto),
                                   prototype_only=False, state='', repo='', base='', head='a'*40,
                                   out=str(root / 'shots'), task='T-299')
            def export(repo, head, tree):
                tree = Path(tree)
                for name in ('index.html', 'other.html'):
                    (tree / name).write_text('<p>head</p>')
                hook = tree / 'tests/e2e/capture-server.sh'
                hook.parent.mkdir(parents=True)
                # No listener needed for this orchestration assertion. The
                # browser is exercised in tests/e2e/capture-pages.spec.ts with the real board.
                hook.write_text("printf '%s\\n' '{\"pages\":{\"index.html\":{\"url\":\"http://127.0.0.1:1234/\",\"ready\":\"#content\"}}}'\ncat >/dev/null\n" + "touch " + shlex.quote(str(root / 'stopped')) + "\n")
            observed = []
            def browser(plan, out):
                observed.extend(plan['shots'])
                Path(out).mkdir()
            with patch.object(fm_design, 'export_tree', export), \
                 patch.object(fm_design, 'changed', return_value=[]), \
                 patch.object(fm_design, 'ui_globs', return_value=[]), \
                 patch.object(fm_design, 'run_capture', browser):
                fm_design.capture(args)
            self.assertTrue((root / 'stopped').is_file(), 'the fixture server stopped before capture returned')
            served = [s for s in observed if s['target'] == 'head' and s['page'] == 'index.html']
            self.assertTrue(served)
            self.assertTrue(all(s['url'] == 'http://127.0.0.1:1234/' for s in served))
            self.assertTrue(all(s['ready'] == '#content' for s in served))
            other = [s for s in observed if s not in served]
            self.assertTrue(all(s['url'].startswith('file:') for s in other))
            self.assertEqual({s['scheme'] for s in served}, {'light', 'dark'})
            self.assertEqual({s['width'] for s in served}, {320, 390, 768, 1440, 1920})


if __name__ == '__main__':
    unittest.main(verbosity=2)
