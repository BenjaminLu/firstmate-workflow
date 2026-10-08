#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Shared feature cases: tests/lib/task_detail_fixture.py
. "$ROOT/tests/lib/board.sh"
. "$ROOT/tests/lib/project-storage.sh"
g="$(safe_tmpdir)"
XDG_CONFIG_HOME="$(safe_tmpdir)"; export XDG_CONFIG_HOME
pid=''
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; safe_rm_rf "$g"; safe_rm_rf "$XDG_CONFIG_HOME"' EXIT
mkdir -p "$g/bin" "$g/board/public" "$g/state/pending" "$g/state/decisions" "$g/design/tasks"
cp -R "$ROOT/bin/lib" "$g/bin/"
project_storage_fixture "$g/bin"
cp "$ROOT/board/server.ts" "$g/board/"
cp "$ROOT/board/public/index.html" "$g/board/public/"
cp -R "$ROOT/i18n" "$g/"
cp "$ROOT/bin/fm-diagram.sh" "$g/bin/"
python3 "$ROOT/tests/lib/task_detail_fixture.py" "$g" "$g/state" self
FM_ROOT="$g" FM_PORT=0 python3 "$ROOT/bin/lib/fm_lifeline.py" keep --pid "$$" --name task-detail-board -- bun run "$g/board/server.ts" > "$g/out" 2>&1 &
pid=$!
port="$(board_port "$g/out" "$pid")"
url="http://127.0.0.1:$port"
curl -s "$url/api/task?id=T-003" > "$g/detail"
assert_eq Plan "$(jq -r '.task.headline' "$g/detail")" 'ready task detail splits the title'
assert_eq ready "$(jq -r '.task.stage' "$g/detail")" 'undispatched task is ready'
assert_eq T-003 "$(curl -s "$url/api/task?project=&id=T-003" | jq -r '.task.id')" 'empty project selects the default'
assert_eq array "$(jq -r '.task.acceptance|type' "$g/detail")" 'acceptance is an array'
assert_eq object "$(jq -r '.task.explain|type' "$g/detail")" 'task explain is returned'
assert_eq 'The task works.' "$(jq -r '.task.detail' "$g/detail")" 'detail retains the rest of the title'
assert_eq true "$(jq '.task.explain_ste.ok' "$g/detail")" 'spec explain has an STE report'
assert_eq 'acceptance scope' "$(jq -r '.tests[].source' "$g/detail" | paste -sd' ' -)" 'planned tests keep source and deduplicate'
assert_eq 405 "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url/api/task?id=T-001")" 'task endpoint is GET only'
assert_eq 404 "$(curl -s -o /dev/null -w '%{http_code}' "$url/api/task?id=T-999")" 'unknown task is JSON 404'
assert_eq 404 "$(curl -s -o /dev/null -w '%{http_code}' "$url/api/task?project=missing&id=T-001")" 'unknown project refuses'
assert_eq SK-001 "$(curl -s "$url/api/task?id=SK-001" | jq -r '.task.id')" 'SK tasks resolve'
curl -s "$url/api/task?id=T-002" > "$g/merged"
assert_eq 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$(jq -r '.rounds[0].head' "$g/merged")" 'review evidence supplies head in nameless self namespace'
assert_eq null "$(jq -r '.rounds[1].head' "$g/merged")" 'push events never supply heads'
assert_eq 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$(jq -r '.rounds[0].worker_head' "$g/merged")" 'worker report supplies its own head'
assert_eq null "$(jq -r '.external_review' "$g/merged")" 'self task suppresses external review records'
assert_eq APPROVE "$(jq -r '.rounds[0].verdict' "$g/merged")" 'verdict marker is public metadata'
assert_eq codex "$(jq -r '.rounds[0].worker_vendor' "$g/merged")" 'round vendor comes from the identity payload'
assert_eq 'Brief headline' "$(jq -r '.brief' "$g/merged")" 'only brief first line is public'
assert_eq SUCCESS "$(jq -r '.readiness.checks[0].conclusion' "$g/merged")" 'readiness checks survive projection'
assert_eq "$(jq -c .gates "$ROOT/bin/lib/fm_gates.json")" "$(jq -c '.readiness.gates' "$g/merged")" 'readiness gates survive projection'
assert_eq false "$(jq '[..|strings|select(contains("BEGIN") or contains("evidence-signing"))]|length>0' "$g/merged")" 'no private evidence bodies'
assert_eq false "$(jq '.readiness|has("review")' "$g/merged")" 'readiness review body is absent'
curl -s "$url/api/task?id=T-001" > "$g/detail"
assert_eq "$(jq -c .gates "$ROOT/bin/lib/fm_gates.json")" "$(jq -c .readiness.gates "$g/detail")" 'name-list readiness matches legacy projection'
assert_eq '["D-1"]' "$(jq -c '[.cards[].id]' "$g/detail")" 'withdrawn cards stay out of history'
assert_eq true "$(jq '.cards[0].ste_ok' "$g/detail")" 'pending card keeps STE status'
wcurl "$port" -s -H 'Content-Type: application/json' -d '{"id":"D-1","chosen":"C","answers":[{"index":0,"ok":true}]}' "$url/decisions" > "$g/answer"
assert_eq true "$(jq '.details != null and .purpose != null and .title != null and .ste.ok' "$g/state/decisions/D-1.json")" 'answer retains authored fields'
assert_eq false "$(jq '.decision|has("details") or has("purpose") or has("title") or has("ste")' "$g/answer")" 'POST answer projection omits authored fields'
assert_eq false "$(wcurl "$port" -s -H 'Content-Type: application/json' -d '{"id":"D-1","chosen":"C","answers":[{"index":0,"ok":true}]}' "$url/decisions" | jq '.decision|has("details") or has("purpose") or has("title") or has("ste")')" 'repeat answer projection omits authored fields'
assert_eq false "$(curl -s "$url/api/state" | jq '.responses[]|select(.id=="D-1")|has("details") or has("purpose") or has("title") or has("ste")')" 'state projection omits authored fields'
assert_eq false "$(jq '.decision|has("details") or has("purpose") or has("title") or has("ste")' "$g/state/session/wake.jsonl" | head -1)" 'wake projection omits authored fields'
assert_eq true "$(curl -s "$url/api/task?id=T-001" | jq '.cards[]|select(.id=="D-1")|.ste_ok and .ste.ok and (.details!=null)')" 'answered detail and STE stay readable'
assert_eq null "$(jq -r '.cards[0].ste_ok' "$g/merged")" 'legacy card has no invented STE report'
assert_eq false "$(jq '.cards[0]|has("details")' "$g/merged")" 'legacy record gains no details'
assert_eq null "$(curl -s "$url/api/task?id=T-002" | jq -r '.task.explain_ste')" 'legacy spec has no invented explain report'
bash "$g/bin/fm-diagram.sh" --repo "$g" --task T-001 > "$g/draw" 2>&1
assert_eq 0 "$?" 'task diagram renders'
assert_eq true "$(curl -s "$url/api/task?id=T-001&lang=en" | jq '.task.diagram')" 'task detail reports its locale diagram'
assert_contains "$(cat "$g/board/public/diagrams/task-T-001.en.html")" 'The check passes.' 'task diagram contains the explain node labels'
for locale in en zh-TW zh-CN; do
  assert_eq 200 "$(curl -s -o /dev/null -w '%{http_code}' "$url/diagrams/task-T-001.$locale.html")" "nameless task diagram: $locale"
done
bash "$g/bin/fm-diagram.sh" --repo "$g" --task T-002 > "$g/draw" 2>&1
assert_eq 64 "$?" 'task without explain refuses a diagram'
assert_contains "$(cat "$g/draw")" 'task has no explain' 'task diagram refusal names the missing explain'
python3 - "$g/state" <<'PY'
import json,sys
from pathlib import Path
p=next((Path(sys.argv[1])/'evidence/self/T-002').glob('*.json'))
r=json.loads(p.read_text());r['text']='FORGED';p.write_text(json.dumps(r))
PY
assert_eq 200 "$(curl -s -o "$g/forged" -w '%{http_code}' "$url/api/task?id=T-002")" 'unreadable evidence does not fail the task read'
assert_eq null "$(jq -r '.readiness' "$g/forged")" 'forged evidence clears readiness'
assert_contains "$(jq -r '.notes[]' "$g/forged")" 'evidence unreadable:' 'unreadable evidence is explicit'
assert_eq '[null,null]' "$(jq -c '[.rounds[].head]' "$g/forged")" 'forged evidence cannot supply any head'
# Same ids in two stores must not cross project boundaries.
cat > "$g/config.yaml" <<Y
vendor: claude
default_project: alpha
projects:
  alpha:
    repo: .
    github: example/alpha
    base: main
    required_check: ci
  beta:
    github: example/beta
    base: main
    required_check: ci
Y
project_fixture_config "$g"
external="$(project_fixture_state "$g" beta)"
python3 "$ROOT/tests/lib/task_detail_fixture.py" "$g" "$external" beta
curl -s "$url/api/task?project=beta&id=T-002" > "$g/beta"
assert_eq CHANGES_REQUESTED "$(jq -r '.external_review.states.Rev.state' "$g/beta")" 'external reviewer states are projected'
assert_eq '[true,false]' "$(jq -c '[.external_review.findings[].current]' "$g/beta")" 'findings mark the record head'
assert_eq 'src/x.py:9' "$(jq -r '.external_review.findings[0]|.path+":"+(.line|tostring)' "$g/beta")" 'finding location survives'
assert_eq false "$(jq '[..|strings|select(contains("BEGIN") or contains("SECRET-EXTERNAL-BODY"))]|length>0' "$g/beta")" 'external review bodies stay private'
assert_eq beta "$(jq -r '.task.project' "$g/beta")" 'external task resolves from its own spec'
assert_eq 'Brief headline beta' "$(jq -r '.brief' "$g/beta")" 'external evidence is isolated'
assert_eq 'D-beta-T002-1' "$(jq -r '.cards[0].id' "$g/beta")" 'external cards are isolated'
assert_eq 'worker-beta' "$(jq -r '.rounds[0].worker' "$g/beta")" 'external rounds are isolated'
assert_eq null "$(curl -s "$url/api/task?project=alpha&id=T-002" | jq -r '.brief')" 'default forged evidence never falls through to external evidence'
bash "$g/bin/fm-diagram.sh" --repo "$g" --project beta --task T-001 > "$g/draw" 2>&1
assert_eq 0 "$?" 'external task diagram renders'
assert_eq 200 "$(curl -s -o /dev/null -w '%{http_code}' "$url/diagrams/task-beta-T-001.en.html")" 'external task diagram serves from its store'
assert_eq 404 "$(curl -s -o /dev/null -w '%{http_code}' "$url/diagrams/task-beta-T-002.en.html")" 'missing external diagram is 404'
assert_eq false "$(jq --arg secret "$(secret_of "$port")" '[..|strings|select(contains($secret))]|length>0' "$g/beta")" 'task never returns board credential'
finish
