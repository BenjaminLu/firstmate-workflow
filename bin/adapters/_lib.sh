# What a vendor's run meant. One place decides it, because every vendor can
# fail the same four ways and a copy of this per adapter drifts.
#
# Not executable and no shebang on purpose: this is a library, which is why
# the contract test skips names beginning with an underscore.
#
# The rule that is easy to get wrong: unavailability is decided by what the
# CLI said, not by how it exited. cursor-agent prints "Authentication
# required" and exits 0. An adapter that trusted the exit code would report
# done, the gates would run against an untouched worktree, and the reviewer
# would spend a round on nothing.
#
# The rule that is easier to get wrong in the other direction: the text being
# searched is written by a model doing the task, and the task may be about
# logins, rate limits or HTTP 429. A false positive discards completed work,
# which is worse than the wasted review round this exists to prevent. So the
# signatures are split:
#
#   NARROW  things no working model emits as its own output. Trusted even on
#           exit 0, and only in the first lines, where a CLI reports an
#           outage before doing anything else.
#   WIDE    things a model can legitimately say. Consulted when the run
#           already failed - where they explain a failure rather than invent
#           one - and, on exit 0, only when the run was short and led with
#           something that reads as an error report. An outage is brief and
#           says so immediately; a model's answer is long and buries the word
#           in the middle of an argument.
#
# The fallback chain appends to one log, so a verdict only ever reads the
# bytes its own run added.

_FM_NARROW='not logged in|please (run|use) [^ ]* ?login|login required|authentication required|invalid api key|missing api key|no api key found|api key not (set|found|configured)|ENOTFOUND|ECONNREFUSED|EAI_AGAIN'
_FM_WIDE='authenticat|unauthor|credentials?|quota exceeded|out of quota|rate limit|40[13]|429|network error|fetch failed|ETIMEDOUT'
_FM_ERRORLIKE='(^|[^A-Za-z])([Ee]rror|ERROR|[Ff]atal|FATAL|[Ff]ailed)([^A-Za-z]|$)|^ *(40[13]|429)[ :]'
_FM_SHORT=4000   # bytes: longer than any outage report, shorter than any answer

# fm_adapter_mark <log> -> byte offset to read from after the run
fm_adapter_mark() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }

# fm_adapter_verdict <rc> <log> <offset> -> 0 done / 1 unfit / 2 unavailable
fm_adapter_verdict() {
  local rc="$1" log="$2" off="$3" said='' head5
  [ -f "$log" ] && said="$(tail -c "+$((off + 1))" "$log" 2>/dev/null)"
  head5="$(printf '%s' "$said" | head -5)"

  # an outage is the first thing the run says, not something it mentions later
  printf '%s' "$head5" | grep -qiE "$_FM_NARROW" && return 2
  if [ "$(printf '%s' "$said" | wc -c | tr -d ' ')" -le "$_FM_SHORT" ] &&
     printf '%s' "$head5" | grep -qiE "$_FM_WIDE" &&
     printf '%s' "$head5" | grep -qE "$_FM_ERRORLIKE"; then
    return 2
  fi

  case "$rc" in 2|4|41|69|75) return 2 ;; esac
  if [ "$rc" != 0 ]; then
    # it already failed; the wide signatures now only name the reason
    printf '%s' "$said" | grep -qiE "$_FM_WIDE" && return 2
    return 1
  fi
  # exit 0 having said nothing at all is not a success either
  [ -n "$said" ] || return 1
  return 0
}
