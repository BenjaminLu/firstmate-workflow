#!/usr/bin/env bash
# `shift 2` with one argument left does not shift. It returns 1 and leaves
# $@ alone, so `while [ $# -gt 0 ]` spins on the same flag for ever - a
# busy loop, not an error, on `bin/fm-emit.sh --type`.
#
# Two things this file has to get right about itself:
#
#   - Every assertion runs under an alarm. A test for a hang that simply
#     calls the script hangs the gate instead of failing it, which is the
#     difference between a suite that catches this and a suite that
#     becomes it. The alarm is asserted first, or the rest pass vacuously.
#
#   - The corpus is pinned, not scraped. Discovering the scripts and their
#     flags by grepping the files under test means a script that stops
#     matching the grep contributes nothing and the suite stays green -
#     all but one of them could drop out silently. The names and counts are
#     written down here, and the discovery is checked against them.
set -uo pipefail
# A live managed worker exports FM_RUN_DIR / FM_ENTRY_* / FM_WORKER_TASK_LOCK_FD
# and Herdr pane ids into this shell. Suites must not inherit them or freeze,
# identity, locks and pushes bind to the outer run instead of the fixture.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The helpers this file leans on are defined in tests/lib.sh. An earlier
# version of this comment inventoried them by hand, with line numbers,
# and got the list wrong - and then the sentence saying so went stale
# too, because the file grew a call to the very helper it claimed never
# to use. So there is no inventory here at all: bin/ci.sh checks every
# assert_* call in tests/ against what lib.sh defines, which is a list
# that cannot go out of date because nobody maintains it.
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# The corpus and the comment stripper come from the same file bin/ci.sh
# reads them from. This suite exists to catch the gate missing a script,
# so a second copy of the rule here is a check that agrees with itself.
# shellcheck source=bin/fm-config.sh
. "$ROOT/bin/fm-config.sh" || { echo "option-loop: no bin/fm-config.sh" >&2; exit 70; }

# Scripts and distinct value-taking flag names. fm repeats --repo in three
# subcommands; its seven parser branches are exercised separately below.
PINNED="fm 5
fm-checkpoint 5
fm-cleanup 2
fm-decide 10
fm-diagram 4
fm-dispatch 3
fm-emit 8
fm-gate 5
fm-merge 4
fm-project 1
fm-protocol 4
fm-ready 3
fm-reconcile 2
fm-review 7
fm-run 2
fm-session 2
fm-sync-prs 2
fm-worker 5"

# perl's alarm rather than timeout(1), which macOS does not ship. Both the
# code and what was said are captured: half of criterion 2 is "says which
# flag", and a helper that returns only a status cannot assert it.
#
# It sets two variables rather than printing the code, because `$(...)`
# runs the function in a subshell and anything it assigns dies there - the
# first version of this file asserted against a $said that was always
# empty, which is the same "assertion that cannot fail" the reviewer has
# been finding all night.
code=''; said=''
run_capped() {   # run_capped <seconds> <cmd...> -> sets $code and $said
  local err
  err="$(mktemp)"
  perl -e 'alarm shift; exec @ARGV; exit 127' "$@" >/dev/null 2>"$err"
  code=$?
  [ "$code" = 142 ] && code=124    # SIGALRM: it never came back
  said="$(cat "$err")"; rm -f "$err"
}

run_capped 1 bash -c 'while :; do :; done'
assert_eq "124" "$code" "the alarm catches something that never returns"
run_capped 5 bash -c 'exit 0'
assert_eq "0" "$code" "and lets something that returns through"
run_capped 5 bash -c 'echo boom >&2'
assert_contains "$said" "boom" "and what the command said is captured, not swallowed"
# `tr -d 'boom\n'` is a character SET, so "mob", "oo" and "" all satisfy
# it - an assertion that cannot fail, in the file whose thesis is that
# an assertion that cannot fail is the bug. What it meant to say:
assert_eq "boom" "$(printf '%s' "$said")" "and nothing else is"

# --- every flag of every pinned script ----------------------------------
total=0
while read -r name want; do
  [ -n "$name" ] || continue
  f="$ROOT/bin/$name.sh"
  assert_ok "test -f '$f'" "$name.sh is still there"
  # discovered from the file, then checked against the pinned count, so a
  # loop written differently tomorrow fails loudly instead of quietly
  flags="$(fm_loop_flags "$f")"
  got="$(printf '%s\n' "$flags" | sed '/^$/d' | wc -l | tr -d ' ')"
  assert_eq "$want" "$got" "$name has its $want value-taking flags"
  if [ "$name" = fm ]; then
    cases='--repo lint
--repo sync-skills
--name sync-skills
--skill self-update
--why self-update
--adopt self-update
--repo self-update'
    assert_eq "$flags" "$(printf '%s\n' "$cases" | awk '{print $1}' | sort -u)" \
      "fm subcommand probes cover every discovered flag"
  else
    cases="$flags"
  fi
  while read -r flag subcommand; do
    [ -n "$flag" ] || continue
    total=$((total + 1))
    args=()
    [ -z "$subcommand" ] || args+=("$subcommand")
    args+=("$flag")
    run_capped 6 bash "$f" "${args[@]}"
    assert_eq "64" "$code" "$name $subcommand $flag with no value is refused"
    # and says which one: a message that lost $1, or the script's name, or
    # went to stdout, would pass a status-only assertion
    assert_contains "$said" "$flag" "$name $flag is named in the refusal"
    assert_contains "$said" "$name" "and so is the script"
    if [ "$name" = fm ]; then
      # A generic usage error can come from a later check or unknown-command
      # fallback. Require this option's guard to be what actually refused it.
      assert_contains "$said" "$flag requires a value" "$subcommand $flag reaches its value guard"
      run_capped 6 bash "$f" "${args[@]}" --unknown
      assert_eq "64" "$code" "$subcommand $flag rejects an option-shaped value"
      assert_contains "$said" "fm: $flag requires a value, got --unknown" \
        "$subcommand $flag refuses before consuming the next option"
    fi
  done <<< "$cases"
done <<< "$PINNED"
assert_eq "76" "$total" "every pinned flag and all seven fm option branches were exercised"

# A script that grows an option loop has to be pinned here too, and the
# corpus is the one bin/ci.sh judges - literally, out of
# bin/fm-config.sh, not a copy of the rule written out again here. The
# copy had drifted twice: it kept the comment stripper that cuts
# `${1#--}` in half after the gate's was fixed, so a script the gate
# demanded a guard from could vanish from the sweep that exists to catch
# the gate missing one, and the pinned list would agree with a sweep
# that had not looked.
loops=''
while IFS= read -r p; do
  loops="$loops$(basename "$p" .sh)
"
done < <(fm_loop_corpus "$ROOT/bin")
assert_eq "$(printf '%s\n' "$PINNED" | awk '{print $1}' | sort)" "$(printf '%s' "$loops" | sort)" \
  "the pinned list is every script that consumes a value with shift 2, and no more"
# and the corpus is not the empty set dressed up as agreement
assert_ne "" "$loops" "the corpus found scripts to compare against"

# The marker is a one-line switch that takes a script out of the gate
# AND out of the list this suite checks the gate against, in one edit,
# with nothing going red - the same shape as the non-descending glob
# above, where a file that drops out of the sweep drops out of the
# count with it. So the exempt set is pinned by name. Adding the marker
# to a real script is then a change to this line, which a reader sees.
exempt=''
while IFS= read -r f; do
  fm_is_lint_source "$f" && exempt="$exempt${f#"$ROOT"/}
"
done < <(fm_shell_corpus "$ROOT/bin")
assert_eq "bin/ci.sh
bin/fm-config.sh" "$(printf '%s' "$exempt" | sed '/^$/d' | sort)" \
  "only the two files that HOLD these rules are exempt from them"

# and nothing consumes a value any other way, which is the blind spot the
# lint and this check would otherwise share. Bare flags shift once; a
# `shift $n` or a getopts loop would be invisible to both.
# the same corpus function, so this cannot be looking at a different set
# of files from the check above it
allsh="$(fm_shell_corpus "$ROOT/bin")"
assert_ne "" "$allsh" "there are scripts to sweep"
assert_eq "" "$(printf '%s\n' "$allsh" | xargs grep -n 'shift' \
  | grep -vE 'shift 2|shift ;;|shift$|shift 1|: *#' || true)" \
  "no script consumes a value with a shift this check cannot see"
assert_eq "" "$(printf '%s\n' "$allsh" | xargs grep -l 'getopts\|OPTARG' || true)" \
  "and none of them uses getopts, which would be invisible too"

# an unknown flag is refused the same way rather than looping
run_capped 6 bash "$ROOT/bin/fm-emit.sh" --no-such-flag
assert_eq "64" "$code" "an unknown flag is refused too"
assert_contains "$said" "unknown argument" "and says so"
# Seven scripts get their guard from a sourced function, and a
# command-not-found under `set -uo pipefail` carries on - the exact hazard
# the assertions stage exists to catch. So the load has to be hard: if the
# library will not load, the script must not reach its option loop.
sourced=0
# the corpus function, not `bin/fm-*.sh`: that glob does not descend,
# which is the very reason the other sweeps use find - a script under
# bin/inner/ taking its guard from the library was never checked, and
# the count would not have noticed, because a file that drops out of the
# sweep drops out of the count with it
while IFS= read -r f; do
  # comments off: scripts that keep a local copy mention fm_need in a
  # comment pointing at the library, and a grep for the name picks them up
  grep -q 'fm_need ' <<< "$(fm_strip_comments "$f")" || continue
  sourced=$((sourced + 1))
  name="$(basename "$f")"
  tmp="$(mktemp -d)"; mkdir -p "$tmp/bin"
  cp "$f" "$tmp/bin/"                       # and NOT fm-config.sh
  run_capped 6 bash "$tmp/bin/$name" --task
  assert_eq "70" "$code" "$name refuses to start without the library it needs"
  assert_contains "$said" "fm-config.sh" "and says which library"
  rm -rf "$tmp"
done < <(fm_shell_corpus "$ROOT/bin")
assert_eq "9" "$sourced" "nine scripts take their guard from the library"

# And the other half of the same number, because two comments say it is
# pinned here and until now it was not: the scripts that deliberately
# depend on nothing and carry a two-line copy of the guard instead. The
# pair has to add up to the corpus, or one of the three numbers is
# describing a set nothing looked at.
local_copies=0
while IFS= read -r f; do
  grep -qE '^need\(\) \{' <<< "$(fm_strip_comments "$f")" || continue
  local_copies=$((local_copies + 1))
done < <(fm_shell_corpus "$ROOT/bin")
assert_eq "9" "$local_copies" "nine scripts carry a local copy of the guard"
assert_eq "$(printf '%s\n' "$PINNED" | awk 'NF {n++} END {print n+0}')" \
  "$((sourced + local_copies))" \
  "and every script with an option loop does one or the other, and not both"

finish
