#!/usr/bin/env bash
# Each gate has a case that passes and one that does not; gate 4 also runs
# whatever the fixture's own config.yaml declares under project:.
set -uo pipefail
# A gate run exports FM_GATE_LOCK_HELD, and a Herdr session its pane ids, into
# every suite it runs. This suite runs the real gate, so it inherits none of
# them: identity, locks and cards bind to its fixtures, not the outer run.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
export HERDR_ENV=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/lib/head-binding.sh"
. "$ROOT/tests/lib/spec-pins.sh"
GATE="$ROOT/bin/fm-gate.sh"
# this suite's own gate lock: it neither waits on a real gate run on this
# machine nor holds one up, and a run that encloses it (gate 4 of this very
# repository) holds a different lock, so the serialization below is real
FM_GATE_LOCK="$(mktemp -d)/gate.lock"; export FM_GATE_LOCK

# a fixture repo whose config.yaml declares its check, a task file, and main
# at a known state. The check script is the fixture's, not firstmate's: the
# gate knows it only by what config.yaml says.
fixture() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q -b main
  git -C "$d" config user.email a@b.c; git -C "$d" config user.name t
  mkdir -p "$d/bin" "$d/tests" "$d/design/tasks" "$d/src"
  printf '#!/usr/bin/env bash\nfor t in "${FM_ROOT:-.}"/tests/*.test.sh; do [ -e "$t" ] || continue; bash "$t" || exit 1; done\nexit 0\n' > "$d/bin/suite"
  chmod +x "$d/bin/suite"
  printf 'vendor: mock\nproject:\n  check: bin/suite\n' > "$d/config.yaml"
  cat > "$d/design/tasks/T-X.json" <<JSON
{"id":"T-X","scope":["src/**","tests/**","bin/**","config.yaml"]}
JSON
  echo base > "$d/src/thing.sh"
  echo design > "$d/design/design.md"
  printf 'state/\n' > "$d/.gitignore"
  git -C "$d" add -A; git -C "$d" commit -qm base
  seed_spec_pin "$d" T-X
  printf '%s' "$d"
}
# declare <repo> <branch-to-create> <from> ; the new config.yaml arrives on stdin
declare_on() {
  git -C "$1" checkout -q -b "$2" "$3"
  cat > "$1/config.yaml"
  git -C "$1" add -A; git -C "$1" commit -qm "$2"; git -C "$1" checkout -q main
}
gate() { "$GATE" --task T-X --repo "$1" --branch "$2" --only "$3" "${@:4}" >/dev/null 2>&1; }
said() { "$GATE" --task T-X --repo "$1" --branch "$2" --only "$3" 2>&1; }

# --- gate 1 --------------------------------------------------------------
d="$(fixture)"
assert_fail "'$GATE' --task T-X --repo '$d' --branch nope --only 1" "1 blocks a branch that does not exist"
git -C "$d" checkout -q -b work; echo x >> "$d/src/thing.sh"; git -C "$d" commit -qam work
git -C "$d" checkout -q main
assert_ok "gate '$d' work 1" "1 passes a branch with commits"

# --- gate 2 --------------------------------------------------------------
assert_ok "gate '$d' work 2" "2 passes a branch that rebases cleanly"
git -C "$d" checkout -q main; echo conflicting > "$d/src/thing.sh"; git -C "$d" commit -qam diverge
assert_fail "gate '$d' work 2" "2 blocks a branch that conflicts"

d="$(fixture)"; git -C "$d" checkout -q -b green
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/tests/a.test.sh"; chmod +x "$d/tests/a.test.sh"
echo impl > "$d/src/thing.sh"; git -C "$d" add -A; git -C "$d" commit -qm green; git -C "$d" checkout -q main
# --- gate 3 --------------------------------------------------------------
assert_ok "gate '$d' green 3" "3 passes a diff inside the declared scope"
git -C "$d" checkout -q -b wide green
mkdir -p "$d/elsewhere"; echo x > "$d/elsewhere/f"; git -C "$d" add -A; git -C "$d" commit -qm wide
git -C "$d" checkout -q main
assert_fail "gate '$d' wide 3" "3 blocks a diff that reaches outside it"

# A branch cannot expand its own approved scope (T-049).
git -C "$d" checkout -q -b ownfile green
printf '{"id":"T-X","scope":["src/**","tests/**","bin/**","config.yaml","design/tasks/T-X.json","elsewhere/**"]}\n' \
  > "$d/design/tasks/T-X.json"
mkdir -p "$d/elsewhere"; echo x > "$d/elsewhere/f"; git -C "$d" add -A; git -C "$d" commit -qm ownfile
git -C "$d" checkout -q main
assert_fail "gate '$d' ownfile 3" "3 rejects a branch that widens its own task scope"
assert_contains "$(said "$d" ownfile 3)" "task spec in diff" "3 names the forbidden spec change"

# --- gate 4: the one that matters ---------------------------------------
d="$(fixture)"
git -C "$d" checkout -q -b vacuous
printf 'real\n' > "$d/src/thing.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/tests/v.test.sh"        # asserts nothing
chmod +x "$d/tests/v.test.sh"; git -C "$d" add -A; git -C "$d" commit -qm vacuous
git -C "$d" checkout -q main
assert_fail "gate '$d' vacuous 4" "4 blocks a test that passes without the implementation"

git -C "$d" checkout -q -b honest main
mkdir -p "$d/tests"          # git does not track an empty directory
printf 'real\n' > "$d/src/thing.sh"
printf '#!/usr/bin/env bash\ngrep -q real "${FM_ROOT:-.}/src/thing.sh"\n' > "$d/tests/h.test.sh"
chmod +x "$d/tests/h.test.sh"; git -C "$d" add -A; git -C "$d" commit -qm honest
git -C "$d" checkout -q main
assert_ok "gate '$d' honest 4" "4 passes a test that goes red without it"

git -C "$d" checkout -q -b untested main
printf 'more\n' >> "$d/src/thing.sh"; git -C "$d" commit -qam untested; git -C "$d" checkout -q main
assert_fail "gate '$d' untested 4" "4 blocks implementation that ships no test at all"

touched() {
  local r; r="$(mktemp -d)"
  git -C "$r" init -q -b main
  git -C "$r" config user.email a@b.c; git -C "$r" config user.name t
  mkdir -p "$r/src" "$r/tests" "$r/design/tasks" "$r/marks"
  printf 'project:\n  check: touch %q/marks/check\n  test: bash {file}\n' "$r" > "$r/config.yaml"
  printf 'touch %q/marks/other\n' "$r" > "$r/tests/other.test.sh"
  # a helper one untouched suite sources, and so exercises
  printf 'verify() { true; }\n' > "$r/tests/helper.sh"
  printf '. "${FM_ROOT:-.}/tests/helper.sh"\nverify\n' > "$r/tests/uses.test.sh"
  # and one that names only a longer name with helper.sh inside it
  printf 'touch %q/marks/near   # fm-helper.sh, not the helper above\n' "$r" > "$r/tests/near.test.sh"
  printf 'base\n' > "$r/src/thing.sh"
  printf '{"id":"T-X","scope":["src/**","tests/**","config.yaml"]}\n' > "$r/design/tasks/T-X.json"
  printf 'marks/\nstate/\n' > "$r/.gitignore"
  echo design > "$r/design/design.md"
  git -C "$r" add -A; git -C "$r" commit -qm base
  seed_spec_pin "$r" T-X
  printf '%s' "$r"
}
t5="$(touched)"
git -C "$t5" checkout -q -b honest
printf 'real\n' > "$t5/src/thing.sh"
printf 'grep -q real "${FM_ROOT:-.}/src/thing.sh"\n' > "$t5/tests/h.test.sh"
git -C "$t5" add -A; git -C "$t5" commit -qm honest; git -C "$t5" checkout -q main

# --- gates 5 and 6: gh is injectable so the suite makes no network call ---
stub() {
  local conclusion=success
  [ "$2" = 0 ] || conclusion=failure
  head_binding_fixture "$1" b "$conclusion"
  printf '%s' "$1/stub/head-gh"
}
d2="$(fixture)"; git -C "$d2" checkout -q -b b; echo y >> "$d2/src/thing.sh"
git -C "$d2" commit -qam b; git -C "$d2" checkout -q main

assert_ok   "FM_GH='$(stub "$d2" 0 reviewer-1)' gate '$d2' b 5 --pr 9" "5 passes when the required check is green"
assert_fail "FM_GH='$(stub "$d2" 1 reviewer-1)' gate '$d2' b 5 --pr 9" "5 blocks when it is not"
assert_fail "'$GATE' --task T-X --repo '$d2' --branch b --only 5" "5 blocks with no pull request at all"

# --- gate 6: the approval binds to the change, not the head (T-113) --------
# `gh pr view <pr> --json comments` answers with the comments as JSON, the
# way GitHub does, and with --jq runs the filter over it and prints strings
# raw, the way gh does, so a gate that filters with --jq is read as it would
# be for real. Each comment is one line of comments.tsv: author, then the
# body with \n for its newlines.
ghc() {  # ghc <dir> ; a gh whose pr view answers from <dir>/comments.tsv
  mkdir -p "$1/stub"
  : > "$1/comments.tsv"
  cat > "$1/stub/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "repo view" ]; then echo fixture/project; exit; fi
if [[ " \$* " = *" --json headRefOid,baseRefOid,baseRefName,headRefName,state "* ]]; then
  h="\$(git -C "$1" rev-parse main)"
  printf '{"state":"OPEN","headRefOid":"%s","baseRefOid":"%s","baseRefName":"main","headRefName":"b"}\n' "\$h" "\$h"
  exit
fi
if [ "\$1 \$2" = "pr view" ]; then
  filter=.
  while [ \$# -gt 0 ]; do [ "\$1" = --jq ] && { filter="\$2"; break; }; shift; done
  jq -Rn '{comments:[inputs|split("\t")|{author:{login:.[0]},body:(.[1]|gsub("\\\\\\\n";"\n"))}]}' < "$1/comments.tsv" |
    if [ "\$filter" = . ]; then cat; else jq -r "\$filter"; fi
  exit
fi
exit 0
EOF
  chmod +x "$1/stub/gh"; printf '%s' "$1/stub/gh"
}
# reviewed <repo> <branch> <verdict> ; the line fm-review.sh posts, worked
# out here from git's porcelain rather than from the script under test
reviewed() {
  local h b p f
  h="$(git -C "$1" rev-parse "$2")"; b="$(git -C "$1" merge-base main "$2")"
  p="$(git -C "$1" diff "main...$2" | git -C "$1" patch-id --stable | cut -d' ' -f1)"
  f="$(git -C "$1" diff --name-only "main...$2" | jq -Rnc '[inputs]')"
  printf 'REVIEWED:T-X verdict=%s head=%s base=%s patch=%s files=%s' "$3" "$h" "$b" "$p" "$f"
}
post() {
  printf '%s\t%s\n' "$2" "$3" >> "$1/comments.tsv"
  python3 "$ROOT/tests/lib/evidence.py" "$ROOT" "$1/state" T-X "$2" "$3"
}   # post <dir> <author> <body>
approval_gate() { FM_GH="$d7/stub/gh" FM_REVIEWER_LOGIN=reviewer-1 "$GATE" --task T-X --repo "$d7" --branch "$1" --only 6 --pr 9 2>&1; }

d7="$(fixture)"; ghc "$d7" >/dev/null
# thing.sh long enough that main can change its far end and still merge cleanly
seq 1 30 > "$d7/src/thing.sh"; echo notes > "$d7/README.md"
git -C "$d7" add -A; git -C "$d7" commit -qm "longer thing"
git -C "$d7" checkout -q -b pr main
sed -i.bak '1s/.*/changed by the pull request/' "$d7/src/thing.sh"; rm -f "$d7/src/thing.sh.bak"
git -C "$d7" commit -qam "the change"; git -C "$d7" checkout -q main
# every line below is built by reviewed(), so it must carry real values: an
# empty head or patch-id would make both sides of a comparison agree on nothing
assert_matches "$(reviewed "$d7" pr APPROVE)" \
  '^REVIEWED:T-X verdict=APPROVE head=[0-9a-f]{40} base=[0-9a-f]{40} patch=[0-9a-f]{40} files=\["src/thing\.sh"\]$' \
  "(the REVIEWED line the tests post carries a head, merge-base, patch-id and the changed file)"

post "$d7" reviewer-1 "looks right\\nAPPROVE:T-X\\n\\n$(reviewed "$d7" pr APPROVE)"
out="$(approval_gate pr)"; rc=$?
assert_eq "0" "$rc" "(6 passes on an APPROVE for the current head, as it did before)"
: > "$d7/comments.tsv"
rm -rf "$d7/state/evidence"
post "$d7" someone-else "APPROVE:T-X\\n\\n$(reviewed "$d7" pr APPROVE)"
out="$(approval_gate pr)"; rc=$?
assert_eq "6" "$rc" "(6 ignores APPROVE from anyone but the reviewer, as it did before)"

# the reviewer approves the pull request as it stands ...
: > "$d7/comments.tsv"
rm -rf "$d7/state/evidence"
post "$d7" reviewer-1 "APPROVE:T-X\\n\\n$(reviewed "$d7" pr APPROVE)"
approved_head="$(git -C "$d7" rev-parse pr)"
# ... then main moves on, touching none of its files, and the pull request is
# brought up to date with a merge, as gh pr update-branch does
echo "more notes" >> "$d7/README.md"; git -C "$d7" commit -qam "main: notes"
git -C "$d7" checkout -q -b updated pr; git -C "$d7" merge -q --no-edit main
git -C "$d7" checkout -q main
assert_ne "$approved_head" "$(git -C "$d7" rev-parse updated)" "(the update moved the head)"
out="$(approval_gate updated)"; rc=$?
assert_eq "0" "$rc" "(6 carries the APPROVE forward across an update-only head; the base passed any head)"

# the worker edits after the approval: another change, another review
git -C "$d7" checkout -q -b edited updated
sed -i.bak '2s/.*/and a worker edit/' "$d7/src/thing.sh"; rm -f "$d7/src/thing.sh.bak"
git -C "$d7" commit -qam "an edit"; git -C "$d7" checkout -q main
out="$(approval_gate edited)"; rc=$?
assert_eq "6" "$rc" "6 blocks a head whose change has a different patch-id"
assert_contains "$out" "condition 1" "and names the condition that failed"
assert_contains "$out" "patch-id" "which is the patch-id"

# main touches a file the pull request changes, far enough away to merge
# cleanly and leave the patch-id as it was: the change is the one approved,
# so the approval still stands (SK-008), whatever file main touched
sed -i.bak '30s/.*/main changed the end/' "$d7/src/thing.sh"; rm -f "$d7/src/thing.sh.bak"
git -C "$d7" commit -qam "main: thing"
git -C "$d7" checkout -q -b touched updated; git -C "$d7" merge -q --no-edit main
git -C "$d7" checkout -q main
assert_eq "$(git -C "$d7" diff main...pr | git -C "$d7" patch-id --stable | cut -d' ' -f1)" \
  "$(git -C "$d7" diff main...touched | git -C "$d7" patch-id --stable | cut -d' ' -f1)" \
  "(the change itself is identical)"
out="$(approval_gate touched)"; rc=$?
assert_eq "0" "$rc" "6 carries the APPROVE forward when main touched a file the approval reviewed and the patch-id is unchanged"
assert_lacks "$out" "re-review" "and asks for no re-review"

# main changes the very line the pull request changes: the update conflicts,
# and the resolution changes the patch-id, so it needs a new review
sed -i.bak '1s/.*/main changed the start/' "$d7/src/thing.sh"; rm -f "$d7/src/thing.sh.bak"
git -C "$d7" commit -qam "main: the start"
git -C "$d7" checkout -q -b resolved touched
git -C "$d7" merge -q --no-edit main >/dev/null 2>&1 || true
assert_contains "$(sed -n 1p "$d7/src/thing.sh")" "<<<<<<<" "(fixture) merging main into the PR branch conflicts on the line both changed"
{ echo "changed by the pull request, after main changed the start"; sed -n '/^>>>>>>>/,$p' "$d7/src/thing.sh" | sed 1d; } > "$d7/src/thing.sh.new"
mv "$d7/src/thing.sh.new" "$d7/src/thing.sh"
git -C "$d7" commit -qam "resolve the conflict"; git -C "$d7" checkout -q main
assert_ne "$(git -C "$d7" diff main...pr | git -C "$d7" patch-id --stable | cut -d' ' -f1)" \
  "$(git -C "$d7" diff main...resolved | git -C "$d7" patch-id --stable | cut -d' ' -f1)" \
  "(the resolution changed the change)"
out="$(approval_gate resolved)"; rc=$?
assert_eq "6" "$rc" "6 blocks a carry-forward across a resolved conflict, whose patch-id changed"
assert_contains "$out" "condition 1" "and names the patch-id condition"

# a later REJECT supersedes the APPROVE, carried forward or not
post "$d7" reviewer-1 "1. open fix the helper\\nCRITERIA-COMPLETE:T-X\\nREJECT:T-X\\n\\n$(reviewed "$d7" pr REJECT)"
out="$(approval_gate updated)"; rc=$?
assert_eq "6" "$rc" "6 blocks an APPROVE superseded by a later REJECT"
assert_contains "$out" "condition 2" "and names the condition that failed"
assert_contains "$out" "REJECT" "which is the later REJECT"
: > "$d7/comments.tsv"
rm -rf "$d7/state/evidence"
post "$d7" reviewer-1 "APPROVE:T-X\\n\\n$(reviewed "$d7" pr APPROVE)"
post "$d7" reviewer-1 "1. open fix the helper\\nCRITERIA-COMPLETE:T-X\\nREJECT:T-X"
out="$(approval_gate pr)"; rc=$?
assert_eq "6" "$rc" "6 blocks even the approved head once a REJECT follows"
# a rejection that mentions the approve marker on the way, posted the way
# fm-review.sh posts it: the reviewer's words, then the REVIEWED line
: > "$d7/comments.tsv"
rm -rf "$d7/state/evidence"
post "$d7" reviewer-1 "I cannot sign APPROVE:T-X while item 1 stands\\n1. open fix the helper\\nCRITERIA-COMPLETE:T-X\\nREJECT:T-X\\n\\n$(reviewed "$d7" pr REJECT)"
out="$(approval_gate pr)"; rc=$?
assert_eq "6" "$rc" "6 blocks a REJECT whose text mentions the approve marker"
assert_contains "$out" "the latest verdict is REJECT:T-X" "and says the latest verdict is REJECT"

# an APPROVE posted by hand records nothing it reviewed: it is read as it
# always was, and the gate says it binds to no head
: > "$d7/comments.tsv"
rm -rf "$d7/state/evidence"
post "$d7" reviewer-1 "APPROVE:T-X"
out="$(approval_gate updated)"; rc=$?
assert_eq "6" "$rc" "6 refuses an unbound legacy approval"
assert_contains "$out" "no reviewed head" "and says it binds to no head"
post "$d7" reviewer-1 "1. open fix the helper\\nCRITERIA-COMPLETE:T-X\\nREJECT:T-X"
out="$(approval_gate updated)"; rc=$?
assert_eq "6" "$rc" "and a later REJECT supersedes it too"

# --- no gate repeats CI (T-114) -----------------------------------------
# A whole run, every gate, on a head CI and the reviewer have passed: the
# project's check never runs, and the gates that do are 1, 2, 3, 4, 5 and 6.
# gh answers as gh does: checks green, and the reviewer's comment is the one
# fm-review.sh posts for this head, REVIEWED line included (T-113)
rm -f "$t5/marks/check" "$t5/marks/other"
ghc "$t5" >/dev/null
post "$t5" reviewer-1 "APPROVE:T-X\\n\\n$(reviewed "$t5" honest APPROVE)"
head_binding_fixture "$t5" honest
out="$(FM_GH="$t5/stub/head-gh" FM_REVIEWER_LOGIN=reviewer-1 \
  "$GATE" --task T-X --repo "$t5" --branch honest --pr 9 2>&1)"; rc=$?
assert_eq "0" "$rc" "a head with green CI and an approval passes every gate"
assert_fail "test -e '$t5/marks/check'" "and no gate ran the project's check in full"
assert_eq "1 2 3 4 5 6" "$(sed -n 's/^  + gate \([0-9]*\) ([^)]*): .*/\1/p' <<<"$out" | tr '\n' ' ' | sed 's/ $//')" \
  "the gates are 1, 2, 3, 4, 5 and 6, each said once, in that order"
assert_contains "$out" "all six gates green" "and the run says all six are green"
assert_lacks "$out" "seven" "and nowhere seven"

# T-231: ancestry diagnostics are stderr only and do not change gate outcomes.
assert_lacks "$out" "behind the base by" "current branch has no behind diagnostic"
echo base-addition > "$t5/base-only"
git -C "$t5" add base-only; git -C "$t5" commit -qm "base moves without conflict"
echo another-addition >> "$t5/base-only"
git -C "$t5" commit -qam "base moves again"
base_sha="$(git -C "$t5" rev-parse main)"
behind_line="behind the base by 2 commits (base ${base_sha:0:12}); a red check can come from the old base - bring the branch up to date"
head_binding_fixture "$t5" honest
FM_GH="$t5/stub/head-gh" FM_REVIEWER_LOGIN=reviewer-1 \
  "$GATE" --task T-X --repo "$t5" --branch honest --pr 9 >"$t5/gate-out" 2>"$t5/gate-err"
assert_eq "0" "$?" "behind clean branch still passes every gate"
assert_eq "1" "$(grep -Fc "$behind_line" "$t5/gate-err")" "full run prints exact behind diagnostic once"
assert_lacks "$(cat "$t5/gate-out")" "behind the base by" "diagnostic never enters gate stdout"
assert_contains "$(cat "$t5/gate-err")" "落後 base 2 個 commit（base ${base_sha:0:12}）" "behind diagnostic includes Chinese and resolved base"
for conclusion in success failure; do
  head_binding_fixture "$t5" honest "$conclusion"
  out="$(FM_GH="$t5/stub/head-gh" "$GATE" --task T-X --repo "$t5" --branch honest --pr 9 --only 5 2>&1)"; rc=$?
  expected=0; [ "$conclusion" = success ] || expected=5
  assert_eq "$expected" "$rc" "behind diagnostic preserves gate 5 $conclusion outcome"
  assert_eq "1" "$(grep -Fc "$behind_line" <<<"$out")" "gate 5 $conclusion prints exact behind diagnostic once"
done
for only in 1 3 4 6; do
  out="$(FM_GH="$t5/stub/head-gh" FM_REVIEWER_LOGIN=reviewer-1 "$GATE" --task T-X --repo "$t5" --branch honest --pr 9 --only "$only" 2>&1)"
  assert_lacks "$out" "behind the base by" "only gate $only omits behind diagnostic"
done
out="$(said "$t5" honest 2)"
assert_eq "1" "$(grep -Fc "$behind_line" <<<"$out")" "without PR, branch-name base resolves to SHA"
# A conflicting gate 2 must stop before the diagnostic.
echo conflict > "$t5/src/thing.sh"; git -C "$t5" commit -qam conflict
out="$(said "$t5" honest 2)"; rc=$?
assert_eq "2" "$rc" "conflicting gate 2 still fails"
assert_lacks "$out" "behind the base by" "failed gate 2 prints only its failure"

# --- gate runs on one machine never overlap (T-114) ---------------------
# finishes <seconds> <command> ; true when it ended, with status 0, in time
finishes() {
  local s="$1" p i=0; shift
  ( eval "$*" ) >/dev/null 2>&1 & p=$!
  while kill -0 "$p" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -le $(( s * 10 )) ] || { kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 1; }
    sleep 0.1
  done
  wait "$p"
}
# a gate 4 that takes a while and writes down when it starts and ends
sl="$(touched)"; trail="$sl/marks/trail"
git -C "$sl" checkout -q -b slow
printf 'real\n' > "$sl/src/thing.sh"
printf 'grep -q real "${FM_ROOT:-.}/src/thing.sh" && exit 0\necho start >> %q\nsleep 2\necho end >> %q\ngrep -q real "${FM_ROOT:-.}/src/thing.sh"\n' "$trail" "$trail" \
  > "$sl/tests/s.test.sh"
git -C "$sl" add -A; git -C "$sl" commit -qm slow; git -C "$sl" checkout -q main
lock="$(mktemp -d)/gate.lock"
FM_GATE_LOCK="$lock" "$GATE" --task T-X --repo "$sl" --branch slow --only 4 >/dev/null 2>&1 & p1=$!
FM_GATE_LOCK="$lock" "$GATE" --task T-X --repo "$sl" --branch slow --only 4 >/dev/null 2>&1 & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
assert_eq "0 0" "$r1 $r2" "two gate runs started together both pass"
assert_eq "start end start end" "$(tr '\n' ' ' < "$trail" | sed 's/ $//')" \
  "and one runs only after the other has finished"
assert_ok "finishes 20 \"FM_GATE_LOCK='$lock' '$GATE' --task T-X --repo '$sl' --branch slow --only 1\"" \
  "and a run after the last one ends does not wait"

# a holder the test controls: a real gate run whose suite says it has started
# and then waits to be let go
held="$sl/marks/held"; release="$sl/marks/release"
git -C "$sl" checkout -q -b hold main
printf 'real\n' > "$sl/src/thing.sh"
printf 'echo held > %q\nwhile [ ! -e %q ]; do sleep 0.1; done\ngrep -q real "${FM_ROOT:-.}/src/thing.sh"\n' "$held" "$release" \
  > "$sl/tests/hold.test.sh"
git -C "$sl" add -A; git -C "$sl" commit -qm hold; git -C "$sl" checkout -q main
# hold <lock> ; starts the holder in the background, and returns once it holds
hold() {
  rm -f "$held" "$release"
  FM_GATE_LOCK="$1" "$GATE" --task T-X --repo "$sl" --branch hold --only 4 >/dev/null 2>&1 & holder=$!
  for _ in $(seq 1 200); do [ -e "$held" ] && return 0; sleep 0.1; done
  return 1
}

# one that holds the lock is waited for, and says whose run it is
lock="$(mktemp -d)/gate.lock"
assert_ok "hold '$lock'" "(a gate run holds the lock)"
FM_GATE_LOCK="$lock" "$GATE" --task T-X --repo "$sl" --branch slow --only 1 > "$sl/marks/w.out" 2> "$sl/marks/w.err" & pw=$!
sleep 2
assert_ok "kill -0 $pw" "a run waits while another live run holds the lock"
assert_contains "$(cat "$sl/marks/w.err")" "waiting for the gate run holding $lock (pid $holder)" "and says whose run it waits for"
touch "$release"
wait "$holder"; rh=$?; wait "$pw"; rw=$?
assert_eq "0 0" "$rh $rw" "and goes on once the holder has finished"

# A run that is killed holds nothing afterwards, and when several runs wait on
# what it left, still only one runs at a time. A slow rename widens the window
# in which a waiter that judged the lock dead acts on a lock another waiter
# has just taken; the waiters start a moment apart so each lands in it.
lock="$(mktemp -d)/gate.lock"
assert_ok "hold '$lock'" "(a gate run holds the lock, and is then killed)"
kill -9 "$holder"; wait "$holder" 2>/dev/null
touch "$release"            # the killed run's suite is let go, and ends on its own
slowbin="$(mktemp -d)"
printf '#!/bin/sh\nsleep 0.5\nexec %q "$@"\n' "$(command -v mv)" > "$slowbin/mv"; chmod +x "$slowbin/mv"
rm -f "$trail"; pids=''
for _ in 1 2 3; do
  PATH="$slowbin:$PATH" FM_GATE_LOCK="$lock" "$GATE" --task T-X --repo "$sl" --branch slow --only 4 >/dev/null 2>&1 &
  pids="$pids $!"; sleep 0.3
done
rcs=''; for p in $pids; do wait "$p"; rcs="$rcs $?"; done
assert_eq " 0 0 0" "$rcs" "three runs waiting on a killed run's lock all pass"
assert_eq "start end start end start end" "$(tr '\n' ' ' < "$trail" | sed 's/ $//')" \
  "and no two of them overlap"

# a lock that names no holder - a run killed before it could write its pid -
# holds nobody up
lock="$(mktemp -d)/gate.lock"; : > "$lock"
assert_ok "finishes 20 \"FM_GATE_LOCK='$lock' '$GATE' --task T-X --repo '$sl' --branch slow --only 1\"" \
  "a lock that names no holder is not waited on for ever"

# The lock's path is in a directory every user writes, so another user can put
# a link there first. A gate run follows none: it neither creates, empties nor
# writes the file a link names, and it refuses rather than runs unlocked.
ld="$(mktemp -d)"
ln -s "$ld/profile" "$ld/dangling.lock"
out="$(FM_GATE_LOCK="$ld/dangling.lock" "$GATE" --task T-X --repo "$sl" --branch slow --only 1 2>&1)"; rc=$?
assert_eq "70" "$rc" "a lock that is a symlink to no file is refused"
assert_fail "test -e '$ld/profile'" "and the file it names is not created"
assert_contains "$out" "cannot use the gate lock $ld/dangling.lock" "and it names the lock"
printf 'keep\n' > "$ld/kept"; ln -s "$ld/kept" "$ld/sym.lock"
FM_GATE_LOCK="$ld/sym.lock" "$GATE" --task T-X --repo "$sl" --branch slow --only 1 >/dev/null 2>&1; rc=$?
assert_eq "70" "$rc" "a lock that is a symlink to a file is refused"
assert_eq "keep" "$(cat "$ld/kept")" "and the file it names keeps what it said"
printf 'keep\n' > "$ld/hard"; ln "$ld/hard" "$ld/hard.lock"
FM_GATE_LOCK="$ld/hard.lock" "$GATE" --task T-X --repo "$sl" --branch slow --only 1 >/dev/null 2>&1; rc=$?
assert_eq "70" "$rc" "a lock that is a hard link to another file is refused"
assert_eq "keep" "$(cat "$ld/hard")" "and that file keeps what it said"
mkfifo "$ld/fifo.lock"
assert_ok "finishes 20 \"FM_GATE_LOCK='$ld/fifo.lock' '$GATE' --task T-X --repo '$sl' --branch slow --only 1; test \\\$? = 70\"" \
  "a lock that is not a regular file is refused, and does not hang the run"

# A run inside a run that holds the same lock would wait for ever, and one
# that skipped the lock would not be serialized: it is refused, and says so.
# A suite that runs the gate takes a lock of its own (see below).
lock="$(mktemp -d)/gate.lock"
out="$(FM_GATE_LOCK="$lock" FM_GATE_LOCK_HELD="$lock" "$GATE" --task T-X --repo "$sl" --branch slow --only 1 2>&1)"; rc=$?
assert_eq "70" "$rc" "a run nested in a run that holds its lock is refused, not run unlocked"
assert_contains "$out" "inside a gate run that holds $lock" "and says why"

# The default lock is one path for the machine. TMPDIR is per user on macOS
# and per sandbox, so a default under it would give two callers two locks.
# Shown by the lock each names when refused, so the suite never takes the
# machine's real lock or waits on a real gate run.
for tmp in "$(mktemp -d)" "$(mktemp -d)"; do
  out="$(env -u FM_GATE_LOCK TMPDIR="$tmp" FM_GATE_LOCK_HELD=/tmp/fm-gate.lock \
    "$GATE" --task T-X --repo "$sl" --branch slow --only 1 2>&1)"; rc=$?
  assert_eq "70" "$rc" "with TMPDIR=$tmp and no FM_GATE_LOCK, the run takes the machine's one lock"
  assert_contains "$out" "holds /tmp/fm-gate.lock;" "and it is /tmp/fm-gate.lock, whatever TMPDIR is"
done

# Every suite that runs the real gate - itself, or through a copied fm-autopilot.sh
# or a copy of every bin/fm-*.sh - sets a lock of its own. On the machine's
# lock it would wait on real gate runs and hold them up, and inside one it is
# refused. A line that only reads the script (sed, grep, cat) does not run it.
# Every source read here and below goes through code(), so a comment that says
# what an assertion looks for can neither satisfy it nor put a suite in a list.
# Shell and Python are read by their own parsers (tests/lib/source_scan.py,
# T-279); a file they refuse is recorded, never read as text instead.
code() {  # code <file> ; else its lines with shell, // and one-line HTML comments emptied
  case "$1" in
    *.sh|*.py) python3 "$ROOT/tests/lib/source_scan.py" code --bash "$BASH" "$1" 2>> "$cmt.refused" ;;
    *) sed -E -e 's@^[[:space:]]*(#|//).*$@@' -e 's@[[:space:]](#|//)[[:space:]].*$@@' -e 's@<!--.*-->@@g' "$1" ;;
  esac
}
cmt="$(mktemp)"; : > "$cmt.refused"
printf '# FM_GATE_LOCK=x\n  // GATE_NUMBERS=[1];\nrun ok # FM_GATE_LOCK=y\n<!-- gates[n-1] -->\nkept\n' > "$cmt"
assert_eq "run ok kept" "$(code "$cmt" | tr -s '\n' ' ' | sed 's/^ //; s/ $//')" \
  "a comment line, a trailing comment and an HTML comment are not code"
# The raw text first: code is a subset of it, and most suites never name the gate.
reaching="$(cd "$ROOT" && for f in tests/*.sh; do grep -E 'ROOT"?/bin/fm-(gate|run|\*)\.sh' "$f" >/dev/null &&
  code "$f" | grep -E 'ROOT"?/bin/fm-(gate|run|\*)\.sh' >/dev/null && printf '%s\n' "$f"; done)"
assert_contains " $(tr '\n' ' ' <<<"$reaching")" " tests/e2e-loop.test.sh " "the sweep finds a suite that runs the gate through a copy"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  runs="$(code "$ROOT/$f" | grep -E 'ROOT"?/bin/fm-(gate|run|\*)\.sh' | grep -vE '(sed|grep|cat|awk) [^|]*ROOT"?/bin/fm-')"
  [ -n "$runs" ] || continue
  assert_contains "$(code "$ROOT/$f")" "FM_GATE_LOCK=" "$f runs the real gate, and sets its own FM_GATE_LOCK"
done <<<"$reaching"
assert_eq "" "$(cat "$cmt.refused")" "the gate sweep parses every shell file it reads"

# --- canonical list agreement, labels and stale prose (T-232) -----------
nums="$(sed -n 's/^g \([0-9]*\) .*/\1/p' "$GATE" | paste -sd ' ' -)"
assert_eq '1 2 3 4 5 6' "$nums" 'six contiguous gates'
assert_eq "$nums" "$(jq -r '.gates[].n' "$ROOT/bin/lib/fm_gates.json" | paste -sd ' ' -)" 'runner agrees with canonical list'
assert_contains "$(code "$ROOT/board/server.ts")" 'bin/lib/fm_gates.json' 'board loads canonical list'
assert_contains "$(code "$ROOT/board/public/index.html")" 'latest?.gates' 'page reads state gate list'
for dict in "$ROOT"/i18n/ui.*.json; do
  for name in $(jq -r '.gates[].name' "$ROOT/bin/lib/fm_gates.json"); do
    assert_ok "jq -e 'has(\"gate_$name\")' '$dict' >/dev/null" "$dict labels $name"
  done
  assert_eq false "$(jq 'has("gate3")' "$dict")" 'retired key removed'
done
count='seven[^.]{0,40}(gate|green)|(gate|green)[^.]{0,40}seven|(^|[^0-9])7 gates|(^|[^0-9A-Za-z])gate 7([^0-9]|$)|gate exits? 7([^0-9]|$)|gate 3 (runs|is) the (whole|project|local) check'
allowed='^tests/lib/worker(-rebuild)?\.sh:[0-9]+:.*seven of them'
sweep_gates() {
  (cd "$1" && git grep -niE "$count" -- . ':!design/tasks/' ':!design/proposals/' ':!design/T-165-validation.md' ':!design/t130-pr-body.md' ':!tests/gate.test.sh' ':!games/voyage-2d/' | grep -vE "$allowed")
}
sweep_root="$(mktemp -d)"
git -C "$sweep_root" init -q
mkdir -p "$sweep_root/games/voyage-2d" "$sweep_root/skills/example"
printf '%s\n' 'The seven gates' > "$sweep_root/games/voyage-2d/README.md"
for phrase in 'seven green means a decision' 'The seven gates' 'all 7 gates' 'gate 7 sends it' 'Gate 3 runs the local check' 'Gate exit 7 launches review'; do
  printf '%s\n' "$phrase" > "$sweep_root/skills/example/SKILL.md"
  git -C "$sweep_root" add .
  found="$(sweep_gates "$sweep_root")"
  assert_contains "$found" 'skills/example/SKILL.md:1:' "same git grep catches: $phrase"
  assert_lacks "$found" 'games/voyage-2d/' 'vendor exclusion leaves engine prose covered'
done
printf '%s\n' 'gates 1-6 are green' 'gate 3 checks the scope' > "$sweep_root/skills/example/SKILL.md"
assert_eq '' "$(sweep_gates "$sweep_root")" 'new numbering is allowed'
assert_eq '' "$(sweep_gates "$ROOT")" 'no obsolete live gate numbers'

# Merge cards use name keys, or explicitly marked legacy fixture data.
board="$(code "$ROOT/board/public/index.html")"
assert_contains "$board" 'gates[name]' 'new cards read by name'
assert_contains "$board" 'latest.gateLegacy' 'old cards read through canonical legacy map'
assert_lacks "$board" 'gates[i]' 'never index by display position'
assert_contains "$(code "$ROOT/bin/fm-decide.sh")" 'map({key:.name,value:true})|from_entries' 'producer uses exactly the canonical names'
arrays="$(cd "$ROOT" && git grep -nE 'gates: *\[[0-9,truefalsnul ]+\]' -- bin/ board/ tests/e2e/ | grep -v 'legacy-gates (T-232)' || true)"
assert_eq '' "$arrays" 'only explicitly marked legacy card keeps an array'
assert_contains "$(cat "$ROOT/tests/e2e/board-decisions.spec.ts")" 'toHaveCount(6)' 'six gate lines in browser'

# --- the exit code names the gate ---------------------------------------
"$GATE" --task T-X --repo "$d" --branch untested --only 4 >/dev/null 2>&1
assert_eq "4" "$?" "the exit code is the number of the gate that failed"
finish
