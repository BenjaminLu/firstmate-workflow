#!/usr/bin/env bash
# codex adapter. Hands the prompt to codex and maps its outcome onto the
# contract in _contract.md. It must never touch git or gh: the scripts above
# do all of that, which is what lets a CLI with no repository access still be
# a worker.
#
# The invocation is the non-interactive one on purpose. An adapter that opens
# a REPL hangs a dispatch until something kills it, and looks like a model
# thinking rather than a script waiting for a human who is not there.
#
#   codex.sh run <prompt> <worktree> <log>
#   codex.sh dimensions     -> which policy dimensions codex's own flags enforce here
set -uo pipefail
_fm_alib="$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
[ -r "$_fm_alib" ] || { echo "codex: missing $_fm_alib" >&2; exit 70; }
# shellcheck source=bin/adapters/_lib.sh
. "$_fm_alib"

# What codex's own flags enforce of the round's policy (T-105). Its
# workspace-write sandbox confines the commands' writes to the working
# directory and the temp directories; with the network off it also keeps
# them from every host and socket, which is what refuses a push, gh and
# Herdr - but it has only on and off, so a round with registries declared
# leaves the network to the OS sandbox. None of the repository files the
# policy keeps unloaded is one codex reads, and MCP servers are emptied on
# the command line. Reading is not among them. On macOS its sandbox is a
# seatbelt, which cannot start inside sandbox-exec: there it is off and the
# outer one confines the commands instead.
codex_native() {
  if [ "${FM_OUTER_OS:-}" = darwin ]; then
    echo "repo-config env ulimit"
  elif [ -z "${FM_POLICY_HOSTS:-}" ]; then
    echo "write network sockets refuse repo-config env ulimit"
  else
    echo "write repo-config env ulimit"
  fi
}
if [ "${1-}" = "dimensions" ]; then
  fm_adapter_policy; read -r -a native <<<"$(codex_native)"
  fm_adapter_dimensions "${native[@]}"; exit 0
fi

[ "${1-}" = "run" ] || { echo "usage: codex.sh run <prompt> <worktree> <log>" >&2; exit 64; }
prompt="${2-}"; tree="${3-}"; log="${4-}"
[ -f "$prompt" ] || { echo "codex: no prompt at $prompt" >&2; exit 64; }
[ -d "$tree" ]   || { echo "codex: no worktree at $tree" >&2; exit 64; }
fm_adapter_context "$0"

command -v codex >/dev/null 2>&1 || {
  # stderr, not the log: the log is what the VENDOR said, and a caller that
  # asks "did anything run?" must not be answered by the adapter's own
  # notice that nothing could
  echo "codex: codex is not installed - vendor unavailable" >&2; exit 2; }

# FM_ADAPTER_ARGS is deliberately unquoted: it carries whatever extra
# arguments the operator configured, and they have to split into words.
off="$(fm_adapter_mark "$log")"
# an operator argument after these would win, and undo the policy
case " ${FM_ADAPTER_ARGS:-} " in
  *--sandbox*|*" -s "*|*--dangerously*|*--full-auto*|*--yolo*|*" -c "*|*--config*|*--add-dir*)
    echo "codex: FM_ADAPTER_ARGS changes permissions; refusing the round" >&2; exit 64 ;;
esac
fm_adapter_policy
if [ "${FM_OUTER_OS:-}" = darwin ]; then
  # sandbox-exec around codex confines every command it runs
  policy_args=(--sandbox danger-full-access)
else
  net=false; [ -z "${FM_POLICY_HOSTS:-}" ] || net=true
  policy_args=(--sandbox workspace-write -c "sandbox_workspace_write.network_access=$net")
fi
policy_args+=(-c 'mcp_servers={}')
# the trailing "-" is codex's read-the-prompt-from-stdin marker and has to
# be the last argument, so FM_ADAPTER_ARGS goes before it
final_args=()
[ -z "${FM_FINAL_PATH:-}" ] || final_args=(--output-last-message "$FM_FINAL_PATH")
read -r -a native <<<"$(codex_native)"
fm_adapter_confine codex "$tree" "${native[@]}"
if [ -n "${FM_ATTEMPT_DIR:-}" ]; then
  ( cd "$tree" && "${FM_LAUNCH[@]}" codex exec --skip-git-repo-check "${policy_args[@]}" ${final_args[@]+"${final_args[@]}"} ${FM_ADAPTER_ARGS:-} - < "$prompt" ) 2>&1 | tee -a "$log"
  fm_adapter_pipeline_status "${PIPESTATUS[@]}"
else
  ( cd "$tree" && "${FM_LAUNCH[@]}" codex exec --skip-git-repo-check "${policy_args[@]}" ${final_args[@]+"${final_args[@]}"} ${FM_ADAPTER_ARGS:-} - < "$prompt" ) >> "$log" 2>&1
fi
rc=$?
fm_adapter_verdict "$rc" "$log" "$off"
exit $?
