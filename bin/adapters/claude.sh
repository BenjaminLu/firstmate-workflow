#!/usr/bin/env bash
# claude adapter. Hands the prompt to claude and maps its outcome onto the
# contract in _contract.md. It must never touch git or gh: the scripts above
# do all of that, which is what lets a CLI with no repository access still be
# a worker.
#
# The invocation is the non-interactive one on purpose. An adapter that opens
# a REPL hangs a dispatch until something kills it, and looks like a model
# thinking rather than a script waiting for a human who is not there.
#
#   claude.sh run <prompt> <worktree> <log>
#   claude.sh dimensions    -> which policy dimensions claude's own flags enforce here
set -uo pipefail
_fm_alib="$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
[ -r "$_fm_alib" ] || { echo "claude: missing $_fm_alib" >&2; exit 70; }
# shellcheck source=bin/adapters/_lib.sh
. "$_fm_alib"

# What claude's own flags enforce of the round's policy (T-105): the deny
# rules refuse the operations the policy names; --restricted,
# --strict-mcp-config and --disable-slash-commands keep the repository's
# .claude/ and .mcp.json and the operator's ~/.claude out; the launcher
# scrubs the environment and sets the ulimits. Reading is not among them:
# claude can deny paths, not deny everything but a few, so the OS sandbox
# is what makes reads default-deny, and no round runs without it.
#
# claude's own sandbox is off inside the OS sandbox, on both platforms. On
# macOS it is a seatbelt, and a seatbelt cannot be applied inside another.
# On Linux its commands would reach the network through claude's own proxy,
# which has no way out of the round's network namespace and records no host
# it refuses; fm's proxy is the one that names a blocked host. Under the
# operator's hatch, with no OS sandbox around claude, its own is back on.
claude_native() { echo "refuse repo-config env ulimit"; }
if [ "${1-}" = "dimensions" ]; then
  fm_adapter_policy; read -r -a native <<<"$(claude_native)"
  fm_adapter_dimensions "${native[@]}"; exit 0
fi

[ "${1-}" = "run" ] || { echo "usage: claude.sh run <prompt> <worktree> <log>" >&2; exit 64; }
prompt="${2-}"; tree="${3-}"; log="${4-}"
[ -f "$prompt" ] || { echo "claude: no prompt at $prompt" >&2; exit 64; }
[ -d "$tree" ]   || { echo "claude: no worktree at $tree" >&2; exit 64; }
fm_adapter_context "$0"

command -v claude >/dev/null 2>&1 || {
  # stderr, not the log: the log is what the VENDOR said, and a caller that
  # asks "did anything run?" must not be answered by the adapter's own
  # notice that nothing could
  echo "claude: claude is not installed - vendor unavailable" >&2; exit 2; }

# FM_ADAPTER_ARGS is deliberately unquoted: it carries whatever extra
# arguments the operator configured, and they have to split into words.
off="$(fm_adapter_mark "$log")"
# operator arguments come after these and the last value wins, so one that
# touches permissions or what is loaded would quietly undo the policy - in
# every round now, not only a run-mode review (T-105)
case " ${FM_ADAPTER_ARGS:-} " in
  *-permission*|*--allow*|*--setting*|*--add-dir*|*--tools*|*--disallow*|*--mcp*|*--plugin*|*--agents*|*--bare*|*--sandbox*)
    echo "claude: FM_ADAPTER_ARGS changes permissions; refusing the round" >&2; exit 64 ;;
  # config.yaml's model is the one place a model is chosen (T-127); an
  # operator argument after it would win and quietly run on another model
  *--model*|*--fallback-model*)
    echo "claude: FM_ADAPTER_ARGS names a model; config.yaml is the one place a model is chosen; refusing the round" >&2; exit 64 ;;
esac
fm_adapter_policy
# A worker edits its worktree; a reviewer works in its output directory, or
# in run mode in fm-review.sh's checkout.
work="$(fm_adapter_rule_path "$tree")" || exit 64; launch=()
# The credentials that outrank the subscription login (T-121): unset unless
# the operator named claude in config.yaml's billing: block, so
# CLAUDE_CODE_OAUTH_TOKEN - the one token this design hands a round - is the
# only claude credential a round ever sees.
CLAUDE_OUTRANKING=(); while IFS= read -r w; do CLAUDE_OUTRANKING+=("$w"); done < <(fm_adapter_outranking claude)
while IFS= read -r w; do launch+=("$w"); done < <(fm_adapter_env_words claude "${CLAUDE_OUTRANKING[@]}")
# fm:review-run
# Every round's confinement is claude's own, not the prompt's, and it is the
# settings T-066 built for a run-mode review, now given every round:
#   - --restricted loads no user, project or local settings. Rules merge
#     across those sources and the worktree or checkout IS the branch, so
#     its .claude/ (hooks, allow rules, sandbox exclusions, extra directories)
#     and the operator's ~/.claude would otherwise join the round; only the
#     --settings below and managed policy apply. --strict-mcp-config and
#     --disable-slash-commands do the same for MCP servers and skills;
#   - --tools names the only tools, and the file tools reach only the working
#     directory and --add-dir: the worktree or checkout, and the temp directory;
#   - dontAsk denies every tool call no rule below allows;
#   - shell commands are allowed because they run inside the OS sandbox
#     fm-sandbox.sh puts around claude itself, which confines their writes
#     to the working directory and the round's temp directory and their
#     network to the registries the policy declares - none by default, never
#     a GitHub host or loopback. Settings that fail validation are dropped
#     silently under -p, and then nothing allows a shell command at all:
#     that failure closes rather than opens.
# What stops a push is that the sandbox reaches no GitHub host, and in run
# mode that the clone has no remote. The deny list below is a second guard
# that matches only a command's literal prefix (`env git push` is not `git
# push`); the confinement does not rest on it.
if [ "${FM_RUN_REVIEW:-}" = 1 ]; then
  work="$(fm_adapter_review_checkout)" || exit 64
fi
tmp="$(fm_adapter_rule_path "${TMPDIR:-/tmp}")" || exit 64
# claude's own state and temp directories are the round's (T-117). Its
# config directory - its .claude.json, sessions, todos and caches - is one
# of the round's own, in its temp directory, so the operator's ~/.claude
# and ~/.claude.json are never opened; and its temp files go to the
# round's temp directory where claude honours CLAUDE_CODE_TMPDIR. What it
# keeps under /tmp/claude-<uid> whatever that says is the policy's `tmp`
# for claude. Its login (T-126) is, in order: a CLAUDE_CODE_OAUTH_TOKEN
# already set, used as is - or an ANTHROPIC_API_KEY, but only when the
# operator chose api-key billing in config.yaml (T-121): otherwise it is shed
# above, and fm-sandbox.sh does not count it as the round's login either,
# since the round would never see it; else the crew's own long-lived
# token (`claude setup-token`), which fm-sandbox.sh reads outside the round
# from a keychain item of fm's own on macOS, else, when secret-tool
# (libsecret) is present, the same item through it (T-126 round 2), else a
# file only the operator may read, and hands in as CLAUDE_CODE_OAUTH_TOKEN;
# only with none of those does it fall back to the access token of the
# operator's own interactive login as before T-126 - keychain on macOS, the
# credentials file elsewhere - which warns, because that can die whenever
# the operator's own login refreshes it.
CLAUDE_CONFIG_DIR="$FM_ROUND_TMP/claude-config"
mkdir -p "$CLAUDE_CONFIG_DIR" || exit 70
CLAUDE_CODE_TMPDIR="$FM_ROUND_TMP"
# claude's own quiet-refusals switch (documented by claude): turns off its
# non-essential network traffic - telemetry and error reporting - so a round
# no longer has the proxy refuse a host like
# http-intake.logs.us5.datadoghq.com and report it as one the project's
# network policy must add (T-123). The proxy's own refusal is unchanged for
# anything this does not cover; this is claude's alone, never another
# vendor's environment.
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CONFIG_DIR CLAUDE_CODE_TMPDIR CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
allow=(Grep Glob "Read(/$work/**)" "Edit(/$work/**)" "Write(/$work/**)"
       "Read(/$tmp/**)" "Edit(/$tmp/**)" "Write(/$tmp/**)")
deny=("Bash(git push:*)" "Bash(git remote:*)" "Bash(git worktree:*)" "Bash(git -C:*)"
      "Bash(gh:*)" "Bash(gh pr comment:*)" "Bash(gh pr review:*)" "Bash(gh pr edit:*)" "Bash(gh pr merge:*)"
      "Bash(gh pr create:*)" "Bash(gh pr close:*)" "Bash(gh pr reopen:*)" "Bash(gh pr ready:*)"
      "Bash(gh issue:*)" "Bash(gh api:*)" "Bash(gh repo:*)" "Bash(gh release:*)"
      "Bash(gh workflow:*)" "Bash(gh run rerun:*)" "Bash(gh run cancel:*)" "Bash(gh secret:*)"
      "Bash(gh variable:*)" "Bash(gh label:*)" "Bash(gh gist:*)" "Bash(gh auth:*)"
      "Bash(herdr:*)" "Bash(open:*)" "Bash(xdg-open:*)" "Bash(osascript:*)"
      "Bash(curl:*)" "Bash(wget:*)")
# the never-readable paths, as rules too: the OS sandbox is what makes
# every other path unreadable. A never_read path that CONTAINS the
# round's own work or temp directory - state, on the self project, whose
# own state/worktrees/<task> is a worker's tree, or a reviewer's
# checkout - must not become a blanket deny of everything under it: a
# deny beats the Read(/$work/**) / Read(/$tmp/**) allow rules above in
# claude's own rule order, so denying the ancestor denies the round's
# own tree too (T-123, found by a live reviewer whose own checkout was
# refused this way under main's policy). fm_adapter_carve_deny walks
# from that ancestor down to the protected directory and denies every
# other entry at each level instead - state/runs/**, state/events.jsonl,
# every other worktree - and never the branch that leads to $work or
# $tmp themselves.
fm_adapter_carve_deny() {
  local anc="$1" protect="$2" cur seg entry other
  cur="$anc"
  if [ "$protect" = "$work" ]; then other="$tmp"; else other="$work"; fi
  while [ "$cur" != "$protect" ]; do
    case "$protect" in "$cur"/*) ;; *) return 0 ;; esac
    seg="${protect#"$cur"/}"; seg="${seg%%/*}"
    while IFS= read -r entry; do
      [ "${entry##*/}" = "$seg" ] && continue
      case "$entry" in *[[:space:]\"\\*\(\),]*) continue ;; esac
      case "$other" in "$entry") continue ;; "$entry"/*) continue ;; esac
      case "$entry" in "$other"/*) continue ;; esac
      deny+=("Read(/$entry/**)" "Read(/$entry)")
    done < <(find "$cur" -mindepth 1 -maxdepth 1 2>/dev/null)
    cur="$cur/$seg"
  done
}
while IFS= read -r p; do
  case "$p" in /*) ;; *) continue ;; esac
  case "$p" in *[[:space:]\"\\*\(\),]*) continue ;; esac
  carved=''
  case "$work" in "$p"|"$p"/*) fm_adapter_carve_deny "$p" "$work"; carved=1 ;; esac
  case "$tmp" in "$p"|"$p"/*) fm_adapter_carve_deny "$p" "$tmp"; carved=1 ;; esac
  [ -n "$carved" ] && continue
  deny+=("Read(/$p/**)" "Read(/$p)")
done < <(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["never_read"]))' "$FM_POLICY")
rules() { local r s=''; for r in "$@"; do s="$s${s:+,}\"$r\""; done; printf '%s' "$s"; }
if [ -n "${FM_UNSANDBOXED:-}" ]; then
  # The operator's hatch (T-117): no OS sandbox around claude, so its own
  # comes back on with T-066's settings - every shell command inside it,
  # none let out of it, its network the policy's registries and nothing
  # else. Bash is then allowed only because it is sandboxed, not by a rule.
  hosts=(); read -r -a hosts <<<"${FM_POLICY_HOSTS:-}"
  sandbox="{\"enabled\":true,\"autoAllowBashIfSandboxed\":true,\"allowUnsandboxedCommands\":false,\"network\":{\"allowedDomains\":[$(rules ${hosts[@]+"${hosts[@]}"})]}}"
else
  # claude's own sandbox is off: the OS sandbox around claude confines
  # every command (see claude_native), so the shell is allowed, and the
  # deny rules stay
  sandbox='{"enabled":false}'
  allow=(Bash "${allow[@]}")
fi
settings="{\"permissions\":{\"defaultMode\":\"dontAsk\",\"allow\":[$(rules "${allow[@]}")],\"deny\":[$(rules "${deny[@]}")]},\"sandbox\":$sandbox}"
# --output-format json always, not only when a managed attempt reads the
# final answer from it (T-127): it is also how the round's own model comes
# back, for the run's record - as the keys of the result message's
# "modelUsage", which names no "model" field (T-146; fm_vendor_model).
mode=(--restricted --strict-mcp-config --disable-slash-commands
      --tools "Bash,Read,Edit,Write,Grep,Glob" --add-dir "$tmp"
      --permission-mode dontAsk --settings "$settings" --output-format json
      --allowedTools "${allow[@]}" --disallowedTools "${deny[@]}")
# config.yaml's model, applied with claude's own flag (T-127); FM_ADAPTER_ARGS
# may not name one (refused above), so this is the one place it comes from
model_args=(); while IFS= read -r _fm_ma; do model_args+=("$_fm_ma"); done \
  < <(fm_adapter_model_args --model)
read -r -a native <<<"$(claude_native)"
fm_adapter_confine claude "$work" "${native[@]}"
if [ -n "${FM_ATTEMPT_DIR:-}" ]; then
  ( cd "$work" && "${FM_LAUNCH[@]}" ${launch[@]+"${launch[@]}"} claude -p "${mode[@]}" \
    ${model_args[@]+"${model_args[@]}"} ${FM_ADAPTER_ARGS:-} < "$prompt" ) 2>&1 | tee -a "$log"
  fm_adapter_pipeline_status "${PIPESTATUS[@]}"
  rc=$?
else
  # stderr goes to the log, as it always has; the launcher's own lines
  # (`fm-sandbox: ...`, which carry the login-fallback warning) are also
  # said on the adapter's stderr, so a caller sees them on every OS. The
  # file sits in the round's control directory, out of the round's reach,
  # which fm_adapter_policy already made or refused the round over; a file
  # that still cannot be made there refuses the round too, rather than
  # dropping its stderr (T-126 round 7).
  errs="$FM_ROUND_CTL/claude-stderr"
  : > "$errs" || { echo "claude: cannot keep the round's stderr at $errs; refusing the round" >&2; exit 70; }
  ( cd "$work" && "${FM_LAUNCH[@]}" ${launch[@]+"${launch[@]}"} claude -p "${mode[@]}" \
    ${model_args[@]+"${model_args[@]}"} ${FM_ADAPTER_ARGS:-} < "$prompt" ) >> "$log" 2> "$errs"
  rc=$?
  cat "$errs" >> "$log"
  grep '^fm-sandbox: ' "$errs" >&2 || true
  rm -f "$errs"
fi
# A model claude does not recognise refuses the round loudly (T-127), rather
# than running silently on whatever it defaulted to: not vendor-unavailable
# (which would fall back to the next one) and not a normal failed attempt.
msg="$(fm_adapter_model_refusal claude "${FM_MODEL:-}" "$log" "$off" "$rc")" && {
  echo "$msg; refusing the round" >&2
  [ -z "${FM_MODEL_REFUSED:-}" ] || printf 'claude\t%s\t%s\n' "$FM_MODEL" "$msg" >> "$FM_MODEL_REFUSED"
  exit 64
}
fm_adapter_verdict "$rc" "$log" "$off"
exit $?
