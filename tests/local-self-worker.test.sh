#!/usr/bin/env bash
# Dependencies: bin/fm-worker.sh tests/lib/worker.sh
# tests/lib/local_self_shell.py
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/worker.sh"
d="$(fixture)"; repo="$d/repo"; GH="$(ghstub "$d")"
printf '{"id":"T-OTHER","scope":["src/**"]}\n' > "$repo/design/tasks/T-OTHER.json"
git -C "$repo" add -f design/tasks/T-OTHER.json
git -C "$repo" commit -qm 'another tracked base task'
git -C "$repo" push -q origin main
cat > "$repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
mkdir -p "$3/src"
printf 'implemented\n' > "$3/src/feature"
printf 'staged by adapter\n' > "$3/design/tasks/T-NEW.json"
printf 'changed other task\n' > "$3/design/tasks/T-OTHER.json"
git -C "$3" add -f design/tasks/T-Z.json design/tasks/T-NEW.json design/tasks/T-OTHER.json
M
chmod +x "$repo/bin/adapters/mock.sh"
(cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" bin/fm-worker.sh --task T-Z) > "$d/out" 2>&1
assert_eq 0 "$?" 'worker round publishes implementation and spec cleanup'
branch="$(tail -1 "$d/out")"
assert_eq '' "$(git -C "$repo" ls-tree --name-only "$branch" -- design/tasks/T-Z.json design/tasks/T-NEW.json)" 'own and non-base specs never enter the round commit'
assert_eq "$(git -C "$repo" rev-parse main:design/tasks/T-OTHER.json)" "$(git -C "$repo" rev-parse "$branch:design/tasks/T-OTHER.json")" 'another tracked base task retains the base bytes'
assert_ok "test -f '$repo/state/worktrees/T-Z/design/tasks/T-Z.json'" 'own pinned spec stays on disk'
# Rebuild helpers run in fixture trees; no production suite is invoked here.
python3 "$ROOT/tests/lib/local_self_shell.py" "$ROOT" "$d"
assert_eq 0 "$?" 'rebuild and checkpoint behavior'
rm -rf "$d"
finish
