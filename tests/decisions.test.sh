#!/usr/bin/env bash
# The captain answers on the board and the answer reaches firstmate. For a
# merge the board does not merge: it calls the one script that may.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
command -v bun >/dev/null 2>&1 || { echo "    bun not installed - decisions suite skipped"; exit 0; }

d="$(mktemp -d)"; mkdir -p "$d/bin" "$d/state" "$d/design" "$d/board/public"
cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-decide.sh" "$d/bin/"
cp "$ROOT/bin/watch-decisions.ts" "$d/bin/" 2>/dev/null || true
cp "$ROOT/board/server.ts" "$d/board/"; cp "$ROOT/board/public/index.html" "$d/board/public/"
printf '{"tasks":[{"id":"T-A","title":"first","milestone":"M0","depends_on":[]}]}\n' > "$d/design/tasks.json"

# fm-merge is the only thing allowed to merge, so the test records that it ran
cat > "$d/bin/fm-merge.sh" <<'M'
#!/usr/bin/env bash
echo "$*" >> "${FM_ROOT}/state/merge-calls"
echo "fm-merge: merged"
M
chmod +x "$d/bin/fm-merge.sh"

# Explicit legacy fixture: the route must keep old pending records readable.
mkdir -p "$d/state/pending"
printf '%s\n' '{"id":"D-1","task":"T-A","kind":"merge","title":"merge it?","pr":16}' > "$d/state/pending/D-1.json"
# The kernel picks the port and the server says which one it got. A RANDOM
# range overlapped the other suites' ranges, and with the gate running suites
# side by side a readiness loop could be answered by somebody else's board.
board_port() {   # board_port <log> <pid>: the port the server printed; 1 if it died first
  local log="$1" pid="$2" end=$(( $(date +%s) + 60 )) port
  while [ "$(date +%s)" -le "$end" ]; do
    port="$(sed -n 's|^board on http://127\.0\.0\.1:\([0-9][0-9]*\).*|\1|p' "$log" 2>/dev/null | head -1)"
    [ -n "$port" ] && { printf '%s' "$port"; return 0; }
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}
FM_ROOT="$d" FM_PORT=0 bun run "$d/board/server.ts" >"$d/out" 2>&1 </dev/null &
pid=$!; trap 'kill "$pid" 2>/dev/null' EXIT
PORT="$(board_port "$d/out" "$pid")"
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORT/api/state" >/dev/null 2>&1 && break; sleep 0.25; done

s="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "D-1" "$(jq -r '.pending[0].id' <<<"$s")" "the pending decision reaches the board"
assert_eq "merge" "$(jq -r '.pending[0].kind' <<<"$s")" "with its kind"
# the heading is filled from the dictionary at runtime, so assert on the
# element the deck renders into rather than on a string that is no longer there
assert_contains "$(curl -sf "http://127.0.0.1:$PORT/")" 'id="deck"' "the page has a decision deck"

# no -f here: a rejection is a 400 with a body, and -f throws the body away
post() { curl -s -X POST "http://127.0.0.1:$PORT/decisions" -H 'content-type: application/json' -d "$1"; }
assert_contains "$(post '{"id":"nope","chosen":"A"}')" "bad decision id" "it rejects an id that is not a decision id"
assert_contains "$(post '{"id":"D-1","chosen":"rm -rf /"}')" "bad choice" "it rejects a choice that is not a letter"
assert_contains "$(post '{"id":"D-1","chosen":["A"]}')" "bad choice" "it never coerces an array into merge authorization"
assert_fail "test -f '$d/state/merge-calls'" "neither attempt reached the merge script"

r="$(post '{"id":"D-1","chosen":"A"}')"
assert_eq "true" "$(jq -r .ok <<<"$r")" "a valid answer is accepted"
assert_ok "test -f '$d/state/decisions/D-1.json'" "the answer lands as a file, which is what firstmate waits on"
assert_eq "A" "$(jq -r .chosen "$d/state/decisions/D-1.json")" "with the choice"
assert_eq "T-A" "$(jq -r .task "$d/state/decisions/D-1.json")" "and the task it belongs to"
assert_contains "$(cat "$d/state/merge-calls")" "--pr 16" "merge called the merge script with the pull request"
assert_contains "$(cat "$d/state/merge-calls")" "--task T-A" "and the task"
assert_fail "test -f '$d/state/pending/D-1.json'" "the pending decision is cleared"

# firstmate, blocked on that decision, is released by it
got="$(FM_ROOT="$d" "$d/bin/fm-decide.sh" --await D-1 --timeout 5)"
assert_eq "A" "$(jq -r .chosen <<<"$got")" "fm-decide returns what the board wrote"

# answering twice does not merge twice
before="$(wc -l < "$d/state/merge-calls" | tr -d ' ')"
post '{"id":"D-1","chosen":"A"}' >/dev/null
assert_eq "$before" "$(wc -l < "$d/state/merge-calls" | tr -d ' ')" "answering again is idempotent"

# a non-merge answer never touches the merge script
printf '%s\n' '{"id":"D-2","task":"T-A","kind":"merge","title":"again?","pr":17}' > "$d/state/pending/D-2.json"
post '{"id":"D-2","chosen":"B"}' >/dev/null
assert_fail "grep -q 'pr 17' '$d/state/merge-calls'" "sending it back does not merge"

printf '%s\n' '{"id":"D-3","task":"T-A","kind":"merge","pr":18}' > "$d/state/pending/D-3.json"
for value in '""' '"   "' 'null' '123'; do
  payload="$(jq -cn --argjson text "$value" '{id:"D-3",chosen:"custom",text:$text}')"
  response="$(post "$payload")"
  assert_contains "$response" 'invalid custom text' 'empty and non-string custom responses fail'
done
large="$(jq -cn '{id:"D-3",chosen:"custom",text:("🚢" * 1001)}')"
assert_contains "$(post "$large")" 'invalid custom text' 'Unicode code point limit enforced'
for pair in '127 007F' '133 0085' '159 009F'; do
  set -- $pair
  payload="$(jq -cn --argjson cp "$1" '{id:"D-3",chosen:"custom",text:("captain" + ([$cp]|implode) + "order")}')"
  assert_contains "$(post "$payload")" 'invalid custom text' "Unicode control U+$2 is rejected"
done
assert_fail "test -f '$d/state/decisions/D-3.json'" 'invalid custom responses leave no record'
literal='  船長 🚢 <script>oops()</script> $(touch forbidden)  '
r="$(post "$(jq -cn --arg text "$literal" '{id:"D-3",chosen:"custom",text:$text}')")"
assert_eq 'true' "$(jq -r .ok <<<"$r")" 'literal custom response accepted'
got="$(FM_ROOT="$d" "$d/bin/fm-decide.sh" --await D-3 --timeout 5)"
assert_eq 'custom' "$(jq -r .chosen <<<"$got")" 'watch returns distinct custom semantics'
assert_eq "$literal" "$(jq -r .text <<<"$got")" 'watch preserves literal response'
state_text="$(curl -sf "http://127.0.0.1:$PORT/api/state" | jq -r '.responses[]|select(.id=="D-3")|.text')"
assert_eq "$literal" "$state_text" 'state roundtrip preserves literal response'
assert_fail "grep -q 'pr 18' '$d/state/merge-calls'" 'custom never authorizes merge'
assert_eq '3' "$(jq -s 'map(select(.type=="decision_made"))|length' "$d/state/events.jsonl")" 'one event per decision, none from await or duplicate'
assert_contains "$(post '{"id":"D-3","chosen":"A"}')" 'already recorded differently' 'conflicting repeat is truthful'
assert_contains "$(post '{"id":"D-404","chosen":"A"}')" 'no pending decision' 'unknown decision cannot be invented'

printf '%s\n' '{"id":"D-4","task":"T-A","kind":"choice"}' > "$d/state/pending/D-4.json"
assert_eq 'true' "$(post "$(jq -cn '{id:"D-4",chosen:"custom",text:("🚢" * 1000)}')" | jq -r .ok)" '1000 Unicode code points accepted'

printf '%s\n' '{"id":"D-5","task":"T-A","kind":"choice"}' > "$d/state/pending/D-5.json"
printf '#!/usr/bin/env bash\nexit 1\n' > "$d/bin/fm-emit.sh"
r="$(post '{"id":"D-5","chosen":"C"}')"
assert_eq 'true' "$(jq -r .ok <<<"$r")" 'event failure cannot hide a recorded decision'
assert_eq 'false' "$(jq -r .eventRecorded <<<"$r")" 'event failure is disclosed'
assert_eq 'decision:D-5' "$(jq -r .decision.identity <<<"$r")" 'recording has an observable stable identity without an awaiter'

kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
rm -rf "$d"
finish
