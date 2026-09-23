#!/usr/bin/env bash
# What the reviewer is shown is the whole point of this script.
set -uo pipefail
# A live managed worker exports FM_RUN_DIR / FM_ENTRY_* / FM_WORKER_TASK_LOCK_FD
# and Herdr pane ids into this shell. Suites must not inherit them or freeze,
# identity, locks and pushes bind to the outer run instead of the fixture.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
export HERDR_ENV=0 FM_TRANSPORT=direct
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

fixture() {
  local d; d="$(mktemp -d)"
  git init -q -b main "$d/repo"; cd "$d/repo" || return 1
  git config user.email a@b.c; git config user.name t
  mkdir -p bin design skills/reviewer src state
  cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-review.sh" bin/
  cp "$ROOT/bin/fm-herdr.py" bin/
  cp -r "$ROOT/bin/adapters" bin/
  cp "$ROOT/skills/reviewer/SKILL.md" skills/reviewer/
  printf 'vendor: mock\n' > config.yaml
  printf '{"tasks":[{"id":"T-Z","title":"a task","activity":{"en":"Review the authored task","zh-TW":"審查已撰寫的任務"},"scope":["src/**"],"acceptance":["it exists"]}]}\n' > design/tasks.json
  echo base > src/a; git add -A; git commit -qm base
  git checkout -q -b work
  echo "SECRET_WORKER_REASONING" > src/a
  git commit -qam work; git checkout -q main
  printf '%s' "$d"
}
ghstub() { mkdir -p "$1/stub"
  printf '#!/usr/bin/env bash\necho "gh $*" >> "%s/ghcalls"\nexit 0\n' "$1" > "$1/stub/gh"
  chmod +x "$1/stub/gh"; printf '%s' "$1/stub/gh"; }

d="$(fixture)"; r="$d/repo"; GH="$(ghstub "$d")"

# the mock adapter copies its prompt out so the test can read what was sent
cat > "$r/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "${FM_CAPTURE:-/dev/null}" 2>/dev/null
printf '%s\n' "${FM_VERDICT:-no verdict}" > "$3/verdict.txt"
exit "${FM_MOCK_EXIT:-0}"
M
chmod +x "$r/bin/adapters/mock.sh"

cap="$d/sent.md"
out="$(cd "$r" && FM_ROOT="$r" FM_GH="$GH" FM_CAPTURE="$cap" FM_VERDICT="APPROVE:T-Z" \
  bin/fm-review.sh --task T-Z --branch work --pr 9 2>&1)"
assert_eq "0" "$?" "a review round exits 0"
sent="$(cat "$cap")"

assert_contains "$sent" "T-Z" "the prompt carries the task"
assert_contains "$sent" "it exists" "the prompt carries the acceptance criteria"
assert_contains "$sent" "SECRET_WORKER_REASONING" "the prompt carries the diff"
assert_contains "$sent" "Find the reason to reject" "the prompt carries the reviewer skill"
# the skill legitimately uses the word "reasoning", so assert on concrete
# leak markers - a path, a log file, the worker script - not on vocabulary
assert_fail "grep -q 'state/worktrees' '$cap'" "the prompt names no worktree path"
assert_fail "grep -qE 'fm-worker\\.sh|\\.fm-prompt|worktrees/[A-Z]' '$cap'" \
  "the prompt carries nothing that identifies the worker's run"

assert_contains "$(cat "$d/ghcalls")" "pr comment" "the verdict is posted by the script"
assert_contains "$out" "APPROVE:T-Z" "the verdict comes back"
types="$(jq -r .type < "$r/state/events.jsonl" | tr '\n' ' ')"
assert_contains "$types" "review_opened" "it emitted review_opened"
assert_contains "$types" "approved" "an APPROVE emits approved"
assert_contains "$types" "crew_status" "the reviewer emits mid-run crew_status"
review_actor="$(jq -r 'select(.type=="review_opened")|.actor' "$r/state/events.jsonl")"
assert_eq "$review_actor" \
  "$(jq -r 'select(.type=="review_opened")|.data.crew_name' "$r/state/events.jsonl")" \
  "the reviewer publishes its exact canonical actor as crew_name"
assert_eq "reviewer" \
  "$(jq -r 'select(.type=="review_opened")|.data.role' "$r/state/events.jsonl")" \
  "the reviewer publishes its explicit role"
assert_eq "Review the authored task" \
  "$(jq -r 'select(.type=="review_opened")|.data.activity.en' "$r/state/events.jsonl")" \
  "the reviewer publishes the authored English work brief"
assert_eq "審查已撰寫的任務" \
  "$(jq -r 'select(.type=="review_opened")|.data.activity["zh-TW"]' "$r/state/events.jsonl")" \
  "the reviewer publishes the authored zh-TW work brief"

# praise is not an approval
d2="$(fixture)"; r2="$d2/repo"; GH2="$(ghstub "$d2")"
cp "$r/bin/adapters/mock.sh" "$r2/bin/adapters/mock.sh"
( cd "$r2" && FM_ROOT="$r2" FM_GH="$GH2" FM_VERDICT="this looks great, nice work" \
  bin/fm-review.sh --task T-Z --branch work --pr 9 >/dev/null 2>&1 )
assert_fail "jq -r .type < '$r2/state/events.jsonl' | grep -qx approved" "prose praise does not emit approved"

# round three tells the reviewer to close the list
cap3="$d/sent3.md"
( cd "$r" && FM_ROOT="$r" FM_GH="$GH" FM_CAPTURE="$cap3" FM_VERDICT="x" \
  bin/fm-review.sh --task T-Z --branch work --round 3 >/dev/null 2>&1 )
assert_contains "$(cat "$cap3")" "CRITERIA-COMPLETE:T-Z" "round three asks for the closed list"

# An outage is a run that produced nothing at all - a CLI that is not there.
# That is the only thing that earns exit 2, because 2 tells fm-run to try
# again next turn, and a run that DID produce something will produce the
# same something next turn, for ever.
printf 'vendor: mock\n' > "$r/config.yaml"   # one vendor, and it is not there
stub_script "$r/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
exit 2
M
rm -f "$r/state/reviews/T-Z-r7.log" "$r/state/reviews/T-Z-r7."*.log
outU="$(cd "$r" && FM_ROOT="$r" FM_GH="$GH" bin/fm-review.sh --task T-Z --branch work --round 7 2>&1)"
assert_eq "2" "$?" "a reviewer that produced nothing at all is an outage"
assert_ok "test -f '$r/state/reviews/T-Z-r7.log'" "and the round still leaves a file to read"
assert_contains "$outU" "state/reviews/T-Z-r7.log" "and says where to read it"
assert_eq "infrastructure_error" \
  "$(jq -r 'select(.type=="review_failed")|.data.review_outcome' "$r/state/events.jsonl" | tail -1)" \
  "and records an unavailable vendor as infrastructure, not rejection"

# but a run that said something, however unusable, is a failed round
stub_script "$r/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'mock: not logged in\n' >> "$4"
exit 2
M
printf 'vendor: mock\n' > "$r/config.yaml"
rm -f "$r/state/reviews/T-Z-r8.log" "$r/state/reviews/T-Z-r8."*.log
( cd "$r" && FM_ROOT="$r" FM_GH="$GH" bin/fm-review.sh --task T-Z --branch work --round 8 >/dev/null 2>&1 )
assert_eq "3" "$?" "a reviewer that said something unusable is a failed round"
assert_contains "$(cat "$r/state/reviews/T-Z-r8.log" 2>/dev/null)" "not logged in" \
  "and what it said is kept"
assert_eq "infrastructure_error" \
  "$(jq -r 'select(.type=="review_failed")|.data.review_outcome' "$r/state/events.jsonl" | tail -1)" \
  "and records a nonzero failed attempt as infrastructure"

# a failed round does not advance the counter, so the next failure at the
# same round must not overwrite the last engine's log
outW="$(cd "$r" && FM_ROOT="$r" FM_GH="$GH" bin/fm-review.sh --task T-Z --branch work --round 8 2>&1)"
assert_ok "test -f '$r/state/reviews/T-Z-r8.2.log'" "a second failure at the same round lands beside the first"
assert_contains "$outW" "T-Z-r8.2.log" "and the reviewer says the path it actually wrote"
restore_scripts
rm -rf "$d" "$d2"
# a review that did not happen must not look like one that did
d="$(fixture)"; r="$d/repo"; GH="$(ghstub "$d")"
: > "$d/ghcalls"
cat > "$r/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'TypeError: cannot read properties of undefined\n  at review.js:12\n' >> "$4"
exit 0
M
chmod +x "$r/bin/adapters/mock.sh"
out="$(cd "$r" && FM_ROOT="$r" FM_GH="$GH" bin/fm-review.sh --task T-Z --branch work --pr 9 2>&1)"
rc=$?
assert_eq "3" "$rc" "a silent reviewer is a failed round, not a passed one"
assert_contains "$out" "produced no review" "it says what went wrong"
assert_contains "$(cat "$r/state/reviews/T-Z-r1.log" 2>/dev/null)" "TypeError" \
  "and keeps what the engine actually said instead of deleting it"
assert_contains "$out" "state/reviews/T-Z-r1.log" "and says where to read it"
assert_fail "grep -q 'pr comment' '$d/ghcalls'" "nothing was posted to the pull request"
types="$(jq -r .type "$r/state/events.jsonl")"
assert_contains "$types" "review_failed" "it emitted review_failed"
assert_lacks "$(printf '%s\n' "$types" | tail -1)" "approved" "and signed nothing"
assert_eq "missing_review" \
  "$(jq -r 'select(.type=="review_failed")|.data.review_outcome' "$r/state/events.jsonl" | tail -1)" \
  "and does not turn an unsigned zero-exit result into rejection"

# Durable handoff: chain returns unsigned, but pane-child already published a
# signed final under last-result with a non-matching chain token. Recovery
# must still post that verdict (transport interrupted mid-chain).
recover="$(mktemp -d)"
mkdir -p "$recover/bin" "$recover/design" "$recover/skills/reviewer" "$recover/src" "$recover/state"
cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-review.sh" "$ROOT/bin/fm-herdr.py" "$recover/bin/"
cp -r "$ROOT/bin/adapters" "$recover/bin/"
cp "$ROOT/skills/reviewer/SKILL.md" "$recover/skills/reviewer/"
printf '{"tasks":[{"id":"T-Z","title":"z","scope":["src/**"],"depends_on":[],"acceptance":["a"]}]}\n' > "$recover/design/tasks.json"
printf '## 6. Gates\n\n## 8. Board\n' > "$recover/design/design.md"
printf 'vendor: mock\n' > "$recover/config.yaml"
mkdir -p "$recover/src"; printf 'x\n' > "$recover/src/a"
cat > "$recover/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
# Pane-child durable publish: last-result exists, but chain_attempt does not
# match the current token so attempt_output skips it — recovery must not.
attempt="$FM_RUN_DIR/handoff-attempt"
mkdir -p "$attempt"
printf 'Recovered from pane-child.\nREJECT:T-Z\nREVIEWER_COMPLETE:T-Z\n' > "$attempt/final.txt"
printf '{"attempt":"%s","status":"completed","exit_code":0,"chain_attempt":"stale-token"}\n' "$attempt" \
  > "$FM_RUN_DIR/last-result.json"
printf 'interrupted chain noise\n' >> "$4"
exit 0
M
chmod +x "$recover/bin/adapters/mock.sh"
: > "$d/ghcalls"
out="$(cd "$recover" && FM_ROOT="$recover" FM_GH="$GH" bin/fm-review.sh --task T-Z --branch work --pr 9 2>&1)"
assert_eq "0" "$?" "recovery from durable last-result exits success"
assert_contains "$out" "REJECT:T-Z" "recovered last-result posts the durable rejection"
assert_contains "$out" "recovered signed verdict" "and names the recovery path"
assert_ok "grep -q 'pr comment' '$d/ghcalls'" "recovery posts the PR comment"
assert_eq "rejected" \
  "$(jq -r 'select(.type=="review_failed")|.data.review_outcome' "$recover/state/events.jsonl" | tail -1)" \
  "and records authoritative rejection from recovered evidence"

# a vendor named in config.yaml with no adapter behind it is a typo, not an
# outage: reporting it as transient would have fm-run say "leaving it for
# the next turn" on every turn, forever
printf 'vendor: mock\nreviewer:\n  vendor: nosuchvendor\nfallback:\n  - mock\n' > "$r/config.yaml"
out="$(cd "$r" && FM_ROOT="$r" FM_GH="$GH" bin/fm-review.sh --task T-Z --branch work --pr 9 2>&1)"
assert_eq "65" "$?" "a vendor with no adapter is a configuration error"
assert_contains "$out" "no adapter" "and says which one"
assert_eq "infrastructure_error" \
  "$(jq -r 'select(.type=="review_failed")|.data.review_outcome' "$r/state/events.jsonl" | tail -1)" \
  "and records the configuration error as infrastructure, not rejection"

# the reviewer falls back the same way the worker does
cat > "$r/bin/adapters/down.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'down: not logged in\n' >> "$4"
exit 2
M
chmod +x "$r/bin/adapters/down.sh"
printf 'vendor: mock\nreviewer:\n  vendor: down\nfallback:\n  - mock\n' > "$r/config.yaml"
cat > "$r/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'the fallback reviewed it\nREJECT:T-Z\n' > "$3/verdict.txt"
exit 0
M
chmod +x "$r/bin/adapters/mock.sh"
out="$(cd "$r" && FM_ROOT="$r" FM_GH="$GH" bin/fm-review.sh --task T-Z --branch work --pr 9 2>&1)"
assert_eq "0" "$?" "an unavailable reviewer vendor falls through to the next"
assert_contains "$out" "the fallback reviewed it" "and the fallback's verdict is the verdict"

# and when the reviewer's own vendor is there, it is the one that reviews -
# a different engine from the worker's is the whole point of the block
cat > "$r/bin/adapters/other.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'reviewed by the other engine\nREJECT:T-Z\n' > "$3/verdict.txt"
exit 0
M
chmod +x "$r/bin/adapters/other.sh"
printf 'vendor: mock\nreviewer:\n  vendor: other\nfallback:\n  - mock\n' > "$r/config.yaml"
out="$(cd "$r" && FM_ROOT="$r" FM_GH="$GH" bin/fm-review.sh --task T-Z --branch work --pr 9 2>&1)"
assert_contains "$out" "reviewed by the other engine" "the reviewer block picks the engine"

# the review is on stdout and the agent left a scratch file in its working
# directory. Reading the working directory alone would discard the review
# and repeat the round for ever.
stub_script "$r/bin/adapters/down.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'a note the agent left behind\n' > "$3/notes.md"
printf 'Two findings, both the same class.\nREJECT:T-Z\n' >> "$4"
exit 2
M
printf 'vendor: mock\nreviewer:\n  vendor: down\nfallback:\n  - mock\n' > "$r/config.yaml"
out="$(cd "$r" && FM_ROOT="$r" FM_GH="$GH" bin/fm-review.sh --task T-Z --branch work --round 9 --pr 9 2>&1)"
assert_eq "0" "$?" "a review on stdout is not lost to a scratch file beside it"
assert_contains "$out" "REJECT:T-Z" "and it is the verdict"
assert_contains "$out" "a note the agent left behind" "with everything the attempt produced"
restore_scripts

# an engine misread as unavailable that signed a verdict anyway keeps it:
# the reviewer's output IS the review, so throwing it away would repeat the
# same round forever
cat > "$r/bin/adapters/down.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'The credentials check is never exercised.\nREJECT:T-Z\n' > "$3/verdict.txt"
exit 2
M
chmod +x "$r/bin/adapters/down.sh"
printf 'vendor: mock\nreviewer:\n  vendor: down\nfallback:\n  - mock\n' > "$r/config.yaml"
out="$(cd "$r" && FM_ROOT="$r" FM_GH="$GH" bin/fm-review.sh --task T-Z --branch work --round 5 --pr 9 2>&1)"
assert_eq "0" "$?" "a signed verdict survives being read as an outage"
assert_contains "$out" "REJECT:T-Z" "and it is the verdict"
assert_contains "$out" "was read as unavailable" "and the reviewer says it was misread"
printf 'vendor: mock\nreviewer:\n  vendor: other\nfallback:\n  - mock\n' > "$r/config.yaml"

# an engine that ran and said something unsigned is a failed round, even
# when what it said trips the signature list. Reporting that as an outage
# would have fm-run retry it every turn on the same input, for ever.
stub_script "$r/bin/adapters/down.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'I could not reach a view on the rate limit changes.\n' > "$3/verdict.txt"
exit 0
M
printf 'vendor: mock\nreviewer:\n  vendor: down\nfallback:\n  - mock\n' > "$r/config.yaml"
out="$(cd "$r" && FM_ROOT="$r" FM_GH="$GH" bin/fm-review.sh --task T-Z --branch work --round 6 --pr 9 2>&1)"
assert_eq "3" "$?" "unsigned output that trips the signature list is a failed round, not an outage"
assert_contains "$(cat "$r/state/reviews/T-Z-r6.log" 2>/dev/null)" "rate limit" \
  "and what it said is kept, from the output directory as well as the log"
assert_contains "$(jq -r .type < "$r/state/events.jsonl" | tr '\n' ' ')" "review_failed" \
  "and it emitted review_failed"
assert_eq "missing_review" \
  "$(jq -r 'select(.type=="review_failed")|.data.review_outcome' "$r/state/events.jsonl" | tail -1)" \
  "and a zero-exit unsigned attempt is missing_review, never rejected"
restore_scripts
printf 'vendor: mock\nreviewer:\n  vendor: other\nfallback:\n  - mock\n' > "$r/config.yaml"

# a round that ends in neither marker is an engine that failed, not a verdict
cat > "$r/bin/adapters/other.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'This looks broadly fine to me, nice work.\n' > "$3/verdict.txt"
exit 0
M
chmod +x "$r/bin/adapters/other.sh"
out="$(cd "$r" && FM_ROOT="$r" FM_GH="$GH" bin/fm-review.sh --task T-Z --branch work --round 2 --pr 9 2>&1)"
assert_eq "3" "$?" "prose with neither marker is not a review"
assert_contains "$out" "state/reviews/T-Z-r2.log" "and round two says where its log is too"

cat > "$r/bin/adapters/other.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'Three findings, all one class.\nREJECT:T-Z\n' > "$3/verdict.txt"
exit 0
M
chmod +x "$r/bin/adapters/other.sh"
out="$(cd "$r" && FM_ROOT="$r" FM_GH="$GH" bin/fm-review.sh --task T-Z --branch work --round 3 --pr 9 2>&1)"
assert_eq "0" "$?" "a signed rejection is a completed round"
assert_contains "$out" "REJECT:T-Z" "and the rejection is the verdict"
assert_lacks "$out" "the fallback reviewed it" "and the worker's engine is not used"
assert_eq "rejected" \
  "$(jq -r 'select(.type=="review_failed")|.data.review_outcome' "$r/state/events.jsonl" | tail -1)" \
  "and only the signed rejection records an authoritative reject outcome"
assert_eq "reviewer" \
  "$(jq -r 'select(.type=="review_failed")|.data.role' "$r/state/events.jsonl" | tail -1)" \
  "the rejection remains explicitly authored by a reviewer"
reject_actor="$(jq -r 'select(.type=="review_failed")|.actor' "$r/state/events.jsonl" | tail -1)"
assert_eq "$reject_actor" \
  "$(jq -r 'select(.type=="review_failed")|.data.crew_name' "$r/state/events.jsonl" | tail -1)" \
  "the rejection publishes its exact canonical actor as crew_name"
assert_eq "Review the authored task|審查已撰寫的任務" \
  "$(jq -r 'select(.type=="review_failed")|[.data.activity.en,.data.activity["zh-TW"]]|join("|")' "$r/state/events.jsonl" | tail -1)" \
  "the rejection preserves the authored bilingual activity"

rm -rf "$d"



# A task that defines itself on its own branch - which is how every new
# task arrives - was invisible: fm-review read design/tasks.json from
# whatever was checked out and said "no task T-027" for a task sitting in
# the diff it was handed.
d9="$(fixture)"; r9="$d9/repo"; GH9="$(ghstub "$d9")"
( cd "$r9" && git checkout -q -b newtask main \
  && python3 - <<'P'
import json
d=json.load(open("design/tasks.json"))
d["tasks"].append({"id":"T-NEW","title":"defined on its own branch",
                   "scope":["src/**"],"acceptance":["it exists"]})
json.dump(d, open("design/tasks.json","w"))
P
  git add -A && git -c user.email=a@b.c -c user.name=t commit -qm "add T-NEW"
  git checkout -q main )
out9="$(cd "$r9" && FM_ROOT="$r9" FM_GH="$GH9" bin/fm-review.sh --task T-NEW --branch newtask 2>&1)"
rc9=$?
assert_ne "65" "$rc9" "a task defined on the branch under review is found"
assert_lacks "$out9" "no task T-NEW" "and not reported as missing"
assert_eq "Work description unavailable|尚無工作說明" \
  "$(jq -r 'select(.type=="review_opened" and .task=="T-NEW")|[.data.activity.en,.data.activity["zh-TW"]]|join("|")' "$r9/state/events.jsonl")" \
  "a reviewer labels missing authored activity honestly"
# and one that exists nowhere is still refused
( cd "$r9" && FM_ROOT="$r9" FM_GH="$GH9" bin/fm-review.sh --task T-NOPE --branch newtask >/dev/null 2>&1 )
assert_eq "65" "$?" "a task that exists nowhere is still refused"
rm -rf "$d9"


# Criterion 9 says every exit path, including the ones that give up -
# and the reviewer's give-up path is `rm -rf "$work"; exit 3`. The worker
# got this loop; the reviewer got nothing.
for scenario in signed unsigned outage; do
  dr="$(fixture)"; rr="$dr/repo"; GHr="$(ghstub "$dr")"
  case "$scenario" in
    signed)   body='printf "looks fine\nAPPROVE:T-Z\n" > "$3/v.txt"'; rc=0 ;;
    unsigned) body='printf "no verdict at all\n" > "$3/v.txt"';        rc=0 ;;
    outage)   body=':';                                                 rc=2 ;;
  esac
  { printf '#!/usr/bin/env bash\n[ "$1" = "run" ] || exit 64\n%s\nexit %s\n' "$body" "$rc"
  } > "$rr/bin/adapters/mock.sh"
  chmod +x "$rr/bin/adapters/mock.sh"
  ( cd "$rr" && FM_ROOT="$rr" FM_GH="$GHr" bin/fm-review.sh --task T-Z --branch work --pr 9 >/dev/null 2>&1 )
  assert_eq "agent_finished" "$(jq -r .type < "$rr/state/events.jsonl" | tail -1)" \
    "a $scenario round says when it ended, last"
  assert_eq "1" "$(jq -r 'select(.type=="agent_finished")|.type' "$rr/state/events.jsonl" | grep -c . || true)" \
    "and exactly once"
  assert_matches "$(jq -r 'select(.type=="agent_finished")|.actor' < "$rr/state/events.jsonl")" \
    '^reviewer-noah-tz-r[0-9]+$' "and under its own per-run name"
  rm -rf "$dr"
done

# the reviewer is the one that had the wrong traps, and it had no kill
# test at all - three clean exits are not "the ones that give up"
# The adapter sleeps and THEN signs, so the two runs differ. A stub that
# only sleeps signs nothing, so an untouched round takes the give-up
# path on its own and posts no comment - and every assertion below would
# have held with the kill deleted.
killable_reviewer() {   # killable_reviewer <repo>
  cat > "$1/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
# says it has STARTED, so the killer waits for the engine to be running
# rather than for the script's first event: fm-review's first event used
# to come after the whole round, so the wait outlasted the run and the
# kill landed on a process that had already exited - green on a fast
# machine, and nothing to do with traps
: > "${FM_STARTED:?}"
sleep 2
printf 'APPROVE:T-Z\n' > "$3/v.txt"
M
  chmod +x "$1/bin/adapters/mock.sh"
}

dkr="$(fixture)"; rkr="$dkr/repo"; GHkr="$(ghstub "$dkr")"
killable_reviewer "$rkr"
# `exec`, so `$!` is the script and not the subshell around it: without
# it the signal may only reach the wrapper, the review is orphaned and
# runs to its natural end, and `kill -0` is false because the wrapper
# was reaped - green on a round nothing interrupted.
started="$dkr/started"
( cd "$rkr" && FM_ROOT="$rkr" FM_GH="$GHkr" FM_STARTED="$started" \
    exec bin/fm-review.sh --task T-Z --branch work --pr 9 >/dev/null 2>&1 ) &
kp=$!
for _ in $(seq 1 60); do [ -e "$started" ] && break; sleep 0.2; done
assert_ok "test -e '$started'" "the engine was running when the signal was sent"
kill -TERM "$kp" 2>/dev/null
wait "$kp" 2>/dev/null; krc=$?
for _ in $(seq 1 40); do
  [ "$(jq -r .type < "$rkr/state/events.jsonl" 2>/dev/null | tail -1)" = "agent_finished" ] && break
  sleep 0.2
done
assert_eq "1" "$(jq -r 'select(.type=="agent_finished")|.type' "$rkr/state/events.jsonl" | grep -c . || true)" \
  "a review killed mid-round ends exactly once"
assert_eq "" "$(jq -r .type "$rkr/state/events.jsonl" | sed -n '/agent_finished/,$p' | tail -n +2)" \
  "and says nothing after it"
# What tells the two rounds apart. Not the log: bash defers a TERM that
# arrives while it is waiting for a child, and the round is waiting on
# its engine almost the whole time, so the engine finishes, the verdict
# is posted and the ending is emitted - the same events an untouched
# round writes. The signal shows in the status, which is the trap doing
# its job: `trap 'exit 143' TERM`, and 143 is 128+TERM. Without that
# trap the EXIT handler would run and the script would CARRY ON, and
# this is 0.
assert_eq "143" "$krc" "a killed round exits on the signal"
assert_fail "kill -0 '$kp' 2>/dev/null" "and the process is gone"
rm -rf "$dkr"

# the same round, left alone: the absence above means nothing without it
dlr="$(fixture)"; rlr="$dlr/repo"; GHlr="$(ghstub "$dlr")"
killable_reviewer "$rlr"
( cd "$rlr" && FM_ROOT="$rlr" FM_GH="$GHlr" FM_STARTED="$dlr/started" \
    bin/fm-review.sh --task T-Z --branch work --pr 9 >/dev/null 2>&1 )
assert_eq "0" "$?" "the same round, not killed, exits 0"
assert_contains "$(cat "$dlr/ghcalls" 2>/dev/null)" "pr comment" \
  "and posts its verdict"
rm -rf "$dlr"

# the role is stated rather than read off the name, so renaming an actor
# cannot turn every reviewer into a worker on the deck
dz="$(fixture)"; rz="$dz/repo"; GHz="$(ghstub "$dz")"
( cd "$rz" && FM_ROOT="$rz" FM_GH="$GHz" bin/fm-review.sh --name rev-7 --task T-Z --branch work >/dev/null 2>&1 )
canonical="$(jq -r 'select(.type=="review_opened")|.actor' "$rz/state/events.jsonl")"
assert_matches "$canonical" '^reviewer-rev-7-tz-r[0-9]+$' "requested alias maps to a canonical reviewer identity"
assert_eq "reviewer" "$(jq -r --arg actor "$canonical" 'select(.actor==$actor)|.data.role' "$rz/state/events.jsonl" | sort -u)" \
  "a reviewer states its role on every event under the allocated actor"
assert_eq "$canonical" "$(jq -r 'select(.type=="agent_finished")|.actor' "$rz/state/events.jsonl")" \
  "completion retires exactly that canonical reviewer"
rm -rf "$dz"

finish
