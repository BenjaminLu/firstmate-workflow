#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/board.sh
. "$ROOT/tests/lib/board.sh"
XDG_CONFIG_HOME="$(safe_tmpdir)"; export XDG_CONFIG_HOME
# --- T-119: one task-id grammar, in the scripts and in the board ------------
# bin/fm-emit.sh holds the grammar every script sources; board/server.ts
# carries its twin, taskGrammar(), between the task-grammar markers, and
# serves it to the page in front of diagram.js. The block is lifted out as
# written and run against the shell functions over one table: ids, branches
# (SK-001's and #96's real ones among them), titles, keys and owned ids.
grammar_cases='T-117
SK-001
T-001
T-1
T-1170
SK-01
sk-001
SK-A
T-A
T-E6
t-117
X-117
T-117x

t-117-t-105-again-every-crew-round
sk-001-skill-update-firstmate
SK-001-caps
t-105-revert
t004-old
t-1170-other
t-117x
tt-117-x
revert-90-t-105-every-crew-round
board-fields
T-117: T-105 again
SK-001: skill-update: firstmate
Revert "T-105: every crew round"
T-1: too short
t-117: lower case
T-117 no colon'
grammar_pairs="$(printf '%s\t%s\n' \
  t-105-revert 'T-105: revert the crew sandbox' \
  t-117-t-105-again 'T-105: a title that disagrees' \
  board-fields 'T-116: the board shows each crew member' \
  board-fields 'Revert "T-116: the board"' \
  revert-90-t-105 'Revert "T-105: every crew round"' \
  sk-001-skill-update-firstmate 'SK-001: skill-update: firstmate' \
  hotfix-typo 'SK-002: a title alone')"
# a decision id's key, and an owned decision id, D-<project>-<key>-<n>
grammar_keys='SK001
T119
TA
T1
TSK001
SK01
SKA
X001
T'
grammar_owned='D-firstmate-workflow-SK001-1
D-firstmate-workflow-T119-2
D-example-app-TA-3
D-a-SK01-1
D-a-SKA-1
D-a-X001-1
D-a-T119-0
D-a-T119-01
D-Bad-T119-1
D-abcdefghijklmnopqrstuvwxy-T119-1
D-007
D-SK-001'
sh_grammar="$(
  # shellcheck source=bin/fm-emit.sh
  . "$ROOT/bin/fm-emit.sh"
  while IFS= read -r s; do
    printf '%s|%s|%s|%s|%s\n' "$s" "$(fm_task_is "$s" && echo y || echo n)" "$(fm_task_key "$s" || echo -)" \
      "$(fm_task_of_branch "$s" || echo -)" "$(fm_task_of_title "$s" || echo -)"
  done <<<"$grammar_cases"
  while IFS=$'\t' read -r b t; do printf '%s\t%s|%s\n' "$b" "$t" "$(fm_task_of_pr "$b" "$t" || echo -)"; done <<<"$grammar_pairs"
  while IFS= read -r k; do printf 'key %s|%s\n' "$k" "$(fm_task_of_key "$k" || echo -)"; done <<<"$grammar_keys"
  while IFS= read -r id; do
    if [[ "$id" =~ $FM_OWNED_ID ]]; then
      p="${BASH_REMATCH[1]}"; k="${BASH_REMATCH[2]}"; n="${BASH_REMATCH[3]}"
      printf 'owned %s|%s|%s|%s\n' "$id" "$p" "$(fm_task_of_key "$k" || echo -)" "$n"
    else printf 'owned %s|-\n' "$id"
    fi
  done <<<"$grammar_owned"
)"
gdir="$(safe_tmpdir)"
sed -n '/^\/\/ --- task grammar (T-119) ---$/,/^\/\/ --- end task grammar ---$/p' "$ROOT/board/server.ts" > "$gdir/grammar.ts"
assert_ok "grep -q 'const taskOfPr' '$gdir/grammar.ts'" "board/server.ts carries the grammar between its markers"
printf 'export { isTask, taskKey, taskOfBranch, taskOfTitle, taskOfPr, taskOfKey, ownerOf };\n' >> "$gdir/grammar.ts"
ts_grammar="$(G="$gdir/grammar.ts" CASES="$grammar_cases" PAIRS="$grammar_pairs" KEYS="$grammar_keys" OWNED="$grammar_owned" bun -e '
const g = require(process.env.G);
const or = (v) => v ?? "-";
const out = process.env.CASES.split("\n").map((s) =>
  [s, g.isTask(s) ? "y" : "n", or(g.taskKey(s)), or(g.taskOfBranch(s)), or(g.taskOfTitle(s))].join("|"));
for (const line of process.env.PAIRS.split("\n")) {
  const [b, t] = line.split("\t");
  out.push(`${b}\t${t}|${or(g.taskOfPr(b, t))}`);
}
for (const k of process.env.KEYS.split("\n")) out.push(`key ${k}|${or(g.taskOfKey(k))}`);
for (const id of process.env.OWNED.split("\n")) {
  const o = g.ownerOf(id);
  out.push(o ? `owned ${id}|${o.project}|${or(o.task)}|${o.n}` : `owned ${id}|-`);
}
// a key reads back as its task, for every task the table holds
for (const s of process.env.CASES.split("\n")) {
  const k = g.taskKey(s);
  if (k !== null && g.taskOfKey(k) !== s) out.push(`FAIL ${s} -> ${k} -> ${g.taskOfKey(k)}`);
}
console.log(out.join("\n"));
')"
assert_eq "$sh_grammar" "$ts_grammar" "the board's grammar and the scripts' agree on every id, branch, title and pull request"
assert_contains "$sh_grammar" "sk-001-skill-update-firstmate|n|-|SK-001|-" "SK-001's real branch is SK-001"
assert_contains "$sh_grammar" "SK-001: skill-update: firstmate|n|-|-|SK-001" "and its real title"
assert_contains "$sh_grammar" "t-105-revert|n|-|T-105|-" "#96's branch is T-105's"
assert_contains "$sh_grammar" "t-1170-other|n|-|T-1170|-" "a task number is read whole"
assert_contains "$sh_grammar" "SK-001|y|SK001|SK-001|-" "SK-001 is a task, keyed SK001"
assert_contains "$sh_grammar" "T-A|n|TA|-|-" "a fixture's T-A is no task but still a card key"
assert_contains "$sh_grammar" "$(printf 'board-fields\tRevert "T-116: the board"|-')" "a revert's title names no task"
assert_contains "$sh_grammar" "key SK001|SK-001" "the key SK001 reads back as SK-001"
assert_contains "$sh_grammar" "key SKA|-" "and SKA is no key"
assert_contains "$sh_grammar" "owned D-firstmate-workflow-SK001-1|firstmate-workflow|SK-001|1" \
  "an SK task's owned card id is owned by SK-001, in both grammars"
assert_contains "$sh_grammar" "owned D-example-app-TA-3|example-app|T-A|3" "a fixture's T-A card is still owned"
assert_contains "$sh_grammar" "owned D-a-SK01-1|-" "an SK key of two digits is no owned id"
rm -rf "$gdir"


safe_rm_rf "$XDG_CONFIG_HOME"
finish
