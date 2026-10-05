#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# shellcheck source=tests/lib/worker-note.sh
. "$ROOT/tests/lib/worker-note.sh"
# The worker cannot run gh, so the only way its question reaches the
# reviewer is this file. Without it the round-three protocol cannot happen:
# ASK-PASS-CRITERIA sits in a log nobody reads while fm-protocol reports a
# violation every turn, which looks exactly like a worker that stopped.
d6="$(fixture)"; r6="$d6/repo"; GH6="$(ghstub "$d6")"
cat > "$r6/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'ASK-PASS-CRITERIA:T-Z\n' > "$3/.fm-say.md"
M
chmod +x "$r6/bin/adapters/mock.sh"
out6="$(cd "$r6" && FM_ROOT="$r6" FM_GH="$GH6" bin/fm-worker.sh --task T-Z --pr 9 2>&1)"
assert_eq "0" "$?" "a round in which the worker only asks is a complete round"
assert_contains "$out6" "asked rather than changed" "and says so rather than looking idle"
assert_contains "$(cat "$d6/ghcalls")" "pr comment" "the question is posted to the pull request"
assert_contains "$(jq -r .type < "$r6/state/events.jsonl" | tr '\n' ' ')" "ask_pass_criteria" \
  "and the log records that the worker spoke"
assert_lacks "$(cat "$d6/ghcalls")" "push" "asking pushes nothing"
b6="$(cd "$r6" && git for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' | head -1)"
assert_fail "git -C '$r6' cat-file -e '$b6:.fm-say.md'" "and the file never reaches the diff"
rm -rf "$d6"

# A question that went nowhere leaves the task deadlocked: the reviewer
# waits for a question it will never see and the next round asks it
# again. That used to be a line on standard error and an exit 0 - the
# run reported a complete round and the log said nothing at all. It is
# the run's outcome now.
d7="$(fixture)"; r7="$d7/repo"; GH7="$(ghstub "$d7")"
cat > "$r7/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'ASK-PASS-CRITERIA:T-Z\n' > "$3/.fm-say.md"
M
chmod +x "$r7/bin/adapters/mock.sh"
# a gh that refuses the comment and nothing else
cat > "$d7/stub/gh" <<'G'
#!/usr/bin/env bash
echo "gh $*" >> "$(dirname "$0")/../ghcalls"
case " $* " in *" pr comment "*) echo "could not post" >&2; exit 1 ;; esac
echo "https://example.invalid/pull/42"
G
chmod +x "$d7/stub/gh"
out7="$(cd "$r7" && FM_ROOT="$r7" FM_GH="$GH7" bin/fm-worker.sh --task T-Z --pr 9 2>&1)"; rc7=$?
assert_eq "73" "$rc7" "a question that could not be posted fails the run"
assert_contains "$out7" "nowhere to put it" "and says what happened"
assert_contains "$out7" "#9" "naming the pull request that would not take it"
# and WHY, which is the only thing that tells the person picking this
# up by hand whether to retry, ask for access, or fix the number
assert_contains "$out7" "could not post" "and passing on what gh said about it"
assert_eq "9" "$(jq -r 'select(.type=="worker_crashed")|.pr' < "$r7/state/events.jsonl" | tail -1)" \
  "and the event carries it, so the board can link the failed round to the pull request"
# the FILE, not the length: with nullglob off bash leaves an unmatched
# pattern in place, so the array has one element either way
unsent7=("$r7"/state/unsent/T-Z-*.md)
assert_ok "test -s '${unsent7[0]}'" "and the question itself is kept, outside the worktree"
assert_contains "$(jq -r .type < "$r7/state/events.jsonl" | tr '\n' ' ')" "worker_crashed" \
  "and the log carries it, so the board is not showing a round that went fine"
# d9 above emits ask_pass_criteria on a round where the post succeeded,
# so this absence is about the post failing and not about a type the
# log never carries
assert_lacks "$(jq -r .type < "$r7/state/events.jsonl" | tr '\n' ' ')" "ask_pass_criteria" \
  "and does not claim the worker spoke"
rm -rf "$d7"

# and the same with no pull request at all to say it on
d8="$(fixture)"; r8="$d8/repo"; GH8="$(ghstub "$d8")"
# written out, not copied from $r7: that fixture was removed four lines
# up, so the cp failed every run and the `||` fallback was the whole
# implementation wearing a conditional
cat > "$r8/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
printf 'ASK-PASS-CRITERIA:T-Z\n' > "$3/.fm-say.md"
M
chmod +x "$r8/bin/adapters/mock.sh"
out8="$(cd "$r8" && FM_ROOT="$r8" FM_GH="$GH8" bin/fm-worker.sh --task T-Z 2>&1)"; rc8=$?
assert_eq "0" "$rc8" "a question-only first round opens its communication channel"
assert_contains "$(cat "$d8/ghcalls")" "--draft" "the question opens a draft pull request"
assert_contains "$(cat "$d8/ghcalls")" "pr comment 42" "the question is posted on the new pull request"
b8="$(printf '%s' "$out8" | tail -1)"
assert_eq 'ASK-PASS-CRITERIA:T-Z' "$(git -C "$r8" show "$b8:design/questions/T-Z.md" 2>/dev/null)" \
  "the draft has a real question diff even when the spec is already on main"
assert_fail "git -C '$r8' cat-file -e '$b8:.fm-say.md'" "the transient note is never committed"
assert_fail "ls '$r8'/state/unsent/T-Z-*.md" "the first-round question is not stranded unsent"
rm -rf "$d8"

# New tasks can use the spec alone as the draft's diff. Cover both the
# uncommitted seed and an earlier attempt that committed only that spec.
for question_seed in seeded committed; do
  dq="$(fixture)"; rq="$dq/repo"; GHq="$(ghstub "$dq")"
  jq -n '{id:"T-Q",title:"question",scope:["src/**","design/tasks/T-Q.json"],acceptance:["needs clarification"]}' \
    > "$rq/design/tasks/T-Q.json"
  seed_spec_preflight "$rq" T-Q
  if [ "$question_seed" = committed ]; then
    mkdir -p "$rq/state/worktrees"
    git -C "$rq" worktree add -q -b t-q-question "$rq/state/worktrees/T-Q" main
    cp "$rq/design/tasks/T-Q.json" "$rq/state/worktrees/T-Q/design/tasks/T-Q.json"
    git -C "$rq/state/worktrees/T-Q" add design/tasks/T-Q.json
    git -C "$rq/state/worktrees/T-Q" commit -qm spec
  fi
  cat > "$rq/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
if grep -q 'Your branch already carries your earlier work' "$2"; then
  echo 'spec-only question was told it carries earlier work' >&2
  exit 65
fi
printf 'SCOPE-BLOCKED:T-Q\nPlease widen the scope to include the required implementation.\n' > "$3/.fm-say.md"
M
  outq="$(cd "$rq" && FM_ROOT="$rq" FM_GH="$GHq" bin/fm-worker.sh --task T-Q 2>&1)"; rcq=$?
  bq="$(printf '%s' "$outq" | tail -1)"
  # The adapter refuses the earlier-work sentence, so success checks the
  # actual prompt without creating a file that would turn asking into work.
  assert_eq 0 "$rcq" "$question_seed spec-only scope question completes with a first-round prompt"
  assert_contains "$(cat "$dq/ghcalls")" --draft "$question_seed scope question opens a draft"
  assert_contains "$(cat "$dq/ghcalls")" 'pr comment 42' "$question_seed scope question is published"
  assert_eq design/tasks/T-Q.json "$(git -C "$rq" diff --name-only "main...$bq")" \
    "$question_seed question draft carries only its spec"
  safe_rm_rf "$dq"
done

# A note is not only a question. An adapter that may edit but not execute
# (claude under acceptEdits) finishes the work and says which checks it
# could not run - and on a first round the old block read that note as a
# premature question, kept it in state/unsent/, exited 73 and opened no
# pull request for work that was sitting in the worktree. Work plus a
# note is a round that pushes, opens its pull request, and then speaks.
d8w="$(fixture)"; r8w="$d8w/repo"; GH8w="$(ghstub "$d8w")"
cat > "$r8w/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"; printf 'the work\n' > "$3/src/done.txt"
printf 'COULD NOT RUN: tests/worker.test.sh\n' > "$3/.fm-say.md"
M
chmod +x "$r8w/bin/adapters/mock.sh"
# the stub records the body it was handed, so the assertion is about
# what the reviewer reads and not only that a comment was attempted
cat > "$d8w/stub/gh" <<G
#!/usr/bin/env bash
echo "gh \$*" >> "$d8w/ghcalls"
case " \$* " in
  *" pr list "*) echo null; exit 0 ;;
  *" pr comment "*)
    while [ \$# -gt 0 ]; do
      [ "\$1" = --body-file ] && cat "\$2" >> "$d8w/commented"; shift
    done
    exit 0 ;;
esac
echo "https://example.invalid/pull/42"
G
chmod +x "$d8w/stub/gh"
out8w="$(cd "$r8w" && FM_ROOT="$r8w" FM_GH="$GH8w" bin/fm-worker.sh --task T-Z 2>&1)"; rc8w=$?
assert_eq "0" "$rc8w" "a first round that changed files and left a note is a complete round"
assert_contains "$(cat "$d8w/ghcalls" 2>/dev/null)" "pr create" "it opens the pull request"
calls8w="$(cat "$d8w/ghcalls" 2>/dev/null)"
assert_contains "$calls8w" "pr comment 42" "and the note goes to the pull request it just opened"
# order, not presence: a comment attempted before the pull request exists
# has nowhere to land
assert_eq "pr create" "$(grep -o 'pr create\|pr comment' "$d8w/ghcalls" 2>/dev/null | head -1)" \
  "the pull request is opened before the note is posted"
assert_eq "COULD NOT RUN: tests/worker.test.sh" "$(sed '/^[<]!-- fm-note sha256=/d; /^$/d' "$d8w/commented" 2>/dev/null)" \
  "with the worker's own words as the comment body"
assert_contains "$(tail -1 "$d8w/commented")" '<!-- fm-note sha256=' "the posted body ends with its marker"
b8w="$(cd "$r8w" && git for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' | head -1)"
assert_ok "cd '$ROOT' && git --git-dir='$d8w/remote.git' cat-file -e '$b8w:src/done.txt'" \
  "the work was committed and pushed"
assert_fail "cd '$ROOT' && git --git-dir='$d8w/remote.git' cat-file -e '$b8w:.fm-say.md'" \
  "and the note never reaches the diff"
assert_lacks "$out8w" "asking is premature" "a note beside real work is not a premature question"
assert_fail "ls '$r8w'/state/unsent/T-Z-*.md" "nothing is left unsent"
types8w="$(jq -r .type < "$r8w/state/events.jsonl" | tr '\n' ' ')"
assert_contains "$types8w" "pr_opened" "the log records the pull request"
assert_lacks "$types8w" "worker_crashed" "and no crash"
assert_eq "42" "$(jq -r 'select(.type=="ask_pass_criteria")|.pr' < "$r8w/state/events.jsonl" | tail -1)" \
  "and that the worker spoke on it"
rm -rf "$d8w"

# The same round when the new pull request will not take the comment: the
# work is already pushed and the pull request open, so those stand - but
# the note is kept where a human can post it and the run says so, exactly
# as a refused comment on an existing pull request does.
d8x="$(fixture)"; r8x="$d8x/repo"
cat > "$r8x/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"; printf 'the work\n' > "$3/src/done.txt"
printf 'COULD NOT RUN: anything\n' > "$3/.fm-say.md"
M
chmod +x "$r8x/bin/adapters/mock.sh"
mkdir -p "$d8x/stub"
cat > "$d8x/stub/gh" <<G
#!/usr/bin/env bash
echo "gh \$*" >> "$d8x/ghcalls"
case " \$* " in
  *" pr list "*) echo null; exit 0 ;;
  *" pr comment "*) echo "refused by the stub" >&2; exit 1 ;;
esac
echo "https://example.invalid/pull/42"
G
chmod +x "$d8x/stub/gh"
out8x="$(cd "$r8x" && FM_ROOT="$r8x" FM_GH="$d8x/stub/gh" bin/fm-worker.sh --task T-Z 2>&1)"; rc8x=$?
assert_eq "0" "$rc8x" "a refused note beside published work completes the run"
assert_contains "$(cat "$d8x/ghcalls" 2>/dev/null)" "pr create" "after the pull request was opened"
assert_contains "$out8x" "#42 would not take the comment" "naming the pull request that refused it"
assert_contains "$out8x" "refused by the stub" "and passing on what gh said"
unsent8x=("$r8x"/state/unsent/T-Z-*.md)
assert_eq "COULD NOT RUN: anything" "$(cat "${unsent8x[0]}" 2>/dev/null)" \
  "and the note is kept outside the worktree"
assert_eq "42" "$(jq -r 'select(.type=="worker_note_unsent")|.pr' < "$r8x/state/events.jsonl" | tail -1)" \
  "the unsent event carries the number"
assert_eq 42 "$(jq -r .pr "${unsent8x[0]}.json")" "the held note sidecar records its new PR"
assert_lacks "$(cat "$r8x/state/events.jsonl")" worker_crashed "held refusal is not a crash"
rm -rf "$d8x"

# Every other way out between setting the note aside and posting it. The
# note left the worktree before the commit, so the scratch copy is the
# only one; a push the remote refuses (71), a url with no number in it
# (72) or a TERM while the pull request is being opened (143) used to
# remove that copy with the rest of the scratch files. Each keeps it
# under state/unsent/ and says so, and each keeps its own exit status.
held_note_case() {   # held_note_case <label> <want-rc> <gh-create-body> [pre-receive]
  local d r out rc
  d="$(fixture)"; r="$d/repo"
  cat > "$r/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"; printf 'the work\n' > "$3/src/done.txt"
printf 'COULD NOT RUN: anything\n' > "$3/.fm-say.md"
M
  chmod +x "$r/bin/adapters/mock.sh"
  mkdir -p "$d/stub"
  cat > "$d/stub/gh" <<G
#!/usr/bin/env bash
echo "gh \$*" >> "$d/ghcalls"
case " \$* " in
  *" pr list "*) echo null; exit 0 ;;
  *" pr create "*) $3 ;;
esac
exit 0
G
  chmod +x "$d/stub/gh"
  if [ -n "${4:-}" ]; then
    printf '#!/bin/sh\necho "%s" >&2\nexit 1\n' "$4" > "$d/remote.git/hooks/pre-receive"
    chmod +x "$d/remote.git/hooks/pre-receive"
  fi
  out="$(cd "$r" && FM_ROOT="$r" FM_GH="$d/stub/gh" bin/fm-worker.sh --task T-Z 2>&1)"; rc=$?
  assert_eq "$2" "$rc" "$1: the run keeps its own exit status"
  local kept=("$r"/state/unsent/T-Z-*.md)
  assert_eq "COULD NOT RUN: anything" "$(cat "${kept[0]}" 2>/dev/null)" \
    "$1: the note that never reached a pull request is kept outside the worktree"
  assert_contains "$out" "state/unsent/T-Z" "$1: and the run says where"
  assert_lacks "$(cat "$d/ghcalls" 2>/dev/null)" "pr comment" "$1: no comment was attempted"
  assert_contains "$(jq -r 'select(.type=="worker_crashed")|.summary.en // .en' \
    < "$r/state/events.jsonl" | tail -1)" "note" "$1: and the log records the note was not posted"
  rm -rf "$d"
}
held_note_case "push refused" 71 'echo https://example.invalid/pull/42' "refused by the remote"
held_note_case "no pull request number" 72 'echo "something went wrong"'
# the stub TERMs the worker while it waits on `pr create`; bash runs the
# trap when the command substitution returns. Single-quoted: the stub
# reads the pid file through the FM_ROOT the worker handed down
held_note_case "TERM while opening the pull request" 143 \
  'kill -TERM "$(cat "$FM_ROOT/state/worktrees/T-Z.pid")"; echo https://example.invalid/pull/42'

# A later round whose lookup could not answer. "No pull request" and
# "gh did not answer" used to be the same empty string, and they are
# opposite instructions: the first means open one, the second means the
# prompt would carry no review and the push would collide with a pull
# request nobody looked for. So the run stops BEFORE the engine - which
# is what this asserts, rather than that it printed a warning.
d10="$(fixture)"; r10="$d10/repo"; GH10="$(ghstub "$d10")"
# the counter is OUTSIDE the worktree, because the worktree is recreated
# from the branch each round - a file the first round committed is back
# on disk before the second one starts, so it cannot say whether the
# engine ran
runs="$d10/engine-runs"
cat > "$r10/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
echo ran >> "${FM_RUNS:?}"
mkdir -p "$3/src"
printf '%s\n' "$RANDOM$$" > "$3/src/work"
M
chmod +x "$r10/bin/adapters/mock.sh"
( cd "$r10" && FM_ROOT="$r10" FM_GH="$GH10" FM_RUNS="$runs" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
assert_eq "1" "$(grep -c . "$runs" 2>/dev/null || true)" "the first round ran the engine once"
# a gh that cannot answer, which is what a rate limit or an outage is
printf '#!/usr/bin/env bash\necho "HTTP 503" >&2\nexit 1\n' > "$d10/stub/gh"
chmod +x "$d10/stub/gh"
out10="$(cd "$r10" && FM_ROOT="$r10" FM_GH="$GH10" FM_RUNS="$runs" bin/fm-worker.sh --task T-Z 2>&1)"; rc10=$?
assert_eq "74" "$rc10" "a later round whose lookup cannot answer stops"
# what it DID, not what it said
assert_eq "1" "$(grep -c . "$runs" 2>/dev/null || true)" \
  "and stops before the engine, rather than running blind"
assert_contains "$out10" "could not ask which pull request" "it says what it could not do"
assert_contains "$out10" "HTTP 503" "and passes on what gh said, instead of swallowing it"
rm -rf "$d10"

# and the other half of the same status, which must NOT stop: a lookup
# that succeeded and said there is none. A round that pushed and then
# died before opening a pull request leaves exactly that, and the right
# thing is to carry on and open one.
d13="$(fixture)"; r13="$d13/repo"; GH13="$(ghstub "$d13")"
cat > "$r13/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
mkdir -p "$3/src"
printf '%s\n' "$RANDOM$$" > "$3/src/work"
M
chmod +x "$r13/bin/adapters/mock.sh"
( cd "$r13" && FM_ROOT="$r13" FM_GH="$GH13" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
# a gh that answers, and answers "none"
cat > "$d13/stub/gh" <<'G'
#!/usr/bin/env bash
echo "gh $*" >> "$(dirname "$0")/../ghcalls"
case " $* " in
  # what gh really prints for a branch with no open pull request,
  # through `--jq '.[0].number'`: the literal four characters, not
  # silence. A stub that answers with nothing tests the code's
  # expectation rather than the vendor.
  *" pr list "*) echo null; exit 0 ;;
  *" pr view "*|*" pr checks "*) exit 0 ;;
esac
echo "https://example.invalid/pull/61"
G
chmod +x "$d13/stub/gh"; : > "$d13/ghcalls"
out14="$(cd "$r13" && FM_ROOT="$r13" FM_GH="$GH13" bin/fm-worker.sh --task T-Z 2>&1)"; rc14=$?
assert_eq "0" "$rc14" "a lookup that answers \"none\" is not a failure"
assert_contains "$out14" "will open one" "and the run says it is opening one"
# d9 counts this on an asking round, which never reaches the post-push
# site at all. This one does - it goes all the way to `pr create` - so
# it is the fixture that can see a second lookup if one comes back
assert_eq "1" "$(grep -c 'pr list' "$d13/ghcalls" || true)" \
  "and asked which pull request exactly once, on a round that runs to the end"
assert_lacks "$out14" "#null" "and never carries gh's four characters through as a number"
assert_contains "$(cat "$d13/ghcalls")" "pr create" "and it does open one"
rm -rf "$d13"

# A failed local store is visible and recoverable, but cannot discard completed work.
dEvidence="$(fixture)"; rEvidence="$dEvidence/repo"; ghEvidence="$(ghstub "$dEvidence")"
# Seeding a receipt leaves the writer lock file; replace it with a blocker.
rm -f "$rEvidence/state/evidence/self/T-Z/.lock"
mkdir -p "$rEvidence/state/evidence/self/T-Z/.lock"
cat > "$rEvidence/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
mkdir -p "$3/src"
printf 'implemented\n' > "$3/src/feature"
printf 'recover this report\n' > "$3/.fm-say.md"
M
outEvidence="$(cd "$rEvidence" && FM_ROOT="$rEvidence" FM_GH="$ghEvidence" bin/fm-worker.sh --task T-Z 2>&1)"; rcEvidence=$?
assert_eq 0 "$rcEvidence" 'local record failure does not abort completed worker work'
assert_contains "$outEvidence" 'local report retention failed' 'record failure warns explicitly'
assert_ok "grep -l 'recover this report' '$rEvidence/state/unsent/'*.md" 'failed local report has an unsent recovery copy'
rm -rf "$dEvidence"


# T-199: refuse reports beside real work, with bounded, lookup-first retries.
for mode in once landed always lookup-fails question push-fails copy-fails; do
  dn="$(fixture)"; rn="$dn/repo"; note_gh "$dn"
  cat > "$rn/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
if [ "${NOTE_MODE:-}" != question ]; then
  mkdir -p "$3/src"; echo implemented > "$3/src/note-work"
fi
printf 'ASK-PASS-CRITERIA:T-Z\n' > "$3/.fm-say.md"
M
  if [ "$mode" = push-fails ]; then
    printf '#!/bin/sh\nexit 1\n' > "$dn/remote.git/hooks/pre-receive"
    chmod +x "$dn/remote.git/hooks/pre-receive"
  fi
  [ "$mode" != copy-fails ] || touch "$rn/state/unsent"
  outn="$(cd "$rn" && NOTE_MODE="$mode" FM_NOTE_RETRY_DELAYS='0 0' FM_ROOT="$rn" FM_GH="$dn/stub/gh" bin/fm-worker.sh --task T-Z --pr 9 2>&1)"; rcn=$?
  want=0; calls=3
  case "$mode" in once) calls=2 ;; landed|lookup-fails) calls=1 ;; question|copy-fails) want=73 ;; push-fails) want=71 ;; esac
  assert_eq "$want" "$rcn" "$mode: note outcome preserves the work outcome"
  assert_eq "$calls" "$(grep -c '^pr comment .*--body-file' "$dn/ghcalls")" "$mode: bounded comment attempts"
  lookups=2
  case "$mode" in once|landed|lookup-fails) lookups=1 ;; esac
  assert_eq "$lookups" "$(grep -c '^api ' "$dn/ghcalls")" "$mode: lookup before every retry"
  assert_eq post "$(awk '/^pr comment / {print "post"; exit} /^api / {print "lookup"; exit}' "$dn/ghcalls")" "$mode: first lookup follows the refused post"
  events="$(cat "$rn/state/events.jsonl")"
  case "$mode" in
    once|landed)
      assert_eq 1 "$(jq -s '[.[]|select(.type=="ask_pass_criteria")]|length' "$rn/state/events.jsonl")" "$mode: spoke once"
      assert_fail "ls '$rn'/state/unsent/T-Z-*.md" "$mode: nothing kept" ;;
    copy-fails)
      assert_contains "$events" worker_crashed "$mode: failed storage reported"
      assert_lacks "$outn" 'it is at' "$mode: never claims retention"
      assert_lacks "$events" worker_note_unsent "$mode: no recovery wake" ;;
    *)
      notes=("$rn"/state/unsent/T-Z-*.md)
      assert_eq 1 "${#notes[@]}" "$mode: exactly one retained note"
      assert_eq 9 "$(jq -r .pr "${notes[0]}.json")" "$mode: sidecar names PR"
      assert_eq 1 "$(jq -r .round "${notes[0]}.json")" "$mode: sidecar names round"
      assert_eq "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "${notes[0]}")" \
        "$(jq -r .marker "${notes[0]}.json")" "$mode: marker hashes original bytes"
      if [ "$mode" = question ]; then
        assert_contains "$events" worker_crashed "$mode: question still fails"
      elif [ "$mode" = push-fails ]; then
        assert_eq null "$(jq -r .head "${notes[0]}.json")" "$mode: no published head"
        assert_lacks "$events" worker_note_unsent "$mode: no wake before push"
        assert_lacks "$events" worker_crashed "$mode: note does not crash the round"
      else
        pushed="$(git --git-dir="$dn/remote.git" rev-parse refs/heads/t-z-a-mock-task)"
        assert_eq "$pushed" "$(jq -r .head "${notes[0]}.json")" "$mode: sidecar binds pushed head"
        assert_eq true "$(jq -s '([.[].type]|index("commit_pushed")) < ([.[].type]|index("worker_note_unsent"))' "$rn/state/events.jsonl")" "$mode: wake follows publication"
        assert_eq 1 "$(jq -s '[.[]|select(.type=="worker_note_unsent" and .pr==9)]|length' "$rn/state/events.jsonl")" "$mode: one recovery wake"
        assert_lacks "$events" worker_crashed "$mode: no crash"
      fi ;;
  esac
  if [ "$want" = 0 ] || [ "$mode" = copy-fails ]; then
    assert_eq 'T-Z: a mock task' "$(git --git-dir="$dn/remote.git" log -1 --format=%s refs/heads/t-z-a-mock-task)" "$mode: normal commit published"
  fi
  safe_rm_rf "$dn"
done

cd "$ROOT" || exit 1
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
