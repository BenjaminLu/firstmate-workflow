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
# nothing here may read stdin. With nullglob an empty file list turns a grep
# into one that reads standard input, and the whole gate stops dead waiting
# for a human who is not there - the same way fm-run's advance loop once ate
# its own input.
exec < /dev/null

fail=0
bold=''; dim=''; red=''; green=''; off=''
if [ -t 1 ]; then bold=$'\033[1m'; dim=$'\033[2m'; red=$'\033[31m'; green=$'\033[32m'; off=$'\033[0m'; fi

stage() { printf '\n%s== %s%s\n' "$bold" "$1" "$off"; }
pass()  { printf '  %s+%s %s\n' "$green" "$off" "$1"; }
flunk() { printf '  %sx%s %s\n' "$red" "$off" "$1"; fail=1; }
skip()  { printf '  %s- %s (skipped)%s\n' "$dim" "$1" "$off"; }

stage "shellcheck"
scripts=(bin/*.sh bin/adapters/*.sh tests/*.sh)  # adapters too: bin/*.sh does not recurse
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
suitefiles=(tests/*.test.sh)
bad=''
if [ ${#suitefiles[@]} -gt 0 ]; then
  bad=$(grep -nE 'assert_(ok|fail) "grep [^|]*\$(ROOT|[A-Za-z_]*ROOT)[^|]*"' "${suitefiles[@]}" 2>/dev/null \
        | grep -v 'grep -v' || true)
fi
if [ -n "$bad" ]; then
  flunk "an assertion greps source without excluding comments"
  printf '%s\n' "$bad"
else
  pass "no assertion greps source without excluding comments"
fi

# a fixture that swaps a script out has to put it back, and a hand-rolled
# save-and-restore is where that goes wrong: the restore ends up parked at
# the bottom of the file, then duplicated or lost by the next edit.
# stub_script pairs them and finish undoes them whether the suite remembered
# or not.
if [ ${#suitefiles[@]} -gt 0 ] && grep -ln '\.keep"' "${suitefiles[@]}" >/dev/null 2>&1; then
  flunk "a suite saves a script by hand; use stub_script"
  grep -n '\.keep"' "${suitefiles[@]}"
else
  pass "every swapped script is paired with its restore"
fi

# the guarantee that nothing reads standard input has to hold for every
# script that dispatches a child, not only the ones that were remembered
stage "stdin"
dispatchers=''
for f in bin/*.sh; do
  case "$f" in */fm-config.sh) continue ;; esac
  grep -qE '\$\(|"\$[A-Z_]*/(bin/)?fm-|fm_run_chain|Bun\.spawn|\$GH ' "$f" || continue
  grep -q '^exec < /dev/null' "$f" || dispatchers="$dispatchers $(basename "$f")"
done
if [ -n "$dispatchers" ]; then
  flunk "these dispatch a child without closing standard input:$dispatchers"
else
  pass "every script that dispatches closes standard input"
fi

# and the vendor chain has one implementation, so a second loop over
# vendors cannot appear without this noticing
# fm-config.sh holds the one implementation; ci.sh is this lint
loops="$(grep -ln 'for v in .*vendors\|for v in \$chain' bin/*.sh 2>/dev/null \
  | grep -vE 'fm-config\.sh|ci\.sh' || true)"
if [ -n "$loops" ]; then
  flunk "a script loops over vendors on its own: $loops"
else
  pass "the vendor chain has one implementation"
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
# tests/e2e belongs to playwright, which owns its own runner; bun picking
# those files up runs them without a browser and calls the result an error
bunspecs=()
while IFS= read -r f; do bunspecs+=("$f"); done < <(
  find . \( -name '*.test.ts' -o -name '*.spec.ts' \) 2>/dev/null \
    | grep -v node_modules | grep -v '/tests/e2e/' | sort)
if [ ${#bunspecs[@]} -eq 0 ]; then
  skip "no bun specs yet"
elif ! command -v bun >/dev/null 2>&1; then
  skip "bun not installed"
else
  if out=$(bun test "${bunspecs[@]}" 2>&1); then
    pass "bun test (${#bunspecs[@]} files)"
  else
    flunk "bun test"; printf '%s\n' "$out"
  fi
fi

stage "end-to-end"
if [ ! -d tests/e2e ]; then
  skip "no e2e suite yet"
elif ! command -v bunx >/dev/null 2>&1; then
  skip "bunx not installed"
elif [ ! -d node_modules/@playwright ]; then
  # an uninstalled browser is a missing tool, not a red gate: say so loudly
  # rather than failing a machine that has not run bun install yet
  skip "playwright not installed (bun install && bunx playwright install chromium)"
else
  if out=$(bunx playwright test 2>&1); then
    pass "playwright: $(printf '%s' "$out" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) passed.*/\1/p' | tail -1) browser tests"
  else
    flunk "playwright"; printf '%s\n' "$out"
  fi
fi

printf '\n'
if [ "$fail" -eq 0 ]; then printf '%sci: green%s\n' "$green" "$off"; else printf '%sci: red%s\n' "$red" "$off"; fi
exit "$fail"
