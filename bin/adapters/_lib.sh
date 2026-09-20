#!/usr/bin/env bash
# What a vendor's run meant. One place decides it, because every vendor can
# fail the same four ways and a copy of this per adapter drifts - the way five
# copies of one sed did.
#
# The rule that is easy to get wrong: unavailability is decided by what the
# CLI said, not by how it exited. cursor-agent prints "Authentication
# required" and exits 0. An adapter that trusted the exit code would report
# done, the gates would run against an untouched worktree, and the reviewer
# would spend a round on nothing.
#
# The fallback chain appends to one log, so a verdict only ever reads the
# bytes its own run added.

# fm_adapter_mark <log> -> byte offset to read from after the run
fm_adapter_mark() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }

# fm_adapter_verdict <rc> <log> <offset> -> 0 done / 1 unfit / 2 unavailable
fm_adapter_verdict() {
  local rc="$1" log="$2" off="$3" said=''
  [ -f "$log" ] && said="$(tail -c "+$((off + 1))" "$log" 2>/dev/null)"

  # specific enough that a model writing about API keys is not mistaken for
  # one being missing; the cost of a false positive is a needless fallback,
  # the cost of a false negative is a wasted review round
  case "$said" in *[Aa]uthenticat*|*[Uu]nauthor*) return 2 ;; esac
  printf '%s' "$said" | grep -qiE \
    'not logged in|please (run|use) [^ ]* ?login|login required|invalid api key|missing api key|no api key found|api key not|credentials? (not|are not) |quota exceeded|out of quota|rate limit|429|network error|fetch failed|ENOTFOUND|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN' \
    && return 2

  # the exit codes vendors use for the same thing
  case "$rc" in 2|4|41|69|75) return 2 ;; esac
  [ "$rc" = 0 ] || return 1
  # exit 0 having said nothing at all is not a success either
  [ -n "$said" ] || return 1
  return 0
}
