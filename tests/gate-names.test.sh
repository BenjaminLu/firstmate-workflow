#!/usr/bin/env bash
# T-232: stable gate identities and legacy readers. Expected red on base:
# the canonical list is absent, and --only 7 still selects approval.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v bun >/dev/null 2>&1; then
  . "$ROOT/tests/lib/board.sh"
else
  . "$ROOT/tests/lib.sh"
fi
export HERDR_ENV=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export FM_GATE_LOCK="$work/gate.lock"
unset FM_GATE_LOCK_HELD

# (a) One versioned mapping; (b) runner and readers agree.
assert_ok "test -f '$ROOT/bin/lib/fm_gates.json'" 'a: canonical gate list exists'
if [ -f "$ROOT/bin/lib/fm_gates.json" ]; then
  assert_eq '1 branch 2 rebase 3 scope 4 fail-first 5 ci 6 approval' "$(jq -r '.gates[] | "\(.n) \(.name)"' "$ROOT/bin/lib/fm_gates.json" | paste -sd ' ' -)" 'a: six stable identities'
  assert_eq '{"1":"branch","2":"rebase","4":"scope","5":"fail-first","6":"ci","7":"approval"}' "$(jq -c .legacy "$ROOT/bin/lib/fm_gates.json")" 'a: legacy has no retired gate'
  assert_eq '2' "$(jq .version "$ROOT/bin/lib/fm_gates.json")" 'a: version two'
  assert_eq "$(jq -r '.gates[].n' "$ROOT/bin/lib/fm_gates.json")" "$(sed -n 's/^g \([0-9]*\) .*/\1/p' "$ROOT/bin/fm-gate.sh")" 'b: runner agrees with the canonical list'
fi
for only in 7 8 foo 0 ''; do
  out="$(bash "$ROOT/bin/fm-gate.sh" --task T-X --repo "$work" --branch work --only "$only" 2>&1)"; rc=$?
  assert_eq 64 "$rc" "b: invalid selector '$only' is refused"
  if [ "$only" = 7 ]; then
    assert_contains "$out" 'gate numbers changed in T-232: approval is 6' 'b: old approval selector explains migration'
  else
    assert_contains "$out" 'branch, rebase, scope, fail-first, ci, approval' 'b: valid names are listed'
  fi
done

# (j) Missing mapping fails before a gate or binding side effect.
mkdir -p "$work/bin"
cp "$ROOT/bin/fm-gate.sh" "$work/bin/"
out="$(bash "$work/bin/fm-gate.sh" --task T-X --repo "$work" --branch work 2>&1)"; rc=$?
assert_eq 70 "$rc" 'j: missing mapping refuses gate run'
assert_contains "$out" 'bin/lib/fm_gates.json' 'j: refusal identifies canonical file'
assert_lacks "$out" '  + gate' 'j: no gate ran'

# (c,f,h,j) Exercise real readers while replacing remote binding dependencies.
python3 - "$ROOT" "$work" <<'PY'
import contextlib, io, json, os, sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
sys.dont_write_bytecode = True
root, work = map(Path, sys.argv[1:])
sys.path.insert(0, str(root/'bin/lib'))
import fm_binding as B
import fm_evidence as E
import fm_autopilot as A
from fm_autopilot_loop import MechanicalLoop as Loop
mapping = B.gate_list()
names = [g['name'] for g in mapping['gates']]
head, base = 'a'*40, 'b'*40
state = work/'state'; (state/'gates').mkdir(parents=True)
report = state/'gates/transcript.txt'
text = f'HEAD:{head}\nBASE:{base}\nGATES:2\n' + ''.join(f"  + gate {g['n']} ({g['name']}): ok\n" for g in mapping['gates'])
report.write_text(text)
binding = dict(patch='patch',files=['a'],spec_sha256='s',contract_sha256='c',conventions_sha256='v')
review = dict(head=head,base=base,round=1,binding=binding)
rows=[]
class Store:
    def __init__(self,*args):pass
    def records(self):return rows
    def append(self,kind,round,actor,head,text,**kw):
        record=dict(kind=kind,round=round,actor=actor,head=head,text=text,**kw);rows.append(record);return record

def run(mode):
    argv=['binding',mode,'--task','T-X','--pr','9','--head',head,'--gate-report',str(report)]
    with patch.object(sys,'argv',argv), contextlib.redirect_stdout(io.StringIO()): B.main()
with patch.dict(os.environ,FM_TARGET_ROOT=str(work),FM_STATE_DIR=str(state),FM_EVIDENCE_PROJECT='self'), \
     patch.object(B,'repository',return_value='o/r'), patch.object(B,'remote_head',return_value={'headRefOid':head}), \
     patch.object(B,'required_checks',return_value=[{'name':'ci','conclusion':'SUCCESS'}]), \
     patch.object(B,'selected_review',return_value=(review,None)), patch.object(B,'source_binding',return_value=binding), \
     patch.object(B,'verify_current'), patch.object(B,'review_identity',return_value='signed'), \
     patch.object(B,'view_base',return_value='main'), patch.object(B,'git',return_value=base), patch.object(E,'Store',Store):
    run('ready')
    assert rows[-1]['gates'] == names, 'c: readiness must store stable names'
    run('candidate')
    rows[-1]['gates']=[1,2,4,5,6,7] # legacy readiness, never rewritten by candidate
    run('candidate')
    assert rows[-1]['gates']==[1,2,4,5,6,7]
    for broken in [text.replace('GATES:2\n',''),text.replace('(ci)','(approval)'),text+'  x gate 1 (branch): red\n']:
        report.write_text(broken)
        try: run('ready')
        except ValueError: pass
        else: raise AssertionError('c: incomplete or mismatched transcript accepted')
    report.write_text(text)
    with patch.object(B,'__file__',str(work/'missing/fm_binding.py')):
        for mode in ('ready','candidate'):
            try:run(mode)
            except ValueError as e:assert str(e)=='gate list unavailable: bin/lib/fm_gates.json'
            else:raise AssertionError('j: missing map accepted')
        summary=E.summary(Store())
        assert summary[-1]['gates_unmapped'] is True
        assert summary[-1]['gates']==[1,2,4,5,6,7]
    assert E.summary(Store())[-1]['gates']==mapping['gates']
    rows[-1]['gates']=names+[3,'unknown']
    assert E.summary(Store())[-1]['gates']==mapping['gates']

calls=[]
fake=SimpleNamespace(landed=lambda *a:False,policy={'review':'fm'},
    authoritative_head=lambda *a:head, launch_review=lambda *a:calls.append(('review',a)),
    attention=lambda *a:calls.append(('attention',a)),merge_card=lambda *a:calls.append(('merge',a)))
for code, expected in [(6,'review'),(0,'merge'),(3,'stopped at gate 3 (scope)'),(5,'stopped at gate 5 (ci)'),(70,'gate run failed (exit 70)')]:
    Loop.job_completed(fake,dict(kind='gate',task='T-X',pr={'head':{'sha':head}},code=code,round=1,base=base))
    assert expected==calls[-1][0] or expected in calls[-1][1][3], (code,calls)
with patch.object(B,'__file__',str(work/'missing/fm_binding.py')):
    Loop.job_completed(fake,dict(kind='gate',task='T-X',pr={},code=3,round=1,base=base))
    assert 'stopped at gate 3 (gate list unavailable)' in calls[-1][1][3]

pilot=A.Pilot.__new__(A.Pilot)
pilot.ctx={'project':'self'};pilot.data={'pulls':{}};pilot.busy=lambda task:False
pilot.queue=lambda *a,**kw:calls.append(('queue',a));pilot.save=lambda:None
for value in ('approval',7):
    calls.clear();pilot.event(dict(type='gate_failed',task='T-001',data={'gate':value}),'fixture')
    assert calls==[], ('h: approval event belongs to review',value,calls)
pilot.event(dict(type='gate_failed',task='T-001',data={'gate':'ci'}),'fixture')
assert calls[-1][0]=='queue', 'h: other gates still need attention'
PY
assert_eq 0 "$?" 'c/f/h/j: binding, summary, autopilot and missing mapping'

# (d) Extract the real prompt section, preserving its current script location.
# No reviewer or network command is started by this narrow harness.
python3 - "$ROOT" "$work" <<'PY'
import sys
from pathlib import Path
root,work=map(Path,sys.argv[1:])
s=(root/'bin/fm-review.sh').read_text()
a=s.index("  printf '\\n## The gates for this head")
b=s.index('\n}\n',a)
(work/'bin/review-section.sh').write_text('section() {\n'+s[a:b]+'\n}\nsection\n')
PY
mkdir -p "$work/bin/lib" "$work/review-state/gates"
cp "$ROOT/bin/lib/fm_gates.json" "$work/bin/lib/"
for version in legacy new; do
  file="$work/review-state/gates/T-X-abc.txt"
  if [ "$version" = new ]; then
    { echo GATES:2; echo '  + gate 1 (branch): ok'; echo '  x gate 2 (rebase): bad'; } > "$file"
  else
    { echo '  + gate 1: ok'; echo '  x gate 2: bad'; } > "$file"
  fi
  out="$(FM_STATE_DIR="$work/review-state" TASK=T-X sha=abc bash "$work/bin/review-section.sh")"
  assert_contains "$out" '3 (scope), 4 (fail-first), 5 (ci), 6 (approval)' "d: $version missing results use new identities"
  if [ "$version" = legacy ]; then
    assert_contains "$out" 'old gate numbers (before T-232): 4 scope, 5 fail-first, 6 ci, 7 approval' 'd: legacy warning'
  else
    assert_lacks "$out" 'old gate numbers' 'd: v2 is not legacy'
  fi
done
rm "$work/bin/lib/fm_gates.json"
out="$(FM_STATE_DIR="$work/review-state" TASK=T-X sha=abc bash "$work/bin/review-section.sh")"
assert_contains "$out" 'gate list unavailable (bin/lib/fm_gates.json missing); gate results unknown' 'j: review missing map'

# (e,j) Emission validates names, preserves fixture legacy values and maps wakes.
for value in 5 '"nope"'; do
  out="$(FM_ROOT="$work/events" bash "$ROOT/bin/fm-emit.sh" --actor autopilot --task T-X --type gate_failed --data "{\"gate\":$value}" 2>&1)"; rc=$?
  assert_eq 64 "$rc" "e: invalid new gate $value refused"
  assert_contains "$out" 'data.gate takes a gate name since T-232' 'e: explains name requirement'
done
FM_ROOT="$work/events" bash "$ROOT/bin/fm-emit.sh" --actor autopilot --task T-X --type gate_failed --data '{"gate":"ci"}'
assert_eq 0 "$?" 'e: name accepted'
assert_contains "$(cat "$work/events/state/session/wake.jsonl")" 'failed gate 5 (ci)' 'e: named wake'
FM_EMIT_LEGACY_GATE=1 FM_ROOT="$work/events" bash "$ROOT/bin/fm-emit.sh" --actor autopilot --task T-X --type gate_failed --data '{"gate":6}'
assert_eq 6 "$(tail -1 "$work/events/state/events.jsonl" | jq .data.gate)" 'e: legacy number stored unchanged'
assert_contains "$(tail -1 "$work/events/state/session/wake.jsonl")" 'failed gate 5 (ci)' 'e: legacy wake uses current identity'
cp "$ROOT/bin/fm-emit.sh" "$work/bin/"
out="$(FM_ROOT="$work/events" bash "$work/bin/fm-emit.sh" --actor worker-fixture --task T-X --type gate_failed --data '{"gate":"ci"}' 2>&1)"; rc=$?
assert_eq 70 "$rc" 'j: emitter missing map refuses gate payload'
assert_contains "$out" 'bin/lib/fm_gates.json' 'j: emitter names missing mapping'
FM_ROOT="$work/events" bash "$work/bin/fm-emit.sh" --actor worker-fixture --task T-X --type dispatched
assert_eq 0 "$?" 'j: unrelated event survives missing map'
# (i) Selectors are normalized before binding and behind-base diagnostics.
mkdir -p "$work/runner/bin/lib"
cp "$ROOT/bin/fm-gate.sh" "$work/runner/bin/"
cp "$ROOT/bin/lib/fm_gates.json" "$work/runner/bin/lib/"
: > "$work/runner/bin/lib/fm-stack.sh"
cat > "$work/runner/bin/fm-config.sh" <<'SH'
fm_storage_init() { FM_TARGET_ROOT="$1"; FM_EXTERNAL=0; FM_STATE_DIR="$1/state"; }
fm_target_validate() { :; }
fm_binding() {
  echo "$1" >> "$FM_TARGET_ROOT/bindings"
  case "$1" in head) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;; base|local-gate-base) echo main ;; esac
}
fm_evidence() { :; }
git() {
  case "$1" in rev-parse|merge-base) echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;; rev-list) echo 2 ;; diff-tree|patch-id) : ;; esac
}
SH
for only in 5 ci 6 approval; do
  : > "$work/runner/bindings"
  out="$(env -u FM_PROJECT FM_GATE_LOCK="$work/runner.lock" bash "$work/runner/bin/fm-gate.sh" --repo "$work/runner" --task T-X --branch work --pr 9 --only "$only" 2>&1)"; rc=$?
  assert_eq 0 "$rc" "i: selector $only works"
  if [ "$only" = 5 ] || [ "$only" = ci ]; then
    assert_contains "$(cat "$work/runner/bindings")" 'head' "i: $only binds authoritative head"
    assert_contains "$out" 'behind the base by 2 commits' "i: $only prints behind diagnostic"
    assert_contains "$out" '+ gate 5 (ci):' 'b: runner prints stable name'
  else
    assert_eq local-gate-base "$(cat "$work/runner/bindings")" "i: $only uses local base"
    assert_lacks "$out" 'behind the base by' "i: $only does not print CI diagnostic"
    assert_contains "$out" '+ gate 6 (approval):' 'b: approval name works'
  fi
done

# (g,j) Actual board API maps legacy events and starts without the list.
if command -v bun >/dev/null 2>&1; then
  . "$ROOT/tests/lib/project-storage.sh"
  boardroot="$work/board-fixture"
  mkdir -p "$boardroot/bin" "$boardroot/board/public" "$boardroot/design/tasks"
  cp -R "$ROOT/bin/lib" "$boardroot/bin/"
  project_storage_fixture "$boardroot/bin"
  cp "$ROOT/board/server.ts" "$boardroot/board/"
  cp "$ROOT/board/public/index.html" "$boardroot/board/public/"
  cp -R "$ROOT/i18n" "$boardroot/"
  printf '{"id":"T-001","title":"gate fixture","depends_on":[]}\n' > "$boardroot/design/tasks/T-001.json"
  for missing in no yes; do
    [ "$missing" = no ] || rm "$boardroot/bin/lib/fm_gates.json"
    FM_ROOT="$boardroot" FM_PORT=0 python3 "$ROOT/bin/lib/fm_lifeline.py" keep --pid "$$" --name gate-names-board -- bun run "$boardroot/board/server.ts" > "$work/board-$missing.log" 2>&1 &
    pid=$!
    trap 'kill "${pid:-}" 2>/dev/null || true; wait "${pid:-}" 2>/dev/null || true; rm -rf "$work"' EXIT
    port="$(board_port "$work/board-$missing.log" "$pid")"
    if [ "$missing" = no ]; then
      assert_eq "$(jq -c .gates "$ROOT/bin/lib/fm_gates.json")" "$(curl -sf "http://127.0.0.1:$port/api/state" | jq -c .gates)" 'g: board agrees with canonical gates'
      for value in '"ci"' 6 7 3; do
        FM_EMIT_LEGACY_GATE=1 FM_ROOT="$boardroot" bash "$ROOT/bin/fm-emit.sh" --actor worker-fixture --task T-001 --type gate_failed --data "{\"gate\":$value}"
        case "$value" in 7) expected='{"n":6,"name":"approval"}' ;; 3) expected=null ;; *) expected='{"n":5,"name":"ci"}' ;; esac
        assert_eq "$expected" "$(curl -sf "http://127.0.0.1:$port/api/state" | jq -c '.tasks[]|select(.id=="T-001")|.badges[]|select(.kind=="gate")|.gate')" "g: badge maps $value"
      done
    else
      state="$(curl -sf "http://127.0.0.1:$port/api/state")"
      assert_eq '[]' "$(jq -c .gates <<<"$state")" 'j: missing map yields empty gate list'
      assert_eq null "$(jq -c '.tasks[]|select(.id=="T-001")|.badges[]|select(.kind=="gate")|.gate' <<<"$state")" 'j: missing map yields null badge'
      assert_eq 1 "$(grep -c 'gate list unavailable: bin/lib/fm_gates.json' "$work/board-$missing.log")" 'j: one warning on startup'
    fi
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    pid=''
  done
else
  assert_fail true 'g/j: Bun required for board acceptance'
fi
finish
