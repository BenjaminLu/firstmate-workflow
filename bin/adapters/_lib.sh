# shellcheck shell=bash
# What a vendor's run meant. One place decides it, because every vendor can
# fail the same four ways and a copy of this per adapter drifts.
#
# Not executable and no shebang on purpose: this is a library, which is why
# the contract test skips names beginning with an underscore. bin/ci.sh does
# lint it - bin/*.sh does not recurse, so the adapters are listed separately.
#
# The rule that is easy to get wrong: unavailability is decided by what the
# CLI said, not by how it exited. cursor-agent prints "Authentication
# required" and exits 0.
#
# The rule that took four rounds to get right: wording cannot settle it.
# There is no phrase a model cannot write - this repository contains
# "Authentication required" in two files, so any review of it quotes them.
# Three attempts to make wording decide (a byte threshold, a five-line
# window, a list of phrases "only a CLI says") all failed the same way: each
# described the outages I happened to have rather than what an outage is.
#
# So what is here is deliberately generous and deliberately not final: one
# list of signatures, matched anywhere in the run's own output, on any exit
# code. No window, no error-line requirement - both were constants chosen to
# fit fixtures.
#
# The caller settles it. fm_run_chain takes a predicate answering "did this
# run produce work?", and work beats any signature: a worker asks whether
# the worktree changed, a reviewer whether the output carries a verdict
# marker. Being over-eager here costs one more vendor attempt, never the
# work.
#
# The fallback chain appends to one log, so a verdict only ever reads the
# bytes its own run added.

# Every alternative here has to be shaped like a failure. Bare nouns are
# what a healthy run prints on its way up: gemini says "Loaded cached
# credentials." before it does anything, and a `credentials?` alternative
# turned every successful gemini run into a reported outage. Each one below
# was read against a successful transcript as well as a failing one.
# Flat on purpose: one alternative per phrase, no nested groups. The suite
# splits this on "|" and fails if any alternative has no transcript that
# carries it, which only works if an alternative is a phrase rather than a
# little grammar. Each one is a way a CLI reports that it could not run.
_FM_SIG='authentication failed|authentication required|authentication error|error authenticating|authenticate failed|not authenticated|unauthori[sz]ed|401 unauthorized|403 forbidden|429 too many requests|status 401|status 403|status 429|too many requests,|not logged in|please run [a-z0-9 ._-]{0,30}login|please use [a-z0-9 ._-]{0,30}login|login required|invalid api key|missing api key|no api key|expired api key|api key not set|api key not found|api key not configured|api key not valid|invalid credentials|missing credentials|expired credentials|credentials could not|quota exceeded|quota exhausted|out of quota|rate limit exceeded|rate limit reached|rate-limited|rate limited|network error:|network error while|network unreachable|network failure|fetch failed|ENOTFOUND|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN'

# fm_adapter_mark <log> -> byte offset to read from after the run
fm_adapter_mark() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }

# fm_adapter_verdict <rc> <log> <offset> -> 0 done / 1 unfit / 2 unavailable
fm_adapter_verdict() {
  local rc="$1" log="$2" off="$3" said=''
  [ -f "$log" ] && said="$(tail -c "+$((off + 1))" "$log" 2>/dev/null)"

  # a here-string, not a pipeline: under `set -o pipefail` a grep -q that
  # matches early kills the producer, printf takes SIGPIPE, and the pipeline
  # reports failure even though the match happened. The verdict would then
  # fall through to "done" on exactly the transcript it was meant to catch.
  grep -qiE "$_FM_SIG" <<< "$said" && return 2
  case "$rc" in 2|4|41|69|75) return 2 ;; esac
  [ "$rc" = 0 ] || return 1
  # exit 0 having said nothing at all is not a success either
  [ -n "$said" ] || return 1
  return 0
}
