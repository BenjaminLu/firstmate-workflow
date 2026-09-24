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
# A live managed worker exports FM_RUN_DIR / FM_ENTRY_* / FM_WORKER_TASK_LOCK_FD
# and Herdr pane ids into this shell. Suites must not inherit them or freeze,
# identity, locks and pushes bind to the outer run instead of the fixture.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
# Keep fixture startup isolated even when this suite is launched by a managed worker.
unset FM_CODE_ROOT FM_ENTRY_PID FM_ENTRY_SCRIPT FM_RUN_DIR FM_CONTEXT_READY FM_ATTEMPT_DIR FM_FINAL_PATH FM_CLI_EXIT
export HERDR_ENV=0 FM_TRANSPORT=direct
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

command -v bun >/dev/null 2>&1 || { echo "    bun not installed - crew e2e skipped"; exit 0; }

d="$(mktemp -d)"; r="$d/repo"
mkdir -p "$r"
mkdir -p "$r/bin" "$r/design" "$r/state" "$r/skills/worker" "$r/skills/reviewer" "$r/board"
cp "$ROOT/bin/fm-worker.sh" "$ROOT/bin/fm-review.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$r/bin/"
cp -r "$ROOT/bin/adapters" "$r/bin/"
cp "$ROOT/board/server.ts" "$r/board/"
cp "$ROOT/skills/worker/SKILL.md" "$r/skills/worker/"
cp "$ROOT/skills/reviewer/SKILL.md" "$r/skills/reviewer/"
printf 'vendor: mock\n' > "$r/config.yaml"
printf '{"tasks":[{"id":"T-1","title":"first","activity":{"en":"Build the first fixture","zh-TW":"實作第一個測試任務"},"scope":["src/**"],"acceptance":["x"]},\n' > "$r/design/tasks.json"
printf '          {"id":"T-2","title":"second","scope":["src/**"],"acceptance":["x"]}]}\n' >> "$r/design/tasks.json"


mkdir -p "$d/stub"
# Only repository/account boundaries are mocked. Worker identity, freezing,
# adapter dispatch, events and the board are the shipped implementation.
cat > "$d/stub/git" <<'G'
#!/usr/bin/env python3
import pathlib, sys
args = sys.argv[1:]
if args[0] in ('show-ref', 'ls-remote'):
    sys.exit(1)
elif args[:2] == ['worktree', 'add']:
    pathlib.Path(args[-2]).mkdir(parents=True, exist_ok=True)
elif args[0] == '-C' and 'status' in args:
    if (pathlib.Path(args[1]) / 'src/thing').exists(): print('?? src/thing')
elif args[0] == 'show':
    print(pathlib.Path('design/tasks.json').read_text())
elif args[0] == 'diff':
    pass
elif args[0] not in ('for-each-ref', 'worktree', '-C'):
    sys.exit('unexpected mock git operation: ' + repr(args))
G
chmod +x "$d/stub/git"
export PATH="$d/stub:$PATH"
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
if [ "${FM_ROLE:-}" = reviewer ]; then
  case "${FM_REVIEW_MODE:-reject}" in
    reject)  printf 'Changes required.\nREJECT:T-1\nREVIEWER_COMPLETE:T-1\n' > "$3/verdict.txt" ;;
    missing) printf 'No signed verdict was produced.\n' > "$3/verdict.txt" ;;
    infra)   printf 'review service unavailable\n' >> "$4"; exit 1 ;;
  esac
  exit 0
fi
mkdir -p "$3/src"; printf 'work\n' > "$3/src/thing"
M
chmod +x "$r/bin/adapters/mock.sh"

# Two real worker runs, two tasks, one root; transport and repository boundaries are fake.
( cd "$r" && FM_ROOT="$r" FM_GH="$d/stub/gh" bin/fm-worker.sh --task T-1 >"$d/worker1.log" 2>&1 )
assert_eq "0" "$?" "first real worker completes fixture startup"
( cd "$r" && FM_ROOT="$r" FM_GH="$d/stub/gh" bin/fm-worker.sh --task T-2 >"$d/worker2.log" 2>&1 )
assert_eq "0" "$?" "second real worker completes fixture startup"
if [ ! -f "$r/state/events.jsonl" ]; then cat "$d/worker1.log" "$d/worker2.log"; rm -rf "$d"; exit 1; fi
actors="$(jq -r 'select(.type=="dispatched")|.actor' "$r/state/events.jsonl" | sort -u)"
assert_eq "2" "$(printf '%s\n' "$actors" | sed '/^$/d' | wc -l | tr -d ' ')" \
  "two real runs emit two distinct actor names"
assert_matches "$actors" '^worker-' "and they are workers by name"

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
FM_ROOT="$r" FM_PORT=0 bun run "$r/board/server.ts" > "$d/out" 2>&1 < /dev/null &
pid=$!
trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -rf "$d"' EXIT
PORT="$(board_port "$d/out" "$pid")"
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

# Replaying one exact completion must remove only its actor, leaving the other.
cp "$r/state/events.jsonl" "$d/finished.jsonl"
first_actor="$(jq -r 'select(.type=="dispatched" and .task=="T-1")|.actor' "$d/finished.jsonl")"
second_actor="$(jq -r 'select(.type=="dispatched" and .task=="T-2")|.actor' "$d/finished.jsonl")"
assert_eq "$actors" "$(jq -r 'select(.type=="agent_finished")|.actor' "$d/finished.jsonl" | sort)" \
  "each real completion names exactly its started actor"
jq -c --arg actor "$second_actor" 'select(.type!="agent_finished" or .actor!=$actor)' "$d/finished.jsonl" > "$r/state/events.jsonl"
remaining="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_eq "$second_actor" "$(jq -r '.crew[]|select(.role=="worker")|.id' <<<"$remaining")" \
  "one completion retires only its exact actor"
assert_lacks "$(jq -r '.crew[].id' <<<"$remaining")" "$first_actor" "finished first actor is absent"
cp "$d/finished.jsonl" "$r/state/events.jsonl"

# now as if both were still running: the same log without the endings
grep -v '"agent_finished"' "$r/state/events.jsonl" > "$r/state/e2" && mv "$r/state/e2" "$r/state/events.jsonl"
s="$(curl -sf "http://127.0.0.1:$PORT/api/state")"
assert_ne "" "$s" "the board still answers"
assert_eq "3" "$(jq -r '.crew|length' <<<"$s")" "firstmate and both real workers are aboard"
tasks="$(jq -r '.crew[]|select(.role=="worker")|.task' <<<"$s" | sort | tr '\n' ' ')"
assert_eq "T-1 T-2 " "$tasks" "each real worker carries its own task"
# "because the run said so" has to be distinguishable from "because the
# name starts with worker-", and with a name like worker-1234 it is not.
# So the claim is split: this is what the real worker WRITES, and
# board.test.sh's rev-9 case is what the server does with a name the
# fallback would read wrongly.
assert_eq "worker" "$(jq -r 'select(.type=="dispatched")|.data.role' "$r/state/events.jsonl" | head -1)" \
  "the real worker states its role in the event"
assert_eq "$first_actor" \
  "$(jq -r 'select(.type=="dispatched" and .task=="T-1")|.data.crew_name' "$r/state/events.jsonl")" \
  "the real worker's crew_name is its exact canonical actor"
assert_eq "Build the first fixture|實作第一個測試任務" \
  "$(jq -r 'select(.type=="dispatched" and .task=="T-1")|[.data.activity.en,.data.activity["zh-TW"]]|join("|")' "$r/state/events.jsonl")" \
  "the real worker preserves an authored bilingual activity"
assert_eq "Work description unavailable|尚無工作說明" \
  "$(jq -r 'select(.type=="dispatched" and .task=="T-2")|[.data.activity.en,.data.activity["zh-TW"]]|join("|")' "$r/state/events.jsonl")" \
  "the real worker labels a missing authored activity honestly"
assert_eq "worker worker " "$(jq -r '.crew[]|select(.id|startswith("worker-"))|.role' <<<"$s" | sort | tr '\n' ' ')" \
  "and both of them are workers on the board"

# Run the shipped reviewer producer through all outcome classes. The consumer
# below is the relevant T-034 replay/handoff reducer copied into this isolated
# fixture after read-only inspection; shipped tests do not reach into T-034 or
# any other checkout.
for mode in reject missing infra; do
  ( cd "$r" && FM_ROOT="$r" FM_GH="$d/stub/gh" FM_REVIEW_MODE="$mode" \
      bin/fm-review.sh --task T-1 --branch work >"$d/reviewer-$mode.log" 2>&1 )
  actual=$?
  case "$mode" in reject) expected=0 ;; missing|infra) expected=3 ;; esac
  assert_eq "$expected" "$actual" "the real reviewer records the $mode outcome"
done
assert_eq "infrastructure_error missing_review rejected " \
  "$(jq -r 'select(.type=="review_failed")|.data.review_outcome' "$r/state/events.jsonl" | sort | tr '\n' ' ')" \
  "real review failures distinguish rejection, infrastructure and missing review"
assert_eq "reviewer" \
  "$(jq -r 'select(.type=="review_failed")|.data.role' "$r/state/events.jsonl" | sort -u)" \
  "every real review failure retains its explicit reviewer role"
assert_eq "true" \
  "$(jq -s 'all(.[]|select(.type=="review_opened"); .data.crew_name == .actor)' "$r/state/events.jsonl")" \
  "every real reviewer publishes its exact canonical crew_name"
assert_eq "true" \
  "$(jq -s 'all(.[]|select(.type=="review_failed"); .data.crew_name == .actor)' "$r/state/events.jsonl")" \
  "every real review_failed publishes its exact canonical crew_name"
assert_eq "Build the first fixture|實作第一個測試任務" \
  "$(jq -r 'select(.type=="review_failed" and .data.review_outcome=="rejected")|[.data.activity.en,.data.activity["zh-TW"]]|join("|")' "$r/state/events.jsonl")" \
  "the authoritative rejection preserves the authored bilingual activity"

cat > "$d/t034-consumer.ts" <<'TS'
import { readFileSync } from "node:fs";
type Event = {actor?:string;task?:string;type?:string;data?:Record<string,unknown>};
const events: Event[] = readFileSync(process.argv[2],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
const roleOf = (actor:string,e:Event): "worker"|"reviewer" => e.data?.role === "reviewer" ? "reviewer" : e.data?.role === "worker" ? "worker" : actor.startsWith("reviewer-") ? "reviewer" : "worker";
const lastByActor = new Map<string,Event>();
const roles = new Map<string,"worker"|"reviewer">();
const finished = new Set<string>();
const handoffs: Array<Record<string,unknown>> = [];
for (const [index,e] of events.entries()) {
  const actor=String(e.actor||''); const data=(e.data||{}) as Record<string,any>;
  const previous=lastByActor.get(actor);
  if(e.type==='dispatched')finished.delete(actor);else if(finished.has(actor))continue;
  if(e.type==='agent_finished')finished.add(actor);
  if(e.type==='dispatched'||data.role)roles.set(actor,roleOf(actor,e));
  const peer=(role:string)=>{const candidates=[...lastByActor].filter(([id,event])=>id!==actor&&id!=='firstmate'&&event.task===e.task&&event.type!=='agent_finished'&&!finished.has(id)&&(roles.get(id)||roleOf(id,event))===role);return candidates.length===1?candidates[0][0]:undefined;};
  let kind='',from:string|undefined,to:string|undefined;
  if(e.type==='review_failed'&&data.review_outcome==='rejected'){kind='reject';from=actor;to=peer('worker');}
  if(kind)handoffs.push({identity:`handoff:${index}:${JSON.stringify(e)}`,kind,from:from||null,to:to||null,task:e.task||null});
  if(!e.actor||e.actor==='github'||e.actor==='captain')continue;
  lastByActor.delete(e.actor);lastByActor.set(e.actor,{...e,task:e.task||previous?.task});
}
console.log(JSON.stringify(handoffs));
TS
handoffs="$(bun run "$d/t034-consumer.ts" "$r/state/events.jsonl")"
assert_eq "1" "$(jq 'length' <<<"$handoffs")" \
  "the copied actual T-034 predicate creates one reject handoff only"
assert_eq "rejected" \
  "$(jq -r '.[0].identity|sub("^handoff:[0-9]+:";"")|fromjson|.data.review_outcome' <<<"$handoffs")" \
  "that handoff comes from the authoritative final rejection"
assert_eq "$first_actor" "$(jq -r '.[0].to' <<<"$handoffs")" \
  "the T-034 consumer directs the rejection to the real matching worker"

# A coordinator may supply the designated consumer source for an additional
# byte-for-byte integration run. It is copied read-only into this disposable
# fixture; the normal shipped test above has no dependency on another checkout.
if [ -n "${FM_BOARD_CONSUMER_SOURCE:-}" ]; then
  assert_ok "test -f '$FM_BOARD_CONSUMER_SOURCE'" "the designated board consumer source exists"
  cp "$FM_BOARD_CONSUMER_SOURCE" "$r/board/designated-server.ts"
  FM_ROOT="$r" FM_PORT=0 bun run "$r/board/designated-server.ts" > "$d/designated-board.log" 2>&1 < /dev/null &
  pid2=$!
  PORT2="$(board_port "$d/designated-board.log" "$pid2")"
  for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORT2/api/state" > "$d/designated-state.json" 2>/dev/null && break; sleep 0.25; done
  assert_ok "test -s '$d/designated-state.json'" "the designated board consumer answers from real producer events"
  assert_eq "1" "$(jq '[.handoffs[]|select(.kind=="reject")]|length' "$d/designated-state.json" 2>/dev/null)" \
    "the designated board creates one reject handoff only"
  assert_eq "$first_actor" "$(jq -r '.handoffs[]|select(.kind=="reject")|.to' "$d/designated-state.json" 2>/dev/null)" \
    "the designated board directs it to the real matching worker"
  kill "$pid2" 2>/dev/null; wait "$pid2" 2>/dev/null
fi
rm -rf "$d"
finish
