#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/ci.sh
. "$ROOT/tests/lib/ci.sh"
gha="$ROOT/.github/workflows/ci.yml"
# --- the workflow: separate jobs behind one required `ci` check -----------
wf="$(cat "$gha")"
assert_contains "$wf" "--stage fast" "the workflow runs the fast checks as their own job"
assert_contains "$wf" "--stage bash" "and the bash suites as their own job(s)"
assert_contains "$wf" "--shard" "sharded across more than one"
assert_contains "$wf" "--stage bun" "and the bun tests as their own job"
assert_contains "$wf" "--stage e2e" "and playwright as their own job"
assert_matches "$wf" 'ci:[[:space:]]*$' "a final job is named ci, the required check's own name"
assert_contains "$wf" "needs:" "and it needs the others"
assert_matches "$wf" 'timeout-minutes:[[:space:]]*10' "every job keeps the 10-minute limit"

# Sharding turned the one `bun install` main had into several - one per bash
# shard, plus bun and e2e - and each pays the registry fetch again unless
# cached. So every job that installs must cache bun's install cache first,
# keyed on bun.lock, not merely have the string "actions/cache" appear
# somewhere in the file (the browser cache alone made that true before any
# bun cache existed). A job is its own block: from its "  <name>:" line to
# the next line at that same two-space indent.
job_names="$(awk '
  /^jobs:[[:space:]]*$/ { f = 1; next }
  f && /^  [a-zA-Z_-]+:[[:space:]]*$/ { line = $0; sub(/^  /, "", line); sub(/:.*$/, "", line); print line }
' "$gha")"
assert_ne "" "$job_names" "the workflow has jobs to check"
uncached=''
for j in $job_names; do
  block="$(awk -v want="  $j:" '
    $0 == want { f = 1; next }
    f && /^  [a-zA-Z_-]+:[[:space:]]*$/ { exit }
    f { print }
  ' "$gha")"
  grep -q "bun install" <<< "$block" || continue
  install_line="$(printf '%s\n' "$block" | grep -n "bun install" | head -1 | cut -d: -f1)"
  cache_line="$(printf '%s\n' "$block" | grep -n "actions/cache" | head -1 | cut -d: -f1)"
  key_line="$(printf '%s\n' "$block" | grep -n "bun\.lock" | head -1 | cut -d: -f1)"
  if [ -z "$cache_line" ] || [ -z "$key_line" ] || [ "$cache_line" -ge "$install_line" ]; then
    uncached="$uncached $j"
  fi
done
assert_eq "" "$uncached" "every job that runs bun install caches bun's install cache first, keyed on bun.lock"

e2e_block="$(awk '
  $0 == "  e2e:" { f = 1; next }
  f && /^  [a-zA-Z_-]+:[[:space:]]*$/ { exit }
  f { print }
' "$gha")"
assert_contains "$e2e_block" "ms-playwright" "the e2e job also caches the playwright browser"

# Every script parses. A `'` in a comment inside a single-quoted program
# (pipe_awk's `grep's`, T-103 round 7) ends the string early, and bash only
# finds out when it reaches that line: ci.sh died mid-stage, and every plant
# above went red for a reason none of them names.
unparsed=''
while IFS= read -r f; do
  bash -n "$f" 2>/dev/null || unparsed="$unparsed $f"
done < <(find "$ROOT/bin" "$ROOT/tests" -type f -name '*.sh')
assert_eq "" "$unparsed" "every script below bin/ and tests/ parses (bash -n)"

PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
