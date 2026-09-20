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

FM_ROOT="$d" "$d/bin/fm-decide.sh" --request D-1 --task T-A --kind merge --title "merge it?" --pr 16 >/dev/null
PORT=$(( 15000 + RANDOM % 900 ))
FM_ROOT="$d" FM_PORT="$PORT" bun run "$d/board/server.ts" >"$d/out" 2>&1 </dev/null &
pid=$!; trap 'kill "$pid" 2>/dev/null' EXIT
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORT/api/state" >/dev/null 2>&1 && break; sleep 0.25; done

s="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "D-1" "$(jq -r '.pending[0].id' <<<"$s")" "the pending decision reaches the board"
assert_eq "merge" "$(jq -r '.pending[0].kind' <<<"$s")" "with its kind"
assert_contains "$(curl -sf "http://127.0.0.1:$PORT/")" "Awaiting your call" "the page has a decision deck"

# no -f here: a rejection is a 400 with a body, and -f throws the body away
post() { curl -s -X POST "http://127.0.0.1:$PORT/decisions" -H 'content-type: application/json' -d "$1"; }
assert_contains "$(post '{"id":"nope","chosen":"A"}')" "bad decision id" "it rejects an id that is not a decision id"
assert_contains "$(post '{"id":"D-1","chosen":"rm -rf /"}')" "bad choice" "it rejects a choice that is not a letter"
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
FM_ROOT="$d" "$d/bin/fm-decide.sh" --request D-2 --task T-A --kind merge --title "again?" --pr 17 >/dev/null
post '{"id":"D-2","chosen":"B"}' >/dev/null
assert_fail "grep -q 'pr 17' '$d/state/merge-calls'" "sending it back does not merge"

kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
rm -rf "$d"
finish
