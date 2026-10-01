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
# For legacy calls and other vendors this is deliberately generous: one
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
# Managed Codex instead reads typed CLI errors and completed turns (T-167).

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

# fm_cfg_in (T-121's billing: block) is read straight from bin/fm-config.sh,
# not reimplemented here: one reader for config.yaml, as fm-config.sh's own
# header says.
_fm_alib_config="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/fm-config.sh"
[ -r "$_fm_alib_config" ] || { echo "adapters/_lib.sh: missing $_fm_alib_config" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$_fm_alib_config"

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

# A marker admits the vendor to the chain, never the invocation. Codex must
# match the context recorded by the trusted transport before executing a model.
fm_adapter_codex_review_context() {
  [ "${FM_CONTEXT_READY:-}" = 1 ] && [ -n "${FM_ATTEMPT_DIR:-}" ] || {
    echo "codex: run review requires managed launcher context" >&2; return 64; }
  python3 - "$_fm_engine" <<'PY'
import importlib.util, json, os, pathlib, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('managed', pathlib.Path(sys.argv[1]) / 'bin/fm-herdr.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    context = m.review_context(os.environ)
    invocation = json.loads((pathlib.Path(os.environ['FM_ATTEMPT_DIR']) / 'invocation.json').read_text())
    expected_adapter = str(pathlib.Path(sys.argv[1]) / 'bin/adapters/codex.sh')
    if invocation.get('review') != context or invocation.get('adapter') != expected_adapter:
        raise ValueError('review checkout does not match trusted invocation')
    for key, name in [('actor', 'FM_ACTOR'), ('role', 'FM_ROLE'), ('task', 'FM_TASK')]:
        if invocation.get(key) != os.environ.get(name): raise ValueError('review identity mismatch')
    print(context['checkout'])
except Exception as error:
    sys.exit('codex: invalid review context: ' + str(error))
PY
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

# --- credentials that would outrank the round's own login (T-121) ----------
# claude documents ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN,
# CLAUDE_CODE_USE_BEDROCK and CLAUDE_CODE_USE_VERTEX as switching which
# account or billing claude uses, ahead of a stored login; codex's
# OPENAI_API_KEY and CODEX_API_KEY do the same ahead of a ChatGPT plan
# login; gemini's GEMINI_API_KEY and GOOGLE_API_KEY do it ahead of the
# Google account flow. Set in the operator's own shell for their own
# interactive use - not chosen for the crew - any of them would silently
# outbid the one login fm hands a round in, which is how a captain's own
# ANTHROPIC_API_KEY could bill their crew's rounds to a personal key without
# anyone asking for that (2026-09-26/27). cursor-agent has no such variable
# here: CURSOR_API_KEY is not a credential that outranks another login, it
# is the only login this design hands a cursor-agent round at all, so
# nothing of cursor-agent's is ever shed.
#
# config.yaml's billing: block is the one place the operator opts a vendor
# into api-key billing; fm_cfg_in reads it without a heredoc, so an adapter
# reached with a plain policy file and no engine root still reads it.
# Settings belong to the operator's repository, not the frozen code snapshot
# (which contains only bin/ and skills/). Keep the explicit override, and
# use the engine's config only for a direct invocation without FM_ROOT.
fm_adapter_config() {
  printf '%s\n' "${FM_ADAPTER_CONFIG:-${FM_ROOT:-$_fm_engine}/config.yaml}"
}

fm_adapter_billing() {  # fm_adapter_billing <vendor> -> "api-key" or ""
  local vendor="$1" mode='' cfg
  cfg="$(fm_adapter_config)"
  if [ -f "$cfg" ]; then
    mode="$(fm_cfg_in billing "$vendor" "$cfg" 2>/dev/null)"
  fi
  case "$mode" in api-key) printf 'api-key\n' ;; *) printf '\n' ;; esac
}

# fm_adapter_env_words <vendor> <var>... -> "env" then "-u NAME" lines that
# must run the vendor's CLI: a run-mode review's launcher scrub
# (fm_adapter_review_env) plus <var>... unless config.yaml's billing: block
# named <vendor> (fm_adapter_billing). Nothing at all when neither applies,
# so an ordinary round with nothing to shed adds no wrapper.
fm_adapter_env_words() {
  local vendor="$1"; shift
  local words=() v
  if [ "${FM_RUN_REVIEW:-}" = 1 ]; then
    while IFS= read -r v; do [ "$v" = env ] || words+=("$v"); done < <(fm_adapter_review_env)
  fi
  if [ "$(fm_adapter_billing "$vendor")" != api-key ]; then
    for v in "$@"; do words+=(-u "$v"); done
  fi
  [ "${#words[@]}" -eq 0 ] || { printf 'env\n'; printf '%s\n' "${words[@]}"; }
}

# fm_adapter_outranking <vendor> -> the variables above, one per line: the
# one list the adapters shed, fm-sandbox.sh does not count as a login
# (--shed) and fm-auth-probe.sh probes without.
fm_adapter_outranking() {
  case "$1" in
    claude) printf '%s\n' ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX ;;
    codex)  printf '%s\n' OPENAI_API_KEY CODEX_API_KEY ;;
    gemini) printf '%s\n' GEMINI_API_KEY GOOGLE_API_KEY ;;
  esac
}

# fm_adapter_credentials <vendor> -> every variable that carries a login of
# <vendor>'s, one per line: its outranking list above, and the variable fm
# hands its round the login in (bin/fm-config.sh's VENDORS `to`/`given`).
fm_adapter_credentials() {
  fm_adapter_outranking "$1"
  case "$1" in
    claude)       printf '%s\n' CLAUDE_CODE_OAUTH_TOKEN ;;
    cursor-agent) printf '%s\n' CURSOR_API_KEY ;;
  esac
}

# fm_adapter_shed <vendor> -> the variables a round of <vendor> goes
# without, one per line: its own outranking list, unless config.yaml's
# billing: block chose api-key billing for it, and every other vendor's
# credentials whatever billing says - a claude round has no use for a
# CURSOR_API_KEY or an OPENAI_API_KEY left in the operator's shell, so the
# round's environment holds exactly the credential its own policy names.
fm_adapter_shed() {
  local v
  [ "$(fm_adapter_billing "$1")" = api-key ] || fm_adapter_outranking "$1"
  while IFS= read -r v; do
    [ "$v" = "$1" ] || fm_adapter_credentials "$v"
  done < <(fm_vendors)
}

# --- a crew round never runs on a login it did not check (T-121) -----------
# fm-auth-probe.sh resolves the login exactly as a round will get it, through
# fm-sandbox.sh's own lookup, and asks the vendor's CLI about that login
# alone - not about the operator's own session. fm-worker.sh and
# fm-review.sh call these before a round ever reaches a vendor's CLI, so a
# login that is not confirmed is found here, not inside the sandbox.
#
# fm_auth_probe <code-root> <vendor> -> sets FM_AUTH_STATUS, FM_AUTH_EN,
# FM_AUTH_TW from bin/fm-auth-probe.sh's own output. The probe's version
# line is fm-doctor.sh's own concern, read there directly; nothing here
# needs it.
fm_auth_probe() {
  local root="$1" vendor="$2" out
  FM_AUTH_STATUS=''; FM_AUTH_EN=''; FM_AUTH_TW=''
  out="$("$root/bin/fm-auth-probe.sh" "$vendor" </dev/null 2>/dev/null)"
  FM_AUTH_STATUS="$(sed -n 's/^status: //p' <<<"$out" | head -1)"
  FM_AUTH_EN="$(sed -n 's/^en: //p' <<<"$out" | head -1)"
  FM_AUTH_TW="$(sed -n 's/^tw: //p' <<<"$out" | head -1)"
}

# fm_auth_quota_reset <text> -> the reset-time phrase a vendor's own quota
# message names ("resets at 3pm", "try again in 45 minutes"), or nothing.
# fm-auth-probe.sh never calls this: its own contract is to never echo the
# vendor's output, so its quota-exhausted reason stays generic. This is for
# `fm doctor --sandbox`'s summary of a real canary round instead, which
# already carries a bounded tail of the vendor's own log in its "why"
# field (bin/fm-canary.sh) - never the whole message, just whatever short
# phrase after "reset"/"try again"/"available again" looks like a time, so
# the fix line says when, not everything the vendor printed.
fm_auth_quota_reset() {
  # No \n in the bracket expression: BSD grep (macOS) does not treat it as
  # a newline there, it excludes the literal character 'n' instead, which
  # cut "minutes" short at "mi" the first time this ran. grep already reads
  # one line at a time, so excluding '.', ',' and ';' is enough.
  grep -oiE '(quota |rate.?limit )?resets?[^.,;]{0,50}|try again in[^.,;]{0,50}|available again[^.,;]{0,50}' \
    <<<"${1-}" | head -1
}

# fm_auth_refuses <status> -> 0 for every answer but `authenticated`: only
# a login the vendor's own status check confirmed is usable (T-121's
# acceptance). `indeterminate` and `timeout` mean the probe could not tell,
# and are never read as authenticated - so gemini, which has no documented
# status command, is refused until its login can be verified.
# `unavailable` (not installed), an unknown word and no answer at all are
# refused the same way.
fm_auth_refuses() {
  [ "${1:-}" != authenticated ]
}

# fm_auth_filter_chain <code-root> <chain> <notes-file> -> prints, on
# stdout, the chain with every vendor the probe knows (fm_vendors) removed
# unless its probe answers `authenticated`. A vendor it does not know -
# mock, or a config typo fm_run_chain already reports as FM_VENDOR_UNKNOWN -
# passes through unprobed. Writes one "vendor|status|en|tw" line per
# refused vendor to <notes-file>, truncating it first, so the caller can
# put each on the board as vendor_unavailable; called through a command
# substitution, so anything this function hands back leaves through stdout
# or a file, never a variable. A chain with nothing left in it reaches
# fm_run_chain empty, which already returns "every vendor was unavailable"
# on its own.
fm_auth_filter_chain() {
  local root="$1" chain="$2" notes_file="$3" v auth_kept=()
  : > "$notes_file"
  for v in $chain; do
    if ! grep -qxF -- "$v" <<<"$(fm_vendors)"; then
      auth_kept+=("$v"); continue
    fi
    fm_auth_probe "$root" "$v"
    if fm_auth_refuses "$FM_AUTH_STATUS"; then
      printf '%s|%s|%s|%s\n' "$v" "${FM_AUTH_STATUS:-no answer}" \
        "${FM_AUTH_EN:-the login probe did not answer, so rounds on it are refused}" \
        "${FM_AUTH_TW:-登入探測沒有回應，因此拒絕在其上執行回合}" >> "$notes_file"
      continue
    fi
    auth_kept+=("$v")
  done
  [ "${#auth_kept[@]}" -eq 0 ] || printf '%s\n' "${auth_kept[@]}"
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

# --- the round's permission policy (T-105, T-117) --------------------------
# Every round runs under one policy fm owns, per role: fm_policy in
# bin/fm-config.sh resolves it from config.yaml, fm-worker.sh and
# fm-review.sh hand it over as FM_POLICY, and nothing about it comes from
# the operator's own CLI settings. Each adapter translates it into its CLI's
# flags and says which dimensions those flags enforce; bin/fm-sandbox.sh
# enforces what it can of the rest from outside the CLI. A dimension that
# neither enforces refuses the round with 2, before the CLI starts, so the
# fallback chain moves on and no round runs less confined than its policy.
#
# The one exception is the operator's escape hatch (design 13.1):
# fm-worker.sh and fm-review.sh set FM_ROUND_UNSANDBOXED=1 only when the
# operator's own shell says FM_CREW_UNSANDBOXED=1 and they are not
# themselves inside a round. Then the round runs without the OS sandbox -
# claude's, codex's and cursor-agent's own sandboxes on (gemini runs with
# none: the adapter never turns its container or seatbelt on), the scrub, the ulimits and the login as ever - and
# says so on stderr. fm-sandbox.sh marks every round with
# FM_IN_ROUND=1 and scrubs both names, so a round never reaches it.
FM_POLICY_DIMENSIONS="write read network sockets env repo-config refuse ulimit"
_fm_engine="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# fm_adapter_policy -> FM_POLICY, FM_POLICY_HOSTS, FM_OUTER_OS, FM_OUTER_DIMS,
# FM_UNSANDBOXED.
# An adapter reached without a policy - by hand, or by a caller that does
# not know about one - resolves the repository's settings for its role.
# shellcheck disable=SC2034  # read by the adapter that sourced this
fm_adapter_policy() {
  local f
  if [ -n "${FM_POLICY:-}" ]; then
    [ -r "$FM_POLICY" ] || { echo "adapter: no policy at $FM_POLICY; refusing an unconfined round" >&2; exit 65; }
  else
    f="$(mktemp "${TMPDIR:-/tmp}/fm-policy.XXXXXX")" || exit 70
    # shellcheck disable=SC2016  # expanded by the inner shell
    bash -c '. "$1/bin/fm-config.sh" && fm_policy "$2" "" "$3"' fm-policy \
      "$_fm_engine" "${FM_ROLE:-worker}" "$(fm_adapter_config)" > "$f" || {
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
  FM_UNSANDBOXED=''
  if [ "${FM_ROUND_UNSANDBOXED:-}" = 1 ]; then
    if [ -n "${FM_IN_ROUND:-}" ]; then
      echo "adapter: FM_ROUND_UNSANDBOXED is set inside a crew round; the escape hatch is the operator's, not a round's - ignoring it" >&2
    else
      FM_UNSANDBOXED=1
    fi
  fi
  if [ -n "$FM_UNSANDBOXED" ]; then
    # the vendors' own sandboxes come back on where the adapter has one to
    # turn on (claude, codex, cursor-agent): they are seatbelts that could
    # not nest inside the OS one, and now need not
    FM_OUTER_OS=''; FM_OUTER_DIMS=''
  else
    FM_OUTER_OS="$("$_fm_engine/bin/fm-sandbox.sh" os)"
    FM_OUTER_DIMS="$("$_fm_engine/bin/fm-sandbox.sh" covers --policy="$FM_POLICY")" || {
      echo "adapter: the policy at $FM_POLICY does not read" >&2; exit 65; }
    [ -n "$FM_OUTER_DIMS" ] || FM_OUTER_OS=''
  fi
  # The round's own temp directory, its TMPDIR from here on and its only
  # temp write root. The caller's TMPDIR is every round's, and run-mode
  # review checkouts are made in it; no round is given that.
  FM_ROUND_TMP="$(mktemp -d "${TMPDIR:-/tmp}/fm-round.XXXXXX")" || {
    echo "adapter: cannot make the round's temp directory" >&2; exit 70; }
  FM_ROUND_TMP="$(cd "$FM_ROUND_TMP" && pwd -P)"
  # Beside it, out of the round's reach: where the sandbox says it started
  # the CLI (fm_adapter_confine, fm_adapter_verdict), and the vendor's
  # login it hands in.
  FM_ROUND_CTL="$(mktemp -d "${TMPDIR:-/tmp}/fm-ctl.XXXXXX")" || {
    rm -rf "$FM_ROUND_TMP"; echo "adapter: cannot make the round's control directory" >&2; exit 70; }
  # shellcheck disable=SC2064  # the paths are fixed now
  trap "rm -rf '$FM_ROUND_TMP' '$FM_ROUND_CTL'" EXIT
  # a signal becomes an EXIT path, or the round's directories outlive it
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  export TMPDIR="$FM_ROUND_TMP" TMP="$FM_ROUND_TMP" TEMP="$FM_ROUND_TMP"
  # The toolchain's caches (T-117). By default each lives under the
  # operator's home - bun's install cache, Playwright's browsers, npm's,
  # pip's, Go's, anything following XDG - where a round may neither read
  # nor write, so a round's `setup` or end-to-end check would be refused.
  # Each is pointed into the round's own temp directory, which is a write
  # root on both platforms and in both roles, whatever the caller or the
  # operator's shell set it to: an inherited value is a path the policy
  # never made writable. It goes when the round does, so no round reads a
  # cache another round wrote.
  local kv
  for kv in $FM_ROUND_CACHES; do
    export "${kv%%=*}=$FM_ROUND_TMP/cache/${kv#*=}"
  done
  # A normal environment besides (T-128): HOME and the three XDG variables
  # are set the same way, under FM_ROUND_TMP, by fm-sandbox.sh itself (both
  # `run` and `plain`) once it knows the round's --tmp, so the guarantee
  # holds whatever called it - this adapter layer, or a direct invocation.
}
# name=directory under the round's cache, for every toolchain cache a round
# is handed (fm_adapter_policy); tests/adapter-contract.test.sh checks each
# one against the generated profile and bwrap arguments
FM_ROUND_CACHES="XDG_CACHE_HOME=xdg BUN_INSTALL_CACHE_DIR=bun PLAYWRIGHT_BROWSERS_PATH=ms-playwright npm_config_cache=npm PIP_CACHE_DIR=pip GOCACHE=go-build GOMODCACHE=go-mod"

# fm_adapter_confine <vendor> <workdir> <dimension>... -> FM_LAUNCH, or exit 2.
# The dimensions are what the vendor's own flags enforce for this round.
# FM_LAUNCH is the words the CLI is started behind: the OS sandbox, or,
# only under the operator's hatch, the environment scrub, the ulimits and
# the vendor's login alone.
# shellcheck disable=SC2034  # read by the adapter that sourced this
fm_adapter_confine() {
  local vendor="$1" work="$2" have d missing=''
  if [ -z "${FM_UNSANDBOXED:-}" ]; then
    have=" ${*:3} $FM_OUTER_DIMS "
    for d in $FM_POLICY_DIMENSIONS; do
      case "$have" in *" $d "*) ;; *) missing="$missing $d" ;; esac
    done
  fi
  if [ -n "$missing" ]; then
    echo "$vendor: this round's policy needs$missing, which neither $vendor's own flags nor an OS sandbox enforce on this host; refusing the round" >&2
    exit 2
  fi
  # absolute: the adapter starts the CLI after changing into it
  work="$(cd "$work" 2>/dev/null && pwd -P)" || { echo "$vendor: no directory at $2" >&2; exit 64; }
  FM_LAUNCH=("$_fm_engine/bin/fm-sandbox.sh")
  FM_ROUND_STARTED="$FM_ROUND_CTL/started"
  # what the round sheds is no login of its own (T-121): fm-sandbox.sh
  # neither counts it as `given` nor lets it into the round
  local shed=() s
  while IFS= read -r s; do [ -n "$s" ] && shed+=(--shed="$s"); done < <(fm_adapter_shed "$vendor")
  if [ -n "$FM_OUTER_OS" ]; then
    FM_LAUNCH+=(run --policy="$FM_POLICY" --root="$work" --tmp="$FM_ROUND_TMP" --vendor="$vendor"
                --started="$FM_ROUND_STARTED" --ctl="$FM_ROUND_CTL" ${shed[@]+"${shed[@]}"})
    # the CLI's own final answer is written where the launcher reads it
    if [ "$vendor" != codex ] || [ "${FM_ROLE:-}" != reviewer ]; then
      [ -z "${FM_ATTEMPT_DIR:-}" ] || FM_LAUNCH+=(--write="$FM_ATTEMPT_DIR")
      [ -z "${FM_FINAL_PATH:-}" ] || FM_LAUNCH+=(--write="$(dirname "$FM_FINAL_PATH")")
    fi
    [ -z "${FM_POLICY_BLOCKED:-}" ] || FM_LAUNCH+=(--blocked="$FM_POLICY_BLOCKED")
  else
    echo "$vendor: !!! FM_CREW_UNSANDBOXED: this round runs WITHOUT the OS sandbox - reads, writes, the network and sockets are not confined by fm !!!" >&2
    FM_LAUNCH+=(plain --policy="$FM_POLICY" --tmp="$FM_ROUND_TMP" --vendor="$vendor"
                --started="$FM_ROUND_STARTED" --ctl="$FM_ROUND_CTL" ${shed[@]+"${shed[@]}"})
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

# --- the configured model (T-127) -----------------------------------------
# config.yaml's model is applied, not only recorded: fm-worker.sh and
# fm-review.sh resolve it and hand it in as FM_MODEL, and each adapter passes
# it with its own CLI's flag. A model the vendor does not recognise refuses
# the round with a usage error, loudly, rather than running on whatever the
# CLI happened to default to.
#
# Unlike _FM_SIG (an outage, which the caller's evidence predicate can still
# rescue - work beats a signature), a model refusal must never fire on a
# completed round: review round 5 found that a broad, generic phrase list run
# over the whole transcript regardless of exit code would misread a round
# that legitimately discussed "an invalid model" or "no such model found" -
# ordinary English in ORM/data-model/ML work, and, after this very task,
# in this codebase's own prose - as a hard configuration failure, discarding
# real work. So this checks three things _FM_SIG does not: the CLI's own
# exit code must be non-zero (a completed round, rc 0, is never read as a
# refusal), the slice must carry no `"model":"..."` field and no non-empty
# claude `"modelUsage"` at all (a report of the model actually used means a
# turn happened, whatever text comes after it), and, for the three vendors with no fixed token (below), the
# phrase must open the line it is found on - the shape a CLI's own one-line
# usage error has, and prose discussing models in passing does not ("Error:
# unrecognized model" opens a line; "...reviewed the invalid model names
# and..." does not). claude names its refusal exactly
# (`[claude-code:unrecognized_model]`), read literally, needing no such
# anchor; codex, cursor-agent and gemini have no such fixed token
# documented, so they are read against one generic, vendor-agnostic phrase
# list instead, the way _FM_SIG is for an outage - but anchored, since
# _FM_SIG's alternatives are each shaped like nothing else, and these
# ordinary phrases are not.
_FM_CLAUDE_MODEL_SIG='[claude-code:unrecognized_model]'
_FM_MODEL_SIG='unrecognized model|unrecognised model|unknown model|invalid model|not a valid model|no such model|model not found'

# fm_adapter_model_refusal <vendor> <model> <log> <off> <rc> -> a one-line
# message naming the vendor and the model when the CLI's own words, in the
# slice of the log this attempt wrote, say it did not recognise the model;
# nothing when it is silent on the question, an empty model asked for
# nothing, the attempt's exit code was 0 (a completed round), or the slice
# already reports a model that ran (real work, whatever came after it).
fm_adapter_model_refusal() {
  local vendor="$1" model="$2" log="$3" off="$4" rc="${5:-0}" said=''
  [ -n "$model" ] || return 1
  [ "$rc" != 0 ] || return 1
  [ -f "$log" ] && said="$(tail -c "+$((off + 1))" "$log" 2>/dev/null)"
  grep -q '"model"[[:space:]]*:[[:space:]]*"[^"]*"' <<< "$said" && return 1
  # claude's result names no "model": the models a turn ran on are the keys
  # of its modelUsage (T-146), and an empty one reports nothing that ran
  grep -q '"modelUsage"[[:space:]]*:[[:space:]]*{[[:space:]]*"' <<< "$said" && return 1
  case "$vendor" in
    claude) grep -qF "$_FM_CLAUDE_MODEL_SIG" <<< "$said" || return 1 ;;
    *)      grep -qiE "^[[:space:]]*error[:.]?[[:space:]].*($_FM_MODEL_SIG)" <<< "$said" || return 1 ;;
  esac
  printf "%s: model '%s' is not recognised by %s\n" "$vendor" "$model" "$vendor"
}

# fm_adapter_model_listcheck <vendor> <model> <list-cmd...> -> a one-line
# message naming the vendor and the model when the vendor's own "list the
# models" command runs, says something, and names none of them <model>
# (checked against the first column of each line, "id - Name", the shape
# cursor-agent's own `--list-models` prints); nothing when the list command
# itself could not be run, exited non-zero, or printed nothing - no login,
# no catalogue reachable offline - so a round is never refused by a check
# that could not actually ask the vendor. This runs before the round, on a
# lightweight call that touches no worktree - unlike
# fm_adapter_model_refusal, which reads the real round's own transcript
# after the fact. The call is given no stdin (nothing is waiting to answer a
# prompt it never asked) and a deadline (an unauthenticated CLI that waits on
# the network or a login prompt must never hang a round that has not even
# started): perl's alarm, since `timeout` is not on every platform this
# runs on; a run past the deadline is exactly "could not be run", silent.
#
# Consumes its own two positional arguments as two single shifts, not one
# `shift 2`: this is a library helper, never an option loop reading a
# round's command line, and a literal `shift 2` pulls this file into the
# option-loop lint's own pinned corpus (tests/option-loop.test.sh, out of
# this task's scope) for a shape that lint was never written to check.
fm_adapter_model_listcheck() {
  local vendor="$1" model="$2" out rc line id
  [ "$#" -ge 2 ] || return 1
  shift; shift
  [ -n "$model" ] || return 1
  out="$(FM_MODEL_LISTCHECK_SECS="${FM_MODEL_LISTCHECK_SECS:-10}" \
    perl -e 'alarm $ENV{FM_MODEL_LISTCHECK_SECS}; exec @ARGV or exit 127' "$@" 2>/dev/null </dev/null)"
  rc=$?
  [ "$rc" -eq 0 ] && [ -n "$out" ] || return 1
  while IFS= read -r line; do
    id="${line%% - *}"
    id="$(printf '%s' "$id" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$id" ] && [ "$id" = "$model" ] && return 1
  done <<< "$out"
  printf "%s: model '%s' is not one %s's own model list names\n" "$vendor" "$model" "$vendor"
}

# fm_adapter_model_args <flag> -> "$flag" "$FM_MODEL" when a model is
# configured, nothing otherwise; the words to splice into a CLI's own argv.
fm_adapter_model_args() {
  [ -n "${FM_MODEL:-}" ] || return 0
  printf '%s\n%s\n' "$1" "$FM_MODEL"
}

# Managed Codex: item payloads are model/tool content, never provider errors.
# Read only this invocation's bytes; final.txt and prior receipts are not inputs.
# Reuse the transport's completed-turn reader, without writing any receipt or
# final answer. The temporary slice belongs to the adapter outside the model.
fm_adapter_codex_verdict() {
  python3 - "$_fm_engine" "$1" "$2" "$3" "$_FM_SIG" "$FM_ROUND_CTL" <<'PY'
import importlib.util, json, pathlib, re, sys, tempfile
sys.dont_write_bytecode = True
root, rc, log, offset, signature, control = sys.argv[1:]
rc = int(rc)
try:
    with open(log, 'rb') as source:
        source.seek(int(offset))
        text = source.read().decode('utf-8')
except (OSError, ValueError, UnicodeError):
    sys.exit(2 if rc in (2, 4, 41, 69, 75) else 1)
failed = malformed = unavailable = False
for line in text.splitlines():
    if not line.strip(): continue
    try:
        event = json.loads(line)
    except ValueError:
        # Broken JSON is not a CLI diagnostic, and cannot rescue a truncated
        # transcript even if an earlier turn completed successfully.
        if line.lstrip().startswith(('{', '[')):
            malformed = True
        elif re.search(signature, line, re.I):
            unavailable = True
        continue
    if not isinstance(event, dict) or not isinstance(event.get('type'), str):
        malformed = True
        continue
    if event['type'] in ('error', 'turn.failed'):
        failed = True
        diagnostic = json.dumps({key: event[key] for key in ('message', 'error') if key in event})
        if re.search(signature, diagnostic, re.I): unavailable = True
if unavailable or rc in (2, 4, 41, 69, 75): sys.exit(2)
if rc != 0 or failed or malformed: sys.exit(1)
spec = importlib.util.spec_from_file_location('managed', pathlib.Path(root) / 'bin/fm-herdr.py')
managed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(managed)
with tempfile.TemporaryDirectory(prefix='fm-codex-verdict-', dir=control) as directory:
    current = pathlib.Path(directory) / 'current.jsonl'
    current.write_text(text)
    answer = managed.cli_final('codex', current)
sys.exit(0 if answer is not None and answer.strip() else 1)
PY
}

# fm_adapter_verdict <rc> <log> <offset> [vendor] -> 0 done / 1 unfit / 2 unavailable
fm_adapter_verdict() {
  local rc="$1" log="$2" off="$3" said=''
  [ -z "${FM_ATTEMPT_DIR:-}" ] || printf '%s\n' "${FM_CLI_EXIT:-$rc}" > "$FM_ATTEMPT_DIR/cli-exit-code"
  [ -f "$log" ] && said="$(tail -c "+$((off + 1))" "$log" 2>/dev/null)"
  # The sandbox never got as far as the CLI: the vendor's login was not
  # there, or its proxy, its profile, the process count or the sandbox
  # binary failed, and the exit code is the launcher's. That is this host
  # failing this vendor, not a model giving up, so the chain moves on to
  # the next vendor (T-105).
  if [ -n "${FM_ROUND_STARTED:-}" ] && ! grep -qx started "$FM_ROUND_STARTED" 2>/dev/null; then
    echo "adapter: the OS sandbox did not start the CLI (exit $rc); counting the vendor unavailable" >&2
    return 2
  fi

  if [ "${4:-}" = codex ] && [ -n "${FM_ATTEMPT_DIR:-}" ]; then
    fm_adapter_codex_verdict "$rc" "$log" "$off"
    return $?
  fi

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
