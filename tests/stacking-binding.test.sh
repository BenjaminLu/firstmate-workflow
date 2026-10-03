#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/review.sh
. "$ROOT/tests/lib/review.sh"
# shellcheck source=tests/lib/head-binding.sh
. "$ROOT/tests/lib/head-binding.sh"
d="$(fixture)"; r="$d/repo"
trap 'cd "$ROOT"; rm -rf "$d"' EXIT
# The review fixture's parent owns src/a. The child owns only src/child.
# Use the real binding implementation and local transport with GitHub shapes.
cp "$ROOT/bin/lib/fm_binding.py" "$r/bin/lib/fm_binding.py"
cp "$ROOT/bin/fm-gate.sh" "$r/bin/"
git -C "$r" branch t-902-child work
head_binding_fixture "$r" t-902-child success work
GH="$r/stub/head-gh"
export FM_GATE_LOCK="$d/gate.lock"
out="$(FM_ROOT="$r" FM_GH="$GH" bash "$r/bin/fm-gate.sh" --task T-Z --repo "$r" --branch t-902-child --pr 9 --only 1 2>&1)"; code=$?
assert_eq 1 "$code" 'gate 1 refuses child with no commits beyond PR parent'
assert_contains "$out" 'gate 1' 'gate refusal is about the child change'
git -C "$r" checkout -q t-902-child
echo CHILD_ONLY_CHANGE > "$r/src/child"
git -C "$r" add src/child; git -C "$r" commit -qm child
git -C "$r" checkout -q main
git -C "$r" update-ref refs/pull/9/head t-902-child
out="$(FM_ROOT="$r" FM_GH="$GH" bash "$r/bin/fm-gate.sh" --task T-Z --repo "$r" --branch t-902-child --pr 9 --only 1 2>&1)"; code=$?
assert_eq 0 "$code" 'gate 1 accepts commits beyond PR parent'
cat > "$r/bin/adapters/mock.sh" <<'MOCK'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
cp "$2" "$FM_CAPTURE"
printf 'APPROVE:T-Z\n' > "$3/verdict.txt"
MOCK
chmod +x "$r/bin/adapters/mock.sh"
cap="$d/prompt"
out="$(cd "$r" && FM_ROOT="$r" FM_GH="$GH" FM_CAPTURE="$cap" bin/fm-review.sh --task T-Z --branch t-902-child --pr 9 2>&1)"; code=$?
assert_eq 0 "$code" 'review accepts authoritative stacked head and base'
assert_contains "$(cat "$cap" 2>/dev/null)" CHILD_ONLY_CHANGE 'review sees child change'
assert_lacks "$(cat "$cap" 2>/dev/null)" SECRET_WORKER_REASONING 'review diff excludes parent change'
parent="$(git -C "$r" rev-parse work)"
assert_contains "$out" "base=$parent" 'review patch binding uses PR parent'
# An identical patch on a new head must carry approval relative to the PR
# parent, excluding that parent's change from the patch-id.
git -C "$r" checkout -q t-902-child
git -C "$r" commit -q --allow-empty -m 'same patch on a new head'
git -C "$r" checkout -q main
git -C "$r" update-ref refs/pull/9/head t-902-child
out="$(FM_ROOT="$r" FM_GH="$GH" bash "$r/bin/fm-gate.sh" --task T-Z --repo "$r" --branch t-902-child --pr 9 --only 7 2>&1)"; code=$?
assert_eq 0 "$code" 'gate 7 carries approval using the stacked PR parent patch'

# Every local-only path must reach its own gate without an origin or PR.
printf '#!/usr/bin/env bash\nexit 1\n' > "$r/stub/no-pr"
chmod +x "$r/stub/no-pr"
for availability in no-origin no-pr; do
  if [ "$availability" = no-origin ]; then
    git -C "$r" remote remove origin
  else
    git -C "$r" remote add origin https://github.com/fixture/project.git
  fi
  for only in 1 2 4 5 7; do
    out="$(FM_ROOT="$r" FM_GH="$r/stub/no-pr" bash "$r/bin/fm-gate.sh" --task T-Z --repo "$r" --branch t-902-child --pr 9 --only "$only" 2>&1)"; code=$?
    assert_ne 6 "$code" "gate $only preserves local evaluation with $availability"
    assert_contains "$out" "gate $only:" "gate $only reaches its own result with $availability"
  done
  out="$(FM_ROOT="$r" FM_GH="$r/stub/no-pr" bash "$r/bin/fm-gate.sh" --task T-Z --repo "$r" --branch t-902-child --pr 9 --only 6 2>&1)"; code=$?
  assert_eq 6 "$code" "gate 6 still requires authoritative evidence with $availability"
done
finish
