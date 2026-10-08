#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
# shellcheck source=tests/lib/review.sh
. "$ROOT/tests/lib/review.sh"
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
# T-153: the round's result records its own wall-clock - started before its
# review_opened, ended at the verdict, and the seconds between - on the
# verdict event /api/state's last_review reads
wall_clock_ok() {   # wall_clock_ok <verdict type> <events> -> 1 when its latest carries the round's clock
  jq -rs --arg ty "$1" '
    (map(select(.type=="review_opened"))|last|.ts|fromdateiso8601) as $o
    | (map(select(.type==$ty))|last|.data.wall_clock) as $w
    | if ($w|type)=="object" and ($w.started|type)=="number" and ($w.ended|type)=="number"
         and $w.started<=$o and $w.ended>=$o and $w.seconds==($w.ended-$w.started)
      then 1 else 0 end' "$2" 2>/dev/null
}
assert_eq "1" "$(wall_clock_ok approved "$r/state/events.jsonl")" \
  "an approving round's verdict event records its wall-clock: started, ended and seconds"
assert_eq "null" "$(jq -c 'select(.type=="review_opened")|.data.wall_clock' "$r/state/events.jsonl")" \
  "and only the verdict does: review_opened carries none"

# praise is not an approval
d2="$(fixture)"; r2="$d2/repo"; GH2="$(ghstub "$d2")"
cp "$r/bin/adapters/mock.sh" "$r2/bin/adapters/mock.sh"
( cd "$r2" && FM_ROOT="$r2" FM_GH="$GH2" FM_VERDICT="this looks great, nice work" \
  bin/fm-review.sh --task T-Z --branch work --pr 9 >/dev/null 2>&1 )
assert_fail "grep -qx approved <<<\"\$(jq -r .type < '$r2/state/events.jsonl')\"" "prose praise does not emit approved"

# round three tells the reviewer to close the list
cap3="$d/sent3.md"
( cd "$r" && FM_ROOT="$r" FM_GH="$GH" FM_CAPTURE="$cap3" FM_VERDICT="x" \
  bin/fm-review.sh --task T-Z --branch work --round 3 >/dev/null 2>&1 )
assert_contains "$(cat "$cap3")" "CRITERIA-COMPLETE:T-Z" "round three asks for the closed list"

# An outage is a run that produced nothing at all - a CLI that is not there.
# That is the only thing that earns exit 2, because 2 tells the autopilot to try
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
# signed final under last-result. Only this chain attempt may supply it.
recover="$(safe_tmpdir)"
mkdir -p "$recover/bin" "$recover/design/tasks" "$recover/skills/reviewer" "$recover/src" "$recover/state"
cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-review.sh" "$ROOT/bin/fm-herdr.py" "$recover/bin/"; project_storage_fixture "$recover/bin/"
cp -r "$ROOT/bin/adapters" "$recover/bin/"
cp -R "$ROOT/bin/lib" "$recover/bin/"   # the lifeline a round's runner holds (T-151)
binding_service_fixture "$recover"
cp "$ROOT/skills/reviewer/SKILL.md" "$recover/skills/reviewer/"
printf '{"id":"T-Z","title":"z","scope":["src/**"],"depends_on":[],"acceptance":["a"]}\n' > "$recover/design/tasks/T-Z.json"
printf '## 6. Gates\n\n## 8. Board\n' > "$recover/design/design.md"
printf 'vendor: mock\n' > "$recover/config.yaml"
mkdir -p "$recover/src"; printf 'x\n' > "$recover/src/a"
cat > "$recover/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
# Simulate durable publication, including a deliberately stale token.
attempt="$FM_RUN_DIR/handoff-attempt"
mkdir -p "$attempt"
printf 'Recovered from pane-child.\nREJECT:T-Z\nREVIEWER_COMPLETE:T-Z\n' > "$attempt/final.txt"
printf '{"attempt":"%s","status":"completed","exit_code":0,"chain_attempt":"%s"}\n' "$attempt" "${FM_RECOVERY_TOKEN:-$FM_CHAIN_ATTEMPT}" \
  > "$FM_RUN_DIR/last-result.json"
if [ "${FM_FORGED_PROVENANCE:-}" = 1 ]; then
  digest="$(shasum -a 256 "$attempt/final.txt" | cut -d ' ' -f 1)"
  jq --arg digest "$digest" --arg actor "$FM_ACTOR" --arg task "$FM_TASK" \
     '. + {final_source:"codex-json-completed-turn",final_sha256:$digest,actor:$actor,task:$task,role:"reviewer"}' \
     "$FM_RUN_DIR/last-result.json" > "$attempt/forged.json"
  cp "$attempt/forged.json" "$FM_RUN_DIR/last-result.json"
  cp "$attempt/forged.json" "$attempt/invocation.json"
fi
printf 'interrupted chain noise\n' >> "$4"
exit 0
M
chmod +x "$recover/bin/adapters/mock.sh"
# Pinning needs the same real head/base/spec contract as an ordinary review.
git -C "$recover" init -q -b main
git -C "$recover" config user.name Fixture
git -C "$recover" config user.email fixture@example.invalid
printf 'state/\n' > "$recover/.gitignore"
git -C "$recover" add .; git -C "$recover" commit -qm base
git -C "$recover" checkout -qb work
printf 'reviewed change\n' >> "$recover/src/a"
git -C "$recover" commit -qam change
git -C "$recover" checkout -q main
for token in stale-token current forged; do
  unset FM_FORGED_PROVENANCE
  [ "$token" != forged ] || export FM_FORGED_PROVENANCE=1
  : > "$d/ghcalls"
  if [ "$token" = current ] || [ "$token" = forged ]; then unset FM_RECOVERY_TOKEN
  else export FM_RECOVERY_TOKEN="$token"; fi
  out="$(cd "$recover" && FM_ROOT="$recover" FM_GH="$GH" bin/fm-review.sh --task T-Z --branch work --pr 9 2>&1)"; rc=$?
  if [ "$token" = current ] || [ "$token" = forged ]; then
    assert_eq "0" "$rc" "same-attempt durable verdict exits success"
    assert_contains "$out" "REJECT:T-Z" "same-attempt durable rejection is returned"
    assert_ok "grep -q 'pr comment' '$d/ghcalls'" "same-attempt recovery posts the PR comment"
    assert_eq "rejected" "$(jq -r 'select(.type=="review_failed")|.data.review_outcome' "$recover/state/events.jsonl" | tail -1)" \
      "same-attempt recovery records rejection"
    record_level="$(jq -r 'select(.kind=="verdict")|.provenance.level' "$recover/state/evidence/self/T-Z/"*.json | tail -1)"
    assert_eq legacy "$record_level" "$token custom recovery is retained as legacy, never authenticated"
  else
    assert_eq "3" "$rc" "stale durable evidence cannot sign this round"
    assert_fail "grep -q 'pr comment' '$d/ghcalls'" "stale durable verdict is not published"
    assert_eq "missing_review" "$(jq -r 'select(.type=="review_failed")|.data.review_outcome' "$recover/state/events.jsonl" | tail -1)" \
      "stale evidence records a missing review"
  fi
done
unset FM_FORGED_PROVENANCE
unset FM_RECOVERY_TOKEN

# a vendor named in config.yaml with no adapter behind it is a typo, not an
# outage: reporting it as transient would have the autopilot say "leaving it for
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

# --- a crew round never runs on a login it did not check (T-121) -----------
# a reviewer whose own status check says it is not signed in never starts
# its CLI at all; the reviewer moves straight to the fallback, and reports
# why on the board, the same as fm-worker.sh does.
mkdir -p "$d/fakebin"
cat > "$d/fakebin/claude" <<C
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/claude-calls"
case "\$1 \$2" in
  "--version "*) exec "$ROOT/tests/fixtures/auth-status/replay.sh" "$ROOT/tests/fixtures/auth-status/claude-signed-out.txt" --version ;;
  "auth status") exec "$ROOT/tests/fixtures/auth-status/replay.sh" "$ROOT/tests/fixtures/auth-status/claude-signed-out.txt" ;;
esac
exit 1
C
chmod +x "$d/fakebin/claude"
# the operator's home and keychain are the suite's: the probe resolves the
# round's login - here a crew token - from them, never the machine's own
auth_home="$d/auth-home"; mkdir -p "$auth_home/.config/firstmate"
printf 'crew-token\n' > "$auth_home/.config/firstmate/claude-token"; chmod 600 "$auth_home/.config/firstmate/claude-token"
auth_env=(HOME="$auth_home" FM_KEYCHAIN_TOOL="$d/no-security" FM_SECRET_TOOL="$d/no-secret-tool")
printf 'vendor: mock\nreviewer:\n  vendor: claude\nfallback:\n  - mock\n' > "$r/config.yaml"
out="$(cd "$r" && env "${auth_env[@]}" PATH="$d/fakebin:$PATH" FM_ROOT="$r" FM_GH="$GH" \
  bin/fm-review.sh --task T-Z --branch work --pr 9 2>&1)"
assert_eq "0" "$?" "a login the probe finds unauthenticated still falls through to the next vendor"
assert_contains "$(cat "$d/claude-calls" 2>/dev/null)" "auth status" "claude's status is asked about the round's crew token"
assert_eq "" "$(grep -vxF -e '--version' -e 'auth status' "$d/claude-calls" 2>/dev/null)" \
  "claude's own CLI is invoked only for its version and its status check, never started for the review itself"
assert_contains "$out" "the fallback reviewed it" "and the fallback's verdict is the verdict"
assert_contains "$(jq -r 'select(.type=="vendor_unavailable")|.summary.en' "$r/state/events.jsonl" | tr '\n' ' ')" \
  "claude" "vendor_unavailable names claude"
rm -f "$d/claude-calls"

# Only `authenticated` is usable (T-121): gemini has no status command, so
# with a round's login present its probe is indeterminate - refused, named
# on the board as vendor_unavailable with its status in both languages, and
# the fallback reviews instead. Its adapter here is a stand-in that records
# whether it ran.
cp "$r/bin/adapters/gemini.sh" "$d/gemini.sh.orig"
printf '#!/usr/bin/env bash\n[ "$1" = run ] || exit 64\ntouch %q\nprintf "reviewed by gemini\\nREJECT:T-Z\\n" > "$3/verdict.txt"\n' \
  "$d/gemini-ran" > "$r/bin/adapters/gemini.sh"
chmod +x "$r/bin/adapters/gemini.sh"
printf '#!/usr/bin/env bash\n[ "$1" = --version ] && { echo 0.60.0; exit 0; }\ntouch %q\nexit 1\n' "$d/gemini-asked" \
  > "$d/fakebin/gemini"
chmod +x "$d/fakebin/gemini"
mkdir -p "$auth_home/.gemini"
printf '{"access_token":"g","refresh_token":"r","expiry_date":%s}' "$(( ($(date +%s) + 86400) * 1000 ))" \
  > "$auth_home/.gemini/oauth_creds.json"
printf 'vendor: mock\nreviewer:\n  vendor: gemini\nfallback:\n  - mock\n' > "$r/config.yaml"
seen="$(wc -l < "$r/state/events.jsonl" | tr -d ' ')"
out="$(cd "$r" && env "${auth_env[@]}" PATH="$d/fakebin:$PATH" FM_ROOT="$r" FM_GH="$GH" \
  bin/fm-review.sh --task T-Z --branch work --pr 9 2>&1)"
assert_eq "0" "$?" "a gemini review whose login the probe cannot verify falls through to the next vendor"
assert_ok "[ ! -e '$d/gemini-ran' ]" "gemini's adapter never runs: an indeterminate login is refused"
assert_ok "[ ! -e '$d/gemini-asked' ]" "and gemini's CLI was asked nothing but its version"
assert_contains "$out" "the fallback reviewed it" "the fallback's verdict is the verdict"
new_events="$(tail -n +"$((seen + 1))" "$r/state/events.jsonl")"
refused="$(jq -r 'select(.type=="vendor_unavailable")|.summary.en, .summary["zh-TW"]' <<<"$new_events" | tr '\n' ' ')"
assert_contains "$refused" "gemini: indeterminate:" "vendor_unavailable names gemini and the status, in English"
assert_contains "$refused" "gemini：indeterminate：" "and in Traditional Chinese"
assert_lacks "$(jq -r 'select(.type=="crew_status")|.summary.en' <<<"$new_events" | tr '\n' ' ')" \
  "unverified" "and it is never admitted as unverified"
cp "$d/gemini.sh.orig" "$r/bin/adapters/gemini.sh"; rm -f "$d/fakebin/gemini" "$d/gemini-ran"

# A status check that does not answer in time is a timeout, refused the
# same way, and the fallback reviews.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\n[ "$1" = --version ] && { echo "claude 2.1.0"; exit 0; }\nexec sleep 30\n' \
  "$d/claude-calls" > "$d/fakebin/claude"
chmod +x "$d/fakebin/claude"
printf 'vendor: mock\nreviewer:\n  vendor: claude\nfallback:\n  - mock\n' > "$r/config.yaml"
seen="$(wc -l < "$r/state/events.jsonl" | tr -d ' ')"
out="$(cd "$r" && env "${auth_env[@]}" FM_AUTH_PROBE_TIMEOUT=1 PATH="$d/fakebin:$PATH" FM_ROOT="$r" FM_GH="$GH" \
  bin/fm-review.sh --task T-Z --branch work --pr 9 2>&1)"
assert_eq "0" "$?" "a claude review whose status check times out falls through to the next vendor"
assert_eq "" "$(grep -vxF -e '--version' -e 'auth status' "$d/claude-calls" 2>/dev/null)" \
  "claude's own CLI is never started for the review itself"
assert_contains "$out" "the fallback reviewed it" "and the fallback's verdict is the verdict"
assert_contains "$(jq -r 'select(.type=="vendor_unavailable")|.summary.en' <<<"$(tail -n +"$((seen + 1))" "$r/state/events.jsonl")" | tr '\n' ' ')" \
  "claude: timeout:" "vendor_unavailable names claude and the timeout"
rm -f "$d/claude-calls" "$d/fakebin/claude"

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
# would have the autopilot retry it every turn on the same input, for ever.
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
assert_eq "1" "$(wall_clock_ok review_failed "$r/state/events.jsonl")" \
  "a rejecting round records its wall-clock the same way (T-153)"

rm -rf "$d"



# A task that defines itself on its own branch - which is how every new
# task arrives - was invisible: fm-review read the task list from whatever
# was checked out and said "no task T-027" for a task sitting in the diff it
# was handed. The task's own file on the branch is what it reads (T-090).
d9="$(fixture)"; r9="$d9/repo"; GH9="$(ghstub "$d9")"
( cd "$r9" && git checkout -q -b newtask main \
  && printf '{"id":"T-NEW","title":"defined on its own branch","scope":["src/**"],"acceptance":["it exists"]}\n' \
       > design/tasks/T-NEW.json
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
  assert_eq "1" "$(grep -c . <<<"$(jq -r 'select(.type=="agent_finished")|.type' "$rr/state/events.jsonl")" || true)" \
    "and exactly once"
  assert_matches "$(jq -r 'select(.type=="agent_finished")|.actor' < "$rr/state/events.jsonl")" \
    '^reviewer-[a-z]+[0-9]*-tz-r[0-9]+[a-z]*$' "and under its own per-run name"
  # T-137: the verdict wakes firstmate - one item on the wake queue, pushed
  # by the round after its agent_finished, and nothing else (its progress
  # and its approved/review_failed push nothing of their own)
  actor_r="$(jq -r 'select(.type=="agent_finished")|.actor' < "$rr/state/events.jsonl")"
  assert_eq "1" "$(grep -c . "$rr/state/session/wake.jsonl" 2>/dev/null || echo 0)" \
    "a $scenario round's end is one wake on the queue, and nothing else is"
  assert_eq "$actor_r verdict" "$(jq -r '"\(.id) \(.reason)"' "$rr/state/session/wake.jsonl" 2>/dev/null)" \
    "under the round's own name"
  case "$scenario" in
    signed) want='^review: T-Z APPROVE( [0-9a-f]{7})? #9$' ;;
    *)      want='^review: T-Z no verdict exit [1-9][0-9]*( [0-9a-f]{7})? #9$' ;;
  esac
  assert_matches "$(jq -r .line "$rr/state/session/wake.jsonl" 2>/dev/null)" "$want" \
    "a $scenario round wakes firstmate with its verdict"
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
# Both waits are for the real condition against a deadline wide enough for a
# loaded machine; a count of sleeps ran out under the gate's parallel pool.
# They return the moment the condition holds, so the kill still lands inside
# the engine's two-second sleep.
eventually test -e "$started"
assert_ok "test -e '$started'" "the engine was running when the signal was sent"
kill -TERM "$kp" 2>/dev/null
wait "$kp" 2>/dev/null; krc=$?
ended() { [ "$(jq -r .type < "$rkr/state/events.jsonl" 2>/dev/null | tail -1)" = "agent_finished" ]; }
eventually ended
assert_eq "1" "$(grep -c . <<<"$(jq -r 'select(.type=="agent_finished")|.type' "$rkr/state/events.jsonl")" || true)" \
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
assert_matches "$canonical" '^reviewer-rev-7-tz-r[0-9]+[a-z]*$' "requested alias maps to a canonical reviewer identity"
assert_eq "reviewer" "$(jq -r --arg actor "$canonical" 'select(.actor==$actor)|.data.role' "$rz/state/events.jsonl" | sort -u)" \
  "a reviewer states its role on every event under the allocated actor"
assert_eq "$canonical" "$(jq -r 'select(.type=="agent_finished")|.actor' "$rz/state/events.jsonl")" \
  "completion retires exactly that canonical reviewer"
rm -rf "$dz"

# T-116: the reviewer's identity rides every payload as separate fields, and
# the actor's r<n> is the review round: --round when given, else one past the
# rounds the log has opened on the task - never the global run counter
dq="$(fixture)"; rq="$dq/repo"; GHq="$(ghstub "$dq")"
mkdir -p "$rq/state/runs"; printf '{"number":472}\n' > "$rq/state/runs/counter.json"
( cd "$rq" && FM_ROOT="$rq" FM_GH="$GHq" bin/fm-review.sh --task T-Z --branch work >/dev/null 2>&1 )
first="$(jq -r 'select(.type=="review_opened")|.actor' "$rq/state/events.jsonl" | head -1)"
assert_matches "$first" '^reviewer-[a-z]+-tz-r1$' "a task's first review round is r1, not the run counter"
fields="$(jq -c --arg a "$first" 'select(.actor==$a)|.data.identity|[.role,.task,.round,.attempt,(.name|type),has("project")]' \
  "$rq/state/events.jsonl" | sort -u)"
assert_eq '["reviewer","T-Z",1,1,"string",true]' "$fields" \
  "every payload of the run carries role, task, round, attempt, name and project as fields"
assert_eq "${first#reviewer-}" "$(jq -r --arg a "$first" 'select(.actor==$a and .type=="review_opened")|.data.identity.name' \
  "$rq/state/events.jsonl")-tz-r1" "and the name field is the crew member's own, not the actor"
( cd "$rq" && FM_ROOT="$rq" FM_GH="$GHq" bin/fm-review.sh --task T-Z --branch work >/dev/null 2>&1 )
assert_matches "$(jq -r 'select(.type=="review_opened")|.actor' "$rq/state/events.jsonl" | sed -n 2p)" \
  '^reviewer-[a-z]+-tz-r2$' "the next round, with one opened in the log, is r2"
( cd "$rq" && FM_ROOT="$rq" FM_GH="$GHq" bin/fm-review.sh --task T-Z --branch work --round 7 >/dev/null 2>&1 )
told="$(jq -r 'select(.type=="review_opened")|.actor' "$rq/state/events.jsonl" | sed -n 3p)"
assert_matches "$told" '^reviewer-[a-z]+-tz-r7$' "a round given with --round is the actor's round"
assert_eq "7" "$(jq -r --arg a "$told" 'select(.actor==$a and .type=="review_opened")|.data.identity.round' \
  "$rq/state/events.jsonl")" "and the payload's round field"
rm -rf "$dq"

# T-127: the reviewer runs on the model config.yaml names, and the round
# records vendor, model and cli_version as separate fields, read from the
# run itself. FM_MOCK_MODEL stands in for a real vendor's transcript
# reporting the model it actually ran on.
dm="$(fixture)"; rmv="$dm/repo"; GHm="$(ghstub "$dm")"
printf 'reviewer:\n  model: mock-model-a\n' >> "$rmv/config.yaml"
cat > "$rmv/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "${FM_CAPTURE:-/dev/null}" 2>/dev/null
[ -z "${FM_MOCK_MODEL:-}" ] || printf '{"type":"result","model":"%s"}\n' "$FM_MOCK_MODEL" >> "$4"
printf '%s\n' "${FM_VERDICT:-no verdict}" > "$3/verdict.txt"
exit "${FM_MOCK_EXIT:-0}"
M
chmod +x "$rmv/bin/adapters/mock.sh"
( cd "$rmv" && FM_ROOT="$rmv" FM_GH="$GHm" FM_MOCK_MODEL="mock-model-b" FM_VERDICT="REJECT:T-Z" \
    bin/fm-review.sh --task T-Z --branch work >/dev/null 2>&1 )
logm="$rmv/state/events.jsonl"
# the model is only known once the round's own CLI has run, so only the
# payloads from that point on - the signed verdict's own review_failed,
# never review_opened, emitted before any adapter runs - carry it
assert_eq '["mock","mock-model-a","mock-model-b","unknown"]' \
  "$(jq -c 'select(.type=="review_failed" and .data.review_outcome=="rejected")|.data.identity|[.vendor,.model_requested,.model,.cli_version]' "$logm" | sort -u)" \
  "the round's crew payloads carry vendor, model_requested, model and cli_version as separate fields"
mactor="$(jq -r 'select(.type=="review_opened")|.actor' "$logm")"
assert_eq '["mock","mock-model-a","mock-model-b","unknown"]' \
  "$(jq -c '[.vendor,.model_requested,.model,.cli_version]' "$rmv/state/runs/$mactor/identity.json")" \
  "and identity.json records the same four fields"
assert_eq "true" "$(jq -r '.model_mismatch' "$rmv/state/runs/$mactor/identity.json")" \
  "flagged as a mismatch since the run reported a different model than config.yaml asked for"
mrowv="$(jq -c 'select(.type=="model_mismatch")' "$logm")"
assert_eq "mock-model-a" "$(jq -r '.data.model_requested' <<<"$mrowv")" "naming what was requested"
assert_eq "mock-model-b" "$(jq -r '.data.model' <<<"$mrowv")" "and what it actually ran on"
assert_ne "" "$(jq -r '.summary.en' <<<"$mrowv")" "with an English summary"
assert_ne "" "$(jq -r '.summary."zh-TW"' <<<"$mrowv")" "and a zh-TW one"
rm -rf "$dm"

# T-104: a reviewer is named from the reviewer roster the installation drew,
# and a worker's name is refused even when asked for by --name
dn="$(fixture)"; rn="$dn/repo"; GHn="$(ghstub "$dn")"
# the stock mock signs nothing, and an unsigned round exits 3
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$FM_VERDICT" > "$3/verdict.txt"\n' > "$rn/bin/adapters/mock.sh"
( cd "$rn" && FM_ROOT="$rn" FM_GH="$GHn" FM_ROSTER_SEED=review FM_VERDICT="REJECT:T-Z" \
    bin/fm-review.sh --task T-Z --branch work >/dev/null 2>&1 )
assert_eq "0" "$?" "a review round with no crew yet exits 0"
named="$(jq -r 'select(.type=="review_opened")|.actor' "$rn/state/events.jsonl" | sed -E 's/^reviewer-([a-z]+)-tz-r[0-9]+[a-z]*$/\1/')"
assert_eq "true" "$(jq --arg n "$named" 'any(.reviewers[]; . == $n) and (any(.workers[]; . == $n) | not)' "$rn/state/crew/rosters.json")" \
  "the reviewer's name is on the drawn reviewer roster and not the worker roster"
worker_name="$(jq -r '.workers[0]' "$rn/state/crew/rosters.json")"
refused="$(cd "$rn" && FM_ROOT="$rn" FM_GH="$GHn" bin/fm-review.sh --name "$worker_name" --task T-Z --branch work 2>&1)"
assert_eq "70" "$?" "a worker's name is refused for a reviewer"
assert_contains "$refused" "crew name $worker_name is on the worker roster" "and the refusal says whose name it is"
rm -rf "$dn"

# T-201: the adapter changes repository state only after review preparation.
for movement in base retarget head closed; do
  df="$(fixture)"; rf="$df/repo"; GHf="$(ghstub "$df")"
  reviewed_head="$(git -C "$rf" rev-parse work)"
  reviewed_base="$(git -C "$rf" merge-base main work)"
  reviewed_patch="$(git -C "$rf" diff-tree -r -p --no-renames "$reviewed_base" "$reviewed_head" |
    git patch-id --stable | cut -d ' ' -f 1)"
  cat > "$rf/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
set -eu
[ "$1" = run ] || exit 64
case "$FM_FIXTURE_MOVEMENT" in
  base|head)
    ref=main
    [ "$FM_FIXTURE_MOVEMENT" != head ] || ref=work
    old="$(git -C "$FM_TARGET_ROOT" rev-parse "$ref")"
    # A sibling file keeps main's new commit unrelated to the reviewed src/a.
    blob="$(printf 'unrelated change\n' | git -C "$FM_TARGET_ROOT" hash-object -w --stdin)"
    tree="$( { git -C "$FM_TARGET_ROOT" ls-tree "$old"; printf '100644 blob %s\tunrelated.txt\n' "$blob"; } |
      git -C "$FM_TARGET_ROOT" mktree)"
    new="$(printf 'move during review\n' | git -C "$FM_TARGET_ROOT" commit-tree "$tree" -p "$old")"
    git -C "$FM_TARGET_ROOT" update-ref "refs/heads/$ref" "$new"
    ;;
  retarget) printf 'other-base\n' > "$FM_TARGET_ROOT/.fixture-pr-base" ;;
  closed) touch "$FM_TARGET_ROOT/.fixture-pr-closed" ;;
esac
printf 'APPROVE:T-Z\n' > "$3/verdict.txt"
M
  chmod +x "$rf/bin/adapters/mock.sh"
  out="$(cd "$rf" && FM_ROOT="$rf" FM_GH="$GHf" FM_FIXTURE_MOVEMENT="$movement" \
    bin/fm-review.sh --task T-Z --branch work --pr 9 2>"$df/stderr")"; code=$?
  actor="$(jq -r 'select(.type=="review_opened")|.actor' "$rf/state/events.jsonl")"
  verdict_heads="$(jq -r 'select(.kind=="verdict")|.head' "$rf/state/evidence/self/T-Z/"*.json)"
  if [ "$movement" = base ]; then
    assert_eq 0 "$code" 'base moving during review does not discard the verdict'
    assert_ne "$reviewed_base" "$(git -C "$rf" rev-parse main)" 'the adapter really advanced main'
    assert_eq "$reviewed_head" "$verdict_heads" 'the retained verdict names the originally reviewed head'
    assert_eq "$reviewed_base" "$(jq -r 'select(.kind=="verdict")|.base' "$rf/state/evidence/self/T-Z/"*.json)" \
      'the retained verdict keeps its original merge-base'
    assert_eq "$reviewed_patch" "$(jq -r 'select(.kind=="verdict")|.patch' "$rf/state/evidence/self/T-Z/"*.json)" \
      'the retained verdict keeps its original patch-id'
    assert_contains "$(cat "$df/ghcalls")" 'pr comment' 'the base-move verdict is projected'
    assert_contains "$(jq -r .type "$rf/state/events.jsonl")" approved 'the base-move verdict emits approved'
    assert_fail "test -e '$rf/state/runs/$actor/stale-final.txt'" 'the base-move verdict is not stale'
  else
    assert_eq 65 "$code" "$movement during review refuses the final verdict"
    assert_ok "test -f '$rf/state/runs/$actor/stale-final.txt'" "$movement retains stale final evidence"
    assert_eq infrastructure_error \
      "$(jq -r 'select(.type=="review_failed")|.data.review_outcome' "$rf/state/events.jsonl" | tail -1)" \
      "$movement emits infrastructure failure"
    assert_eq '' "$verdict_heads" "$movement records no verdict"
    assert_lacks "$(cat "$df/ghcalls")" 'pr comment' "$movement projects no verdict"
    if [ "$movement" = retarget ]; then
      assert_contains "$(cat "$df/stderr")" 'fm-binding:' 'retarget failure preserves binding stderr'
      assert_contains "$(cat "$df/stderr")" 'base' 'retarget failure names the base'
    fi
  fi
  rm -rf "$df"
done

# T-213: movement while the review waits for CI.
for movement in base head retarget closed; do
  df="$(fixture)"; rf="$df/repo"; GHf="$(ghstub "$df")"
  reviewed_head="$(git -C "$rf" rev-parse work)"
  reviewed_base="$(git -C "$rf" merge-base main work)"
  reviewed_patch="$(git -C "$rf" diff-tree -r -p --no-renames "$reviewed_base" "$reviewed_head" |
    git patch-id --stable | cut -d ' ' -f 1)"
  cat > "$GHf" <<'GH'
#!/usr/bin/env bash
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
echo "gh $*" >> "$here/ghcalls"
case "$*" in
  "api repos/"*"/branches/"*"/protection/required_status_checks")
    if [ ! -e "$here/moved" ]; then
      touch "$here/moved"
      case "$FM_FIXTURE_MOVEMENT" in
        base|head)
          ref=main
          [ "$FM_FIXTURE_MOVEMENT" != head ] || ref=work
          old="$(git -C "$FM_TARGET_ROOT" rev-parse "$ref")"
          blob="$(printf 'unrelated change\n' | git -C "$FM_TARGET_ROOT" hash-object -w --stdin)"
          tree="$( { git -C "$FM_TARGET_ROOT" ls-tree "$old"; printf '100644 blob %s\tunrelated.txt\n' "$blob"; } |
            git -C "$FM_TARGET_ROOT" mktree)"
          new="$(printf 'move during CI wait\n' | git -C "$FM_TARGET_ROOT" commit-tree "$tree" -p "$old")"
          git -C "$FM_TARGET_ROOT" update-ref "refs/heads/$ref" "$new"
          ;;
        retarget) printf 'other-base\n' > "$FM_TARGET_ROOT/.fixture-pr-base" ;;
        closed) touch "$FM_TARGET_ROOT/.fixture-pr-closed" ;;
      esac
    fi
    printf '{"contexts":[],"checks":[]}\n'
    ;;
esac
exit 0
GH
  cat > "$rf/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
set -eu
[ "$1" = run ] || exit 64
touch "$FM_TARGET_ROOT/.adapter-ran"
printf 'APPROVE:T-Z\n' > "$3/verdict.txt"
M
  chmod +x "$rf/bin/adapters/mock.sh"
  out="$(cd "$rf" && FM_ROOT="$rf" FM_GH="$GHf" FM_FIXTURE_MOVEMENT="$movement" \
    bin/fm-review.sh --task T-Z --branch work --pr 9 2>"$df/stderr")"; code=$?
  actor="$(jq -r 'select(.type=="review_opened")|.actor' "$rf/state/events.jsonl")"
  verdict_heads="$(jq -r 'select(.kind=="verdict")|.head' "$rf/state/evidence/self/T-Z/"*.json)"
  assert_ok "test -f '$df/moved'" "$movement happened on the required-checks request"
  if [ "$movement" = base ]; then
    assert_eq 0 "$code" 'base moving during the CI wait does not refuse review'
    assert_ok "test -f '$rf/.adapter-ran'" 'base movement still runs the reviewer'
    assert_ne "$reviewed_base" "$(git -C "$rf" rev-parse main)" 'the CI request really advanced main'
    assert_eq "$reviewed_head" "$verdict_heads" 'the CI-wait verdict keeps its original head'
    assert_eq "$reviewed_base" "$(jq -r 'select(.kind=="verdict")|.base' "$rf/state/evidence/self/T-Z/"*.json)" \
      'the CI-wait verdict keeps its original merge-base'
    assert_eq "$reviewed_patch" "$(jq -r 'select(.kind=="verdict")|.patch' "$rf/state/evidence/self/T-Z/"*.json)" \
      'the CI-wait verdict keeps its original patch-id'
    assert_contains "$(cat "$df/ghcalls")" 'pr comment' 'the CI-wait base-move verdict is projected'
    assert_contains "$(jq -r .type "$rf/state/events.jsonl")" approved 'the CI-wait base-move verdict emits approved'
  else
    assert_eq 65 "$code" "$movement during the CI wait refuses review"
    assert_fail "test -e '$rf/.adapter-ran'" "$movement during the CI wait never starts the adapter"
    assert_eq '' "$verdict_heads" "$movement during the CI wait records no verdict"
    assert_lacks "$(cat "$df/ghcalls")" 'pr comment' "$movement during the CI wait projects no verdict"
    failure="$(jq -c 'select(.type=="review_failed")' "$rf/state/events.jsonl" | tail -1)"
    assert_eq infrastructure_error "$(jq -r '.data.review_outcome' <<<"$failure")" \
      "$movement during the CI wait emits infrastructure failure"
    assert_contains "$(jq -r '.summary.en' <<<"$failure")" 'while the review waited for CI' \
      "$movement failure names the CI wait"
    assert_contains "$(cat "$df/stderr")" 'fm-review: the PR changed while the review waited for CI' \
      "$movement refusal explains why no review ran"
    assert_contains "$(cat "$df/stderr")" 'fm-binding:' "$movement preserves the binding refusal reason"
  fi
  assert_fail "test -e '$rf/state/runs/$actor/stale-final.txt'" "$movement during the CI wait leaves no stale final"
  rm -rf "$df"
done

# Locally owned stock managed CLI fixture; no manufactured authentication.
python3 - "$ROOT" <<'PY_ASK'
import json
import os
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

root = Path(sys.argv[1])

class AskClarification(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve()
        self.repo = self.home / 'repo'
        self.repo.mkdir()
        self.tools = self.home / 'tools'
        self.tools.mkdir()
        self.roundtmp = self.home / 'tmp'
        self.roundtmp.mkdir()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('FM_', 'HERDR_', 'GIT_', 'CODEX_', 'CMUX_', 'TMUX', 'XDG_'))}
        self.env.update(HOME=str(self.home), TMPDIR=str(self.roundtmp),
                        PATH=str(self.tools) + os.pathsep + os.environ['PATH'],
                        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
                        FM_ROOT=str(self.repo), FM_TRANSPORT='direct', HERDR_ENV='0',
                        GH_REPO='fixture/project', FM_REVIEW_CI_WAIT='0', FM_GH=str(self.tools / 'gh'))
        shutil.copytree(root / 'bin', self.repo / 'bin')
        shutil.copytree(root / 'skills', self.repo / 'skills')
        (self.repo / 'design/tasks').mkdir(parents=True)
        (self.repo / 'design/tasks/T-Z.json').write_text(json.dumps(dict(
            id='T-Z', title='fixture', scope=['src/**'], acceptance=['pinned review'])))
        (self.repo / 'config.yaml').write_text(
            'vendor: codex\nreviewer:\n  vendor: codex\n  mode: run\n  model: fixture-model\n')
        self.write(self.repo / 'bin/fm-auth-probe.sh',
                   '#!/bin/sh\necho "status: authenticated"\n')
        # This is only a launch fixture, never evidence of OS confinement.
        self.write(self.repo / 'bin/fm-sandbox.sh', '''#!/bin/sh
case "$1" in
 os) echo darwin;;
 covers) echo 'write read network sockets env repo-config refuse ulimit';;
 run)
   shift
   while [ "$1" != -- ]; do
     case "$1" in --started=*) echo started > "${1#*=}";; esac
     shift
   done
   shift
   exec "$@";;
 *) exit 99;;
esac
''')
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('add', '.')
        self.git('commit', '-qm', 'base')
        self.base = self.git('rev-parse', 'HEAD')
        self.git('checkout', '-qb', 'work')
        (self.repo / 'src').mkdir()
        (self.repo / 'src/a').write_text('pinned change\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'head')
        self.head = self.git('rev-parse', 'HEAD')
        self.git('commit', '-q', '--allow-empty', '-m', 'later head')
        self.later = self.git('rev-parse', 'HEAD')
        self.git('reset', '--hard', self.head)
        self.git('checkout', '-q', 'main')
        self.git('config', 'url.' + str(self.repo) + '.insteadOf', 'https://github.com/fixture/project.git')
        self.git('update-ref', 'refs/pull/9/head', self.head)
        self.write(self.tools / 'gh', '''#!/usr/bin/env python3
import json, pathlib, subprocess, sys
home = pathlib.Path(HOME_LITERAL)
args = sys.argv[1:]
with (home / 'ghcalls').open('a') as f: f.write(json.dumps(args) + '\\n')
if args[:2] == ['pr', 'comment']:
    (home / 'published').write_text(args[args.index('--body') + 1])
elif args and args[0] == 'api' and 'protection' in ' '.join(args):
    if (home / 'move').exists():
        subprocess.run(['git', '-C', str(home / 'repo'), 'update-ref', 'refs/heads/work', LATER_LITERAL], check=True)
    print('{"contexts":["ci"]}')
elif args and args[0] == 'api' and 'check-runs' in ' '.join(args):
    print('{"check_runs":[]}')
elif args[:2] == ['pr', 'view'] and 'comments' in args:
    print((home / 'comments.json').read_text() if (home / 'comments.json').exists() else '{"comments":[]}')
elif args[:2] == ['pr', 'view'] and 'headRefOid,baseRefOid,baseRefName,headRefName,state' in args:
    head = subprocess.check_output(['git', '-C', str(home / 'repo'), 'rev-parse', 'refs/pull/9/head'], text=True).strip()
    print(json.dumps(dict(state='OPEN', headRefOid=head, baseRefOid=BASE_LITERAL,
                         headRefName='work', baseRefName='main')))
elif '--json' in args:
    print('[]')
'''.replace('HOME_LITERAL', repr(str(self.home))).replace('LATER_LITERAL', repr(self.later)).replace('HEAD_LITERAL', repr(self.head)).replace('BASE_LITERAL', repr(self.base)))
        self.write(self.tools / 'codex', '''#!/usr/bin/env python3
import json, pathlib, subprocess, sys, re, hashlib
home = pathlib.Path(HOME_LITERAL)
if sys.argv[1:] == ['--version']:
    print('codex-cli fixture'); raise SystemExit
assert sys.argv[1] == 'exec' and sys.argv[-1] == '-'
assert '--json' in sys.argv and '--output-last-message' not in sys.argv
assert sys.argv[sys.argv.index('-m') + 1] == 'fixture-model'
prompt = sys.stdin.read()
mode = (home / 'mode').read_text()
old = list(home.glob('capture-*.json'))
number = len(old) + 1
checkout = pathlib.Path.cwd()
record = dict(prompt=prompt, checkout=str(checkout),
              head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
              clean=not subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip())
if '# Bounded review context' in prompt:
    archive = pathlib.Path(re.search(r'are retained in (.+?)\\. Those paths', prompt)[1])
    assert checkout in archive.parents
    record['archive'] = str(archive)
    record['sources'] = {p.name: p.read_text() for p in archive.iterdir()}
    for name in ('history.md', 'diff.md'):
        digest = hashlib.sha256((archive / name).read_bytes()).hexdigest()
        assert digest in prompt, (name, 'missing source digest')
(home / ('capture-%s.json' % number)).write_text(json.dumps(record))
assert record['clean'], 'every invocation starts fresh'
(checkout / 'review-scratch').write_text('legitimate reviewer write')
print(json.dumps({'type':'thread.started', 'thread_id':'fixture'}))
print(json.dumps({'type':'turn.started'}))
answer = (home / 'answer').read_text()
print(json.dumps({'type':'item.completed','item':{'type':'command_execution','aggregated_output':answer}}))
if mode == 'unavailable':
    print('rate limit exceeded'); raise SystemExit(2)
if mode == 'retry' and number == 1:
    answer = 'Read the files; no decision yet.'
if mode == 'transcript':
    answer = 'No signed final answer.'
print(json.dumps({'type':'item.completed','item':{'id':'final','type':'agent_message','text':answer}}))
if mode != 'failed-turn':
    print(json.dumps({'type':'turn.completed','usage':{}}))
else:
    print(json.dumps({'type':'turn.failed','error':{'message':'fixture failure'}}))
'''.replace('HOME_LITERAL', repr(str(self.home))))

    def write(self, path, source):
        path.write_text(source)
        path.chmod(0o755)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args],
            env=self.env, stderr=subprocess.DEVNULL, text=True).strip()

    def run_review(self, mode='success', round_number='1', **extra):
        (self.home / 'mode').write_text(mode)
        result = subprocess.run([str(self.repo / 'bin/fm-review.sh'), '--task', 'T-Z',
            '--branch', 'work', '--pr', '9', '--round', round_number], cwd=self.repo, env=dict(self.env, **extra),
            capture_output=True, text=True, timeout=90)
        self.assertFalse(list(self.roundtmp.glob('fm-review.*')), result.stderr)
        self.assertFalse(list(self.roundtmp.glob('fm-round.*')), result.stderr)
        return result

    def seed(self, actor, text):
        subprocess.run([sys.executable, str(root / 'tests/lib/evidence.py'), str(root),
                        str(self.repo / 'state'), 'T-Z', actor, text], env=self.env, check=True)

    def test_ask_clarification_every_truthful_verdict_and_round(self):
        self.seed('reviewer-old', '1. open history\nCRITERIA-COMPLETE:T-Z\nREJECT:T-Z')
        self.seed('reviewer-old', '1. open timestamp\n2. open history\nCRITERIA-COMPLETE:T-Z\nREJECT:T-Z')
        records = self.repo / 'state/evidence/self/T-Z'
        legacy = json.loads(next(records.glob('*.json')).read_text())
        legacy.pop('signature')
        (records / '00000000-unsealed.json').write_text(json.dumps(legacy))
        for actor in ('firstmate', 'worker-fixture'):
            self.seed(actor, 'PRIVATE_PROSE /private/STATE_SENTINEL\nASK-PASS-CRITERIA:T-Z')
        before = {p: p.read_bytes() for p in records.glob('*.json')}
        pins = {}
        for number, verdict in ((2, 'APPROVE'), (3, 'REJECT'), (5, 'APPROVE')):
            state = 'done' if verdict == 'APPROVE' else 'open'
            (self.home / 'answer').write_text(f'1. {state} timestamp: independently checked\n2. {state} history: independently checked\nCRITERIA-COMPLETE:T-Z\n{verdict}:T-Z\nREVIEWER_COMPLETE:T-Z')
            result = self.run_review(round_number=str(number))
            self.assertEqual(0, result.returncode, result.stderr)
            capture = json.loads(sorted(self.home.glob('capture-*.json'))[-1].read_text())
            self.assertIn('ASK-PASS-CRITERIA:T-Z', capture['prompt'])
            self.assertIn('Before any truthful verdict, including APPROVE or REJECT, independently reissue the complete contiguous numbered standing list', capture['prompt'], 'ASK clarification every truthful verdict: fixed stock instruction')
            self.assertIn('close it with CRITERIA-COMPLETE:T-Z', capture['prompt'])
            self.assertNotIn('PRIVATE_PROSE', capture['prompt'])
            receipt = json.loads(max((self.repo / 'state').rglob('last-result.json'), key=lambda p: p.stat().st_mtime_ns).read_text())
            latest = [json.loads(p.read_text()) for p in sorted(records.glob('*.json')) if json.loads(p.read_text())['kind'] == 'verdict'][-1]
            self.assertEqual('authenticated', latest['provenance']['level'])
            self.assertEqual(receipt['final_sha256'], latest['provenance']['final_sha256'])
            self.assertEqual(hashlib.sha256((Path(receipt['attempt']) / 'final.txt').read_bytes()).hexdigest(), receipt['final_sha256'])
            self.assertEqual(capture['checkout'], receipt['review']['checkout'])
            self.assertEqual(self.head, receipt['review']['head'])
            self.assertEqual(self.head, latest['binding']['head'])
            self.assertEqual(self.base, latest['binding']['base'])
            self.assertEqual(self.base, receipt['review']['base'])
            invocation = json.loads((Path(receipt['attempt']) / 'invocation.json').read_text())
            self.assertEqual(invocation['review'], receipt['review'])
            self.assertEqual(invocation['actor'], receipt['actor'])
            self.assertEqual(receipt['review']['patch'], latest['binding']['patch'])
            self.assertEqual(pins, {p: p.read_bytes() for p in pins})
            pins.update({p: p.read_bytes() for p in (self.repo / 'state').rglob('*')
                         if p.is_file() and p.name in ('spec.json', 'design.md', 'contract.yaml')})
        self.assertTrue(pins, 'existing pin bytes were compared across new launches')
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_ordinary_approval_migration_without_ask(self):
        for number in (1, 2):
            (self.home / 'answer').write_text('APPROVE:T-Z\nREVIEWER_COMPLETE:T-Z')
            result = self.run_review(round_number=str(number))
            self.assertEqual(0, result.returncode, result.stderr)
            capture = json.loads(sorted(self.home.glob('capture-*.json'))[-1].read_text())
            self.assertNotIn('Before any truthful verdict, including APPROVE or REJECT, independently reissue', capture['prompt'])
            if number == 1:
                self.seed('reviewer-old', 'ASK-PASS-CRITERIA:T-Z\n1. open history\nCRITERIA-COMPLETE:T-Z\nREJECT:T-Z')

    def test_worker_only_ask_and_private_old_instruction_mutation(self):
        self.seed('worker-fixture', 'WORKER_ONLY_PROSE\nASK-PASS-CRITERIA:T-Z')
        (self.home / 'answer').write_text('APPROVE:T-Z\nREVIEWER_COMPLETE:T-Z')
        result = self.run_review(round_number='2')
        self.assertEqual(0, result.returncode, result.stderr)
        capture = json.loads((self.home / 'capture-1.json').read_text())
        instruction = 'Before any truthful verdict, including APPROVE or REJECT, independently reissue the complete contiguous numbered standing list'
        self.assertIn(instruction, capture['prompt'], 'worker-only ASK receives fixed stock instruction')
        # Private fixture mutation restores old history behavior, never production code.
        launcher = self.repo / 'bin/fm-review.sh'
        source = launcher.read_text()
        begin = source.find('  local history\n', source.index('closed_list() {'))
        end = source.find("  printf '\\nEvery REJECT", begin)
        if begin >= 0 and end >= 0:
            launcher.write_text(source[:begin] + '  fm_evidence history --reviewer || return 1\n' + source[end:])
        result = self.run_review(round_number='3')
        self.assertEqual(0, result.returncode, result.stderr)
        mutated = json.loads((self.home / 'capture-2.json').read_text())
        self.assertNotIn(instruction, mutated['prompt'], 'old stock history mutation removes the feature instruction')
        with self.assertRaises(AssertionError, msg='the same named instruction assertion is behaviorally red under the private old-code mutation'):
            self.assertIn(instruction, mutated['prompt'], 'ASK clarification every truthful verdict: fixed stock instruction')

    def test_history_nonce_boundaries_only_actual_standalone_ask_clarifies(self):
        # Signed legacy records exercise quotation, not managed authentication.
        # The independent managed final-capture assertions above remain intact.
        sys.path.insert(0, str(root / 'bin/lib'))
        from fm_evidence import Store
        marker = 'ASK-PASS-CRITERIA:T-Z'
        instruction = 'ASK clarification: Before any truthful verdict'
        cases = (
            ('mismatched-close', '----- end deadbeef -----\n' + marker, None),
            ('nested-pair', '----- begin cafe -----\n----- end cafe -----\n' + marker, None),
            ('nested-begin', '----- begin cafe -----\n' + marker, None),
            ('normal-quoted', marker, None),
            ('ordinary-no-ask', 'ordinary review prose', None),
            ('malformed-truncated', '----- begin bad -----\n----- end bad ----\n'
             '----- end -----\n----- begin\n' + marker, None),
            ('matching-close-operator', '----- begin cafe -----\n----- end deadbeef -----\n'
             + marker, 'firstmate'),
            ('matching-close-worker', '----- begin cafe -----\n' + marker, 'worker-fixture'),
        )
        script = (root / 'bin/fm-review.sh').read_text()
        start = script.index('closed_list() {')
        assembly = script[start:script.index('\n}\n', start) + 3]
        for name, quoted, actor in cases:
            with self.subTest(case=name):
                state = self.home / ('nonce-' + name)
                store = Store(state, 'self', 'T-Z')
                store.append('verdict', 1, 'reviewer-old', self.head,
                             quoted + '\n1. open retained finding\nCRITERIA-COMPLETE:T-Z\nREJECT:T-Z',
                             verdict='REJECT', provenance={'level': 'legacy'})
                if actor:
                    store.append('ask', 2, actor, self.head, 'EXCLUDED_ASK_PROSE\n' + marker)
                before = {p: p.read_bytes() for p in store.directory.glob('*.json')}
                authority = store.records()
                self.assertTrue(all(r.get('signature') for r in authority))
                self.assertEqual(bool(actor), any(r['kind'] == 'ask' for r in authority))
                proc = subprocess.run(['bash', '-c',
                    '. "$CODE/bin/fm-config.sh"; TASK=T-Z; ' + assembly + '\nclosed_list'],
                    env=dict(self.env, FM_STATE_DIR=str(state), FM_PROJECT='self',
                             FM_EXTERNAL='0', CODE=str(root)),
                    capture_output=True, text=True, check=True)
                self.assertIn(quoted, proc.stdout, 'production Store.history retains quoted bytes')
                if actor:
                    self.assertIn(instruction, proc.stdout,
                                  'exact generated enclosing close restores genuine standalone ASK')
                else:
                    self.assertNotIn(instruction, proc.stdout,
                                     'nonce boundary: quoted markers never request clarification')
                self.assertNotIn('EXCLUDED_ASK_PROSE', proc.stdout)
                self.assertEqual(before, {p: p.read_bytes() for p in store.directory.glob('*.json')})
                self.assertEqual(authority, store.records(), 'signed history authority unchanged')

    def test_external_private_store_marker_only_stock_context(self):
        # Execute the stock history assembly against a private external Store.
        # No authenticated verdict is manufactured in this transport fixture.
        sys.path.insert(0, str(root / 'bin/lib'))
        from fm_evidence import Store
        from fm_review_context import compose
        private = self.home / 'PRIVATE_STATE_SENTINEL'
        store = Store(private, 'private-project', 'T-Z', external=True)
        for actor in ('firstmate', 'worker-fixture'):
            store.append('ask', 2, actor, self.head,
                         f'PRIVATE_{actor}_PROSE {private}\nASK-PASS-CRITERIA:T-Z')
        store.append('worker-report', 2, 'worker-fixture', self.head, 'PRIVATE_REPORT_PROSE')
        store.append('brief', 2, 'firstmate', self.head, 'PRIVATE_BRIEF_PROSE')
        before = {p: p.read_bytes() for p in store.directory.glob('*.json')}
        # Real Store.history and the launcher's own fixed instruction, not a test copy.
        script = (root / 'bin/fm-review.sh').read_text()
        start = script.index('closed_list() {')
        end = script.index('\n}\n', start) + 3
        assembly = script[start:end]
        proc = subprocess.run(['bash', '-c',
            '. "$CODE/bin/fm-config.sh"; TASK=T-Z; ' + assembly + '\nclosed_list'],
            env=dict(self.env, FM_EXTERNAL='1', FM_STATE_DIR=str(private),
                     FM_PROJECT='private-project', CODE=str(root)),
            capture_output=True, text=True, check=True)
        context = self.home / 'public-context'
        context.mkdir()
        for part in ('intro', 'history', 'evidence', 'diff', 'outro'):
            (context / (part + '.md')).write_text(proc.stdout if part == 'history' else '')
        compose(context, 'diff', self.repo)
        prompt = (context / 'prompt.md').read_text()
        self.assertIn('ASK-PASS-CRITERIA:T-Z', prompt)
        self.assertIn('Before any truthful verdict, including APPROVE or REJECT', prompt)
        public = (context / 'prompt.md').read_bytes()
        # Real optional-comment wrapper; only the final delivery endpoint is a fixture.
        subprocess.run(['bash', '-c',
            '. "$CODE/bin/fm-config.sh"; fm_projection() { echo comments; }; '
            'fm_github() { cp "$5" "$COMMENT"; }; '
            'fm_comment_projection 9 --body-file "$PUBLIC"'],
            env=dict(self.env, FM_EXTERNAL='1', CODE=str(root),
                     COMMENT=str(self.home / 'optional-comment'), PUBLIC=str(context / 'prompt.md')),
            check=True)
        (self.repo / 'public-artifact').write_bytes(public)
        for path in [*context.glob('*.md'), self.home / 'optional-comment', self.repo / 'public-artifact']:
            content = path.read_text()
            for sentinel in ('PRIVATE_firstmate_PROSE', 'PRIVATE_worker-fixture_PROSE',
                             'PRIVATE_STATE_SENTINEL', 'PRIVATE_REPORT_PROSE', 'PRIVATE_BRIEF_PROSE'):
                self.assertNotIn(sentinel, content)
        self.assertEqual(before, {p: p.read_bytes() for p in before})
        self.assertFalse((self.repo / 'state/evidence/private-project').exists())

unittest.main(argv=['ask-clarification'], verbosity=2)
PY_ASK
assert_eq 0 "$?" "managed ASK clarification lifecycle"

finish
