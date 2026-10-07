#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/review.sh
. "$ROOT/tests/lib/review.sh"
# shellcheck source=tests/lib/review-run.sh
. "$ROOT/tests/lib/review-run.sh"
# --- diff mode is today's round, byte for byte ------------------------------
# The prompt is the skill, the task, the round, the head's evidence (T-088)
# and the diff, plus T-173’s complete input index - no checkout, no
# run-mode text - whether the project says `mode: diff` or nothing at all,
# and a run-mode setting in the caller's environment does not leak into it.
for declared in nothing diff; do
  dd="$(fixture)"; rd="$dd/repo"; GHd="$(ghstub "$dd")"
  cat > "$rd/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "$FM_SEEN/prompt.md"
printf '%s' "$FM_PINNED_DIR" > "$FM_SEEN/pinned-path"
printf 'mode=%s\ncheckout=%s\n' "${FM_RUN_REVIEW:-}" "${FM_REVIEW_CHECKOUT:-}" > "$FM_SEEN/seen"
printf 'APPROVE:T-Z\n' > "$3/v.txt"
M
  chmod +x "$rd/bin/adapters/mock.sh"
  [ "$declared" = diff ] && printf 'vendor: mock\nreviewer:\n  mode: diff\n' > "$rd/config.yaml"
  ( cd "$rd" && FM_ROOT="$rd" FM_GH="$GHd" FM_SEEN="$dd" \
    FM_RUN_REVIEW=1 FM_REVIEW_CHECKOUT="$dd" \
    bin/fm-review.sh --task T-Z --branch work --pr 9 >/dev/null 2>&1 )
  assert_eq "0" "$?" "a diff round ($declared declared) exits 0"
  ( cd "$rd" && {
      cat skills/reviewer/SKILL.md
      # T-173 deliberately inserts paths/hashes in place of inline design.
      # Derive these expected bytes independently; retain every other byte of
      # the old self diff prompt and the fixture's original missing design.
      # tests/lib/review_pinned_golden.py is the literal helper dependency.
      python3 "$ROOT/tests/lib/review_pinned_golden.py" "$(cat "$dd/pinned-path")" \
        "$(git show work:design/tasks/T-Z.json | jq .)" "$rd/config.yaml"
      printf '\n---\n\n# The task\n\n```json\n%s\n```\n' \
        "$(git show work:design/tasks/T-Z.json | jq .)"
      printf '\n# Round %s\n' 1
      # given --pr, today's round carries the head's evidence (T-088); this
      # gh answers nothing and state/gates/ is empty, so all of it is unknown
      hd="$(git rev-parse work)"
      printf '\n# The head under review\n'
      printf '\nHead SHA: %s\n' "$hd"
      printf '\n## The required check for this head, from GitHub\n'
      printf '\nThe required check for head %s could not be read from GitHub, so its CI result is unknown.\n' "$hd"
      # T-155 changed the CI-wait lines: the names come from the base's
      # protection, the pull request, then config.yaml; this gh and config
      # name none, so the prompt says the round did not wait for CI
      printf '\nNo source named any required check - not the protection of the base branch %s, not the pull request'"'"'s required checks, not config.yaml'"'"'s required_check - so this round did not wait for CI before it started.\n' main
      # T-153 added these three sections: every CI job, the failing
      # assertions and the fail-first report, each saying it is unknown here
      printf '\n## Every CI job for this head\n'
      printf '\nThe CI jobs of head %s could not be read from GitHub, so their results are unknown.\n' "$hd"
      printf "\n## Failing assertions, from the failed jobs' logs\n"
      printf '\nNot available: the CI jobs of head %s could not be read, so which assertions failed is unknown.\n' "$hd"
      printf '\n## The fail-first report\n'
      printf '\nNot available: the CI jobs of head %s could not be read, so no fail-first report was fetched.\n' "$hd"
      printf '\n## The gates for this head\n'
      printf '\nNo gate summary for head %s exists under state/gates/, so its gate results are unknown.\n' "$hd"
      printf '\n---\n\n# The diff under review\n\n```diff\n'
      git diff main...work
      printf '```\n'
    } ) > "$dd/golden.md"
  assert_eq "$(shasum < "$dd/golden.md")" "$(shasum < "$dd/prompt.md" 2>/dev/null)" \
    "a diff round's prompt ($declared declared) is byte for byte today's: the skill, the task, the round, the head's evidence and the diff"
  assert_eq "|" "$(seen_of mode "$dd")|$(seen_of checkout "$dd")" \
    "and its adapter is handed no checkout, whatever the caller exported"
  assert_eq "review_opened crew_status approved crew_status agent_finished" \
    "$(jq -r .type "$rd/state/events.jsonl" | tr '\n' ' ' | sed 's/ $//')" \
    "and its events are today's ($declared declared)"
  assert_eq "reviewer|T-Z reviewer|T-Z" \
    "$(jq -r 'select(.type=="review_opened" or .type=="approved")|[.data.role,.task]|join("|")' "$rd/state/events.jsonl" | tr '\n' ' ' | sed 's/ $//')" \
    "with the reviewer role and the task on the review's opening and ending"
  rm -rf "$dd"
done

# --- the verdict says what it reviewed (T-113) -----------------------------
# Gate 6 carries an approval across an update onto main only when the change
# is the one approved, so the posted verdict records it: the head, the
# merge-base, the patch-id and the changed files, on one line the script
# writes after the reviewer's own words.
dv="$(fixture)"; rv="$dv/repo"
# the branch work comes first: main moves on after work forked, so the
# merge-base is not main and the diff main...work is not main..work
git -C "$rv" checkout -q work
printf 'second\n' > "$rv/src/b"; git -C "$rv" add src/b; git -C "$rv" commit -qm "a second file"
git -C "$rv" checkout -q main
printf 'moved on\n' > "$rv/src/c"; git -C "$rv" add src/c; git -C "$rv" commit -qm "main moves"
# the adapter is written after every commit and checkout, as a working-tree
# change on main: a commit or a checkout after it would fold it into the
# change under review or put the stock one back
mkdir -p "$dv/stub"
cat > "$dv/stub/gh" <<S
#!/usr/bin/env bash
if [ "\$1 \$2" = "pr comment" ]; then
  while [ \$# -gt 0 ]; do [ "\$1" = --body ] && { printf '%s' "\$2" > "$dv/posted"; break; }; shift; done
fi
exit 0
S
chmod +x "$dv/stub/gh"
cat > "$rv/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "${FM_CAPTURE:-/dev/null}" 2>/dev/null
printf 'the change is sound\n%s\n' "${FM_VERDICT:-no verdict}" > "$3/verdict.txt"
exit 0
M
chmod +x "$rv/bin/adapters/mock.sh"
# every expected value comes from git's porcelain, and each is checked to be
# there before the line built from them is trusted
vhead="$(git -C "$rv" rev-parse work)"; vbase="$(git -C "$rv" merge-base main work)"
vpatch="$(git -C "$rv" diff main...work | git -C "$rv" patch-id --stable | cut -d' ' -f1)"
assert_matches "$vhead $vbase $vpatch" '^[0-9a-f]{40} [0-9a-f]{40} [0-9a-f]{40}$' \
  "(the expected head, merge-base and patch-id are all there)"
assert_ne "$(git -C "$rv" rev-parse main)" "$vbase" "(main has moved past the merge-base)"
vfiles='["src/a","src/b"]'
want="REVIEWED:T-Z verdict=APPROVE head=$vhead base=$vbase patch=$vpatch files=$vfiles"
out="$(cd "$rv" && FM_ROOT="$rv" FM_GH="$dv/stub/gh" FM_CAPTURE="$dv/sent.md" FM_VERDICT="APPROVE:T-Z" \
  bin/fm-review.sh --task T-Z --branch work --pr 9 2>&1)"
assert_eq "0" "$?" "(a round that records what it reviewed exits 0)"
posted="$(cat "$dv/posted" 2>/dev/null)"
assert_contains "$posted" "the change is sound" "(the posted verdict keeps the reviewer's own words)"
assert_eq "$want" "$(grep '^REVIEWED:T-Z ' <<<"$posted")" \
  "and carries one REVIEWED line: the verdict, head, merge-base, patch-id and changed files"
assert_eq "$want" "$(tail -1 <<<"$posted")" "which is the comment's last line"
assert_contains "$(sed '$d' <<<"$posted")" "APPROVE:T-Z" "after the reviewer's own verdict"
assert_contains "$out" "$want" "and the verdict printed carries the same line"
# the prompt's diff is the change the line names: merge-base to head, with
# none of what main did since
sent="$(cat "$dv/sent.md" 2>/dev/null)"
# (these hold on the base too: main...work is the same diff in this fixture)
assert_contains "$sent" "$(git -C "$rv" diff main...work)" "(the prompt's diff is the change from the merge-base)"
assert_contains "$sent" "+second" "(which carries the branch's second file)"
assert_lacks "$sent" "moved on" "(and none of main's later work)"
rm -f "$dv/posted"
out="$(cd "$rv" && FM_ROOT="$rv" FM_GH="$dv/stub/gh" FM_VERDICT="REJECT:T-Z" \
  bin/fm-review.sh --task T-Z --branch work --pr 9 2>&1)"
assert_eq "REVIEWED:T-Z verdict=REJECT head=$vhead base=$vbase patch=$vpatch files=$vfiles" \
  "$(tail -1 "$dv/posted" 2>/dev/null)" "a REJECT records what it rejected the same way"
# a rejection that mentions the approve marker on the way is still a
# rejection: the last marker on a line of its own decides, for the REVIEWED
# line and for the event alike
rm -f "$dv/posted"
approvals() { grep -cx approved <<<"$(jq -r .type < "$rv/state/events.jsonl" 2>/dev/null)"; }
rejections() { grep -cx review_failed <<<"$(jq -r .type < "$rv/state/events.jsonl" 2>/dev/null)"; }
na="$(approvals)"; nr="$(rejections)"
out="$(cd "$rv" && FM_ROOT="$rv" FM_GH="$dv/stub/gh" \
  FM_VERDICT="$(printf 'I cannot sign APPROVE:T-Z while item 1 stands\nREJECT:T-Z')" \
  bin/fm-review.sh --task T-Z --branch work --pr 9 2>&1)"
assert_eq "REVIEWED:T-Z verdict=REJECT head=$vhead base=$vbase patch=$vpatch files=$vfiles" \
  "$(tail -1 "$dv/posted" 2>/dev/null)" "a REJECT that mentions the approve marker earlier is recorded as REJECT"
assert_eq "$na" "$(approvals)" "and emits no approved"
assert_eq "$((nr + 1))" "$(rejections)" "but review_failed, as the REVIEWED line says"
rm -rf "$dv"

# T-165: stock assembly must refuse an unrepresentable diff before calling
# an adapter, even when that adapter would have returned APPROVE.
bounded="$(fixture)"; bounded_repo="$bounded/repo"
cat > "$bounded_repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
# fm:review-run
[ "$1" = "run" ] || exit 64
cp "$2" "$FM_CAPTURE"
printf '%s\n' "${FM_RUN_REVIEW:-}" > "$FM_CAPTURE.mode"
git -C "${FM_REVIEW_CHECKOUT:-.}" rev-parse HEAD > "$FM_CAPTURE.head"
printf 'APPROVE:T-Z\n' > "$3/verdict.txt"
M
chmod +x "$bounded_repo/bin/adapters/mock.sh"
python3 - "$bounded_repo/src/oversized" <<'PYBOUND'
import sys
from pathlib import Path
Path(sys.argv[1]).write_text('oversized diff line\n' * 145000)
PYBOUND
(cd "$bounded_repo" && git checkout -q work && git add src/oversized && git commit -qm oversized && git checkout -q main)
bounded_out="$(cd "$bounded_repo" && FM_ROOT="$bounded_repo" FM_CAPTURE="$bounded/called" \
  bin/fm-review.sh --task T-Z --branch work 2>&1)"; bounded_rc=$?
assert_eq "65" "$bounded_rc" "oversized stock diff context fails before vendor launch"
assert_fail "test -e '$bounded/called'" "an unrepresentable context spends no model call"
assert_contains "$bounded_out" "cannot represent" "context refusal names its actual cause"
printf 'reviewer:\n  mode: run\n' >> "$bounded_repo/config.yaml"
bounded_out="$(cd "$bounded_repo" && FM_ROOT="$bounded_repo" FM_CAPTURE="$bounded/called" \
  bin/fm-review.sh --task T-Z --branch work 2>&1)"; bounded_rc=$?
assert_eq "0" "$bounded_rc" "oversized stock run context reaches the adapter with pinned references"
assert_eq "1" "$(cat "$bounded/called.mode" 2>/dev/null)" "bounded context adapter receives run mode"
assert_eq "$(git -C "$bounded_repo" rev-parse work)" "$(cat "$bounded/called.head" 2>/dev/null)" \
  "bounded context adapter receives the actual pinned checkout"
bounded_bytes=9999999
if [ -f "$bounded/called" ]; then bounded_bytes="$(wc -c < "$bounded/called")"; fi
assert_ok "test -f '$bounded/called' && test $bounded_bytes -le 524288" \
  "stock composed run prompt stays within the byte cap"
assert_contains "$(cat "$bounded/called" 2>/dev/null)" "OMITTED entire inline patch" "stock run mode discloses missing inline coverage"
assert_contains "$(cat "$bounded/called" 2>/dev/null)" "$(git -C "$bounded_repo" rev-parse work)" "stock reference pins the reviewed head"
assert_contains "$(cat "$bounded/called" 2>/dev/null)" "$(git -C "$bounded_repo" merge-base main work)" "stock reference pins the merge base"
bounded_patch="$(git -C "$bounded_repo" diff-tree -r -p --no-renames main work | git patch-id --stable | cut -d' ' -f1)"
assert_contains "$(cat "$bounded/called" 2>/dev/null)" "$bounded_patch" "stock reference pins the stable patch identity"

finish
