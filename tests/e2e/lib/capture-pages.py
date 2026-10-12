"""Exercise the production Python capture entrypoints for the Playwright suite."""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_design
from fm_capture_server import capture_server

mode, directory = sys.argv[1:]
out = Path(directory)
out.mkdir(parents=True, exist_ok=True)
source = out / 'index.html'
if mode == 'remote':
    source.write_text('''<p>offline fixture</p><script>
fetch('https://example.invalid/api').catch(()=>{});
new WebSocket('wss://example.invalid/socket');
</script><img src="https://example.invalid/image.png">''')
else:
    source.write_text('<p>file fixture</p>')

with capture_server(ROOT if mode == 'served' else out) as server:
    shot = dict(page='board/public/index.html', target='head', viewport='w390', width=390,
                height=900, scheme='light', url=source.as_uri(), file='head/page.png')
    planned = dict(out=str(out), shots=[shot])
    if server:
        if hasattr(fm_design, 'apply_server'):
            fm_design.apply_server(planned, server)
        else:
            # Retain the old single-page setup for base comparisons, so the
            # named-view assertion fails instead of a missing-helper error.
            shot.update(server['pages']['board/public/index.html'])
    fm_design.run_capture(planned, out)
(out / 'server.json').write_text(json.dumps(server))
