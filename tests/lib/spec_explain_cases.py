"""T-230 explain contract, including CLI exit codes and isolated config imports."""
import copy
import json
from pathlib import Path
import shutil
import subprocess
import sys

from ste_cases import card
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'bin/lib'))
import fm_spec_preflight

work = Path(sys.argv[1])
fields = ('intent', 'why', 'scope_in', 'scope_out', 'done', 'notes', 'before_nodes', 'after_nodes')
explain = {lang: {k: v for k, v in loc.items() if k in fields} for lang, loc in card().items()}
spec = dict(id='T-001', title='Plan: The task works.', scope=['tests/plan.test.sh'], acceptance=['The check passes.'], explain=explain)
path = work / 'T-001.json'

def cli(value, code):
    path.write_text(json.dumps(value))
    result = subprocess.run([sys.executable, str(ROOT / 'bin/lib/fm_ste.py'), 'check-explain', str(path)], capture_output=True, text=True)
    assert result.returncode == code, (result.returncode, code, result.stderr)
    return result

assert json.loads(cli(spec, 0).stdout)['ok'] is True
bad = copy.deepcopy(spec)
bad['explain']['en']['done'] = [dict(kind='fact', text='The check passes.')]
assert 'Intent 1' in cli(bad, 64).stderr
try:
    fm_spec_preflight.prompt('T-001', json.dumps(bad), 'a' * 40)
except ValueError as error:
    assert 'explain' in str(error)
else:
    raise AssertionError('preflight accepted missing alignment')
bad = copy.deepcopy(spec)
bad['explain']['en']['before_nodes'] *= 2
assert 'counts' in cli(bad, 64).stderr
bad = copy.deepcopy(spec)
bad['explain']['en']['intent'][0]['text'] = 'Ensure the check passes.'
assert 'en intent: Ensure the check passes. -> R6' in cli(bad, 65).stderr
for field in ('intent', 'done', 'before_nodes', 'after_nodes'):
    bad = copy.deepcopy(spec)
    for loc in bad['explain'].values():
        del loc[field]
    cli(bad, 64)
for forbidden in ('questions', 'change_table'):
    bad = copy.deepcopy(spec)
    for loc in bad['explain'].values():
        loc[forbidden] = []
    cli(bad, 64)
assert json.loads(cli(dict(id='T-001'), 0).stdout) == {'explain': False}
# A standalone copy has no fm_ste to import. Ordinary tasks must still work.
lib = work / 'isolated'
lib.mkdir()
shutil.copy(ROOT / 'bin/lib/fm_config_tasks.py', lib)
tasks = work / 'tasks'
tasks.mkdir()
plain = {k: v for k, v in spec.items() if k != 'explain'}
(tasks / path.name).write_text(json.dumps(plain))
command = [sys.executable, '-I', str(lib / 'fm_config_tasks.py'), 'check', str(tasks)]
result = subprocess.run(command, capture_output=True, text=True)
assert result.returncode == 0, result.stdout
(tasks / path.name).write_text(json.dumps(spec))
result = subprocess.run(command, capture_output=True, text=True)
assert result.returncode == 1 and 'T-001: explain: fm_ste unavailable' in result.stdout
bad = copy.deepcopy(spec)
bad['explain']['en']['done'] = []
(tasks / path.name).write_text(json.dumps(bad))
result = subprocess.run([sys.executable, str(ROOT / 'bin/lib/fm_config_tasks.py'), 'check', str(tasks)], capture_output=True, text=True)
assert result.returncode == 1 and 'T-001: explain:' in result.stdout
