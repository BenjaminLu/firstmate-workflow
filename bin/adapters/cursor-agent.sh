#!/usr/bin/env bash
# cursor-agent adapter. Hands the prompt to cursor-agent and maps its outcome onto the
# contract in _contract.md. It must never touch git or gh: the scripts above
# do all of that, which is what lets a CLI with no repository access still be
# a worker.
#
# The invocation is the non-interactive one on purpose. An adapter that opens
# a REPL hangs a dispatch until something kills it, and looks like a model
# thinking rather than a script waiting for a human who is not there.
#
#   cursor-agent.sh run <prompt> <worktree> <log>
#   cursor-agent.sh dimensions  -> which policy dimensions cursor-agent's own flags enforce here
set -uo pipefail
_fm_alib="$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
[ -r "$_fm_alib" ] || { echo "cursor-agent: missing $_fm_alib" >&2; exit 70; }
# shellcheck source=bin/adapters/_lib.sh
. "$_fm_alib"

# What cursor-agent's own flags enforce of the round's policy (T-105). It
# used to run with -f, which lets every command through, and no sandbox.
# Now --trust answers the workspace-trust prompt for the worktree the
# scripts made, and --sandbox enabled runs its commands in cursor's own
# sandbox, which confines their writes to the workspace. The network, the
# sockets and the refused operations are the OS sandbox's, whose proxy is
# what names a refused host; if cursor's own sandbox cuts the network off
# before the proxy sees a request, that refusal names no host, which the
# canary shows per version. MCP servers are never approved (no
# --approve-mcps). The repository's .cursor/ and .mcp.json are still read
# by cursor, and reading in general is not confined, so those two are the
# OS sandbox's. On macOS cursor's sandbox is a seatbelt, which cannot start
# inside sandbox-exec: there it is off and the outer one confines the
# commands instead.
#
# Its login (T-117): on macOS `agent login` keeps the access token in the
# keychain, which no round reaches. fm-sandbox.sh reads that one item
# (cursor-access-token) outside the round and serves it, and no other, to
# the round through a stand-in for security(1) first on its PATH.
# Elsewhere the login is ~/.config/cursor/auth.json, which holds the
# refresh token too, and no round reads it: fm-sandbox.sh writes a copy with
# the refresh token emptied under the round's own XDG_CONFIG_HOME.
#
# No `fm:review-run` line: a run-mode review needs the reviewer's writes
# confined to a checkout by the CLI itself, which T-066 asked of claude
# alone. So cursor-agent reviews in diff mode only, and fm_adapter_context
# refuses a run-mode round before the CLI starts.
cursor_native() {
  if [ "${FM_OUTER_OS:-}" = darwin ]; then
    echo "env ulimit"
  else
    echo "write env ulimit"
  fi
}
if [ "${1-}" = "dimensions" ]; then
  fm_adapter_policy; read -r -a native <<<"$(cursor_native)"
  fm_adapter_dimensions "${native[@]}"; exit 0
fi

[ "${1-}" = "run" ] || { echo "usage: cursor-agent.sh run <prompt> <worktree> <log>" >&2; exit 64; }
prompt="${2-}"; tree="${3-}"; log="${4-}"
[ -f "$prompt" ] || { echo "cursor-agent: no prompt at $prompt" >&2; exit 64; }
[ -d "$tree" ]   || { echo "cursor-agent: no worktree at $tree" >&2; exit 64; }
fm_adapter_context "$0"

command -v cursor-agent >/dev/null 2>&1 || {
  # stderr, not the log: the log is what the VENDOR said, and a caller that
  # asks "did anything run?" must not be answered by the adapter's own
  # notice that nothing could
  echo "cursor-agent: cursor-agent is not installed - vendor unavailable" >&2; exit 2; }

# FM_ADAPTER_ARGS is deliberately unquoted: it carries whatever extra
# arguments the operator configured, and they have to split into words.
off="$(fm_adapter_mark "$log")"
# an operator argument after these would win, and undo the policy
case " ${FM_ADAPTER_ARGS:-} " in
  *" -f "*|*--force*|*--sandbox*|*--approve-mcps*|*--yolo*)
    echo "cursor-agent: FM_ADAPTER_ARGS changes permissions; refusing the round" >&2; exit 64 ;;
esac
fm_adapter_policy
sandbox=enabled; [ "${FM_OUTER_OS:-}" != darwin ] || sandbox=disabled
read -r -a native <<<"$(cursor_native)"
fm_adapter_confine cursor-agent "$tree" "${native[@]}"
# where fm-sandbox.sh puts the login file's copy, when the login is a file
mkdir -p "$FM_ROUND_TMP/cursor-config" || exit 70
export XDG_CONFIG_HOME="$FM_ROUND_TMP/cursor-config"
if [ -n "${FM_ATTEMPT_DIR:-}" ]; then
  ( cd "$tree" && "${FM_LAUNCH[@]}" cursor-agent -p --trust --sandbox "$sandbox" --output-format json ${FM_ADAPTER_ARGS:-} < "$prompt" ) 2>&1 | tee -a "$log"
  fm_adapter_pipeline_status "${PIPESTATUS[@]}"
else
  ( cd "$tree" && "${FM_LAUNCH[@]}" cursor-agent -p --trust --sandbox "$sandbox" ${FM_ADAPTER_ARGS:-} < "$prompt" ) >> "$log" 2>&1
fi
rc=$?
fm_adapter_verdict "$rc" "$log" "$off"
exit $?
