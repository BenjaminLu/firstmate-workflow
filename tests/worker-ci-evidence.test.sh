#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# A log that cannot be fetched must SAY so. An empty block reads to the
# worker exactly like a green run - it cannot run gh, so that block is
# its only view of the runner - and a round was spent asking why the
# check was red when the block was simply blank.
d16="$(fixture)"; r16="$d16/repo"; GH16="$(ghstub "$d16")"
cat > "$r16/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "${FM_CAPTURE:-/dev/null}" 2>/dev/null
mkdir -p "$3/src"
if [ -f "$3/src/round-one" ]; then printf 'two\n' > "$3/src/round-two"
else printf 'one\n' > "$3/src/round-one"; fi
M
chmod +x "$r16/bin/adapters/mock.sh"
( cd "$r16" && FM_ROOT="$r16" FM_GH="$GH16" FM_CAPTURE=/dev/null \
    bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
# a red check whose log gh will not hand over
cat > "$d16/stub/gh" <<'G'
#!/usr/bin/env bash
case " $* " in
  *" pr list "*) echo 21; exit 0 ;;
  # the run id is NOT in gh's message: `404` in both would make
  # "names the run" pass off the echoed gh line alone
  *" pr checks "*) echo "https://example.invalid/actions/runs/51/job/1"; exit 0 ;;
  " run view 51 --log-failed ") echo "HTTP 404: Not Found" >&2; exit 1 ;;
  *" run view "*) echo "could not find any workflow run" >&2; exit 1 ;;
  *" pr view "*" comments "*) printf '## reviewer-1

something
' ;;
esac
exit 0
G
chmod +x "$d16/stub/gh"
check_strict_run_stub "$d16/stub/gh" 51
cap16="$d16/sent.md"
( cd "$r16" && FM_ROOT="$r16" FM_GH="$GH16" FM_CAPTURE="$cap16" \
    bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
sent16="$(cat "$cap16" 2>/dev/null)"
assert_contains "$sent16" "The required check is red" "the prompt still says the check is red"
# the whole phrase, so a mis-parsed run id fails it: `run 51/job/1`
# would satisfy a bare "51" and so would gh's own message
assert_contains "$sent16" "The log for run 51 could not be fetched" \
  "and says the log could not be fetched, naming the run it asked for"
assert_contains "$sent16" "gh: HTTP 404" "and passing on what gh said about it"
rm -rf "$d16"

# and a required check that is not an Actions run at all - Buildkite,
# CircleCI - whose link has no /actions/runs/ in it. Reading the tail
# of that leaves the whole URL, which the run-id trim reduces to
# `https:`, and the worker is told "the log for run https: could not be
# fetched".
d17="$(fixture)"; r17="$d17/repo"; GH17="$(ghstub "$d17")"
cat > "$r17/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "${FM_CAPTURE:-/dev/null}" 2>/dev/null
mkdir -p "$3/src"
if [ -f "$3/src/round-one" ]; then printf 'two\n' > "$3/src/round-two"
else printf 'one\n' > "$3/src/round-one"; fi
M
chmod +x "$r17/bin/adapters/mock.sh"
( cd "$r17" && FM_ROOT="$r17" FM_GH="$GH17" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
cat > "$d17/stub/gh" <<'G'
#!/usr/bin/env bash
echo "gh $*" >> "$(dirname "$0")/../ghcalls"
case " $* " in
  *" pr list "*) echo 22; exit 0 ;;
  *" pr checks "*) echo "https://buildkite.com/acme/pipeline/builds/1234"; exit 0 ;;
  *" pr view "*" comments "*) printf '## reviewer-1\n\nsomething\n' ;;
esac
exit 0
G
chmod +x "$d17/stub/gh"; : > "$d17/ghcalls"
cap17="$d17/sent.md"
( cd "$r17" && FM_ROOT="$r17" FM_GH="$GH17" FM_CAPTURE="$cap17" \
    bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
sent17="$(cat "$cap17" 2>/dev/null)"
assert_contains "$sent17" "The required check is red" "the prompt still says the check is red"
assert_contains "$sent17" "No run id could be read out of" "and says what it could not do"
assert_contains "$sent17" "buildkite.com/acme/pipeline/builds/1234" "naming the check it means"
assert_lacks "$sent17" "run https:" "rather than asking for a run called https:"
assert_lacks "$sent17" "is not a GitHub Actions run" \
  "and does not claim to know which CI produced the link, which it cannot"
assert_lacks "$(cat "$d17/ghcalls")" "run view" "and it does not ask gh for a run that is not one"
rm -rf "$d17"

# The three ways the block can come out empty, each said differently,
# because to the worker they mean different things. A run id that is
# not a number; a fetch that failed; and a fetch that SUCCEEDED and
# had nothing, which "could not be fetched" would misreport as gh's
# fault in the one block the worker cannot check.
# <id> is the run or job ID the code must compute out of <link>:
# the stub answers that and refuses anything else, so a mis-parse is a
# failure here rather than a pass. A stub that answers `run view` for
# any argument cannot see the bug this task exists for.
redcheck() {   # redcheck <label> <check link> <id> <run view body> <want> [job]
  # Optional seventh/eighth arguments assert retained log and stderr content.
  local d r g cap sent
  d="$(fixture)"; r="$d/repo"; g="$(ghstub "$d")"
  cat > "$r/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "${FM_CAPTURE:-/dev/null}" 2>/dev/null
mkdir -p "$3/src"
if [ -f "$3/src/round-one" ]; then printf 'two\n' > "$3/src/round-two"
else printf 'one\n' > "$3/src/round-one"; fi
M
  chmod +x "$r/bin/adapters/mock.sh"
  ( cd "$r" && FM_ROOT="$r" FM_GH="$g" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
  { printf '#!/usr/bin/env bash\n'
    printf 'echo "gh $*" >> "$(dirname "$0")/../ghcalls"\n'
    printf 'case " $* " in\n'
    printf '  *" pr list "*) echo 23; exit 0 ;;\n'
    printf '  *" pr checks "*) echo "%s"; exit 0 ;;\n' "$2"
    # Exact arguments keep job IDs and workflow run IDs in separate namespaces.
    printf '  " run view %s%s --log-failed ") %s ;;\n' "${6:+--job }" "$3" "$4"
    printf '  *" run view "*) echo "could not find any workflow run" >&2; exit 1 ;;\n'
    printf '  *" pr view "*" comments "*) printf %s ;;\n' "'## r\n\nsomething\n'"
    printf 'esac\nexit 0\n'
  } > "$d/stub/gh"
  chmod +x "$d/stub/gh"
  cap="$d/sent.md"
  ( cd "$r" && FM_ROOT="$r" FM_GH="$g" FM_CAPTURE="$cap" \
      bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
  sent="$(cat "$cap" 2>/dev/null)"
  assert_contains "$sent" "The required check is red" "$1: the section is there"
  assert_contains "$sent" "$5" "$1"
  [ -z "${7:-}" ] || assert_contains "$sent" "$7" "$1: log content survives"
  [ -z "${8:-}" ] || assert_contains "$sent" "$8" "$1: fetch diagnostic survives"
  rm -rf "$d"
}
redcheck "a run id that is not a number says what the SCRIPT could not do" \
  "https://github.com/o/r/actions/runs/latest/job/1" "NONE" "exit 0" \
  "No run id could be read out of"
# Legacy details URLs identify jobs, not workflow runs. The stub refuses
# the same numeric ID when passed as a positional workflow run ID.
redcheck "an old-style /runs/<id> link selects a job" \
  "https://github.com/o/r/runs/6789123" "6789123" \
  "printf 'ci\tbin/ci.sh\tOLD STYLE LOG\n'; exit 0" \
  "OLD STYLE LOG" job
# and that link is served with a query on the job segment in the wild
redcheck "even with a query string after the id" \
  "https://github.com/o/r/runs/6789124?check_suite_focus=true" "6789124" \
  "printf 'ci\tbin/ci.sh\tQUERY STRING LOG\n'; exit 0" \
  "QUERY STRING LOG" job
redcheck "a legacy fragment also selects the job" \
  "https://github.com/o/r/runs/6789125#step:2:1" "6789125" \
  "printf 'ci\tx\tFRAGMENT LOG\n'; exit 0" \
  "FRAGMENT LOG" job
redcheck "modern links keep the workflow run namespace" \
  "https://github.com/o/r/actions/runs/72/job/6789125?check_suite_focus=true#step:2:1" "72" \
  "printf 'ci\tx\tWORKFLOW RUN LOG\n'; exit 0" \
  "WORKFLOW RUN LOG"
redcheck "a legacy job fetch failure names the job" \
  "https://github.com/o/r/runs/6789126" "6789126" "exit 1" \
  "The log for job 6789126 could not be fetched" job
redcheck "an empty legacy job log names the job" \
  "https://github.com/o/r/runs/6789127" "6789127" "exit 0" \
  "Job 6789127 reported no failing step log" job
redcheck "a partial legacy job log retains the failure context" \
  "https://github.com/o/r/runs/6789128" "6789128" \
  "printf 'ci\tx\tLEGACY PARTIAL LOG\nci\tx\t\nci\tx\tAFTER BLANK\n'; echo 'job log unavailable' >&2; exit 1" \
  "this log is incomplete: gh exited 1 while fetching job 6789128" job \
  $'LEGACY PARTIAL LOG\n\nAFTER BLANK' "gh: job log unavailable"
# but digits followed by more id are not an id
redcheck "while digits with letters after them fail closed" \
  "https://github.com/o/r/runs/12ab" "12ab" \
  "printf 'ci\tbin/ci.sh\tSHOULD NOT APPEAR\n'; exit 0" \
  "No run id could be read out of"
# Some of it came back and gh still failed - a multi-job run with one
# job's log gone. A partial log printed alone reads as the whole of
# the failure, which is the same lie as a blank block wearing a green
# run's face.
redcheck "a partial log says it is partial" \
  "https://github.com/o/r/actions/runs/64/job/1" "64" \
  "printf 'ci\tx\tHALF THE LOG\n'; echo 'one job log is gone' >&2; exit 1" \
  "this log is incomplete"
redcheck "and still shows what did come back" \
  "https://github.com/o/r/actions/runs/64/job/1" "64" \
  "printf 'ci\tx\tHALF THE LOG\n'; echo 'one job log is gone' >&2; exit 1" \
  "HALF THE LOG"
redcheck "and passes on why the rest did not" \
  "https://github.com/o/r/actions/runs/64/job/1" "64" \
  "printf 'ci\tx\tHALF THE LOG\n'; echo 'one job log is gone' >&2; exit 1" \
  "gh: one job log is gone"
redcheck "a fetch that failed says so" \
  "https://github.com/o/r/actions/runs/61/job/1" "61" "exit 1" \
  "The log for run 61 could not be fetched"
redcheck "a fetch that succeeded with nothing says THAT, not that gh failed" \
  "https://github.com/o/r/actions/runs/62/job/1" "62" "exit 0" \
  "Run 62 reported no failing step log"
redcheck "and a log the column trim empties is the same case" \
  "https://github.com/o/r/actions/runs/63/job/1" "63" \
  "printf 'ci\tbin/ci.sh\t\nci\tbin/ci.sh\t   \n'; exit 0" \
  "Run 63 reported no failing step log"

# A blank line inside a real log is part of the log. The emptiness
# filter is for DECIDING; printing it deleted every separator in a
# traceback, and spent the 120-line budget on lines it then dropped.
d18="$(fixture)"; r18="$d18/repo"; GH18="$(ghstub "$d18")"
cat > "$r18/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "${FM_CAPTURE:-/dev/null}" 2>/dev/null
mkdir -p "$3/src"
if [ -f "$3/src/round-one" ]; then printf 'two\n' > "$3/src/round-two"
else printf 'one\n' > "$3/src/round-one"; fi
M
chmod +x "$r18/bin/adapters/mock.sh"
( cd "$r18" && FM_ROOT="$r18" FM_GH="$GH18" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
cat > "$d18/stub/gh" <<'G'
#!/usr/bin/env bash
case " $* " in
  *" pr list "*) echo 24; exit 0 ;;
  *" pr checks "*) echo "https://github.com/o/r/actions/runs/71/job/1"; exit 0 ;;
  " run view 71 --log-failed ") printf 'ci\tx\tTraceback ABOVE\nci\tx\t\nci\tx\tAssertionError BELOW\n'; exit 0 ;;
  *" run view "*) echo "could not find any workflow run" >&2; exit 1 ;;
  *" pr view "*" comments "*) printf '## r\n\nsomething\n' ;;
esac
exit 0
G
chmod +x "$d18/stub/gh"
check_strict_run_stub "$d18/stub/gh" 71
cap18="$d18/sent.md"
( cd "$r18" && FM_ROOT="$r18" FM_GH="$GH18" FM_CAPTURE="$cap18" \
    bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
sent18="$(cat "$cap18" 2>/dev/null)"
assert_contains "$sent18" "Traceback ABOVE" "the line above a blank one reaches the prompt"
assert_contains "$sent18" "AssertionError BELOW" "and the line below it"
assert_contains "$sent18" "Traceback ABOVE

AssertionError BELOW" "with the blank line still between them"
rm -rf "$d18"

# The failed-fetch branch with no scratch file to capture gh into: the
# `:-/dev/null` fallback has to hold, the run still has to be told the
# log could not be fetched, and there must be no `gh:` lines claiming
# to quote something nothing captured.
d19="$(fixture)"; r19="$d19/repo"; GH19="$(ghstub "$d19")"
cat > "$r19/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "${FM_CAPTURE:-/dev/null}" 2>/dev/null
mkdir -p "$3/src"
if [ -f "$3/src/round-one" ]; then printf 'two\n' > "$3/src/round-two"
else printf 'one\n' > "$3/src/round-one"; fi
M
chmod +x "$r19/bin/adapters/mock.sh"
( cd "$r19" && FM_ROOT="$r19" FM_GH="$GH19" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
cat > "$d19/stub/gh" <<'G'
#!/usr/bin/env bash
case " $* " in
  *" pr list "*) echo 25; exit 0 ;;
  *" pr checks "*) echo "https://github.com/o/r/actions/runs/81/job/1"; exit 0 ;;
  " run view 81 --log-failed ") echo "boom" >&2; exit 1 ;;
  *" run view "*) echo "could not find any workflow run" >&2; exit 1 ;;
  *" pr view "*" comments "*) printf '## r\n\nsomething\n' ;;
esac
exit 0
G
chmod +x "$d19/stub/gh"
check_strict_run_stub "$d19/stub/gh" 81
# Fail only the optional log capture. `--pr 25` skips lookup_err, so
# the first worker allocation is log_err; chain_result must still succeed
# before the adapter can capture the prompt. Keep state outside the shim's
# process because scratch_new runs in command substitutions.
mkdir -p "$d19/tmp"
real_mktemp19="$(command -v mktemp)"
cat > "$d19/stub/mktemp" <<'M'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = "$TMPDIR/fm-worker-XXXXXX" ]; then
  if [ ! -e "$FM_MKTEMP_FAILED" ]; then
    : > "$FM_MKTEMP_FAILED"
    exit 1
  fi
fi
exec "$FM_REAL_MKTEMP" "$@"
M
chmod +x "$d19/stub/mktemp"
cap19="$d19/sent.md"
( cd "$r19" && PATH="$d19/stub:$PATH" TMPDIR="$d19/tmp" \
    FM_REAL_MKTEMP="$real_mktemp19" FM_MKTEMP_FAILED="$d19/mktemp-failed" \
    FM_ROOT="$r19" FM_GH="$GH19" FM_CAPTURE="$cap19" \
    bin/fm-worker.sh --task T-Z --pr 25 >/dev/null 2>&1 )
rc19=$?
assert_eq "0" "$rc19" "optional log allocation failure still completes the worker run"
assert_ok "test -f '$d19/mktemp-failed'" "the optional log allocation failure was exercised"
assert_ok "test -s '$cap19'" "the adapter ran and captured the prompt after allocation failure"
sent19="$(cat "$cap19" 2>/dev/null)"
assert_contains "$sent19" "The log for run 81 could not be fetched" \
  "with no scratch file, the failed fetch is still reported"
assert_lacks "$sent19" "gh: " "and nothing is quoted that nothing captured"
assert_lacks "$sent19" "No such file or directory" \
  "and the redirection did not fall over on an empty path"
rm -rf "$d19"

# gh's stderr is bounded like the log above it: everything that reaches
# that fence has to be, and a runner that dies noisily can say a great
# deal on stderr
d20="$(fixture)"; r20="$d20/repo"; GH20="$(ghstub "$d20")"
cp "$r19/bin/adapters/mock.sh" "$r20/bin/adapters/mock.sh" 2>/dev/null || true
cat > "$r20/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "${FM_CAPTURE:-/dev/null}" 2>/dev/null
mkdir -p "$3/src"
if [ -f "$3/src/round-one" ]; then printf 'two\n' > "$3/src/round-two"
else printf 'one\n' > "$3/src/round-one"; fi
M
chmod +x "$r20/bin/adapters/mock.sh"
( cd "$r20" && FM_ROOT="$r20" FM_GH="$GH20" bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
cat > "$d20/stub/gh" <<'G'
#!/usr/bin/env bash
case " $* " in
  *" pr list "*) echo 26; exit 0 ;;
  *" pr checks "*) echo "https://github.com/o/r/actions/runs/91/job/1"; exit 0 ;;
  " run view 91 --log-failed ") i=0; while [ "$i" -lt 200 ]; do echo "noise $i" >&2; i=$((i+1)); done; exit 1 ;;
  *" run view "*) echo "could not find any workflow run" >&2; exit 1 ;;
  *" pr view "*" comments "*) printf '## r\n\nsomething\n' ;;
esac
exit 0
G
chmod +x "$d20/stub/gh"
check_strict_run_stub "$d20/stub/gh" 91
cap20="$d20/sent.md"
( cd "$r20" && FM_ROOT="$r20" FM_GH="$GH20" FM_CAPTURE="$cap20" \
    bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
lines20="$(grep -c '^gh: noise' "$cap20" 2>/dev/null || true)"
assert_contains "$(cat "$cap20")" "gh: noise 0" "gh's first words reach the prompt"
assert_ok "[ '$lines20' -le 20 ]" "and 200 lines of them do not: the splice is bounded"
rm -rf "$d20"


cd "$ROOT" || exit 1
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
