#!/usr/bin/env bash
# claude adapter. Hands the prompt to claude and maps its outcome onto the
# contract in _contract.md. It must never touch git or gh: the scripts above
# do all of that, which is what lets a CLI with no repository access still be
# a worker.
#
# The invocation is the non-interactive one on purpose. An adapter that opens
# a REPL hangs a dispatch until something kills it, and looks like a model
# thinking rather than a script waiting for a human who is not there.
set -uo pipefail
_fm_alib="$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
[ -r "$_fm_alib" ] || { echo "claude: missing $_fm_alib" >&2; exit 70; }
# shellcheck source=bin/adapters/_lib.sh
. "$_fm_alib"
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
# A worker has to be able to edit files in its own worktree, and nobody is
# there to answer a prompt. acceptEdits is the least that allows the work:
# it accepts file edits and still asks about everything else - which the
# adapter never needs, because the scripts do all the git and gh.
work="$tree"; mode=(--permission-mode acceptEdits); launch=()
# fm:review-run
# A run-mode reviewer works in fm-review.sh's checkout and may run commands
# there, so the confinement is claude's own, not the prompt's:
#   - --restricted loads no user, project or local settings. Rules merge
#     across those sources and the checkout IS the branch under review, so
#     its .claude/ (hooks, allow rules, sandbox exclusions, extra directories)
#     and the operator's ~/.claude would otherwise join the round; only the
#     --settings below and managed policy apply. --strict-mcp-config and
#     --disable-slash-commands do the same for MCP servers and skills;
#   - --tools names the only tools, and the file tools reach only the working
#     directory and --add-dir: the checkout and the temp directory;
#   - dontAsk denies every tool call no rule below allows;
#   - shell commands are allowed only inside claude's sandbox, which confines
#     their writes to the working directory and their network to the domains
#     config.yaml's `reviewer: network:` declares - none by default. Settings
#     that fail validation are dropped silently under -p, and then nothing
#     allows a shell command at all: that failure closes rather than opens.
# What stops a push is that the clone has no remote and the sandbox reaches
# no GitHub host. The deny list below is a second guard that matches only a
# command's literal prefix (`env git push` is not `git push`); the
# confinement does not rest on it.
if [ "${FM_RUN_REVIEW:-}" = 1 ]; then
  # operator arguments come after these and the last value wins, so one that
  # touches permissions or what is loaded would quietly undo the confinement
  case " ${FM_ADAPTER_ARGS:-} " in
    *-permission*|*--allow*|*--setting*|*--add-dir*|*--tools*|*--disallow*|*--mcp*|*--plugin*|*--agents*|*--bare*)
      echo "claude: FM_ADAPTER_ARGS changes permissions; refusing a run-mode review" >&2; exit 64 ;;
  esac
  work="$(fm_adapter_review_checkout)" || exit 64
  tmp="$(fm_adapter_rule_path "${TMPDIR:-/tmp}")" || exit 64
  # each name goes into the settings string verbatim, so anything but a
  # plain domain name is refused rather than escaped. Split with read: an
  # unquoted expansion also globs, and `*` would pass as the file names here
  hosts=(); net=()
  read -r -a net <<<"${FM_REVIEW_NETWORK:-}"
  for h in ${net[@]+"${net[@]}"}; do
    case "$h" in
      *[!A-Za-z0-9.-]*|.*|*.) echo "claude: '$h' in reviewer network is not a domain name" >&2; exit 64 ;;
    esac
    hosts+=("$h")
  done
  allow=(Grep Glob "Read(/$work/**)" "Edit(/$work/**)" "Write(/$work/**)"
         "Read(/$tmp/**)" "Edit(/$tmp/**)" "Write(/$tmp/**)")
  deny=("Bash(git push:*)" "Bash(git remote:*)" "Bash(git worktree:*)" "Bash(git -C:*)"
        "Bash(gh pr comment:*)" "Bash(gh pr review:*)" "Bash(gh pr edit:*)" "Bash(gh pr merge:*)"
        "Bash(gh pr create:*)" "Bash(gh pr close:*)" "Bash(gh pr reopen:*)" "Bash(gh pr ready:*)"
        "Bash(gh issue:*)" "Bash(gh api:*)" "Bash(gh repo:*)" "Bash(gh release:*)"
        "Bash(gh workflow:*)" "Bash(gh run rerun:*)" "Bash(gh run cancel:*)" "Bash(gh secret:*)"
        "Bash(gh variable:*)" "Bash(gh label:*)" "Bash(gh gist:*)" "Bash(gh auth:*)"
        "Bash(curl:*)" "Bash(wget:*)")
  rules() { local r s=''; for r in "$@"; do s="$s${s:+,}\"$r\""; done; printf '%s' "$s"; }
  settings="{\"permissions\":{\"defaultMode\":\"dontAsk\",\"allow\":[$(rules "${allow[@]}")],\"deny\":[$(rules "${deny[@]}")]},\"sandbox\":{\"enabled\":true,\"autoAllowBashIfSandboxed\":true,\"allowUnsandboxedCommands\":false,\"network\":{\"allowedDomains\":[$(rules ${hosts[@]+"${hosts[@]}"})]}}}"
  mode=(--restricted --strict-mcp-config --disable-slash-commands
        --tools "Bash,Read,Edit,Write,Grep,Glob" --add-dir "$tmp"
        --permission-mode dontAsk --settings "$settings"
        --allowedTools "${allow[@]}" --disallowedTools "${deny[@]}")
  # the commands the reviewer runs inherit claude's environment, so the
  # launcher's FM_ROOT and friends are dropped here (see _lib.sh)
  launch=(); while IFS= read -r w; do launch+=("$w"); done < <(fm_adapter_review_env)
fi
if [ -n "${FM_ATTEMPT_DIR:-}" ]; then
  ( cd "$work" && ${launch[@]+"${launch[@]}"} claude -p "${mode[@]}" --output-format json ${FM_ADAPTER_ARGS:-} < "$prompt" ) 2>&1 | tee -a "$log"
  fm_adapter_pipeline_status "${PIPESTATUS[@]}"
else
  ( cd "$work" && ${launch[@]+"${launch[@]}"} claude -p "${mode[@]}" ${FM_ADAPTER_ARGS:-} < "$prompt" ) >> "$log" 2>&1
fi
rc=$?
fm_adapter_verdict "$rc" "$log" "$off"
exit $?
