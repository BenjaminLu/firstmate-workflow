#!/usr/bin/env bash
# The only thing allowed to merge, and until now the only script without a
# suite of its own. It is the most privileged thing here: it is what a
# button on the board reaches, so what it refuses matters as much as what
# it does.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

fixture() {                       # <pr state> <head branch>
  local d; d="$(mktemp -d)"
  mkdir -p "$d/bin" "$d/state" "$d/stub"
  cp "$ROOT/bin/fm-merge.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$d/bin/"
  printf 'vendor: mock\n' > "$d/config.yaml"
  cat > "$d/stub/gh" <<G
#!/usr/bin/env bash
echo "gh \$*" >> "$d/ghcalls"
case " \$* " in
  *" state "*)       echo "$1" ;;
  *" headRefName "*) echo "$2" ;;
esac
exit 0
G
  chmod +x "$d/stub/gh"
  printf '%s' "$d"
}
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
FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 --task T-042 >/dev/null 2>&1
assert_contains "$(types "$d")" "merged T-042" "an explicit task wins over the branch"
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

d="$(fixture OPEN some-branch-with-no-task)"
out="$(FM_ROOT="$d" FM_GH="$d/stub/gh" bash "$d/bin/fm-merge.sh" --pr 9 2>&1)"
assert_eq "0" "$?" "a branch with no task in its name still merges"
assert_contains "$(types "$d")" "merged -" "and the event simply has no task"
rm -rf "$d"
finish
