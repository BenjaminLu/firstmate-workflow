#!/usr/bin/env bash
# Fail-first, run by the machine (T-153). A reviewer used to prove it by hand
# inside its round's sandbox, where the suites that start rounds of their own
# cannot run; GitHub's runner has no outer sandbox, so the `fail-first` job
# runs this on every pull request and the review reads its report.
#
#   fm-failfirst.sh [--report <file>] [--setup <command>] [--jobs <n>] <base-ref>
#   fm-failfirst.sh --shard=<i/n> --part=<file> [--setup <command>] [--jobs <n>] <base-ref>
#   fm-failfirst.sh --merge=<dir> [--report <file>] <base-ref>
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
#                    base, or it changes no suite the `test` template runs,
#                    or a changed suite was not run at all (a shard failed)
#   pass           - it does, and at least one did
# The report says which and why, and per suite lists the assertions that went
# red on base by name and the guards. It goes to stdout, to --report, and to
# $GITHUB_STEP_SUMMARY when that is set.
#
# Sharded (T-158): a large change ran past the job's limit in one job, so CI
# runs it as n shards and one merge. --shard=i/n runs only the i-th share of
# the changed suites - split by `bin/ci.sh --plan`, the very split the bash
# shards get, from the same FM_CI_TIMINGS_IN - on head and base, and writes
# what it found to --part, a JSON file; it decides no verdict, and exits 0
# once its share ran (at once when it has none), 70 when it could not run,
# its part then saying why. --merge=<dir> runs nothing: it classifies the
# change again, reads every part under <dir>, and writes the one report, the
# same report a single run writes for the same change. A changed suite no
# part reports fails it, naming the suite and its shard.
#
# --setup replaces the declared `setup`, run in each tree before its suites
# (CI passes the dependency install alone: the suites need no browser).
# --jobs is how many suite runs go at once (default: online CPUs, at most 6).
# --head=<ref> selects a branch without changing the caller's checkout.
# --gate uses declared docs exemptions and falls back to project.check when
# no suite can be determined; it shares restoration, execution and reporting.
# --contract=<file> supplies the verified JSON contract from the gate launcher;
# with it, target config.yaml is never read and --setup cannot override the pin.
#
# Exit: 0 pass or not applicable, 1 fail, 64 usage, 70 it could not run.
set -uo pipefail
# Nothing below may read standard input; see fm-gate.sh.
exec < /dev/null

# The library first: its fm_need guards the option loop, as in the other
# scripts that take it from there (tests/option-loop.test.sh pins them).
_fm_lib="$(dirname "${BASH_SOURCE[0]}")/fm-config.sh"
[ -f "$_fm_lib" ] || { echo "${0##*/}: missing $_fm_lib" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$_fm_lib"
FF_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --shard, --part and --merge take their value after `=`, in one word, as
# bin/ci.sh's --shard=i/n does.
GATE_MODE=''; HEAD_REF=HEAD; CONTRACT=''
REPORT=''; SETUP=''; SETUP_GIVEN=''; JOBS=''; BASE_REF=''; SHARD=''; PART=''; MERGE=''
while [ $# -gt 0 ]; do
  case "$1" in
    --gate) GATE_MODE=1; shift ;;
    --contract=*) CONTRACT="${1#--contract=}"; [ -n "$CONTRACT" ] || exit 64; shift ;;
    --head=*) HEAD_REF="${1#--head=}"; shift ;;
    --report) fm_need "fm-failfirst" "$@"; REPORT="${2-}"; shift 2 ;;
    --setup) fm_need "fm-failfirst" "$@"; SETUP="${2-}"; SETUP_GIVEN=1; shift 2 ;;
    --jobs) fm_need "fm-failfirst" "$@"; JOBS="${2-}"; shift 2 ;;
    --shard=*) SHARD="${1#--shard=}"; shift ;;
    --part=*) PART="${1#--part=}"; shift ;;
    --merge=*) MERGE="${1#--merge=}"; shift ;;
    --shard|--part|--merge)
      echo "fm-failfirst: $1 takes its value in the same word: $1=<value>" >&2; exit 64 ;;
    -*) echo "fm-failfirst: unknown argument $1" >&2; exit 64 ;;
    *) [ -z "$BASE_REF" ] || { echo "fm-failfirst: one base ref, not $1 as well" >&2; exit 64; }
       BASE_REF="$1"; shift ;;
  esac
done
[ -n "$BASE_REF" ] || {
  echo "usage: fm-failfirst.sh [--report <file>] [--setup <command>] [--jobs <n>] <base-ref>" >&2
  echo "       fm-failfirst.sh --shard=<i/n> --part=<file> [--setup <command>] [--jobs <n>] <base-ref>" >&2
  echo "       fm-failfirst.sh --merge=<dir> [--report <file>] <base-ref>" >&2; exit 64; }
case "$JOBS" in
  '') JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
      case "$JOBS" in ''|*[!0-9]*|0) JOBS=2 ;; esac
      [ "$JOBS" -le 6 ] || JOBS=6 ;;
  *[!0-9]*|0) echo "fm-failfirst: --jobs must be a positive integer" >&2; exit 64 ;;
esac
if [ -n "$GATE_MODE" ] && { [ -n "$SHARD" ] || [ -n "$MERGE" ]; }; then
  echo "fm-failfirst: --gate cannot be sharded or merged" >&2; exit 64
fi
if [ -n "$CONTRACT" ] && { [ -z "$GATE_MODE" ] || [ -n "$SETUP_GIVEN" ]; }; then
  echo "fm-failfirst: --contract requires --gate and cannot override pinned setup" >&2; exit 64
fi
SHARD_I=1; SHARD_N=1
if [ -n "$SHARD" ]; then
  [[ "$SHARD" =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]] && [ "${BASH_REMATCH[1]}" -le "${BASH_REMATCH[2]}" ] || {
    echo "fm-failfirst: --shard must look like i/n with i at most n, e.g. 2/4" >&2; exit 64; }
  SHARD_I="${BASH_REMATCH[1]}"; SHARD_N="${BASH_REMATCH[2]}"
  [ -n "$PART" ] || { echo "fm-failfirst: --shard needs --part=<file> to write its share to" >&2; exit 64; }
  [ -z "$REPORT" ] || {
    echo "fm-failfirst: a shard writes --part; the report is --merge's" >&2; exit 64; }
fi
[ -z "$PART" ] || [ -n "$SHARD" ] || { echo "fm-failfirst: --part is a shard's; give --shard=i/n too" >&2; exit 64; }
[ -z "$MERGE" ] || [ -z "$SHARD" ] || { echo "fm-failfirst: --merge runs nothing, so it takes no --shard" >&2; exit 64; }
if [ -n "$MERGE" ]; then
  [ -d "$MERGE" ] || { echo "fm-failfirst: no such directory of parts: $MERGE" >&2; exit 64; }
  MERGE="$(cd "$MERGE" && pwd)"
fi
case "$PART" in ''|/*) : ;; *) PART="$PWD/$PART" ;; esac

say() { echo "fm-failfirst: $*" >&2; }
REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { say "not inside a git checkout"; exit 70; }
cd "$REPO" || exit 70
HEAD_SHA="$(git rev-parse --verify -q "$HEAD_REF^{commit}")" || { say "no HEAD commit"; exit 70; }
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

# Gate 5 supplies the verified pin, independent of any target config file.
# Standalone CI retains its head declaration.
P_SETUP=''; P_TEST=''; P_TESTS=''; P_CHECK=''; P_DOCS=''; P_ENV=()
if [ -n "$CONTRACT" ]; then
  # Validate before reading any field, including check_env (whose process
  # substitution otherwise cannot propagate a parser failure).
  jq -e '
    type == "object" and
    (keys - ["setup","check","test","tests","docs","check_env"] | length == 0) and
    all(.setup,.check,.test; . == null or type == "string") and
    all(.tests,.docs; . == null or (type == "array" and all(.[]; type == "string"))) and
    (.check_env == null or (.check_env | type == "object" and
      all(to_entries[]; (.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) and (.value | type == "string")))) and
    (.test == null or .test == "" or (.test | contains("{file}")))
  ' "$CONTRACT" >/dev/null || { say "invalid pinned gate contract"; exit 70; }
  P_SETUP="$(jq -r '.setup // ""' "$CONTRACT")"
  P_TEST="$(jq -r '.test // ""' "$CONTRACT")"
  P_TESTS="$(jq -r '.tests // [] | .[]' "$CONTRACT")"
  P_CHECK="$(jq -r '.check // ""' "$CONTRACT")"
  P_DOCS="$(jq -r '.docs // [] | .[]' "$CONTRACT")"
  while IFS= read -r -d '' kv; do P_ENV+=("$kv"); done < <(
    jq -j '.check_env // {} | to_entries[] | .key + "=" + .value + "\u0000"' "$CONTRACT")
elif git show "$HEAD_SHA:config.yaml" > "$work/config.yaml" 2>/dev/null && [ -s "$work/config.yaml" ]; then
  P_SETUP="$(fm_project setup "$work/config.yaml")" || { say "config.yaml's project block does not read"; exit 70; }
  P_TEST="$(fm_project test "$work/config.yaml")" || exit 70
  P_TESTS="$(fm_project tests "$work/config.yaml")" || exit 70
  P_CHECK="$(fm_project check "$work/config.yaml")" || exit 70
  P_DOCS="$(fm_project docs "$work/config.yaml")" || exit 70
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
is_behaviour() {
  if [ -n "$GATE_MODE" ]; then
    ! matches "$1" "$P_DOCS"
    return
  fi
  case "$1" in bin/*|board/*|adapters/*|*/adapters/*) return 0 ;; *) return 1 ;; esac; }
# fill <template> <file>: every {file} becomes the shell-quoted path
fill() {
  local rest="$1" q out=''
  q="$(printf '%q' "$2")"
  while [[ "$rest" == *'{file}'* ]]; do
    out="$out${rest%%\{file\}*}$q"; rest="${rest#*\{file\}}"
  done
  printf '%s' "$out$rest"
}

: > "$work/changed-tests"; : > "$work/suites"; : > "$work/behaviour"; : > "$work/restored"; : > "$work/removed"; : > "$work/other"
while IFS=$'\t' read -r st path; do
  [ -n "$path" ] || continue
  if is_test "$path"; then
    printf '%s\n' "$path" >> "$work/changed-tests"
    [ "$st" = D ] || printf '%s\n' "$path" >> "$work/suites"
    continue
  fi
  if [ "$st" = A ]; then printf '%s\n' "$path" >> "$work/removed"
  else printf '%s\n' "$path" >> "$work/restored"; fi
  if is_behaviour "$path"; then printf '%s\n' "$path" >> "$work/behaviour"
  else printf '%s\n' "$path" >> "$work/other"; fi
done < <(git diff --name-status --no-renames "$MB" "$HEAD_SHA")

# A changed test helper also selects its consumers, with filename boundaries.
# CI and the gate share this selection; an implementation reference alone
# never selects an unchanged suite.
if [ -s "$work/changed-tests" ]; then
while IFS= read -r f; do
  is_test "$f" || continue
  grep -qxF "$f" "$work/suites" && continue
  git show "$HEAD_SHA:$f" > "$work/candidate" 2>/dev/null || continue
  while IFS= read -r helper; do
    [ -n "$helper" ] || continue
    name="$(printf '%s' "${helper##*/}" | sed 's#[][\\.*^$+?(){}|/]#\\&#g')"
    if grep -qE "(^|[^A-Za-z0-9._-])$name([^A-Za-z0-9._-]|\$)" "$work/candidate"; then
      printf '%s\n' "$f" >> "$work/suites"; break
    fi
  done < "$work/changed-tests"
done < <(git ls-tree -r --name-only "$HEAD_SHA")
fi

if [ -n "$GATE_MODE" ] && [ -s "$work/changed-tests" ] && [ -n "$P_CHECK" ] &&
    { [ -z "$P_TEST" ] || [ ! -s "$work/suites" ]; }; then
  if [ -z "$P_TEST" ]; then
    say "config.yaml declares no project.test to run one suite with, so the whole project.check runs"
  else
    say "no suite the diff touches is left in the tree, so the whole project.check runs"
  fi
  P_TEST="$P_CHECK"
  printf 'project.check\n' > "$work/suites"
fi

verdict=''; reason=''
if [ ! -s "$work/behaviour" ]; then
  verdict='not applicable'
  if [ ! -s "$work/restored" ] && [ ! -s "$work/removed" ]; then
    reason='the change touches only tests: no behaviour to revert'
  else
    reason='the change touches no behaviour (nothing under bin/, board/ or adapters/): only docs, skills, CI or other non-code files'
    [ -z "$GATE_MODE" ] || reason='every changed non-test path matches the declared docs globs'
  fi
elif [ ! -s "$work/suites" ]; then
  verdict='fail'; reason='the change modifies behaviour and adds or changes no test suite'
elif [ -z "$P_TEST" ]; then
  verdict='fail'; reason="config.yaml declares no project.test to run a changed suite with"
fi

# --- the part and the report --------------------------------------------------
# One program, two steps. `part` reads the runs of the suites this process
# ran ($work/planned, their indices in $work/suites) into a JSON part.
# `render` reads parts - this run's own, or every shard's under --merge -
# into the report and its verdict. A single run renders its own part the
# way the merge renders the shards', so the two cannot disagree.
IFS= read -r -d '' FF_PY <<'PY'
import glob, json, os, re, sys

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


def collect(runs, i, suite):
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
            red.append([name, 'FAIL on base'])
        elif key not in base_o and b_rc != '0':
            red.append([name, 'not reached on base, whose run exited %s' % b_rc])
        elif base_o.get(key) == 'ok':
            guard.append(name)
    silent = False
    if not head_o:
        if h_rc == '0' and b_rc not in ('0', '?'):
            red.append(['the suite as a whole', 'exited %s on base and 0 on head; it prints no assertion lines' % b_rc])
        elif h_rc == '0':
            silent = True
    return {'suite': suite, 'head_exit': h_rc, 'base_exit': b_rc, 'red': red, 'guard': guard,
            'head_red': head_red, 'silent': silent}


def part(argv):
    work, shard, of, head, mb, status, error, predicted = argv
    suites = lines(os.path.join(work, 'suites'))
    planned = [int(x) for x in lines(os.path.join(work, 'planned'))]
    results = []
    if status == 'ran':
        results = [collect(os.path.join(work, 'runs'), i, suites[i]) for i in planned]
    json.dump({'fail_first_part': 1, 'shard': int(shard), 'of': int(of), 'head': head, 'base': mb,
               'status': status, 'error': error, 'planned': [suites[i] for i in planned],
               'predicted': predicted, 'results': results}, sys.stdout, indent=1)
    print()
    return 0


def section(r):
    s = ['### %s' % r['suite'], '', 'head exit %s, base exit %s' % (r['head_exit'], r['base_exit']), '']
    if r['silent']:
        s += ['The project\'s `test` template ran no assertion of it (it printed none), so it shows nothing either way.', '']
    s.append('Red on base (%d):' % len(r['red']))
    s += ['- %s: %s' % (code(n), why) for n, why in r['red']] or ['- none']
    s += ['', 'Guard, green on base too (%d):' % len(r['guard'])]
    s += ['- %s' % code(n) for n in r['guard']] or ['- none']
    if r['head_red']:
        s += ['', 'Failing on the head itself (%d), counted neither way:' % len(r['head_red'])]
        s += ['- %s' % code(n) for n in r['head_red']]
    return '\n'.join(s)


def load_parts(paths, head, mb):
    parts, ignored = [], []
    for p in sorted(paths):
        try:
            with open(p) as f:
                d = json.load(f)
        except (OSError, ValueError):
            ignored.append('%s does not read as a part' % os.path.basename(p))
            continue
        if not isinstance(d, dict) or d.get('fail_first_part') != 1:
            ignored.append('%s is not a fail-first part' % os.path.basename(p))
        elif d.get('head') != head or d.get('base') != mb:
            ignored.append('shard %s/%s reported another head or base' % (d.get('shard'), d.get('of')))
        else:
            parts.append(d)
    parts.sort(key=lambda d: d.get('shard', 0))
    return parts, ignored


def not_run(suite, parts):
    tag = lambda d: 'shard %s/%s' % (d.get('shard'), d.get('of'))
    for d in parts:
        if suite in (d.get('planned') or []):
            if d.get('status') == 'error':
                return '%s could not run it: %s' % (tag(d), d.get('error') or 'no reason given')
            return '%s did not report its result' % tag(d)
    if not parts:
        return 'no fail-first shard sent a report'
    of = max(int(d.get('of') or 0) for d in parts)
    got = set(int(d.get('shard') or 0) for d in parts)
    missing = ['%d/%d' % (k, of) for k in range(1, of + 1) if k not in got]
    return 'no shard reported it' + ('; no report came from shard %s' % ', '.join(missing) if missing else '')


def render(argv):
    work, verdict, reason, base_ref, mb, head = argv[:6]
    suites = lines(os.path.join(work, 'suites'))
    sections, red_total, unrun = [], 0, []
    if not verdict:
        parts, ignored = load_parts(argv[6:], head, mb)
        results = {}
        for d in parts:
            for r in d.get('results') or []:
                if isinstance(r, dict) and r.get('suite') in suites:
                    results.setdefault(r['suite'], r)
        for suite in suites:
            r = results.get(suite)
            if r is None:
                why = not_run(suite, parts)
                unrun.append(suite)
                s = ['### %s' % suite, '', 'Not run: %s.' % why]
                if ignored:
                    s += ['', 'Ignored: %s.' % '; '.join(ignored)]
                sections.append('\n'.join(s))
                continue
            red_total += len(r['red'])
            sections.append(section(r))
        if unrun:
            verdict = 'fail'
            reason = '%d changed suite(s) did not run, so fail-first cannot say what they do on base: %s' % (
                len(unrun), ', '.join(code(x) for x in unrun))
        elif red_total:
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
        out.append('- the head was re-run beside the base, on the same runner, not read from CI\'s bash shards')
    out.append('')
    out += [x + '\n' for x in sections]
    print('\n'.join(out).rstrip('\n'))
    return 3 if verdict == 'fail' else 0


if __name__ == '__main__':
    mode, rest = sys.argv[1], sys.argv[2:]
    if mode == 'parts':
        print('\n'.join(sorted(glob.glob(os.path.join(rest[0], '**', '*.json'), recursive=True))))
        sys.exit(0)
    sys.exit(part(rest) if mode == 'part' else render(rest))
PY

# --- which of the changed suites this process runs ---------------------------
# All of them, unless it is a shard: then the share bin/ci.sh --plan gives
# the i-th of n, the bash shards' own split. Indices into $work/suites.
: > "$work/planned"
PREDICTED=''
all=()   # the changed suites, by index (bash 3.2 has no mapfile)
while IFS= read -r f; do all+=("$f"); done < "$work/suites"
if [ -z "$verdict" ] && [ -z "$MERGE" ]; then
  if [ -z "$SHARD" ]; then
    awk '{ print NR - 1 }' "$work/suites" > "$work/planned"
  else
    plan="$(FM_ROOT="$REPO" bash "$FF_BIN/ci.sh" --plan "$SHARD" -- ${all[@]+"${all[@]}"})" || {
      say "bin/ci.sh --plan $SHARD could not split the changed suites"; exit 70; }
    load=''; top=''; unit=''; : > "$work/bash-shards"
    while IFS=' ' read -r k a b c; do
      case "$k" in
        i) printf '%s\n' "$a" >> "$work/planned" ;;
        p) load="$a"; top="$b"; unit="$c" ;;
        l) printf '%s %s\n' "$a" "$b" >> "$work/bash-shards" ;;
      esac
    done <<< "$plan"
    # What the shard is predicted to take, beside what the heaviest bash
    # shard is, by one rule for both: a pool of $JOBS runs at once takes the
    # longer of its longest run and its whole load spread over the pool.
    # Here every suite runs twice, on the head and on the base, side by side.
    if [ -n "$load" ] && [ -s "$work/bash-shards" ]; then
      PREDICTED="$(awk -v p="$load" -v t="$top" -v u="$unit" -v j="$JOBS" '
        function wall(s, m) { return (m > s / j) ? m : s / j }
        { w = wall($1, $2); if (w > b) b = w }
        END {
          u = (u == "s") ? "s" : " bytes"; f = wall(2 * p, t)
          printf "%.1f%s (head and base of each suite, %d at a time: the longer of its longest suite, %.1f%s, and 2 x %.1f%s over %d); the bash shards'"'"' longest is predicted %.1f%s by the same rule: %s",
            f, u, j, t, u, p, u, j, b, u, (f > b + 0.0005) ? "this shard is predicted OVER it" : "within it"
        }' "$work/bash-shards")"
    fi
  fi
fi

# write_part <status> [error]: this shard's part, to --part
write_part() {
  [ -n "$PART" ] || return 0
  python3 -c "$FF_PY" part "$work" "$SHARD_I" "$SHARD_N" "$HEAD_SHA" "$MB" "$1" "${2-}" "$PREDICTED" > "$work/part.json" &&
    cp "$work/part.json" "$PART" || { say "could not write the part $PART"; return 1; }
}
# die <message>: it could not run; a shard's part says why first, so the
# merge can name the suites it was given
die() { say "$1"; write_part error "$1"; exit 70; }

if [ -n "$SHARD" ]; then
  if [ -n "$verdict" ]; then
    say "shard $SHARD: nothing to run: $reason; the merge reports it"
    write_part decided || exit 70
    exit 0
  fi
  n_all="$(awk 'END { print NR }' "$work/suites")"
  if [ ! -s "$work/planned" ]; then
    say "shard $SHARD: none of the $n_all changed suite(s) is this shard's: not applicable"
    write_part none || exit 70
    exit 0
  fi
  say "shard $SHARD: $(awk 'END { print NR }' "$work/planned") of $n_all changed suite(s)${PREDICTED:+, predicted $PREDICTED}"
fi

# --- the two trees, and every planned suite run in both ---------------------
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
if [ -z "$verdict" ] && [ -z "$MERGE" ]; then
  for t in head base; do
    git worktree add -q --detach "$work/$t" "$HEAD_SHA" >/dev/null 2>&1 || die "could not make the $t worktree"
  done
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    git -C "$work/base" checkout -q "$MB" -- "$f" 2>/dev/null || die "could not restore $f from $MB"
  done < "$work/restored"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rm -f "$work/base/$f"
  done < "$work/removed"
  if [ -n "$SETUP" ]; then
    for t in head base; do
      ( cd "$work/$t" && env FM_ROOT="$work/$t" bash -c "$SETUP" ) > "$work/setup.$t.log" 2>&1 || {
        setup_rc=$?
        tail -n 20 "$work/setup.$t.log" >&2; die "setup failed (exit $setup_rc) in the $t tree: $SETUP"; }
    done
  fi
  # one run: its tree, the suite's index, and what it runs. Each has its own
  # session - the shell running it, which ends with it - as bin/ci.sh gives
  # a suite, so nothing it starts outlives it (T-151).
  mkdir -p "$work/runs"
  printf '%s' "$ONE_SH" > "$work/one.sh"
  : > "$work/list"
  n=0
  while IFS= read -r i; do
    [ -n "$i" ] || continue
    cmd="$(fill "$P_TEST" "${all[$i]}")"
    for t in head base; do
      printf '%s\0%s\0%s\0%s\0' "$work/$t" "$i" "$cmd" "$work/runs/$t.$i" >> "$work/list"
    done
    n=$((n + 1))
  done < "$work/planned"
  say "running the suites the diff touches: $(tr '\n' ' ' < "$work/suites")"
  say "running $n changed suite(s) on the head and on the base, $JOBS at a time"
  env ${P_ENV[@]+"${P_ENV[@]}"} xargs -0 -n 4 -P "$JOBS" bash "$work/one.sh" < "$work/list"
fi

# --- a shard: its part, and the merge writes the report ----------------------
if [ -n "$SHARD" ]; then
  write_part ran || exit 70
  {
    printf '## Fail-first shard %s\n\n' "$SHARD"
    printf 'Ran %s changed suite(s) on the head and on the base:\n\n' "$n"
    while IFS= read -r i; do printf -- '- `%s`\n' "${all[$i]}"; done < "$work/planned"
    [ -z "$PREDICTED" ] || printf '\nPredicted %s.\n' "$PREDICTED"
    printf '\nThe verdict and the report are the `fail-first` job'"'"'s, which merges every shard'"'"'s part.\n'
  } > "$work/shard.md"
  cat "$work/shard.md"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || cat "$work/shard.md" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

# --- the report -------------------------------------------------------------
parts=()
if [ -z "$verdict" ]; then
  if [ -n "$MERGE" ]; then
    while IFS= read -r p; do [ -z "$p" ] || parts+=("$p"); done < <(python3 -c "$FF_PY" parts "$MERGE")
    say "merging ${#parts[@]} part(s) from $MERGE"
  else
    PART="$work/own.json"; write_part ran || exit 70
    parts=("$work/own.json")
  fi
fi
python3 -c "$FF_PY" render "$work" "$verdict" "$reason" "$BASE_REF" "$MB" "$HEAD_SHA" \
  ${parts[@]+"${parts[@]}"} > "$work/report.md"
case "$?" in
  0) rc=0 ;;
  3) rc=1 ;;
  *) say "the report could not be written"; exit 70 ;;
esac
cat "$work/report.md"
[ -z "$REPORT" ] || cp "$work/report.md" "$REPORT" || { say "could not write $REPORT"; exit 70; }
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || cat "$work/report.md" >> "$GITHUB_STEP_SUMMARY"
exit "$rc"
