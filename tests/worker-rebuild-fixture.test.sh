#!/usr/bin/env bash
# Feature dependencies: tests/lib/worker-rebuild.sh tests/worker-executable.test.sh tests/worker-rebuild.test.sh tests/worker-rebuild-publication.test.sh tests/spec-pin-sync.test.sh
# Historical proof: overlay this complete harness and ONLY library initializer
# guards on cd996fc1f2ce66ef05141cfe0b480f93efad98d4. Keep old clone/callers.
# Expected red: transport selection and no worker after failed setup, with the
# worker-call sentinel present. Ordinary gate 4 has no runtime code to revert.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Do not inherit live managed-round or host routing into synthetic fixtures.
for fixture_env in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$fixture_env" || true
done
export HERDR_ENV=0 FM_TRANSPORT=direct
. "$ROOT/tests/lib.sh"
isolate_tmpdir
RB_FIXTURE_LIBRARY_ONLY=1
. "$ROOT/tests/lib/worker-rebuild.sh"
case_dir="$(safe_tmpdir)" || exit 1
mkdir -p "$case_dir/stub" "$case_dir/repo"
git init -q --bare "$case_dir/remote.git"
git init -q -b main "$case_dir/repo"
git -C "$case_dir/repo" config user.email a@b.c
git -C "$case_dir/repo" config user.name t
printf 'before\n' > "$case_dir/repo/value"
git -C "$case_dir/repo" add value
git -C "$case_dir/repo" commit -qm seed
git -C "$case_dir/repo" remote add origin "$case_dir/remote.git"
git -C "$case_dir/repo" push -q origin main
before="$(rb_head "$case_dir" main)"
cat > "$case_dir/main.sh" <<'STEP'
printf 'edited\n' > "$RB_CASE_DIR/main-edit"
printf 'after\n' > value
STEP
cat > "$case_dir/stub/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RB_CASE_DIR/git-argv"
if [ "${1:-}" = clone ] && [ "${RB_CLONE_FAIL:-0}" = 1 ]; then
  if [ "${RB_CLONE_NOISE:-0}" = 1 ]; then
    printf '%6000s' '' | tr ' ' x >&2
    printf '\n' >&2
  fi
  printf 'fixture sentinel: clone refused\n' >&2
  exit 128
fi
exec "$RB_REAL_GIT" "$@"
STUB
chmod +x "$case_dir/stub/git"
export RB_CASE_DIR="$case_dir" RB_REAL_GIT="$rb_git_real" RB_CLONE_FAIL=1
original_path="$PATH"
PATH="$case_dir/stub:$PATH"; export PATH
rb_move_main "$case_dir" "$case_dir/main.sh" > "$case_dir/stdout" 2> "$case_dir/stderr"; clone_rc=$?
assert_ne 0 "$clone_rc" 'clone refusal propagates nonzero'
assert_eq '' "$(cat "$case_dir/stdout")" 'failure preserves empty stdout'
assert_contains "$(cat "$case_dir/stderr")" 'rebuild fixture clone failed' 'fixed fixture diagnostic class'
assert_contains "$(cat "$case_dir/stderr")" 'fixture sentinel: clone refused' 'original Git error retained'
assert_matches "$(cat "$case_dir/stderr")" 'source_exists=true destination_exists=false source_main=[0-9a-f]{7,12} destination_main=unavailable' 'bounded local metadata'
assert_fail "test -e '$case_dir/main-edit'" 'clone failure never edits main'
assert_eq "$before" "$(rb_head "$case_dir" main)" 'clone failure never changes remote main'
assert_lacks "$(cat "$case_dir/git-argv")" 'push' 'clone failure never pushes'
assert_contains "$(cat "$case_dir/git-argv")" 'clone --no-local -q -b main' 'ordinary transport selected'

RB_CLONE_NOISE=1; export RB_CLONE_NOISE
rb_move_main "$case_dir" "$case_dir/main.sh" > "$case_dir/stdout" 2> "$case_dir/stderr"; noisy_rc=$?
assert_ne 0 "$noisy_rc" 'large clone error still fails'
assert_contains "$(cat "$case_dir/stderr")" 'fixture sentinel: clone refused' 'bounded tail retains final original error'
assert_ok "test $(wc -c < "$case_dir/stderr") -le 4352" 'original stderr tail is at most 4 KiB plus fixed metadata'
unset RB_CLONE_NOISE

# Execute each actual setup command from the four consumers in isolation.
# Only synthetic task setup is replaced; rb_move_main and Git readers remain
# real. The next worker is a sentinel, never a production round. On historical
# unchecked callers the sentinel appears and the assertion below goes red.
python3 - "$ROOT" > "$case_dir/callers" <<'PY'
from pathlib import Path
import re, sys
for name in ('worker-executable', 'worker-rebuild', 'worker-rebuild-publication', 'spec-pin-sync'):
    for line in (Path(sys.argv[1]) / f'tests/{name}.test.sh').read_text().splitlines():
        if re.match(r'\s*rb_(move_main|replay_conflict|conflicting_main|ascii_conflict) "', line):
            command = line.strip().split(';', 1)[0]
            command = re.sub(r'"\$[^" ]+"', '"$case_dir"', command, count=1)
            command = re.sub(r'"\$[^" ]+/main.sh"', '"$case_dir/main.sh"', command)
            print(command)
PY
while IFS= read -r setup; do
  rm -f "$case_dir/worker-call"
  (
    rb_replay_conflict() { rb_move_main "$1" "$1/main.sh"; }
    rb_conflicting_main() { rb_move_main "$1" "$1/main.sh"; }
    rb_ascii_conflict() { rb_move_main "$1" "$1/main.sh"; }
    rb_round_two() { printf 'worker-call sentinel\n' > "$case_dir/worker-call"; }
    setup_and_round() {
      eval "$setup"
      rb_round_two
    }
    setup_and_round
  ) > "$case_dir/caller-out" 2>&1
  assert_fail "test -e '$case_dir/worker-call'" "no worker after failed setup: $setup"
  if [ -e "$case_dir/worker-call" ]; then cat "$case_dir/worker-call"; fi
done < "$case_dir/callers"
assert_ok "test -s '$case_dir/callers'" 'controlled caller inventory is nonempty'

# X4 has a multiline initializer, not a named rb_* setup command. Select
# its complete actual flow, including the handler, rather than copying a guard.
# Strict boundaries/counts make missing or ambiguous extraction a test failure.
python3 - "$ROOT" "$case_dir" <<'PYX4' || exit 1
from pathlib import Path
import re, sys
root, out = map(Path, sys.argv[1:])
source = (root / 'tests/worker-executable.test.sh').read_text()
start = 'dX4="$(RB_HOOKS=1 rb_fixture)"; bX4="$(rb_branch "$dX4")"\n'
end = 'rb_round_two "$dX4" "$dX2/tool.sh"\n'
assert source.count(start) == source.count(end) == 1, 'X4 flow boundaries missing/ambiguous'
flow = source[source.index(start):source.index(end) + len(end)]
current = '{ echo "fm-test: could not set up X4" >&2; exit 1; }'
historical = 'echo "fm-test: could not set up X4" >&2'
assert flow.count(historical) == 1, 'X4 handler missing/ambiguous'
assert flow.count(current) in (0, 1), 'X4 current handler ambiguous'
assert flow.count('rb_commit ') == flow.count('rb_replay_conflict ') == 1, 'X4 setup selection incomplete'
assert flow.count('git push ') == flow.count('rb_round_two ') == 1, 'X4 continuation selection incomplete'
(out / 'x4-current.sh').write_text(flow)
(out / 'x4-historical.sh').write_text(flow.replace(current, historical, 1))
(out / 'x4-mutation.txt').write_text(current + '\n=>\n' + historical + '\n')
# Every stopping setup handler in these consumers must belong to the named
# command inventory or the selected X4 block. Future multiline guards cannot
# silently disappear from controlled coverage.
from collections import Counter
# Existing unrelated stopping handlers, with exact multiplicity. These are not
# T261 replacements; any additional handler requires explicit coverage review.
legacy = {
    'worker-executable': Counter({'cd "$ROOT" || exit 1': 1}),
    'worker-rebuild': Counter({
        'cd "$ROOT" || exit 1': 1,
        "      && rb_commit -m 'the task adds a file' && git push -q origin HEAD ) || return 1": 1,
    }),
    'worker-rebuild-publication': Counter({'cd "$ROOT" || exit 1': 1}),
    'spec-pin-sync': Counter({
        '  d="$(fixture)" || exit 1; repo="$d/repo"; GH="$(ghstub "$d")"': 1,
        'cd "$3" || exit 1': 1,
        'cd "$FM_SEEN" || exit 1': 1,
        'rb_seed="$(RB_PINNED=1 rb_build_fixture)" || exit 1': 1,
        'cd "$ROOT" || exit 1': 1,
    }),
}
named = 0
for name in ('worker-executable', 'worker-rebuild', 'worker-rebuild-publication', 'spec-pin-sync'):
    text = (root / f'tests/{name}.test.sh').read_text()
    remaining = legacy[name].copy()
    for line in text.splitlines():
        selected = re.match(r'\s*rb_(move_main|replay_conflict|conflicting_main|ascii_conflict) "', line)
        if selected:
            named += 1
        if re.search(r'\|\|.*(?:exit|return) 1', line):
            if not selected and not (name == 'worker-executable' and line in flow.splitlines()):
                assert remaining[line] > 0, f'uncovered stopping setup handler: {name}: {line}'
                remaining[line] -= 1
    assert not +remaining, f'legacy stopping-handler inventory changed: {name}'
assert named == 48, f'named setup inventory changed: {named}'
PYX4

x4_dir="$case_dir/x4"
mkdir -p "$x4_dir/repo/state/worktrees/T-Z/bin"
printf ': synthetic tool\n' > "$x4_dir/tool.sh"
x4_run() {
  local script="$1" commit_rc="$2"
  rm -f "$x4_dir/commit-call" "$x4_dir/push-call" "$x4_dir/later-setup" "$x4_dir/worker-call"
  (
    # The complete helper was loaded above in library-only mode. Replace only
    # this case's setup/continuation with bounded owned sentinels; no real round.
    rb_fixture() { printf '%s' "$x4_dir"; }
    rb_branch() { printf '%s' ownedbranch; }
    rb_commit() { printf 'commit-call\n' > "$x4_dir/commit-call"; return "$commit_rc"; }
    git() {
      case "$1" in
        add) return 0 ;;
        push) printf 'push-call\n' > "$x4_dir/push-call" ;;
        *) echo 'unexpected X4 Git command' >&2; return 64 ;;
      esac
    }
    rb_replay_conflict() { printf 'later-setup sentinel\n' > "$x4_dir/later-setup"; }
    rb_round_two() { printf 'worker-call sentinel\n' > "$x4_dir/worker-call"; }
    # Read by the exact dynamically sourced X4 continuation below.
    # shellcheck disable=SC2034
    dX2="$x4_dir"
    # shellcheck disable=SC1090
    . "$script"
  ) > "$x4_dir/output" 2>&1
  x4_rc=$?
}
x4_no_worker_after_failure() {
  [ "$x4_rc" -ne 0 ] && [ ! -e "$x4_dir/worker-call" ]
}
x4_run "$case_dir/x4-current.sh" 128
assert_ok "test -e '$x4_dir/commit-call'" 'actual X4 initializer reaches injected commit failure'
assert_eq 1 "$x4_rc" 'actual X4 setup failure terminates nonzero'
assert_contains "$(cat "$x4_dir/output")" 'fm-test: could not set up X4' 'actual X4 failure handler emits fixed error'
assert_ok x4_no_worker_after_failure 'actual X4 failure stops before worker invocation'
assert_fail "test -e '$x4_dir/later-setup'" 'actual X4 failure stops before later setup'
assert_fail "test -e '$x4_dir/push-call'" 'failed X4 commit never reaches push'

# Focused mutation: only the actual handler changes to its historical bytes.
# The same no-worker assertion must turn red, with positive continuation proof.
x4_run "$case_dir/x4-historical.sh" 128
assert_ok "test -e '$x4_dir/commit-call'" 'historical X4 flow reaches the same injected failure'
assert_eq 0 "$x4_rc" 'historical echo-only handler continues after setup failure'
assert_contains "$(cat "$x4_dir/output")" 'fm-test: could not set up X4' 'historical flow executes its error handler'
assert_ok "test -e '$x4_dir/later-setup'" 'historical handler reaches later setup sentinel'
assert_eq 'worker-call sentinel' "$(cat "$x4_dir/worker-call")" 'historical handler reaches worker sentinel'
assert_fail x4_no_worker_after_failure 'historical X4 handler makes the same no-worker assertion red'
printf 'X4 mutation: %s\n' "$(cat "$case_dir/x4-mutation.txt")"
printf 'X4 historical worker-call sentinel; no-worker assertion red\n'

x4_run "$case_dir/x4-current.sh" 0
assert_eq 0 "$x4_rc" 'actual X4 successful setup continues'
assert_ok "test -e '$x4_dir/commit-call'" 'X4 success control reaches commit'
assert_ok "test -e '$x4_dir/push-call'" 'X4 success control reaches push'
assert_ok "test -e '$x4_dir/later-setup'" 'X4 success control reaches subsequent actual setup line'
assert_eq 'worker-call sentinel' "$(cat "$x4_dir/worker-call")" 'X4 success control reaches subsequent actual worker line'
assert_lacks "$(cat "$x4_dir/output")" 'could not set up X4' 'X4 success control avoids failure handler'

RB_CLONE_FAIL=0; export RB_CLONE_FAIL
: > "$case_dir/git-argv"
rb_move_main "$case_dir" "$case_dir/main.sh" > "$case_dir/stdout" 2> "$case_dir/stderr"; success_rc=$?
assert_eq 0 "$success_rc" 'successful ordinary transport returns zero'
assert_eq '' "$(cat "$case_dir/stdout")" 'successful helper preserves stdout'
assert_contains "$(cat "$case_dir/git-argv")" 'clone --no-local -q -b main' 'successful clone uses ordinary transport'
assert_eq after "$(git --git-dir="$case_dir/remote.git" show main:value)" 'intended main change pushed'
assert_ok "test -e '$case_dir/main-edit'" 'successful clone executes main edit'
assert_ne "$before" "$(rb_head "$case_dir" main)" 'successful clone advances main'
PATH="$original_path"; export PATH
safe_rm_rf "$case_dir"
finish
