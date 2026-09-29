#!/usr/bin/env bash
# T-137: firstmate never ends a turn blind. The watcher (bin/fm-watch.sh), the
# arm (bin/fm-watch-arm.sh), the turn-end guard and the hooks of each harness.
#
# Every fixture is a root of its own with an event log written by the real
# bin/fm-emit.sh, and its own state/watch. The harness stubs answer as each
# harness's documents say - the Stop payload a hook reads, the exit code or
# JSON it must answer with - and the live verification of each is recorded in
# docs/verification/supervision.md.
set -uo pipefail
# A live managed worker exports FM_RUN_DIR / FM_IN_ROUND / HERDR ids into this
# shell. The fixture must not inherit them: FM_IN_ROUND alone would make every
# arm below stand down, which is a green suite that tested nothing.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
ARM="$ROOT/bin/fm-watch-arm.sh"
GUARD="$ROOT/bin/fm-turnend-guard.sh"
EMITTER="$ROOT/bin/fm-emit.sh"
H="$ROOT/bin/hooks"
export FM_WATCH_POLL=0.1 FM_WATCH_ARM_POLL=0.1

roots=''
new_root() {   # a fresh root, exported as FM_ROOT, with the cursor at the start of the log
  r="$(safe_tmpdir)"; mkdir -p "$r/state/watch"; printf '0\n' > "$r/state/watch/cursor"
  export FM_ROOT="$r"; roots="$roots $r"
}
# a live watcher's process is a cycle plus the fm-watch.sh it runs; the
# watcher leaves by itself once its cycle is gone
stop_watch() {   # stop_watch <root>
  local pid=''
  [ -r "$1/state/watch/owner" ] && read -r _ pid < "$1/state/watch/owner"
  [ -z "$pid" ] || kill "$pid" 2>/dev/null
  return 0
}
cleanup() { local r; for r in $roots; do stop_watch "$r"; safe_rm_rf "$r"; done; roots=''; }
trap cleanup EXIT

emit() {   # emit <actor> <type> [task] [pr] [data]
  local a=(--actor "$1" --type "$2")
  [ -z "${3-}" ] || a+=(--task "$3")
  [ -z "${4-}" ] || a+=(--pr "$4")
  [ -z "${5-}" ] || a+=(--data "$5")
  "$EMITTER" "${a[@]}"
}
# one watcher run, given up on after <secs>: what it printed, if anything
watch_once() { perl -e 'alarm shift; exec @ARGV' "$1" "$WATCH" 2>/dev/null; }
lines_of() { wc -l < "$1" | tr -d ' '; }
# poll <secs> <command...>: until the command succeeds
poll() { local end=$(( $(date +%s) + $1 )); shift; until "$@" >/dev/null 2>&1; do [ "$(date +%s)" -le "$end" ] || return 1; sleep 0.1; done; }
nonempty() { [ -s "$1" ]; }
alive_now() { "$ARM" --status >/dev/null 2>&1; }
owner_pid() { local p; read -r _ p < "$FM_ROOT/state/watch/owner"; printf '%s' "$p"; }

# --- each event kind wakes exactly once ------------------------------------
# type | task | pr | data | the line it prints
kinds='agent_finished|T-1|||finished: T-1
agent_lost|T-1|||lost: T-1
worker_crashed|T-1|||crashed: T-1
vendor_unavailable|T-1|||vendor: T-1
approved|T-1||{"head":"4ea1ec2abc"}|review: T-1 APPROVE 4ea1ec2
review_failed|T-1|||review: T-1 REJECT
gate_passed|T-1||{"gate":5}|gate: T-1 pass 5
gate_failed|T-1||{"gate":5}|gate: T-1 fail 5
decision_made|||{"decision":"D-x-T1-1","chosen":"A"}|card: D-x-T1-1 answered A
merged|T-1|106||merged: #106
protocol_violation|T-1|||protocol: T-1'
while IFS='|' read -r ty task pr data want; do
  new_root
  emit worker-1 "$ty" "$task" "$pr" "$data"
  assert_eq "$want" "$(watch_once 5)" "$ty wakes with [$want]"
  assert_eq "" "$(watch_once 1)" "$ty does not wake a second time"
done <<< "$kinds"

# progress of a round still running is absorbed: read, judged, and silent
new_root
for ty in greenlit dispatched commit_pushed pr_opened review_opened crew_status ask_pass_criteria criteria_returned decision_requested reopened; do
  emit worker-1 "$ty" T-1
done
assert_eq "" "$(watch_once 1)" "progress events wake nobody"
assert_eq "$(lines_of "$FM_ROOT/state/events.jsonl")" "$(cat "$FM_ROOT/state/watch/cursor")" "and are absorbed: the cursor moved past all of them"

# an event that wakes is the only one taken: the ones after it wait
new_root
emit worker-1 crew_status T-1; emit worker-1 agent_finished T-1; emit reviewer-1 approved T-1
assert_eq "finished: T-1" "$(watch_once 5)" "the first event that needs firstmate wakes it, past absorbed ones"
assert_eq "2" "$(cat "$FM_ROOT/state/watch/cursor")" "the cursor stops at the event that woke, not past its successors"
assert_eq "review: T-1 APPROVE" "$(watch_once 5)" "the next watcher takes the next event"
assert_eq "" "$(watch_once 1)" "and then there is nothing"

# history is not news: the first watcher ever starts at the end of the log
r="$(safe_tmpdir)"; mkdir -p "$r/state"; export FM_ROOT="$r"; roots="$roots $r"
emit worker-1 agent_finished T-1
assert_eq "" "$(watch_once 1)" "a watcher with no cursor does not replay the log"
assert_eq "1" "$(cat "$r/state/watch/cursor")" "it starts at the end of it"

# firstmate's own events never wake firstmate
new_root
emit firstmate merged T-1 5
assert_eq "" "$(watch_once 1)" "an event firstmate wrote itself does not wake it"

# the beacon proves the watcher is alive
new_root
watch_once 1 >/dev/null
assert_ok "[ \"\$(perl -e 'print time - (stat shift)[9]' '$FM_ROOT/state/watch/beacon')\" -le 2 ]" "the watcher touches its beacon"

# --- the required check finishing -----------------------------------------
new_root
S="$FM_ROOT/stub"; mkdir -p "$S"
printf '#!/bin/sh\necho "$*" >> "%s/calls"\ncase "$1 $2" in\n  "pr list") cat "%s/prs" 2>/dev/null ;;\n  "pr checks") cat "%s/checks.$3" 2>/dev/null ;;\nesac\n' "$S" "$S" "$S" > "$S/gh"
chmod +x "$S/gh"
export GH="$S/gh" FM_WATCH_CI_MIN=0 FM_WATCH_CI_MAX=0
emit worker-1 dispatched T-1
printf '7 abc123\n' > "$S/prs"; printf 'pending\n' > "$S/checks.7"
perl -e 'alarm 12; exec @ARGV' "$WATCH" > "$S/out" 2>/dev/null &
cipid=$!
sleep 1
assert_eq "" "$(cat "$S/out")" "a check still pending wakes nobody"
printf 'pass,pass\n' > "$S/checks.7"
poll 8 nonempty "$S/out"
assert_eq "ci: #7 success" "$(cat "$S/out")" "a check that finished green wakes with its result"
wait "$cipid" 2>/dev/null
assert_eq "" "$(watch_once 1)" "and only once: the finish is not reported again"

new_root
S="$FM_ROOT/stub"; mkdir -p "$S"
printf '#!/bin/sh\ncase "$1 $2" in\n  "pr list") cat "%s/prs" ;;\n  "pr checks") cat "%s/checks.$3" ;;\nesac\n' "$S" "$S" > "$S/gh"
chmod +x "$S/gh"
export GH="$S/gh"
emit worker-1 dispatched T-1
printf '8 def456\n9 999999\n' > "$S/prs"; printf 'pending,pass\n' > "$S/checks.8"; printf 'pass\n' > "$S/checks.9"
perl -e 'alarm 12; exec @ARGV' "$WATCH" > "$S/out" 2>/dev/null &
cipid=$!
sleep 1
assert_eq "" "$(cat "$S/out")" "a check that was already done when watching began is not a finish"
printf 'fail,pass\n' > "$S/checks.8"
poll 8 nonempty "$S/out"
assert_eq "ci: #8 failure" "$(cat "$S/out")" "a check that finished red wakes as a failure"
wait "$cipid" 2>/dev/null

# the pull requests are polled only while work is in flight, and with backoff
new_root
S="$FM_ROOT/stub"; mkdir -p "$S"
printf '#!/bin/sh\necho "$*" >> "%s/calls"\ncase "$1 $2" in\n  "pr list") echo "7 abc" ;;\n  "pr checks") echo pending ;;\nesac\n' "$S" > "$S/gh"
chmod +x "$S/gh"
export GH="$S/gh" FM_WATCH_CI_MIN=0 FM_WATCH_CI_MAX=0
watch_once 1 >/dev/null
assert_eq "" "$(cat "$S/calls" 2>/dev/null)" "with nothing in flight, GitHub is not asked"
emit worker-1 dispatched T-1
export FM_WATCH_CI_MIN=100 FM_WATCH_CI_MAX=300
watch_once 2 >/dev/null
assert_eq "1" "$(grep -c '^pr list' "$S/calls")" "with work in flight the poll backs off: one ask in two seconds, not one a pass"
unset GH FM_WATCH_CI_MIN FM_WATCH_CI_MAX

# --- arming: one watcher per repository ------------------------------------
new_root
emit worker-1 dispatched T-1
"$ARM" --max-wait 20 > "$FM_ROOT/a.out" 2>/dev/null & pa=$!
"$ARM" --max-wait 20 > "$FM_ROOT/b.out" 2>/dev/null & pb=$!
poll 8 alive_now
assert_contains "$("$ARM" --status)" 'gen=1' "arming starts a watcher, generation 1"
sleep 1
assert_eq "1" "$(grep -c '^successor 1$' "$FM_ROOT/state/watch/journal")" "two arms attach to one watcher: only one cycle was started"
emit worker-1 agent_finished T-1
wait "$pa" "$pb"
assert_eq "finished: T-1" "$(cat "$FM_ROOT/a.out" "$FM_ROOT/b.out")" "the wake is delivered once, by whichever arm claimed it"
assert_eq "1" "$(grep -c '^delivered 1$' "$FM_ROOT/state/watch/journal")" "and recorded as delivered once"
sn="$(grep -n '^successor 2$' "$FM_ROOT/state/watch/journal" | cut -d: -f1)"
dn="$(grep -n '^delivered 1$' "$FM_ROOT/state/watch/journal" | cut -d: -f1)"
assert_ok "[ -n '$sn' ] && [ '$sn' -lt '$dn' ]" "the successor was started before the wake was delivered"
assert_contains "$("$ARM" --status)" 'alive gen=2' "so a watcher is alive, the next generation, once the wake is in hand"
assert_eq "finished: T-1" "$(jq -r .reason "$FM_ROOT/state/watch/last-wake.json")" "the last wake and its reason are recorded for the board"
# a later arm parks again: the old wake is not delivered twice
assert_eq "" "$("$ARM" --max-wait 1 2>/dev/null)" "an arm after the delivery finds nothing to deliver"
stop_watch "$FM_ROOT"

# a dead owner is superseded
new_root
"$ARM" --ensure
first="$(owner_pid)"
kill -9 "$first" 2>/dev/null
poll 3 bash -c "! kill -0 $first"
"$ARM" --ensure
assert_contains "$("$ARM" --status)" 'alive gen=2' "a dead owner is superseded by the next generation"
assert_ne "$first" "$(owner_pid)" "by a new process"
stop_watch "$FM_ROOT"

# an owner that is alive but whose beacon has gone stale is superseded too
new_root
sleep 300 & hung=$!
printf '4 %s\n' "$hung" > "$FM_ROOT/state/watch/owner"; : > "$FM_ROOT/state/watch/beacon"
touch -t 200001010000 "$FM_ROOT/state/watch/beacon"
"$ARM" --ensure
assert_contains "$("$ARM" --status)" 'alive gen=5' "a hung owner is superseded: the generation moves on"
poll 3 bash -c "! kill -0 $hung"
assert_fail "kill -0 $hung" "and the stale process is stopped"
stop_watch "$FM_ROOT"

# the gap - work in flight and no live watcher - is recorded for the board
new_root
emit worker-1 dispatched T-1
sleep 0.1 & gone=$!; wait "$gone"
printf '1 %s\n' "$gone" > "$FM_ROOT/state/watch/owner"; : > "$FM_ROOT/state/watch/beacon"
touch -t "$(perl -e 'use POSIX; print strftime("%Y%m%d%H%M.%S", localtime(time - 30))')" "$FM_ROOT/state/watch/beacon"
"$ARM" --ensure
assert_eq "1" "$(lines_of "$FM_ROOT/state/watch/gaps.jsonl")" "arming after a lapse records the gap"
assert_ok "[ \"\$(jq -r .secs '$FM_ROOT/state/watch/gaps.jsonl')\" -ge 29 ]" "with how long it lasted"
assert_eq "1" "$(jq -r .inflight "$FM_ROOT/state/watch/gaps.jsonl")" "and how much work was in flight"
stop_watch "$FM_ROOT"

# --- only the primary arms --------------------------------------------------
new_root
emit worker-1 dispatched T-1
FM_IN_ROUND=1 "$ARM" --ensure
assert_fail "test -e '$FM_ROOT/state/watch/owner'" "a crew round (FM_IN_ROUND) never arms"
assert_eq "" "$(FM_IN_ROUND=1 "$ARM" --max-wait 1)" "and is never woken"
w="$(safe_tmpdir)"; mkdir -p "$w/state/worktrees/T-9/state"
FM_ROOT="$w/state/worktrees/T-9" "$ARM" --ensure
assert_fail "test -e '$w/state/worktrees/T-9/state/watch/owner'" "a worktree under state/worktrees never arms"
roots="$roots $w"
touch "$FM_ROOT/state/away"
"$ARM" --ensure
assert_fail "test -e '$FM_ROOT/state/watch/owner'" "while the captain is away, arming stands down"
rm -f "$FM_ROOT/state/away"
g="$(safe_tmpdir)"; roots="$roots $g"
git -C "$g" init -q . && git -C "$g" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m init \
  && git -C "$g" worktree add -q "$g/wt" -b wt-branch
mkdir -p "$g/state" "$g/wt/state"
FM_ROOT="$g/wt" "$ARM" --ensure
assert_fail "test -e '$g/wt/state/watch/owner'" "a git worktree of the repository never arms"
FM_ROOT="$g" "$ARM" --ensure
assert_ok "test -e '$g/state/watch/owner'" "the repository's own checkout does"
stop_watch "$g"

# --- the turn-end guard ------------------------------------------------------
new_root
assert_ok "'$GUARD' --check" "nothing in flight: the turn may end"
emit worker-1 dispatched T-1
msg="$("$GUARD" --check 2>&1 >/dev/null)"; rc=$?
assert_eq "2" "$rc" "work in flight and no watcher: the turn may not end"
assert_contains "$msg" "no watcher is alive" "and it says why"
assert_contains "$msg" "bin/fm-watch-arm.sh" "and what to run"
assert_eq "2" "$(FM_WATCH_ARM=/usr/bin/false "$GUARD" >/dev/null 2>&1; echo $?)" "a watcher that cannot be started leaves the refusal standing"
assert_eq "0" "$("$GUARD" >/dev/null 2>&1; echo $?)" "otherwise the guard starts the watcher its hook raced ahead of, and allows the stop"
assert_ok "'$ARM' --status" "and that watcher is alive"
assert_ok "'$GUARD' --check" "with a watcher alive, --check allows it too"
stop_watch "$FM_ROOT"
new_root
emit worker-1 dispatched T-1
assert_eq "0" "$(FM_IN_ROUND=1 "$GUARD" --check >/dev/null 2>&1; echo $?)" "a crew round is never held by the guard"
touch "$FM_ROOT/state/away"
assert_ok "'$GUARD' --check" "nor is a captain who is away"
rm -f "$FM_ROOT/state/away"
emit worker-1 agent_finished T-1
assert_ok "'$GUARD' --check" "a finished round is no longer work in flight"

# --- Claude Code: the Stop hooks ---------------------------------------------
new_root
emit worker-1 dispatched T-1
payload_fresh='{"hook_event_name":"Stop","stop_hook_active":false}'
payload_active='{"hook_event_name":"Stop","stop_hook_active":true}'
msg="$(FM_WATCH_ARM=/usr/bin/false "$H/claude-stop-guard.sh" <<<"$payload_fresh" 2>&1 >/dev/null)"; rc=$?
assert_eq "2" "$rc" "Claude guard: exit 2 blocks the stop while work is in flight and no watcher lives"
assert_contains "$msg" "no watcher is alive" "and stderr carries the reason back to the model"
assert_eq "0" "$(FM_WATCH_ARM=/usr/bin/false "$H/claude-stop-guard.sh" <<<"$payload_active" >/dev/null 2>&1; echo $?)" "Claude guard: a stop already forced by a hook is not refused again"
assert_eq "0" "$("$H/claude-stop-guard.sh" <<<"$payload_fresh" >/dev/null 2>&1; echo $?)" "Claude guard: with the watcher started, the stop is allowed"
stop_watch "$FM_ROOT"

new_root
emit worker-1 dispatched T-1
FM_HOOK_MAX_WAIT=1 "$H/claude-stop-arm.sh" <<<'{}' >/dev/null 2>"$FM_ROOT/e0"; rc=$?
assert_eq "0" "$rc" "Claude arm hook: nothing to say by the time its wait ends is a quiet exit 0"
assert_eq "" "$(cat "$FM_ROOT/e0")" "with nothing on stderr"
FM_HOOK_MAX_WAIT=20 "$H/claude-stop-arm.sh" <<<'{}' >/dev/null 2>"$FM_ROOT/e1" & hp=$!
poll 8 alive_now
emit worker-1 agent_finished T-1
wait "$hp"; rc=$?
assert_eq "2" "$rc" "Claude arm hook: an event wakes the idle session with exit 2"
assert_eq "finished: T-1" "$(cat "$FM_ROOT/e1")" "the reason is on stderr, alone"
stop_watch "$FM_ROOT"
new_root
emit worker-1 dispatched T-1
FM_IN_ROUND=1 FM_HOOK_MAX_WAIT=1 "$H/claude-stop-arm.sh" <<<'{}' >/dev/null 2>&1
assert_fail "test -e '$FM_ROOT/state/watch/owner'" "Claude hooks: in a crew round they stand down"

# --- Codex: the Stop hook ----------------------------------------------------
new_root
emit worker-1 dispatched T-1
FM_HOOK_PARK_SECS=20 "$H/codex-stop.sh" <<<"$payload_fresh" > "$FM_ROOT/o1" 2>/dev/null & hp=$!
poll 8 alive_now
emit worker-1 agent_finished T-1
wait "$hp"; rc=$?
assert_eq "0" "$rc" "Codex hook: answers on stdout, exit 0"
assert_eq "block" "$(jq -r .decision "$FM_ROOT/o1")" "Codex hook: a wake continues the turn with decision block"
assert_contains "$(jq -r .reason "$FM_ROOT/o1")" "finished: T-1" "carrying the reason as what the model reads next"
emit worker-1 dispatched T-1   # the round that just finished is followed by another
out="$(FM_HOOK_PARK_SECS=1 "$H/codex-stop.sh" <<<"$payload_fresh" 2>/dev/null)"
assert_eq "block" "$(jq -r .decision <<<"$out")" "Codex hook: a park that ran out with work in flight blocks the stop"
assert_contains "$(jq -r .reason <<<"$out")" "bin/fm-watch-arm.sh" "and tells the model to park on the arm itself"
assert_eq "" "$(FM_HOOK_PARK_SECS=1 "$H/codex-stop.sh" <<<"$payload_active" 2>/dev/null)" "Codex hook: a stop that is already a hook's continuation is let end"
stop_watch "$FM_ROOT"
new_root
assert_eq "" "$("$H/codex-stop.sh" <<<"$payload_fresh" 2>/dev/null)" "Codex hook: nothing in flight, the turn ends without parking"
assert_ok "'$ARM' --status" "though the watcher has been made sure of"
stop_watch "$FM_ROOT"
new_root
emit worker-1 dispatched T-1
assert_eq "" "$(FM_IN_ROUND=1 FM_HOOK_PARK_SECS=1 "$H/codex-stop.sh" <<<"$payload_fresh" 2>/dev/null)" "Codex hook: a crew round is never parked"
assert_fail "test -e '$FM_ROOT/state/watch/owner'" "and never arms"

# --- Cursor: the stop hook ---------------------------------------------------
new_root
emit worker-1 dispatched T-1
FM_HOOK_PARK_SECS=20 "$H/cursor-stop.sh" <<<'{"status":"completed","loop_count":0}' > "$FM_ROOT/o1" 2>/dev/null & hp=$!
poll 8 alive_now
emit worker-1 approved T-1
wait "$hp"
assert_contains "$(jq -r .followup_message "$FM_ROOT/o1")" "review: T-1 APPROVE" "Cursor hook: a wake is returned as the follow-up message"
out="$(FM_HOOK_PARK_SECS=1 "$H/cursor-stop.sh" <<<'{"status":"completed","loop_count":1}' 2>/dev/null)"
assert_contains "$(jq -r .followup_message <<<"$out")" "bin/fm-watch-arm.sh" "Cursor hook: a park that ran out with work in flight still returns a follow-up"
assert_eq "" "$(FM_HOOK_PARK_SECS=1 "$H/cursor-stop.sh" <<<'{"status":"aborted","loop_count":0}' 2>/dev/null)" "Cursor hook: an aborted turn is never parked on"
assert_eq "" "$(FM_IN_ROUND=1 FM_HOOK_PARK_SECS=1 "$H/cursor-stop.sh" <<<'{"status":"completed","loop_count":0}' 2>/dev/null)" "Cursor hook: a crew round is never parked"
stop_watch "$FM_ROOT"

# --- the harness configs -------------------------------------------------------
assert_ok "jq -e '.hooks.Stop[0].hooks[0] | (.command | contains(\"codex-stop.sh\")) and .timeout > 3300' '$ROOT/.codex/hooks.json'" ".codex/hooks.json runs the Codex hook with a timeout longer than its park"
assert_ok "jq -e '.hooks.Stop[0].hooks | map(select(.command | contains(\"claude-stop-arm.sh\"))) | .[0] | .asyncRewake == true and .timeout > 85000' '$H/claude-settings.json'" "the Claude arm hook is asyncRewake with a timeout longer than its wait"
assert_ok "jq -e '.hooks.Stop[0].hooks | map(select(.command | contains(\"claude-stop-guard.sh\"))) | .[0] | (.asyncRewake // false) == false and .timeout <= 60' '$H/claude-settings.json'" "the Claude guard is synchronous and short"
assert_ok "jq -e '.hooks.stop[0] | (.command | contains(\"cursor-stop.sh\")) and (.loop_limit | type == \"number\" and . >= 1) and .timeout > 3300' '$H/cursor-hooks.json'" "the Cursor stop hook is bounded by a loop_limit and outlasts its park"
for f in claude-stop-arm claude-stop-guard codex-stop cursor-stop; do
  assert_ok "test -x '$H/$f.sh'" "$f.sh is executable"
done
assert_contains "$(cat "$ROOT/skills/firstmate/SKILL.md")" "never ends blind" "the firstmate skill states the rule"
finish
