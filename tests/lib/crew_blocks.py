"""Execute unchanged launcher blocks with controlled boundary functions.

No launcher is rewritten and no git/network mutation is performed. The tests
exercise shell control flow and the real private-policy helpers; lifecycle,
transport and git are outside these blocks' contract.
"""
import os
from pathlib import Path
import re
import subprocess


def section(path, start, end):
    text = Path(path).read_text()
    return text[text.index(start):text.index(end, text.index(start))]


def function(path, name):
    text = Path(path).read_text()
    match = re.search(r'^' + re.escape(name) + r'\(\) \{.*?^\}', text, re.M | re.S)
    if not match:
        raise AssertionError('launcher function missing: ' + name)
    return match.group(0) + '\n'


def shell(root, home, body, prefix=''):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('FM_', 'HERDR_')) and k != 'GH_REPO'}
    env.update(FM_EXTERNAL='1', FM_STATE_DIR=str(home/'state'), FM_PROJECT='app',
               FM_CONFIG=str(home/'config.yaml'), GH_REPO='owner/app', FM_BASE='main',
               PYTHONDONTWRITEBYTECODE='1')
    setup = '''
. "$1/bin/fm-config.sh"
TASK=T-Z; PR=9; BASE=main; R_HEAD=abc; R_BASE=base; round_head=abc; ROUND=1; REPO="$1"
FM_SPEC_PIN_JSON=
work="$2"; tree="$2/tree"; branch=task; spec='{"title":"Private intent"}'
FM_DESIGN="$work/design.md"
GH="$2/gh"; export FM_GH="$GH"
fm_project_get() { printf '%s\n' "$work/CONVENTIONS.md"; }
fm_projection() { printf '%s\n' "${projection:-comments}"; }
fm_comment_projection() { printf '%s\n' "$*" >> "$work/comments"; }
emit() { printf '%s\n' "$*" >> "$work/events"; }
emit_status() { printf '%s\n' "$*" >> "$work/events"; }
scratch_new() { mktemp "$work/scratch.XXXXXX"; }
scratch_add() { :; }
worker_changed_files() { return 1; }
'''
    return subprocess.run(['bash', '-c', setup + prefix + '\n' + body, '_', str(root), str(home)],
                          env=env, capture_output=True, text=True, timeout=15)
