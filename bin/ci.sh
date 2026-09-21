#!/usr/bin/env bash
# fm:lint-source  # this file quotes the shapes it forbids; lints skip it
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

# The corpus and the comment stripper come from the library, so the gate
# and tests/option-loop.test.sh judge the same files by the same rule.
# They were written out at each call site - four times, and three of them
# were a version of the stripper that cuts `${1#--}` in half.
# beside the SCRIPT, not under FM_ROOT: the gate is run against other
# trees and the library is part of the gate, not of the tree it judges
_fm_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-config.sh"
[ -r "$_fm_lib" ] || { echo "ci: missing $_fm_lib" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$_fm_lib"

fail=0
started_at="$(date +%s)"
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
#
# What it catches: the `assert_ok "grep ... $ROOT..."` shape, which is how
# the mistake has always been written here. What it does NOT catch: a source
# grep built any other way - a variable assigned from sed|grep and then
# asserted on, for instance. Those are on the author. Widen this when one of
# them bites, not before, because a lint that flags every grep is a lint
# people learn to ignore.
suitefiles=(tests/*.test.sh)
bad=''
if [ ${#suitefiles[@]} -gt 0 ]; then
  bad=$(grep -HnE 'assert_(ok|fail) "grep [^|]*\$(ROOT|[A-Za-z_]*ROOT)[^|]*"' "${suitefiles[@]}" 2>/dev/null \
        | grep -v 'grep -v' || true)
fi
if [ -n "$bad" ]; then
  flunk "an assertion greps source without excluding comments"
  printf '%s\n' "$bad"
else
  pass "no assertion greps source without excluding comments (${#suitefiles[@]} suites)"
fi

# assert_ok and assert_fail eval their argument, so interpolating captured
# output into one hands that output to the shell. A gate transcript echoes
# back the source lines it complains about, so a fixture containing $(date)
# got RUN by the assertion meant to read it - and when the result failed to
# parse, assert_fail called that a pass. It reported a real failure as ok
# about half the time. assert_contains and assert_lacks take data as data.
evalled=''
if [ ${#suitefiles[@]} -gt 0 ]; then
  evalled="$(grep -Hn "assert_\(ok\|fail\) \"printf" "${suitefiles[@]}" 2>/dev/null \
    | grep -v '^[^:]*:[0-9]*: *#' || true)"
fi
if [ -n "$evalled" ]; then
  flunk "an assertion evals captured output; use assert_contains or assert_lacks"
  printf '%s\n' "$evalled"
else
  pass "no assertion evals captured output"
fi

# `shift 2` with one argument left does not shift - it returns 1 and leaves
# $@ alone, so the option loop spins on the same flag for ever. Every
# value-taking flag has to check first. What this catches: a `shift 2`
# branch with no `need` in front of it. What it does not: a loop that
# checks some other way, which is why the check is named rather than
# inferred.
# ci.sh quotes the shape it forbids, so it declares itself a lint source
# the way a sourced library declares itself sourced - by a marker rather
# than by being on a list.
# Comments come off the line BEFORE it is judged, both for finding the
# corpus and for finding the guard. `--x) v="${2-}"; shift 2 ;; # need` was
# a `shift 2` that spins for ever and satisfied a grep for the word
# `need`: the lint was recognising the fix by its name rather than by its
# presence in the code.
#
# Both of these - which files, and what a comment is - come from
# bin/fm-config.sh, because tests/option-loop.test.sh has to sweep for a
# script this stage should have linted and did not, and a sweep written
# out by hand at each call site drifts from the thing it is checking.
loopfiles=()
while IFS= read -r f; do loopfiles+=("$f"); done < <(fm_loop_corpus bin)
unguarded=''
# bash 3.2 treats "${arr[@]}" on an empty array as unbound under set -u,
# so the count is checked before the array is touched, the way the
# earlier stage does it
#
# The guard has to come BEFORE the shift, and the grep did not care
# where it was: `--x) v="${2-}"; shift 2; need "$@" ;;` checks after the
# argument is gone and still passed, and so did `shift 2; echo "need a
# value"`, which is not a check at all. So the line is cut at the shift
# and only the part in front of it is searched, for a CALL - the word
# followed by an argument - rather than for the word.
[ ${#loopfiles[@]} -eq 0 ] || for f in "${loopfiles[@]}"; do
  hits="$(fm_strip_comments "$f" | awk '
            # The unit is the case BRANCH, not the line. A guard has to
            # come before the shift, and a branch is what `;;` ends - so
            # the ordinary
            #     --repo)
            #       fm_need "fm-x" "$@"
            #       REPO="$2"; shift 2 ;;
            # is guarded, and reading one physical line called it naked.
            # Going the other way, a guard in the PREVIOUS branch must
            # not cover this one, which is what `;;` resets.
            function guard(t) { return t ~ /(^|[^[:alnum:]_])(fm_)?need[ \t]+[^;[:space:]]/ }
            { rest = $0
              while (1) {
                p = index(rest, ";;")
                seg = p ? substr(rest, 1, p - 1) : rest
                sp = index(seg, "shift 2")
                gp = 0
                if (match(seg, /(^|[^[:alnum:]_])(fm_)?need[ \t]+[^;[:space:]]/)) gp = RSTART
                if (sp && !seen && !(gp && gp < sp)) print FNR ":" $0
                if (gp && (!sp || gp < sp)) seen = 1
                if (!p) break
                seen = 0                     # the branch ended here
                rest = substr(rest, p + 2)
              }
            }
          ' || true)"
  [ -z "$hits" ] || unguarded="$unguarded$(printf '%s\n' "$hits" | sed "s|^|$f:|")
"
done
if [ -n "$unguarded" ]; then
  flunk "a shift 2 that has not checked it has two:"
  printf '%s\n' "$unguarded"
else
  # the count, so an empty corpus is visible rather than looking like a
  # clean one - the stage passed identically when it linted nothing
  pass "no option loop can spin on a flag with no value (${#loopfiles[@]} scripts)"
fi

# `producer | grep -q` under pipefail: grep exits on the first match, the
# producer takes SIGPIPE, and the pipeline reports failure even though the
# match happened. `yes MATCH | grep -qi match` returns 141. A here-string
# has no producer to kill and takes the data as data.
# grep -n prints path:line:text, so a comment filter has to skip TWO
# fields - `^[^:]*: *#` could only ever match the line number, and never
# did. And ci.sh is skipped the way a sourced library is: by a marker it
# declares about itself, not by its name.
piped="$(grep -Hn '| *grep -[qc]' bin/*.sh bin/adapters/*.sh 2>/dev/null \
  | grep -v '^[^:]*:[0-9]*: *#' \
  | while IFS=: read -r pf rest; do
      grep -q '^# fm:lint-source' "$pf" || printf '%s:%s\n' "$pf" "$rest"
    done || true)"
if [ -n "$piped" ]; then
  flunk "a pipeline feeds grep -q or -c; use a here-string"
  printf '%s\n' "$piped"
else
  pass "nothing feeds grep -q through a pipe"
fi

# a fixture that swaps a script out has to put it back, and a hand-rolled
# save-and-restore is where that goes wrong: the restore ends up parked at
# the bottom of the file, then duplicated or lost by the next edit.
# stub_script pairs them and finish undoes them whether the suite remembered
# or not.
#
# What it catches: a `.keep"` file, which is how that mistake was written
# here. It is a tripwire on one idiom, not a proof that every swap is
# paired - a suite that saves to `$d/saved-copy` walks past it. The real
# guarantee is that stub_script exists and is easier than the alternative.
if [ ${#suitefiles[@]} -gt 0 ] && grep -ln '\.keep"' "${suitefiles[@]}" >/dev/null 2>&1; then
  flunk "a suite saves a script by hand; use stub_script"
  grep -n '\.keep"' "${suitefiles[@]}"
else
  pass "every swapped script is paired with its restore"
fi

# The guarantee that nothing reads standard input, checked against every
# script that looks like it starts a child. "Looks like" is the honest word:
# the test is a grep for command substitution, a call to another fm script,
# the vendor chain, or gh - not a proof that the script dispatches. It errs
# towards demanding the line, which costs nothing.
#
# board/server.ts is out of scope because it is not a shell script and Bun
# gives a spawned child a closed stdin by default. bin/adapters/*.sh are
# exempt because each one redirects the prompt into its vendor on the one
# line that starts a child - that is their whole job, and the contract test
# asserts the redirect per adapter.
stage "stdin"
dispatchers=''
for f in bin/*.sh; do
  # A file that is meant to be sourced must NOT have the line: `exec` in a
  # sourced file redirects the caller's own standard input for the rest of
  # its life. Such a file says so about itself with `# fm:sourced`, so a
  # library added tomorrow is exempt by being what it is rather than by
  # being on a list someone remembered to extend.
  grep -q '^# fm:sourced' "$f" && continue
  grep -qE '\$\(|"\$[A-Z_]*/(bin/)?fm-|fm_run_chain|Bun\.spawn|\$GH ' "$f" || continue
  grep -q '^exec < /dev/null' "$f" || dispatchers="$dispatchers $(basename "$f")"
done
if [ -n "$dispatchers" ]; then
  flunk "these dispatch a child without closing standard input:$dispatchers"
else
  pass "every script that dispatches closes standard input"
fi

# `exec < /dev/null` sets fd 0 for the script and nothing more: a child
# dispatched inside `while ... done <<<"$list"` is handed the list. So every
# dispatch of one of our own scripts carries its own redirect as well, and
# that is checkable by reading the file rather than by a probe.
# joined first: a redirect often sits on the continuation line, and a
# per-physical-line grep would call that a miss. Then the guards are struck
# OUT of the line rather than the line being dropped - `[ -x "$REPO/bin/x" ]
# && "$REPO/bin/x" ...` joins to one record, and excluding the record
# excluded the dispatch with it.
undirected=''
for f in bin/*.sh; do
  case "$f" in */ci.sh) continue ;; esac
  hits="$(sed -e :a -e '/\\$/N; s/\\\n//; ta' "$f" \
    | grep -v '^[[:space:]]*#' \
    | sed -e 's/\[ *-[a-z] *"[^"]*" *\]//g' \
          -e 's/command -v [^ ]*//g' \
          -e 's/[A-Za-z_][A-Za-z_0-9]*="[^"]*bin\/[^"]*"//g' \
    | grep -n '"\$B/\|"\$REPO/bin/fm-\|"\$EMIT"' \
    | grep -v '</dev/null' || true)"
  [ -z "$hits" ] || undirected="$undirected
$f: $hits"
done
if [ -n "$undirected" ]; then
  flunk "these dispatch one of our scripts without their own </dev/null:"
  printf '%s\n' "$undirected"
else
  pass "every dispatch carries its own redirect, not only the script's"
fi

# A file meant to be sourced must NOT carry the redirect: in a sourced file
# it belongs to the caller for the rest of its life. The exemptions above
# are names; this asserts the property they stand for.
wrongly=''
sourced=0
for f in bin/*.sh; do
  grep -q '^# fm:sourced' "$f" || continue
  sourced=$((sourced + 1))
  grep -q '^exec < /dev/null' "$f" && wrongly="$wrongly $(basename "$f")"
done
# no tripwire for "nobody declared themselves": the gate runs against
# arbitrary trees, and a tree with no sourced library is a normal tree. The
# count is reported instead, and this repository's own suite asserts it.
if [ -n "$wrongly" ]; then
  flunk "these are sourced and must not redirect the caller's input:$wrongly"
else
  pass "no sourced library takes the caller's standard input ($sourced declared)"
fi

# The vendor chain has one implementation. What this catches: a `for v in`
# over a vendor list, which is the shape the duplicate would take. A second
# implementation written any other way walks past it; the contract test
# covering fm_run_chain is what makes that one visible.
# fm-config.sh holds the one implementation; ci.sh is this lint
loops="$(grep -ln 'for v in .*vendors\|for v in \$chain' bin/*.sh 2>/dev/null \
  | grep -vE 'fm-config\.sh|ci\.sh' || true)"
if [ -n "$loops" ]; then
  flunk "a script loops over vendors on its own: $loops"
else
  pass "the vendor chain has one implementation"
fi

# An assertion helper that does not exist is a command-not-found: under
# `set -uo pipefail` it prints to stderr, the suite carries on, and the
# file exits 0. A whole suite goes green for free - in the files whose job
# is to stop exactly that. So every assert_* a suite calls has to be one
# tests/lib.sh defines.
stage "assertions"
if [ -d tests ] && [ -f tests/lib.sh ]; then
  defined="$(grep -ohE '^assert_[a-z_]+' tests/lib.sh 2>/dev/null | sort -u)"
  # comments off first: a suite that NAMES a helper in prose - "this file
  # leans on assert_ne" - is not calling it, and counting the mention
  # turns the gate red for a sentence
  called=''
  for _t in tests/*.sh; do
    called="$called$(fm_strip_comments "$_t" | grep -ohE 'assert_[a-z_]+' || true)
"
  done
  called="$(printf '%s' "$called" | sed '/^$/d' | sort -u)"
  missing=''
  for a in $called; do
    printf '%s\n' "$defined" | grep -qx "$a" || missing="$missing $a"
  done
  if [ -n "$missing" ]; then
    flunk "a suite calls an assertion tests/lib.sh does not define:$missing"
  else
    pass "every assertion a suite calls is defined ($(printf '%s\n' "$called" | sed '/^$/d' | wc -l | tr -d ' ') names)"
  fi
else
  skip "no test harness"
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
    # The check below reads the shell's OWN messages, and bash localises
    # them: on a zh-TW shell it says 命令未找到 and an English grep
    # matches nothing, which is green for a suite that never ran half
    # its lines. So the messages are pinned - and only the messages.
    # LC_ALL=C pins collation and ctype too, which would run every
    # suite's sort, grep and tr over UTF-8 in a locale no developer
    # uses; and LC_ALL has to be cleared as well, because it outranks
    # LC_MESSAGES wherever the caller has it set. Empty, not unset: an
    # empty LC_ALL is the POSIX way to say "do not override", and
    # unsetting it in a child needs a subshell.
    if LC_ALL='' LC_MESSAGES=C bash "$t" > "$tmp" 2>&1; then
      # A suite that calls something that does not exist prints to
      # stderr, carries on, and reaches finish green - which is how a
      # test file with two spliced lines reported the same as one
      # without. Under `set -uo pipefail` with no -e, the shell will not
      # tell us, so the gate reads what the run said.
      #
      # What it looks for is the shell's OWN diagnostic, which carries
      # the "<file>: line N:" prefix. A suite that prints one of these
      # phrases as data, or asserts a script's error text, is not a
      # suite that broke, and the prefix is what tells them apart.
      #
      # The set is chosen, not collected: these are bash's diagnostics
      # for "this line did not run and I am carrying on anyway", which
      # is the whole hazard under `set -uo pipefail` with no -e. A
      # missing command, an unset variable in a subshell - where `set -u`
      # kills the subshell and leaves the parent running, which is the
      # only shape of it that reaches here, since in the main shell bash
      # exits and the other arm catches it - a file that will not exec,
      # and a syntax error in something sourced - which leaves the suite
      # running with half its functions undefined and exiting 0, the way
      # two spliced lines in a test file did. Diagnostics that stop the
      # shell do not belong here: the suite's exit status already
      # catches those, on the other arm.
      noise="$(grep -nE '^[^:]+: line [0-9]+: .*(command not found|unbound variable|No such file or directory|syntax error)' "$tmp" || true)"
      if [ -n "$noise" ]; then
        flunk "$t said it passed, but something in it did not run:"
        printf '%s\n' "$noise"
      else
        pass "$t"
      fi
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

# The design's budget is sixty seconds for a full local pass, and a budget
# nobody measures is a wish. The hard limit is three times it, because a
# loaded CI runner is not the machine the budget was written for - but the
# number is printed either way, so a suite that starts spending it is
# visible before it breaks anything.
took=$(( $(date +%s) - started_at ))
printf '\n%s took %ss (the design asks for 60s locally)%s\n' "$dim" "$took" "$off"
if [ "$took" -gt 180 ]; then
  flunk "the gate took ${took}s, more than three times its budget"
fi
if [ "$fail" -eq 0 ]; then printf '%sci: green%s\n' "$green" "$off"; else printf '%sci: red%s\n' "$red" "$off"; fi
exit "$fail"
