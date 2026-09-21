#!/usr/bin/env bash
# Nothing here edits a skill. The system changes its own behaviour the way it
# changes anything else: a task, a branch, a pull request, seven gates. What
# this suite is really asserting is the absence of a shortcut.
#
# Two habits this file keeps, because the last round broke both:
#
#   - No assertion proves a property by grepping a source file. Every one of
#     them runs something and reads what happened. A grep for "$SRC" that
#     should have been "$src" passed on every input for a whole round and
#     read as coverage the entire time.
#   - Where the lint is asserted, it is asserted from a table of samples, so
#     the next person to touch the detector finds out what they broke rather
#     than discovering that the two samples in the suite happened to be the
#     two shapes the code already handled.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
FM="$ROOT/bin/fm.sh"

# a repository shaped like this one: the scripts that matter, two skills, a
# task file, and nothing under git - only the gate fixture needs a real repo
fixture() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/bin" "$d/board" "$d/design" "$d/state" "$d/skills/worker" "$d/skills/reviewer"
  cp "$ROOT/bin/fm.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-decide.sh" \
     "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-dispatch.sh" "$d/bin/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/fm-worker.sh"; chmod +x "$d/bin/fm-worker.sh"
  printf 'concurrency: 3\n' > "$d/config.yaml"
  printf '# Worker\n\nYou are one crew member on one task.\n' > "$d/skills/worker/SKILL.md"
  printf '# Reviewer\n\nFind the reason to reject.\n' > "$d/skills/reviewer/SKILL.md"
  printf '{"tasks":[{"id":"T-001","depends_on":[],"scope":["bin/**"]}]}\n' > "$d/design/tasks.json"
  printf '%s' "$d"
}

# content, not timestamps: an import that rewrote the source in place would
# change a checksum, and one that only read it cannot
treesum() { ( cd "$1" 2>/dev/null && find . -type f | LC_ALL=C sort \
  | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done ); }
# imported trees are read-only on purpose, so removing one needs the bit back
scrub() { for p in "$@"; do [ -e "$p" ] || continue; chmod -R u+w "$p" 2>/dev/null; rm -rf "$p"; done; }
types() { jq -r .type < "$1/state/events.jsonl" 2>/dev/null | tr '\n' ' '; }
# plant <path> <body> ; an executable script with one interesting line in it
plant() { mkdir -p "$(dirname "$1")"; printf '#!/usr/bin/env bash\n%s\n' "$2" > "$1"; chmod +x "$1"; }

# =========================================================================
# 1. self-update proposes; it never edits
# =========================================================================
d="$(fixture)"
before="$(treesum "$d/skills")"
assert_ok "'$FM' self-update --skill worker --why 'say the round-three rule once' --repo '$d'" \
  "self-update accepts a skill and a reason"
assert_eq "$before" "$(treesum "$d/skills")" "it changes nothing under skills/"
assert_ok "test -f '$d/state/skill-updates/SK-001.json'" "the proposal is written to state/"

spec="$(cat "$d/state/skill-updates/SK-001.json" 2>/dev/null)"
assert_eq "SK-001" "$(jq -r .id <<<"$spec" 2>/dev/null)" "the proposal is an ordinary task spec"
assert_contains "$(jq -r .title <<<"$spec" 2>/dev/null)" "skill-update" "titled as a skill-update"
assert_contains "$(jq -r .why <<<"$spec" 2>/dev/null)" "round-three" "and it carries the reason given"
# a bootstrap task is one built by hand, outside the loop - which is exactly
# the shortcut a skill-update may not take
assert_eq "false" "$(jq -r .bootstrap <<<"$spec" 2>/dev/null)" "it is not a bootstrap task"

# the scope is the whole of the promise that a skill-update cannot smuggle
# code: it reaches skills/ and the test that proves the skill, and nowhere else
scopes="$(jq -r '.scope[]' <<<"$spec" 2>/dev/null)"
assert_contains "$scopes" "skills/worker/**" "its scope reaches the named skill"
assert_lacks "$scopes" "bin/" "its scope cannot reach bin/"
assert_lacks "$scopes" "board/" "its scope cannot reach board/"
offscope=''
while IFS= read -r s; do
  [ -n "$s" ] || continue
  case "$s" in skills/*|tests/*) ;; *) offscope="$offscope $s" ;; esac
done <<< "$scopes"
assert_eq "" "$offscope" "every glob is under skills/ or tests/"

# it asks the captain rather than starting work
assert_contains "$(types "$d")" "decision_requested" "it puts a card in front of the captain"
assert_lacks "$(types "$d")" "dispatched" "and dispatches nothing itself"
assert_ok "test -f '$d/state/pending/D-SK-001.json'" "the decision is pending on the board"

assert_ok "'$FM' self-update --skill reviewer --why 'again' --repo '$d'" "a second proposal is accepted"
assert_ok "test -f '$d/state/skill-updates/SK-002.json'" "and gets the next free id"

assert_fail "'$FM' self-update --skill nosuch --why 'x' --repo '$d'" "it refuses a skill that does not exist"
assert_fail "'$FM' self-update --skill worker --repo '$d'" "it refuses a change with no stated reason"
assert_fail "'$FM' self-update --skill vendor/imported --why 'x' --repo '$d'" \
  "it refuses to rewrite an imported skill"
assert_eq "$before" "$(treesum "$d/skills")" "and none of the refusals wrote anything"

# =========================================================================
# 2. the captain's answer is what moves it, and nothing else
#
# A card nobody reads the answer to is decoration. The step between "the
# captain said yes" and "the dispatcher can see it" used to be a human
# retyping JSON into design/tasks.json, which meant the green light had no
# mechanical consequence at all.
# =========================================================================
printf '# Design\n\n## 14. the tasks\n\n| id | title | depends |\n| --- | --- | --- |\n| T-001 | first | - |\n' \
  > "$d/design/design.md"

assert_fail "'$FM' self-update --adopt SK-001 --repo '$d'" "adopt refuses while the card is unanswered"
assert_lacks "$(cat "$d/design/tasks.json")" "SK-001" "and the plan is untouched"

printf '{"id":"D-SK-001","task":"SK-001","chosen":"B"}\n' > "$d/state/decisions/D-SK-001.json"
assert_fail "'$FM' self-update --adopt SK-001 --repo '$d'" "and refuses when the captain answered no"
assert_lacks "$(cat "$d/design/tasks.json")" "SK-001" "the plan is still untouched"

printf '{"id":"D-SK-001","task":"SK-001","chosen":"A"}\n' > "$d/state/decisions/D-SK-001.json"
assert_ok "'$FM' self-update --adopt SK-001 --repo '$d'" "a yes adopts it"
assert_eq "SK-001" "$(jq -r '.tasks[]|select(.id=="SK-001")|.id' "$d/design/tasks.json" 2>/dev/null)" \
  "the proposal is now a task in design/tasks.json"
assert_contains "$(cat "$d/design/design.md")" "| SK-001 |" \
  "and a row in design.md, which bin/ci.sh checks against tasks.json"
assert_eq "$before" "$(treesum "$d/skills")" "adopting still edits no skill"
assert_ok "'$FM' self-update --adopt SK-001 --repo '$d'" "adopting twice is not an error"
assert_eq "1" "$(jq '[.tasks[]|select(.id=="SK-001")]|length' "$d/design/tasks.json" 2>/dev/null)" \
  "and does not add it twice"
assert_fail "'$FM' self-update --adopt SK-999 --repo '$d'" "a proposal that was never made cannot be adopted"

# =========================================================================
# 3. the proposal travels the ordinary dispatcher
# =========================================================================
assert_contains "$(FM_ROOT="$d" "$d/bin/fm-dispatch.sh" --repo "$d" --dry-run 2>/dev/null | sed '/^fm-dispatch/d')" \
  "SK-001" "the same dispatcher picks it up, with no special case for a skill-update"

# the eighth gate, checked on a tree where nobody has green-lit anything
d2="$(fixture)"
"$FM" self-update --skill worker --why 'x' --repo "$d2" >/dev/null 2>&1
jq '{tasks:[.]}' "$d2/state/skill-updates/SK-001.json" > "$d2/design/tasks.json"
assert_fail "FM_ROOT='$d2' '$d2/bin/fm-dispatch.sh' --repo '$d2' --dry-run" \
  "a skill-update waits for a greenlit event like anything else"

# =========================================================================
# 4. and all seven gates, not only the one that reads the scope
#
# A skill-update changes markdown and nothing else, which is the exact shape
# that tends to fall through a gate written with code in mind. So the whole
# set runs against one, and each gate is shown blocking as well as passing.
# =========================================================================
g="$(mktemp -d)"
GHSTATE="$(mktemp -d)"; export GHSTATE
GH="$ROOT/tests/gh-stub.sh"
git -C "$g" init -q -b main
git -C "$g" config user.email a@b.c; git -C "$g" config user.name t
mkdir -p "$g/design" "$g/skills/worker" "$g/bin" "$g/tests"
jq '{tasks:[.]}' "$d/state/skill-updates/SK-001.json" > "$g/design/tasks.json"
printf '# Worker\n' > "$g/skills/worker/SKILL.md"
printf 'x\n' > "$g/bin/thing.sh"
# gate 3 runs whatever bin/ci.sh the branch carries, so the fixture needs a
# real one: a gate that cannot run is not a gate a skill-update passed
printf '#!/usr/bin/env bash\nset -uo pipefail\nR="${FM_ROOT:-.}"\nrc=0\nfor t in "$R"/tests/*.test.sh; do\n  [ -f "$t" ] || continue\n  FM_ROOT="$R" bash "$t" || rc=1\ndone\nexit "$rc"\n' > "$g/bin/ci.sh"
chmod +x "$g/bin/ci.sh"
git -C "$g" add -A; git -C "$g" commit -qm base

git -C "$g" checkout -q -b sk-001-skill
printf '# Worker\n\nthe new rule.\n' > "$g/skills/worker/SKILL.md"
printf '#!/usr/bin/env bash\ngrep -q "the new rule" "${FM_ROOT:-.}/skills/worker/SKILL.md"\n' > "$g/tests/skills.test.sh"
git -C "$g" add -A; git -C "$g" commit -qm skill; git -C "$g" checkout -q main

# the pull request the change travels on, in a gh that remembers
pr="$("$GH" pr create --head sk-001-skill --title 'skill-update: worker' | sed 's|.*/||')"
GH_AS=reviewer-1 "$GH" pr comment "$pr" --body "APPROVE:SK-001"

gate="GHSTATE='$GHSTATE' FM_GH='$GH' FM_REVIEWER_LOGIN=reviewer-1 '$ROOT/bin/fm-gate.sh' --task SK-001 --repo '$g'"
assert_ok "$gate --branch sk-001-skill --pr $pr" \
  "a skill-update passes all seven gates, markdown diff and all"

# and each of the seven, shown blocking. A gate nobody has seen go red is a
# gate nobody has seen.
assert_fail "$gate --branch nosuch --pr $pr --only 1" "1 blocks a branch that does not exist"

git -C "$g" checkout -q -b sk-001-conflict main
printf '# Worker\n\na different rule.\n' > "$g/skills/worker/SKILL.md"
git -C "$g" commit -qam conflict
git -C "$g" checkout -q main
printf '# Worker\n\nmain moved.\n' > "$g/skills/worker/SKILL.md"
git -C "$g" commit -qam moved
assert_fail "$gate --branch sk-001-conflict --pr $pr --only 2" "2 blocks one that will not rebase"
git -C "$g" reset -q --hard HEAD~1

# git removes a directory that has no tracked file left in it, so checking
# main out takes tests/ with it every time
git -C "$g" checkout -q -b sk-001-redci main
mkdir -p "$g/tests"
printf '# Worker\n\nthe new rule.\n' > "$g/skills/worker/SKILL.md"
printf '#!/usr/bin/env bash\nexit 1\n' > "$g/tests/skills.test.sh"
git -C "$g" add -A; git -C "$g" commit -qm redci; git -C "$g" checkout -q main
assert_fail "$gate --branch sk-001-redci --pr $pr --only 3" "3 blocks one whose own suite is red"
assert_ok "$gate --branch sk-001-skill --pr $pr --only 3" "and passes one whose suite is green"

git -C "$g" checkout -q -b sk-001-code main
printf 'y\n' > "$g/bin/thing.sh"; git -C "$g" commit -qam code; git -C "$g" checkout -q main
assert_fail "$gate --branch sk-001-code --pr $pr --only 4" "4 blocks one that reaches into bin/"

# Gate 5 is the other one a skill-update could have slipped past. A skill
# changes no code, only markdown, and a gate that read "markdown is not
# implementation" would wave every skill-update through untested.
git -C "$g" checkout -q -b sk-001-vacuous main
mkdir -p "$g/tests"
printf '# Worker\n\nthe new rule.\n' > "$g/skills/worker/SKILL.md"
printf '#!/usr/bin/env bash\ntest -f "${FM_ROOT:-.}/skills/worker/SKILL.md"\n' > "$g/tests/skills.test.sh"
git -C "$g" add -A; git -C "$g" commit -qm vacuous; git -C "$g" checkout -q main
assert_fail "$gate --branch sk-001-vacuous --pr $pr --only 5" "5 blocks one whose test passes without the change"

: > "$GHSTATE/red"
assert_fail "$gate --branch sk-001-skill --pr $pr --only 6" "6 blocks when the required check is red"
rm -f "$GHSTATE/red"

# the pull request is not decoration either: with no pull request there is no
# required check and no approval, so a skill-update cannot reach the merge
# card without one
assert_fail "$gate --branch sk-001-skill --only 6" "6 blocks a skill-update with no pull request at all"
assert_fail "$gate --branch sk-001-skill --only 7" "7 blocks one with no pull request at all"

pr2="$("$GH" pr create --head sk-001-code --title 'another' | sed 's|.*/||')"
assert_fail "$gate --branch sk-001-skill --pr $pr2 --only 7" "7 blocks a pull request nobody approved"
GH_AS=someone-else "$GH" pr comment "$pr2" --body "APPROVE:SK-001"
assert_fail "$gate --branch sk-001-skill --pr $pr2 --only 7" "7 blocks an approval from the wrong account"

# =========================================================================
# 5. no path edits skills/ without a pull request
#
# The corpus is every program in the repository, which is the whole of the
# fix: the last round read bin/*.sh and board/*.ts, so a rogue in scripts/,
# at the root, in .github/workflows/ or simply named rogue.py was invisible.
# =========================================================================
assert_ok "'$FM' lint --repo '$ROOT'" "this repository has no path that writes a skill"
assert_contains "$("$FM" lint --repo "$ROOT" 2>&1)" "1 declared writer" \
  "and exactly one script in it declares itself the writer"

# a tree with no declared writer of its own, so the marker can be given out
# and taken away without disturbing the copy of fm.sh the other sections use
m="$(mktemp -d)"; mkdir -p "$m/bin" "$m/board" "$m/skills/worker"
printf '# Worker\n\nplain.\n' > "$m/skills/worker/SKILL.md"
assert_ok "'$FM' lint --repo '$m'" "an empty tree passes"

# --- where a rogue can hide ---------------------------------------------
body='cp new.md "$FIX/skills/worker/SKILL.md"'
while IFS= read -r where; do
  [ -n "$where" ] || continue
  plant "$m/$where" "$body"
  assert_fail "'$FM' lint --repo '$m'" "the lint reads $where"
  assert_contains "$("$FM" lint --repo "$m" 2>&1)" "$where" "and names it"
  rm -f "$m/$where"
done <<'WHERE'
bin/rogue.sh
bin/rogue.py
bin/rogue.tsx
bin/rogue
board/rogue.ts
board/rogue.html
.githooks/pre-commit
scripts/rogue.sh
rogue.sh
.github/workflows/rogue.yml
sub/dir/deep/rogue.sh
WHERE
assert_ok "'$FM' lint --repo '$m'" "the fixture is clean again"

# a file with no suffix and no executable bit is still a program if it says
# so on its first line - which is how a git hook and a python script that is
# run as `python3 thing` both get read
printf '#!/usr/bin/env python3\nopen("skills/worker/SKILL.md", "w").write(x)\n' > "$m/hook-no-suffix"
assert_fail "'$FM' lint --repo '$m'" "a shebang alone puts a file in the corpus"
rm -f "$m/hook-no-suffix"

# html is read when something in it runs and not when it is prose. The board
# is an html file with a script tag in it, which is why the suffix is in the
# corpus at all; a document that quotes a shell line is not.
printf '<html><script>\nawait Bun.write("skills/worker/SKILL.md", body)\n</script></html>\n' > "$m/board/page.html"
assert_fail "'$FM' lint --repo '$m'" "html that runs something is read"
printf '<html><p>then run: cp new.md skills/worker/SKILL.md</p></html>\n' > "$m/board/page.html"
assert_ok "'$FM' lint --repo '$m'" "html that only describes one is prose"
rm -f "$m/board/page.html"

# --- and how it can be written ------------------------------------------
# Every shape below is a write. The table is here so that the next person to
# touch the detector finds out what they broke; the last round shipped two
# samples, both of which happened to be shapes the regex already caught.
while IFS= read -r sample; do
  [ -n "$sample" ] || continue
  plant "$m/bin/rogue.sh" "$sample"
  assert_fail "'$FM' lint --repo '$m'" "caught: $sample"
  rm -f "$m/bin/rogue.sh"
done <<'WRITES'
printf x > "$FIX/skills/worker/SKILL.md"
printf x > "$FIX"/skills/worker/SKILL.md
printf x >"$FIX"/skills/worker/SKILL.md
printf x >> "$FIX"/skills/worker/SKILL.md
printf x > skills/worker/SKILL.md
cp new.md "$FIX"/skills/worker/SKILL.md
cp -R staged/. "$FIX/skills/worker/"
install -m 644 new.md "$FIX/skills/worker/SKILL.md"
rsync -a staged/ "$FIX/skills/worker/"
mv tmp.md "$FIX/skills/worker/SKILL.md"
rm -rf "$FIX/skills"
mkdir -p "$FIX/skills/worker"
touch "$FIX/skills/worker/SKILL.md"
tee "$FIX/skills/worker/SKILL.md" < new.md
cat new.md | sponge "$FIX/skills/worker/SKILL.md"
sed -i .bak s/a/b/ "$FIX/skills/worker/SKILL.md"
perl -i -pe s/a/b/ "$FIX/skills/worker/SKILL.md"
git -C "$FIX" checkout other -- skills/worker/SKILL.md
git -C "$FIX" restore --source other skills/worker/SKILL.md
await Bun.write("skills/worker/SKILL.md", body)
writeFileSync("skills/worker/SKILL.md", body)
appendFile("skills/worker/SKILL.md", body)
python3 -c "open(\"skills/worker/SKILL.md\", \"w\").write(x)"
WRITES

# and every shape below is not a write, because reading a skill is allowed
# and a lint that flags reads is a lint people turn off
while IFS= read -r sample; do
  [ -n "$sample" ] || continue
  plant "$m/bin/rogue.sh" "$sample"
  assert_ok "'$FM' lint --repo '$m'" "allowed: $sample"
  rm -f "$m/bin/rogue.sh"
done <<'READS'
cp "$FIX/skills/worker/SKILL.md" /tmp/backup
grep -q rule "$FIX/skills/worker/SKILL.md"
diff a "$FIX/skills/worker/SKILL.md"
[ -f "$FIX/skills/worker/SKILL.md" ] || exit 1
printf 'see skills/worker for the rule\n'
WRITES_TO="$FIX/skills/worker"
READS
assert_ok "'$FM' lint --repo '$m'" "the fixture is clean after the table"

# --- the marker says "the one writer", not "anywhere" --------------------
plant "$m/bin/rogue.sh" '# fm:skills-writer
cp -R staged/. "$FIX/skills/vendor/imported/"'
assert_ok "'$FM' lint --repo '$m'" "the declared writer may write skills/vendor"
rm -f "$m/bin/rogue.sh"

while IFS= read -r sample; do
  [ -n "$sample" ] || continue
  plant "$m/bin/rogue.sh" "# fm:skills-writer
$sample"
  assert_fail "'$FM' lint --repo '$m'" "declared, and still refused: $sample"
  rm -f "$m/bin/rogue.sh"
done <<'ESCAPES'
cp new.md "$FIX/skills/worker/SKILL.md"
cp -R s/. "$FIX/skills/vendor/../worker/"
cp -R s/. "$FIX/skills/vendor/./../worker/"
mv tmp "$FIX/skills/vendor/../../skills/worker"
rm -rf "$FIX/skills"
ESCAPES

# the count is read, not merely printed: two files quietly declaring the same
# marker is how "the marker licenses this script" becomes "the marker
# licenses any script that adds a comment line"
assert_contains "$("$FM" lint --repo "$m" 2>&1)" "0 declared writer" "a fixture with no writer says so"
plant "$m/bin/one.sh" '# fm:skills-writer
: nothing'
assert_ok "'$FM' lint --repo '$m'" "one declared writer is the shape a tree is allowed"
plant "$m/bin/two.sh" '# fm:skills-writer
: nothing'
assert_fail "'$FM' lint --repo '$m'" "a second self-declared writer fails the lint"
rm -f "$m/bin/one.sh" "$m/bin/two.sh"
assert_ok "'$FM' lint --repo '$m'" "the fixture is clean again"

# --- under tests/ the question is different ------------------------------
# A suite builds its own tree in a temporary directory and writes that; it
# never writes the checkout it is running from. So a skills/ path in a suite
# is only a violation when it is rooted at the checkout - and the names a
# suite has for the checkout are read out of the file, not guessed.
mkdir -p "$m/tests"
printf '#!/usr/bin/env bash\nt="$(mktemp -d)"\nmkdir -p "$t/skills/worker"\nprintf x > "$t/skills/worker/SKILL.md"\n' \
  > "$m/tests/fixture.test.sh"
assert_ok "'$FM' lint --repo '$m'" "a suite may write the tree it built itself"

# built out of a %s so that this file never contains the shape it plants
{ printf '#!/usr/bin/env bash\n'
  printf 'R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"\n'
  printf 'printf x > "$%s/skills/worker/SKILL.md"\n' R
} > "$m/tests/rogue.test.sh"
assert_fail "'$FM' lint --repo '$m'" "but not the checkout it is running from"
assert_contains "$("$FM" lint --repo "$m" 2>&1)" "rogue.test.sh" "and the lint names the suite"
rm -f "$m/tests/rogue.test.sh"

{ printf '#!/usr/bin/env bash\n'
  printf 'printf x > "$%s/skills/worker/SKILL.md"\n' FM_ROOT
} > "$m/tests/rogue.test.sh"
assert_fail "'$FM' lint --repo '$m'" "FM_ROOT is the checkout under any name the suite gives it"
rm -f "$m/tests/rogue.test.sh" "$m/tests/fixture.test.sh"
assert_ok "'$FM' lint --repo '$m'" "the fixture is clean once the suites are gone"

# =========================================================================
# 6. sync-skills imports one way
# =========================================================================
src="$(mktemp -d)"
mkdir -p "$src/plain-skill" "$src/vendor-skill"
printf -- '---\nname: plain-skill\n---\n\nPlain markdown, no vendor anywhere.\n' > "$src/plain-skill/SKILL.md"
printf 'a reference\n' > "$src/plain-skill/reference.md"
printf -- '---\nname: vendor-skill\n---\n\nRead CLAUDE.md first.\n' > "$src/vendor-skill/SKILL.md"
srcsum="$(treesum "$src")"
chmod -R a-w "$src"          # if it ever wrote back, this run would fail

assert_ok "'$FM' sync-skills '$src' --repo '$d'" "it imports from a read-only source"
assert_eq "$srcsum" "$(treesum "$src")" "the source is byte for byte unchanged"
assert_ok "test -f '$d/skills/vendor/plain-skill/SKILL.md'" "the clean skill lands in skills/vendor/"
assert_ok "test -f '$d/skills/vendor/plain-skill/reference.md'" "with the rest of its files"
assert_fail "test -e '$d/skills/vendor/vendor-skill'" "the one with vendor syntax is not imported"
assert_contains "$("$FM" sync-skills "$src" --repo "$d" 2>&1)" "vendor-skill" "and the run says which it skipped"
assert_ok "'$FM' lint --repo '$d'" "so skills/ still passes the lint after an import"

# read-only means the tree, not only the files in it: a tree whose files are
# locked and whose directories are not is a tree you can still add a file to
assert_fail "test -w '$d/skills/vendor/plain-skill/SKILL.md'" "an imported file is read-only"
assert_fail "touch '$d/skills/vendor/plain-skill/sneaked.md'" "and a file cannot be added to an imported tree"
assert_fail "test -e '$d/skills/vendor/plain-skill/sneaked.md'" "so nothing was added"

assert_ok "test -f '$d/skills/vendor/MANIFEST.tsv'" "the import records where it came from"
assert_contains "$(cat "$d/skills/vendor/MANIFEST.tsv")" "plain-skill" "naming the skill it took"

# git ignoring skills/vendor is a thing git does, not a character in a file:
# the old assertion read '^\*$' out of .gitignore and would have passed on a
# .gitignore that ignored nothing
gi="$(mktemp -d)"
git -C "$gi" init -q -b main
git -C "$gi" config user.email a@b.c; git -C "$gi" config user.name t
"$FM" sync-skills "$src" --repo "$gi" >/dev/null 2>&1
assert_ok "git -C '$gi' check-ignore -q skills/vendor/plain-skill/SKILL.md" \
  "git itself ignores what the import wrote"
assert_ok "git -C '$gi' check-ignore -q skills/vendor/MANIFEST.tsv" \
  "including the manifest, which records a local path"
assert_fail "git -C '$gi' check-ignore -q skills/vendor/.gitignore" \
  "and the .gitignore that says so is itself tracked"

# one way: a local edit is not a change to the source, it is a change to be lost
chmod -R u+w "$d/skills/vendor/plain-skill"
printf 'locally edited\n' > "$d/skills/vendor/plain-skill/SKILL.md"
assert_ok "'$FM' sync-skills '$src' --repo '$d'" "a second import runs"
assert_lacks "$(cat "$d/skills/vendor/plain-skill/SKILL.md")" "locally edited" "the local edit is gone"
assert_eq "$srcsum" "$(treesum "$src")" "and was never pushed back to the source"

# the role skills are not in the blast radius of an import
assert_contains "$(cat "$d/skills/worker/SKILL.md")" "one crew member" "an import leaves skills/worker alone"

single="$(mktemp -d)"; mkdir -p "$single/inner"
printf 'plain.\n' > "$single/inner/SKILL.md"
assert_ok "'$FM' sync-skills '$single/inner' --repo '$d' --name renamed" "a single skill can be imported by name"
assert_ok "test -f '$d/skills/vendor/renamed/SKILL.md'" "under the name it was given"
assert_fail "'$FM' sync-skills '$single/inner' --repo '$d' --name '../escape'" "it refuses a name that climbs out"
assert_fail "test -e '$d/skills/escape'" "and nothing lands outside skills/vendor"
assert_fail "'$FM' sync-skills '$d/skills' --repo '$d'" "it refuses a source inside the repository"
empty="$(mktemp -d)"
assert_fail "'$FM' sync-skills '$empty' --repo '$d'" "and a source with no skill in it"

# =========================================================================
# 7. the lint knows vendor syntax when it sees it
# =========================================================================
while IFS= read -r sample; do
  [ -n "$sample" ] || continue
  printf '# Worker\n\n%s\n' "$sample" > "$d/skills/worker/SKILL.md"
  assert_fail "'$FM' lint --repo '$d'" "lint rejects [$sample]"
done <<'SAMPLES'
<invoke name="Read">
<tool_call>
The rules live in CLAUDE.md.
Run claude -p "do the thing".
Install @anthropic-ai/sdk first.
allowed-tools: Bash, Read
SAMPLES
printf '# Worker\n\nPlain markdown that names no engine.\n' > "$d/skills/worker/SKILL.md"
assert_ok "'$FM' lint --repo '$d'" "and passes plain portable markdown"

scrub "$d" "$d2" "$g" "$gi" "$m" "$src" "$single" "$empty" "$GHSTATE"
finish
