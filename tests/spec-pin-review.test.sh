#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/review.sh"
. "$ROOT/tests/lib/spec-pins.sh"
d="$(fixture)"; repo="$d/repo"; GH="$(ghstub "$d")"
printf 'vendor: mock\nproject:\n  check: true\n' > "$repo/config.yaml"
printf 'state/\n' > "$repo/.gitignore"
printf '# Approved design\n' > "$repo/design/design.md"
git -C "$repo" add config.yaml .gitignore design/design.md; git -C "$repo" commit -qm contract
seed_spec_pin "$repo" T-Z
git -C "$repo" checkout -q work
printf '{"id":"T-Z","title":"BRANCH_SCOPE_INJECTION","scope":["**"]}\n' > "$repo/design/tasks/T-Z.json"
git -C "$repo" commit -qam 'branch edits task'; git -C "$repo" checkout -q main
cat > "$repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
cp "$2" "$FM_SEEN/prompt.md"
printf 'APPROVE:T-Z\n' > "$3/verdict.txt"
M
chmod +x "$repo/bin/adapters/mock.sh"
(cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-review.sh --task T-Z --branch work) > "$d/out" 2>&1
assert_eq 0 "$?" 'reviewer resolves an authorized pin before its adapter'
intro="$(sed '/^# Round /q' "$d/prompt.md")"
assert_contains "$intro" '# Approved spec pin' 'reviewer receives the same pin record as the worker'
assert_contains "$intro" '"title":"a task"' 'reviewer task context keeps the approved spec'
assert_lacks "$intro" BRANCH_SCOPE_INJECTION 'branch edits cannot replace reviewer acceptance or scope'
rm -rf "$d"
finish
