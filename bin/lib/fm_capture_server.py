"""A repository's optional fixture server, owned by this capture only.

The fixed tests/e2e/capture-server.sh hook prints one JSON line after it is
ready: {"pages": {"repository/page.html": {"url": "http://127.0.0.1:port/",
"ready": "CSS selector"}}}. Unlisted pages retain their file URLs. EOF on
stdin asks the hook to stop; the lifeline also ends it when its owner dies.
"""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time
from urllib.parse import urlsplit

from fm_lifeline import start


def local_url(value):
    url = urlsplit(value)
    return url.scheme in ('http', 'https') and (
        url.hostname in ('localhost', '::1') or
        (url.hostname or '').startswith('127.') and
        len((url.hostname or '').split('.')) == 4 and
        all(p.isdigit() and 0 <= int(p) <= 255 for p in url.hostname.split('.')))


@contextmanager
def capture_server(root):
    root = Path(root).resolve()
    hook = root / 'tests/e2e/capture-server.sh'
    if not hook.is_file():
        yield None
        return
    env = dict(os.environ)
    # The exported head has no dependencies installed. The capture launcher
    # already has Playwright; Bun hooks can resolve it without changing head.
    env['NODE_PATH'] = str(Path(__file__).resolve().parents[2] / 'node_modules')
    with tempfile.TemporaryFile() as log:
        proc = start(['bash', str(hook)], owner=None, cwd=root, env=env,
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(proc.stdout, selectors.EVENT_READ)
                data = b''
                # A bounded, pushed readiness record; no process polling.
                deadline = time.monotonic() + 120
                while b'\n' not in data:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not selector.select(remaining):
                        raise ValueError('capture server did not announce readiness')
                    chunk = os.read(proc.stdout.fileno(), 4096)
                    if not chunk:
                        log.seek(0)
                        raise ValueError('capture server exited before readiness: ' + log.read().decode(errors='replace')[-2000:])
                    data += chunk
                    if len(data) > 65536:
                        raise ValueError('capture server readiness record is too large')
            record = json.loads(data.split(b'\n', 1)[0])
            if not isinstance(record.get('pages'), dict):
                raise ValueError('capture server must name its served pages')
            for page, entry in record['pages'].items():
                if not isinstance(entry, dict) or not local_url(entry.get('url', '')):
                    raise ValueError('capture server page URL must be local: ' + page)
                if entry.get('ready') is not None and not isinstance(entry['ready'], str):
                    raise ValueError('capture server ready must be a CSS selector')
            yield record
        finally:
            proc.stdin.close()
            try:
                proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                proc.terminate()  # keeper drains the entire owned process group
                proc.wait(timeout=15)
            proc.stdout.close()
