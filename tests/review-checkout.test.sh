#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/review.sh
. "$ROOT/tests/lib/review.sh"
# shellcheck source=tests/lib/review-run.sh
. "$ROOT/tests/lib/review-run.sh"
# A decoy left in the real TMPDIR, owned by a genuinely live process that
# holds a kernel flock on its owner file (T-123 round 13) - the same shape
# checkout_is_free treats as in use, not the dead-pid shape a stale sweep
# would remove regardless of isolation. It must survive the whole suite
# untouched, since every fm-review.sh call below runs under the isolated
# TMPDIR above and never globs the real one at all (T-123).
decoy_root="$(mktemp -d "$real_tmp/fm-review.XXXXXX")"
printf '1\n' > "$decoy_root/owner"
decoy_lockmark="$real_tmp/fm-review-decoy-lock.$$"
perl -MFcntl=:flock -e '
  open(my $l, "+<", $ARGV[0]) or exit 2;
  flock($l, LOCK_EX) or exit 1;
  open(my $m, ">", $ARGV[1]) or exit 1; print $m "locked\n"; close $m;
  sleep 3600;
' "$decoy_root/owner" "$decoy_lockmark" &
decoy_holder=$!
eventually test -e "$decoy_lockmark"

dm="$(run_fixture)"; rm_="$dm/repo"; GHm="$(ghstub "$dm")"
runner_adapter "$rm_"
printf 'vendor: mock\nreviewer:\n  vendor: runner\n  mode: run\n' > "$rm_/config.yaml"
# T-153: a run-mode reviewer no longer judges the head by running it; the
# machine ran the tests, and the round is shown what it found exactly as a
# diff round is. Green CI and the gates are still firstmate's merge gate, not
# a review criterion (captain, 2026-09-25). This gh answers the way gh does -
# `pr checks` prints its list and exits 8 for a pending check, `api` returns
# the head's check runs.
ghci() {   # ghci <dir> <head oid>
  mkdir -p "$1/stub"
  cat > "$1/stub/gh" <<M
#!/usr/bin/env bash
echo "gh \$*" >> "$1/ghcalls"
case "\$1 \$2" in
  "pr view") printf '{"comments":[],"headRefOid":"%s","state":"OPEN"}\n' "$2" ;;
  "pr checks") case " \$* " in *" --jq "*) printf 'ci\n' ;;
      *) printf '[{"bucket":"pass","name":"ci","state":"SUCCESS","workflow":"CI_WORKFLOW"}]\n' ;; esac
    exit 8 ;;
  "api "*) printf '{"check_runs":[{"id":1,"name":"ci","head_sha":"%s","status":"completed","conclusion":"success","details_url":"https://x/CI_RUN"}]}\n' "$2" ;;
  "pr comment") ;;
esac
exit 0
M
  chmod +x "$1/stub/gh"; printf '%s' "$1/stub/gh"
}
headM="$(git -C "$rm_" rev-parse work)"
GHj="$(ghci "$dm" "$headM")"; : > "$dm/ghcalls"
outM="$(cd "$rm_" && FM_ROOT="$rm_" FM_GH="$GHj" FM_SEEN="$dm" \
  bin/fm-review.sh --task T-Z --branch work --round 3 --pr 9 2>&1)"
assert_eq "0" "$?" "a run-mode round exits 0"
ck="$(seen_of checkout "$dm")"
assert_eq "1" "$(seen_of mode "$dm")" "the adapter is told the round is a run-mode one"
assert_matches "$ck" '^/.+/checkout$' "and is handed the checkout, as an absolute path"
rp="$(cd "$rm_" && pwd -P)"
case "$ck/" in "$rm_"/*|"$rp"/*) inside=1 ;; *) inside=0 ;; esac
assert_eq "0" "$inside" "the checkout is outside the repository and every worktree in it"
assert_eq "$(git -C "$rm_" rev-parse work)" "$(seen_of head "$dm")" "the checkout is the head under review"
assert_eq "SECRET_WORKER_REASONING" "$(seen_of a "$dm")" "with the head's files checked out"
assert_eq "$(git -C "$rm_" rev-parse main)" "$(seen_of base "$dm")" "and the base under fm/base, as the comparison base"
assert_eq "" "$(seen_of remotes "$dm")" "and no remote to push to"
assert_fail "test -e '$ck'" "the round removes the checkout when it ends"
assert_fail "test -e '$(dirname "$ck")'" "and the directory made for it"
assert_contains "$(cat "$dm/ghcalls")" "pr comment" "fm-review.sh itself posts the run-mode verdict"
assert_contains "$outM" "APPROVE:T-Z" "and the verdict comes back"
sentM="$(cat "$dm/prompt.md")"
assert_contains "$sentM" "# Run mode" "the run-mode prompt says what the round is"
assert_contains "$sentM" "$ck" "and names the checkout"
assert_contains "$sentM" "make check-it" "and carries the contract the branch under review declares"
# T-153: the machine runs the tests, fail-first included; the reviewer reads
# what it found and proves nothing by hand
assert_contains "$sentM" "1. Read what CI found on this head, in the head section: each job's
   result, the failing assertions with their log lines, and the fail-first
   report." "the first step reads CI's results and the fail-first report"
# SK-007: the full check is the required GitHub check on the same head, not
# the reviewer's; the step text says so, apart from the skill it quotes
assert_contains "$sentM" "Do not run the full \`check\`: it is the required GitHub check on
   this same head" "the run-mode steps tell the reviewer not to run the full check"
assert_contains "$sentM" "Run no suite
   that starts rounds, a board or a browser" "nor any suite that starts rounds, a board or a browser"
assert_contains "$sentM" "challenge a test the change
   relies on that it lists only as a guard" "and to challenge a test fail-first found only green-guarded"
assert_contains "$sentM" "**Executed**" "and asks which evidence was executed"
assert_contains "$sentM" "**Read, not run**" "and which was only read"
assert_contains "$sentM" "SECRET_WORKER_REASONING" "and still carries the diff"
assert_contains "$sentM" "Find the reason to reject" "and the reviewer skill"
assert_fail "grep -q 'state/worktrees' '$dm/prompt.md'" "the run-mode prompt names no worktree path"
evM="$rm_/state/events.jsonl"
assert_eq "review_opened approved agent_finished" \
  "$(jq -r 'select(.type=="review_opened" or .type=="approved" or .type=="review_failed" or .type=="agent_finished")|.type' "$evM" | tr '\n' ' ' | sed 's/ $//')" \
  "a run-mode round opens the review and ends it with approved"
assert_eq "reviewer|T-Z" "$(jq -r 'select(.type=="review_opened")|[.data.role,.task]|join("|")' "$evM")" \
  "review_opened carries the reviewer role and the task"
assert_eq "reviewer|T-Z" "$(jq -r 'select(.type=="approved")|[.data.role,.task]|join("|")' "$evM")" \
  "approved carries the reviewer role and the task"
assert_eq "Review the authored task" "$(jq -r 'select(.type=="approved")|.data.activity.en' "$evM")" \
  "with the authored activity line"
assert_contains "$(jq -r 'select(.type=="crew_status")|.data.activity.en' "$evM")" "fresh checkout" \
  "and the board is told the checkout is being made"

assert_eq "" "$(seen_of network "$dm")" "a project that declares no reviewer network gives the sandbox none"
assert_contains "$sentM" "network only for these
hosts: none" "and the prompt says so"
assert_lacks "$sentM" "read-only gh" "the prompt offers no gh, which the sandbox cannot reach"

# The round has a writable HOME and temp directory. The adapter sets the
# tool caches within that round environment; adapter-contract.test.sh checks
# each cache path against the profile. fm-review.sh hands the round none
# of its own, since a directory
# beside the checkout is none of the round's write roots (T-117)
ckroot="$(dirname "$ck")"
for cache in xdg bun pw npm; do
  cv="$(seen_of "$cache" "$dm")"
  case "$cv" in "$ckroot"/*) beside=1 ;; *) beside=0 ;; esac
  assert_eq "0" "$beside" "fm-review.sh points no $cache cache beside the checkout, outside the round's write roots ($cv)"
done
assert_contains "$sentM" "this round's own temp directory (\$TMPDIR)" "and the prompt says where the caches are"

sentG="$(cat "$dm/prompt.md")"
callsG="$(cat "$dm/ghcalls")"
assert_contains "$callsG" "pr checks" "a run-mode round reads the head's checks from GitHub (T-153)"
assert_contains "$callsG" "gh api" "and their runs"
assert_contains "$callsG" "gh pr view 9 --json comments" "while the closed-list protocol still reads the comments"
assert_contains "$callsG" "gh pr comment 9" "and fm-review.sh still posts the verdict"
assert_ok "grep -qx '# The head under review' '$dm/prompt.md'" "the run-mode prompt carries the head-under-review section"
assert_contains "$sentG" "Conclusion: success" "with the required check's conclusion"
assert_contains "$sentG" "CI_RUN" "and its run"
assert_contains "$sentG" "# The closed list" "the closed-list section is still there from round three"
assert_contains "$sentG" "firstmate's merge gate, not a criterion of this review" \
  "and the prompt says green CI and the gates are firstmate's merge gate"
# Diff-mode head/check evidence is covered by the closed-list fixture above.

# T-153: the reviewer starts once the head's required checks have finished,
# and is handed what CI found: every job's result, the failing assertions
# with their log lines from each failed job's log, and the fail-first report,
# the fail-first job's artifact. This gh answers the way GitHub does: the
# required check's runs per commit, every job's runs for the commit (an older
# run of a job and a run of another head among them), a failed job's log in
# `gh run view --log-failed`'s tab-separated shape, and the artifact.
# GH_PENDING_POLLS is how many times the required check is still running
# before it completes.
ghjobs() {   # ghjobs <dir> <head oid>
  mkdir -p "$1/stub"
  cat > "$1/stub/gh" <<M
#!/usr/bin/env bash
echo "gh \$*" >> "$1/ghcalls"
case "\$1 \$2" in
  "pr view") printf '{"comments":[]}\n' ;;
  "pr checks") printf 'ci\n'; [ -z "\${GH_EXTRA_CHECK:-}" ] || printf 'lint\n'; exit 1 ;;
  "api "*)
    case "\$2" in
      *check_name=ci)
        n="\$(cat "$1/polls" 2>/dev/null || echo 0)"; echo \$((n + 1)) > "$1/polls"
        if [ "\$n" -lt "\${GH_PENDING_POLLS:-0}" ]; then st=in_progress; c=null; else st=completed; c='"failure"'; fi
        printf '{"check_runs":[{"id":10,"name":"ci","head_sha":"%s","status":"%s","conclusion":%s,"details_url":"https://github.com/o/r/actions/runs/500/job/10"}]}\n' "$2" "\$st" "\$c" ;;
      *check_name=lint)
        [ -z "\${GH_LINT_MISSING:-}" ] || { printf '{"check_runs":[]}\n'; exit 0; }
        n="\$(cat "$1/polls" 2>/dev/null || echo 0)"
        if [ "\$n" -le 3 ]; then st=in_progress; else st=completed; fi
        printf '{"check_runs":[{"id":20,"name":"lint","head_sha":"%s","status":"%s"}]}\n' "$2" "\$st" ;;
      *per_page=100)
        [ -z "\${GH_JOBS_DOWN:-}" ] || exit 1
        ff='{"id":13,"name":"fail-first","head_sha":"$2","status":"completed","conclusion":"success","details_url":"https://github.com/o/r/actions/runs/500/job/13"},'
        [ -z "\${GH_NO_FAILFIRST:-}" ] || ff=''
        printf '{"check_runs":[%s
 {"id":11,"name":"bash suites (shard 1/4)","head_sha":"$2","status":"completed","conclusion":"failure","details_url":"https://github.com/o/r/actions/runs/500/job/11"},
 {"id":12,"name":"fast checks","head_sha":"$2","status":"completed","conclusion":"success","details_url":"https://github.com/o/r/actions/runs/500/job/12"},
 {"id":9,"name":"fast checks","head_sha":"$2","status":"completed","conclusion":"failure","details_url":"https://github.com/o/r/actions/runs/499/job/OLDER_RUN"},
 {"id":14,"name":"bun tests","head_sha":"0000000","status":"completed","conclusion":"failure","details_url":"https://github.com/o/r/actions/runs/1/job/OTHER_HEAD_RUN"}]}\n' "\$ff" ;;
      *) exit 1 ;;
    esac ;;
  "run view")
    [ "\$3 \$4 \$5" = "--job 11 --log-failed" ] || exit 1
    p='bash suites (shard 1/4)\tUNKNOWN STEP\t2026-09-29T14:33:08.2265145Z '
    printf "\$p%s\n" \
      '    a passing assertion                                 ok' \
      '    the board refuses an empty port                     FAIL' \
      '      expected [64] got [0]' \
      '  + tests/review.test.sh' \
      '  x tests/board.test.sh' \
      '##[error]Process completed with exit code 1.' ;;
  "run download")
    [ -z "\${GH_ARTIFACT_DOWN:-}" ] || exit 1
    [ "\$3 \$4 \$5" = "500 -n fail-first-report" ] || exit 1
    d=''; while [ \$# -gt 0 ]; do [ "\$1" = -D ] && d="\${2-}"; shift; done
    [ -n "\$d" ] && printf '## Fail-first: pass\n\nFF_REPORT_BODY\n' > "\$d/fail-first.md" ;;
  "pr comment") ;;
esac
exit 0
M
  chmod +x "$1/stub/gh"; printf '%s' "$1/stub/gh"
}
GHk="$(ghjobs "$dm" "$headM")"
# The CI fixture's clock advances only when gh serves another check state.
# Command startup time on macOS must not consume the wait bound, or turn
# an already-completed response into a claimed wait. All other date uses
# retain the host command (event timestamps and identity allocation).
jobs_real_date="$(command -v date)"
cat > "$dm/stub/date" <<'CLOCK'
#!/usr/bin/env bash
if [ "$*" = '+%s' ]; then
  n="$(cat "$FM_SEEN/polls" 2>/dev/null || echo 0)"
  [ "$n" -eq 0 ] || n=$((n - 1))
  echo "$((1800000000 + n))"
else
  exec "$JOBS_REAL_DATE" "$@"
fi
CLOCK
chmod +x "$dm/stub/date"
jobs_round() {   # jobs_round [env...]: a run-mode round against this gh; its prompt in $dm/prompt.md
  rm -f "$dm/polls" "$dm/prompt.md"; : > "$dm/ghcalls"
  ( cd "$rm_" && env PATH="$dm/stub:$PATH" JOBS_REAL_DATE="$jobs_real_date" FM_ROOT="$rm_" FM_GH="$GHk" FM_SEEN="$dm" "$@" \
    /bin/bash bin/fm-review.sh --task T-Z --branch work --pr 9 >"$dm/review.log" 2>&1 )
}
jobs_round
sentK="$(cat "$dm/prompt.md" 2>/dev/null)"
jobsK="$(awk '/^## Every CI job for this head/{f=1;next} /^## /{f=0} f' <<< "$sentK")"
assert_contains "$jobsK" "- bash suites (shard 1/4): failure (https://github.com/o/r/actions/runs/500/job/11)" \
  "the prompt lists every CI job of the head with its result and run"
assert_contains "$jobsK" "- fast checks: success" "the latest run of each job"
assert_lacks "$jobsK" "OLDER_RUN" "not an older run of it"
assert_lacks "$jobsK" "OTHER_HEAD_RUN" "nor a run of another head"
assert_contains "$jobsK" "- fail-first: success" "the fail-first job among them"
failK="$(awk '/^## Failing assertions, from the failed jobs/{f=1;next} /^## /{f=0} f' <<< "$sentK")"
assert_contains "$failK" "bash suites (shard 1/4), verbatim from its log" "the failed job's log is quoted"
assert_contains "$failK" "    the board refuses an empty port                     FAIL" "with its failing assertion"
assert_contains "$failK" "      expected [64] got [0]" "and the line that says how it failed"
assert_contains "$failK" "  x tests/board.test.sh" "and the red suite"
assert_lacks "$failK" "a passing assertion" "but not the assertions that passed"
assert_lacks "$failK" "tests/review.test.sh" "nor the suites that passed"
assert_lacks "$failK" "2026-09-29T14:33:08" "and without the runner's timestamps"
assert_contains "$(cat "$dm/ghcalls")" "gh run view --job 11 --log-failed" "read from the failed job's own log"
ffK="$(awk '/^## The fail-first report/{f=1;next} /^## The gates for this head/{f=0} f' <<< "$sentK")"
assert_contains "$ffK" "FF_REPORT_BODY" "the fail-first report is quoted"
assert_contains "$ffK" "----- begin fail-first report" "fenced"
assert_contains "$(cat "$dm/ghcalls")" "gh run download 500 -n fail-first-report" "from the fail-first job's own run"
assert_lacks "$sentK" "This round waited" "a head whose checks had finished is not waited on"

jobs_round GH_NO_FAILFIRST=1
assert_contains "$(cat "$dm/prompt.md" 2>/dev/null)" "No fail-first job has run for head $headM" \
  "a head with no fail-first job says so"
jobs_round GH_ARTIFACT_DOWN=1
assert_contains "$(cat "$dm/prompt.md" 2>/dev/null)" "The fail-first job ran for head $headM (success), but its report could not be read" \
  "a report that cannot be downloaded is stated, with the job's result"
jobs_round GH_JOBS_DOWN=1
assert_contains "$(cat "$dm/prompt.md" 2>/dev/null)" "The CI jobs of head $headM could not be read from GitHub" \
  "CI jobs that cannot be read are stated"
# and the two sections that depend on them still stand, saying plainly that
# nothing was fetched - never absent, which would read as nothing failed
sentJ="$(cat "$dm/prompt.md" 2>/dev/null)"
failJ="$(awk '/^## Failing assertions, from the failed jobs/{f=1;next} /^## /{f=0} f' <<< "$sentJ")"
assert_contains "$failJ" "Not available: the CI jobs of head $headM could not be read, so which assertions failed is unknown." \
  "with no CI data the failing-assertions section says it is not available"
assert_lacks "$sentJ" "No CI job failed" "and never claims that nothing failed"
ffJ="$(awk '/^## The fail-first report/{f=1;next} /^## The gates for this head/{f=0} f' <<< "$sentJ")"
assert_contains "$ffJ" "Not available: the CI jobs of head $headM could not be read, so no fail-first report was fetched." \
  "and the fail-first section says so too"

# the wait: the required check runs for two more polls, then completes; the
# round starts only then, with its result, and says it waited
before_wait_events="$(wc -l < "$rm_/state/events.jsonl" | tr -d ' ')"
jobs_round GH_PENDING_POLLS=2 GH_EXTRA_CHECK=1 FM_REVIEW_CI_WAIT=60 FM_REVIEW_CI_POLL=1
sentW="$(cat "$dm/prompt.md" 2>/dev/null)"
assert_ok "[ \"\$(cat '$dm/polls' 2>/dev/null || echo 0)\" -ge 3 ]" "a round asks again while the required check is still running"
assert_contains "$sentW" "waited" "and says it waited for the required checks"
assert_contains "$sentW" "Conclusion: failure" "and is handed the finished check's result"
assert_lacks "$sentW" "required checks still running" "with nothing still running"
evK="$rm_/state/events.jsonl"
assert_contains "$(jq -r 'select(.type=="crew_status")|.data.activity.en' "$evK")" "Waiting for CI on T-Z" \
  "the board is told the round is waiting for CI"
assert_contains "$(jq -r 'select(.type=="crew_status")|.data.activity["zh-TW"]' "$evK")" "等待 T-Z 的 CI" "in Chinese too"
assert_ok "[ \"\$(jq -s '[.[]|select(.type==\"approved\")]|last|.data.wall_clock.ci_wait' '$evK')\" -ge 2 ]" \
  "and the round's wall-clock records how long it waited"
# T-159: unchanged polls emit only once, with a machine-readable phase.
wait_eventsK="$(tail -n +$((before_wait_events + 1)) "$evK")"
waitK="$(jq -s '[.[]|select(.type=="crew_status" and .data.phase=="waiting_ci")]|last' <<<"$wait_eventsK")"
assert_eq 'lint' "$(jq -r '.data.ci_pending' <<<"$waitK")" "CI waiting state names the pending check"
assert_eq 'false' "$(jq -r '.data.window_expected' <<<"$waitK")" "CI wait expects no reviewer window"
assert_eq '2' "$(jq -s '[.[]|select(.type=="crew_status" and .data.phase=="waiting_ci")]|length' <<<"$wait_eventsK")" \
  "unchanged pending checks do not emit on every poll"
assert_eq 'review' "$(jq -sr '[.[]|select(.type=="crew_status" and .data.phase)]|last|.data.phase' <<<"$wait_eventsK")" \
  "after CI the reviewer returns to reviewing"
assert_eq '["ci, lint","lint"]' \
  "$(jq -sc '[.[]|select(.type=="crew_status" and .data.phase=="waiting_ci")|.data.ci_pending]' <<<"$wait_eventsK")" \
  "pending check changes refresh the waiting state without duplicate polls"
# a bounded wait: past it the round starts anyway, naming what still runs
before_bound_events="$(wc -l < "$evK" | tr -d ' ')"
jobs_round GH_PENDING_POLLS=1000 GH_EXTRA_CHECK=1 GH_LINT_MISSING=1 FM_REVIEW_CI_WAIT=2 FM_REVIEW_CI_POLL=1
assert_eq '0' "$?" "the bounded CI wait completes under /bin/bash"
assert_lacks "$(cat "$dm/review.log")" 'unbound variable' "the bounded wait has no variable expansion failure"
sentB="$(cat "$dm/prompt.md" 2>/dev/null)"
assert_contains "$sentB" "started with these required checks still running for this head, or not yet started: ci" \
  "past the bound the round starts, naming the checks still running"
assert_contains "$sentB" "Conclusion: none yet, status in_progress" "and shows them as not concluded"
# Three wait reads, then one fresh read while building the head evidence.
assert_eq '4' "$(cat "$dm/polls" 2>/dev/null)" "and it did not wait on past its bound"
assert_contains "$(jq -r 'select(.type=="crew_status" and .data.ci_wait_bound==true)|.data.activity.en' "$evK")" \
  'CI wait bound reached' "the board is told when the wait reaches its bound"
assert_contains "$(jq -r 'select(.type=="crew_status" and .data.ci_wait_bound==true)|.data.activity["zh-TW"]' "$evK")" \
  '仍待完成：ci, lint。即將開始審核。' "the wait bound reports pending names in Chinese under /bin/bash"
bound_eventsK="$(tail -n +$((before_bound_events + 1)) "$evK")"
assert_eq 'review' "$(jq -sr '[.[]|select(.type=="crew_status" and .data.phase)]|last|.data.phase' <<<"$bound_eventsK")" \
  "after the CI wait bound the reviewer returns to reviewing"
assert_eq 'true' "$(jq -s '
  to_entries
  | ([.[]|select(.value.type=="crew_status" and .value.data.ci_wait_bound==true)]|last|.key) as $bound
  | ([.[]|select(.value.type=="crew_status" and .value.data.phase)]|last) as $phase
  | $bound != null and $phase != null and $phase.value.data.phase == "review" and $phase.key > $bound
' <<<"$bound_eventsK")" "the final reviewing phase follows the CI wait bound event"
( cd "$rm_" && FM_ROOT="$rm_" FM_GH="$GHk" FM_SEEN="$dm" FM_REVIEW_CI_WAIT=soon \
  bin/fm-review.sh --task T-Z --branch work --pr 9 >/dev/null 2>&1 )
assert_eq "64" "$?" "a wait that is not whole seconds is refused"

assert_contains "$sentB" "No run of the required check lint was found for head $headM" \
  "past the same bound a required check with no run yet is stated as missing"
assert_contains "$sentB" "not yet started: ci, lint" \
  "the bound names both the running and the not-yet-created check"

# T-155: right after the worker's push GitHub has created no check on the
# pull request, and `gh pr checks --required` lists only checks that exist,
# so a round that took its names from it alone waited on nothing (T-145's
# first review, 2026-09-30). The names come from what the base requires. This
# gh answers the way GitHub does: the base's protection names `ci` (in
# .contexts and .checks[].context); `pr checks --required` with no check yet
# prints nothing and exits 1; the head's `ci` runs are none for
# GH_MISSING_POLLS asks, then queued for GH_QUEUED_POLLS, then completed.
# Each answer and the reviewer's start go to one log, in the order they
# happened, so "started only after completion" is read, not inferred.
ghreq() {   # ghreq <dir>
  mkdir -p "$1/stub"
  cat > "$1/stub/gh" <<'M'
#!/usr/bin/env bash
S="$FM_T155"
echo "gh $*" >> "$S/ghcalls"
case "$1 $2" in
  "pr view") printf '{"comments":[]}\n' ;;
  "pr checks")
    if [ -n "${GH_PR_CHECKS:-}" ]; then printf '%s\n' "$GH_PR_CHECKS"; exit 1; fi
    echo "no required checks reported on the 'work' branch" >&2; exit 1 ;;
  "api "*)
    case "$2" in
      */branches/main/protection/required_status_checks)
        if [ -n "${GH_PROTECTION_DOWN:-}" ]; then
          printf '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}\n'
          echo 'gh: Not Found (HTTP 404)' >&2; exit 1
        fi
        p='{"url":"https://api.github.com/repos/o/r/branches/main/protection/required_status_checks","strict":true,"contexts":["ci"],"checks":[{"context":"ci","app_id":15368}]}'
        printf '%s\n' "${GH_PROTECTION:-$p}" ;;
      */check-runs\?check_name=ci)
        n="$(cat "$S/polls" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$S/polls"
        m="${GH_MISSING_POLLS:-0}"; q=$((m + ${GH_QUEUED_POLLS:-0}))
        if [ "$n" -lt "$m" ]; then echo "SERVED missing" >> "$S/order"; printf '{"total_count":0,"check_runs":[]}\n'; exit 0; fi
        if [ "$n" -lt "$q" ]; then st=queued; c=null; else st=completed; c='"success"'; fi
        echo "SERVED $st" >> "$S/order"
        printf '{"total_count":1,"check_runs":[{"id":20,"name":"ci","head_sha":"%s","status":"%s","conclusion":%s,"details_url":"https://github.com/o/r/actions/runs/600/job/20"}]}\n' \
          "$(cat "$S/head")" "$st" "$c" ;;
      */check-runs\?per_page=100) printf '{"total_count":0,"check_runs":[]}\n' ;;
      *) exit 1 ;;
    esac ;;
esac
exit 0
M
  chmod +x "$1/stub/gh"; printf '%s' "$1/stub/gh"
}
dq="$(fixture)"; rq5="$dq/repo"; GHq5="$(ghreq "$dq")"
git -C "$rq5" rev-parse work > "$dq/head"
cat > "$rq5/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
echo "REVIEWER_STARTED" >> "$FM_T155/order"
cp "$2" "$FM_T155/prompt.md"
printf 'APPROVE:T-Z\n' > "$3/verdict.txt"
M
chmod +x "$rq5/bin/adapters/mock.sh"
req_round() {   # req_round [env...]: a diff round given --pr against this gh
  rm -f "$dq/polls" "$dq/order" "$dq/prompt.md"; : > "$dq/ghcalls"
  ( cd "$rq5" && env FM_ROOT="$rq5" FM_GH="$GHq5" FM_T155="$dq" "$@" \
    bin/fm-review.sh --task T-Z --branch work --pr 9 >/dev/null 2>&1 )
}
# the first line of the order log that is the reviewer starting, and the
# first that is a completed run: the reviewer must come after it
started_after_completed() {
  local s c
  s="$(grep -n -m1 '^REVIEWER_STARTED$' "$dq/order" 2>/dev/null | cut -d: -f1)"
  c="$(grep -n -m1 '^SERVED completed$' "$dq/order" 2>/dev/null | cut -d: -f1)"
  [ -n "$s" ] && [ -n "$c" ] && [ "$c" -lt "$s" ]
}

# protection names ci; no run exists yet, then it is queued, then completed
req_round GH_MISSING_POLLS=2 GH_QUEUED_POLLS=2 FM_REVIEW_CI_WAIT=60 FM_REVIEW_CI_POLL=1
sentQ="$(cat "$dq/prompt.md" 2>/dev/null)"
assert_contains "$(cat "$dq/ghcalls")" "gh api repos/{owner}/{repo}/branches/main/protection/required_status_checks" \
  "a round reads the required checks from the base branch's protection"
assert_ok "grep -qx 'SERVED missing' '$dq/order'" "the required check had no run for the head when the round began"
assert_ok "grep -qx 'SERVED queued' '$dq/order'" "and was then queued"
assert_ok "started_after_completed" "the reviewer starts only after the required check completed, not while it was missing or queued"
assert_ok "[ \"\$(cat '$dq/polls' 2>/dev/null || echo 0)\" -ge 5 ]" "having asked through every missing and queued answer"
assert_contains "$sentQ" "Required checks, from the protection of the base branch main: ci." "the prompt names the checks and where they came from"
assert_contains "$sentQ" "Conclusion: success" "and hands over the completed check's result"
assert_contains "$sentQ" "This round waited" "and says it waited"
assert_lacks "$sentQ" "could not be read" "and never says the required check could not be read"

# protection that names its check only in .checks[] is read too
req_round 'GH_PROTECTION={"strict":true,"contexts":[],"checks":[{"context":"ci","app_id":null}]}' \
  GH_MISSING_POLLS=0 FM_REVIEW_CI_WAIT=60 FM_REVIEW_CI_POLL=1
assert_ok "started_after_completed" "a check named only in the protection's .checks[] is waited on"
assert_contains "$(cat "$dq/prompt.md" 2>/dev/null)" "Required checks, from the protection of the base branch main: ci." \
  "and named from the protection"

# protection that cannot be read falls back to the pull request's required checks
req_round GH_PROTECTION_DOWN=1 GH_PR_CHECKS=ci GH_MISSING_POLLS=0 FM_REVIEW_CI_WAIT=60 FM_REVIEW_CI_POLL=1
assert_ok "started_after_completed" "unreadable protection falls back to gh pr checks --required, and waits on what it names"
assert_contains "$(cat "$dq/prompt.md" 2>/dev/null)" "Required checks, from the pull request's required checks: ci." \
  "and says where the names came from"

# and, when neither names one, to config.yaml's declared required check
cp "$rq5/config.yaml" "$dq/config.plain"
printf 'vendor: mock\ndefault_project: fx\nprojects:\n  fx:\n    repo: .\n    github: o/r\n    base: main\n    required_check: ci\n' > "$rq5/config.yaml"
req_round GH_PROTECTION_DOWN=1 GH_MISSING_POLLS=0 FM_REVIEW_CI_WAIT=60 FM_REVIEW_CI_POLL=1
assert_ok "started_after_completed" "with neither readable, config.yaml's required_check is waited on"
assert_contains "$(cat "$dq/prompt.md" 2>/dev/null)" "Required checks, from config.yaml's required_check: ci." \
  "and named as config.yaml's"

cp "$dq/config.plain" "$rq5/config.yaml"

# only when no source names any required check is the wait skipped, said plainly
before_no_checks_events="$(wc -l < "$rq5/state/events.jsonl" | tr -d ' ')"
req_round GH_PROTECTION_DOWN=1 GH_MISSING_POLLS=1000 FM_REVIEW_CI_WAIT=60 FM_REVIEW_CI_POLL=1
assert_ok "[ ! -e '$dq/polls' ]" "with no source naming a required check, no check's runs are waited on"
assert_contains "$(cat "$dq/prompt.md" 2>/dev/null)" "No source named any required check" \
  "and the prompt says plainly that no required check was named"
assert_contains "$(cat "$dq/prompt.md" 2>/dev/null)" "so this round did not wait for CI before it started" \
  "and that the round did not wait for CI"
# With no wait, review_opened establishes review; no CI phase overrides it.
no_checks_events="$(tail -n +$((before_no_checks_events + 1)) "$rq5/state/events.jsonl")"
assert_eq 'review' "$(jq -sr '[.[] |
  if .type=="review_opened" then "review"
  elif .type=="crew_status" and .data.phase then .data.phase
  else empty end]|last' <<<"$no_checks_events")" \
  "with no required checks the reviewer enters reviewing"
assert_eq '0' "$(jq -s '[.[]|select(.type=="crew_status" and .data.phase=="waiting_ci")]|length' <<<"$no_checks_events")" \
  "with no required checks the reviewer never enters CI waiting"
rm -rf "$dq"

# A round that was SIGKILLed ran no trap; the next run-mode round removes its
# checkout, and leaves alone one still in use or one not yet claimed. Never
# `kill -0` on the pid an owner file names to decide it (T-123): inside a
# sandboxed round `kill -0` and `ps` are both denied, so a live sibling's pid
# can fail a signal exactly as a dead one's would, and pid 1 - always alive,
# but never signallable by this non-root user - is a faithful, real instance
# of that same failure (`kill -0 1` here fails with EPERM, not ESRCH). Only a
# kernel flock on the owner file, held by a background process standing in
# for the round that made it, says a checkout is still in use.
tmpM="$dm/tmp"; mkdir -p "$tmpM/fm-review.stale/checkout" "$tmpM/fm-review.live" "$tmpM/fm-review.fresh"
( exit 0 ) & deadpid=$!; wait "$deadpid"
printf '%s\n' "$deadpid" > "$tmpM/fm-review.stale/owner"
printf '1\n' > "$tmpM/fm-review.live/owner"
livelock="$dm/live-locked"
perl -MFcntl=:flock -e '
  open(my $l, "+<", $ARGV[0]) or exit 2;
  flock($l, LOCK_EX) or exit 1;
  open(my $m, ">", $ARGV[1]) or exit 1; print $m "locked\n"; close $m;
  sleep 60;
' "$tmpM/fm-review.live/owner" "$livelock" &
liveholder=$!
eventually test -e "$livelock"
( cd "$rm_" && TMPDIR="$tmpM" FM_ROOT="$rm_" FM_GH="$GHm" FM_SEEN="$dm" \
  bin/fm-review.sh --task T-Z --branch work --round 3 >/dev/null 2>&1 )
assert_eq "0" "$?" "a run-mode round with a stale checkout around still runs"
assert_fail "test -e '$tmpM/fm-review.stale'" "and removes a checkout whose owner pid is gone and whose lock nothing holds"
assert_ok "test -d '$tmpM/fm-review.live'" \
  "but not one a live process still locks, whatever kill -0 on its recorded pid 1 says (EPERM here, not ESRCH)"
assert_ok "test -d '$tmpM/fm-review.fresh'" "nor one no round has claimed yet"
assert_eq "fm-review.fresh fm-review.live" "$(cd "$tmpM" && ls -d fm-review.* | tr '\n' ' ' | sed 's/ $//')" \
  "and its own checkout is gone when it ends"
kill "$liveholder" 2>/dev/null; wait "$liveholder" 2>/dev/null

# A suite invoked from inside another round's own TMPDIR - as running this
# suite from inside a live review round's bin/ci.sh would, before
# isolate_tmpdir existed - must not reach that outer round's checkout: its
# sweep only ever globs its own TMPDIR, never an ancestor's.
outerlock="$dm/outer-locked"
mkdir -p "$tmpM/fm-review.outer" "$tmpM/nested"
printf '1\n' > "$tmpM/fm-review.outer/owner"
perl -MFcntl=:flock -e '
  open(my $l, "+<", $ARGV[0]) or exit 2;
  flock($l, LOCK_EX) or exit 1;
  open(my $m, ">", $ARGV[1]) or exit 1; print $m "locked\n"; close $m;
  sleep 60;
' "$tmpM/fm-review.outer/owner" "$outerlock" &
outerholder=$!
eventually test -e "$outerlock"
( cd "$rm_" && TMPDIR="$tmpM/nested" FM_ROOT="$rm_" FM_GH="$GHm" FM_SEEN="$dm" \
  bin/fm-review.sh --task T-Z --branch work --round 3 >/dev/null 2>&1 )
assert_eq "0" "$?" "a round started inside another round's TMPDIR still runs"
assert_ok "test -d '$tmpM/fm-review.outer'" \
  "and never sweeps the outer round's checkout, which sits outside its own TMPDIR"
kill "$outerholder" 2>/dev/null; wait "$outerholder" 2>/dev/null

# the hosts a project's setup needs reach the adapter; a GitHub host never does
printf 'vendor: mock\nreviewer:\n  vendor: runner\n  mode: run\n  network: registry.npmjs.org cdn.playwright.dev\n' > "$rm_/config.yaml"
( cd "$rm_" && FM_ROOT="$rm_" FM_GH="$GHm" FM_SEEN="$dm" \
  bin/fm-review.sh --task T-Z --branch work --round 3 >/dev/null 2>&1 )
assert_eq "registry.npmjs.org cdn.playwright.dev" "$(seen_of network "$dm")" \
  "the adapter is handed the hosts config.yaml's reviewer network declares"
assert_contains "$(cat "$dm/prompt.md")" "registry.npmjs.org cdn.playwright.dev" "and the prompt names them"
# One entrypoint refusal; adapter-contract owns the host matrix.
gh_host=api.github.com
printf 'vendor: mock\nreviewer:\n  vendor: runner\n  mode: run\n  network: registry.npmjs.org %s\n' "$gh_host" > "$rm_/config.yaml"
: > "$dm/seen"
outN="$(cd "$rm_" && FM_ROOT="$rm_" FM_GH="$GHm" FM_SEEN="$dm" \
  bin/fm-review.sh --task T-Z --branch work --round 3 2>&1)"
assert_eq "65" "$?" "a reviewer network naming $gh_host is a configuration error"
assert_contains "$outN" "may not reach GitHub" "and says why"
assert_eq "" "$(seen_of mode "$dm")" "and no engine runs"
printf 'vendor: mock\nreviewer:\n  vendor: runner\n  mode: run\n' > "$rm_/config.yaml"

# a signed rejection in run mode ends the review lane the same way
: > "$dm/ghcalls"
( cd "$rm_" && FM_ROOT="$rm_" FM_GH="$GHm" FM_SEEN="$dm" FM_VERDICT="REJECT:T-Z" \
  bin/fm-review.sh --task T-Z --branch work --round 2 --pr 9 >/dev/null 2>&1 )
assert_eq "0" "$?" "a run-mode rejection is a completed round"
assert_eq "rejected|reviewer|T-Z" \
  "$(jq -r 'select(.type=="review_failed")|[.data.review_outcome,.data.role,.task]|join("|")' "$evM" | tail -1)" \
  "and emits review_failed, rejected, as the reviewer on the task"
assert_fail "test -e '$(seen_of checkout "$dm")'" "and removes its checkout too"

# a round that produced no verdict still removes its checkout
( cd "$rm_" && FM_ROOT="$rm_" FM_GH="$GHm" FM_SEEN="$dm" FM_RUNNER_SILENT=1 \
  bin/fm-review.sh --task T-Z --branch work --round 4 >/dev/null 2>&1 )
assert_eq "3" "$?" "an unsigned run-mode round is a failed round"
assert_eq "missing_review" \
  "$(jq -r 'select(.type=="review_failed")|.data.review_outcome' "$evM" | tail -1)" \
  "and says so on the board"
assert_ne "" "$(seen_of checkout "$dm")" "the unsigned round was handed a checkout"
assert_fail "test -e '$(seen_of checkout "$dm")'" "and the failed round removes it all the same"

# a head that is not there cannot be checked out; that is said, not reviewed
: > "$dm/seen"
( cd "$rm_" && FM_ROOT="$rm_" FM_GH="$GHm" FM_SEEN="$dm" \
  bin/fm-review.sh --task T-Z --branch no-such-branch >/dev/null 2>&1 )
assert_eq "70" "$?" "a run-mode round with no head to check out fails"
assert_eq "" "$(seen_of mode "$dm")" "and never reaches an engine"
assert_eq "infrastructure_error" \
  "$(jq -r 'select(.type=="review_failed")|.data.review_outcome' "$evM" | tail -1)" \
  "and ends its review as an infrastructure failure"

# the reviewer's own vendor cannot be confined: a configuration error, and
# no engine runs - least of all the unconfined one
plain_adapter "$rm_" plain
printf 'vendor: mock\nreviewer:\n  vendor: plain\n  mode: run\nfallback:\n  - runner\n' > "$rm_/config.yaml"
rm -f "$dm/plain-ran"; : > "$dm/seen"; mkdir -p "$dm/tmp65"
outP="$(cd "$rm_" && TMPDIR="$dm/tmp65" FM_ROOT="$rm_" FM_GH="$GHm" FM_SEEN="$dm" \
  bin/fm-review.sh --task T-Z --branch work --pr 9 2>&1)"
assert_eq "65" "$?" "a run-mode reviewer whose adapter cannot confine it is a configuration error"
assert_eq "" "$(find "$dm/tmp65" -mindepth 1 -maxdepth 1 -name 'fm-review.*')" \
  "and the checkout it made before refusing is removed"
assert_contains "$outP" "plain has no adapter that confines a run-mode review" "and says which vendor"
assert_fail "test -e '$dm/plain-ran'" "and the unconfined engine never ran"
assert_eq "" "$(seen_of mode "$dm")" "nor did a fallback stand in for the reviewer the config named"
assert_eq "infrastructure_error" \
  "$(jq -r 'select(.type=="review_failed")|.data.review_outcome' "$evM" | tail -1)" \
  "and the review ends as an infrastructure failure"
# the same refusal for an explicit override
( cd "$rm_" && FM_ROOT="$rm_" FM_GH="$GHm" FM_SEEN="$dm" \
  bin/fm-review.sh --task T-Z --branch work --vendor plain >/dev/null 2>&1 )
assert_eq "65" "$?" "an explicit --vendor that cannot be confined is refused in run mode"

# a fallback that cannot be confined is left out of the round's chain
stub_script "$rm_/bin/adapters/runner.sh" <<'M'
#!/usr/bin/env bash
# fm:review-run
[ "$1" = "run" ] || exit 64
exit 2
M
printf 'vendor: mock\nreviewer:\n  vendor: runner\n  mode: run\nfallback:\n  - plain\n' > "$rm_/config.yaml"
rm -f "$dm/plain-ran"
( cd "$rm_" && FM_ROOT="$rm_" FM_GH="$GHm" FM_SEEN="$dm" \
  bin/fm-review.sh --task T-Z --branch work --round 5 >/dev/null 2>&1 )
assert_eq "2" "$?" "with the confined reviewer down, a run-mode round is an outage"
assert_fail "test -e '$dm/plain-ran'" "not a round handed to an engine that cannot be confined"
restore_scripts

# --- a destroyed run-mode checkout is retried once (T-128) -------------------
# Review checkouts are disposable, unlike a worker's branch: there is
# nothing in one worth mirroring, only worth noticing and rebuilding, at the
# same path the prompt already named, so nothing else about the round has
# to change.
dRc="$(run_fixture)"; rc_="$dRc/repo"; GHrc="$(ghstub "$dRc")"
cat > "$rc_/bin/adapters/wrecker.sh" <<'M'
#!/usr/bin/env bash
# fm:review-run
[ "$1" = "run" ] || exit 64
ck="${FM_REVIEW_CHECKOUT:-}"
mark="$FM_SEEN/wrecker-tries"
tries=0
[ -s "$mark" ] && tries="$(cat "$mark")"
tries=$((tries + 1))
printf '%s' "$tries" > "$mark"
if [ "$tries" = 1 ]; then
  rm -rf "$ck"
  exit 0
fi
printf 'checkout=%s\n' "$ck" >> "$FM_SEEN/wrecker-seen"
printf 'head=%s\n' "$(git -C "$ck" rev-parse HEAD 2>/dev/null)" >> "$FM_SEEN/wrecker-seen"
printf 'APPROVE:T-Z\n' > "$3/v.txt"
exit 0
M
chmod +x "$rc_/bin/adapters/wrecker.sh"
printf 'vendor: mock\nreviewer:\n  vendor: wrecker\n  mode: run\n' > "$rc_/config.yaml"
rm -f "$dRc/wrecker-tries" "$dRc/wrecker-seen"
outRc="$(cd "$rc_" && FM_ROOT="$rc_" FM_GH="$GHrc" FM_SEEN="$dRc" \
  bin/fm-review.sh --task T-Z --branch work --pr 9 2>&1)"
assert_eq "0" "$?" "a round-mode reviewer whose checkout was destroyed still completes"
assert_eq "2" "$(cat "$dRc/wrecker-tries" 2>/dev/null)" "it retried the round exactly once"
assert_contains "$outRc" "APPROVE:T-Z" "and the retried round's verdict comes back"
assert_contains "$(cat "$dRc/wrecker-seen" 2>/dev/null)" "$(git -C "$rc_" rev-parse work)" \
  "the fresh checkout the retry got is the same head under review"
assert_contains "$outRc" "destroyed" "fm-review.sh reports the checkout destroyed, not silence"
evRc="$rc_/state/events.jsonl"
# bin/fm-emit.sh's TYPES enum has no type of its own for this; it rides
# worker_crashed, named by .data.event_kind (bin/fm-review.sh).
assert_eq "review_checkout_destroyed" \
  "$(jq -r 'select(.type=="worker_crashed" and .data.event_kind=="review_checkout_destroyed")|.data.event_kind' "$evRc" | tail -1)" \
  "and records it as an event"
restore_scripts

# a checkout destroyed on every attempt is not retried a second time: the
# round fails as any other unsigned run does, not silently or forever
dRc2="$(run_fixture)"; rc2_="$dRc2/repo"; GHrc2="$(ghstub "$dRc2")"
cat > "$rc2_/bin/adapters/wrecker.sh" <<'M'
#!/usr/bin/env bash
# fm:review-run
[ "$1" = "run" ] || exit 64
rm -rf "${FM_REVIEW_CHECKOUT:-}"
exit 0
M
chmod +x "$rc2_/bin/adapters/wrecker.sh"
printf 'vendor: mock\nreviewer:\n  vendor: wrecker\n  mode: run\n' > "$rc2_/config.yaml"
( cd "$rc2_" && FM_ROOT="$rc2_" FM_GH="$GHrc2" FM_SEEN="$dRc2" \
  bin/fm-review.sh --task T-Z --branch work --pr 9 >/dev/null 2>&1 )
assert_eq "3" "$?" "a checkout destroyed again on the retry ends the round, not another retry"
restore_scripts

# --- the round's permission policy (T-105), in either mode --------------------
# The reviewer's adapter is handed the policy config.yaml resolves for a
# reviewer, and a host the round's proxy refused is reported, never allowed.
# The runner stands in for the proxy by writing to the file it is handed.
stub_script "$rm_/bin/adapters/runner.sh" <<'M'
#!/usr/bin/env bash
# fm:review-run
[ "$1" = "run" ] || exit 64
cp "$FM_POLICY" "$FM_SEEN/policy.json"
printf 'mode=%s\nnetwork=%s\nhatch=%s\n' "${FM_RUN_REVIEW:-}" "${FM_REVIEW_NETWORK:-}" "${FM_ROUND_UNSANDBOXED:-}" \
  > "$FM_SEEN/seen"
printf 'pypi.evil.example\n' >> "$FM_POLICY_BLOCKED"
printf 'APPROVE:T-Z\n' > "$3/v.txt"
M
for mode in diff run; do
  printf 'vendor: mock\nreviewer:\n  vendor: runner\n  mode: %s\npolicy:\n  reviewer:\n    network: registry.npmjs.org\n' \
    "$mode" > "$rm_/config.yaml"
  rm -f "$dm/policy.json"
  outR="$(cd "$rm_" && FM_ROOT="$rm_" FM_GH="$GHm" FM_SEEN="$dm" \
    bin/fm-review.sh --task T-Z --branch work --round 3 2>&1)"
  assert_eq "0" "$?" "a $mode-mode round runs under the reviewer's policy"
  assert_eq "reviewer" "$(jq -r .role "$dm/policy.json" 2>/dev/null)" "its adapter is handed the reviewer's policy ($mode)"
  assert_eq '["registry.npmjs.org"]' "$(jq -c .network "$dm/policy.json" 2>/dev/null)" \
    "with the registries the policy declares ($mode)"
  assert_contains "$outR" "refused undeclared hosts: pypi.evil.example" "a host its proxy refused is reported ($mode)"
  assert_eq "" "$(seen_of hatch "$dm")" "and the round runs under the OS sandbox ($mode)"
done
assert_eq "registry.npmjs.org" "$(seen_of network "$dm")" "a run-mode round's sandbox reaches the policy's registries"
assert_eq "reviewer pypi.evil.example" \
  "$(jq -r '"\(.role) \(.hosts | join(" "))"' "$rm_/state/policy/blocked-hosts.jsonl" 2>/dev/null | tail -1)" \
  "and the refused host is recorded for firstmate's choice card"
# the operator's escape hatch (T-117) reaches a review round the same way,
# and only from outside a crew round
rm -rf "$rm_/state/reviews"
outU="$(cd "$rm_" && FM_ROOT="$rm_" FM_GH="$GHm" FM_SEEN="$dm" FM_CREW_UNSANDBOXED=1 \
  bin/fm-review.sh --task T-Z --branch work --round 3 2>&1)"
assert_eq "0" "$?" "a review round under the operator's hatch runs"
assert_eq "1" "$(seen_of hatch "$dm")" "and its adapter is told to run without the OS sandbox"
assert_contains "$outU" "WITHOUT the OS sandbox" "which is said on stderr"
assert_contains "$(cat "$rm_"/state/reviews/T-Z-r3*.log 2>/dev/null)" \
  "fm-review: !!! FM_CREW_UNSANDBOXED=1: this round runs WITHOUT the OS sandbox !!!" "in the round's log"
assert_contains "$(jq -r 'select(.type=="crew_status") | .data.activity.en' "$rm_/state/events.jsonl" 2>/dev/null)" \
  "Reviewing T-Z WITHOUT the OS sandbox (FM_CREW_UNSANDBOXED)" "and on the board"
assert_contains "$(jq -r 'select(.type=="crew_status") | .data.activity["zh-TW"]' "$rm_/state/events.jsonl" 2>/dev/null)" \
  "正在審核 T-Z，未使用 OS 沙箱（FM_CREW_UNSANDBOXED）" "in both languages"
outU2="$(cd "$rm_" && FM_ROOT="$rm_" FM_GH="$GHm" FM_SEEN="$dm" FM_CREW_UNSANDBOXED=1 FM_IN_ROUND=1 \
  bin/fm-review.sh --task T-Z --branch work --round 3 2>&1)"
assert_eq "" "$(seen_of hatch "$dm")" "a review started inside a crew round cannot take it"
assert_contains "$outU2" "ignoring it" "and says so"
# Loopback refusal is covered by adapter-contract.test.sh.
restore_scripts
printf 'vendor: mock\nreviewer:\n  vendor: runner\n  mode: run\n' > "$rm_/config.yaml"

# a mode that is neither is a typo, not a quiet diff round
printf 'vendor: mock\nreviewer:\n  vendor: runner\n  mode: execute\n' > "$rm_/config.yaml"
outQ="$(cd "$rm_" && FM_ROOT="$rm_" FM_GH="$GHm" FM_SEEN="$dm" \
  bin/fm-review.sh --task T-Z --branch work 2>&1)"
assert_eq "65" "$?" "an unknown reviewer mode is a configuration error"
assert_contains "$outQ" "must be diff or run" "and says what it must be"
rm -rf "$dm"

# T-123: the decoy planted in the real TMPDIR before isolate_tmpdir, above,
# outlives every run-mode fm-review.sh call this whole suite has made -
# proof that none of them ever swept the real TMPDIR at all
assert_ok "test -d '$decoy_root'" \
  "the suite's real-TMPDIR decoy checkout survives the whole run-mode suite untouched"
kill "$decoy_holder" 2>/dev/null; wait "$decoy_holder" 2>/dev/null
rm -rf "$decoy_root" "$decoy_lockmark"

finish
