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
# it refuses; fm's proxy is the one that names a blocked host.
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
esac
fm_adapter_policy
# A worker edits its worktree; a reviewer works in its output directory, or
# in run mode in fm-review.sh's checkout.
work="$(fm_adapter_rule_path "$tree")" || exit 64; launch=()
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
#
# On macOS claude keeps its login in the keychain, which the OS sandbox
# keeps out of every round's reach because gh's token is kept there too.
# There a round signs in with CLAUDE_CODE_OAUTH_TOKEN (`claude
# setup-token`) or ANTHROPIC_API_KEY from the environment; without either,
# claude says it is not logged in and the chain moves on.
if [ "${FM_RUN_REVIEW:-}" = 1 ]; then
  work="$(fm_adapter_review_checkout)" || exit 64
  # the commands the reviewer runs inherit claude's environment, so the
  # launcher's FM_ROOT and friends are dropped here (see _lib.sh)
  while IFS= read -r w; do launch+=("$w"); done < <(fm_adapter_review_env)
fi
tmp="$(fm_adapter_rule_path "${TMPDIR:-/tmp}")" || exit 64
# the shell runs under the OS sandbox, which is what confines it
allow=(Grep Glob Bash "Read(/$work/**)" "Edit(/$work/**)" "Write(/$work/**)"
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
# every other path unreadable
while IFS= read -r p; do
  case "$p" in /*) ;; *) continue ;; esac
  case "$p" in *[[:space:]\"\\*\(\),]*) continue ;; esac
  deny+=("Read(/$p/**)" "Read(/$p)")
done < <(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["never_read"]))' "$FM_POLICY")
rules() { local r s=''; for r in "$@"; do s="$s${s:+,}\"$r\""; done; printf '%s' "$s"; }
# claude's own sandbox is off: the OS sandbox around claude confines every
# command (see claude_native), and the deny rules stay
settings="{\"permissions\":{\"defaultMode\":\"dontAsk\",\"allow\":[$(rules "${allow[@]}")],\"deny\":[$(rules "${deny[@]}")]},\"sandbox\":{\"enabled\":false}}"
mode=(--restricted --strict-mcp-config --disable-slash-commands
      --tools "Bash,Read,Edit,Write,Grep,Glob" --add-dir "$tmp"
      --permission-mode dontAsk --settings "$settings"
      --allowedTools "${allow[@]}" --disallowedTools "${deny[@]}")
read -r -a native <<<"$(claude_native)"
fm_adapter_confine claude "$work" "${native[@]}"
if [ -n "${FM_ATTEMPT_DIR:-}" ]; then
  ( cd "$work" && "${FM_LAUNCH[@]}" ${launch[@]+"${launch[@]}"} claude -p "${mode[@]}" --output-format json ${FM_ADAPTER_ARGS:-} < "$prompt" ) 2>&1 | tee -a "$log"
  fm_adapter_pipeline_status "${PIPESTATUS[@]}"
else
  ( cd "$work" && "${FM_LAUNCH[@]}" ${launch[@]+"${launch[@]}"} claude -p "${mode[@]}" ${FM_ADAPTER_ARGS:-} < "$prompt" ) >> "$log" 2>&1
fi
rc=$?
fm_adapter_verdict "$rc" "$log" "$off"
exit $?
