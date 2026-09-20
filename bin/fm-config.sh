# fm:sourced  # this file is sourced; see bin/ci.sh, stdin stage
# shellcheck shell=bash
# One reader for config.yaml. There were five copies of the same sed
# expression and every one of them kept the trailing comment, so
# "concurrency: 3  # workers in flight" arithmetic-errored the dispatcher the
# first time anyone ran it for real. One place to be wrong is the fix.
#
#   . bin/fm-config.sh
#   fm_cfg vendor                 -> claude
#   fm_cfg_in reviewer vendor     -> cursor-agent
#   fm_cfg_list fallback          -> one per line

_fm_clean() {   # strip an inline comment, surrounding quotes, and stray space
  sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' \
      -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

fm_cfg() {      # fm_cfg <key> [file]
  local f="${2:-config.yaml}"
  [ -f "$f" ] || return 1
  sed -n "s/^$1:[[:space:]]*//p" "$f" | head -1 | _fm_clean
}

fm_cfg_in() {   # fm_cfg_in <section> <key> [file]
  local f="${3:-config.yaml}"
  [ -f "$f" ] || return 1
  sed -n "/^$1:/,/^[^[:space:]#]/p" "$f" \
    | sed -n "s/^[[:space:]][[:space:]]*$2:[[:space:]]*//p" | head -1 | _fm_clean
}

fm_cfg_list() { # fm_cfg_list <section> [file]
  local f="${2:-config.yaml}"
  [ -f "$f" ] || return 1
  sed -n "/^$1:/,/^[^[:space:]#-]/p" "$f" \
    | sed -n 's/^[[:space:]]*-[[:space:]]*//p' | _fm_clean
}

# The order vendors are tried in, and the running of that order. Both the
# worker and the reviewer need it and they must behave identically, so it
# lives here once rather than as a loop in each.
#
# fm_vendor_chain [role] [explicit]
#   An explicit --vendor is the whole chain: the caller asked for that engine,
#   not for whatever the config would fall back to.
fm_vendor_chain() {
  local role="${1:-}" explicit="${2:-}" head=''
  if [ -n "$explicit" ]; then printf '%s\n' "$explicit"; return 0; fi
  [ -n "$role" ] && head="$(fm_cfg_in "$role" vendor)"
  [ -n "$head" ] || head="$(fm_cfg vendor)"
  [ -n "$head" ] || head=mock
  # one run per vendor: a fallback list may name the head, or itself twice
  printf '%s\n' "$head"
  fm_cfg_list fallback | grep -vxF "$head" | awk '!seen[$0]++' || true
}

# fm_run_chain <adapters-dir> <chain> <prompt> <tree> <log> [evidence]
#   Returns the adapter's own exit code, or 2 if every vendor was unavailable.
#   Sets FM_VENDOR_USED and FM_VENDOR_SKIPPED so the caller can say what it did.
#
#   <evidence> is a command that answers "did that run produce work?". An
#   adapter decides "unavailable" by reading text, and text can lie in both
#   directions, so the caller gets the last word: a worker asks whether the
#   worktree changed, a reviewer whether the output carries a verdict marker.
#   Work beats a signature, and the chain stops there. FM_VENDOR_MISREAD names
#   the vendor this happened to, so the caller can say so.
#
#   FM_VENDOR_SPOKE is 1 when some attempt produced output of its own -
#   bytes appended to the log, or, in per-vendor mode only, a file in its
#   own directory. In shared mode the directory is the caller's artefact and
#   was not empty to begin with, so it cannot answer the question and is not
#   consulted. With
#   the return code it is the whole of what a caller needs: rc 2 with
#   nothing said is a vendor that was not there; rc 2 with something said is
#   an engine that ran badly. Neither caller may re-derive this by looking
#   at bytes itself - they disagreed when they did.
#
#   The head of the chain having no adapter is a typo in config.yaml, not an
#   outage: nothing is run at all, FM_VENDOR_UNKNOWN names it and 65 comes
#   straight back, so the caller's own exit 65 cannot discard work a later
#   vendor had already done.
#
#   <outmode> "per-vendor" gives each attempt its own directory under <tree>
#   and names it in FM_RUN_OUTDIR (in shared mode that is <tree> itself,
#   shared by every attempt); the default shares <tree>, which is what
#   a worker wants because the worktree IS the artefact. FM_RUN_LOG_OFF is
#   where this attempt's bytes start in the shared log, so an evidence
#   predicate can read its own output and no one else's.
# shellcheck disable=SC2034  # these are read by the callers, not here
fm_run_chain() {
  local dir="$1" chain="$2" prompt="$3" tree="$4" log="$5" evidence="${6:-}" \
        outmode="${7:-shared}" v rc=2 head='' out='' after=0
  # every output of this function, including the two that say where an
  # attempt's bytes are: leaving those set means a caller on the
  # configuration-error path reads the PREVIOUS call's attempt, which is the
  # exact confusion the offsets exist to prevent
  FM_VENDOR_USED=''; FM_VENDOR_SKIPPED=''; FM_VENDOR_MISREAD=''; FM_VENDOR_UNKNOWN=''
  FM_RUN_OUTDIR=''; FM_RUN_LOG_OFF=0; FM_VENDOR_SPOKE=0
  # before anything runs. A typo at the head of the chain used to be found
  # after a real vendor had already worked, and the caller's exit 65 then
  # threw that work away.
  # unquoted on purpose: a chain arrives space-separated or newline-separated
  # and the head is the first word either way. SC2086 is info-level and the
  # gate runs at warning, so there is no directive here to go stale - the
  # adapters rely on the same deliberate splitting for FM_ADAPTER_ARGS.
  head="$(printf '%s\n' $chain | head -1)"
  if [ -n "$head" ] && [ ! -x "$dir/$head.sh" ]; then
    FM_VENDOR_UNKNOWN="$head"; return 65
  fi
  for v in $chain; do
    [ -x "$dir/$v.sh" ] || continue
    # each vendor reads only what it wrote. The chain shares one log, and a
    # vendor that dies half way through must not have its bytes read as the
    # next one's answer - so the caller is told where this attempt's output
    # begins, and where it went.
    FM_RUN_LOG_OFF="$(wc -c "$log" 2>/dev/null | awk '{print $1}')"
    [ -n "$FM_RUN_LOG_OFF" ] || FM_RUN_LOG_OFF=0
    if [ "$outmode" = "per-vendor" ]; then
      out="$tree/$v"; mkdir -p "$out"
    else
      out="$tree"
    fi
    FM_RUN_OUTDIR="$out"
    "$dir/$v.sh" run "$prompt" "$out" "$log"; rc=$?
    # did this vendor say anything of its own? The callers need to tell an
    # engine that ran badly from one that was not there, and this is the
    # only place that can answer it - an adapter's notice about a missing
    # CLI goes to stderr precisely so it does not count here.
    #
    # In shared mode the directory IS the artefact and is never empty, so
    # only the log slice can answer this; the per-vendor directory starts
    # empty and anything in it was written by this attempt. The meaning is
    # the same in both modes: bytes this attempt produced.
    after="$(wc -c "$log" 2>/dev/null | awk '{print $1}')"; [ -n "$after" ] || after=0
    [ "$after" != "$FM_RUN_LOG_OFF" ] && FM_VENDOR_SPOKE=1
    if [ "$outmode" = "per-vendor" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
      FM_VENDOR_SPOKE=1
    fi
    if [ "$rc" = 2 ] && [ -n "$evidence" ] && $evidence; then
      FM_VENDOR_USED="$v"; FM_VENDOR_MISREAD="$v"; return 0
    fi
    if [ "$rc" = 2 ]; then FM_VENDOR_SKIPPED="${FM_VENDOR_SKIPPED:+$FM_VENDOR_SKIPPED }$v"; continue; fi
    FM_VENDOR_USED="$v"; return "$rc"
  done
  return "$rc"
}
