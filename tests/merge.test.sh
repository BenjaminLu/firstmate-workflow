#!/usr/bin/env bash
# The only thing allowed to merge, and until now the only script without a
# suite of its own. It is the most privileged thing here: it is what a
# button on the board reaches, so what it refuses matters as much as what
# it does.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/lib/binding-fixture.sh"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"

fixture() {                       # <pr state> <head branch> [title] [number]
  local d; d="$(mktemp -d)"
  mkdir -p "$d/bin" "$d/state" "$d/stub"
  git init -q -b main "$d"
  git -C "$d" remote add origin https://github.com/fixture/project.git
  cp "$ROOT/bin/fm-merge.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$d/bin/"; project_storage_fixture "$d/bin/"
  cp "$ROOT/bin/lib/fm_conventions.py" "$d/bin/lib/"
  binding_service_fixture "$d"
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
  repo:view) echo fixture/project ;;
  pr:list) echo "\${DOWNSTREAM:-[]}" ;;
  pr:view)
    doc="\$(jq -c --arg n "\$3" 'select((.number|tostring)==\$n)' "$d/pr.json")"
    [ -n "\$doc" ] || { echo "GraphQL: Could not resolve to a PullRequest with the number of \$3. (repository.pullRequest)" >&2; exit 1; }
    out="\$(jq -cS --arg f "\$(arg --json "\$@")" '. as \$d | reduce (\$f|split(","))[] as \$k ({}; .[\$k] = \$d[\$k])' <<<"\$doc")"
    q="\$(arg --jq "\$@")"
    if [ -n "\$q" ]; then jq -r "\$q" <<<"\$out"; else printf '%s\n' "\$out"; fi ;;
  pr:merge)
    expected="\$(arg --match-head-commit "\$@")"
    actual="\$(jq -r .headRefOid "$d/pr.json")"
    if [ -f "$d/move-on-merge" ]; then
      actual=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      jq --arg h "\$actual" '.headRefOid=\$h' "$d/pr.json" > "$d/pr.next"
      mv "$d/pr.next" "$d/pr.json"
    fi
    [ "\$expected" = "\$actual" ] || { echo 'Head branch was modified. Review and try the merge again.' >&2; exit 1; }
    touch "$d/merged" ;;
esac
exit 0
G
  chmod +x "$d/stub/gh"
  printf '%s' "$d"
}
# pr_is <fixture> <state> <head branch> [title] [number]: what GitHub holds
# for that pull request (#9 unless named) now
pr_is() { jq -cn --arg s "$2" --arg b "$3" --arg t "${4:-a pull request}" --argjson n "${5:-9}" \
  '{number:$n,state:$s,headRefName:$b,title:$t,baseRefName:"main",headRefOid:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' > "$1/pr.json"; }
types() { jq -r '.type + " " + (.task // "-")' "$1/state/events.jsonl" 2>/dev/null | tr '\n' ' '; }

# --- what it refuses ----------------------------------------------------
d="$(fixture OPEN t-009-board)"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 'x; rm -rf /' >/dev/null 2>&1
assert_eq "64" "$?" "a pull request number that is not a number is refused"
assert_eq "" "$(cat "$d/ghcalls" 2>/dev/null)" "and nothing was asked of gh at all"

FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null 2>&1
assert_eq "64" "$?" "so is no pull request at all"
rm -rf "$d"

d="$(fixture CLOSED t-009-board)"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 >/dev/null 2>&1
assert_ne "0" "$?" "a pull request that is not open is refused"
assert_lacks "$(cat "$d/ghcalls")" "pr merge" "and no merge was attempted"
rm -rf "$d"

d="$(fixture MERGED t-009-board)"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 2>&1)"
assert_eq "0" "$?" "one already merged is not an error"
assert_contains "$out" "already merged" "and says so"
assert_lacks "$(cat "$d/ghcalls")" "pr merge" "and merges nothing twice"
rm -rf "$d"

# Retention applies to merge's remote deletion as well as cleanup's local one.
for downstream in '[{"number":22}]' 'unreadable'; do
  d="$(fixture OPEN t-009-board-server)"
  DOWNSTREAM="$downstream" FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" \
    --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 >/dev/null 2>&1
  assert_lacks "$(cat "$d/ghcalls")" "--delete-branch" "merge retains downstream base for $downstream"
  assert_ok "test -f '$d/merged'" "retention still allows the approved merge"
  rm -rf "$d"
done

# --- what it does -------------------------------------------------------
d="$(fixture OPEN t-009-board-server)"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 2>&1)"
assert_eq "0" "$?" "an open pull request merges"
assert_contains "$(grep 'pr merge 9 ' "$d/ghcalls")" "--squash" "PR #9 through gh, squashed"
# the event has to carry the task: the board keys on it, and a merged event
# without one leaves the task in whatever lane it was in - finished work
# showing as work in progress
assert_contains "$(types "$d")" "merged T-009" "the merged event names the task"
assert_contains "$out" "by its branch name" "which it read off the branch"
rm -rf "$d"

d="$(fixture OPEN t-009-board-server)"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 --task T-009 >/dev/null 2>&1
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
project_fixture_config "$1"
}
d="$(fixture OPEN t-004-app)"; registry "$d"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 --project example-app 2>&1)"
assert_eq "65" "$?" "a named project's merge requires conventions policy"
assert_eq "" "$(cat "$d/ghcalls" 2>/dev/null)" "no GitHub mutation precedes project policy"
assert_contains "$out" "CONVENTIONS.md" "refusal names missing conventions"
assert_contains "$out" "readable" "refusal explains unreadable policy"
assert_fail "test -e '$d/state/events.jsonl'" "no external merged event leaks into self state"

rm -rf "$d"

d="$(fixture OPEN t-009-board)"; registry "$d"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 --project firstmate-workflow >/dev/null 2>&1
assert_eq "0" "$?" "the default project named explicitly merges"
assert_contains "$(grep 'pr merge' "$d/ghcalls")" "--repo owner/engine" "on the engine's own repository"
rm -rf "$d"

# Cleanup knows only the engine's own worktree root: another project's T-004
# is not cleaned up here, or state/worktrees/T-004 - the engine's own T-004 -
# would go with it. The self project's merge still cleans up.
cleanup_stub() { printf '#!/usr/bin/env bash\necho "$*" >> "%s/cleanup-calls"\n' "$1" > "$1/bin/fm-cleanup.sh"
  chmod +x "$1/bin/fm-cleanup.sh"; }
d="$(fixture OPEN t-004-app)"; registry "$d"; cleanup_stub "$d"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 --project example-app 2>&1)"
assert_eq "65" "$?" "another project without policy stays held with cleanup present"
assert_fail "test -e '$d/cleanup-calls'" "and does not run the engine's cleanup for it"
assert_contains "$out" "CONVENTIONS.md" "and says so"
rm -rf "$d"
d="$(fixture OPEN t-009-board)"; registry "$d"; cleanup_stub "$d"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 --project firstmate-workflow 2>&1)"
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
  out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 --project firstmate-workflow 2>&1)"
  assert_eq "0" "$?" "a self entry written [$spelling] merges"
  assert_contains "$(cat "$d/cleanup-calls" 2>/dev/null)" "--task T-009" "and cleans up its task [$spelling]"
  rm -rf "$d"
done
d="$(fixture OPEN t-009-board)"; self_as "$d" ''; cleanup_stub "$d"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 --project firstmate-workflow 2>&1)"
assert_eq "65" "$?" "an entry with no repo requires external merge policy"
assert_eq "" "$(cat "$d/ghcalls")" "no merge is inferred from missing repo field"
assert_fail "test -e '$d/cleanup-calls'" "but is a managed clone, so the engine's cleanup is not run for it"
rm -rf "$d"
for spelling in 'repo: ./' "repo: $ROOT" 'repo: ../engine'; do
  d="$(fixture OPEN t-009-board)"; self_as "$d" "$spelling"; cleanup_stub "$d"
  FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 --project firstmate-workflow >/dev/null 2>&1
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
project_fixture_config "$d"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 --project firstmate-workflow >/dev/null 2>&1
assert_eq "65" "$?" "a self project registered with no github is refused by name"
assert_eq "" "$(cat "$d/ghcalls" 2>/dev/null)" "before gh is asked anything"
assert_fail "bash -c '. \"$d/bin/fm-config.sh\"; fm_project_resolve firstmate-workflow \"$d/config.yaml\"'" \
  "because the registry refuses the name itself, not only its github"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 >/dev/null 2>&1
assert_eq "0" "$?" "while a merge naming no project still runs in the checkout"
assert_contains "$(cat "$d/ghcalls")" "--repo fixture/project" "unnamed legacy merge explicitly names its resolved repository"
rm -rf "$d"

d="$(fixture OPEN t-009-board)"; registry "$d"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 --project nosuch-app >/dev/null 2>&1
assert_eq "65" "$?" "a project the registry does not hold exits 65"
assert_eq "" "$(cat "$d/ghcalls" 2>/dev/null)" "and nothing was asked of gh"
rm -rf "$d"

d="$(fixture OPEN t-009-board)"; registry "$d"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 >/dev/null 2>&1
assert_eq "0" "$?" "with no --project it merges as before"
assert_contains "$(cat "$d/ghcalls")" "--repo owner/engine" "unnamed self merge explicitly names its registered repository"
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
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 96 --task T-117 2>&1)"
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
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 96 --task T-105 >/dev/null 2>&1
assert_eq "0" "$?" "#96 merges on the card of its own task, T-105"
assert_contains "$(types "$d")" "merged T-105" "and writes merged for T-105"
rm -rf "$d"

# and not from an untracked card: a task's own pull request merged as
# untracked writes no task, and that task's card would never move
d="$(fixture OPEN "$R96_BRANCH" "$R96_TITLE" 96)"; cleanup_stub "$d"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 96 --untracked 2>&1)"
assert_ne "0" "$?" "#96, T-105's by its branch, is refused from an untracked card"
assert_contains "$out" "--task T-105" "and the refusal points at T-105's card"
assert_lacks "$(cat "$d/ghcalls")" "pr merge" "nothing is merged"
assert_eq "" "$(types "$d")" "and no merged event is written"
rm -rf "$d"
# the untracked card was raised while the branch named no task; by the click
# it names one
d="$(fixture OPEN "$REV_BRANCH" "$REV_TITLE" 96)"; cleanup_stub "$d"
pr_is "$d" OPEN "$R96_BRANCH" "$REV_TITLE" 96
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 96 --untracked 2>&1)"
assert_ne "0" "$?" "an untracked card is refused at merge time once the branch names a task"
assert_contains "$out" "T-105" "naming that task"
assert_lacks "$(cat "$d/ghcalls")" "pr merge" "and merging nothing"
rm -rf "$d"
# the title alone is enough to make it a task's
d="$(fixture OPEN hotfix-board "$R96_TITLE" 96)"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 96 --untracked >/dev/null 2>&1
assert_ne "0" "$?" "an untracked card is refused when the title names a task"
rm -rf "$d"
# already merged on GitHub, under an untracked card: not settled as untracked
d="$(fixture MERGED "$R96_BRANCH" "$R96_TITLE" 96)"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 96 --untracked >/dev/null 2>&1
assert_ne "0" "$?" "an already merged task's pull request does not settle an untracked card"
rm -rf "$d"

# a revert that belongs to no task, clicked on an untracked card
d="$(fixture OPEN "$REV_BRANCH" "$REV_TITLE" 96)"; cleanup_stub "$d"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 96 --untracked 2>&1)"
assert_eq "0" "$?" "a pull request of no task merges from an untracked card"
assert_contains "$(grep 'pr merge 96 ' "$d/ghcalls")" "--squash" "PR #96 through gh, squashed"
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
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 96 --untracked --project example-app 2>&1)"
assert_eq "65" "$?" "an external untracked merge awaits confirmed conventions policy"
assert_contains "$out" "CONVENTIONS.md" "untracked merges retain the external policy hold"
assert_ok "test ! -s '$d/ghcalls'" "policy hold precedes every external GitHub operation"
assert_lacks "$out" "worktree" "and says nothing of a worktree it does not have"
rm -rf "$d"
# bash 3.2 reads a CJK character after a bare $name as part of the name, so
# under set -u such a summary kills the script after GitHub has merged. The
# runner's bash 5 does not, so the rule is checked on the text itself.
assert_eq "" "$(perl -ne 'print "$ARGV:$.\n" if /\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]/; close ARGV if eof' \
  "$ROOT/bin/fm-merge.sh" "$ROOT/bin/fm-decide.sh" "$ROOT/bin/fm-emit.sh")" \
  "no bare \$name runs into a non-ASCII character in the T-119 scripts"
d="$(fixture OPEN t-009-board)"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 --task T-009 --untracked >/dev/null 2>&1
assert_eq "64" "$?" "a card is a task's or untracked, never both"
assert_eq "" "$(cat "$d/ghcalls" 2>/dev/null)" "and gh is not asked"
rm -rf "$d"

# a pull request that belongs to no task is not merged as if it did
d="$(fixture OPEN "$REV_BRANCH" "$REV_TITLE")"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 2>&1)"
assert_ne "0" "$?" "a pull request of no task is refused without an untracked card"
assert_contains "$out" "no task" "and says it belongs to no task"
assert_lacks "$(cat "$d/ghcalls")" "pr merge" "merging nothing"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 --task T-105 >/dev/null 2>&1
assert_ne "0" "$?" "nor under a task its branch and title do not name"
assert_lacks "$(cat "$d/ghcalls")" "pr merge" "still merging nothing"
rm -rf "$d"
# an already merged pull request under another task's card is refused too:
# "already merged" would settle the wrong card as merged
d="$(fixture MERGED "$R96_BRANCH" "$R96_TITLE" 96)"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 96 --task T-117 >/dev/null 2>&1
assert_ne "0" "$?" "an already merged pull request of another task is not reported merged for this one"
rm -rf "$d"
# a pull request gh cannot read is not merged on a guess
d="$(fixture OPEN t-009-board)"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 10 --task T-009 >/dev/null 2>&1
assert_ne "0" "$?" "a pull request gh cannot find is refused"
assert_lacks "$(cat "$d/ghcalls")" "pr merge" "and not merged"
rm -rf "$d"

# the branch says nothing, the title does
d="$(fixture OPEN board-fields 'T-116: the board shows each crew member')"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 --task T-116 >/dev/null 2>&1
assert_eq "0" "$?" "a branch with no task defers to the title's T-xxx: prefix"
assert_contains "$(types "$d")" "merged T-116" "and merges as the title's task"
rm -rf "$d"
# a task id is its whole number: t-1170 is not T-117
d="$(fixture OPEN t-1170-other)"
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 --task T-117 >/dev/null 2>&1
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
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 94 --task SK-001 2>&1)"
assert_eq "0" "$?" "SK-001's merge card merges #94"
assert_contains "$(types "$d")" "merged SK-001" "and writes merged for SK-001"
assert_contains "$(cleanup_calls "$d")" "--task SK-001" "and cleans up SK-001's worktree"
rm -rf "$d"
d="$(fixture OPEN sk-001-skill-update-firstmate 'SK-001: skill-update: firstmate' 94)"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 94 2>&1)"
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
# T-138: the candidate is fixed when the card is raised.
d="$(fixture OPEN t-009-board)"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 2>&1)"
assert_eq 1 "$?" "missing merge head binding refuses"
assert_contains "$out" "missing verified candidate SHA" "missing binding gives specific refusal"
assert_lacks "$(cat "$d/ghcalls" 2>/dev/null)" "pr merge" "missing binding never calls merge"
assert_fail "test -e '$d/merged'" "missing binding leaves PR unmerged"
jq '.headRefOid="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$d/pr.json" > "$d/new.json"
mv "$d/new.json" "$d/pr.json"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2>&1)"
assert_eq 1 "$?" "head moving after card refuses"
assert_contains "$out" "PR head changed or is unverifiable" "stale card gives specific refusal"
assert_lacks "$(cat "$d/ghcalls")" "pr merge" "stale card never calls merge"
assert_fail "test -e '$d/merged'" "stale card leaves PR unmerged"
pr_is "$d" OPEN t-009-board
touch "$d/move-on-merge"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2>&1)"
assert_eq 1 "$?" "head moving between read and merge refuses atomically"
assert_contains "$out" "Head branch was modified" "atomic refusal is GitHub rejection"
assert_eq 1 "$(grep -c 'pr merge' "$d/ghcalls")" "atomic refusal attempts merge exactly once"
assert_contains "$(cat "$d/ghcalls")" "--match-head-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "GitHub receives exact gated candidate"
assert_fail "test -e '$d/merged'" "atomic refusal leaves PR unmerged"
assert_lacks "$(types "$d")" merged "refusals never emit merged"
rm -rf "$d"
if command -v bun >/dev/null 2>&1; then
  d="$(fixture OPEN t-009-board)"
  python3 "$ROOT/tests/lib/merge_board_binding.py" "$ROOT" "$d"
  assert_eq 0 "$?" "board records stale, atomic and missing binding failures and forwards matching head"
  rm -rf "$d"
else
  assert_eq available missing "bun is required for merge board binding coverage"
fi
# Policy that retains branches needs no downstream query at merge time.
# shellcheck source=tests/lib/stacking.sh
. "$ROOT/tests/lib/stacking.sh"
d="$(fixture OPEN t-009-board)"
stacking_policy "$d/CONVENTIONS.md" hold
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --pr 9 2>&1)"
assert_eq 0 "$?" "retention policy permits the bound merge"
assert_contains "$(grep 'pr merge 9 ' "$d/ghcalls")" '--squash' 'retention policy still merges the intended PR'
assert_lacks "$(cat "$d/ghcalls")" 'pr list' 'retention policy makes no unnecessary downstream lookup'
assert_lacks "$(cat "$d/ghcalls")" '--delete-branch' 'retention policy never requests deletion'
rm -rf "$d"

python3 "$ROOT/tests/lib/external_adopt.py" "$ROOT" merge
assert_eq 0 "$?" 'adopted PR merge follows pinned ownership and base'
# T-220: signed tracked answers carry only through the bounded helper path.
carry_fixture() {
  d="$(fixture OPEN t-009-board)"
  git -C "$d" config user.name Fixture; git -C "$d" config user.email fixture@example.invalid
  printf base > "$d/base-file"; git -C "$d" add base-file; git -C "$d" commit -qm base
  git clone -q --bare "$d" "$d-origin"
  git -C "$d" remote set-url origin "$d-origin"
  jq '.headRefOid="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$d/pr.json" > "$d/next"
  mv "$d/next" "$d/pr.json"
  real_git="$(command -v git)"
  cat > "$d/stub/git" <<GIT
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$d/gitcalls"
exec "$real_git" "\$@"
GIT
  chmod +x "$d/stub/git"
}
carry_merge() {
  PATH="$d/stub:$PATH" FM_ROOT="$d" FM_GH="$d/stub/gh" FM_MERGE_CARRY_SECONDS="${carry_seconds:-5}" FM_MERGE_CARRY_POLL=1 \
    bash "$d/bin/fm-merge.sh" --pr 9 --task T-009 --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --bound-signature cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
}
carry_fixture
printf '%s\n' '{"head":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' > "$d/.fixture-carry"
out="$(carry_merge 2>&1)"; assert_eq 0 "$?" 'carried head merges'
assert_contains "$(cat "$d/ghcalls")" '--match-head-commit bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' 'merge uses carried head'
assert_eq aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$(jq -r 'select(.type=="merged")|.data.carried_from' "$d/state/events.jsonl")" 'event names original head'
assert_eq bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$(jq -r 'select(.type=="merged")|.data.head' "$d/state/events.jsonl")" 'event names merged head'
assert_contains "$(jq -r 'select(.type=="merged")|.summary["zh-TW"]' "$d/state/events.jsonl")" '答案沿用' 'carried event authored in both locales'
rm -rf "$d" "$d-origin"
for mode in wait refuse; do
  carry_fixture; carry_seconds=2
  printf 'fixture readiness %s\n' "$mode" > "$d/.fixture-carry-$mode"
  started="$(date +%s)"; out="$(carry_merge 2>&1)"; status=$?
  assert_eq 1 "$status" "carry $mode refuses"
  if [ "$mode" = wait ]; then
    assert_contains "$out" waited 'wait deadline en'; assert_contains "$out" 已等待 'wait deadline tw'
  else
    assert_contains "$out" 'cannot carry' 'lasting refusal en'; assert_contains "$out" 無法沿用 'lasting refusal tw'
    assert_ok "test $(( $(date +%s) - started )) -lt 2" 'lasting refusal does not consume deadline'
  fi
  assert_lacks "$(cat "$d/ghcalls")" 'pr merge' 'refusal merges nothing'
  rm -rf "$d" "$d-origin"
done
# Unknown state is unreadable throughout the carry helper, never terminal.
for remote_state in UNKNOWN 7; do
  carry_fixture; carry_seconds=0
  jq --arg state "$remote_state" '.state=$state' "$d/pr.json" > "$d/next"
  mv "$d/next" "$d/pr.json"
  out="$(carry_merge 2>&1)"; assert_eq 1 "$?" 'unreadable state reaches bounded deadline'
  assert_contains "$out" waited 'unknown state waits rather than permanently refusing'
  assert_lacks "$(cat "$d/gitcalls" 2>/dev/null)" fetch 'unknown state authorizes no sync'
  assert_lacks "$(cat "$d/ghcalls")" 'pr merge' 'unknown state authorizes no merge'
  rm -rf "$d" "$d-origin"
done
carry_seconds=5
carry_fixture
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --task T-009 --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2>&1)"
assert_eq 1 "$?" 'unsigned moved head still refuses'; assert_contains "$out" 'PR head changed' 'unsigned route unchanged'
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --bound-signature cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc 2>&1)"
assert_eq 1 "$?" 'signature without explicit task keeps old moved-head refusal'
assert_contains "$out" 'PR head changed' 'no-task signature does not enter carry'
out="$(FM_ROOT="$d" bash "$d/bin/fm-merge.sh" --pr 9 --bound-signature fixture 2>&1)"
assert_eq 64 "$?" 'invalid signature shape refused'
out="$(FM_ROOT="$d" bash "$d/bin/fm-merge.sh" --pr 9 --bound-signature '' 2>&1)"
assert_eq 64 "$?" 'explicit empty signature is invalid'
rm -rf "$d" "$d-origin"
carry_fixture
jq '.baseRefName="t-008-parent"' "$d/pr.json" > "$d/next"; mv "$d/next" "$d/pr.json"
before="$(git -C "$d" rev-parse main)"
out="$(carry_merge 2>&1)"; assert_eq 1 "$?" 'stacked signed card refuses immediately'
assert_contains "$out" 'stacked on t-008-parent' 'stacked reason en'; assert_contains "$out" '疊在 t-008-parent' 'stacked reason tw'
assert_fail "test -e '$d/.fixture-carry-calls'" 'stacked card never evaluates carry'
assert_lacks "$(cat "$d/gitcalls" 2>/dev/null)" fetch 'stacked card never fetches'
assert_eq "$before" "$(git -C "$d" rev-parse main)" 'stacked card never synchronizes base'
rm -rf "$d" "$d-origin"
carry_fixture
jq '.state="MERGED"|.headRefName="t-010-other"' "$d/pr.json" > "$d/next"; mv "$d/next" "$d/pr.json"
out="$(carry_merge 2>&1)"; assert_eq 1 "$?" 'merged wrong-task card refuses'
assert_contains "$out" "not T-009's" 'ownership precedes merged state'; assert_lacks "$out" 'already merged' 'wrong card cannot settle as merged'
rm -rf "$d" "$d-origin"
# Ownership is re-read during the wait, before MERGED can settle another task.
carry_fixture
printf 'waiting for readiness\n' > "$d/.fixture-carry-wait"
python3 "$ROOT/tests/lib/carry_ownership.py" "$ROOT" "$d"
assert_eq 0 "$?" 'during-wait MERGED still checks ownership first'
rm -rf "$d" "$d-origin"
carry_fixture
printf 'transient precheck read\n' > "$d/.fixture-precheck-wait"
carry_seconds=2
out="$(carry_merge 2>&1)"; assert_eq 1 "$?" 'unreadable precheck waits to deadline'
assert_contains "$out" 'transient precheck read' 'precheck wait reason retained'
assert_lacks "$(cat "$d/gitcalls" 2>/dev/null)" fetch 'precheck wait performs no synchronization'
assert_lacks "$(cat "$d/.fixture-carry-calls")" full 'precheck wait grants no full acceptance'
rm -rf "$d" "$d-origin"
carry_seconds=5
# Lasting precheck refusals must win over divergent AND dirty base sync75.
for local_state in divergent dirty; do
  for reason in 'evidence store failed verification: forged or modified local evidence record' 'no current local approval' 'external review policy: a review identity is bound to its head'; do
    carry_fixture
    old="$(git -C "$d" rev-parse main)"
    git clone -q "$d-origin" "$d-writer"
    git -C "$d-writer" config user.name Fixture; git -C "$d-writer" config user.email fixture@example.invalid
    printf remote > "$d-writer/base-file"; git -C "$d-writer" commit -qam advance
    git -C "$d-writer" push -q origin main
    if [ "$local_state" = divergent ]; then
      printf own > "$d/own"; git -C "$d" add own; git -C "$d" commit -qm own
    else
      printf dirty > "$d/base-file"
    fi
    before="$(git -C "$d" rev-parse main)"
    printf '%s\n' "$reason" > "$d/.fixture-precheck-refuse"
    started="$(date +%s)"; out="$(carry_merge 2>&1)"; assert_eq 1 "$?" 'lasting precheck wins'
    assert_contains "$out" "$reason" 'lasting reason preserved'
    assert_ok "test $(( $(date +%s) - started )) -lt 5" 'lasting refusal prompt'
    assert_eq "$before" "$(git -C "$d" rev-parse main)" 'lasting refusal writes no base'
    assert_lacks "$(cat "$d/.fixture-carry-calls")" full 'lasting precheck prevents full carry'
    assert_lacks "$(cat "$d/gitcalls" 2>/dev/null)" fetch 'lasting precheck performs no synchronization'
    assert_lacks "$(cat "$d/ghcalls")" 'pr merge' 'lasting precheck prevents merge'
    rm -rf "$d" "$d-origin" "$d-writer"
  done
done
# A valid precheck plus sync75 waits; a full carry wait still synchronizes main.
for mode in divergent advance; do
  carry_fixture; carry_seconds=2
  old="$(git -C "$d" rev-parse main)"
  git clone -q "$d-origin" "$d-writer"
  git -C "$d-writer" config user.name Fixture; git -C "$d-writer" config user.email fixture@example.invalid
  printf live > "$d-writer/live"; git -C "$d-writer" add live; git -C "$d-writer" commit -qm advance
  git -C "$d-writer" push -q origin main
  live="$(git -C "$d-writer" rev-parse main)"
  if [ "$mode" = divergent ]; then
    printf own > "$d/own"; git -C "$d" add own; git -C "$d" commit -qm own
    old="$(git -C "$d" rev-parse main)"
  fi
  printf 'no signed six-gate readiness for candidate\n' > "$d/.fixture-carry-wait"
  out="$(carry_merge 2>&1)"; assert_eq 1 "$?" 'sync/wait deadline refuses'
  assert_contains "$out" waited 'deadline message retained'
  if [ "$mode" = divergent ]; then
    assert_contains "$out" 'cannot be fast-forwarded' 'sync reason survives deadline'
    assert_eq "$old" "$(git -C "$d" rev-parse main)" 'divergent base untouched'
    assert_lacks "$(cat "$d/.fixture-carry-calls")" full 'sync75 prevents full carry'
  else
    assert_eq "$live" "$(git -C "$d" rev-parse main)" 'sync advances before readiness arrives'
    assert_contains "$(cat "$d/.fixture-carry-calls")" full 'full carry only follows successful sync'
  fi
  rm -rf "$d" "$d-origin" "$d-writer"
done
carry_seconds=5
# Valid shape alone never changes untracked routing.
d="$(fixture OPEN hotfix 'hotfix')"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --untracked --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --bound-signature cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc 2>&1)"
assert_eq 0 "$?" 'signed-shape untracked card keeps existing route'
assert_fail "test -e '$d/.fixture-carry-calls'" 'untracked never calls carry'
rm -rf "$d"
python3 "$ROOT/tests/lib/carry_code.py" "$ROOT"
assert_eq 0 "$?" "carry freezes executable binding, adoption, emission and final cleanup with real project storage"
finish
