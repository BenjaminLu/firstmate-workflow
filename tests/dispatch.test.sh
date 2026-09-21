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
  cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-dispatch.sh" "$d/bin/"
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
cp "$ROOT/bin/ci.sh" "$lintdir/"; mkdir -p "$lintdir/bin"
cp "$ROOT/bin/ci.sh" "$ROOT/bin/fm-config.sh" "$lintdir/bin/"
assert_fail "FM_ROOT='$lintdir' bash '$lintdir/bin/ci.sh'" "the gate fails when the design omits a task id"
printf '| T-404 | a task |\n' >> "$lintdir/design/design.md"
assert_ok "FM_ROOT='$lintdir' bash '$lintdir/bin/ci.sh'" "and passes once the design lists it"
rm -rf "$lintdir"
rm -rf "$d" "$d2" "$d3"

# A task whose pull request is open is being worked on, whoever started
# it. Without this the dispatcher starts a second worker on a branch a
# reviewer has already signed - which is what happened the first time the
# dispatcher ran after a task had been started by hand.
# ONE builder for both trees. The control below has to be the same
# tree as the negative or the comparison is between two different
# things, and two copies of a setup written out by hand agree only
# until one of them is edited.
pr_tree() {                     # pr_tree -> a greenlit repo with T-001 and T-002
  local d; d="$(mktemp -d)"; mkdir -p "$d/bin" "$d/design" "$d/state"
  cp "$ROOT/bin/fm-dispatch.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$d/bin/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/fm-worker.sh"; chmod +x "$d/bin/fm-worker.sh"
  printf 'vendor: mock\nconcurrency: 3\n' > "$d/config.yaml"
  printf '{"tasks":[{"id":"T-001","title":"a","depends_on":[]},{"id":"T-002","title":"b","depends_on":[]}]}\n' \
    > "$d/design/tasks.json"
  FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor captain --type greenlit --en go --tw 開工 >/dev/null
  printf '%s' "$d"
}
p="$(pr_tree)"
# the positive control first, or "it did not appear" is evidence about a
# string rather than about a filter: before anything is said about it,
# T-001 is a task this dispatcher would start
# The control is a SEPARATE tree, because running the dispatcher for
# real emits `dispatched` - so a control run against this fixture would
# leave T-001 in flight and the two assertions below could no longer
# tell "not restarted because its pull request is open" from "not
# restarted because it is already started". Same invocation, same
# output surface, no shared state.
c="$(pr_tree)"
assert_contains "$(cd "$c" && FM_ROOT="$c" bin/fm-dispatch.sh --repo "$c" 2>&1)" "T-001" \
  "the same tree without the pull request event does dispatch T-001"
rm -rf "$c"
# T-001 has a pull request open and no dispatched event: started by hand
FM_ROOT="$p" "$p/bin/fm-emit.sh" --actor worker-1 --task T-001 --type pr_opened --pr 5 \
  --en "opened #5" --tw "已開 #5" >/dev/null
out="$(cd "$p" && FM_ROOT="$p" bin/fm-dispatch.sh --repo "$p" 2>&1)"
assert_lacks "$out" "T-001" "a task with an open pull request is not dispatched again"
assert_contains "$out" "T-002" "and the one that is free still starts"
# once it is merged it is done, not free
FM_ROOT="$p" "$p/bin/fm-emit.sh" --actor captain --task T-001 --type merged --pr 5 \
  --en "merged" --tw "已合併" >/dev/null
out="$(cd "$p" && FM_ROOT="$p" bin/fm-dispatch.sh --repo "$p" 2>&1)"
assert_lacks "$out" "T-001" "and a merged task is not dispatched either"
# Which is why a worker has to find its own pull request: there is no
# state in which this script starts a task that has one. It is in flight
# while the pull request is open and done once it is settled, so the
# number it reads off the log is never a number it can hand to a worker.
# A later round started by hand therefore arrives with nothing, and
# bin/fm-worker.sh looks the number up before it builds the prompt.
rm -rf "$p"

# §5.3.2 says nothing reads the worker's exit status, which is why one
# failed round is one card on the board and not two. That is a claim
# about this file, so this file carries it: the worker is started in
# the background and never waited for.
started_line="$(grep -n 'bin/fm-worker.sh' "$ROOT/bin/fm-dispatch.sh" | grep -v '^[0-9]*: *#')"
assert_ne "" "$started_line" "the dispatcher starts the worker"
assert_contains "$started_line" "&" "in the background"
assert_eq "" "$(grep -vE '^[[:space:]]*#' "$ROOT/bin/fm-dispatch.sh" | grep -E '\bwait\b' || true)" \
  "and never waits for it, so nothing here reads its exit status"

finish
