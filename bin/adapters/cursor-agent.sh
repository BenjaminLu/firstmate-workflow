#!/usr/bin/env bash
# cursor-agent adapter. Hands the prompt to cursor-agent and maps its outcome onto the
# contract in _contract.md. It must never touch git or gh: the scripts above
# do all of that, which is what lets a CLI with no git access still be a worker.
set -uo pipefail
[ "${1-}" = "run" ] || { echo "usage: cursor-agent.sh run <prompt> <worktree> <log>" >&2; exit 64; }
prompt="${2-}"; tree="${3-}"; log="${4-}"
[ -f "$prompt" ] || { echo "cursor-agent: no prompt at $prompt" >&2; exit 64; }
[ -d "$tree" ]   || { echo "cursor-agent: no worktree at $tree" >&2; exit 64; }

command -v cursor-agent >/dev/null 2>&1 || {
  # the log is the only trace a stand-down or a reconcile will have
  echo "cursor-agent: cursor-agent is not installed - vendor unavailable" | tee -a "$log" >&2; exit 2; }

( cd "$tree" && cursor-agent  < "$prompt" ) >> "$log" 2>&1
rc=$?
case "$rc" in
  0) exit 0 ;;
  # authentication, quota and network failures are the vendor being unavailable,
  # not the model failing at the task
  2|4|41|69|75) exit 2 ;;
  *) grep -qiE 'not logged in|unauthor|quota|rate limit|network|ENOTFOUND|ECONNREFUSED' "$log" \
       && exit 2 || exit 1 ;;
esac
