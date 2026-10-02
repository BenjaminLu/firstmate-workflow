#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/project-storage.sh
. "$ROOT/tests/lib/project-storage.sh"
# shellcheck source=tests/lib/board.sh
. "$ROOT/tests/lib/board.sh"
XDG_CONFIG_HOME="$(safe_tmpdir)"; export XDG_CONFIG_HOME
# --- T-069: every pull request number links to its project's pull request ----
# The URL comes from the project registry through bin/fm-config.sh, the one
# resolver every script uses, so the fixture carries it and its parser. The
# server is started with FM_PROJECT naming the other project: an event or
# card naming no project is the default project's, whatever the shell that
# started the board exported (T-054 covers events that name one, below).
g="$(safe_tmpdir)"; mkdir -p "$g/bin" "$g/state/pending" "$g/state/decisions" "$g/design" "$g/board/public"
cp "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-herdr.py" "$g/bin/"; project_storage_fixture "$g/bin/"
cp -R "$ROOT/bin/lib" "$g/bin/"   # the lifeline the board starts merges and rounds under (T-151)
cp "$ROOT/board/server.ts" "$g/board/"
cp "$ROOT/board/public/index.html" "$g/board/public/"
fm_tasks_write /dev/stdin "$g/design/tasks" <<'J'
{"tasks":[{"id":"T-G1","title":"in review","milestone":"M2","depends_on":[]},
          {"id":"T-G2","title":"merged","milestone":"M2","depends_on":[]},
          {"id":"T-G3","title":"no pull request","milestone":"M2","depends_on":[]},
          {"id":"T-G4","title":"a string pr, follows #46","milestone":"M2","depends_on":[]}]}
J
FM_ROOT="$g" "$g/bin/fm-emit.sh" --actor captain --type greenlit --en "go" --tw "開工" >/dev/null
FM_ROOT="$g" "$g/bin/fm-emit.sh" --actor worker-g --task T-G1 --type dispatched --en "on it" --tw "接下" >/dev/null
FM_ROOT="$g" "$g/bin/fm-emit.sh" --actor worker-g --task T-G1 --type pr_opened --pr 41 \
  --en "opened #41" --tw "開了 #41" >/dev/null
FM_ROOT="$g" "$g/bin/fm-emit.sh" --actor github --task T-G2 --type merged --pr 42 --en "merged #42" --tw "已合併 #42" >/dev/null
# numbers named in text that are no record's own pr: a summary on a line with
# no pr, a decision's title, a task title (T-G4's), and one that is not a
# pull request number at all
FM_ROOT="$g" "$g/bin/fm-emit.sh" --actor github --task T-G1 --type commit_pushed \
  --en "pushed to #41, replacing #44 (not #044, not T#9)" --tw "推到 #41，取代 #44" >/dev/null
# another tool writes pr as a string: the same number to the board, and a
# pr that is not a number is not linked at all
printf '%s\n' '{"ts":"2026-09-21T10:00:00Z","actor":"other","task":"T-G4","type":"pr_seen","pr":"43","summary":{"en":"saw #43"}}' \
  '{"ts":"2026-09-21T10:00:01Z","actor":"stranger","task":"T-G3","type":"pr_seen","pr":"043","summary":{"en":"odd"}}' \
  >> "$g/state/events.jsonl"
printf '{"id":"D-41","task":"T-G1","kind":"merge","pr":41,"title":"ready, after #45"}\n' > "$g/state/pending/D-41.json"
printf '{"id":"D-40","task":"T-G2","kind":"merge","pr":42,"chosen":"A","merged":{"ok":true}}\n' > "$g/state/decisions/D-40.json"
FM_ROOT="$g" FM_PORT=0 FM_PROJECT=alpha bun run "$g/board/server.ts" > "$g/out" 2>&1 < /dev/null &
pidg=$!
PORTG="$(board_port "$g/out" "$pidg")"
endg=$(( $(date +%s) + 60 ))
until curl -sf "http://127.0.0.1:$PORTG/api/state" >/dev/null 2>&1; do
  [ "$(date +%s)" -le "$endg" ] && kill -0 "$pidg" 2>/dev/null || break
  sleep 0.05
done
sg() {
  local selected
  selected="$(sed -n 's/^default_project: //p' "$g/config.yaml" 2>/dev/null)"
  curl -sf "http://127.0.0.1:$PORTG/api/state${selected:+?project=$selected}"
}
# every place /api/state returns a pr number, as "pr=url" per line; a url
# the server leaves out reads as null
urls() {
  jq -r '[(.tasks[]|select(.pr!=null)), .pending[], .responses[],
          (.recent[]|select(.pr!=null and .actor!="stranger")),
          (.outcomes[]|select(.pr!=null))] | map("\(.pr)=\(.pr_url)") | .[]' <<<"$(sg)"
}
# every #n written in text anywhere in /api/state, and the URL beside it
mentions() { jq -r '.pr_urls | to_entries | map("\(.key)=\(.value)") | .[]' <<<"$(sg)"; }
registry() {   # registry <default> <alpha github line> <beta github line>
  cat > "$g/config.yaml" <<Y
vendor: claude
default_project: $1
projects:
  alpha:
$( [ "$1" != alpha ] || printf "    repo: ." )
$2
    base: main
    required_check: ci
  beta:
$( [ "$1" != beta ] || printf "    repo: ." )
$3
    base: main
    required_check: check
Y
  project_fixture_config "$g"
}

# no registry at all: no URL anywhere, and never a guessed one
assert_eq "9" "$(urls | wc -l | tr -d ' ')" "the fixture puts a pr number in tasks, decisions, responses, the log and outcomes"
assert_eq "" "$(urls | grep -v '=null$')" "without a registry no pr number carries a URL"
assert_eq "{}" "$(jq -c '.pr_urls' <<<"$(sg)")" "without a registry no #n in any text carries a URL"
assert_eq "null" "$(jq -r '.tasks[]|select(.id=="T-G3")|.pr_url' <<<"$(sg)")" "a task with no pull request has no URL"

# the default project's github, next to every pr number
registry beta "    github: example-org/alpha-app" "    github: example-org/beta-app"
assert_eq "" "$(urls | grep -vE '^(41|42|43)=https://github\.com/example-org/beta-app/pull/(41|42|43)$')" \
  "every pr number carries the default project's pull request URL"
assert_eq "" "$(urls | awk -F= '$2 !~ ("/pull/" $1 "$")')" "and each URL is its own number's"
# one reading of a pr number: the string "43" another tool wrote is 43 on
# the card and on the log line, and "043" is no pull request anywhere
assert_eq "number=https://github.com/example-org/beta-app/pull/43" \
  "$(jq -r '.tasks[]|select(.id=="T-G4")|"\(.pr|type)=\(.pr_url)"' <<<"$(sg)")" "a string pr is the same number on its card"
assert_eq "string=https://github.com/example-org/beta-app/pull/43" \
  "$(jq -r '.recent[]|select(.actor=="other")|"\(.pr|type)=\(.pr_url)"' <<<"$(sg)")" "and carries its URL on its log line"
assert_eq "null=null" "$(jq -r '(.tasks[]|select(.id=="T-G3")|.pr), (.recent[]|select(.actor=="stranger")|.pr_url)' <<<"$(sg)" | paste -sd= -)" \
  "a pr that is not a pull request number is neither a card's number nor a link"
# every #n in any text, whoever's it is: a line with no pr, a title, a
# decision, and never #044 or T#9
assert_eq "41 42 43 44 45 46" "$(mentions | cut -d= -f1 | sort -n | paste -sd' ' -)" \
  "every #n written anywhere in the state is mapped, and nothing else"
assert_eq "" "$(mentions | awk -F= '$2 != ("https://github.com/example-org/beta-app/pull/" $1)')" \
  "each to its own pull request on the registered repository"
assert_eq "https://github.com/example-org/beta-app/pull/41" \
  "$(jq -r '.tasks[]|select(.id=="T-G1")|.pr_url' <<<"$(sg)")" "a lane card's #41 links to pull 41 on the registered repository"
assert_eq "https://github.com/example-org/beta-app/pull/41" \
  "$(jq -r '.pending[]|select(.id=="D-41")|.pr_url' <<<"$(sg)")" "and so does its decision card"
assert_eq "https://github.com/example-org/beta-app/pull/42" \
  "$(jq -r '.recent[]|select(.type=="merged")|.pr_url' <<<"$(sg)")" "and a log line's #42"
assert_eq "9" "$(grep -c '=https://github\.com/example-org/beta-app/pull/' <<<"$(urls)")" \
  "not one of them is left without it"

# the registry changes, the URL follows on the next request
registry beta "    github: example-org/alpha-app" "    github: other-org/renamed-app"
assert_eq "https://github.com/other-org/renamed-app/pull/41" \
  "$(jq -r '.tasks[]|select(.id=="T-G1")|.pr_url' <<<"$(sg)")" "the URL follows the registry's github when it changes"
assert_eq "" "$(urls | grep -v '=https://github\.com/other-org/renamed-app/pull/')" "everywhere at once"
assert_eq "" "$(mentions | grep -v '=https://github\.com/other-org/renamed-app/pull/')" "in text as well"
# the default project decides, not the first entry or the shell's FM_PROJECT
registry alpha "    github: example-org/alpha-app" "    github: other-org/renamed-app"
assert_eq "https://github.com/example-org/alpha-app/pull/41" \
  "$(jq -r '.tasks[]|select(.id=="T-G1")|.pr_url' <<<"$(sg)")" "the default project is the one whose repository is linked"

# the default project has no github: the registry refuses it, and the page
# gets no URL rather than some other project's
registry alpha "" "    github: other-org/renamed-app"
assert_eq "" "$(urls | grep -v '=null$')" "a default project with no github entry yields no URL"
assert_eq "{}" "$(jq -c '.pr_urls' <<<"$(sg)")" "and no #n in text is linked either"
# a config with no projects map registers nothing, so nothing is linked
printf 'vendor: claude\n' > "$g/config.yaml"
assert_eq "" "$(urls | grep -v '=null$')" "a config.yaml without a registry yields no URL"

kill "$pidg" 2>/dev/null
wait "$pidg" 2>/dev/null || true
rm -rf "$g"


safe_rm_rf "$XDG_CONFIG_HOME"
finish
