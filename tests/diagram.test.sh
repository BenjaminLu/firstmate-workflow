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
newroot() {  # newroot -> prints a fresh root with the dictionaries in it
  local d; d="$(mktemp -d)"
  mkdir -p "$d/bin" "$d/i18n" "$d/state/pending" "$d/state/decisions" \
           "$d/design/diagrams" "$d/board/public"
  # errors are not swallowed here: a fixture that half-builds itself and says
  # nothing turns every assertion downstream of it into a report about the
  # fixture rather than about the generator
  cp "$ROOT/bin/fm-emit.sh" "$d/bin/"
  cp "$ROOT/i18n/ui.en.json" "$ROOT/i18n/ui.zh-TW.json" "$ROOT/i18n/tw2cn.tsv" "$d/i18n/"
  printf '%s' "$d"
}
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

probed="$(mktemp -d)"
{
  printf '%s\n' 'const fs = require("fs");'
  printf '%s\n' 'const rows = fs.readFileSync(process.env.TBL, "utf8").split("\n")'
  printf '%s\n' '  .filter(l => l && l[0] !== "#" && l.includes("\t"))'
  printf '%s\n' '  .map(l => [l.slice(0, l.indexOf("\t")), l.slice(l.indexOf("\t") + 1)]);'
  printf '%s\n' 'const DICT = { tw2cn: rows };'
  grep -h 'const cn = ' "$ROOT/board/public/index.html"
  printf '%s\n' 'const d = JSON.parse(fs.readFileSync(process.env.TW, "utf8"));'
  printf '%s\n' 'process.stdout.write(Object.keys(d).sort().map(k => cn(d[k])).join("\n"));'
} > "$probed/cn.js"
assert_eq "1" "$(grep -c 'const cn = ' "$ROOT/board/public/index.html" | tr -d ' ')" \
  "the page declares cn() exactly once, so there is one of it to lift"
assert_ok "grep -q 'DICT.tw2cn' '$probed/cn.js'" "the board's own cn() was lifted into the probe"
bycn="$(TBL="$ROOT/i18n/tw2cn.tsv" TW="$ROOT/i18n/ui.zh-TW.json" bun run "$probed/cn.js" 2>&1)"
assert_eq "$bycn" "$byawk" \
  "the board's cn() and the generator's awk agree on every value in the dictionary"
rm -rf "$probed"

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

# ---------------------------------------------------------------- refusals
R="$(newroot)"
for bad in "../../etc/passwd" "D-1234567" "T-004" "D-" "" ; do
  "$DG" --decision "$bad" --repo "$R" >/dev/null 2>&1
  assert_eq "64" "$?" "[$bad] is refused as a decision id"
done
assert_eq "" "$(find "$R/board/public" -name '*.html' 2>/dev/null)" "and nothing was written on the way"
"$DG" --decision D-404 --repo "$R" >/dev/null 2>&1
assert_eq "66" "$?" "a decision with no file is a missing input, not a crash"

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

# the other half of that contract: a key the dictionary does not answer is
# not a missing input, it is a visible hole with the key's name on it
holey="$(newroot)"
jq 'del(.laneQueued)' "$ROOT/i18n/ui.en.json" > "$holey/i18n/ui.en.json"
decision "$holey" D-042 '{"id":"D-042","task":"T-004","kind":"choice","title":"pick one"}'
"$DG" --decision D-042 --repo "$holey" >/dev/null 2>&1
assert_eq "0" "$?" "a dictionary with one key missing still renders"
assert_contains "$(cat "$holey/board/public/diagrams/D-042.en.html" 2>/dev/null)" "laneQueued" \
  "and the key itself shows through, which is the bug report"

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

# a captain's title is captain-supplied text, so it reaches the page as text
R="$(newroot)"
decision "$R" D-014 '{"id":"D-014","task":"T-004","kind":"choice","title":"<script>alert(1)</script> & <b>"}'
"$DG" --decision D-014 --repo "$R" >/dev/null 2>&1
d14="$(cat "$R/board/public/diagrams/D-014.en.html" 2>/dev/null)"
assert_contains "$d14" "&lt;script&gt;" "a title with markup in it is escaped"
assert_lacks    "$d14" "<script>"       "and no script tag reaches the page"

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
page="$(cat "$ROOT/board/public/index.html")"
assert_contains "$page" "diagram.js"      "the page loads the embed module"
assert_contains "$page" "DIAGRAM.embed"   "the decision card carries the iframe"
assert_contains "$page" "DIAGRAM.mount"   "and the language swap goes through it"
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
for _ in $(seq 1 40); do
  curl -sf "http://127.0.0.1:$PORT/api/state" >/dev/null 2>&1 && break; sleep 0.25
done
trap 'kill "$pid" 2>/dev/null' EXIT

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
trap - EXIT
rm -rf "$R"

# ------------------------------------------------- where the suite has to be
ci="$(cat "$ROOT/bin/ci.sh")"
assert_contains "$ci" "suites=(tests/*.test.sh)" "ci.sh runs every tests/*.test.sh"
assert_ok "test -f '$ROOT/tests/diagram.test.sh'" "and this suite is one of them"

# generated diagrams are not committed: they are derived from the decision
# and the dictionaries, and regenerating them is cheaper than merging them
assert_ok "test -f '$ROOT/board/public/diagrams/.gitignore'" \
  "the output directory keeps its contents out of git"

finish
