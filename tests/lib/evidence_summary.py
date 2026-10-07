"""Summary exposes a fixed projection of verified evidence, never body fields."""
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'bin/lib'))
from fm_evidence import Store

for external in (False, True):
    state = Path(sys.argv[1]) / str(external)
    store = Store(state, 'self', 'T-001', external=external)
    store.append('brief', 1, 'firstmate', 'a'*40, 'Brief headline\nBEGIN PRIVATE BRIEF')
    store.append('worker-report', 1, 'worker-imani', 'a'*40, 'BEGIN PRIVATE REPORT')
    store.append('verdict', 1, 'reviewer-lee', 'a'*40, 'BEGIN PRIVATE VERDICT', verdict='APPROVE', provenance={'level':'legacy'})
    store.append('readiness', 1, 'firstmate', 'a'*40, '', gate_base='b'*40, gates=[1,2,4,5,6,7], checks=[{'name':'ci','conclusion':'SUCCESS','private':'BEGIN'}], review={'text':'BEGIN PRIVATE REVIEW'})
    store.append('readiness', 2, 'firstmate', 'b'*40, '', gates=['branch','rebase','scope','fail-first','ci','approval'])
    cmd = [sys.executable, str(ROOT / 'bin/lib/fm_evidence.py'), 'summary', '--state', str(state), '--project', 'self', '--task', 'T-001'] + (['--external'] if external else [])
    result = subprocess.run(cmd, capture_output=True, text=True, env={**os.environ, 'FM_EXTERNAL': '0'})
    assert result.returncode == 0, result.stderr
    rows = json.loads(result.stdout)
    assert rows[0]['brief'] == 'Brief headline'
    assert rows[2]['verdict'] == 'APPROVE'
    assert rows[4]['gates'] == rows[3]['gates']
    assert rows[3]['checks'] == [{'name':'ci','conclusion':'SUCCESS'}]
    assert rows[3]['gates'] == json.loads((ROOT/'bin/lib/fm_gates.json').read_text())['gates']
    assert all(set(r) <= {'kind','round','actor','head','verdict','time','brief','gate_base','gates','checks'} for r in rows)
    assert 'BEGIN' not in result.stdout and 'signature' not in result.stdout
    file = sorted(store.directory.glob('[0-9]*.json'))[0]
    value = json.loads(file.read_text())
    value['text'] = 'Forged brief'
    file.write_text(json.dumps(value))
    result = subprocess.run(cmd, capture_output=True, text=True, env={**os.environ, 'FM_EXTERNAL': '0'})
    assert result.returncode != 0 and not result.stdout

    value['text'] = 'Brief headline\nBEGIN PRIVATE BRIEF'
    file.write_text(json.dumps(value))
    store.key_path.unlink()
    result = subprocess.run(cmd, capture_output=True, text=True, env={**os.environ, 'FM_EXTERNAL': '0'})
    assert result.returncode != 0 and 'evidence-signing' not in result.stderr
