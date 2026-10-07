#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# --- the mirror: a round that destroys its own tree is restored (T-128) ----
# A hostile adapter, not a real vendor: destruction has to be exact and
# repeatable to prove recovery, not left to a model's mood. It runs
# unsandboxed (like mock.sh, the adapter it replaces here) - the mirror and
# the restore this proves live in fm-worker.sh itself, outside the sandbox,
# and do not depend on the OS sandbox being the thing that stops the
# deletion; tests/sandbox.test.sh's real-sandbox check covers that half.
dMir="$(fixture T-MIR)"
# Destroy only after the written file is present in a committed mirror
# generation. A fixed delay could expire before the watcher copied it.
cat > "$dMir/repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
tree="$3"
: > "$tree/before-the-wreck.txt"
python3 - "$FM_ROOT" "${tree##*/}" <<'PYMIRROR'
from pathlib import Path
import sys, time
mirror = Path(sys.argv[1]) / 'state/mirrors/self' / sys.argv[2]
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    if any(p.parent.name.isdigit() for p in mirror.glob('*/before-the-wreck.txt')):
        break
    time.sleep(.05)
else:
    raise SystemExit('the written file never reached a mirror generation')
PYMIRROR
[ "$?" = 0 ] || exit 70
rm -rf "$tree"
exit 0
M
chmod +x "$dMir/repo/bin/adapters/mock.sh"
GHMir="$(ghstub "$dMir")"
outMir="$(cd "$dMir/repo" && FM_ROOT="$dMir/repo" FM_GH="$GHMir" FM_MIRROR_INTERVAL=1 \
  bin/fm-worker.sh --task T-MIR --name worker-mir 2>&1)"; rcMir=$?
assert_eq "0" "$rcMir" "a round that destroys its own tree, having left uncommitted work the mirror already caught, still completes"
assert_contains "$outMir" "destroyed its own tree" "and says so, rather than reporting it as a round that changed nothing"
assert_ok "test -e '$dMir/repo/state/worktrees/T-MIR/.git'" "and the worktree's .git is there afterward"
assert_ok "git -C '$dMir/repo/state/worktrees/T-MIR' status" "and git works in it"
assert_contains "$(git -C "$dMir/repo/state/worktrees/T-MIR" show --stat HEAD 2>/dev/null)" "before-the-wreck.txt" \
  "the file written just before the wreck reached the commit fm-worker.sh pushed"
mirlog="$dMir/repo/state/events.jsonl"
# bin/fm-emit.sh's TYPES enum is out of this task's scope and has no
# worktree_restored type; it rides worker_crashed, named by .data.event_kind
# (bin/fm-worker.sh's mirror_restore).
assert_eq "worktree_restored" \
  "$(jq -r 'select(.type=="worker_crashed" and .data.event_kind=="worktree_restored") | .data.event_kind' "$mirlog" | tail -1)" \
  "a worktree_restored event is recorded"
assert_eq "true" \
  "$(jq -r 'select(.type=="worker_crashed" and .data.event_kind=="worktree_restored") | .summary.en | (type=="string" and test("\\S"))' "$mirlog" 2>/dev/null | tail -1)" \
  "with an English summary"
assert_eq "true" \
  "$(jq -r 'select(.type=="worker_crashed" and .data.event_kind=="worktree_restored") | .summary."zh-TW" | (type=="string" and test("\\S"))' "$mirlog" 2>/dev/null | tail -1)" \
  "and a zh-TW one (design section 9)"
# the mirror itself, outside both of the round's write roots
assert_ok "test -d '$dMir/repo/state/mirrors/self/T-MIR'" "the mirror lives outside the worktree and the round's own temp directory"
# gate 4: revert bin/fm-worker.sh's mirror mechanism (the sandbox.test.sh
# static profile checks are this test's fail-first for the sandbox half) -
# left to the reviewer's run, since it needs the real script reverted, not
# a fixture copy; this suite proves the mechanism works, not its absence
rm -rf "$dMir"

# --- detection asks git, not a guess from file type or path (T-128 round 5) -
# on 2026-09-27 the required check found four real crew rounds (T-035's
# fixture among them, in tests/herdr.test.sh, out of this task's own scope)
# whose git never lays down a real .git of its own - a stub that answers
# every unhandled command with silent success, exactly what
# tests/herdr.test.sh's and tests/crew-end-to-end.test.sh's own stub git do
# - judged "its .git link is gone" by a check that only asked whether the
# path existed, restored an older mirror generation over a tree that was
# never wrecked, and lost the round's own file that generation predated.
# tree_git_ok (bin/fm-worker.sh) is extracted here verbatim, not retyped by
# hand, so reverting the real function empties this block and the call
# below fails outright rather than quietly passing.
dGitOk="$(safe_tmpdir)"
mkdir -p "$dGitOk/stub" "$dGitOk/tree"
cat > "$dGitOk/stub/git" <<'G'
#!/usr/bin/env python3
import sys, pathlib
a = sys.argv[1:]
if a[:2] == ['worktree', 'add']:
    pathlib.Path(a[-2]).mkdir(parents=True, exist_ok=True)
elif a[0] in ('show-ref', 'ls-remote'):
    sys.exit(1)
# every other command, including -C <tree> rev-parse -q --verify HEAD,
# answers with silent success - an unhandled command falling through with no
# branch of its own, the same shape both real fixtures' stub git take
G
chmod +x "$dGitOk/stub/git"
{
  sed -n '/^tree_git_ok() {/,/^}/p' "$ROOT/bin/fm-worker.sh"
  printf 'tree="$1"\n'
  printf 'tree_git_ok && echo healthy || echo wrecked\n'
} > "$dGitOk/probe.sh"
outGitOk="$(PATH="$dGitOk/stub:$PATH" bash "$dGitOk/probe.sh" "$dGitOk/tree" 2>/dev/null)"
assert_eq "healthy" "$outGitOk" \
  "a tree whose git never lays down a .git of its own is not judged wrecked"
# and the same function must still catch a real worktree's .git actually
# going missing - the ceiling this fix relies on (GIT_CEILING_DIRECTORIES)
# must stop short of finding this repository's own outer .git and answering
# for that one instead, since every real worktree sits nested inside it
rm -rf "$dGitOk/tree"
(
  cd "$dGitOk" || exit 1
  git init -q -b main >/dev/null 2>&1
  git config user.email a@b.c; git config user.name t
  echo hi > f.txt
  git add -A; git commit -qm base >/dev/null 2>&1
  git worktree add -q tree -b t-x-branch >/dev/null 2>&1
)
outGitOkReal="$(bash "$dGitOk/probe.sh" "$dGitOk/tree" 2>/dev/null)"
assert_eq "healthy" "$outGitOkReal" "and a real, intact worktree nested in its own repository is judged healthy"
rm -f "$dGitOk/tree/.git"
outGitOkGone="$(bash "$dGitOk/probe.sh" "$dGitOk/tree" 2>/dev/null)"
assert_eq "wrecked" "$outGitOkGone" \
  "and that same worktree's .git actually gone is still caught, not papered over by the enclosing repository"
safe_rm_rf "$dGitOk"

# --- restore must never lose work newer than the mirror (T-128 round 5) ----
# Even a genuine wreck must not cost a file the round wrote since the
# mirror's last generation: wiping the tree before copying the mirror back
# in, as an earlier round did, deletes such a file first and then has
# nothing newer to put in its place - a restore that makes a file vanish is
# worse than no restore. FM_MIRROR_INTERVAL is generous here so only the
# deterministic before/after-the-round syncs run, never the background
# watcher, so the new file is provably absent from every mirror generation
# when the round ends, not merely absent by timing luck.
dPreserve="$(fixture T-PRESERVE)"
cat > "$dPreserve/repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
tree="$3"
echo new-content > "$tree/new-since-mirror.txt"
rm -f "$tree/.git"
exit 0
M
chmod +x "$dPreserve/repo/bin/adapters/mock.sh"
GHPreserve="$(ghstub "$dPreserve")"
outPreserve="$(cd "$dPreserve/repo" && FM_ROOT="$dPreserve/repo" FM_GH="$GHPreserve" FM_MIRROR_INTERVAL=60 \
  bin/fm-worker.sh --task T-PRESERVE --name worker-preserve 2>&1)"; rcPreserve=$?
assert_eq "0" "$rcPreserve" "a round that deletes only its own .git, having written a file since the last mirror generation, still completes"
assert_contains "$outPreserve" "destroyed its own tree" "and is reported as one that destroyed its own tree"
assert_ok "test -e '$dPreserve/repo/state/worktrees/T-PRESERVE/.git'" "its .git is repaired"
assert_ok "git -C '$dPreserve/repo/state/worktrees/T-PRESERVE' status" "and git works in it again"
assert_eq "new-content" \
  "$(cat "$dPreserve/repo/state/worktrees/T-PRESERVE/new-since-mirror.txt" 2>/dev/null)" \
  "the file written after the last mirror generation was not overwritten by the restore"
assert_contains "$(git -C "$dPreserve/repo/state/worktrees/T-PRESERVE" show --stat HEAD 2>/dev/null)" \
  "new-since-mirror.txt" \
  "and reached the commit fm-worker.sh pushed, not lost to the restore that repaired .git"
rm -rf "$dPreserve"

# --- a restored round is told so in its NEXT prompt (T-128 round 8, review) -
# Acceptance 4's own words: "a worker round that finds its tree restored
# mid-run is told so in its next prompt." fm-worker.sh:1275-1283 reads and
# clears state/worktrees/<task>.restored while building the prompt, but
# nothing before this ran fm-worker.sh a second time to see it happen - round
# 1 destroys the tree (the same proven shape T-MIR uses above), round 2 is a
# plain adapter that only captures the prompt it was handed, and round 3
# proves the marker was cleared, not merely never written.
dRP="$(fixture T-RESTOREPROMPT)"
cat > "$dRP/repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
tree="$3"
: > "$tree/before-the-wreck.txt"
python3 - "$FM_ROOT" "${tree##*/}" <<'PYMIRROR'
from pathlib import Path
import sys, time
mirror = Path(sys.argv[1]) / 'state/mirrors/self' / sys.argv[2]
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    if any(p.parent.name.isdigit() for p in mirror.glob('*/before-the-wreck.txt')):
        break
    time.sleep(.05)
else:
    raise SystemExit('the written file never reached a mirror generation')
PYMIRROR
[ "$?" = 0 ] || exit 70
rm -rf "$tree"
exit 0
M
chmod +x "$dRP/repo/bin/adapters/mock.sh"
GHRP="$(ghstub "$dRP")"
( cd "$dRP/repo" && FM_ROOT="$dRP/repo" FM_GH="$GHRP" FM_MIRROR_INTERVAL=1 \
    bin/fm-worker.sh --task T-RESTOREPROMPT --name worker-rp1 >/dev/null 2>&1 )
assert_ok "test -s '$dRP/repo/state/worktrees/T-RESTOREPROMPT.restored'" \
  "round 1 destroyed its tree and left a marker for the next round to read"

cat > "$dRP/repo/bin/adapters/mock.sh" <<'M2'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "${FM_CAPTURE:-/dev/null}" 2>/dev/null
: > "$3/round-two.txt"
exit 0
M2
chmod +x "$dRP/repo/bin/adapters/mock.sh"
capRP2="$dRP/prompt2.md"
( cd "$dRP/repo" && FM_ROOT="$dRP/repo" FM_GH="$GHRP" FM_CAPTURE="$capRP2" \
    bin/fm-worker.sh --task T-RESTOREPROMPT --name worker-rp2 >/dev/null 2>&1 )
assert_contains "$(cat "$capRP2" 2>/dev/null)" "Your tree was restored" \
  "round 2's own prompt says the tree was restored mid-run"
assert_ok "[ ! -s '$dRP/repo/state/worktrees/T-RESTOREPROMPT.restored' ]" \
  "and the marker is cleared after being read once"

capRP3="$dRP/prompt3.md"
( cd "$dRP/repo" && FM_ROOT="$dRP/repo" FM_GH="$GHRP" FM_CAPTURE="$capRP3" \
    bin/fm-worker.sh --task T-RESTOREPROMPT --name worker-rp3 >/dev/null 2>&1 )
assert_lacks "$(cat "$capRP3" 2>/dev/null)" "Your tree was restored" \
  "round 3, with nothing left to report, is not told again"
rm -rf "$dRP"

# --- the watcher does not outlive a round killed outright (T-128 round 4) --
# SIGKILL runs no trap, so a round killed outright never reaches
# mirror_watch_stop to write the stop file; without its own check the
# watcher would run forever as an orphan, still writing into state/. `exec`
# inside the backgrounded subshell below replaces it with fm-worker.sh
# itself, so the captured pid is the round's own, and killing only that one
# pid (never its process group) leaves every child, the watcher included, to
# fend for itself - exactly an uncatchable kill of the parent alone.
mirror_gen_latest() {   # mirror_gen_latest <mirror-dir> -> highest generation number, or 0
  local n best=0
  for n in "$1"/*/; do
    [ -d "$n" ] || continue
    n="${n%/}"; n="${n##*/}"
    case "$n" in *[!0-9]*|'') continue ;; esac
    [ "$n" -le "$best" ] || best="$n"
  done
  printf '%s\n' "$best"
}
dKill="$(fixture T-KILL)"; rKill="$dKill/repo"; GHKill="$(ghstub "$dKill")"
cat > "$rKill/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
: > "${FM_STARTED:?}"
echo $$ > "${FM_ADAPTER_PID:?}"
# one process, so the kill below ends all of it: a bash that ran sleep as
# its child would leave the sleep behind (T-151)
exec sleep 60
M
chmod +x "$rKill/bin/adapters/mock.sh"
# The first incremental mirror calls rsync from the watcher. Record that
# caller so the test can wait on its kernel exit notification after SIGKILL.
mkdir -p "$dKill/mirror-tools"
real_rsync="$(command -v rsync)"
printf '#!/usr/bin/env bash\nprintf "%%s\n" "$PPID" > %q\nexec %q "$@"\n' \
  "$dKill/mirror.pid" "$real_rsync" > "$dKill/mirror-tools/rsync"
chmod +x "$dKill/mirror-tools/rsync"
startedKill="$dKill/started"; adapterpidKill="$dKill/adapter.pid"; mirdirKill="$rKill/state/mirrors/self/T-KILL"
( cd "$rKill" && PATH="$dKill/mirror-tools:$PATH" FM_ROOT="$rKill" FM_GH="$GHKill" FM_MIRROR_INTERVAL=1 FM_STARTED="$startedKill" \
    FM_ADAPTER_PID="$adapterpidKill" exec bin/fm-worker.sh --task T-KILL --name worker-kill >/dev/null 2>&1 ) &
kpKill=$!
for _ in $(seq 1 60); do [ -e "$startedKill" ] && break; sleep 0.2; done
assert_ok "test -e '$startedKill'" "T-KILL: the adapter started, so the round and its watcher are both up"
for _ in $(seq 1 150); do
  g1="$(mirror_gen_latest "$mirdirKill")"
  [ "$g1" -ge 2 ] && break
  sleep 0.1
done
assert_ok "[ \"$g1\" -ge 2 ]" "T-KILL: the watcher published a generation after the initial baseline"
python3 - "$ROOT/bin/lib" "$dKill/mirror.pid" "$kpKill" <<'PYEXIT'
import os, select, signal, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from fm_lifeline import ProcessExit
watcher = int(Path(sys.argv[2]).read_text())
notice = ProcessExit(watcher)
try:
    os.kill(int(sys.argv[3]), signal.SIGKILL)
    ready, _, _ = select.select([notice.fileno()], [], [], 10)
    if not ready or not notice.gone():
        os.kill(watcher, signal.SIGKILL)
        raise SystemExit('mirror watcher did not end with its owner')
finally:
    notice.close()
PYEXIT
watcher_exit=$?
kill -KILL "$kpKill" 2>/dev/null || true  # also clean up if instrumentation failed
wait "$kpKill" 2>/dev/null
g2="$(mirror_gen_latest "$mirdirKill")"
g1plus1=$(( g1 + 1 ))
assert_ok "[ \"$watcher_exit\" = 0 ] && [ \"$g2\" -le \"$g1plus1\" ]" \
  "T-KILL: the watcher stops within its own poll tick once its parent is gone (killed alone, no trap runs), not left running as an orphan"
# the adapter outlived the round on purpose here; the block ends it and
# waits until it is gone, so nothing it started runs past the suite (T-151)
apKill="$(cat "$adapterpidKill" 2>/dev/null)"
if [ -n "$apKill" ]; then
  kill -KILL "$apKill" 2>/dev/null
  for _ in $(seq 1 50); do kill -0 "$apKill" 2>/dev/null || break; sleep 0.1; done
fi
rm -rf "$dKill"


cd "$ROOT" || exit 1
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
