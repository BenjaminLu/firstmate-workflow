"""Exercise capture on head and base using only their shared Python interface."""
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_design

mode, directory = sys.argv[1:]
out = Path(directory).resolve()
out.mkdir(parents=True, exist_ok=True)
page = 'board/public/index.html' if mode == 'served' else 'index.html'
spec = out / 'spec.json'
spec.write_text(json.dumps({'design': {'pages': [{'path': page}]}}))


def export_fixture(repo, head, tree):
    tree = Path(tree)
    if mode == 'served':
        # Supply the retained fixture hook exactly where production discovers
        # it. The old capture implementation simply ignores this hook.
        for name in ('board', 'bin', 'tests', 'i18n', 'design', 'games'):
            (tree / name).symlink_to(ROOT / name, target_is_directory=True)
    else:
        text = '<p>file fixture</p>'
        if mode == 'remote':
            text = '''<p>offline fixture</p><script>
fetch('https://example.invalid/api').catch(()=>{});
new WebSocket('wss://example.invalid/socket');
</script><img src="https://example.invalid/image.png">'''
        (tree / page).write_text(text)


args = SimpleNamespace(spec=spec, config='', project='', prototype=None,
                       prototype_only=False, state='', repo='', base='', head='fixture',
                       out=str(out), task='T-299')
# Observe screenshots without changing navigation, routing or server setup.
os.environ['FM_DESIGN_CAPTURE'] = shlex.join([
    shutil.which('node') or shutil.which('bun'), str(ROOT / 'tests/e2e/lib/capture-observer.mjs')])
with patch.object(fm_design, 'export_tree', export_fixture), \
     patch.object(fm_design, 'changed', return_value=[]), \
     patch.object(fm_design, 'viewports', return_value=[('w390', 390, 900)]), \
     patch.object(fm_design, 'SCHEMES', ('light',)):
    fm_design.capture(args)
