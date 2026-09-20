#!/usr/bin/env bash
# gemini adapter. Hands the prompt to gemini and maps its outcome onto the
# contract in _contract.md. It must never touch git or gh: the scripts above
# do all of that, which is what lets a CLI with no repository access still be
# a worker.
#
# The invocation is the non-interactive one on purpose. An adapter that opens
# a REPL hangs a dispatch until something kills it, and looks like a model
# thinking rather than a script waiting for a human who is not there.
set -uo pipefail
_fm_alib="$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
[ -r "$_fm_alib" ] || { echo "gemini: missing $_fm_alib" >&2; exit 70; }
# shellcheck source=bin/adapters/_lib.sh
. "$_fm_alib"
[ "${1-}" = "run" ] || { echo "usage: gemini.sh run <prompt> <worktree> <log>" >&2; exit 64; }
prompt="${2-}"; tree="${3-}"; log="${4-}"
[ -f "$prompt" ] || { echo "gemini: no prompt at $prompt" >&2; exit 64; }
[ -d "$tree" ]   || { echo "gemini: no worktree at $tree" >&2; exit 64; }

command -v gemini >/dev/null 2>&1 || {
  # the log is the only trace a stand-down or a reconcile will have
  echo "gemini: gemini is not installed - vendor unavailable" | tee -a "$log" >&2; exit 2; }

off="$(fm_adapter_mark "$log")"
# no -p here: gemini's -p takes the prompt as its value, so an empty
# FM_ADAPTER_ARGS left the flag dangling and the prompt was never delivered.
# A piped stdin is what puts it in headless mode.
( cd "$tree" && gemini ${FM_ADAPTER_ARGS:-} < "$prompt" ) >> "$log" 2>&1
rc=$?
fm_adapter_verdict "$rc" "$log" "$off"
exit $?
