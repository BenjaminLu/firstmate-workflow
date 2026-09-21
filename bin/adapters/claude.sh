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
# FM_SESSION_ID makes the run findable afterwards. A headless `claude -p`
# is not a named session, so a dispatched worker was invisible to anything
# that lists sessions - the captain could see the crew on the board and
# had no way to open one and read what it actually did.
( cd "$tree" && claude -p --permission-mode acceptEdits \
    ${FM_SESSION_ID:+--session-id "$FM_SESSION_ID"} \
    ${FM_ADAPTER_ARGS:-} < "$prompt" ) >> "$log" 2>&1
rc=$?
fm_adapter_verdict "$rc" "$log" "$off"
exit $?
