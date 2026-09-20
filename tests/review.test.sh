#!/usr/bin/env bash
# What the reviewer is shown is the whole point of this script.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

fixture() {
  local d; d="$(mktemp -d)"
  git init -q -b main "$d/repo"; cd "$d/repo" || return 1
  git config user.email a@b.c; git config user.name t
  mkdir -p bin design skills/reviewer src state
  cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-review.sh" bin/
  cp -r "$ROOT/bin/adapters" bin/
  cp "$ROOT/skills/reviewer/SKILL.md" skills/reviewer/
  printf 'vendor: mock\n' > config.yaml
  printf '{"tasks":[{"id":"T-Z","title":"a task","scope":["src/**"],"acceptance":["it exists"]}]}\n' > design/tasks.json
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
assert_fail "printf '%s' \"$types\" | tail -1 | grep -q approved" "and signed nothing"

# a vendor named in config.yaml with no adapter behind it is a typo, not an
# outage: reporting it as transient would have fm-run say "leaving it for
# the next turn" on every turn, forever
printf 'vendor: mock\nreviewer:\n  vendor: nosuchvendor\nfallback:\n  - mock\n' > "$r/config.yaml"
out="$(cd "$r" && FM_ROOT="$r" FM_GH="$GH" bin/fm-review.sh --task T-Z --branch work --pr 9 2>&1)"
assert_eq "65" "$?" "a vendor with no adapter is a configuration error"
assert_contains "$out" "no adapter" "and says which one"

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
assert_fail "printf '%s' \"$out\" | grep -q 'the fallback reviewed it'" "and the worker's engine is not used"

rm -rf "$d"


finish
