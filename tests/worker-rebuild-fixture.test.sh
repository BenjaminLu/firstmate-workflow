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
