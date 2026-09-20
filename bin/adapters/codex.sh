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
[ -f "$_fm_alib" ] || { echo "codex: missing $_fm_alib" >&2; exit 70; }
# shellcheck source=bin/adapters/_lib.sh
. "$_fm_alib"
[ "${1-}" = "run" ] || { echo "usage: codex.sh run <prompt> <worktree> <log>" >&2; exit 64; }
prompt="${2-}"; tree="${3-}"; log="${4-}"
[ -f "$prompt" ] || { echo "codex: no prompt at $prompt" >&2; exit 64; }
[ -d "$tree" ]   || { echo "codex: no worktree at $tree" >&2; exit 64; }

command -v codex >/dev/null 2>&1 || {
  # the log is the only trace a stand-down or a reconcile will have
  echo "codex: codex is not installed - vendor unavailable" | tee -a "$log" >&2; exit 2; }

off="$(fm_adapter_mark "$log")"
( cd "$tree" && codex exec --skip-git-repo-check ${FM_ADAPTER_ARGS:-} - < "$prompt" ) >> "$log" 2>&1
rc=$?
fm_adapter_verdict "$rc" "$log" "$off"
exit $?
