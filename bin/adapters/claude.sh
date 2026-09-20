#!/usr/bin/env bash
# claude adapter. Hands the prompt to claude and maps its outcome onto the
# contract in _contract.md. It must never touch git or gh: the scripts above
# do all of that, which is what lets a CLI with no git access still be a worker.
set -uo pipefail
[ "${1-}" = "run" ] || { echo "usage: claude.sh run <prompt> <worktree> <log>" >&2; exit 64; }
prompt="${2-}"; tree="${3-}"; log="${4-}"
[ -f "$prompt" ] || { echo "claude: no prompt at $prompt" >&2; exit 64; }
[ -d "$tree" ]   || { echo "claude: no worktree at $tree" >&2; exit 64; }

command -v claude >/dev/null 2>&1 || {
  # the log is the only trace a stand-down or a reconcile will have
  echo "claude: claude is not installed - vendor unavailable" | tee -a "$log" >&2; exit 2; }

( cd "$tree" && claude  < "$prompt" ) >> "$log" 2>&1
rc=$?
case "$rc" in
  0) exit 0 ;;
  # authentication, quota and network failures are the vendor being unavailable,
  # not the model failing at the task
  2|4|41|69|75) exit 2 ;;
  *) grep -qiE 'not logged in|unauthor|quota|rate limit|network|ENOTFOUND|ECONNREFUSED' "$log" \
       && exit 2 || exit 1 ;;
esac
