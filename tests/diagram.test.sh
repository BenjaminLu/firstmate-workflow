#!/usr/bin/env bash
# Decision diagrams. Three files per decision, none at all for a routine
# event, and a zh-CN page that is the zh-TW page with its words changed and
# its markup left alone.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

DG="$ROOT/bin/fm-diagram.sh"

# A scratch root, so nothing here writes into the repository the suite runs
# from and nothing here depends on what happens to be in state/ today.
#
# Every one of them is registered as it is made and removed at the end,
# because they were not: about a dozen were created here and four were
# rm -rf'd, so most of a suite's worth of trees was left in /tmp on every
# run. A cleanup written at each use site is a cleanup that is there on the
# branches somebody remembered.
#
# The register is a FILE and not a variable. newroot is always called as
# `R="$(newroot)"`, which runs it in a subshell, so a variable it appended to
# would be discarded along with the subshell and the whole thing would read
# as a cleanup while cleaning nothing up.
REG="$(mktemp)"
newroot() {  # newroot -> prints a fresh root with the dictionaries in it
  local d; d="$(mktemp -d)"
  printf '%s\n' "$d" >> "$REG"
  mkdir -p "$d/bin" "$d/i18n" "$d/state/pending" "$d/state/decisions" \
           "$d/design/diagrams" "$d/board/public"
  # errors are not swallowed here: a fixture that half-builds itself and says
  # nothing turns every assertion downstream of it into a report about the
  # fixture rather than about the generator
  cp "$ROOT/bin/fm-emit.sh" "$d/bin/"
  cp "$ROOT/i18n/ui.en.json" "$ROOT/i18n/ui.zh-TW.json" "$ROOT/i18n/tw2cn.tsv" "$d/i18n/"
  printf '%s' "$d"
}
# one exit path, so the server section does not have to take the trap away
# from the roots and remember to give it back
SERVER_PID=''
on_exit() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  while IFS= read -r r; do [ -z "$r" ] || rm -rf "$r"; done < "$REG"
  rm -f "$REG"
  return 0
}
trap on_exit EXIT

decision() {  # decision <root> <id> <json>
  printf '%s\n' "$3" > "$1/state/pending/$2.json"
}
# the tag stream of a page: everything between < and >, with the document's
# language normalised away. Two pages with the same tag stream differ only in
# their text nodes, which is the whole claim the zh-CN conversion makes.
tagstream() {
  tr '\n' ' ' < "$1" | grep -o '<[^>]*>' | sed 's/lang="[^"]*"/lang="_"/'
}
hancount() { perl -CSD -ne 'print if /\p{Han}/' "$1" | wc -l | tr -d ' '; }

# Run a command with a deadline and report 124 if it outlives it. The whole
# argument section below runs through here, because the failure it is written
# for is a loop that never ends: asserting on the exit code of a command that
# never exits hangs the suite, the gate, and eventually the runner, with
# nothing in the output to say which line did it. A hang has to read as a
# failing assertion.
bounded() {  # bounded <seconds> <cmd...> -> the command's status, or 124
  local secs="$1"; shift
  "$@" >/dev/null 2>&1 &
  local pid=$! ticks=0
  while kill -0 "$pid" 2>/dev/null; do
    ticks=$((ticks + 1))
    if [ "$ticks" -gt $((secs * 20)) ]; then
      kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124
    fi
    perl -e 'select(undef,undef,undef,0.05)' 2>/dev/null || sleep 1
  done
  wait "$pid" 2>/dev/null
}

assert_ok "test -x '$DG'" "the generator exists and is executable"

# ------------------------------------------------------ the argument surface
#
# Every flag here takes a value, and `shift 2` with nothing after the flag
# does not shift: it returns 1 and leaves $@ exactly where it was, so the
# option loop spins on the same argument for ever. `fm-diagram.sh --decision`
# was a busy loop that had to be killed from outside - in a file whose header
# spends five lines guaranteeing that a dispatched child never blocks its
# caller. Nothing in the suite had ever invoked the script with a flag and
# nothing after it, so the whole argument surface is covered from here.
R="$(newroot)"
assert_ok "test -x '$R/bin/fm-emit.sh' && test -s '$R/i18n/tw2cn.tsv'" \
  "the scratch root really has its fixtures in it"
for flag in --decision --event --wants --repo; do
  bounded 5 "$DG" "$flag"
  assert_eq "64" "$?" "[$flag] with no value is refused, not spun on"
done
bounded 5 "$DG" --repo "$R" --decision
assert_eq "64" "$?" "a trailing flag after a good one is refused too"
bounded 5 "$DG" --nonsense
assert_eq "64" "$?" "an unknown flag is refused"
bounded 5 "$DG" --repo "$R/nowhere" --decision D-001
assert_eq "64" "$?" "a --repo that is not a directory is refused"

help="$("$DG" -h 2>&1)"
assert_eq "0" "$?" "-h is help and exits clean"
for f in --decision --event --wants; do
  assert_contains "$help" "$f" "the help names $f"
done
assert_eq "$help" "$("$DG" --help 2>&1)" "--help says the same thing"

# --------------------------------------------------------------- the ruling
#
# Q8: only a decision the captain must rule on gets a drawing. bin/fm-emit.sh
# says what an event may be; bin/fm-diagram.sh says which of those the captain
# has to see. Two files, two lists, and this section is the only thing holding
# them together - so the one thing it must not do is compare a list with
# itself.
#
# Which is what it used to do. The suite parsed fm-emit's TYPES line; the
# generator parsed the same line the same way; every type therefore "had a
# ruling" by construction and no content of fm-emit.sh could turn it red. The
# generator now carries its ruling written out, and each direction is checked
# against the other program run for real.
emit_types() {  # the types fm-emit will accept, read from the file that declares them
  sed -n '/^TYPES=/,/"$/p' "$1" | tr ' \\"' '\n\n\n' | grep -E '^[a-z_]+$' | sort -u
}
ruling_of() {  # the types fm-diagram has ruled on, read from the file that declares them
  sed -n -e '/^RULED="/p' -e '/^ROUTINE="/,/[^\\]"$/p' "$1" \
    | tr ' \\"' '\n\n\n' | grep -E '^[a-z_]+$' | sort -u
}

R="$(newroot)"
"$DG" --wants decision_requested --repo "$R" >/dev/null 2>&1
assert_eq "0" "$?" "a decision the captain must rule on wants a diagram"

types="$(emit_types "$ROOT/bin/fm-emit.sh")"
ntypes="$(printf '%s\n' "$types" | wc -l | tr -d ' ')"
assert_ok "test '$ntypes' -ge 15" "fm-emit's type list was found ($ntypes types)"

# the parse is not taken on trust: fm-emit itself is run once per name, so a
# list that has stopped describing fm-emit's behaviour fails here first
refused=''
for t in $types; do
  FM_ROOT="$R" "$R/bin/fm-emit.sh" --actor test --type "$t" >/dev/null 2>&1 \
    || refused="$refused $t"
done
assert_eq "" "$refused" "fm-emit really does accept every type the parse found"
FM_ROOT="$R" "$R/bin/fm-emit.sh" --actor test --type not_an_event >/dev/null 2>&1
assert_ne "0" "$?" "and really does refuse one it did not"

# direction one: a type fm-emit can write that fm-diagram has no ruling for
unruled=''; drawn=''
for t in $types; do
  "$DG" --wants "$t" --repo "$R" >/dev/null 2>&1
  case "$?" in
    0) drawn="$drawn $t" ;;
    1) ;;
    *) unruled="$unruled $t" ;;
  esac
done
assert_eq "" "$unruled" "every event type fm-emit can write has a ruling here"
assert_eq " decision_requested" "$drawn" "and exactly one of them is drawn"

# direction two: a type ruled on here that fm-emit could not write. Set
# equality, between two lists read out of two different files.
assert_eq "$types" "$(ruling_of "$ROOT/bin/fm-diagram.sh")" \
  "fm-diagram's ruling covers fm-emit's list exactly, name for name"

# ...and the proof that the assertion above can go red, which is precisely
# what the version it replaces could not do. An fm-emit with one more type in
# it - a real one, it is run and it accepts the type - no longer matches.
mutd="$(mktemp -d)"; mut="$mutd/fm-emit.sh"
sed 's/^TYPES="greenlit/TYPES="a_brand_new_type greenlit/' "$ROOT/bin/fm-emit.sh" > "$mut"
chmod +x "$mut"
FM_ROOT="$R" "$mut" --actor test --type a_brand_new_type >/dev/null 2>&1
assert_eq "0" "$?" "the mutant is a real fm-emit that writes a type nobody has ruled on"
assert_contains "$(emit_types "$mut")" "a_brand_new_type" "and the parse sees it"
assert_ne "$(emit_types "$mut")" "$(ruling_of "$ROOT/bin/fm-diagram.sh")" \
  "so a type added to fm-emit tomorrow fails this suite rather than going undrawn"
rm -rf "$mutd"

"$DG" --wants not_an_event --repo "$R" >/dev/null 2>&1
assert_eq "64" "$?" "a type with no ruling is an error, not a silent no"

# --event is the entry point a caller can use blindly: routine in, nothing
# written, and a zero exit so the caller does not have to know the ruling
decision "$R" D-001 '{"id":"D-001","task":"T-004","kind":"merge","title":"x"}'
for routine in dispatched commit_pushed gate_passed merged; do
  "$DG" --event "$routine" --decision D-001 --repo "$R" >/dev/null 2>&1
  assert_eq "0" "$?" "a $routine event exits clean"
done
assert_eq "" "$(find "$R/board/public/diagrams" -name 'D-001.*' 2>/dev/null)" \
  "and four routine events drew nothing"
"$DG" --event decision_requested --decision D-001 --repo "$R" >/dev/null 2>&1
assert_eq "3" "$(find "$R/board/public/diagrams" -name 'D-001.*' 2>/dev/null | wc -l | tr -d ' ')" \
  "the decision event drew all three"

# ------------------------------------------------------ the three languages
R="$(newroot)"
decision "$R" D-007 '{"id":"D-007","task":"T-004","kind":"merge","title":"合併 T-004 的程式碼","pr":9}'
out="$("$DG" --decision D-007 --repo "$R" 2>&1)"
assert_eq "0" "$?" "a merge decision renders"
assert_contains "$out" "D-007.en.html" "it names what it wrote"

en="$R/board/public/diagrams/D-007.en.html"
tw="$R/board/public/diagrams/D-007.zh-TW.html"
cnf="$R/board/public/diagrams/D-007.zh-CN.html"
for f in "$en" "$tw" "$cnf"; do
  assert_ok "test -s '$f'" "$(basename "$f") exists and is not empty"
done

enb="$(cat "$en")"; twb="$(cat "$tw")"; cnb="$(cat "$cnf")"
assert_contains "$enb" "branch has commits"  "the English page takes its words from ui.en.json"
assert_contains "$twb" "分支有 commit"        "the zh-TW page takes its words from ui.zh-TW.json"
assert_lacks    "$enb" "分支有 commit"        "and neither page carries the other's"
assert_contains "$enb" 'lang="en"'            "the English page says so"
assert_contains "$twb" 'lang="zh-TW"'         "the zh-TW page says so"
assert_contains "$cnb" 'lang="zh-CN"'         "the zh-CN page says so"
assert_contains "$enb" "#9"                   "the pull request is on the card"
assert_contains "$enb" "T-004"                "so is the task"

# the seven gates, because this one is a merge
for n in 1 2 3 4 5 6 7; do
  assert_contains "$enb" "$(jq -r ".gate$n" "$ROOT/i18n/ui.en.json")" "gate $n is on the merge card"
done
assert_contains "$enb" "Merge into main" "a merge card offers the merge"

# ------------------------------------------- zh-CN is the table, not a model
assert_contains "$cnb" "闸门"   "zh-CN converts the vocabulary (閘門)"
assert_lacks    "$cnb" "閘門"   "and leaves none of the zh-TW form behind"
assert_contains "$cnb" "代码"   "the captain's own title is converted too (程式碼)"
assert_lacks    "$cnb" "程式碼" "and none of it is left in zh-TW"
assert_contains "$cnb" "已合并" "已合併 becomes 已合并"
assert_ok "test $(hancount "$cnf") -gt 0" "the zh-CN page really is Chinese"

# the two Chinese pages differ in their words and in the document language,
# and in nothing else
assert_eq "$(tagstream "$tw")" "$(tagstream "$cnf")" \
  "zh-CN changes text nodes only: the tag stream is unchanged"
assert_ne "$twb" "$cnb" "but the pages are not the same page"

# and the scope of that is not an accident of today's table holding only CJK.
# A row that also matches markup - which nothing stops someone adding - must
# still leave the markup alone.
R2="$(newroot)"
printf 'class\tklass\n%s\t%s\n' "程式碼" "代码" > "$R2/i18n/tw2cn.tsv"
decision "$R2" D-007 '{"id":"D-007","task":"T-004","kind":"merge","title":"合併 T-004 的程式碼","pr":9}'
"$DG" --decision D-007 --repo "$R2" >/dev/null 2>&1
cn2="$R2/board/public/diagrams/D-007.zh-CN.html"
assert_contains "$(cat "$cn2")" 'class="answers"' "an ASCII table row does not rewrite an attribute"
assert_lacks    "$(cat "$cn2")" 'klass'           "nor any other markup"
assert_contains "$(cat "$cn2")" "代码"            "while the text node it sits next to still converts"

# and the other end of "everything between < and > is markup": a tag ends at
# the first > that is not inside an attribute value. Ending it at the first >
# full stop handed the tail of the attribute to the converter as if it were a
# text node - and an authored fragment is the one input on this path that
# this program did not write, so a > inside an attribute is exactly where it
# would arrive from.
R="$(newroot)"
printf '%s\n' '<svg><text data-note="a > 程式碼 b">唯讀的檔案</text></svg>' \
  > "$R/design/diagrams/D-033.zh-TW.html"
printf '%s\n' '<svg><text data-note="a > b">read only</text></svg>' \
  > "$R/design/diagrams/D-033.en.html"
decision "$R" D-033 '{"id":"D-033","task":"T-099","kind":"choice","title":"x"}'
"$DG" --decision D-033 --repo "$R" >/dev/null 2>&1
cn33="$(cat "$R/board/public/diagrams/D-033.zh-CN.html" 2>/dev/null)"
assert_contains "$cn33" 'data-note="a > 程式碼 b"' \
  "a > inside a quoted attribute does not end the tag, so the rest of it is not converted"
assert_contains "$cn33" "只读的文件" "while the text node beside it converts as it should"

# ----------------------------------------- one table, two appliers, one rule
#
# board/public/index.html already puts zh-TW through this table:
#
#   const cn = (x) => DICT.tw2cn.reduce((acc, p) => acc.split(p[0]).join(p[1]), x)
#
# and fm-diagram does it again, in awk, which is worth an answer. They are
# not interchangeable: cn() converts a dictionary VALUE before it has met any
# markup - nothing it is handed could contain a tag - and fm-diagram converts
# a finished DOCUMENT, which it has to, because an authored drawing out of
# design/diagrams/ carries zh-TW that was never a dictionary value and so was
# never converted on the way in. Two units of work.
#
# What could quietly drift is the rule they share, so the rule is pinned
# here: the real cn(), lifted out of the page rather than retyped into this
# file, against the real generator run end to end over a drawing whose text
# nodes are every value in the zh-TW dictionary. The day the two stop
# agreeing is the day this goes red, rather than the day a reader notices the
# board and the diagram spelling the same word two ways.
assert_ok "command -v bun >/dev/null 2>&1" "bun is installed, so nothing below is skipped"

R="$(newroot)"
# jq's keys are sorted by codepoint and so is JavaScript's .sort(), which is
# what lets the two lists be compared position by position. `sort` is not
# used: its collation is locale-dependent and laneQueued/log would order one
# way here and another way in the probe.
keys="$(jq -r 'keys[]' "$ROOT/i18n/ui.zh-TW.json")"
# an en file beside it, because a tier authored for one language and not the
# other is refused now - and the corpus is a zh-TW drawing by nature
printf '<p>the corpus, in English</p>\n' > "$R/design/diagrams/D-031.en.html"
: > "$R/design/diagrams/D-031.zh-TW.html"
for k in $keys; do
  jq -r --arg k "$k" '"<p>" + .[$k] + "</p>"' "$ROOT/i18n/ui.zh-TW.json" \
    >> "$R/design/diagrams/D-031.zh-TW.html"
done
decision "$R" D-031 '{"id":"D-031","task":"T-004","kind":"choice","title":"x"}'
"$DG" --decision D-031 --repo "$R" >/dev/null 2>&1
# the drawing's own nodes, in order. The card's own paragraph carries a class
# and so is not one of them.
byawk="$(grep -o '<p>[^<]*</p>' "$R/board/public/diagrams/D-031.zh-CN.html" \
  | sed 's|<p>||;s|</p>||')"
assert_eq "$(printf '%s\n' "$keys" | wc -l | tr -d ' ')" \
          "$(printf '%s\n' "$byawk" | wc -l | tr -d ' ')" \
  "every dictionary value reached the generated page as a text node"

# the board's own cn() and its table, lifted rather than retyped. Two callers
# now, so it is a function: a second copy of the lift is a second thing that
# could stop being the page's cn() without anyone noticing.
cn_prelude() {
  printf '%s\n' 'const fs = require("fs");'
  printf '%s\n' 'const rows = fs.readFileSync(process.env.TBL, "utf8").split("\n")'
  printf '%s\n' '  .filter(l => l && l[0] !== "#" && l.includes("\t"))'
  printf '%s\n' '  .map(l => [l.slice(0, l.indexOf("\t")), l.slice(l.indexOf("\t") + 1)]);'
  printf '%s\n' 'const DICT = { tw2cn: rows };'
  grep -h 'const cn = ' "$ROOT/board/public/index.html"
}

probed="$(mktemp -d)"
{
  cn_prelude
  printf '%s\n' 'const d = JSON.parse(fs.readFileSync(process.env.TW, "utf8"));'
  printf '%s\n' 'process.stdout.write(Object.keys(d).sort().map(k => cn(d[k])).join("\n"));'
} > "$probed/cn.js"
assert_eq "1" "$(grep -c 'const cn = ' "$ROOT/board/public/index.html" | tr -d ' ')" \
  "the page declares cn() exactly once, so there is one of it to lift"
assert_ok "grep -q 'DICT.tw2cn' '$probed/cn.js'" "the board's own cn() was lifted into the probe"
bycn="$(TBL="$ROOT/i18n/tw2cn.tsv" TW="$ROOT/i18n/ui.zh-TW.json" bun run "$probed/cn.js" 2>&1)"
assert_eq "$bycn" "$byawk" \
  "the board's cn() and the generator's awk agree on every value in the dictionary"

# ...and the one shape that corpus cannot hold. Every node above is one line,
# because the test wrote it that way; cn() reduces over a whole string and
# the awk's conv() runs per line, so the unit of work is the only place the
# two could part company and the fixture excluded it by construction.
#
# They do not part company, and the reason is worth pinning rather than
# arguing: a match can only be lost at a line break if the row's own text
# spans one, and tests/i18n.test.sh fails the table if any row is not exactly
# two tab-separated columns. So this asserts the agreement on a node that
# wraps mid-phrase - 程式碼 split between 程式 and 碼, where the whole-string
# and per-line readings would differ if anything could make them.
wrapped="$(mktemp -d)"
printf '%s' '前面的程式
碼在後面，還有唯讀的檔案' > "$wrapped/node.txt"
R="$(newroot)"
{ printf '<p>'; cat "$wrapped/node.txt"; printf '</p>\n'; } > "$R/design/diagrams/D-032.zh-TW.html"
printf '<p>a node that wraps</p>\n' > "$R/design/diagrams/D-032.en.html"
decision "$R" D-032 '{"id":"D-032","task":"T-099","kind":"choice","title":"x"}'
"$DG" --decision D-032 --repo "$R" >/dev/null 2>&1
gotwrap="$(perl -0777 -ne 'print $1 if m{<div class="drawn">\s*<p>(.*?)</p>}s' \
  "$R/board/public/diagrams/D-032.zh-CN.html" 2>/dev/null)"
{ cn_prelude
  printf '%s\n' 'process.stdout.write(cn(fs.readFileSync(process.env.NODE, "utf8")));'
} > "$wrapped/cn2.js"
wantwrap="$(TBL="$ROOT/i18n/tw2cn.tsv" NODE="$wrapped/node.txt" bun run "$wrapped/cn2.js" 2>&1)"
assert_eq "2" "$(printf '%s\n' "$gotwrap" | wc -l | tr -d ' ')" \
  "the wrapped node reached the page still wrapped, which is what makes this a test"
assert_eq "$wantwrap" "$gotwrap" \
  "and the two appliers agree on a text node that spans a line break"
rm -rf "$probed" "$wrapped"

# --------------------------------------------- an authored drawing wins
R="$(newroot)"
printf '<svg class="authored"><text>%s</text></svg>\n' "唯讀的檔案" > "$R/design/diagrams/D-011.zh-TW.html"
printf '<svg class="authored"><text>drawn by hand</text></svg>\n' > "$R/design/diagrams/D-011.en.html"
printf '<svg class="by-task"></svg>\n' > "$R/design/diagrams/T-004.html"
decision "$R" D-011 '{"id":"D-011","task":"T-004","kind":"choice","title":"which schema"}'
"$DG" --decision D-011 --repo "$R" >/dev/null 2>&1
assert_contains "$(cat "$R/board/public/diagrams/D-011.en.html")" "drawn by hand" \
  "design/diagrams/<id>.<lang>.html is used when it exists"
assert_lacks "$(cat "$R/board/public/diagrams/D-011.en.html")" "by-task" \
  "and the decision's own drawing beats the task's"
assert_contains "$(cat "$R/board/public/diagrams/D-011.zh-CN.html")" "只读的文件" \
  "an authored drawing goes through the table like everything else"

# a decision with no drawing of its own falls back to the task's
decision "$R" D-012 '{"id":"D-012","task":"T-004","kind":"choice","title":"which schema"}'
"$DG" --decision D-012 --repo "$R" >/dev/null 2>&1
assert_contains "$(cat "$R/board/public/diagrams/D-012.en.html")" "by-task" \
  "design/diagrams/<task>.html is the fallback"

# and one with neither still renders: the frame is not the drawing
decision "$R" D-013 '{"id":"D-013","task":"T-099","kind":"choice","title":"pick one"}'
"$DG" --decision D-013 --repo "$R" >/dev/null 2>&1
d13="$(cat "$R/board/public/diagrams/D-013.en.html" 2>/dev/null)"
assert_contains "$d13" "Choose A" "a choice with no drawing still offers the choice"
assert_lacks    "$d13" "$(jq -r .gate5 "$ROOT/i18n/ui.en.json")" "and carries no merge checklist"

# ----------------------------------- a drawing authored unevenly is refused
#
# The lookup used to run per language: <id>.<lang>, <id>, <task>.<lang>,
# <task>, resolved independently three times. Every rung of that ladder can
# succeed for one language and fail for another, and the only signal was the
# rendered page - three files written, exit 0, nothing said.
#
# So the unit is the tier, decided once for the decision, and the fixtures
# below are the two shapes that distinguish a tier check from a per-language
# one. The second is the one a pairwise <id>.en/<id>.zh-TW existence check
# walks straight past, because no file is missing anywhere in it.
R="$(newroot)"
decision "$R" D-071 '{"id":"D-071","task":"T-004","kind":"choice","title":"which schema"}'
printf '<svg class="only-en"></svg>\n' > "$R/design/diagrams/D-071.en.html"
msg="$("$DG" --decision D-071 --repo "$R" 2>&1)"
assert_eq "65" "$?" "a decision drawn for en and not zh-TW is refused, with a number of its own"
assert_contains "$msg" "zh-TW" "and the refusal names the language nothing answers"
assert_eq "" "$(find "$R/board/public" -name 'D-071.*' 2>/dev/null)" "and nothing at all was written"
# the same directory one file later: a refusal has to be a refusal of THIS
# tree, not of the idea of authored drawings
printf '<svg class="now-tw"></svg>\n' > "$R/design/diagrams/D-071.zh-TW.html"
"$DG" --decision D-071 --repo "$R" >/dev/null 2>&1
assert_eq "0" "$?" "and the moment the other language is drawn it renders"
assert_contains "$(cat "$R/board/public/diagrams/D-071.zh-TW.html")" "now-tw" \
  "with each language showing its own drawing"

# the shape with no file missing: the decision drawn in English, the task
# drawn in zh-TW. Every language is answered - by two different pictures.
R="$(newroot)"
decision "$R" D-072 '{"id":"D-072","task":"T-004","kind":"choice","title":"which schema"}'
printf '<svg class="decision-en"></svg>\n' > "$R/design/diagrams/D-072.en.html"
printf '<svg class="task-tw"></svg>\n'     > "$R/design/diagrams/T-004.zh-TW.html"
"$DG" --decision D-072 --repo "$R" >/dev/null 2>&1
assert_eq "65" "$?" "a decision's drawing in one language and the task's in another is refused too"
assert_eq "" "$(find "$R/board/public" -name 'D-072.*' 2>/dev/null)" "and it too wrote nothing"

# the task's drawings are a tier and are held to the same rule, or half the
# ladder keeps the old behaviour
R="$(newroot)"
decision "$R" D-073 '{"id":"D-073","task":"T-004","kind":"choice","title":"x"}'
printf '<svg class="task-en"></svg>\n' > "$R/design/diagrams/T-004.en.html"
"$DG" --decision D-073 --repo "$R" >/dev/null 2>&1
assert_eq "65" "$?" "an uneven set of the TASK's drawings is refused the same way"
assert_eq "" "$(find "$R/board/public" -name 'D-073.*' 2>/dev/null)" "and wrote nothing either"

# but the rule is about the tier answering every language, not about there
# being three files: one wordless drawing answers all of them
R="$(newroot)"
decision "$R" D-074 '{"id":"D-074","task":"T-004","kind":"choice","title":"x"}'
printf '<svg class="wordless"></svg>\n' > "$R/design/diagrams/D-074.html"
"$DG" --decision D-074 --repo "$R" >/dev/null 2>&1
assert_eq "0" "$?" "one file with no words in it serves every language"
for l in en zh-TW zh-CN; do
  assert_contains "$(cat "$R/board/public/diagrams/D-074.$l.html" 2>/dev/null)" "wordless" \
    "and the $l page shows it"
done

# a hand-written zh-CN file answers no language at all - zh-CN is derived,
# never authored - so a tier holding only one cannot serve anybody. The
# README's "never write a zh-CN file" gets a number rather than a shrug.
R="$(newroot)"
decision "$R" D-075 '{"id":"D-075","task":"T-099","kind":"choice","title":"x"}'
printf '<svg class="hand-cn"></svg>\n' > "$R/design/diagrams/D-075.zh-CN.html"
"$DG" --decision D-075 --repo "$R" >/dev/null 2>&1
assert_eq "65" "$?" "a hand-written zh-CN file is refused rather than quietly ignored"

# and a half-drawn decision does not fall through to the task's drawing: if
# the decision has any file at all, the decision is the tier
R="$(newroot)"
decision "$R" D-076 '{"id":"D-076","task":"T-004","kind":"choice","title":"x"}'
printf '<svg class="half"></svg>\n'     > "$R/design/diagrams/D-076.en.html"
printf '<svg class="complete"></svg>\n' > "$R/design/diagrams/T-004.html"
"$DG" --decision D-076 --repo "$R" >/dev/null 2>&1
assert_eq "65" "$?" "a half-drawn decision is refused rather than served the task's complete drawing"

# ---------------------------------------------------------------- refusals
R="$(newroot)"
for bad in "../../etc/passwd" "D-1234567" "T-004" "D-" "" ; do
  "$DG" --decision "$bad" --repo "$R" >/dev/null 2>&1
  assert_eq "64" "$?" "[$bad] is refused as a decision id"
done
assert_eq "" "$(find "$R/board/public" -name '*.html' 2>/dev/null)" "and nothing was written on the way"
"$DG" --decision D-404 --repo "$R" >/dev/null 2>&1
assert_eq "66" "$?" "a decision with no file is a missing input, not a crash"

# --event names a type the captain must rule on, but says nothing about which
# decision. That is the caller's mistake and it gets a number, not a card with
# a hole where the id goes.
"$DG" --event decision_requested --repo "$R" >/dev/null 2>&1
assert_eq "64" "$?" "--event on a drawn type still needs a decision"
assert_eq "" "$(find "$R/board/public" -name '*.html' 2>/dev/null)" "and drew nothing without one"

# An id that is supplied is checked wherever it is supplied. The shape used
# to be checked only on the path that draws, so a misspelled id was a refusal
# for decision_requested and a silent exit 0 for the other seventeen types -
# invisible on seventeen of eighteen calls, and seventeen of eighteen is
# where a typo lives longest, because nothing downstream of a routine event
# ever looks at the id again.
decision "$R" D-002 '{"id":"D-002","task":"T-004","kind":"choice","title":"x"}'
for bad in "D-oo2" "../../etc/passwd" "D-1234567" "T-004"; do
  "$DG" --event gate_passed --decision "$bad" --repo "$R" >/dev/null 2>&1
  assert_eq "64" "$?" "[$bad] is refused on a routine event too, not only on the drawn one"
done
"$DG" --event gate_passed --decision D-002 --repo "$R" >/dev/null 2>&1
assert_eq "0" "$?" "while a real id on a routine event is still a clean no-op"
assert_eq "" "$(find "$R/board/public/diagrams" -name 'D-002.*' 2>/dev/null)" \
  "which is a no-op because it drew nothing, not because it refused"

# A decision file that is not JSON. jq answers nothing for every field, so
# the card used to render with no task, no pull request and the dictionary's
# placeholder for a title - a blank card delivered with exit 0, which is the
# same failure as the missing dictionary one section down: an input the
# script cannot read must not come back looking like one it could.
for broken in '{"id":"D-061",' '' 'not json at all'; do
  printf '%s' "$broken" > "$R/state/pending/D-061.json"
  "$DG" --decision D-061 --repo "$R" >/dev/null 2>&1
  assert_eq "66" "$?" "a decision file that is not json is a bad input, not a blank card"
  assert_eq "" "$(find "$R/board/public" -name 'D-061.*' 2>/dev/null)" \
    "and nothing was rendered from it"
done
# valid JSON that is not an object is the same kind of unreadable: .task on a
# list is an error, and jq -e . alone would have called it good
printf '%s' '["D-061"]' > "$R/state/pending/D-061.json"
"$DG" --decision D-061 --repo "$R" >/dev/null 2>&1
assert_eq "66" "$?" "json that is not an object is refused too"
# and the guard is not so tight it refuses a real file: the same path renders
# once the file is an object again
printf '%s' '{"id":"D-061","task":"T-004","kind":"choice","title":"pick one"}' \
  > "$R/state/pending/D-061.json"
"$DG" --decision D-061 --repo "$R" >/dev/null 2>&1
assert_eq "0" "$?" "while a readable decision file still renders"

# The output directory is the one thing here that is written rather than
# read, and a tree where it cannot be made says so with the write number
# rather than three empty redirects and a zero.
ro="$(newroot)"
decision "$ro" D-062 '{"id":"D-062","task":"T-004","kind":"merge","title":"merge it"}'
: > "$ro/board/public/diagrams"   # a file standing where the directory goes
"$DG" --decision D-062 --repo "$ro" >/dev/null 2>&1
assert_eq "73" "$?" "an output directory that cannot be made is a write failure, with its own number"
assert_ok "test -f '$ro/board/public/diagrams'" "and the thing in its way was left alone"
rm -rf "$ro"

# ------------------------------------------- the inputs it cannot do without
#
# A dictionary that is not there used to render every key as itself and exit
# 0 - a whole page reading laneQueued, gate3, chooseA, delivered as a
# success, which is a broken install that looks exactly like a working one. A
# missing KEY still renders as its key, on purpose: that is a bug report on
# the page, and the page is where anyone would see it. A missing FILE is an
# install that has not finished and has to say so with a number.
bare="$(mktemp -d)"
mkdir -p "$bare/i18n" "$bare/state/pending" "$bare/board/public"
decision "$bare" D-041 '{"id":"D-041","task":"T-004","kind":"merge","title":"merge it"}'
# the table comes first on purpose. It was always checked, so a root missing
# it refused even before this - which would make every assertion below pass
# for the wrong reason if the dictionaries were the files added last.
have=''
for one in '' tw2cn.tsv ui.en.json ui.zh-TW.json; do
  [ -z "$one" ] || { cp "$ROOT/i18n/$one" "$bare/i18n/"; have="$have $one"; }
  "$DG" --decision D-041 --repo "$bare" >/dev/null 2>&1
  rc=$?
  if [ "$one" = ui.zh-TW.json ]; then
    assert_eq "0" "$rc" "with all three files present it renders"
  else
    assert_eq "66" "$rc" "with only[$have] it is a missing input, not a page of raw keys"
    assert_eq "" "$(find "$bare/board/public" -name '*.html' 2>/dev/null)" \
      "and nothing half-rendered was left behind"
  fi
done
rm -rf "$bare"

# A dictionary that is THERE and cannot be read is the same failure wearing a
# file. jq answers nothing for a file it cannot parse, load_dict reads no
# rows, and every key on the page renders as itself - the page of raw keys
# again, out of a root where all three files are present. Both dictionaries,
# because a check on one of them is a check on neither.
for which in ui.en.json ui.zh-TW.json; do
  junk="$(newroot)"
  printf '%s' '{"laneQueued": ' > "$junk/i18n/$which"
  decision "$junk" D-043 '{"id":"D-043","task":"T-004","kind":"merge","title":"merge it"}'
  "$DG" --decision D-043 --repo "$junk" >/dev/null 2>&1
  assert_eq "66" "$?" "a $which that is not json is a bad input, not a page of raw keys"
  assert_eq "" "$(find "$junk/board/public" -name '*.html' 2>/dev/null)" \
    "and nothing half-rendered was left behind"
  # valid json of the wrong shape reads no rows just as surely
  printf '%s' '["laneQueued"]' > "$junk/i18n/$which"
  "$DG" --decision D-043 --repo "$junk" >/dev/null 2>&1
  assert_eq "66" "$?" "a $which that is json but not an object is refused too"
  rm -rf "$junk"
done

# the other half of that contract: a key the dictionary does not answer is
# not a missing input, it is a visible hole with the key's name on it
holey="$(newroot)"
jq 'del(.laneQueued)' "$ROOT/i18n/ui.en.json" > "$holey/i18n/ui.en.json"
decision "$holey" D-042 '{"id":"D-042","task":"T-004","kind":"choice","title":"pick one"}'
"$DG" --decision D-042 --repo "$holey" >/dev/null 2>&1
assert_eq "0" "$?" "a dictionary with one key missing still renders"
assert_contains "$(cat "$holey/board/public/diagrams/D-042.en.html" 2>/dev/null)" "laneQueued" \
  "and the key itself shows through, which is the bug report"

# the other side of that line. A key the dictionary answers with the empty
# string is a key it answered, and it gets the empty string. The test above
# is the only one that could have caught the confusion and it cannot: a
# missing key and a key blanked on purpose both render as the key's name
# under `-n "${!n-}"`, and only one of them is a bug worth reporting on the
# page.
blank="$(newroot)"
jq '.laneQueued = ""' "$ROOT/i18n/ui.en.json" > "$blank/i18n/ui.en.json"
decision "$blank" D-044 '{"id":"D-044","task":"T-004","kind":"choice","title":"pick one"}'
"$DG" --decision D-044 --repo "$blank" >/dev/null 2>&1
assert_eq "0" "$?" "a dictionary with one value deliberately blank still renders"
assert_lacks "$(cat "$blank/board/public/diagrams/D-044.en.html" 2>/dev/null)" "laneQueued" \
  "and an empty value renders empty, not as the name of the key that holds it"

# --repo at a tree with no bin/ in it. The ruling used to be read out of
# bin/fm-emit.sh, which meant a root without that file fell back to
# "decision_requested is the only event there is" - so every ROUTINE type
# died 64, and the entry point documented as usable blindly inverted its
# contract at exactly the moment the list could not be read. The ruling is
# written into fm-diagram now and there is nothing left to fall back from.
nb="$(newroot)"
rm -f "$nb/bin/fm-emit.sh"
decision "$nb" D-051 '{"id":"D-051","task":"T-004","kind":"merge","title":"merge it"}'
"$DG" --event gate_passed --decision D-051 --repo "$nb" >/dev/null 2>&1
assert_eq "0" "$?" "a routine event is still routine in a tree with no bin/"
assert_eq "" "$(find "$nb/board/public/diagrams" -name 'D-051.*' 2>/dev/null)" \
  "and still draws nothing"
"$DG" --event decision_requested --decision D-051 --repo "$nb" >/dev/null 2>&1
assert_eq "3" "$(find "$nb/board/public/diagrams" -name 'D-051.*' 2>/dev/null | wc -l | tr -d ' ')" \
  "while a decision still draws all three"

# a captain's title is captain-supplied text, so it reaches the page as text.
#
# All four characters are asserted, and not only the < that the failure
# arrived as. The escape was written as ${s//</&lt;}, and bash 5.2 turned
# patsub_replacement on by default: an unquoted & in the replacement means
# the text the pattern matched. Under it & -> &amp; still came out right
# (the match IS an &) while <, > and " all came out as <lt; >gt; "quot;. So
# a suite that checks one of the four can be green on a machine where three
# of them are broken - which is what happened: this ran green on bash 3.2
# and red on the runner, with the one assertion below it reporting ok
# because <lt;script>gt; contains no script tag either.
R="$(newroot)"
decision "$R" D-014 '{"id":"D-014","task":"T-004","kind":"choice","title":"<script>alert(1)</script> & <b> \"q\""}'
"$DG" --decision D-014 --repo "$R" >/dev/null 2>&1
d14="$(cat "$R/board/public/diagrams/D-014.en.html" 2>/dev/null)"
assert_contains "$d14" "&lt;script&gt;" "a title with markup in it is escaped"
assert_contains "$d14" "&amp;"          "and its ampersand is escaped"
assert_contains "$d14" "&quot;q&quot;"  "and its quotes are escaped"
assert_lacks    "$d14" "<script>"       "and no script tag reaches the page"
# the exact shape the 5.2 expansion produced, pinned so it cannot come back
# wearing the old assertions' approval
for wrong in '<lt;' '>gt;' '"quot;'; do
  assert_lacks "$d14" "$wrong" "and no half-escape [$wrong] is on the page"
done

# an answered decision is still drawable: the board may show the card while
# the merge it asked for is running
R="$(newroot)"
printf '%s\n' '{"id":"D-015","task":"T-004","kind":"merge","title":"merge it","pr":3}' \
  > "$R/state/decisions/D-015.json"
"$DG" --decision D-015 --repo "$R" >/dev/null 2>&1
assert_eq "0" "$?" "a decision that has been answered still renders"

# -------------------------------------------------------------- the embed
#
# The board points an iframe at the file and moves that src when the reader
# changes language. board/public/diagram.js holds the one function that says
# where a diagram lives, so the page and the swap cannot disagree.
# The three assertions below are PRESENCE checks and nothing more: they see a
# substring in the page's source text. `DIAGRAM.mount` appearing in
# index.html does not prove it is called with the new language, on the right
# element, or that its promise is handled - all three would pass on a page
# that called it with the previous lang. What executes is the probe under
# them, which runs the module itself; the click handler that calls it has no
# executing test in this suite. Read these as "the wiring is still spelled
# here", not as "the wiring works".
page="$(cat "$ROOT/board/public/index.html")"
assert_contains "$page" "diagram.js"      "index.html still names diagram.js (presence)"
assert_contains "$page" "DIAGRAM.embed"   "and still names DIAGRAM.embed on the card (presence)"
assert_contains "$page" "DIAGRAM.mount"   "and still names DIAGRAM.mount for the swap (presence)"
assert_ok "test -f '$ROOT/board/public/diagram.js'" "the module is there"

probe="$(mktemp -d)/embed.js"
cat > "$probe" <<'JS'
// A DOM small enough to read. The module is loaded from the repository, so
// what is asserted here is the file the board serves.
const D = require(process.env.MOD);
const fail = (m) => { console.log("FAIL " + m); process.exitCode = 1; };

if (D.src("D-007", "en") !== "diagrams/D-007.en.html") fail("en src");
if (D.src("D-007", "zh-TW") !== "diagrams/D-007.zh-TW.html") fail("zh-TW src");
if (D.src("D-007", "zh-CN") !== "diagrams/D-007.zh-CN.html") fail("zh-CN src");
if (D.src("D-007", "kl-KL") !== "diagrams/D-007.zh-TW.html") fail("unknown language falls back");
if (D.src("../../etc/passwd", "en") !== "") fail("a non-decision has no diagram");
if (!D.embed("D-007").includes('data-decision="D-007"')) fail("embed names its decision");
if (D.embed("nope") !== "") fail("embed of a non-decision is nothing");

const frame = (id) => {
const attrs = { "data-decision": id };
return {
  dataset: { decision: id }, gone: false,
  getAttribute: (k) => (k in attrs ? attrs[k] : null),
  setAttribute: (k, v) => { attrs[k] = v; },
  removeAttribute: (k) => { delete attrs[k]; },
  remove() { this.gone = true; },
  attrs,
};
};
const root = (fs) => ({ querySelectorAll: () => fs });

(async () => {
const a = frame("D-007"), b = frame("D-008");
const seen = [];
const fetcher = async (u) => { seen.push(u); return { ok: !u.includes("D-008") }; };

let n = await D.mount(root([a, b]), "zh-TW", fetcher);
if (n !== 1) fail("one of the two mounted, got " + n);
if (a.attrs.src !== "diagrams/D-007.zh-TW.html") fail("mounted at the zh-TW file");
if ("hidden" in a.attrs) fail("a mounted iframe is shown");
if (!b.gone) fail("a decision with no diagram leaves no iframe behind");

// the swap: same iframe, new language, new src
n = await D.mount(root([a]), "en", fetcher);
if (n !== 1) fail("the swap moved it");
if (a.attrs.src !== "diagrams/D-007.en.html") fail("swapped to the English file, got " + a.attrs.src);

// and asking for the language it already shows moves nothing
n = await D.mount(root([a]), "en", fetcher);
if (n !== 0) fail("re-mounting the same language is a no-op");

// a fetcher that throws must not take the board down with it
const c = frame("D-009");
n = await D.mount(root([c]), "en", async () => { throw new Error("offline"); });
if (n !== 0 || !c.gone) fail("an unreachable probe hides the diagram rather than throwing");
console.log("embed ok");
})();
JS
MOD="$ROOT/board/public/diagram.js" bun run "$probe" > "$probe.out" 2>&1
rc=$?
assert_eq "0" "$rc" "the embed module behaves"
assert_contains "$(cat "$probe.out" 2>/dev/null)" "embed ok" "and said so"
[ "$rc" = 0 ] || cat "$probe.out"
rm -rf "$(dirname "$probe")"

# The other end of the same claim: the url the module builds is the url the
# board answers. The generator writes into board/public/diagrams and the
# server already serves that tree, so nothing had to be added to the server -
# but "already serves it" is exactly the kind of thing that is true until it
# is not, and the two halves are written in different languages by different
# people.
R="$(newroot)"
cp "$ROOT/board/server.ts" "$R/board/"
cp "$ROOT/board/public/index.html" "$ROOT/board/public/diagram.js" "$R/board/public/"
printf '%s\n' '{"tasks":[]}' > "$R/design/tasks.json"
decision "$R" D-021 '{"id":"D-021","task":"T-004","kind":"merge","title":"merge it","pr":9}'
"$DG" --decision D-021 --repo "$R" >/dev/null 2>&1

PORT=$(( 14900 + RANDOM % 900 ))
# every descriptor detached: ci.sh runs suites inside $(...), and a child
# holding stdout holds the command substitution open with it
FM_ROOT="$R" FM_PORT="$PORT" bun run "$R/board/server.ts" > "$R/out" 2>&1 < /dev/null &
pid=$!
# recorded before the wait, not after it: the trap that kills this used to be
# installed after the readiness loop, so a suite interrupted during those ten
# seconds left bun running on the port it took
SERVER_PID="$pid"
# and the loop reports what happened rather than running out. A server that
# died - a taken port, a bun that will not start - used to leave every
# assertion below failing on its own terms, reading as a broken diagram
# rather than as a board that never came up, with $R/out never printed.
ready=0
for _ in $(seq 1 40); do
  kill -0 "$pid" 2>/dev/null || break
  curl -sf "http://127.0.0.1:$PORT/api/state" >/dev/null 2>&1 && { ready=1; break; }
  sleep 0.25
done
assert_eq "1" "$ready" "the board server came up, so what follows is about the diagrams"
[ "$ready" = 1 ] || cat "$R/out"

for l in en zh-TW zh-CN; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/diagrams/D-021.$l.html")"
  assert_eq "200" "$code" "the board serves diagrams/D-021.$l.html, where the module points"
done
assert_contains "$(curl -sf "http://127.0.0.1:$PORT/diagrams/D-021.zh-CN.html")" "闸门" \
  "and what comes back over the wire is the converted page"
# mount asks with HEAD and hides the iframe on anything but ok, so the
# answer for a decision with no diagram has to be an honest 404
assert_eq "404" "$(curl -s -I -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/diagrams/D-404.en.html")" \
  "a decision with no diagram answers HEAD with 404"
assert_eq "200" "$(curl -s -I -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/diagrams/D-021.en.html")" \
  "and one that has a diagram answers HEAD with 200"

kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null || true
SERVER_PID=''

# ------------------------------------------- the class, not the one instance
#
# The escape above was one site. The class is every ${var/pat/rep} in the
# repository whose replacement carries a literal &, because that character
# changed meaning between the bash on a mac (3.2, & is an ampersand) and the
# bash on the runner (5.2, patsub_replacement is on and & is the matched
# text). Such a line is not portable in either direction - \& is the 5.2
# escape and two literal characters in 3.2 - so the answer is always to take
# the substitution somewhere that has one meaning, as esc() now does with
# sed. A grep, so a new one cannot arrive quietly the way this one did: the
# only machine that would have caught it is the runner, and it says nothing
# until the pull request is already open.
#
# Comment lines are dropped, or this block would flag the paragraphs that
# explain it. ${cnout//$a/$b} in tests/i18n.test.sh is not a hit and should
# not be: an & arriving from an expansion is data, and only a literal & in
# the source text of the replacement is read as the match.
patsub="$(grep -HnE '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?/[/#%]?[^}/]*/[^}]*&' \
  "$ROOT"/bin/*.sh "$ROOT"/bin/adapters/*.sh "$ROOT"/tests/*.sh 2>/dev/null \
  | grep -v '^[^:]*:[0-9]*: *#' || true)"
assert_eq "" "$patsub" \
  "no pattern substitution puts a literal & in its replacement"

# and the grep is not a grep that cannot find anything: the shape it looks
# for, handed to it on purpose, has to come back
probe="$(mktemp -d)"
# the ampersand is interpolated rather than written out, because a fixture
# that spells the forbidden shape in full is itself a hit on the grep above
a='&'
{ printf 'x="${s//</%slt;}"\n'   "$a"
  printf '# x="${s//>/%sgt;}"\n' "$a"; } > "$probe/bin.sh"
hits="$(grep -HnE '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?/[/#%]?[^}/]*/[^}]*&' \
  "$probe/bin.sh" | grep -v '^[^:]*:[0-9]*: *#' || true)"
assert_contains "$hits" '&lt;' "the guard above really does see the shape it forbids"
assert_lacks    "$hits" '&gt;' "and really does walk past it in a comment"
rm -rf "$probe"

# ------------------------------------------------- where the suite has to be
ci="$(cat "$ROOT/bin/ci.sh")"
assert_contains "$ci" "suites=(tests/*.test.sh)" "ci.sh runs every tests/*.test.sh"
assert_ok "test -f '$ROOT/tests/diagram.test.sh'" "and this suite is one of them"

# generated diagrams are not committed: they are derived from the decision
# and the dictionaries, and regenerating them is cheaper than merging them
assert_ok "test -f '$ROOT/board/public/diagrams/.gitignore'" \
  "the output directory keeps its contents out of git"

finish
