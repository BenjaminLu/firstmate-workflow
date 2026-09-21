#!/usr/bin/env bash
# Nothing here edits a skill. The system changes its own behaviour the way it
# changes anything else: a task, a branch, a pull request, seven gates. What
# this suite is really asserting is the absence of a shortcut.
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
# 2. the proposal travels the ordinary dispatcher
# =========================================================================
jq '{tasks:[.]}' "$d/state/skill-updates/SK-001.json" > "$d/design/tasks.json"
assert_fail "FM_ROOT='$d' '$d/bin/fm-dispatch.sh' --repo '$d' --dry-run" \
  "a skill-update waits for a greenlit event like anything else"
FM_ROOT="$d" "$d/bin/fm-emit.sh" --actor firstmate --type greenlit >/dev/null
assert_eq "SK-001" "$(FM_ROOT="$d" "$d/bin/fm-dispatch.sh" --repo "$d" --dry-run 2>/dev/null | sed '/^fm-dispatch/d')" \
  "and is then dispatched by the same dispatcher"

# =========================================================================
# 3. and the same gates. Gate 4 is the one that reads the scope.
# =========================================================================
g="$(mktemp -d)"
git -C "$g" init -q -b main
git -C "$g" config user.email a@b.c; git -C "$g" config user.name t
mkdir -p "$g/design" "$g/skills/worker" "$g/bin" "$g/tests"
jq '{tasks:[.]}' "$d/state/skill-updates/SK-001.json" > "$g/design/tasks.json"
printf '# Worker\n' > "$g/skills/worker/SKILL.md"
printf 'x\n' > "$g/bin/thing.sh"
git -C "$g" add -A; git -C "$g" commit -qm base

git -C "$g" checkout -q -b sk-001-skill
printf '# Worker\n\nthe new rule.\n' > "$g/skills/worker/SKILL.md"
printf '#!/usr/bin/env bash\ngrep -q "the new rule" "${FM_ROOT:-.}/skills/worker/SKILL.md"\n' > "$g/tests/skills.test.sh"
git -C "$g" add -A; git -C "$g" commit -qm skill; git -C "$g" checkout -q main
assert_ok "'$ROOT/bin/fm-gate.sh' --task SK-001 --repo '$g' --branch sk-001-skill --only 4" \
  "gate 4 passes a skill-update that stays in skills/"

git -C "$g" checkout -q -b sk-001-code main
printf 'y\n' > "$g/bin/thing.sh"; git -C "$g" commit -qam code; git -C "$g" checkout -q main
assert_fail "'$ROOT/bin/fm-gate.sh' --task SK-001 --repo '$g' --branch sk-001-code --only 4" \
  "gate 4 blocks one that reaches into bin/"

# Gate 5 is the other one a skill-update could have slipped past. A skill
# changes no code, only markdown, and a gate that read "markdown is not
# implementation" would wave every skill-update through untested. The
# proposal's own acceptance list says reverting the SKILL.md turns the
# assertion red, so the gate has to agree.
assert_ok "'$ROOT/bin/fm-gate.sh' --task SK-001 --repo '$g' --branch sk-001-skill --only 5" \
  "gate 5 passes a skill-update whose test reads the new sentence"

git -C "$g" checkout -q -b sk-001-vacuous main
printf '# Worker\n\nthe new rule.\n' > "$g/skills/worker/SKILL.md"
printf '#!/usr/bin/env bash\ntest -f "${FM_ROOT:-.}/skills/worker/SKILL.md"\n' > "$g/tests/skills.test.sh"
git -C "$g" add -A; git -C "$g" commit -qm vacuous; git -C "$g" checkout -q main
assert_fail "'$ROOT/bin/fm-gate.sh' --task SK-001 --repo '$g' --branch sk-001-vacuous --only 5" \
  "gate 5 blocks one whose test passes without the change"

# =========================================================================
# 4. no path edits skills/ without a pull request
# =========================================================================
assert_ok "'$FM' lint --repo '$ROOT'" "this repository has no path that writes a skill"

rogue() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$1"; chmod +x "$1"; }
rogue "$d/bin/rogue.sh" 'printf better > "$REPO/skills/worker/SKILL.md"'
assert_fail "'$FM' lint --repo '$d'" "a script that writes a skill fails the lint"
assert_contains "$("$FM" lint --repo "$d" 2>&1)" "rogue.sh" "and the lint names it"
rm -f "$d/bin/rogue.sh"

# the marker says "I am the one writer", not "I may write anywhere"
rogue "$d/bin/rogue.sh" '# fm:skills-writer
cp new.md "$REPO/skills/worker/SKILL.md"'
assert_fail "'$FM' lint --repo '$d'" "declaring the marker does not license skills/worker"
rm -f "$d/bin/rogue.sh"

rogue "$d/bin/rogue.sh" '# fm:skills-writer
cp -R staged/. "$REPO/skills/vendor/imported/"'
assert_ok "'$FM' lint --repo '$d'" "the declared writer may write skills/vendor"
rm -f "$d/bin/rogue.sh"

# board/ is scanned too: the board is the other thing that runs on this machine
printf 'await Bun.write("skills/worker/SKILL.md", body)\n' > "$d/board/server.ts"
assert_fail "'$FM' lint --repo '$d'" "the board cannot write a skill either"
rm -f "$d/board/server.ts"
assert_ok "'$FM' lint --repo '$d'" "the fixture is clean again"

# and .githooks/, which is the third thing that runs here - a hook fires on
# every commit, with no pull request anywhere near it. Hooks carry no .sh
# suffix, so a scan that filtered by extension would have missed the lot.
mkdir -p "$d/.githooks"
rogue "$d/.githooks/pre-commit" 'cp staged.md "$REPO/skills/worker/SKILL.md"'
assert_fail "'$FM' lint --repo '$d'" "a git hook that writes a skill fails the lint"
assert_contains "$("$FM" lint --repo "$d" 2>&1)" "pre-commit" "and the lint names it"
rm -f "$d/.githooks/pre-commit"
assert_ok "'$FM' lint --repo '$d'" "the fixture is clean once the hook is gone"

# =========================================================================
# 5. sync-skills imports one way
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

assert_fail "test -w '$d/skills/vendor/plain-skill/SKILL.md'" "an imported file is read-only"
assert_ok "test -f '$d/skills/vendor/MANIFEST.tsv'" "the import records where it came from"
assert_contains "$(cat "$d/skills/vendor/MANIFEST.tsv")" "plain-skill" "naming the skill it took"
assert_ok "grep -q '^\*$' '$d/skills/vendor/.gitignore'" "and skills/vendor is ignored by git"

# one way: a local edit is not a change to the source, it is a change to be lost
chmod u+w "$d/skills/vendor/plain-skill/SKILL.md"
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

# the assertion behind "never writes back", read off the script itself
assert_fail "grep -vE '^[[:space:]]*#' '$ROOT/bin/fm.sh' | grep -qE '(>|cp|mv|rm|chmod|sed -i)[^|]*\"\\\$SRC' " \
  "the script contains no write to the source"

# =========================================================================
# 6. the lint knows vendor syntax when it sees it
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

scrub "$d" "$g" "$src" "$single" "$empty"
finish
