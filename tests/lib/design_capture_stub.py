"""T-298 fixture: stands in for the browser. Writes every planned screenshot
as a tiny PNG, or fails when FM_TEST_CAPTURE_FAIL is set."""
import json
import os
import sys
from pathlib import Path

plan = json.loads(Path(sys.argv[1]).read_text())
if os.environ.get('FM_TEST_CAPTURE_FAIL'):
    print('capture failed: chromium could not start', file=sys.stderr)
    sys.exit(1)
log = os.environ.get('FM_TEST_CAPTURE_LOG')
for shot in plan['shots']:
    out = Path(plan['out']) / shot['file']
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(b'\x89PNG\r\n\x1a\n' + shot['file'].encode())
    if log:
        with open(log, 'a') as stream:
            stream.write(f"{shot['target']} {shot['page']} {shot['viewport']} {shot['scheme']}\n")
