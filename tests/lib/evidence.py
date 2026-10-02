"""Seed trusted legacy receipts in isolated fixtures, never production state.

These receipts exercise readers. Managed authentication is covered separately by
codex-review-integration.test.sh through the real launcher and transport.
"""
import json
from pathlib import Path
import re
import sys

root, state, task, actor, text = sys.argv[1:]
sys.path.insert(0, str(Path(root) / 'bin/lib'))
from fm_evidence import Store, verdict_marker

store = Store(state, 'self', task)
text = text.replace('\\n', '\n').replace('\r', '\n')
marker = verdict_marker(text, task)
if marker:
    binding = re.search(r'^REVIEWED:' + re.escape(task) + r' verdict=\w+ head=(\w+) base=(\w+) patch=(\w*)', text, re.M)
    store.append('verdict', 1, actor, binding[1] if binding else '', text,
                 verdict=marker, base=binding[2] if binding else '', patch=binding[3] if binding else '',
                 provenance={'level': 'legacy'})
elif ('ASK-PASS-CRITERIA:' + task) in text.splitlines():
    store.append('ask', 1, actor, 'a' * 40, text)
else:
    store.append('worker-report', 1, actor, 'a' * 40, text)
