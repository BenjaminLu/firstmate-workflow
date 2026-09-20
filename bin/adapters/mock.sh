#!/usr/bin/env bash
# The adapter CI runs. No model, no network - a scripted diff, so every
# end-to-end test is fast, free and deterministic.
#
#   FM_MOCK_EXIT=2          what to exit with (default 0)
#   FM_MOCK_FILE=path       file to create inside the worktree (default mock.txt)
#   FM_MOCK_BODY=text       what to put in it
set -uo pipefail
[ "${1-}" = "run" ] || { echo "usage: mock.sh run <prompt> <worktree> <log>" >&2; exit 64; }
prompt="${2-}"; tree="${3-}"; log="${4-}"
[ -f "$prompt" ] || { echo "mock: no prompt at $prompt" >&2; exit 64; }
[ -d "$tree" ]   || { echo "mock: no worktree at $tree" >&2; exit 64; }

code="${FM_MOCK_EXIT:-0}"
{
  echo "mock adapter"
  echo "prompt: $(wc -c < "$prompt" | tr -d ' ') bytes"
  echo "exit: $code"
} >> "$log"

if [ "$code" = "0" ] || [ "$code" = "1" ]; then
  out="$tree/${FM_MOCK_FILE:-mock.txt}"
  mkdir -p "$(dirname "$out")"
  printf '%s\n' "${FM_MOCK_BODY:-written by the mock adapter}" > "$out"
fi
exit "$code"
