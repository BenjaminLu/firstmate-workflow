#!/usr/bin/env bash
# The only thing allowed to merge, and until now the only script without a
# suite of its own. It is the most privileged thing here: it is what a
# button on the board reaches, so what it refuses matters as much as what
# it does.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

fixture() {                       # <pr state> <head branch> [title] [number]
  local d; d="$(mktemp -d)"
  mkdir -p "$d/bin" "$d/state" "$d/stub"
  cp "$ROOT/bin/fm-merge.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$d/bin/"
  printf 'vendor: mock\n' > "$d/config.yaml"
  pr_is "$d" "$1" "$2" "${3-}" "${4-}"
  # Answers as gh does. `gh pr view <n> --json a,b` prints an object of
  # exactly those fields, keys sorted (Go's encoding of a map); `--jq` applies
  # the filter to it and prints raw strings. A number with no pull request
  # behind it is GraphQL's error on stderr and exit 1, nothing on stdout.
  # `gh pr merge` prints nothing on stdout when it is not a terminal.
  cat > "$d/stub/gh" <<G
#!/usr/bin/env bash
echo "gh \$*" >> "$d/ghcalls"
arg() { local w="\$1"; shift; while [ \$# -gt 0 ]; do [ "\$1" = "\$w" ] && { printf '%s' "\${2-}"; return; }; shift; done; }
case "\${1-}:\${2-}" in
  pr:view)
    doc="\$(jq -c --arg n "\$3" 'select((.number|tostring)==\$n)' "$d/pr.json")"
    [ -n "\$doc" ] || { echo "GraphQL: Could not resolve to a PullRequest with the number of \$3. (repository.pullRequest)" >&2; exit 1; }
    out="\$(jq -cS --arg f "\$(arg --json "\$@")" '. as \$d | reduce (\$f|split(","))[] as \$k ({}; .[\$k] = \$d[\$k])' <<<"\$doc")"
    q="\$(arg --jq "\$@")"
    if [ -n "\$q" ]; then jq -r "\$q" <<<"\$out"; else printf '%s\n' "\$out"; fi ;;
  pr:merge) : ;;
esac
exit 0
G
  chmod +x "$d/stub/gh"
  printf '%s' "$d"
}
# pr_is <fixture> <state> <head branch> [title] [number]: what GitHub holds
# for that pull request (#9 unless named) now
pr_is() { jq -cn --arg s "$2" --arg b "$3" --arg t "${4:-a pull request}" --argjson n "${5:-9}" \
  '{number:$n,state:$s,headRefName:$b,title:$t}' > "$1/pr.json"; }
types() { jq -r '.type + " " + (.task // "-")' "$1/state/events.jsonl" 2>/dev/null | tr '\n' ' '; }

# --- what it refuses ----------------------------------------------------
d="$(fixture OPEN t-009-board)"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 'x; rm -rf /' >/dev/null 2>&1
assert_eq "64" "$?" "a pull request number that is not a number is refused"
assert_eq "" "$(cat "$d/ghcalls" 2>/dev/null)" "and nothing was asked of gh at all"

FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" >/dev/null 2>&1
assert_eq "64" "$?" "so is no pull request at all"
rm -rf "$d"

d="$(fixture CLOSED t-009-board)"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 >/dev/null 2>&1
assert_ne "0" "$?" "a pull request that is not open is refused"
assert_lacks "$(cat "$d/ghcalls")" "pr merge" "and no merge was attempted"
rm -rf "$d"

d="$(fixture MERGED t-009-board)"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 2>&1)"
assert_eq "0" "$?" "one already merged is not an error"
assert_contains "$out" "already merged" "and says so"
assert_lacks "$(cat "$d/ghcalls")" "pr merge" "and merges nothing twice"
rm -rf "$d"

# --- what it does -------------------------------------------------------
d="$(fixture OPEN t-009-board-server)"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 2>&1)"
assert_eq "0" "$?" "an open pull request merges"
assert_contains "$(cat "$d/ghcalls")" "pr merge 9 --squash" "through gh, squashed"
# the event has to carry the task: the board keys on it, and a merged event
# without one leaves the task in whatever lane it was in - finished work
# showing as work in progress
assert_contains "$(types "$d")" "merged T-009" "the merged event names the task"
assert_contains "$out" "by its branch name" "which it read off the branch"
rm -rf "$d"

d="$(fixture OPEN t-009-board-server)"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --task T-009 >/dev/null 2>&1
assert_contains "$(types "$d")" "merged T-009" "a task named by the card and the branch alike merges as that task"
rm -rf "$d"

# --- T-047: the project's own repository ---------------------------------
registry() { cat >> "$1/config.yaml" <<'Y'
default_project: firstmate-workflow
projects:
  firstmate-workflow:
    repo: .
    github: owner/engine
    base: main
    required_check: ci
  example-app:
    github: example-org/example-app
    base: main
    required_check: check
Y
}
d="$(fixture OPEN t-004-app)"; registry "$d"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --project example-app 2>&1)"
assert_eq "0" "$?" "a named project's pull request merges"
assert_contains "$(grep 'pr merge' "$d/ghcalls")" "--repo example-org/example-app" \
  "on that project's repository"
assert_contains "$(grep 'pr view' "$d/ghcalls" | head -1)" "--repo example-org/example-app" \
  "and its state is read there too, not from the engine checkout"
assert_eq "example-app" "$(jq -r 'select(.type=="merged")|.project' "$d/state/events.jsonl")" \
  "the merged event carries the project"
assert_eq "T-004" "$(jq -r 'select(.type=="merged")|.task' "$d/state/events.jsonl")" "and the task"
rm -rf "$d"

d="$(fixture OPEN t-009-board)"; registry "$d"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --project firstmate-workflow >/dev/null 2>&1
assert_eq "0" "$?" "the default project named explicitly merges"
assert_contains "$(grep 'pr merge' "$d/ghcalls")" "--repo owner/engine" "on the engine's own repository"
rm -rf "$d"

# Cleanup knows only the engine's own worktree root: another project's T-004
# is not cleaned up here, or state/worktrees/T-004 - the engine's own T-004 -
# would go with it. The self project's merge still cleans up.
cleanup_stub() { printf '#!/usr/bin/env bash\necho "$*" >> "%s/cleanup-calls"\n' "$1" > "$1/bin/fm-cleanup.sh"
  chmod +x "$1/bin/fm-cleanup.sh"; }
d="$(fixture OPEN t-004-app)"; registry "$d"; cleanup_stub "$d"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --project example-app 2>&1)"
assert_eq "0" "$?" "another project's merge with a cleanup script present still merges"
assert_fail "test -e '$d/cleanup-calls'" "and does not run the engine's cleanup for it"
assert_contains "$out" "T-004's worktree in example-app is not cleaned up here" "and says so"
rm -rf "$d"
d="$(fixture OPEN t-009-board)"; registry "$d"; cleanup_stub "$d"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --project firstmate-workflow 2>&1)"
assert_contains "$(cat "$d/cleanup-calls" 2>/dev/null)" "--task T-009" "the self project's merge cleans up its task"
assert_lacks "$out" "not cleaned up here" "without saying otherwise"
rm -rf "$d"

# The self entry as the registry lets it be written (T-046): `repo` is `.`,
# however it is quoted or commented, and that alone is the engine. An entry
# with no repo is a managed clone, never the engine; any other repo is
# refused before gh is asked anything.
self_as() {   # self_as <dir> <repo line or empty>
  { printf 'default_project: firstmate-workflow\nprojects:\n  firstmate-workflow:\n'
    [ -z "$2" ] || printf '    %s\n' "$2"
    printf '    github: owner/engine\n    base: main\n    required_check: ci\n'
  } >> "$1/config.yaml"
}
for spelling in 'repo: .' 'repo: "."' "repo: '.'" 'repo: .   # the engine itself'; do
  d="$(fixture OPEN t-009-board)"; self_as "$d" "$spelling"; cleanup_stub "$d"
  out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --project firstmate-workflow 2>&1)"
  assert_eq "0" "$?" "a self entry written [$spelling] merges"
  assert_contains "$(cat "$d/cleanup-calls" 2>/dev/null)" "--task T-009" "and cleans up its task [$spelling]"
  rm -rf "$d"
done
d="$(fixture OPEN t-009-board)"; self_as "$d" ''; cleanup_stub "$d"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --project firstmate-workflow 2>&1)"
assert_eq "0" "$?" "an entry with no repo merges on its own repository"
assert_contains "$(grep 'pr merge' "$d/ghcalls")" "--repo owner/engine" "named by its github"
assert_fail "test -e '$d/cleanup-calls'" "but is a managed clone, so the engine's cleanup is not run for it"
rm -rf "$d"
for spelling in 'repo: ./' "repo: $ROOT" 'repo: ../engine'; do
  d="$(fixture OPEN t-009-board)"; self_as "$d" "$spelling"; cleanup_stub "$d"
  FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --project firstmate-workflow >/dev/null 2>&1
  assert_eq "65" "$?" "a repo written [$spelling] is refused"
  assert_eq "" "$(cat "$d/ghcalls" 2>/dev/null)" "before gh is asked anything [$spelling]"
  assert_fail "test -e '$d/cleanup-calls'" "and nothing is cleaned up [$spelling]"
  rm -rf "$d"
done

# Every registered project has a github: an entry without one makes the
# registry refuse every lookup (T-046), the self project's included. So a
# merge naming the self project can never find it registered but with no
# repository to merge on; it is refused before gh is asked anything, and a
# merge naming no project still runs in the checkout as before.
d="$(fixture OPEN t-009-board)"
cat >> "$d/config.yaml" <<'Y'
default_project: firstmate-workflow
projects:
  firstmate-workflow:
    repo: .
    base: main
    required_check: ci
Y
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --project firstmate-workflow >/dev/null 2>&1
assert_eq "65" "$?" "a self project registered with no github is refused by name"
assert_eq "" "$(cat "$d/ghcalls" 2>/dev/null)" "before gh is asked anything"
assert_fail "bash -c '. \"$d/bin/fm-config.sh\"; fm_project_resolve firstmate-workflow \"$d/config.yaml\"'" \
  "because the registry refuses the name itself, not only its github"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 >/dev/null 2>&1
assert_eq "0" "$?" "while a merge naming no project still runs in the checkout"
assert_lacks "$(cat "$d/ghcalls")" "--repo" "with no repository named"
rm -rf "$d"

d="$(fixture OPEN t-009-board)"; registry "$d"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --project nosuch-app >/dev/null 2>&1
assert_eq "65" "$?" "a project the registry does not hold exits 65"
assert_eq "" "$(cat "$d/ghcalls" 2>/dev/null)" "and nothing was asked of gh"
rm -rf "$d"

d="$(fixture OPEN t-009-board)"; registry "$d"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 >/dev/null 2>&1
assert_eq "0" "$?" "with no --project it merges as before"
assert_lacks "$(cat "$d/ghcalls")" "--repo" "naming no repository, as before"
assert_eq "false" "$(jq -c 'select(.type=="merged")|has("project")' "$d/state/events.jsonl")" \
  "and its event carries no project, as before"
rm -rf "$d"

# --- T-119: a merge card merges only the pull request of its own task ------
# The sequence of 2026-09-26: a card for #96 raised under T-117, clicked, and
# fm-merge wrote `merged` for T-117 although #96 was T-105's revert. #96's
# branch and title as GitHub holds them, recorded on 2026-09-26:
#   $ gh api repos/BenjaminLu/firstmate-workflow/pulls/96 \
#       --jq '{number: .number, head: .head.ref, title: .title}'
#   head: t-105-revert
#   number: 96
#   title: "T-105: revert the crew sandbox, which locks every vendor out on macOS"
# (main's squash commit fe396a5 carries git's revert subject, not this title.)
# By the grammar, then, #96 is T-105's pull request.
R96_BRANCH='t-105-revert'
R96_TITLE='T-105: revert the crew sandbox, which locks every vendor out on macOS'
# A revert that belongs to no task. NOT recorded: it is the pull request
# GitHub's Revert button would have opened for #90, built from two recorded
# values - the title is fe396a5's subject without " (#96)", and the branch is
# the button's revert-<n>-<head> around #90's head as recorded:
#   $ gh api repos/BenjaminLu/firstmate-workflow/pulls/90 --jq '{head: .head.ref}'
#   head: t-105-every-crew-round-runs-under
REV_BRANCH='revert-90-t-105-every-crew-round-runs-under'
REV_TITLE="Revert \"T-105: every crew round runs under one fm-owned permission policy, enforced by the vendor's own flags and an OS sandbox, for every vendor (#90)\""
cleanup_calls() { cat "$1/cleanup-calls" 2>/dev/null; }

# the card was raised while #96 looked like T-117's; by the click it is not
d="$(fixture OPEN t-117-t-105-again-every-crew-round 'T-117: T-105 again' 96)"; cleanup_stub "$d"
pr_is "$d" OPEN "$R96_BRANCH" "$R96_TITLE" 96
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 96 --task T-117 2>&1)"
rc=$?
assert_ne "0" "$rc" "#96 is refused at merge time under T-117's card, its branch now T-105's"
assert_contains "$out" "T-105" "the refusal names the task the pull request belongs to"
assert_contains "$out" "T-117" "and the card's task"
assert_lacks "$(cat "$d/ghcalls")" "pr merge" "nothing is merged"
assert_eq "" "$(types "$d")" "and no merged event is written, for T-117 or anyone"
assert_eq "" "$(cleanup_calls "$d")" "and T-117's worktree is left alone"
rm -rf "$d"

# the same pull request is T-105's, so it merges on T-105's card
d="$(fixture OPEN "$R96_BRANCH" "$R96_TITLE" 96)"; cleanup_stub "$d"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 96 --task T-105 >/dev/null 2>&1
assert_eq "0" "$?" "#96 merges on the card of its own task, T-105"
assert_contains "$(types "$d")" "merged T-105" "and writes merged for T-105"
rm -rf "$d"

# and not from an untracked card: a task's own pull request merged as
# untracked writes no task, and that task's card would never move
d="$(fixture OPEN "$R96_BRANCH" "$R96_TITLE" 96)"; cleanup_stub "$d"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 96 --untracked 2>&1)"
assert_ne "0" "$?" "#96, T-105's by its branch, is refused from an untracked card"
assert_contains "$out" "--task T-105" "and the refusal points at T-105's card"
assert_lacks "$(cat "$d/ghcalls")" "pr merge" "nothing is merged"
assert_eq "" "$(types "$d")" "and no merged event is written"
rm -rf "$d"
# the untracked card was raised while the branch named no task; by the click
# it names one
d="$(fixture OPEN "$REV_BRANCH" "$REV_TITLE" 96)"; cleanup_stub "$d"
pr_is "$d" OPEN "$R96_BRANCH" "$REV_TITLE" 96
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 96 --untracked 2>&1)"
assert_ne "0" "$?" "an untracked card is refused at merge time once the branch names a task"
assert_contains "$out" "T-105" "naming that task"
assert_lacks "$(cat "$d/ghcalls")" "pr merge" "and merging nothing"
rm -rf "$d"
# the title alone is enough to make it a task's
d="$(fixture OPEN hotfix-board "$R96_TITLE" 96)"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 96 --untracked >/dev/null 2>&1
assert_ne "0" "$?" "an untracked card is refused when the title names a task"
rm -rf "$d"
# already merged on GitHub, under an untracked card: not settled as untracked
d="$(fixture MERGED "$R96_BRANCH" "$R96_TITLE" 96)"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 96 --untracked >/dev/null 2>&1
assert_ne "0" "$?" "an already merged task's pull request does not settle an untracked card"
rm -rf "$d"

# a revert that belongs to no task, clicked on an untracked card
d="$(fixture OPEN "$REV_BRANCH" "$REV_TITLE" 96)"; cleanup_stub "$d"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 96 --untracked 2>&1)"
assert_eq "0" "$?" "a pull request of no task merges from an untracked card"
assert_contains "$(cat "$d/ghcalls")" "pr merge 96 --squash" "through gh, squashed"
assert_eq "merged -" "$(types "$d" | sed 's/ $//')" "its merged event names no task"
assert_eq "true" "$(jq -r 'select(.type=="merged")|.data.untracked' "$d/state/events.jsonl")" \
  "and says it belongs to no task"
assert_eq "從看板合併 #96（不屬於任何任務）" \
  "$(jq -r 'select(.type=="merged")|.summary."zh-TW"' "$d/state/events.jsonl")" \
  "with its zh-TW summary naming the pull request"
assert_eq "" "$(cleanup_calls "$d")" "and no task's worktree is cleaned up"
rm -rf "$d"
# on another project it has no task whose worktree to speak of either
d="$(fixture OPEN "$REV_BRANCH" "$REV_TITLE" 96)"; registry "$d"; cleanup_stub "$d"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 96 --untracked --project example-app 2>&1)"
assert_eq "0" "$?" "an untracked merge on another project merges"
assert_lacks "$out" "worktree" "and says nothing of a worktree it does not have"
rm -rf "$d"
# bash 3.2 reads a CJK character after a bare $name as part of the name, so
# under set -u such a summary kills the script after GitHub has merged. The
# runner's bash 5 does not, so the rule is checked on the text itself.
assert_eq "" "$(perl -ne 'print "$ARGV:$.\n" if /\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]/; close ARGV if eof' \
  "$ROOT/bin/fm-merge.sh" "$ROOT/bin/fm-decide.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-sync-prs.sh")" \
  "no bare \$name runs into a non-ASCII character in the T-119 scripts"
d="$(fixture OPEN t-009-board)"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --task T-009 --untracked >/dev/null 2>&1
assert_eq "64" "$?" "a card is a task's or untracked, never both"
assert_eq "" "$(cat "$d/ghcalls" 2>/dev/null)" "and gh is not asked"
rm -rf "$d"

# a pull request that belongs to no task is not merged as if it did
d="$(fixture OPEN "$REV_BRANCH" "$REV_TITLE")"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 2>&1)"
assert_ne "0" "$?" "a pull request of no task is refused without an untracked card"
assert_contains "$out" "no task" "and says it belongs to no task"
assert_lacks "$(cat "$d/ghcalls")" "pr merge" "merging nothing"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --task T-105 >/dev/null 2>&1
assert_ne "0" "$?" "nor under a task its branch and title do not name"
assert_lacks "$(cat "$d/ghcalls")" "pr merge" "still merging nothing"
rm -rf "$d"
# an already merged pull request under another task's card is refused too:
# "already merged" would settle the wrong card as merged
d="$(fixture MERGED "$R96_BRANCH" "$R96_TITLE" 96)"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 96 --task T-117 >/dev/null 2>&1
assert_ne "0" "$?" "an already merged pull request of another task is not reported merged for this one"
rm -rf "$d"
# a pull request gh cannot read is not merged on a guess
d="$(fixture OPEN t-009-board)"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 10 --task T-009 >/dev/null 2>&1
assert_ne "0" "$?" "a pull request gh cannot find is refused"
assert_lacks "$(cat "$d/ghcalls")" "pr merge" "and not merged"
rm -rf "$d"

# the branch says nothing, the title does
d="$(fixture OPEN board-fields 'T-116: the board shows each crew member')"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --task T-116 >/dev/null 2>&1
assert_eq "0" "$?" "a branch with no task defers to the title's T-xxx: prefix"
assert_contains "$(types "$d")" "merged T-116" "and merges as the title's task"
rm -rf "$d"
# a task id is its whole number: t-1170 is not T-117
d="$(fixture OPEN t-1170-other)"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --task T-117 >/dev/null 2>&1
assert_ne "0" "$?" "t-1170-… is T-1170's branch, not T-117's"
rm -rf "$d"

# --- T-119: a skill update merges through the board like any task --------
# SK-001 (#94) as GitHub holds it, recorded on 2026-09-26:
#   $ gh api repos/BenjaminLu/firstmate-workflow/pulls/94 \
#       --jq '{number: .number, head: .head.ref, title: .title}'
#   head: sk-001-skill-update-firstmate
#   number: 94
#   title: "SK-001: skill-update: firstmate"
d="$(fixture OPEN sk-001-skill-update-firstmate 'SK-001: skill-update: firstmate' 94)"; cleanup_stub "$d"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 94 --task SK-001 2>&1)"
assert_eq "0" "$?" "SK-001's merge card merges #94"
assert_contains "$(types "$d")" "merged SK-001" "and writes merged for SK-001"
assert_contains "$(cleanup_calls "$d")" "--task SK-001" "and cleans up SK-001's worktree"
rm -rf "$d"
d="$(fixture OPEN sk-001-skill-update-firstmate 'SK-001: skill-update: firstmate' 94)"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 94 2>&1)"
assert_contains "$(types "$d")" "merged SK-001" "with no --task, SK-001 is read off its branch"
assert_contains "$out" "by its branch name" "and says so"
rm -rf "$d"

# --- T-119: fm-emit keeps a merged event's task a task -------------------
# A branch name or a title is never a merged event's task. Any other name
# passes: the suites' fixture tasks (A, C, T-1) are not task ids either.
d="$(fixture OPEN t-009-board)"
em() { FM_ROOT="$d" bash "$d/bin/fm-emit.sh" --actor captain --type merged --pr 9 "$@" 2>&1; }
out="$(em --task t-117-t-105-again)"
assert_ne "" "$out" "fm-emit refuses a merged event whose task is a branch name"
assert_contains "$out" "T-117" "naming the task the branch holds"
em --task 'T-117: T-105 again' >/dev/null
assert_ne "0" "$?" "and one whose task is a pull request title"
em --task T-117 --data '{"untracked":true}' >/dev/null
assert_ne "0" "$?" "and an untracked merged event that names a task"
assert_eq "" "$(types "$d")" "writing none of them"
em --task T-117 >/dev/null;  assert_eq "0" "$?" "a task id passes"
em --task SK-001 >/dev/null; assert_eq "0" "$?" "an SK task id passes"
em --task C >/dev/null;      assert_eq "0" "$?" "a fixture's name that holds no task id passes"
em --data '{"untracked":true}' >/dev/null
assert_eq "0" "$?" "an untracked merged event with no task passes"
assert_eq "merged T-117 merged SK-001 merged C merged -" "$(types "$d" | sed 's/ $//')" \
  "and each of those is written"
rm -rf "$d"
finish
