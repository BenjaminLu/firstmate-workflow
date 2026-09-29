#!/usr/bin/env bash
# Fail-first, run by the machine (T-153). A reviewer used to prove it by hand
# inside its round's sandbox, where the suites that start rounds of their own
# cannot run; GitHub's runner has no outer sandbox, so the `fail-first` job
# runs this on every pull request and the review reads its report.
#
#   fm-failfirst.sh [--report <file>] [--setup <command>] [--jobs <n>] <base-ref>
#
# Run from the checkout of the head. From the merge-base of <base-ref> and
# HEAD it lists the test files the change adds or modifies (the project's
# declared `tests` globs; tests/**, *.test.* and *.spec.* when none are
# declared) and the non-test files it changes. It makes two worktrees of the
# head: in one, the "base" tree, every changed non-test file is put back as
# the merge-base has it and every file the change adds is removed; the head's
# tests stay. It runs each changed suite in both trees, through the declared
# `test` template, and compares them assertion by assertion: an assertion
# that passes on the head and fails on the base - or is never reached there,
# the base's run having failed - went red on base; one that passes on both is
# a guard. The head is re-run here, beside the base, not read from CI's
# shards: both runs then see the same runner and the same setup.
#
# The verdict:
#   not applicable - the change touches no behaviour: no non-test file under
#                    bin/, board/ or adapters/ (docs, skills, tests, CI only)
#   fail           - it does, and no assertion of a changed suite went red on
#                    base, or it changes no suite the `test` template runs
#   pass           - it does, and at least one did
# The report says which and why, and per suite lists the assertions that went
# red on base by name and the guards. It goes to stdout, to --report, and to
# $GITHUB_STEP_SUMMARY when that is set.
#
# --setup replaces the declared `setup`, run in each tree before its suites
# (CI passes the dependency install alone: the suites need no browser).
# --jobs is how many suite runs go at once (default: online CPUs, at most 6).
#
# Exit: 0 pass or not applicable, 1 fail, 64 usage, 70 it could not run.
set -uo pipefail
# Nothing below may read standard input; see fm-gate.sh.
exec < /dev/null

REPORT=''; SETUP=''; SETUP_GIVEN=''; JOBS=''; BASE_REF=''
need() { [ "$#" -ge 2 ] || { echo "fm-failfirst: $1 needs a value" >&2; exit 64; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --report) need "$@"; REPORT="${2-}"; shift 2 ;;
    --setup) need "$@"; SETUP="${2-}"; SETUP_GIVEN=1; shift 2 ;;
    --jobs) need "$@"; JOBS="${2-}"; shift 2 ;;
    -*) echo "fm-failfirst: unknown argument $1" >&2; exit 64 ;;
    *) [ -z "$BASE_REF" ] || { echo "fm-failfirst: one base ref, not $1 as well" >&2; exit 64; }
       BASE_REF="$1"; shift ;;
  esac
done
[ -n "$BASE_REF" ] || {
  echo "usage: fm-failfirst.sh [--report <file>] [--setup <command>] [--jobs <n>] <base-ref>" >&2; exit 64; }
case "$JOBS" in
  '') JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
      case "$JOBS" in ''|*[!0-9]*|0) JOBS=2 ;; esac
      [ "$JOBS" -le 6 ] || JOBS=6 ;;
  *[!0-9]*|0) echo "fm-failfirst: --jobs must be a positive integer" >&2; exit 64 ;;
esac

_fm_lib="$(dirname "${BASH_SOURCE[0]}")/fm-config.sh"
[ -f "$_fm_lib" ] || { echo "${0##*/}: missing $_fm_lib" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$_fm_lib"

say() { echo "fm-failfirst: $*" >&2; }
REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { say "not inside a git checkout"; exit 70; }
cd "$REPO" || exit 70
HEAD_SHA="$(git rev-parse --verify -q 'HEAD^{commit}')" || { say "no HEAD commit"; exit 70; }
git rev-parse --verify -q "$BASE_REF^{commit}" >/dev/null || { say "no such base ref: $BASE_REF"; exit 70; }
MB="$(git merge-base "$BASE_REF" "$HEAD_SHA")" || { say "no merge-base between $BASE_REF and HEAD"; exit 70; }

work="$(mktemp -d "${TMPDIR:-/tmp}/fm-failfirst.XXXXXX")" || exit 70
cleanup() {
  local t
  for t in head base; do
    [ -d "$work/$t" ] && git -C "$REPO" worktree remove --force "$work/$t" >/dev/null 2>&1
  done
  rm -rf "$work"
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# The head's own declaration, as gate 5 reads the branch's.
P_SETUP=''; P_TEST=''; P_TESTS=''; P_ENV=()
if git show "$HEAD_SHA:config.yaml" > "$work/config.yaml" 2>/dev/null && [ -s "$work/config.yaml" ]; then
  P_SETUP="$(fm_project setup "$work/config.yaml")" || { say "config.yaml's project block does not read"; exit 70; }
  P_TEST="$(fm_project test "$work/config.yaml")" || exit 70
  P_TESTS="$(fm_project tests "$work/config.yaml")" || exit 70
  while IFS= read -r -d '' kv; do P_ENV+=("$kv"); done < <(fm_project check_env "$work/config.yaml")
fi
[ -n "$SETUP_GIVEN" ] || SETUP="$P_SETUP"

# matches <path> <globs, one per line>; a leading **/ also matches at the top
# level (fm-gate.sh's own rule)
matches() {
  local g
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    # shellcheck disable=SC2254
    case "$1" in $g) return 0 ;; esac
    # shellcheck disable=SC2254
    case "$g" in '**/'*) case "$1" in ${g#\*\*/}) return 0 ;; esac ;; esac
  done <<< "$2"
  return 1
}
is_test() {
  if [ -z "$P_TESTS" ]; then
    case "$1" in tests/*|*.test.*|*.spec.*) return 0 ;; *) return 1 ;; esac
  fi
  matches "$1" "$P_TESTS"
}
# what behaves: code a round, the board or an adapter runs
is_behaviour() { case "$1" in bin/*|board/*|adapters/*|*/adapters/*) return 0 ;; *) return 1 ;; esac; }
# fill <template> <file>: every {file} becomes the shell-quoted path
fill() {
  local rest="$1" q out=''
  q="$(printf '%q' "$2")"
  while [[ "$rest" == *'{file}'* ]]; do
    out="$out${rest%%\{file\}*}$q"; rest="${rest#*\{file\}}"
  done
  printf '%s' "$out$rest"
}

: > "$work/suites"; : > "$work/behaviour"; : > "$work/restored"; : > "$work/removed"; : > "$work/other"
while IFS=$'\t' read -r st path; do
  [ -n "$path" ] || continue
  if is_test "$path"; then
    [ "$st" = D ] || printf '%s\n' "$path" >> "$work/suites"
    continue
  fi
  if [ "$st" = A ]; then printf '%s\n' "$path" >> "$work/removed"
  else printf '%s\n' "$path" >> "$work/restored"; fi
  if is_behaviour "$path"; then printf '%s\n' "$path" >> "$work/behaviour"
  else printf '%s\n' "$path" >> "$work/other"; fi
done < <(git diff --name-status --no-renames "$MB" "$HEAD_SHA")

verdict=''; reason=''
if [ ! -s "$work/behaviour" ]; then
  verdict='not applicable'
  if [ ! -s "$work/restored" ] && [ ! -s "$work/removed" ]; then
    reason='the change touches only tests: no behaviour to revert'
  else
    reason='the change touches no behaviour (nothing under bin/, board/ or adapters/): only docs, skills, CI or other non-code files'
  fi
elif [ ! -s "$work/suites" ]; then
  verdict='fail'; reason='the change modifies behaviour and adds or changes no test suite'
elif [ -z "$P_TEST" ]; then
  verdict='fail'; reason="config.yaml declares no project.test to run a changed suite with"
fi

# --- the two trees, and every changed suite run in both ---------------------
# One run, as xargs hands it over: <tree> <suite index> <command> <output
# prefix>. The shell running it is the session of whatever the suite starts,
# as bin/ci.sh makes a suite's runner, so nothing outlives it (T-151); the
# shell's own messages are pinned to C, as there.
IFS= read -r -d '' ONE_SH <<'SH'
#!/usr/bin/env bash
cd "$1" || exit 70
me="$(exec sh -c 'echo "$PPID"')"
FIRSTMATE_CI_SESSION="$me" FM_SESSION_PID="$me" FM_ROOT="$1" LC_ALL='' LC_MESSAGES=C \
  bash -c "$3" > "$4.log" 2>&1 < /dev/null
printf '%s\n' "$?" > "$4.rc"
SH
if [ -z "$verdict" ]; then
  for t in head base; do
    git worktree add -q --detach "$work/$t" "$HEAD_SHA" >/dev/null 2>&1 || {
      say "could not make the $t worktree"; exit 70; }
  done
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    git -C "$work/base" checkout -q "$MB" -- "$f" 2>/dev/null || { say "could not restore $f from $MB"; exit 70; }
  done < "$work/restored"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rm -f "$work/base/$f"
  done < "$work/removed"
  if [ -n "$SETUP" ]; then
    for t in head base; do
      ( cd "$work/$t" && env FM_ROOT="$work/$t" bash -c "$SETUP" ) > "$work/setup.$t.log" 2>&1 || {
        say "setup failed in the $t tree: $SETUP"; tail -n 20 "$work/setup.$t.log" >&2; exit 70; }
    done
  fi
  # one run: its tree, the suite's index, and what it runs. Each has its own
  # session - the shell running it, which ends with it - as bin/ci.sh gives
  # a suite, so nothing it starts outlives it (T-151).
  mkdir -p "$work/runs"
  printf '%s' "$ONE_SH" > "$work/one.sh"
  : > "$work/list"
  i=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    cmd="$(fill "$P_TEST" "$f")"
    for t in head base; do
      printf '%s\0%s\0%s\0%s\0' "$work/$t" "$i" "$cmd" "$work/runs/$t.$i" >> "$work/list"
    done
    i=$((i + 1))
  done < "$work/suites"
  say "running $i changed suite(s) on the head and on the base, $JOBS at a time"
  env ${P_ENV[@]+"${P_ENV[@]}"} xargs -0 -n 4 -P "$JOBS" bash "$work/one.sh" < "$work/list"
fi

# --- the report -------------------------------------------------------------
IFS= read -r -d '' REPORT_PY <<'PY'
import os, re, sys

work, verdict, reason, base_ref, mb, head = sys.argv[1:7]
line = re.compile(r'^    (.+?) *(ok|FAIL)$')


def read(path):
    try:
        with open(path, errors='replace') as f:
            return f.read()
    except OSError:
        return None


def lines(path):
    return [x for x in (read(path) or '').splitlines() if x]


def outcomes(text):
    seen, out = {}, []
    for raw in (text or '').splitlines():
        m = line.match(raw)
        if not m:
            continue
        name = m.group(1).strip()
        seen[name] = seen.get(name, 0) + 1
        out.append(((name, seen[name]), m.group(2)))
    return out


def code(s):
    return '`%s`' % s.replace('`', "'")


suites = lines(os.path.join(work, 'suites'))
sections, red_total = [], 0
if not verdict:
    for i, suite in enumerate(suites):
        runs = os.path.join(work, 'runs')
        h_log, b_log = read(os.path.join(runs, 'head.%d.log' % i)), read(os.path.join(runs, 'base.%d.log' % i))
        h_rc = (read(os.path.join(runs, 'head.%d.rc' % i)) or '?').strip()
        b_rc = (read(os.path.join(runs, 'base.%d.rc' % i)) or '?').strip()
        head_o, base_o = outcomes(h_log), dict(outcomes(b_log))
        red, guard, head_red = [], [], []
        for key, st in head_o:
            name = key[0] + (' (#%d)' % key[1] if key[1] > 1 else '')
            if st == 'FAIL':
                head_red.append(name)
            elif base_o.get(key) == 'FAIL':
                red.append((name, 'FAIL on base'))
            elif key not in base_o and b_rc != '0':
                red.append((name, 'not reached on base, whose run exited %s' % b_rc))
            elif base_o.get(key) == 'ok':
                guard.append(name)
        s = ['### %s' % suite, '', 'head exit %s, base exit %s' % (h_rc, b_rc), '']
        if not head_o:
            if h_rc == '0' and b_rc not in ('0', '?'):
                red.append(('the suite as a whole', 'exited %s on base and 0 on head; it prints no assertion lines' % b_rc))
            elif h_rc == '0':
                s += ['The project\'s `test` template ran no assertion of it (it printed none), so it shows nothing either way.', '']
        red_total += len(red)
        s.append('Red on base (%d):' % len(red))
        s += ['- %s: %s' % (code(n), why) for n, why in red] or ['- none']
        s += ['', 'Guard, green on base too (%d):' % len(guard)]
        s += ['- %s' % code(n) for n in guard] or ['- none']
        if head_red:
            s += ['', 'Failing on the head itself (%d), counted neither way:' % len(head_red)]
            s += ['- %s' % code(n) for n in head_red]
        sections.append('\n'.join(s))
    if red_total:
        verdict, reason = 'pass', '%d assertion(s) of the changed suites went red on base' % red_total
    else:
        verdict, reason = 'fail', 'the change modifies behaviour and no assertion of a changed suite went red on base'

out = ['## Fail-first: %s' % verdict, '', reason[0].upper() + reason[1:] + '.', '',
       '- base: `%s`, the merge-base of HEAD with %s' % (mb, base_ref),
       '- head: `%s`' % head]
behaviour = lines(os.path.join(work, 'behaviour'))
restored, removed = lines(os.path.join(work, 'restored')), lines(os.path.join(work, 'removed'))
out.append('- behaviour changed: ' + (', '.join(code(x) for x in behaviour) or 'none'))
out.append('- changed suites: ' + (', '.join(code(x) for x in suites) or 'none'))
if sections:
    out.append('- in the base tree: %d changed non-test file(s) restored to the merge-base, %d the change adds removed'
               % (len(restored), len(removed)))
    out.append('- the head was re-run in this job beside the base, not read from CI\'s shards')
out.append('')
out += [x + '\n' for x in sections]
print('\n'.join(out).rstrip('\n'))
sys.exit(3 if verdict == 'fail' else 0)
PY
python3 -c "$REPORT_PY" "$work" "$verdict" "$reason" "$BASE_REF" "$MB" "$HEAD_SHA" > "$work/report.md"
case "$?" in
  0) rc=0 ;;
  3) rc=1 ;;
  *) say "the report could not be written"; exit 70 ;;
esac
cat "$work/report.md"
[ -z "$REPORT" ] || cp "$work/report.md" "$REPORT" || { say "could not write $REPORT"; exit 70; }
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || cat "$work/report.md" >> "$GITHUB_STEP_SUMMARY"
exit "$rc"
