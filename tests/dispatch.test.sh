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
# failed round is one card on the board and not two. Behaviour, not a
# grep for `&` - which is also `2>&1` and `&&`, and would have been
# satisfied by a line with the background operator deleted.
#
# A worker that takes its time: if the dispatcher waited, this would
# take as long as the worker does.
b="$(pr_tree)"
cat > "$b/bin/fm-worker.sh" <<W
#!/usr/bin/env bash
echo \$\$ > "$b/worker-pid"
sleep 5
echo done >> "$b/worker-finished"
W
chmod +x "$b/bin/fm-worker.sh"
t0=$(date +%s)
FM_ROOT="$b" "$b/bin/fm-dispatch.sh" --repo "$b" >/dev/null 2>&1
t1=$(date +%s)
assert_ok "[ $(( t1 - t0 )) -lt 3 ]" "the dispatcher returns without waiting for the worker"
assert_fail "test -e '$b/worker-finished'" "and the worker it started is still running"
# and it is put down rather than left writing into a tree the suite is
# about to delete
for _ in $(seq 1 30); do [ -s "$b/worker-pid" ] && break; sleep 0.1; done
wpid="$(cat "$b/worker-pid" 2>/dev/null)"
[ -z "$wpid" ] || kill -TERM "$wpid" 2>/dev/null

# and the conclusion criterion 6 rests on, rather than the premise: the
# worker the dispatcher starts is not handed a number. The two states
# above are WHY there is never one to hand; this reads the argv of the
# worker that actually ran, on a tree where the other task does have a
# pull request - so it is the conclusion observed once, not proved for
# every path.
a="$(pr_tree)"
cat > "$a/bin/fm-worker.sh" <<W
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$a/argv"
W
chmod +x "$a/bin/fm-worker.sh"
FM_ROOT="$a" "$a/bin/fm-emit.sh" --actor firstmate --type pr_opened --task T-001 --pr 5 \
  --en "opened #5" --tw "已開 #5" >/dev/null
FM_ROOT="$a" "$a/bin/fm-dispatch.sh" --repo "$a" >/dev/null 2>&1
for _ in $(seq 1 30); do [ -s "$a/argv" ] && break; sleep 0.1; done
assert_ne "" "$(cat "$a/argv" 2>/dev/null)" "a worker was started, so there is an argv to read"
assert_lacks "$(cat "$a/argv")" "--pr" "and no worker is ever started with a pull request number"
rm -rf "$a"

# and it does not read what the worker exits with: a worker that fails
# immediately leaves the dispatcher's own status untouched, so a failed
# round writes the one event the worker wrote and no second one
e="$(pr_tree)"
# a worker that records that it HAS exited, so the absence below is
# read after the thing that could have caused it, not after a sleep
printf '#!/usr/bin/env bash\necho x > "%s/worker-done"\nexit 9\n' "$e" > "$e/bin/fm-worker.sh"
chmod +x "$e/bin/fm-worker.sh"
FM_ROOT="$e" "$e/bin/fm-dispatch.sh" --repo "$e" >/dev/null 2>&1
assert_eq "0" "$?" "a worker that fails does not fail the dispatcher"
for _ in $(seq 1 60); do [ -e "$e/worker-done" ] && break; sleep 0.1; done
assert_ok "test -e '$e/worker-done'" "the failing worker has run and exited"
assert_eq "0" "$(jq -r 'select(.type=="worker_crashed")|.type' "$e/state/events.jsonl" \
  | grep -c . || true)" "and the dispatcher writes no event about it"
rm -rf "$b" "$e"

finish
