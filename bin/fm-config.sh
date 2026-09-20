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

# fm_run_chain <adapters-dir> <chain> <prompt> <tree> <log>
#   Returns the adapter's own exit code, or 2 if every vendor was unavailable.
#   Sets FM_VENDOR_USED and FM_VENDOR_SKIPPED so the caller can say what it did.
# shellcheck disable=SC2034  # both are read by the callers, not here
fm_run_chain() {
  local dir="$1" chain="$2" prompt="$3" tree="$4" log="$5" v rc=2
  FM_VENDOR_USED=''; FM_VENDOR_SKIPPED=''
  for v in $chain; do
    [ -x "$dir/$v.sh" ] || continue
    "$dir/$v.sh" run "$prompt" "$tree" "$log"; rc=$?
    if [ "$rc" = 2 ]; then FM_VENDOR_SKIPPED="${FM_VENDOR_SKIPPED:+$FM_VENDOR_SKIPPED }$v"; continue; fi
    FM_VENDOR_USED="$v"; return "$rc"
  done
  return "$rc"
}
