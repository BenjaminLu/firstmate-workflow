#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# shellcheck source=tests/lib/stacking.sh
. "$ROOT/tests/lib/stacking.sh"

for scenario in matching stale mismatched; do
  d="$(fixture T-902)"; r="$d/repo"
  stacking_policy "$r/CONVENTIONS.md" allowed
  printf '{"id":"T-901","depends_on":[]}\n' > "$r/design/tasks/T-901.json"
  jq '.depends_on=["T-901"]' "$r/design/tasks/T-902.json" > "$d/task"
  mv "$d/task" "$r/design/tasks/T-902.json"
  seed_spec_preflight "$r" T-902
  seed_self_pr_authoring "$r" T-902 self
  cat > "$r/bin/adapters/mock.sh" <<'MOCK'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
mkdir -p "$3/src"
printf 'child\n' > "$3/src/child"
MOCK
  chmod +x "$r/bin/adapters/mock.sh"
  git -C "$r" add -A; git -C "$r" commit -qm 'child contract'
  git -C "$r" checkout -qb t-901-parent
  mkdir -p "$r/src"; echo parent > "$r/src/parent"
  git -C "$r" add src; git -C "$r" commit -qm parent
  parent="$(git -C "$r" rev-parse HEAD)"
  git -C "$r" push -q origin main t-901-parent
  git -C "$r" checkout -q main
  advertised="$parent"; parent_branch=t-901-parent
  [ "$scenario" != stale ] || advertised=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  [ "$scenario" != mismatched ] || parent_branch=t-999-unrelated
  stacking_gh "$d" "$advertised" "$parent_branch"
  seed_self_pr_authoring "$r" T-902 self
  out="$(cd "$r" && GH_REPO=fixture/project FM_ROOT="$r" FM_GH="$d/gh" bin/fm-worker.sh --task T-902 2>&1)"; code=$?
  printf '%s\n' "$out" > "$d/worker.out"
  if [ "$scenario" = matching ]; then
    assert_eq 0 "$code" 'stacked worker completes'
    assert_contains "$(grep 'pr create' "$d/ghcalls")" '--base t-901-parent' 'stacked worker opens PR against parent'
    assert_ok "test -f '$r/state/worktrees/T-902/src/parent'" 'stacked worker inherits parent implementation'
  else
    assert_eq 65 "$code" "$scenario parent refuses worker"
    assert_lacks "$(cat "$d/ghcalls")" 'pr create' "$scenario parent creates no PR"
    assert_fail "test -e '$r/state/worktrees/T-902/src/child'" "$scenario parent never starts adapter"
  fi
  rm -rf "$d"
done
finish
