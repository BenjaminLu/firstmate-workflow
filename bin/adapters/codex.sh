#!/usr/bin/env bash
# codex adapter. Hands the prompt to codex and maps its outcome onto the
# contract in _contract.md. It must never touch git or gh: the scripts above
# do all of that, which is what lets a CLI with no repository access still be
# a worker.
#
# The invocation is the non-interactive one on purpose. An adapter that opens
# a REPL hangs a dispatch until something kills it, and looks like a model
# thinking rather than a script waiting for a human who is not there.
set -uo pipefail
_fm_alib="$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
[ -r "$_fm_alib" ] || { echo "codex: missing $_fm_alib" >&2; exit 70; }
# shellcheck source=bin/adapters/_lib.sh
. "$_fm_alib"
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
# the trailing "-" is codex's read-the-prompt-from-stdin marker and has to
# be the last argument, so FM_ADAPTER_ARGS goes before it
final_args=()
[ -z "${FM_FINAL_PATH:-}" ] || final_args=(--output-last-message "$FM_FINAL_PATH")
if [ -n "${FM_ATTEMPT_DIR:-}" ]; then
  ( cd "$tree" && codex exec --skip-git-repo-check ${final_args[@]+"${final_args[@]}"} ${FM_ADAPTER_ARGS:-} - < "$prompt" ) 2>&1 | tee -a "$log"
  fm_adapter_pipeline_status "${PIPESTATUS[@]}"
else
  ( cd "$tree" && codex exec --skip-git-repo-check ${final_args[@]+"${final_args[@]}"} ${FM_ADAPTER_ARGS:-} - < "$prompt" ) >> "$log" 2>&1
fi
rc=$?
fm_adapter_verdict "$rc" "$log" "$off"
exit $?
