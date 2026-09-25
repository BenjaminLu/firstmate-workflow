#!/usr/bin/env bash
# fm:lint-source  # this file quotes the shapes it forbids; lints skip it
# The one gate. Both the local pre-push check and GitHub Actions run this file,
# so there is no second copy of the steps to drift out of sync.
#
#   bin/ci.sh            run every stage against the repo this script lives in
#   FM_ROOT=/path        run against another tree (used by the tests)
#   FM_CI_MAX_SECONDS=600 select an explicit elapsed-time budget (default 180)
#   FM_CI_JOBS=N         run N bash suites at once (default: online CPUs, at
#                        most 6); FM_CI_JOBS=1 is the one-at-a-time run
set -uo pipefail

# Bound the string before arithmetic, avoiding overflow, octal interpretation,
# and accidental unlimited runs. An explicitly empty value is invalid.
ci_max_seconds="${FM_CI_MAX_SECONDS-180}"
if [[ ! "$ci_max_seconds" =~ ^[1-9][0-9]{0,3}$ ]] || [ "$ci_max_seconds" -gt 3600 ]; then
  printf '%s\n' 'ci: FM_CI_MAX_SECONDS must be a decimal integer from 1 to 3600 (no leading zeros); unset it for 180' >&2
  exit 64
fi
# The pool's width. Every suite still runs, every assertion in it still
# counts, and the budget above is unchanged; what changes is how many run at
# once. Six is the cap because past it the suites that start servers and
# workers spend the extra width waiting on each other, not on the CPU.
ci_cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)"
[[ "$ci_cpus" =~ ^[1-9][0-9]*$ ]] || ci_cpus=1
if [ -n "${FM_CI_JOBS+set}" ]; then
  ci_jobs="$FM_CI_JOBS"
  if [[ ! "$ci_jobs" =~ ^[1-9][0-9]?$ ]]; then
    printf '%s\n' 'ci: FM_CI_JOBS must be a decimal integer from 1 to 99 (no leading zeros); unset it for the CPU count' >&2
    exit 64
  fi
else
  ci_jobs="$ci_cpus"
  [ "$ci_jobs" -le 6 ] || ci_jobs=6
fi
# Playwright runs beside the pool, so the two share the machine rather than
# each taking all of it: half the CPUs, at most the four the config asks
# for. On a 4-vCPU runner, four browsers beside four suites starved the
# browsers until their waits ran out.
e2e_workers=$((ci_cpus / 2))
[ "$e2e_workers" -ge 1 ] || e2e_workers=1
[ "$e2e_workers" -le 4 ] || e2e_workers=4
printf 'ci: effective budget: %ss\n' "$ci_max_seconds"
printf 'ci: bash suites: %s at a time\n' "$ci_jobs"
printf 'ci: end-to-end: %s workers\n' "$e2e_workers"

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

# --- the slow work starts first, and all of it at once -------------------
# The bash suites go through a bounded pool, and the shellcheck and
# end-to-end stages run beside it. Nothing is printed from the background:
# each job writes to its own log, and the stages below print those logs in
# the order they always have, so the transcript reads the same whatever
# finished first.
#
# The logs live in a mktemp directory, never under FM_ROOT: the gate is run
# against other trees, and tests/ci.test.sh's fixture cache is keyed on the
# tree's contents - a gate that wrote into it would never hit that cache.
ci_tmp="$(mktemp -d "${TMPDIR:-/tmp}/fm-ci.XXXXXX")" || { echo "ci: mktemp failed" >&2; exit 70; }
bg_pids=''
# an interrupted gate takes its jobs with it; the pool passes the signal on
# to the suites it is running
ci_cleanup() {
  # shellcheck disable=SC2086  # a list of pids, split on purpose
  [ -z "$bg_pids" ] || kill $bg_pids 2>/dev/null
  rm -rf "$ci_tmp"
}
trap ci_cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

# end-to-end: decided now, run in the background, reported in its place
e2e_state=run
if [ ! -d tests/e2e ]; then e2e_state=no-suite
elif ! command -v bunx >/dev/null 2>&1; then e2e_state=no-bunx
elif [ ! -d node_modules/@playwright ]; then e2e_state=no-playwright
fi
# One background stage: its command, its own log and its exit status. The
# stage shell passes a signal on to the command, or killing the gate would
# kill the shell and leave playwright's browsers running.
run_stage() {   # run_stage <name> <command...>
  local name="$1" c=''
  shift
  trap '[ -z "$c" ] || kill "$c" 2>/dev/null; exit 143' TERM INT HUP
  "$@" > "$ci_tmp/$name.log" 2>&1 < /dev/null &
  c=$!
  wait "$c"
  echo "$?" > "$ci_tmp/$name.rc"
}
if [ "$e2e_state" = run ]; then
  run_stage e2e bunx playwright test --workers="$e2e_workers" &
  e2e_pid=$!; bg_pids="$bg_pids $e2e_pid"
fi

# The bash suites, glob order being the order they are reported in.
suites=(tests/*.test.sh)
# Slowest first, so the long ones are not the last to start. The three the
# gate has always spent longest on lead by name; the rest follow by size,
# which is the proxy for the rest. FM_CI_JOBS=1 keeps glob order, which is
# the one-at-a-time run exactly as it was.
pool_order() {
  local i t
  if [ "$ci_jobs" -eq 1 ]; then
    for i in "${!suites[@]}"; do printf '%s\n' "$i"; done
    return
  fi
  for i in "${!suites[@]}"; do
    t="${suites[$i]}"
    case "$t" in
      tests/herdr.test.sh|tests/reconcile.test.sh|tests/worker.test.sh)
        printf '%s %s\n' 999999999 "$i" ;;
      *) printf '%s %s\n' "$(wc -c < "$t" | tr -d ' ')" "$i" ;;
    esac
  done | sort -k1,1nr -k2,2n | cut -d' ' -f2
}
# One suite: the environment the noise check below depends on, standard
# input closed, and its own log - to a file, never $(...): a suite that
# starts a server leaves a child holding its output, and a command
# substitution waits for that to close. A small wrapper waits for the suite
# and writes its exit status beside the log, renamed into place so a status
# file that exists is a whole one.
run_suite() {   # run_suite <index>
  local i="$1" c=''
  trap '[ -z "$c" ] || kill "$c" 2>/dev/null; exit 143' TERM INT HUP
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
  LC_ALL='' LC_MESSAGES=C bash "${suites[$i]}" > "$ci_tmp/suite.$i.log" 2>&1 < /dev/null &
  c=$!
  wait "$c"
  printf '%s\n' "$?" > "$ci_tmp/suite.$i.part" && mv "$ci_tmp/suite.$i.part" "$ci_tmp/suite.$i.rc"
}
# The pool is a background shell of its own, so the stages that print
# before the bash suites can do so while they run. bash 3.2 has no
# `wait -n`, so it polls: a slot is free when a suite it started has
# written its status.
run_pool() {
  local i started=0 live=''
  # shellcheck disable=SC2086  # a list of pids, split on purpose
  trap '[ -z "$live" ] || kill $live 2>/dev/null; exit 143' TERM INT HUP
  for i in $(pool_order); do
    while :; do
      set -- "$ci_tmp"/suite.*.rc      # nullglob: $# is how many have finished
      [ $((started - $#)) -lt "$ci_jobs" ] && break
      sleep 0.1
    done
    run_suite "$i" &
    live="$live $!"
    started=$((started + 1))
  done
  wait
}
if [ ${#suites[@]} -gt 0 ]; then
  run_pool < /dev/null &
  pool_pid=$!; bg_pids="$bg_pids $pool_pid"
fi

scripts=(bin/*.sh bin/adapters/*.sh tests/*.sh)  # adapters too: bin/*.sh does not recurse
if [ ${#scripts[@]} -gt 0 ] && command -v shellcheck >/dev/null 2>&1; then
  run_stage shellcheck shellcheck -x -S warning "${scripts[@]}" &
  shellcheck_pid=$!; bg_pids="$bg_pids $shellcheck_pid"
fi

stage "shellcheck"
if [ ${#scripts[@]} -eq 0 ]; then
  skip "no shell scripts"
elif command -v shellcheck >/dev/null 2>&1; then
  wait "$shellcheck_pid"
  if [ "$(cat "$ci_tmp/shellcheck.rc" 2>/dev/null)" = 0 ]; then
    pass "${#scripts[@]} scripts clean"
  else
    flunk "shellcheck"; printf '%s\n' "$(cat "$ci_tmp/shellcheck.log")"
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
            #
            # And the guard has to be a COMMAND, not the four letters
            # somewhere to the left. `echo "you need a value"; v="$2";
            # shift 2` passed a column comparison, and so did `die "need
            # a value"` and a `usage()` helper defined above the loop
            # whose message happens to say the word. So every candidate
            # is checked for what precedes it: a command starts a
            # segment, or follows ; ( ) { } & | then do else.
            function guardcol(seg,   s, off, pre, c) {
              off = 0; s = seg
              while (match(s, /(fm_)?need[ \t]+[^;[:space:]]/)) {
                pre = substr(s, 1, RSTART - 1)
                sub(/[ \t]+$/, "", pre)
                c = (pre == "") ? "" : substr(pre, length(pre), 1)
                if (pre == "" || c == ";" || c == "(" || c == ")" || c == "{" \
                    || c == "}" || c == "&" || c == "|" \
                    || pre ~ /(^|[ \t])(then|do|else)$/)
                  return off + RSTART
                off += RSTART + RLENGTH - 1
                s = substr(s, RSTART + RLENGTH)
              }
              return 0
            }
            # a new case pattern also ends the previous branch: a branch
            # written without `;;` before the next one - or a guard that
            # lives in a function above the loop - must not carry over
            /^[[:space:]]*[^[:space:]()]+\)([[:space:]]|$)/ { seen = 0 }
            { rest = $0
              while (1) {
                p = index(rest, ";;")
                seg = p ? substr(rest, 1, p - 1) : rest
                sp = index(seg, "shift 2")
                gp = guardcol(seg)
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
#
# The test suites are read too, and every directory below them (T-103): the
# lint read bin/ alone, and tests/adapter-contract.test.sh's completeness
# loop reported a signature that matched as unread, a different one each
# CI run.
#
# One regex over one line read one spelling of the construct and let the
# others through: `grep -Eq` (the flag was looked for as the first letter
# only), `| grep -m 1 -q`, `| grep pat -q` (GNU grep permutes), `egrep -q`,
# `| LC_ALL=C grep -q`, and a pipe that ends one line with grep starting
# the next. And it flagged `cmd || grep -q x file`, which has no pipe. So
# the stage reads the command instead: comments off (fm_strip_comments,
# the loop stage's stripper), continuation lines joined, `||` taken out,
# and each command that a single `|` starts is checked for being grep,
# egrep or fgrep, with -q/-c anywhere in its options, stepping over the
# value of an option that takes one. In front of grep it steps over `!`,
# `{`, `(`, NAME=value assignments, and the wrappers in the BEGIN table
# below with their own options (and their values: `env -u NAME`,
# `nice -n 5`, `timeout -s KILL 5`, `stdbuf -o L`). Options are read the
# way getopt reads them, on both sides: a cluster whose last letter takes a
# value takes the next word (`env -iu NAME`, `timeout -vs KILL 5`), and a
# long option may be any prefix that names one option (`grep --quie`,
# `env --un NAME`); an ambiguous one (`grep --co`) is refused by grep and
# not flagged. What it does not catch:
# grep behind any other command (`xargs`, `sudo`, ...), behind a function
# or alias of another name, a flag held in a variable, or a `-q`/`-c` that
# comes after a grep operand holding `|`, `;`, `&`, `)` or a backtick
# (`grep -E '(a|b)' -q`, `grep -e 'a;b' -q`): quotes are transparent, so
# that character ends grep's words where it stands.
# Quotes are transparent on purpose: a pipe inside `assert_ok "..."` is
# eval'd, so it is as live as one in the code.
pipe_awk='
  BEGIN {
    # wrapper -> its short options that take a separate value, all its long
    # ones, and how many operands it reads before the command; gl holds the
    # long ones of grep. A long option is name:kind (v takes a separate value, q is
    # quiet or count, o is anything else), all of them, so an abbreviation
    # getopt_long accepts resolves the way getopt_long resolves it
    wv["env"] = "uC"
    wl["env"] = "ignore-environment:o null:o unset:v chdir:v split-string:o block-signal:o default-signal:o ignore-signal:o list-signal-handling:o debug:o help:o version:o"
    wv["nice"] = "n";     wl["nice"] = "adjustment:v help:o version:o"
    wv["time"] = "fo"
    wl["time"] = "format:v output:v append:o portability:o verbose:o quiet:o help:o version:o"
    wv["timeout"] = "sk"; wp["timeout"] = 1
    wl["timeout"] = "foreground:o kill-after:v preserve-status:o signal:v verbose:o help:o version:o"
    wv["stdbuf"] = "ioe"; wl["stdbuf"] = "input:v output:v error:v help:o version:o"
    wv["exec"] = "a";     wl["exec"] = ""
    wv["command"] = "";   wl["command"] = ""
    wv["builtin"] = "";   wl["builtin"] = ""
    wv["nohup"] = "";     wl["nohup"] = ""
    gl = "after-context:v before-context:v basic-regexp:o binary:o binary-files:v byte-offset:o color:o colour:o context:v count:q dereference-recursive:o devices:v directories:v exclude:v exclude-dir:v exclude-from:v extended-regexp:o file:v files-with-matches:o files-without-match:o fixed-strings:o group-separator:v help:o ignore-case:o include:v initial-tab:o invert-match:o label:v line-buffered:o line-number:o line-regexp:o max-count:v no-filename:o no-group-separator:o no-ignore-case:o no-messages:o null:o null-data:o only-matching:o perl-regexp:o quiet:q recursive:o regexp:v silent:q text:o version:o with-filename:o word-regexp:o"
  }
  # the kind of long option l (no leading --) in table tab: an exact name,
  # else every name it is a prefix of, if they agree; "" when unknown or
  # ambiguous, which getopt_long refuses
  function lkind(l, tab,   n, e, i, name, k, got) {
    sub(/=.*/, "", l)
    if (l == "") return ""
    n = split(tab, e, " "); got = ""
    for (i = 1; i <= n; i++) {
      k = substr(e[i], length(e[i])); name = substr(e[i], 1, length(e[i]) - 2)
      if (name == l) return k
      if (index(name, l) == 1) got = (got == "" || got == k) ? k : "?"
    }
    return got == "?" ? "" : got
  }
  function hazard(s,   n, seg, i, cut, ntok, tok, j, k, t, p, c, w, mode, opts, pos) {
    gsub(sq, "", s); gsub(/"/, "", s); gsub(/\\/, "", s)
    n = split(s, seg, /[|]/)
    for (i = 2; i <= n; i++) {
      cut = seg[i]; sub(/^&/, "", cut)       # |& is a pipe too
      if (match(cut, /[;&)`]/)) cut = substr(cut, 1, RSTART - 1)
      ntok = split(cut, tok)
      mode = ""; opts = 0; pos = 0
      for (j = 1; j <= ntok; j++) {
        t = tok[j]
        if (opts && t == "--") { opts = 0; continue }
        if (opts && t ~ /^-./) {
          if (t ~ /^--/) {
            if (!index(t, "=") && lkind(substr(t, 3), wl[mode]) == "v") j++
            continue
          }
          # a cluster: the first letter that takes a value takes the rest
          # of the word, or the next word when it is the last letter
          for (p = 2; p <= length(t); p++)
            if (index(wv[mode], substr(t, p, 1))) { if (p == length(t)) j++; break }
          continue
        }
        opts = 0
        if (pos > 0) { pos--; continue }
        if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || t ~ /^(!|[{(])$/) continue
        w = t; sub(/.*\//, "", w)
        if (w in wv) { mode = w; opts = 1; pos = wp[w] + 0; continue }
        break
      }
      if (j > ntok) continue
      w = tok[j]; sub(/.*\//, "", w)
      if (w !~ /^[ef]?grep$/) continue
      for (k = j + 1; k <= ntok; k++) {
        t = tok[k]
        if (t == "--") break
        if (t ~ /^--/) {
          c = lkind(substr(t, 3), gl)
          if (c == "q") return 1
          if (c == "v" && !index(t, "=")) k++
          continue
        }
        if (t !~ /^-[A-Za-z]/) continue
        for (p = 2; p <= length(t); p++) {
          c = substr(t, p, 1)
          if (c == "q" || c == "c") return 1
          if (index("efmABCdD", c)) { if (p == length(t)) k++; break }
        }
      }
    }
    return 0
  }
  { s = $0; gsub(/[|][|]/, ";", s)
    if (buf == "") { start = FNR; text = $0 } else text = text " " $0
    if (s ~ /\\$/) { sub(/\\$/, "", s); buf = buf s " "; next }
    if (s ~ /[|][ \t]*$/) { buf = buf s " "; next }
    buf = buf s
    if (hazard(buf)) print start ":" text
    buf = ""
  }
  END { if (buf != "" && hazard(buf)) print start ":" text }'
pipefiles=()
while IFS= read -r f; do pipefiles+=("$f"); done < <(
  fm_shell_corpus bin
  [ ! -d tests ] || fm_shell_corpus tests)
piped=''
[ ${#pipefiles[@]} -eq 0 ] || for f in "${pipefiles[@]}"; do
  fm_is_lint_source "$f" && continue
  hits="$(fm_strip_comments "$f" | awk -v sq="'" "$pipe_awk" || true)"
  [ -z "$hits" ] || piped="$piped$(sed "s|^|$f:|" <<<"$hits")
"
done
if [ -n "$piped" ]; then
  flunk "a pipeline feeds grep -q or -c; use a here-string"
  printf '%s\n' "$piped"
else
  pass "nothing feeds grep -q through a pipe (${#pipefiles[@]} scripts)"
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
    grep -qx "$a" <<<"$defined" || missing="$missing $a"
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
# a task list is a directory, one file per task (T-090), checked once for
# every registered project (design section 15.2): every file parses, its id
# is its file name, its dependencies exist, and nothing waits on itself.
# Nothing generated is committed, so there is no copy to agree with. A tree
# with no registry has the one directory, design/tasks.
dag_check() {   # dag_check <label> <dir>
  local label="$1" dir="$2" problems n
  if problems="$(fm_tasks_check "$dir" 2>&1)"; then
    n="$(find "$dir" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
    pass "${label}every task file parses, is named by its id, and depends only on tasks that exist, with no cycle ($n tasks)"
  else
    flunk "${label}the task list is not a sound DAG:"
    printf '%s\n' "$problems" | sed 's/^/      /'
  fi
}
if ! registry="$(fm_projects config.yaml 2>&1)"; then
  flunk "the project registry: $registry"
elif [ -z "$registry" ]; then
  if [ -e design/tasks ] || [ -e design/tasks.json ]; then
    dag_check '' design/tasks
  else
    skip "no DAG yet"
  fi
else
  for name in $registry; do
    tasks="$(fm_project_get "$name" tasks config.yaml)" \
      || { flunk "project ${name}: its registry entry does not resolve"; continue; }
    if [ -d "$tasks" ]; then
      dag_check "project ${name} ($tasks): " "$tasks"
    else
      flunk "project ${name}: $tasks does not exist"
    fi
  done
fi

stage "bash tests"
if [ ${#suites[@]} -eq 0 ]; then
  skip "no suites yet"
else
  # the pool ran them in whatever order it did; they are reported in glob
  # order, each from its own log, as if they had run one after another
  wait "$pool_pid"
  for i in "${!suites[@]}"; do
    t="${suites[$i]}"
    tmp="$ci_tmp/suite.$i.log"
    # no status file is a suite that never finished, which is not a pass
    if [ "$(cat "$ci_tmp/suite.$i.rc" 2>/dev/null)" = 0 ]; then
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
      flunk "$t"; cat "$tmp" 2>/dev/null
    fi
  done
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
# started at the top, beside the pool; reported here, in its old place
case "$e2e_state" in
  no-suite) skip "no e2e suite yet" ;;
  no-bunx)  skip "bunx not installed" ;;
  # an uninstalled browser is a missing tool, not a red gate: say so loudly
  # rather than failing a machine that has not run bun install yet
  no-playwright) skip "playwright not installed (bun install && bunx playwright install chromium)" ;;
  *)
    wait "$e2e_pid"
    out="$(cat "$ci_tmp/e2e.log" 2>/dev/null)"
    if [ "$(cat "$ci_tmp/e2e.rc" 2>/dev/null)" = 0 ]; then
      pass "playwright: $(printf '%s' "$out" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) passed.*/\1/p' | tail -1) browser tests"
    else
      flunk "playwright"; printf '%s\n' "$out"
    fi
    ;;
esac

# Measure the full gate without interrupting or bypassing functional checks.
took=$(( $(date +%s) - started_at ))
printf '\n%s took %ss (effective budget: %ss)%s\n' "$dim" "$took" "$ci_max_seconds" "$off"
if [ "$took" -gt "$ci_max_seconds" ]; then
  flunk "the gate took ${took}s, exceeds effective budget of ${ci_max_seconds}s"
fi
if [ "$fail" -eq 0 ]; then printf '%sci: green%s\n' "$green" "$off"; else printf '%sci: red%s\n' "$red" "$off"; fi
# every job was waited for above; a pid that has been reaped may belong to
# somebody else by now, so the exit trap has nothing left to signal
bg_pids=''
exit "$fail"
