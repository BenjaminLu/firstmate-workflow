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
    shot = dict(page='index.html', target='head', viewport='w390', width=390,
                height=900, scheme='light', url=source.as_uri(), file='head/page.png')
    if server:
        shot.update(server['pages']['board/public/index.html'])
    fm_design.run_capture(dict(out=str(out), shots=[shot]), out)
(out / 'server.json').write_text(json.dumps(server))
