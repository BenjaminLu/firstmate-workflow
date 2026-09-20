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
# The rule that is easier to get wrong in the other direction: the text being
# searched is written by a model doing the task, and the task may be about
# logins, rate limits or HTTP 429. A false positive discards completed work,
# which is worse than the wasted review round this exists to prevent. Two
# earlier attempts at the discriminator were fitted to the fixtures - a byte
# threshold, then a five-line window - and both were wrong for the same
# reason: they measured the shape of the outages I happened to have rather
# than what distinguishes one.
#
# What actually distinguishes an outage: the CLI reports it as an error, on
# its own line, as the thing it did instead of the work. So on exit 0 a line
# must BEGIN with an error marker and carry a signature on that same line. A
# model writing "1. the adapter failed to deliver the prompt; the CLI returns
# 401" does neither - its mention is mid-line, in a numbered list.
#
# The window is the opening of the output, in bytes rather than lines,
# because a CLI may print an update notice or "Loaded cached credentials."
# before it gets to the failure. It is generous: a run that is still
# reporting an outage two kilobytes in has not started the work either.
#
# When the run already failed, the signatures only name the reason, so both
# lists are searched over the whole output - being wrong there costs a
# fallback, not finished work.

# There is no phrase a model cannot write: this very repository contains
# "Authentication required" in two files, so any review of it quotes them.
# Wording alone can therefore never decide. Three attempts at making it
# decide - a byte threshold, a five-line window, a "only a CLI says this"
# list - all failed the same way: they described the outages I happened to
# have rather than what an outage is.
#
# So wording no longer decides anything final. It is deliberately generous
# here, and the caller settles it: fm_run_chain takes a predicate that
# answers "did this run produce work?", and work beats any signature. A
# worker asks whether the worktree changed; a reviewer asks whether the
# output carries a verdict marker. Being over-eager here now costs at most
# one more vendor attempt, and never the work.
_FM_SIG='authenticat|unauthor|not logged in|please (run|use) [^ ]* ?login|login required|invalid api key|missing api key|no api key|api key not (set|found|configured)|credentials?|quota|rate limit|network (error|unreachable)|fetch failed|ENOTFOUND|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN'
_FM_OPENING=2000   # bytes of the opening a CLI gets to report an outage in

# fm_adapter_mark <log> -> byte offset to read from after the run
fm_adapter_mark() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }

# fm_adapter_verdict <rc> <log> <offset> -> 0 done / 1 unfit / 2 unavailable
fm_adapter_verdict() {
  local rc="$1" log="$2" off="$3" said='' opening
  [ -f "$log" ] && said="$(tail -c "+$((off + 1))" "$log" 2>/dev/null)"
  opening="$(printf '%s' "$said" | head -c "$_FM_OPENING")"

  printf '%s' "$opening" | grep -qiE "$_FM_SIG" && return 2


  case "$rc" in 2|4|41|69|75) return 2 ;; esac
  if [ "$rc" != 0 ]; then
    # it already failed; a signature anywhere now only names the reason
    printf '%s' "$said" | grep -qiE "$_FM_SIG" && return 2
    return 1
  fi
  # exit 0 having said nothing at all is not a success either
  [ -n "$said" ] || return 1
  return 0
}
