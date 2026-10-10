#!/usr/bin/env bash
# The board's side of the periodic retrospective (T-273), over HTTP.
# POST /retro records a request through bin/lib/fm_retro.py and wakes
# firstmate; POST /decisions takes A with one answer per item, or C, on a
# retrospective card, and every other card behaves as before.
#
# Fail-first on a tree without the retro: the board records no item_answers
# on a retrospective card fixture and accepts a B on it. POST /retro needs
# bin/lib/fm_retro.py; without it those cases print SKIP and are not evidence.
# Feature dependencies: board/server.ts bin/lib/fm_retro.py
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
# shellcheck source=tests/lib/board.sh
. "$ROOT/tests/lib/board.sh"
export HERDR_ENV=0
XDG_CONFIG_HOME="$(safe_tmpdir)"; export XDG_CONFIG_HOME
skip() { printf '    %-52sSKIP (not evidence: %s)\n' "$1" "$2"; }
x="$(safe_tmpdir)"; mkdir -p "$x/bin" "$x/state/pending" "$x/state/decisions" "$x/design/tasks" "$x/board/public"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-decide.sh" "$ROOT/bin/fm-herdr.py" "$x/bin/"
project_storage_fixture "$x/bin/"
cp -R "$ROOT/bin/lib" "$x/bin/"
cp "$ROOT/board/server.ts" "$x/board/"
cp "$ROOT/board/public/index.html" "$x/board/public/"
printf 'retro:\n  vendor: claude\n  model: claude-opus-5-5\n' > "$x/config.yaml"
: > "$x/state/events.jsonl"
have_retro=0; [ -f "$x/bin/lib/fm_retro.py" ] && have_retro=1

# Every process this suite starts is owned through bin/lib/fm-lifeline.sh by
# this shell, and stopped by the EXIT trap on any exit, normal or not (T-151).
# Readiness is pushed, never polled: the board's output goes through a FIFO
# to a reader that copies it to "$1/out" and, on the board's own "board on"
# line, writes "$1/ready" and rings; this shell waits on that ring.
keepers="$x.keepers"; : > "$keepers"
cleanup() { stop_pids "$keepers"; safe_rm_rf "$x"; safe_rm_rf "$XDG_CONFIG_HOME"; rm -f "$keepers" "$x.reader.py" "$x.stop"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
owned() {   # owned <log> <command...>: start it owned by this shell; its keeper pid
  bash "$ROOT/bin/lib/fm-lifeline.sh" --owner-pid "$$" --log "$1" -- "${@:2}"
}
# the reader: copies the board's output to <root>/out and, at the listening
# line, writes <root>/ready and rings the doorbells under <root>
cat > "$x.reader.py" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[3])
import fm_lifeline
fifo, root = sys.argv[1], sys.argv[2]
ready = os.path.join(root, 'ready')
with open(fifo, 'rb') as source, open(os.path.join(root, 'out'), 'ab', buffering=0) as out:
    for line in source:
        out.write(line)
        if line.startswith(b'board on http://127.0.0.1:') and not os.path.exists(ready):
            with open(ready + '.tmp', 'wb') as note:
                note.write(line)
            os.replace(ready + '.tmp', ready)
            fm_lifeline.ring(root, 'board ready')
PY
start() {   # start <root> [env...]: sets $pid and $port once the board is listening
  local fifo="$1/board.fifo"
  rm -f "$fifo" "$1/ready" "$1/out"; mkfifo "$fifo"
  owned /dev/null python3 "$x.reader.py" "$fifo" "$1" "$ROOT/bin/lib" >> "$keepers"
  pid="$(env "${@:2}" FM_ROOT="$1" FM_PORT=0 bash "$ROOT/bin/lib/fm-lifeline.sh" --owner-pid "$$" --log "$fifo" -- bun run "$1/board/server.ts")"
  printf '%s\n' "$pid" >> "$keepers"
  bash "$ROOT/bin/lib/fm-lifeline.sh" await "$1" "$1/ready" 60 || {
    assert_eq 'board listening' 'no ready line' 'the fixture board starts'; cat "$1/out" >&2; exit 1; }
  port="$(sed -n 's|^board on http://127\.0\.0\.1:\([0-9][0-9]*\).*|\1|p' "$1/ready")"
}
stop() {   # stop: end the board started last (the EXIT trap ends the rest)
  printf '%s\n' "$pid" > "$x.stop"
  stop_pids "$x.stop"
}
start "$x"
retro() {   # retro <body>: the HTTP status, the body in $x/resp
  wcurl "$port" -s -m 30 -o "$x/resp" -w '%{http_code}' -X POST -H 'content-type: application/json' -d "$1" "http://127.0.0.1:$port/retro"
}
decide() {   # decide <json>: the HTTP status, the body in $x/post
  wcurl "$port" -s -m 30 -o "$x/post" -w '%{http_code}' -X POST -H 'content-type: application/json' -d "$1" "http://127.0.0.1:$port/decisions"
}

# --- POST /retro --------------------------------------------------------------
# A tree without the retro has no POST /retro at all: every case here is a
# skip there, never evidence.
if [ "$have_retro" = 1 ]; then
  signed_out="$(curl -s -o "$x/resp" -w '%{http_code}' -X POST -H "Origin: http://127.0.0.1:$port" \
    -H 'content-type: application/json' -d '{}' "http://127.0.0.1:$port/retro")"
  assert_eq 403 "$signed_out" 'POST /retro without the signed-in credential is refused'
  assert_ok "[ ! -d '$x/state/retro/requests' ]" 'and records no request'
  assert_eq 400 "$(retro '{"project":"quoll-ledger"}')" 'a body naming a project is refused'
  assert_eq 200 "$(retro '{}')" 'the captain requests a retrospective'
  request="$(jq -r .request "$x/resp")"
  assert_ok "[ -f '$x/state/retro/requests/$request.json' ]" 'the request is recorded by fm_retro.py'
  assert_eq 'board' "$(jq -r .source "$x/state/retro/requests/$request.json")" 'from the board'
  assert_eq "retro-request-$request retro_requested" \
    "$(jq -r 'select(.reason=="retro_requested")|.id+" "+.reason' "$x/state/session/wake.jsonl")" 'and firstmate is woken once'
  assert_eq 409 "$(retro '{}')" 'a second request while one waits is busy'
  assert_eq retroBusy "$(jq -r .code "$x/resp")" 'with the retroBusy code'
  rm -f "$x/state/retro/requests/"*.json
  # two requests at once, each an owned child that writes its status, then
  # rings; this shell waits on the rings, not on a pid
  for n in 1 2; do
    owned /dev/null bash -c 'code="$(curl -s -m 30 -o /dev/null -w "%{http_code}" -X POST -H "Origin: http://127.0.0.1:$1" \
      -H "Authorization: Bearer $2" -H "content-type: application/json" -d "{}" "http://127.0.0.1:$1/retro")"
      printf "%s\n" "$code" > "$3.tmp" && mv "$3.tmp" "$3"; python3 "$4/fm_lifeline.py" ring "$5" race' \
      race "$port" "$(secret_of "$port")" "$x/race-$n" "$ROOT/bin/lib" "$x" >> "$keepers"
  done
  for n in 1 2; do
    bash "$ROOT/bin/lib/fm-lifeline.sh" await "$x" "$x/race-$n" 60 || assert_eq "race $n" 'no answer' 'each simultaneous request answers'
  done
  assert_eq '200 409' "$(cat "$x/race-1" "$x/race-2" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')" 'two simultaneous requests: one accepted, one busy'
  rm -f "$x/state/retro/requests/"*.json
  open='20261009T120000Z-abcdef'
  mkdir -p "$x/state/retro/$open"
  printf '{"state":"awaiting-answer"}\n' > "$x/state/retro/$open/state.json"
  jq --arg r "$open" '.open_run=$r' "$x/state/retro/index.json" > "$x/i" && mv "$x/i" "$x/state/retro/index.json"
  assert_eq 409 "$(retro '{}')" 'a request while a run is open is busy'
else
  skip 'POST /retro requests' 'bin/lib/fm_retro.py is absent'
fi

# --- POST /decisions on a retrospective card -------------------------------------
card() {   # card <id>: a pending retrospective card with two items
  python3 - "$ROOT" "$x/state/pending/$1.json" "$1" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1] + '/tests/lib')
from ste_cases import retro_card
details = retro_card('ok')
json.dump(dict(id=sys.argv[3], kind='choice', purpose='retro', details=details, title=details['en']['title'],
               expected_head='', binding=None), open(sys.argv[2], 'w'))
PY
}
card D-1000
# send <id> <chosen> [item_answers JSON]: the HTTP status, the body in $x/post
send() {
  local body
  if [ "$#" -ge 3 ]; then
    body="$(jq -cn --arg i "$1" --arg c "$2" --argjson a "$3" '{id:$i,chosen:$c,text:"why",item_answers:$a}')"
  else
    body="$(jq -cn --arg i "$1" --arg c "$2" '{id:$i,chosen:$c,text:"why"}')"
  fi
  decide "$body"
}
items='[{"index":0,"id":"self/R1","choice":"A"},{"index":1,"id":"P-0a1b2c3d/R2","choice":"D"}]'
for chosen in B D custom; do
  assert_eq 400 "$(send D-1000 "$chosen")" "a retro card refuses $chosen"
done
assert_eq 'bad choice' "$(jq -r .error "$x/post")" 'as a bad choice'
for bad in 'null' '[]' '[{"index":0,"id":"self/R1","choice":"A"}]' \
  '[{"index":0,"id":"P-0a1b2c3d/R2","choice":"A"},{"index":1,"id":"self/R1","choice":"D"}]' \
  '[{"index":0,"id":"self/R1","choice":"B"},{"index":1,"id":"P-0a1b2c3d/R2","choice":"D"}]' \
  '[{"index":1,"id":"self/R1","choice":"A"},{"index":1,"id":"P-0a1b2c3d/R2","choice":"D"}]' \
  '[{"index":0,"id":"self/R1","choice":"A","note":"x"},{"index":1,"id":"P-0a1b2c3d/R2","choice":"D"}]'; do
  assert_eq 400 "$(send D-1000 A "$bad")" "A with item_answers $bad is refused"
  assert_eq itemAnswersInvalid "$(jq -r .code "$x/post")" 'with the itemAnswersInvalid code'
done
assert_eq 400 "$(send D-1000 C "$items")" 'C takes no item_answers'
assert_ok "[ ! -e '$x/state/decisions/D-1000.json' ]" 'no refusal records an answer'
assert_eq 200 "$(send D-1000 A "$items")" 'A with one answer per item is recorded'
assert_eq "$(jq -c . <<<"$items")" "$(jq -c .item_answers "$x/state/decisions/D-1000.json")" 'the decision record stores item_answers'
assert_eq 'A|retro' "$(jq -r '.chosen+"|"+.purpose' "$x/state/decisions/D-1000.json")" 'and the card'"'"'s choice and purpose'
assert_eq 200 "$(send D-1000 A "$items")" 'the same replay is accepted'
assert_eq true "$(jq -r .already "$x/post")" 'as already recorded'
other='[{"index":0,"id":"self/R1","choice":"C"},{"index":1,"id":"P-0a1b2c3d/R2","choice":"D"}]'
assert_eq 409 "$(send D-1000 A "$other")" 'a replay with other item answers is refused'
assert_eq 409 "$(send D-1000 C)" 'a replay with another choice is refused'
card D-1001
assert_eq 200 "$(send D-1001 C)" 'C parks the whole retrospective'
assert_eq 'C,C' "$(jq -r '[.item_answers[].choice]|join(",")' "$x/state/decisions/D-1001.json")" 'every item is recorded as parked'
assert_eq 200 "$(send D-1001 C)" 'the same C replay is accepted'
assert_eq 409 "$(send D-1001 C "$items")" 'a C replay with item answers is refused'

# --- every other card is unchanged ---------------------------------------------------
jq -n '{title:"t",explanation:"e",before:"b",after:"a",outcome:"o",options:{A:{description:"a",pros:"p",cons:"c"},B:{description:"b",pros:"p",cons:"c"},C:{description:"c",pros:"p",cons:"c"}}} as $l
  | {id:"D-7",kind:"choice",task:"T-7",title:"an old card",details:{en:$l}}' > "$x/state/pending/D-7.json"
assert_eq 200 "$(send D-7 B "$items")" 'an old pending card is answered B as before'
assert_eq 'B|false' "$(jq -r '.chosen+"|"+(has("item_answers")|tostring)' "$x/state/decisions/D-7.json")" 'with no item_answers recorded'
jq -n '{id:"D-8",chosen:"A",task:"T-8",kind:"choice",merge:null}' > "$x/state/decisions/D-8.json"
assert_eq 200 "$(send D-8 A)" 'an old answered card replays as before'
assert_eq 409 "$(send D-8 B)" 'and refuses a different replay as before'

stop
if [ "$have_retro" = 1 ]; then
  start "$x" FM_EXTERNAL=1
  assert_eq 400 "$(retro '{}')" 'a board in an external project'"'"'s context refuses POST /retro'
  stop
fi
finish
