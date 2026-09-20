#!/usr/bin/env bash
# The one gate. Both the local pre-push check and GitHub Actions run this file,
# so there is no second copy of the steps to drift out of sync.
#
#   bin/ci.sh            run every stage against the repo this script lives in
#   FM_ROOT=/path        run against another tree (used by the tests)
set -uo pipefail

ROOT="${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || exit 2
shopt -s nullglob

fail=0
bold=''; dim=''; red=''; green=''; off=''
if [ -t 1 ]; then bold=$'\033[1m'; dim=$'\033[2m'; red=$'\033[31m'; green=$'\033[32m'; off=$'\033[0m'; fi

stage() { printf '\n%s== %s%s\n' "$bold" "$1" "$off"; }
pass()  { printf '  %s+%s %s\n' "$green" "$off" "$1"; }
flunk() { printf '  %sx%s %s\n' "$red" "$off" "$1"; fail=1; }
skip()  { printf '  %s- %s (skipped)%s\n' "$dim" "$1" "$off"; }

stage "shellcheck"
scripts=(bin/*.sh tests/*.sh)
if [ ${#scripts[@]} -eq 0 ]; then
  skip "no shell scripts"
elif command -v shellcheck >/dev/null 2>&1; then
  if out=$(shellcheck -x -S warning "${scripts[@]}" 2>&1); then
    pass "${#scripts[@]} scripts clean"
  else
    flunk "shellcheck"; printf '%s\n' "$out"
  fi
else
  skip "shellcheck not installed"
fi

stage "lint"
# the event log has exactly one writer; anything else appending to it is a bug
strays=$(grep -rnE '>>[[:space:]]*[^|]*events\.jsonl' bin board 2>/dev/null | grep -v 'bin/fm-emit.sh' || true)
if [ -n "$strays" ]; then
  flunk "something appends to state/events.jsonl outside fm-emit.sh"
  printf '%s\n' "$strays"
else
  pass "state/events.jsonl has a single writer"
fi

stage "test hygiene"
# an assertion that greps a source file is satisfied by a comment unless it
# filters them out. This has been written three times now; the machine checks
# it from here on.
bad=$(grep -nE 'assert_(ok|fail) "grep [^|]*\$(ROOT|[A-Za-z_]*ROOT)[^|]*"' tests/*.test.sh 2>/dev/null \
      | grep -v 'grep -v' || true)
if [ -n "$bad" ]; then
  flunk "an assertion greps source without excluding comments"
  printf '%s\n' "$bad"
else
  pass "no assertion greps source without excluding comments"
fi

stage "dag"
# section 14 of the design and tasks.json are two views of one DAG
if [ -f design/tasks.json ] && [ -f design/design.md ]; then
  missing=''
  for id in $(jq -r '.tasks[].id' design/tasks.json 2>/dev/null); do
    grep -q "| $id |" design/design.md || missing="$missing $id"
  done
  if [ -n "$missing" ]; then
    flunk "tasks.json has ids the design does not list:$missing"
  else
    pass "the design and tasks.json agree"
  fi
else
  skip "no DAG yet"
fi

stage "bash tests"
suites=(tests/*.test.sh)
if [ ${#suites[@]} -eq 0 ]; then
  skip "no suites yet"
else
  # to a file, never $(...): a suite that starts a server leaves a child
  # holding the pipe, and command substitution waits for that pipe to close
  tmp="$(mktemp)"
  for t in "${suites[@]}"; do
    if bash "$t" > "$tmp" 2>&1; then
      pass "$t"
    else
      flunk "$t"; cat "$tmp"
    fi
  done
  rm -f "$tmp"
fi

stage "bun tests"
bunspecs=$(find . -name '*.test.ts' -o -name '*.spec.ts' 2>/dev/null | grep -v node_modules | head -1)
if [ -z "$bunspecs" ]; then
  skip "no bun specs yet"
elif ! command -v bun >/dev/null 2>&1; then
  skip "bun not installed"
else
  if out=$(bun test 2>&1); then pass "bun test"; else flunk "bun test"; printf '%s\n' "$out"; fi
fi

stage "end-to-end"
if [ -d tests/e2e ]; then
  if command -v bunx >/dev/null 2>&1; then
    if out=$(bunx playwright test 2>&1); then pass "playwright"; else flunk "playwright"; printf '%s\n' "$out"; fi
  else
    skip "bunx not installed"
  fi
else
  skip "no e2e suite yet"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then printf '%sci: green%s\n' "$green" "$off"; else printf '%sci: red%s\n' "$red" "$off"; fi
exit "$fail"
