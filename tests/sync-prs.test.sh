#!/usr/bin/env bash
# The captain merging in a browser has to reach the system by the system
# looking. Driven from recorded gh output, so the suite makes no network call.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

fixture() {
  local d; d="$(mktemp -d)"; mkdir -p "$d/bin" "$d/state"
  cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-sync-prs.sh" "$d/bin/"
  printf '%s' "$d"
}
# a gh that replays a recorded payload; one directory per recording
rec() { local dir="$1/gh-$2"; mkdir -p "$dir"
  { printf '#!/usr/bin/env bash\ncat <<'\''JSON'\''\n'; cat; printf 'JSON\n'; } > "$dir/gh"
  chmod +x "$dir/gh"; printf '%s' "$dir/gh"; }

d="$(fixture)"
MERGED="$(rec "$d" merged <<'J'
[{"number":8,"state":"MERGED","title":"T-005: the worker","headRefName":"t-005-worker","mergedAt":"2026-09-20T16:00:00Z"},
 {"number":9,"state":"OPEN","title":"T-006: the reviewer","headRefName":"t-006-review","mergedAt":null}]
J
)"
out="$(FM_ROOT="$d" FM_GH="$MERGED" "$d/bin/fm-sync-prs.sh" --repo "$d" 2>&1)"
assert_eq "0" "$?" "a sync exits 0"
assert_contains "$out" "merged #8" "it noticed the merge nobody told it about"
assert_contains "$out" "pr_opened #9" "and the open pull request"

log="$d/state/events.jsonl"
assert_eq "merged" "$(jq -r 'select(.pr==8)|.type' "$log")" "the merge is in the log"
assert_eq "T-005" "$(jq -r 'select(.pr==8)|.task' "$log")" "the task is derived from the branch name"
assert_eq "github" "$(jq -r 'select(.pr==8)|.actor' "$log")" "attributed to github, not to a person"
assert_ok "jq -e 'select(.pr==8)|.summary[\"zh-TW\"]' '$log' >/dev/null" "it carries both languages"

before="$(wc -l < "$log" | tr -d ' ')"
FM_ROOT="$d" FM_GH="$MERGED" "$d/bin/fm-sync-prs.sh" --repo "$d" >/dev/null 2>&1
assert_eq "$before" "$(wc -l < "$log" | tr -d ' ')" "running it twice writes nothing new"

# the same pull request moving on is a new event, not a duplicate
NOW="$(rec "$d" later <<'J'
[{"number":9,"state":"MERGED","title":"T-006: the reviewer","headRefName":"t-006-review","mergedAt":"2026-09-20T17:00:00Z"}]
J
)"
FM_ROOT="$d" FM_GH="$NOW" "$d/bin/fm-sync-prs.sh" --repo "$d" >/dev/null 2>&1
assert_eq "merged" "$(jq -r 'select(.pr==9 and .type=="merged")|.type' "$log")" "a pull request that later merges is recorded"

# failure must not poison the log
d2="$(fixture)"
BROKEN="$(mkdir -p "$d2/ghx" && printf '#!/usr/bin/env bash\nexit 1\n' > "$d2/ghx/gh" && chmod +x "$d2/ghx/gh" && printf '%s' "$d2/ghx/gh")"
assert_fail "FM_ROOT='$d2' FM_GH='$BROKEN' '$d2/bin/fm-sync-prs.sh' --repo '$d2'" "it exits non-zero when gh fails"
assert_fail "test -s '$d2/state/events.jsonl'" "and writes nothing"

d3="$(fixture)"
JUNK="$(rec "$d3" junk <<'J'
not json at all
J
)"
assert_fail "FM_ROOT='$d3' FM_GH='$JUNK' '$d3/bin/fm-sync-prs.sh' --repo '$d3'" "it rejects an unexpected response"
assert_fail "test -s '$d3/state/events.jsonl'" "and writes nothing then either"

# --- T-047: every registered project's repository, keyed (project, pr) ---
# Both projects have a pull request #7, for a task both call T-004. Each is
# read from its own repository and written with its own project, and one
# project's #7 never counts as the other's.
d4="$(fixture)"
cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$d4/bin/"
cat > "$d4/config.yaml" <<'Y'
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
mkdir -p "$d4/ghp"
# answers like gh: `pr list --repo <owner/repo>` lists that repository's pull
# requests; a call without --repo would be the engine checkout's, and is
# refused here so it cannot pass for either
cat > "$d4/ghp/gh" <<G
#!/usr/bin/env bash
echo "\$*" >> "$d4/ghcalls"
repo=''; while [ \$# -gt 0 ]; do [ "\$1" = --repo ] && repo="\$2"; shift; done
case "\$repo" in
  owner/engine) cat "$d4/ghp/engine.json" ;;
  example-org/example-app) cat "$d4/ghp/app.json" ;;
  *) echo "no repository named" >&2; exit 1 ;;
esac
G
chmod +x "$d4/ghp/gh"
printf '%s\n' '[{"number":7,"state":"OPEN","title":"T-004: engine side","headRefName":"t-004-engine","mergedAt":null}]' \
  > "$d4/ghp/engine.json"
printf '%s\n' '[{"number":7,"state":"MERGED","title":"T-004: app side","headRefName":"t-004-app","mergedAt":"2026-09-24T00:00:00Z"}]' \
  > "$d4/ghp/app.json"
# the engine's #7 was already opened before projects existed: no project on
# the line, so it is the default project's, and is not written twice
printf '%s\n' '{"ts":"2026-09-20T00:00:00Z","actor":"github","type":"pr_opened","task":"T-004","pr":7}' \
  > "$d4/state/events.jsonl"
out4="$(FM_ROOT="$d4" FM_GH="$d4/ghp/gh" "$d4/bin/fm-sync-prs.sh" --repo "$d4" 2>&1)"
assert_eq "0" "$?" "a sync across two projects exits 0"
assert_contains "$out4" "merged #7 (T-004) in example-app" "and says which project each new event is in"
calls="$(cat "$d4/ghcalls")"
assert_contains "$calls" "--repo owner/engine" "it polls the default project's repository by name"
assert_contains "$calls" "--repo example-org/example-app" "and the other project's"
log4="$d4/state/events.jsonl"
assert_eq "example-app" "$(jq -r 'select(.type=="merged" and .pr==7)|.project' "$log4")" \
  "the other project's merge is written with that project"
assert_eq "T-004" "$(jq -r 'select(.type=="merged" and .pr==7)|.task' "$log4")" "and its task"
assert_eq "1" "$(jq -s 'map(select(.type=="pr_opened" and .pr==7))|length' "$log4")" \
  "the default project's #7, already in the log without a project, is not written again"
# the app's #7 opens later in the other repository: its own event, not a
# duplicate of the engine's pr_opened #7
printf '%s\n' '[{"number":7,"state":"OPEN","title":"T-004: app side","headRefName":"t-004-app","mergedAt":null}]' \
  > "$d4/ghp/app.json"
FM_ROOT="$d4" FM_GH="$d4/ghp/gh" "$d4/bin/fm-sync-prs.sh" --repo "$d4" >/dev/null 2>&1
assert_eq "example-app" "$(jq -r 'select(.type=="pr_opened" and .pr==7 and .project=="example-app")|.project' "$log4")" \
  "a pull request number in one project never matches another project's event"
n4="$(wc -l < "$log4" | tr -d ' ')"
FM_ROOT="$d4" FM_GH="$d4/ghp/gh" "$d4/bin/fm-sync-prs.sh" --repo "$d4" >/dev/null 2>&1
assert_eq "$n4" "$(wc -l < "$log4" | tr -d ' ')" "and a second sync writes nothing new in either project"
# a project whose repository cannot be read does not stop the others
printf 'not json\n' > "$d4/ghp/engine.json"
printf '%s\n' '[{"number":8,"state":"OPEN","title":"T-005: app","headRefName":"t-005-app","mergedAt":null}]' \
  > "$d4/ghp/app.json"
FM_ROOT="$d4" FM_GH="$d4/ghp/gh" "$d4/bin/fm-sync-prs.sh" --repo "$d4" >/dev/null 2>&1
assert_ne "0" "$?" "a project that cannot be read makes the sync exit non-zero"
assert_eq "example-app" "$(jq -r 'select(.pr==8)|.project' "$log4")" "but the other project is still synced"
rm -rf "$d4"

# A tree whose config.yaml has no `projects:` map - every fixture written
# before projects existed - still needs nothing beside the script: not the
# registry library, which the old fixture never copied. It polls the
# checkout's own repository and writes no project, as before.
d5="$(fixture)"
printf 'vendor: mock\nconcurrency: 2\n' > "$d5/config.yaml"
OLD5="$(rec "$d5" old <<'J'
[{"number":3,"state":"OPEN","title":"T-003: old","headRefName":"t-003-old","mergedAt":null}]
J
)"
out5="$(FM_ROOT="$d5" FM_GH="$OLD5" "$d5/bin/fm-sync-prs.sh" --repo "$d5" 2>&1)"
assert_eq "0" "$?" "a config.yaml with no projects: map syncs with only the two scripts it always had"
assert_contains "$out5" "pr_opened #3" "and writes what it found"
assert_eq "false" "$(jq -c 'select(.pr==3)|has("project")' "$d5/state/events.jsonl")" \
  "with no project, as before"
rm -rf "$d5"
# The same tree shipping the registry library, as a real checkout does: the
# library finds no `projects:` map, so the sync is the same as before. The
# script never reads config.yaml itself (tests/config.test.sh).
d6="$(fixture)"; cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$d6/bin/"
printf 'vendor: mock\nconcurrency: 2\n' > "$d6/config.yaml"
OLD6="$(rec "$d6" old <<'J'
[{"number":3,"state":"OPEN","title":"T-003: old","headRefName":"t-003-old","mergedAt":null}]
J
)"
out6="$(FM_ROOT="$d6" FM_GH="$OLD6" "$d6/bin/fm-sync-prs.sh" --repo "$d6" 2>&1)"
assert_eq "0" "$?" "a config.yaml with no projects: map read through the library syncs"
assert_contains "$out6" "pr_opened #3" "and writes what it found"
assert_eq "false" "$(jq -c 'select(.pr==3)|has("project")' "$d6/state/events.jsonl")" \
  "with no project, as before"
rm -rf "$d6"

# --- T-119: every task's branch, by the one grammar -----------------------
# SK-001's pull request (#94) and the revert #96 as GitHub holds them,
# recorded on 2026-09-26 (#96 is taken as still open here):
#   $ gh api repos/BenjaminLu/firstmate-workflow/pulls/94 \
#       --jq '{number: .number, head: .head.ref, title: .title, merged_at: .merged_at}'
#   head: sk-001-skill-update-firstmate
#   merged_at: "2026-09-26T07:46:54Z"
#   number: 94
#   title: "SK-001: skill-update: firstmate"
#   $ gh api repos/BenjaminLu/firstmate-workflow/pulls/96 \
#       --jq '{number: .number, head: .head.ref, title: .title}'
#   head: t-105-revert
#   number: 96
#   title: "T-105: revert the crew sandbox, which locks every vendor out on macOS"
# #95, #98 and #99 are made up. #98 is the pull request GitHub's Revert
# button would open for #90 (recorded head t-105-every-crew-round-runs-under;
# the title is main's squash subject fe396a5 without " (#96)"): its branch
# and title name no task. A branch that names nothing defers to the title.
d7="$(fixture)"
SK="$(rec "$d7" sk <<'J'
[{"number":94,"state":"MERGED","title":"SK-001: skill-update: firstmate","headRefName":"sk-001-skill-update-firstmate","mergedAt":"2026-09-26T07:46:54Z"},
 {"number":95,"state":"OPEN","title":"T-116: the board shows each crew member","headRefName":"board-fields","mergedAt":null},
 {"number":96,"state":"OPEN","title":"T-105: revert the crew sandbox, which locks every vendor out on macOS","headRefName":"t-105-revert","mergedAt":null},
 {"number":98,"state":"OPEN","title":"Revert \"T-105: every crew round runs under one fm-owned permission policy, enforced by the vendor's own flags and an OS sandbox, for every vendor (#90)\"","headRefName":"revert-90-t-105-every-crew-round-runs-under","mergedAt":null},
 {"number":99,"state":"OPEN","title":"T-1170: a longer number","headRefName":"t-1170-other","mergedAt":null}]
J
)"
out7="$(FM_ROOT="$d7" FM_GH="$SK" "$d7/bin/fm-sync-prs.sh" --repo "$d7" 2>&1)"
assert_eq "0" "$?" "a sync with a skill update's pull request exits 0"
log7="$d7/state/events.jsonl"
assert_eq "SK-001" "$(jq -r 'select(.pr==94)|.task' "$log7")" "sk-001-… syncs as SK-001"
assert_contains "$out7" "merged #94 (SK-001)" "and says so"
assert_eq "T-116" "$(jq -r 'select(.pr==95)|.task' "$log7")" "a branch naming no task defers to the title's prefix"
assert_eq "T-105" "$(jq -r 'select(.pr==96)|.task' "$log7")" "#96's t-105-revert is T-105's"
assert_eq "none" "$(jq -r 'select(.pr==98)|.task // "none"' "$log7")" "a revert of no task names no task"
assert_eq "T-1170" "$(jq -r 'select(.pr==99)|.task' "$log7")" "t-1170-… is T-1170, the whole number"
rm -rf "$d7"

# it goes through the one writer like everyone else
# the header comment names fm-emit.sh too; look at what runs
assert_ok "grep -q 'fm-emit.sh' <<<\"\$(grep -vE '^[[:space:]]*#' '$ROOT/bin/fm-sync-prs.sh')\"" \
  "it writes through fm-emit.sh"
rm -rf "$d" "$d2" "$d3"
finish
