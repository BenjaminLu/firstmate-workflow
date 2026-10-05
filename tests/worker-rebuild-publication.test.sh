#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# shellcheck source=tests/lib/worker-rebuild.sh
. "$ROOT/tests/lib/worker-rebuild.sh"
# shellcheck source=tests/lib/worker-note.sh
. "$ROOT/tests/lib/worker-note.sh"
# --- a clean rebuild is always published (T-098) ------------------------
# A rebuild with nothing handed to the worker is the round's work whether
# or not the worker adds to it. A worker that changed nothing and left a
# note - or only asked, which from round three is the protocol - ended the
# round on the exit path, and the EXIT trap said "the rebuild ... was not
# committed (exit-0)": the branch stayed on its old head, DIRTY on GitHub,
# until the captain pushed it by hand (T-089, T-086). Under the real hooks.
rb_published_alone() {   # rb_published_alone <dir> <branch> <old head> <main head> <case>
  assert_eq "0" "$rb_rc" "$5: the round completes"
  assert_lacks "$rb_out" "was not committed" "$5: and the exit publishes nothing of its own"
  assert_eq "$4" "$(rb_head "$1" "$2^")" "$5: the branch is one commit on the new base"
  assert_eq "1" "$(git --git-dir="$1/remote.git" rev-list --count "main..$2")" "$5: exactly one"
  # the rebuild alone: the task's own change, and nothing else
  assert_eq "$(git --git-dir="$1/remote.git" diff --name-only "$(git --git-dir="$1/remote.git" merge-base main "$3")" "$3")" \
    "$(git --git-dir="$1/remote.git" diff --name-only main "$2")" "$5: carrying the task's change and nothing more"
  assert_contains "$(git --git-dir="$1/remote.git" show "$2:src/app.txt")" "line 10 by main" "$5: with main's change"
  assert_contains "$(git --git-dir="$1/remote.git" show "$2:src/app.txt")" "line 5 by the task" "$5: and the task's"
  assert_eq "$(rb_head "$1" "$2")" "$(git -C "$1/repo" rev-parse "$2")" "$5: the local branch moved onto what was pushed"
  # on the event that reports the push: pr_opened when this round opened
  # the pull request, commit_pushed when it was already there
  assert_eq "$3" "$(jq -r 'select((.type=="commit_pushed" or .type=="pr_opened") and .data.rebuilt!=null)|.data.rebuilt.previous_head' \
    "$1/repo/state/events.jsonl" | tail -1)" "$5: the pushed round records the previous head"
}
# V0: the worker changes nothing and says nothing. Already published before
# T-098; retained as the no-change publication control.
dV0="$(RB_HOOKS=1 rb_fixture)"; bV0="$(rb_branch "$dV0")"
rb_replay_conflict "$dV0"; oldV0="$(rb_head "$dV0" "$bV0")"; mainV0="$(rb_head "$dV0" main)"
printf ':\n' > "$dV0/nothing.sh"
rb_round_two "$dV0" "$dV0/nothing.sh"
rb_rebuilt "$dV0" "V0"
rb_published_alone "$dV0" "$bV0" "$oldV0" "$mainV0" "V0"
# V1: the worker changes nothing and says so in a note
dV1="$(RB_HOOKS=1 rb_fixture)"; bV1="$(rb_branch "$dV1")"
rb_replay_conflict "$dV1"; oldV1="$(rb_head "$dV1" "$bV1")"; mainV1="$(rb_head "$dV1" main)"
printf 'printf "Nothing to change: the rebuild is clean.\\n" > .fm-say.md\n' > "$dV1/note.sh"
rb_round_two "$dV1" "$dV1/note.sh"
rb_rebuilt "$dV1" "V1"
rb_published_alone "$dV1" "$bV1" "$oldV1" "$mainV1" "V1"
assert_contains "$(cat "$dV1/ghcalls")" "pr comment 42 --body-file" "V1: the note is on the pull request"
# V2: the worker only asks. The rebuild is pushed; the round still reports
# that it asked, and the question is on the pull request.
dV2="$(RB_HOOKS=1 rb_fixture)"; bV2="$(rb_branch "$dV2")"
rb_replay_conflict "$dV2"; oldV2="$(rb_head "$dV2" "$bV2")"; mainV2="$(rb_head "$dV2" main)"
printf 'printf "ASK-PASS-CRITERIA:T-Z\\n" > .fm-say.md\n' > "$dV2/ask.sh"
rb_round_two "$dV2" "$dV2/ask.sh"
rb_rebuilt "$dV2" "V2"
rb_published_alone "$dV2" "$bV2" "$oldV2" "$mainV2" "V2"
assert_contains "$rb_out" "the worker asked rather than changed anything; its question is on #42" \
  "V2: the round is reported as asked"
assert_contains "$(cat "$dV2/ghcalls")" "pr comment 42 --body-file" "V2: and the question is on the pull request"
assert_eq "1" "$(jq -r 'select(.type=="ask_pass_criteria")|.type' "$dV2/repo/state/events.jsonl" | wc -l | tr -d ' ')" \
  "V2: posted once"
# V3: the same with no pull request yet. The rebuild opens one, and the
# question waits for it rather than being kept as premature.
dV3="$(RB_HOOKS=1 rb_fixture)"; bV3="$(rb_branch "$dV3")"
rb_replay_conflict "$dV3"; oldV3="$(rb_head "$dV3" "$bV3")"; mainV3="$(rb_head "$dV3" main)"
rb_round_two "$dV3" "$dV2/ask.sh" ''
rb_rebuilt "$dV3" "V3"
rb_published_alone "$dV3" "$bV3" "$oldV3" "$mainV3" "V3"
assert_contains "$rb_out" "the worker asked rather than changed anything; its question waits for the pull request this round opens" \
  "V3: the round is reported as asked"
assert_contains "$(cat "$dV3/ghcalls")" "pr create" "V3: the pull request is opened"
assert_lacks "$(cat "$dV3/ghcalls")" "--draft" "V3: a question beside a rebuild opens a ready pull request"
assert_contains "$(cat "$dV3/ghcalls")" "pr comment 42 --body-file" "V3: and the question goes on it"
assert_eq "" "$(ls "$dV3/repo/state/unsent" 2>/dev/null)" "V3: nothing is kept as unsent"
# V5: the pull request refuses the worker's note. The round still fails as
# a refused note does, and keeps it once, where it was refused - and the
# rebuild is pushed all the same. The note is never posted a second time.
rb_refusing_gh() {   # rb_refusing_gh <dir> [once]: --body-file is refused, every time or the first
  cat > "$1/stub/gh" <<G
#!/usr/bin/env bash
echo "gh \$*" >> "$1/ghcalls"
case " \$* " in *" --body-file "*)
  if [ "${2:-}" != once ] || [ ! -e "$1/refused-once" ]; then
    : > "$1/refused-once"; echo "could not post" >&2; exit 1
  fi ;;
esac
echo "https://example.invalid/pull/42"
G
}
rb_note_kept_once() {   # rb_note_kept_once <dir> <case>
  assert_contains "$rb_out" "#42 would not take the comment" "$2: the refusal is said"
  assert_eq "1" "$(grep -c -- '--body-file' "$1/ghcalls")" "$2: the note is offered to the pull request once"
  assert_eq "1" "$(find "$1/repo/state/unsent" -name 'T-Z-*.md' 2>/dev/null | wc -l | tr -d ' ')" "$2: and kept once"
  local kept=("$1"/repo/state/unsent/T-Z-*.md)
  assert_eq 42 "$(jq -r .pr "${kept[0]}.json")" "$2: sidecar records PR"
  assert_contains "$(cat "${kept[0]}" 2>/dev/null)" "ASK-PASS-CRITERIA:T-Z" "$2: with the worker's text"
  assert_lacks "$rb_out" "before the worker's note reached a pull request" "$2: and never said to be lost"
  assert_contains "$rb_out" "the worker asked rather than changed anything; #42 would not take its question" \
    "$2: the round is reported as asked"
}
dV5="$(RB_HOOKS=1 rb_fixture)"; bV5="$(rb_branch "$dV5")"
rb_replay_conflict "$dV5"; oldV5="$(rb_head "$dV5" "$bV5")"; mainV5="$(rb_head "$dV5" main)"
rb_refusing_gh "$dV5"
rb_round_two "$dV5" "$dV2/ask.sh"
rb_rebuilt "$dV5" "V5"
assert_eq "73" "$rb_rc" "V5: a refused note still fails the round"
rb_note_kept_once "$dV5" "V5"
assert_lacks "$rb_out" "was not committed" "V5: and the rebuild is not left behind"
assert_eq "$mainV5" "$(rb_head "$dV5" "$bV5^")" "V5: the branch is one commit on the new base"
assert_ne "$oldV5" "$(rb_head "$dV5" "$bV5")" "V5: off its old head"
assert_eq "$(rb_head "$dV5" "$bV5")" "$(git -C "$dV5/repo" rev-parse "$bV5")" \
  "V5: the local branch moved onto what was pushed"
# V5b: the pull request refuses the first post and would take a later one.
# There is no later one: the round is 73, and the note is in one place.
dV5b="$(RB_HOOKS=1 rb_fixture)"; bV5b="$(rb_branch "$dV5b")"
rb_replay_conflict "$dV5b"; mainV5b="$(rb_head "$dV5b" main)"
rb_refusing_gh "$dV5b" once
rb_round_two "$dV5b" "$dV2/ask.sh"
rb_rebuilt "$dV5b" "V5b"
assert_eq "73" "$rb_rc" "V5b: a note refused once still fails the round"
rb_note_kept_once "$dV5b" "V5b"
assert_eq "$mainV5b" "$(rb_head "$dV5b" "$bV5b^")" "V5b: and the rebuild is pushed"
# V5c: the note is refused, then so is the push. The note was kept where it
# was refused, so the failed push neither loses it nor keeps it again.
dV5c="$(RB_HOOKS=1 rb_fixture)"; bV5c="$(rb_branch "$dV5c")"
rb_replay_conflict "$dV5c"; oldV5c="$(rb_head "$dV5c" "$bV5c")"
rb_refusing_gh "$dV5c"
PATH="$(rb_gitwrap "$dV5c"):$PATH" FM_T_GIT_FAIL=" --force-with-lease=" rb_round_two "$dV5c" "$dV2/ask.sh"
rb_rebuilt "$dV5c" "V5c"
assert_eq "71" "$rb_rc" "V5c: a refused push ends the round with its own code"
assert_contains "$rb_out" "could not push the rebuilt $bV5c" "V5c: the refusal is the rebuild's push"
rb_note_kept_once "$dV5c" "V5c"
assert_eq "$oldV5c" "$(rb_head "$dV5c" "$bV5c")" "V5c: and the branch stays where it was"
# T-199: a report beside worker changes survives a rebuilt publication.
for outcome in published lease-refused; do
  dN="$(RB_HOOKS=1 rb_fixture)"; bN="$(rb_branch "$dN")"
  rb_replay_conflict "$dN"; oldN="$(rb_head "$dN" "$bN")"; mainN="$(rb_head "$dN" main)"
  cat > "$dN/work-note.sh" <<'S'
echo work > src/round-two
printf 'ASK-PASS-CRITERIA:T-Z\n' > .fm-say.md
S
  if [ "$outcome" = published ]; then
    note_gh "$dN"
    NOTE_PR=42 FM_NOTE_RETRY_DELAYS='0 0' rb_round_two "$dN" "$dN/work-note.sh"
    assert_eq 0 "$rb_rc" 'rebuilt work completes despite exhausted transient note retries'
    assert_eq 3 "$(grep -c -- '--body-file' "$dN/ghcalls")" 'rebuilt note has at most two retries'
    assert_eq "$mainN" "$(rb_head "$dN" "$bN^")" 'rebuilt work is on current base'
    assert_eq work "$(git --git-dir="$dN/remote.git" show "$bN:src/round-two")" 'worker changes were pushed'
    assert_eq 'T-Z: a mock task' "$(git --git-dir="$dN/remote.git" log -1 --format=%s "$bN")" 'rebuilt publication uses normal commit'
    assert_eq 1 "$(jq -s '[.[]|select(.type=="worker_note_unsent" and .pr==42)]|length' "$dN/repo/state/events.jsonl")" 'one unsent event'
    want_head="$(rb_head "$dN" "$bN")"
  else
    rb_refusing_gh "$dN"
    PATH="$(rb_gitwrap "$dN"):$PATH" FM_T_GIT_FAIL=' --force-with-lease=' rb_round_two "$dN" "$dN/work-note.sh"
    assert_eq 71 "$rb_rc" 'lease refusal retains its own code after saving note'
    assert_eq 1 "$(grep -c -- '--body-file' "$dN/ghcalls")" 'generic refusal offered once'
    assert_eq "$oldN" "$(rb_head "$dN" "$bN")" 'lease refusal leaves branch unchanged'
    assert_lacks "$(cat "$dN/repo/state/events.jsonl")" worker_note_unsent 'no wake for unpublished rebuild'
    want_head=null
  fi
  rb_rebuilt "$dN" "$outcome"
  keptN=("$dN"/repo/state/unsent/T-Z-*.md)
  assert_eq 1 "${#keptN[@]}" 'rebuilt changed round keeps note once'
  assert_contains "$rb_out" state/unsent/T-Z 'rebuilt round says where recovery lives'
  assert_eq 42 "$(jq -r .pr "${keptN[0]}.json")" 'rebuilt sidecar records PR'
  assert_eq "$want_head" "$(jq -r .head "${keptN[0]}.json")" 'rebuilt sidecar reflects publication'
  assert_lacks "$(cat "$dN/repo/state/events.jsonl")" worker_crashed 'refused report is not a crash'
done
# V4: a conflicting rebuild the worker only asks about is still not
# published: the markers are the worker's to resolve, next round.
dV4="$(RB_HOOKS=1 rb_fixture)"; bV4="$(rb_branch "$dV4")"; oldV4="$(rb_head "$dV4" "$bV4")"
rb_conflicting_main "$dV4"; pushedV4="$(rb_pushed "$dV4")"
rb_round_two "$dV4" "$dV2/ask.sh"
rb_rebuilt "$dV4" "V4"
assert_eq "0" "$rb_rc" "V4: an asking round on a conflicting rebuild completes"
assert_contains "$rb_out" "the worker asked rather than changed anything" "V4: as asked"
assert_contains "$rb_out" "the rebuild of $bV4 was not committed" "V4: and says the rebuild is not published"
assert_eq "$oldV4" "$(rb_head "$dV4" "$bV4")" "V4: the remote branch is not touched"
assert_eq "$oldV4" "$(git -C "$dV4/repo" rev-parse "$bV4")" "V4: nor the local one"
assert_eq "$pushedV4" "$(rb_pushed "$dV4")" "V4: and no commit is reported"
# V6: every file merges, but restoring the frozen task file fails. That is
# unresolved like a marker - the check before the commit refuses it as it
# stands - so an asking round on it publishes nothing, as in V4.
dV6="$(RB_HOOKS=1 rb_fixture)"; bV6="$(rb_branch "$dV6")"
rb_replay_conflict "$dV6"
cat > "$dV6/main.sh" <<'S'
jq '.title="main retitled the task"' design/tasks/T-Z.json > n && mv n design/tasks/T-Z.json
S
rb_move_main "$dV6" "$dV6/main.sh"
oldV6="$(rb_head "$dV6" "$bV6")"; pushedV6="$(rb_pushed "$dV6")"
# Refuse only the restore's file-writing show, not fm_task's pipe read.
mkdir -p "$dV6/gitwrap"
cat > "$dV6/gitwrap/git" <<W
#!/usr/bin/env bash
if [ "\${1:-}" = show ] && [ "\${2:-}" = "$oldV6:design/tasks/T-Z.json" ] && [ -f /dev/stdout ]; then
  exit 128
fi
exec "$rb_git_real" "\$@"
W
chmod +x "$dV6/gitwrap/git"
PATH="$dV6/gitwrap:$PATH" rb_round_two "$dV6" "$dV2/ask.sh"
rb_rebuilt "$dV6" "V6"
pV6="$(cat "$dV6/prompt.md")"
assert_contains "$pV6" "Every file applied cleanly" "V6: nothing conflicts"
assert_contains "$pV6" "The rebuild could not keep your task's own entry in" \
  "V6: but the task's file is handed to the worker to put back"
assert_eq "0" "$rb_rc" "V6: an asking round on it completes"
assert_contains "$rb_out" "the worker asked rather than changed anything; its question is on #42" "V6: as asked"
assert_contains "$rb_out" "the rebuild of $bV6 was not committed" "V6: and says the rebuild is not published"
assert_eq "$oldV6" "$(rb_head "$dV6" "$bV6")" "V6: the remote branch is not touched"
assert_eq "$oldV6" "$(git -C "$dV6/repo" rev-parse "$bV6")" "V6: nor the local one"
assert_eq "$pushedV6" "$(rb_pushed "$dV6")" "V6: and no commit is reported"


cd "$ROOT" || exit 1
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
