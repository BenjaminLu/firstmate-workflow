#!/usr/bin/env bash
# Gate 4 executes the approved snapshot even if target config disappears.
set -uo pipefail
for key in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do unset "$key" || true; done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/lib/spec-pins.sh"
isolate_tmpdir
d="$(safe_tmpdir)"
export FM_GATE_LOCK="$d/gate.lock"
git -C "$d" init -q -b main
git -C "$d" config user.email a@b.c
git -C "$d" config user.name fixture
mkdir -p "$d/design/tasks" "$d/src" "$d/tests"
echo old > "$d/src/value"
echo design > "$d/design/design.md"
echo '{"id":"T-X","scope":["src/**","tests/**","config.yaml","notes/**"]}' > "$d/design/tasks/T-X.json"
printf 'state/\ngate.lock\n' > "$d/.gitignore"
cat > "$d/config.yaml" <<'YAML'
project:
  setup: echo prepared > setup-marker
  check: exit 93
  check_env:
    PIN_VALUE: approved
  tests:
    - tests/**
  test: bash {file}
  docs:
    - notes/**
    - config.yaml
YAML
git -C "$d" add -A; git -C "$d" commit -qm base
seed_spec_pin "$d" T-X
git -C "$d" checkout -qb work
echo new > "$d/src/value"
cat > "$d/tests/value.test.sh" <<'TEST'
test "$PIN_VALUE" = approved && test -f setup-marker && test "$(cat src/value)" = new
TEST
git -C "$d" add -A; git -C "$d" commit -qm feature
run_gate() { "$ROOT/bin/fm-gate.sh" --repo "$d" --task T-X --branch work --only 4 > "$d.out" 2>&1; }
assert_ok run_gate "gate 4 executes pinned setup, env and test template"
# Both the head and the mutable checkout now advertise a failing setup.
printf 'project:\n  setup: exit 94\n  check: exit 95\n' > "$d/config.yaml"
git -C "$d" add config.yaml; git -C "$d" commit -qm altered-contract
assert_ok run_gate "a scoped branch config change cannot change its own gate contract"
rm "$d/config.yaml"
git -C "$d" add config.yaml; git -C "$d" commit -qm removed-config
assert_ok run_gate "gate 4 uses the complete pin even when head has no config"

# Docs classification also comes from the immutable snapshot.
git -C "$d" checkout -q main
git -C "$d" branch -D work >/dev/null
git -C "$d" checkout -qb work
mkdir -p "$d/notes"; echo documentation > "$d/notes/readme"
printf 'project:\n  check: exit 95\n' > "$d/config.yaml"
git -C "$d" add -A; git -C "$d" commit -qm documentation
assert_ok run_gate "pinned docs exemptions survive a branch contract edit"

# A contract without a per-suite command must use its approved whole check.
d="$(safe_tmpdir)"
export FM_GATE_LOCK="$d/gate.lock"
git -C "$d" init -q -b main
git -C "$d" config user.email a@b.c
git -C "$d" config user.name fixture
mkdir -p "$d/design/tasks" "$d/src" "$d/tests"
echo old > "$d/src/value"
echo design > "$d/design/design.md"
echo '{"id":"T-X","scope":["src/**","tests/**","config.yaml"]}' > "$d/design/tasks/T-X.json"
printf 'state/\ngate.lock\n' > "$d/.gitignore"
cat > "$d/config.yaml" <<'YAML'
project:
  check: test "$PIN_VALUE" = approved && test "$(cat src/value)" = new
  check_env:
    PIN_VALUE: approved
YAML
git -C "$d" add -A; git -C "$d" commit -qm base
seed_spec_pin "$d" T-X
git -C "$d" checkout -qb work
echo new > "$d/src/value"
echo '# contract runs the whole check' > "$d/tests/changed.test.sh"
printf 'project:\n  check: exit 95\n' > "$d/config.yaml"
git -C "$d" add -A; git -C "$d" commit -qm feature
assert_ok run_gate "gate 4 fallback runs pinned check with pinned environment"
finish
