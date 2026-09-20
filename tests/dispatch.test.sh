#!/usr/bin/env bash
# Nothing starts before the captain has seen it, nothing starts before its
# dependencies land, and never more than the limit at once.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

fixture() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/bin" "$d/design" "$d/state"
  cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-dispatch.sh" "$d/bin/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/fm-worker.sh"; chmod +x "$d/bin/fm-worker.sh"
  printf 'concurrency: 2\n' > "$d/config.yaml"
  cat > "$d/design/tasks.json" <<'JSON'
{"tasks":[
 {"id":"A","depends_on":[]},
 {"id":"B","depends_on":["A"]},
 {"id":"C","depends_on":[]},
 {"id":"D","depends_on":[]}
]}
JSON
  printf '%s' "$d"
}
say() { FM_ROOT="$1" "$1/bin/fm-emit.sh" --actor firstmate --type "$2" ${3:+--task "$3"} >/dev/null; }
ready() { FM_ROOT="$1" "$1/bin/fm-dispatch.sh" --repo "$1" --dry-run 2>/dev/null | sed '/^fm-dispatch/d'; }

d="$(fixture)"
assert_fail "FM_ROOT='$d' '$d/bin/fm-dispatch.sh' --repo '$d' --dry-run" \
  "nothing is dispatched before a greenlit event"
say "$d" greenlit
assert_eq "A
C" "$(ready "$d")" "only tasks with no unmet dependency, up to the limit"

say "$d" dispatched A; say "$d" dispatched C
assert_eq "" "$(ready "$d")" "the limit is respected while work is in flight"

say "$d" merged A
assert_eq "B" "$(ready "$d")" "a merged dependency unblocks its dependent, one slot free"

say "$d" merged C
assert_eq "B
D" "$(ready "$d")" "both slots free again"

# a closed task frees its slot without unblocking anything downstream
d2="$(fixture)"; say "$d2" greenlit; say "$d2" dispatched A; say "$d2" closed A
assert_eq "C
D" "$(ready "$d2")" "a closed task frees a slot but does not count as done"
assert_fail "ready '$d2' | grep -qx B" "a closed dependency does not unblock its dependent"

# the limit comes from config.yaml and can be overridden
d3="$(fixture)"; say "$d3" greenlit
assert_eq "1" "$(FM_ROOT="$d3" "$d3/bin/fm-dispatch.sh" --repo "$d3" --dry-run --limit 1 | sed '/^fm-dispatch/d' | wc -l | tr -d ' ')" \
  "--limit overrides the configured concurrency"

# the drift lint lives in ci.sh; check the lint's logic, not the ambient repo
lintdir="$(mktemp -d)"; mkdir -p "$lintdir/design"
printf '{"tasks":[{"id":"T-404"}]}\n' > "$lintdir/design/tasks.json"
printf '# design, mentioning nothing\n' > "$lintdir/design/design.md"
cp "$ROOT/bin/ci.sh" "$lintdir/"; mkdir -p "$lintdir/bin"; cp "$ROOT/bin/ci.sh" "$lintdir/bin/"
assert_fail "FM_ROOT='$lintdir' bash '$lintdir/bin/ci.sh'" "the gate fails when the design omits a task id"
printf '| T-404 | a task |\n' >> "$lintdir/design/design.md"
assert_ok "FM_ROOT='$lintdir' bash '$lintdir/bin/ci.sh'" "and passes once the design lists it"
rm -rf "$lintdir"
rm -rf "$d" "$d2" "$d3"
finish
