#!/usr/bin/env bash
# Gate bases follow the selected project and the verified stacked PR.
set -uo pipefail
for key in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do unset "$key" || true; done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/lib/head-binding.sh"
isolate_tmpdir
d="$(safe_tmpdir)"
export FM_GATE_LOCK="$d/gate.lock"
git -C "$d" init -q -b main
git -C "$d" config user.email a@b.c
git -C "$d" config user.name fixture
cat > "$d/config.yaml" <<'YAML'
default_project: firstmate-workflow
projects:
  firstmate-workflow:
    repo: .
    github: fixture/project
    base: trunk
    required_check: ci
YAML
echo original > "$d/value"
git -C "$d" add -A; git -C "$d" commit -qm base
git -C "$d" checkout -qb trunk
echo trunk > "$d/value"; git -C "$d" commit -qam trunk
git -C "$d" branch task
gate() { "$ROOT/bin/fm-gate.sh" --task T-X --repo "$d" --branch task --only "$@" > "$d.out" 2>&1; }
assert_fail 'gate 1' 'unnamed self gate 1 uses project trunk rather than main'
assert_fail 'gate 1 --project firstmate-workflow' 'explicit self gate 1 uses the same base'
git -C "$d" checkout -q task
echo feature > "$d/feature"; git -C "$d" add feature; git -C "$d" commit -qm feature
assert_ok 'gate 1' 'project-base gate 1 passes new task commits'

# GitHub targets task itself as a stack base: no commits beyond it.
head_binding_fixture "$d" task success task
export FM_GH="$d/stub/head-gh"
assert_fail 'gate 1 --pr 9' 'gate 1 uses the authoritative stacked base'
assert_contains "$(cat "$d.out")" 'x gate 1' 'the stacked comparison reaches gate 1'
git -C "$d" branch stack task
echo child > "$d/child"; git -C "$d" add child; git -C "$d" commit -qm child
git -C "$d" checkout -q trunk
echo conflict > "$d/feature"; git -C "$d" add feature; git -C "$d" commit -qm conflict
head_binding_fixture "$d" task success stack
assert_ok 'gate 2 --pr 9' 'gate 2 rebases onto the verified stack instead of conflicting trunk'
finish
