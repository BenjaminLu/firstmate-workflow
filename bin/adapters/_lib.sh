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

# Called after argument validation and before touching a model. The Python
# runner invokes this same adapter inside a real pane with context-ready=1.
fm_adapter_context() {
  local adapter="$1" code bad
  unset FM_CLI_EXIT
  # A run-mode review may only reach an adapter that confines it (see
  # fm_review_run_chain). fm-review.sh already keeps the rest out of the
  # chain; this is the same rule where the CLI would start, for every adapter
  # that sources this file, so no caller can hand one an unconfined round.
  if [ "${FM_RUN_REVIEW:-}" = 1 ] && ! grep -q '^# fm:review-run' "$adapter"; then
    echo "${adapter##*/}: cannot confine a run-mode review; refusing it" >&2
    exit 64
  fi
  # The same for the network: fm-review.sh refuses a GitHub host with 65, and
  # an adapter reached any other way refuses it here, before its CLI starts.
  if [ "${FM_RUN_REVIEW:-}" = 1 ]; then
    bad="$(fm_review_network_refusal "${FM_REVIEW_NETWORK:-}")"
    [ -z "$bad" ] || {
      echo "${adapter##*/}: reviewer network names $bad; refusing a run-mode review" >&2
      exit 64; }
  fi
  code="$(cd "$(dirname "$adapter")/../.." && pwd)"
  if [ "${HERDR_ENV:-}" = 1 ] && [ "${FM_TRANSPORT:-herdr}" = direct ] && [ "${FM_ALLOW_DIRECT:-}" != 1 ]; then
    echo "${adapter##*/}: FM_TRANSPORT=direct is refused when HERDR_ENV=1; use stock managed Herdr via fm-worker/fm-review" >&2
    exit 70
  fi
  if [ "${FM_CONTEXT_READY:-}" != 1 ] && { [ -n "${FM_RUN_DIR:-}" ] || { [ "${HERDR_ENV:-}" = 1 ] && [ "${FM_TRANSPORT:-herdr}" != direct ]; }; }; then
    # shellcheck disable=SC2154  # validated positional arguments in each adapter
    exec python3 "$code/bin/fm-herdr.py" transport "$adapter" "$prompt" "$tree" "$log"
  fi
}

# The domains GitHub operates. A run-mode sandbox reaches none of them, nor
# any subdomain: the network is what keeps a push, a comment or any other gh
# call from leaving the round, and a prefix deny list cannot.
FM_GITHUB_DOMAINS=(github.com github.io github.dev githubusercontent.com githubassets.com
                   githubapp.com githubcopilot.com ghcr.io ghe.com)

# fm_review_host_refusal <host> -> why a run-mode sandbox may not reach it,
# or nothing when it may. Plain domain names only: each goes into a settings
# string verbatim, and a wildcard such as `*.com` reaches GitHub as surely as
# naming it. Case does not matter, and a GitHub domain is matched on a label
# boundary, so raw.githubusercontent.com is one and notgithub.com is not.
fm_review_host_refusal() {
  local h d
  case "${1-}" in
    ''|*[!A-Za-z0-9.-]*|.*|*.|*..*) printf 'is not a plain domain name\n'; return 0 ;;
  esac
  h="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  for d in "${FM_GITHUB_DOMAINS[@]}"; do
    case "$h" in
      "$d"|*."$d") printf 'is a GitHub host; a run-mode reviewer may not reach GitHub\n'; return 0 ;;
    esac
  done
  # and loopback, which is the captain's board, dev servers and Herdr (T-105)
  case "$h" in
    localhost|*.localhost) printf 'is loopback; a crew round may not reach loopback\n'; return 0 ;;
    *[!0-9.]*) ;;
    *) printf 'is an address; a registry is named, and loopback is never one\n'; return 0 ;;
  esac
}

# fm_review_network_refusal <hosts> -> "<host>, which <why>" for the first of
# the space-separated hosts a run-mode sandbox may not reach, or nothing.
# Split with read: an unquoted expansion also globs, and `*` would be checked
# as the file names in the current directory.
fm_review_network_refusal() {
  local net=() h why
  read -r -a net <<<"${1-}"
  for h in ${net[@]+"${net[@]}"}; do
    why="$(fm_review_host_refusal "$h")"
    [ -z "$why" ] || { printf '%s, which %s\n' "$h" "$why"; return 0; }
  done
}

# fm_adapter_review_checkout -> the run-mode checkout, resolved, or exit 64.
# It must look like the clone fm-review.sh made: an absolute directory with
# its own .git, never a relative path the CLI would resolve against wherever
# it happened to start.
fm_adapter_review_checkout() {
  local dir="${FM_REVIEW_CHECKOUT:-}"
  case "$dir" in /*) ;; *) echo "adapter: FM_REVIEW_CHECKOUT must be an absolute path" >&2; exit 64 ;; esac
  [ -d "$dir/.git" ] || { echo "adapter: no checkout at $dir" >&2; exit 64; }
  fm_adapter_rule_path "$dir"
}

# fm_adapter_review_env -> `env -u NAME ...` words, one per line, that start
# a run-mode engine without the launcher's state. fm_identity exports FM_ROOT
# at the task's repository and the checkout's scripts choose their tree from
# FM_ROOT, so a `check` the reviewer runs there would gate another tree; the
# same holds for the rest of FM_*, for HERDR_* (which routes a nested adapter
# into the captain's panes), for GIT_* (GIT_DIR would point git inside the
# checkout at another repository) and for the GitHub tokens, which the round
# has no use for. Everything else, the cache redirection included, stays.
fm_adapter_review_env() {
  local v
  printf 'env\n'
  while IFS= read -r v; do
    case "$v" in FM_*|HERDR_*|GIT_*|GH_*|GITHUB_TOKEN) printf -- '-u\n%s\n' "$v" ;; esac
  done < <(compgen -e)
}

# fm_adapter_rule_path <dir> -> the directory resolved, or exit 64. The path
# goes into permission rules and a JSON settings string verbatim, so one
# that would need quoting there is refused rather than escaped.
fm_adapter_rule_path() {
  local dir
  dir="$(cd "$1" 2>/dev/null && pwd -P)" || { echo "adapter: no directory at $1" >&2; exit 64; }
  case "$dir" in
    *[[:space:]\"\\*\(\),]*) echo "adapter: $dir cannot be written into a permission rule" >&2; exit 64 ;;
  esac
  printf '%s\n' "$dir"
}

# --- the round's permission policy (T-105) --------------------------------
# Every round runs under one policy fm owns, per role: fm_policy in
# bin/fm-config.sh resolves it from config.yaml, fm-worker.sh and
# fm-review.sh hand it over as FM_POLICY, and nothing about it comes from
# the operator's own CLI settings. Each adapter translates it into its CLI's
# flags and says which dimensions those flags enforce; bin/fm-sandbox.sh
# enforces what it can of the rest from outside the CLI. A dimension that
# neither enforces refuses the round with 2, before the CLI starts, so the
# fallback chain moves on and no round runs less confined than its policy.
FM_POLICY_DIMENSIONS="write read network sockets env repo-config refuse ulimit"
_fm_engine="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# fm_adapter_policy -> FM_POLICY, FM_POLICY_HOSTS, FM_OUTER_OS, FM_OUTER_DIMS.
# An adapter reached without a policy - by hand, or by a caller that does
# not know about one - takes the engine's own for its role rather than none.
# shellcheck disable=SC2034  # read by the adapter that sourced this
fm_adapter_policy() {
  local f
  if [ -n "${FM_POLICY:-}" ]; then
    [ -r "$FM_POLICY" ] || { echo "adapter: no policy at $FM_POLICY; refusing an unconfined round" >&2; exit 65; }
  else
    f="$(mktemp "${TMPDIR:-/tmp}/fm-policy.XXXXXX")" || exit 70
    # shellcheck disable=SC2016  # expanded by the inner shell
    bash -c '. "$1/bin/fm-config.sh" && fm_policy "$2" "" "$1/config.yaml"' fm-policy \
      "$_fm_engine" "${FM_ROLE:-worker}" > "$f" || {
      rm -f "$f"; echo "adapter: the crew policy does not read; refusing an unconfined round" >&2; exit 65; }
    FM_POLICY="$f"; export FM_POLICY
  fi
  FM_POLICY_HOSTS="$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["network"]))' \
    "$FM_POLICY" 2>/dev/null)" || { echo "adapter: the policy at $FM_POLICY does not read" >&2; exit 65; }
  # fm_policy refuses these already; a policy file that says otherwise was
  # not written by it, and no vendor flag is given GitHub or loopback
  local bad
  bad="$(fm_review_network_refusal "$FM_POLICY_HOSTS")"
  [ -z "$bad" ] || { echo "adapter: the policy's network names $bad; refusing the round" >&2; exit 65; }
  FM_OUTER_OS="$("$_fm_engine/bin/fm-sandbox.sh" os)"
  FM_OUTER_DIMS="$("$_fm_engine/bin/fm-sandbox.sh" covers --policy="$FM_POLICY")" || {
    echo "adapter: the policy at $FM_POLICY does not read" >&2; exit 65; }
  [ -n "$FM_OUTER_DIMS" ] || FM_OUTER_OS=''
}

# fm_adapter_confine <vendor> <workdir> <dimension>... -> FM_LAUNCH, or exit 2.
# The dimensions are what the vendor's own flags enforce for this round.
# FM_LAUNCH is the words the CLI is started behind: the OS sandbox when this
# host has one, and otherwise the environment scrub and ulimits alone.
# shellcheck disable=SC2034  # read by the adapter that sourced this
fm_adapter_confine() {
  local vendor="$1" work="$2" have d missing=''
  have=" ${*:3} $FM_OUTER_DIMS "
  for d in $FM_POLICY_DIMENSIONS; do
    case "$have" in *" $d "*) ;; *) missing="$missing $d" ;; esac
  done
  if [ -n "$missing" ]; then
    echo "$vendor: this round's policy needs$missing, which neither $vendor's own flags nor an OS sandbox enforce on this host; refusing the round" >&2
    exit 2
  fi
  # absolute: the adapter starts the CLI after changing into it
  work="$(cd "$work" 2>/dev/null && pwd -P)" || { echo "$vendor: no directory at $2" >&2; exit 64; }
  FM_LAUNCH=("$_fm_engine/bin/fm-sandbox.sh")
  if [ -n "$FM_OUTER_OS" ]; then
    FM_LAUNCH+=(run --policy="$FM_POLICY" --root="$work" --vendor="$vendor")
    # the CLI's own final answer is written where the launcher reads it
    [ -z "${FM_ATTEMPT_DIR:-}" ] || FM_LAUNCH+=(--write="$FM_ATTEMPT_DIR")
    [ -z "${FM_FINAL_PATH:-}" ] || FM_LAUNCH+=(--write="$(dirname "$FM_FINAL_PATH")")
    [ -z "${FM_POLICY_BLOCKED:-}" ] || FM_LAUNCH+=(--blocked="$FM_POLICY_BLOCKED")
  else
    FM_LAUNCH+=(plain --policy="$FM_POLICY")
  fi
  FM_LAUNCH+=(--)
}

# fm_adapter_dimensions <dimension>... -> the declaration `<vendor>.sh
# dimensions` prints: what this vendor's flags enforce here, and what the OS
# sandbox adds
fm_adapter_dimensions() {
  printf 'native: %s\n' "$*"
  printf 'sandbox: %s\n' "${FM_OUTER_DIMS:-none}"
}

# Keep the CLI's exit separately from a failed transcript writer. Either failure
# fails the adapter, but only the first pipeline member is the model process.
fm_adapter_pipeline_status() {
  FM_CLI_EXIT="$1"
  [ "$2" = 0 ] || return 1
  return "$1"
}

# fm_adapter_mark <log> -> byte offset to read from after the run
fm_adapter_mark() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }

# fm_adapter_verdict <rc> <log> <offset> -> 0 done / 1 unfit / 2 unavailable
fm_adapter_verdict() {
  local rc="$1" log="$2" off="$3" said=''
  [ -z "${FM_ATTEMPT_DIR:-}" ] || printf '%s\n' "${FM_CLI_EXIT:-$rc}" > "$FM_ATTEMPT_DIR/cli-exit-code"
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
