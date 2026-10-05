#!/usr/bin/env bash
# T-211: chosen=change never confers readiness or pin authority or repairs C/D.
# Dependencies: bin/fm-ready.sh bin/fm-reconcile.sh bin/lib/fm_spec_pins.py bin/lib/fm_watch.py
set -uo pipefail
for key in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do unset "$key" || true; done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/lib/project-storage.sh"
x="$(safe_tmpdir)"
trap 'rm -rf "$x"' EXIT
mkdir -p "$x/bin" "$x/design/tasks" "$x/state/decisions"
cp "$ROOT/bin/fm-ready.sh" "$ROOT/bin/fm-reconcile.sh" "$ROOT/bin/fm-emit.sh" "$x/bin/"
project_storage_fixture "$x/bin/"
printf '%s\n' '{"id":"T-211","title":"Intent cards","depends_on":[]}' > "$x/design/tasks/T-211.json"
: > "$x/state/events.jsonl"
bash "$x/bin/fm-ready.sh" judged --task T-211 --decision D-211 --repo "$x" >/dev/null
for pick in A C D; do
  jq -cn --arg picked "$pick" '{id:"D-211",task:"T-211",kind:"choice",chosen:"change",picked:$picked,answers:[{index:0,ok:false,text:"Revise"}],effect:null,effect_outcome:"recorded",merge:null}' > "$x/state/decisions/D-211.json"
  jq -cn --arg picked "$pick" '{type:"decision_made",task:"T-211",actor:"captain",ts:"2026-10-05T00:00:00Z",data:{decision:"D-211",chosen:"change",picked:$picked,outcome:"recorded"}}' > "$x/state/events.jsonl"
  assert_eq '' "$(bash "$x/bin/fm-ready.sh" cleared --repo "$x")" "change picked $pick never clears readiness"
  out="$(bash "$x/bin/fm-reconcile.sh" --repair-cards --repo "$x" 2>&1)"; rc=$?
  assert_eq 0 "$rc" 'repair command succeeds'
  assert_contains "$out" 'cards: nothing to repair' "change picked $pick is never repaired as park/drop"
done
# Positive control: this same readiness episode does confer authority for A.
jq '.chosen="A"' "$x/state/decisions/D-211.json" > "$x/yes.json"
cp "$x/yes.json" "$x/state/decisions/D-211.json"
assert_eq T-211 "$(bash "$x/bin/fm-ready.sh" cleared --repo "$x")" 'the fixture has a current readiness episode'
PYTHONPATH="$ROOT/bin/lib" python3 - "$x" <<'PY'
import json, sys
from pathlib import Path
from fm_spec_pins import Pins
from fm_watch import wake_line
root = Path(sys.argv[1])
env = dict(FM_ENGINE_ROOT=str(root), FM_TARGET_ROOT=str(root), FM_STATE_DIR=str(root/'state'),
           FM_TASKS_DIR=str(root/'design/tasks'), FM_DESIGN=str(root/'design/design.md'))
pins = Pins(env, 'T-211')
path = root/'state/decisions/D-211.json'
record = json.loads(path.read_text())
record.update(chosen='change', picked='A')
path.write_text(json.dumps(record))
assert pins.answer('D-211') is None, 'picked A on a change record is not pin approval'
assert pins.approval() is None, 'a readiness change record supplies no approval'
try:
    pins.approval('D-211')
except ValueError:
    pass
else:
    raise AssertionError('explicit change authorization must be refused')
assert wake_line({'id':'D-211','reason':'answered','decision':record}) == 'card: D-211 answered change'
record['chosen'] = 'A'
path.write_text(json.dumps(record))
event = dict(type='decision_made',task='T-211',actor='captain',ts='2026-10-05T00:00:00Z',data=dict(decision='D-211',chosen='A'))
(root/'state/events.jsonl').write_text(json.dumps(event)+'\n')
assert pins.approval('D-211')['decision'] == 'D-211', 'positive control really approves A'
PY
assert_eq 0 "$?" 'pin and watch consumers distinguish a change request from approval'
finish
