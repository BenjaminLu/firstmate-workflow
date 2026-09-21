#!/usr/bin/env bash
# The board keys the crew on actor names. Every other test in the suite
# hand-writes those names, so a test that invents its producer's output
# cannot catch a mismatch with the real producer: if fm-worker emitted a
# constant actor, "two agents on two tasks are two crewmen" would be true
# of fixtures and false of the board.
#
# So this one runs the real fm-worker twice against one root and asks the
# real server what is aboard.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

command -v bun >/dev/null 2>&1 || { echo "    bun not installed - crew e2e skipped"; exit 0; }

d="$(mktemp -d)"; r="$d/repo"
git init -q -b main "$r"
( cd "$r" && git config user.email a@b.c && git config user.name t )
mkdir -p "$r/bin" "$r/design" "$r/state" "$r/skills/worker" "$r/board"
cp "$ROOT/bin/fm-worker.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$r/bin/"
cp -r "$ROOT/bin/adapters" "$r/bin/"
cp "$ROOT/board/server.ts" "$r/board/"
cp "$ROOT/skills/worker/SKILL.md" "$r/skills/worker/"
printf 'vendor: mock\n' > "$r/config.yaml"
printf '{"tasks":[{"id":"T-1","title":"first","scope":["src/**"],"acceptance":["x"]},\n' > "$r/design/tasks.json"
printf '          {"id":"T-2","title":"second","scope":["src/**"],"acceptance":["x"]}]}\n' >> "$r/design/tasks.json"
( cd "$r" && echo base > f && git add -A && git commit -qm base )

mkdir -p "$d/stub"
cat > "$d/stub/gh" <<G
#!/usr/bin/env bash
echo "gh \$*" >> "$d/ghcalls"
case " \$* " in *" pr list "*) exit 0 ;; esac
echo "https://example.invalid/pull/1"
G
chmod +x "$d/stub/gh"
cat > "$r/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"; printf 'work\n' > "$3/src/thing"
M
chmod +x "$r/bin/adapters/mock.sh"

# two real runs, two tasks, one root - and NOT finished, so both are aboard
( cd "$r" && FM_ROOT="$r" FM_GH="$d/stub/gh" bin/fm-worker.sh --task T-1 >/dev/null 2>&1 )
( cd "$r" && FM_ROOT="$r" FM_GH="$d/stub/gh" bin/fm-worker.sh --task T-2 >/dev/null 2>&1 )
actors="$(jq -r 'select(.type=="dispatched")|.actor' "$r/state/events.jsonl" | sort -u)"
assert_eq "2" "$(printf '%s\n' "$actors" | sed '/^$/d' | wc -l | tr -d ' ')" \
  "two real runs emit two distinct actor names"
assert_matches "$actors" '^worker-' "and they are workers by name"

PORT=$(( 15000 + RANDOM % 900 ))
FM_ROOT="$r" FM_PORT="$PORT" bun run "$r/board/server.ts" > "$d/out" 2>&1 < /dev/null &
pid=$!
trap 'kill "$pid" 2>/dev/null' EXIT
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORT/api/state" >/dev/null 2>&1 && break; sleep 0.25; done
# First with the log exactly as the two real runs left it. Both said
# agent_finished, so both have gone home and only firstmate is aboard -
# which is criteria 8 and 9 joined end to end, by the producer and the
# server rather than by hand. The first version of this test deleted
# those events before asking, which removed the join it exists to make.
s0="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_ne "" "$s0" "the board answers"
assert_eq "1" "$(jq -r '.crew|length' <<<"$s0")" \
  "two runs that finished leave only firstmate aboard"
assert_eq "firstmate" "$(jq -r '.crew[0].id' <<<"$s0")" "and that one is firstmate"

# now as if both were still running: the same log without the endings
grep -v '"agent_finished"' "$r/state/events.jsonl" > "$r/state/e2" && mv "$r/state/e2" "$r/state/events.jsonl"
s="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_ne "" "$s" "the board still answers"
assert_eq "3" "$(jq -r '.crew|length' <<<"$s")" "firstmate and both real workers are aboard"
tasks="$(jq -r '.crew[]|select(.role=="worker")|.task' <<<"$s" | sort | tr '\n' ' ')"
assert_eq "T-1 T-2 " "$tasks" "each real worker carries its own task"
# and the role came off the event rather than off the name
assert_eq "worker worker " "$(jq -r '.crew[]|select(.id|startswith("worker-"))|.role' <<<"$s" | sort | tr '\n' ' ')" \
  "and says it is a worker because the run said so"
rm -rf "$d"
finish
