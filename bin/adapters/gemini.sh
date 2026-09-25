#!/usr/bin/env bash
# gemini adapter. Hands the prompt to gemini and maps its outcome onto the
# contract in _contract.md. It must never touch git or gh: the scripts above
# do all of that, which is what lets a CLI with no repository access still be
# a worker.
#
# The invocation is the non-interactive one on purpose. An adapter that opens
# a REPL hangs a dispatch until something kills it, and looks like a model
# thinking rather than a script waiting for a human who is not there.
#
#   gemini.sh run <prompt> <worktree> <log>
#   gemini.sh dimensions    -> which policy dimensions gemini's own flags enforce here
set -uo pipefail
_fm_alib="$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
[ -r "$_fm_alib" ] || { echo "gemini: missing $_fm_alib" >&2; exit 70; }
# shellcheck source=bin/adapters/_lib.sh
. "$_fm_alib"

# What gemini's own flags enforce of the round's policy (T-105): nothing of
# the OS kind. Its --sandbox is a container or a seatbelt, neither of which
# can start inside the OS sandbox fm puts around it, so every dimension but
# the launcher's environment scrub and ulimits is the OS sandbox's, and
# where that sandbox does not cover them all - Linux, where bwrap leaves the
# network - gemini refuses the round. Inside it, --approval-mode yolo lets
# the round's commands run (headless, nobody can approve one), --extensions
# none loads no extension, and --allowed-mcp-server-names names a server no
# configuration declares, so none starts.
gemini_native() { echo "env ulimit"; }
if [ "${1-}" = "dimensions" ]; then
  fm_adapter_policy; read -r -a native <<<"$(gemini_native)"
  fm_adapter_dimensions "${native[@]}"; exit 0
fi

[ "${1-}" = "run" ] || { echo "usage: gemini.sh run <prompt> <worktree> <log>" >&2; exit 64; }
prompt="${2-}"; tree="${3-}"; log="${4-}"
[ -f "$prompt" ] || { echo "gemini: no prompt at $prompt" >&2; exit 64; }
[ -d "$tree" ]   || { echo "gemini: no worktree at $tree" >&2; exit 64; }
fm_adapter_context "$0"

command -v gemini >/dev/null 2>&1 || {
  # stderr, not the log: the log is what the VENDOR said, and a caller that
  # asks "did anything run?" must not be answered by the adapter's own
  # notice that nothing could
  echo "gemini: gemini is not installed - vendor unavailable" >&2; exit 2; }

# FM_ADAPTER_ARGS is deliberately unquoted: it carries whatever extra
# arguments the operator configured, and they have to split into words.
off="$(fm_adapter_mark "$log")"
# an operator argument after these would win, and undo the policy
case " ${FM_ADAPTER_ARGS:-} " in
  *--sandbox*|*" -s "*|*--extensions*|*" -e "*|*--allowed-mcp*|*--include-directories*)
    echo "gemini: FM_ADAPTER_ARGS changes permissions; refusing the round" >&2; exit 64 ;;
esac
fm_adapter_policy
read -r -a native <<<"$(gemini_native)"
fm_adapter_confine gemini "$tree" "${native[@]}"
policy_args=(--approval-mode yolo --extensions none --allowed-mcp-server-names fm-none)
# no -p here: gemini's -p takes the prompt as its value, so an empty
# FM_ADAPTER_ARGS left the flag dangling and the prompt was never delivered.
# A piped stdin is what puts it in headless mode.
if [ -n "${FM_ATTEMPT_DIR:-}" ]; then
  ( cd "$tree" && "${FM_LAUNCH[@]}" gemini "${policy_args[@]}" --output-format json ${FM_ADAPTER_ARGS:-} < "$prompt" ) 2>&1 | tee -a "$log"
  fm_adapter_pipeline_status "${PIPESTATUS[@]}"
else
  ( cd "$tree" && "${FM_LAUNCH[@]}" gemini "${policy_args[@]}" ${FM_ADAPTER_ARGS:-} < "$prompt" ) >> "$log" 2>&1
fi
rc=$?
fm_adapter_verdict "$rc" "$log" "$off"
exit $?
