"""Seed trusted legacy receipts in isolated fixtures, never production state.

These receipts exercise readers. Managed authentication is covered separately by
codex-review-integration.test.sh through the real launcher and transport.
"""
from pathlib import Path
import re
import os
import sys
import subprocess

root, state, task, actor, text = sys.argv[1:]
sys.path.insert(0, str(Path(root) / 'bin/lib'))
from fm_evidence import Store, verdict_marker

# Resolve through the production functions with this fixture's configuration,
# not the source checkout's config or the caller's working directory.
project = subprocess.check_output(
    ['bash', '-c', '. "$1/bin/fm-config.sh"; fm_storage_init "$2" || exit; fm_evidence_project',
     'fixture-evidence', root, str(Path(state).resolve().parent)], text=True).strip()
store = Store(state, project, task)
text = text.replace('\\n', '\n').replace('\r', '\n')
marker = verdict_marker(text, task)
if marker:
    binding = re.search(r'^REVIEWED:' + re.escape(task) + r' verdict=\w+ head=(\w+) base=(\w+) patch=(\w*)', text, re.M)
    fields = {}
    if binding:
        from fm_binding import source_binding
        os.environ['FM_TARGET_ROOT'] = str(Path(state).resolve().parent)
        os.environ['FM_EXTERNAL'] = '0'
        try:
            fields['binding'] = source_binding(task, binding[1], binding[2], root)
        except (ValueError, OSError, subprocess.SubprocessError):
            pass  # Deliberately invalid heads remain unbound negative fixtures.
    store.append('verdict', 1, actor, binding[1] if binding else '', text,
                 verdict=marker, base=binding[2] if binding else '', patch=binding[3] if binding else '',
                 provenance={'level': 'legacy'}, **fields)
elif ('ASK-PASS-CRITERIA:' + task) in text.splitlines():
    store.append('ask', 1, actor, 'a' * 40, text)
else:
    store.append('worker-report', 1, actor, 'a' * 40, text)
