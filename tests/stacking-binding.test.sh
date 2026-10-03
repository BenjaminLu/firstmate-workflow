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
finish
