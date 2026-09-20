#!/usr/bin/env bash
# Decision diagrams, and only for decisions.
#
#   bin/fm-diagram.sh --decision D-007 [--repo <root>]   render the three files
#   bin/fm-diagram.sh --event <type> --decision D-007     render only if the
#                                                         type is one the
#                                                         captain must rule on
#   bin/fm-diagram.sh --wants <type>                      the ruling alone
#
# Q8, the second half: a drawing is made for a decision the captain must rule
# on and for nothing else. A routine event - a dispatch, a push, a passing
# gate - gets none, so --event is the entry point a caller can use blindly
# for any type bin/fm-emit.sh will accept: it consults the same ruling
# --wants reports and writes nothing for the rest. A type fm-emit would
# itself refuse, or one nobody here has ruled on, is an error and not a quiet
# no - see RULED and ROUTINE below for why that is the loud end.
#
# I4: each decision produces D-*.en.html and D-*.zh-TW.html out of the two
# dictionaries, and D-*.zh-CN.html out of the zh-TW page by putting its TEXT
# NODES through i18n/tw2cn.tsv. Tags, attributes, comments, script and style
# are left exactly as they were - the zh-TW and zh-CN pages differ in their
# words and in the document's lang, in nothing else. That is what keeps a
# table row from rewriting markup the day someone adds one that is not CJK.
#
# Q8, the first half: an authored drawing in design/diagrams/ wins over the
# built-in one. Which drawing is decided once for the whole decision -
# decision before task - and that choice then has to answer every language or
# the render is refused. See "the authored drawing tier" below for why the
# unit is the tier and not the file.
#
# Output lands in board/public/diagrams/, which the board already serves as a
# static file, so nothing has to be added to the server to show one.
set -uo pipefail
# Nothing below may read standard input. A dispatched child inherits it, and
# a child that reads it blocks the caller waiting for a human who is not
# there. One guarantee, in one place; bin/ci.sh fails if a script that
# dispatches is missing it.
exec < /dev/null

ROOT="${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

die()   { printf 'fm-diagram: %s\n' "$1" >&2; exit "${2:-64}"; }

# `shift 2` with one argument left does not shift: it returns 1 and leaves
# $@ alone, so `while [ $# -gt 0 ]` spins on the same flag for ever. A
# trailing --decision was an unkillable busy loop, which is the failure this
# file's own header spends five lines forbidding. So no branch shifts a count
# it has not checked: need() is handed what is left of the command line and
# refuses before the shift rather than after it.
need() { [ "$#" -ge 2 ] || die "$1 needs a value"; }

MODE=''; ID=''; EVENT=''
while [ $# -gt 0 ]; do
  case "$1" in
    --decision) need "$@"; ID="$2";                shift 2 ;;
    --event)    need "$@"; MODE=event; EVENT="$2"; shift 2 ;;
    --wants)    need "$@"; MODE=wants; EVENT="$2"; shift 2 ;;
    --repo)     need "$@"; ROOT="$2";              shift 2 ;;
    -h|--help)  sed -n '4,8p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -d "$ROOT" ] || die "no repo at $ROOT"
ROOT="$(cd "$ROOT" && pwd)"

# A whole-STRING check, in the shell, and not `grep -Eq '^...$'`. grep matches
# a LINE. An id of $'D-007\nanything else' has one line that matches, so it
# passed a check written as an anchored regex - and what went on to be joined
# to a path below was both lines. I could not build a traversal out of it,
# because the newline glues to the leading path component and every use of
# the id here is a leading component; so this was validation that did not mean
# what it said rather than a hole. It is fixed in both the places it was
# written that way and not only in the one that was noticed. A case glob has
# no notion of a line: it is handed the whole value, and a newline is not in
# [0-9] nor in [A-Za-z0-9._-].
is_decision_id() {
  local rest
  case "$1" in D-*) rest="${1#D-}" ;; *) return 1 ;; esac
  case "$rest" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#rest}" -le 6 ]
}
is_task_stem() {
  local rest
  case "$1" in T-*) rest="${1#T-}" ;; *) return 1 ;; esac
  case "$rest" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#rest}" -le 32 ]
}

# An id that was supplied is checked wherever it was supplied. The shape used
# to be checked only on the path that draws, so `--event gate_passed
# --decision D-oo7` exited 0 and said nothing while `--event
# decision_requested` with the same typo exited 64: the misspelling was
# invisible for seventeen of the eighteen event types and visible for one.
# It is the caller's mistake either way, and the routine path is the one
# where nothing downstream would ever have noticed.
[ -z "$ID" ] || is_decision_id "$ID" || die "not a decision id: $ID"

OUT="$ROOT/board/public/diagrams"
SRC="$ROOT/design/diagrams"
I18N="$ROOT/i18n"

# ---------------------------------------------------------------- the ruling

# The ruling, written out. Every type bin/fm-emit.sh can write appears in
# exactly one of these two lines: RULED puts something in front of the
# captain and gets a drawing, ROUTINE is everything else and gets none.
#
# This used to be derived by parsing fm-emit.sh's TYPES line, which read like
# the careful thing to do and was the opposite: a type added there became a
# type known here on the same commit, silently classified as routine and
# silently undrawn - and the suite, which parsed fm-emit the same way,
# compared that list against itself and could not go red for any input.
# A copied list that a test compares against the original is drift a machine
# can see. A derived list is drift a machine cannot see.
RULED="decision_requested"
ROUTINE="greenlit dispatched commit_pushed pr_opened gate_passed gate_failed \
review_opened review_failed ask_pass_criteria criteria_returned \
protocol_violation approved merged closed decision_made worker_crashed \
vendor_unavailable"

# 0 the captain must rule on it, 1 routine, 64 no ruling for it here
wants() {
  local type="$1"
  [ -n "$type" ] || die "--wants needs an event type"
  case " $RULED " in *" $type "*) return 0 ;; esac
  case " $ROUTINE " in *" $type "*) return 1 ;; esac
  # Not silence, and not a default. A type fm-emit can write and this file
  # has not ruled on is a question nobody has answered yet, and tests/
  # diagram.test.sh walks fm-emit's list to find it the moment it appears.
  die "no ruling for event type: $type"
}

if [ "$MODE" = wants ]; then
  wants "$EVENT"; exit $?
fi
if [ "$MODE" = event ]; then
  # the ruling decides; a routine event leaves the tree untouched and says so
  # with a zero exit, because a caller that emits events should not have to
  # know which of them are drawn
  wants "$EVENT" || exit 0
fi

# ------------------------------------------------------------- the decision

# the id reaches the filesystem, so its shape was checked above, before any
# mode could act on it - the same shape the board's POST handler accepts
[ -n "$ID" ] || die "--decision is required"

FILE=''
for c in "$ROOT/state/pending/$ID.json" "$ROOT/state/decisions/$ID.json"; do
  [ -f "$c" ] && { FILE="$c"; break; }
done
[ -n "$FILE" ] || die "no decision $ID under state/pending or state/decisions" 66
command -v jq >/dev/null 2>&1 || die "jq is required" 69
# The file is read before it is believed. Every field below is `// ""`, so a
# file jq cannot parse answers nothing for all of them and the card renders
# blank, with exit 0 - the same failure as an absent dictionary, which is a
# broken input wearing a working input's face. A list parses and is still not
# a decision, so the test is the shape and not merely the syntax.
jq -e 'type == "object"' "$FILE" >/dev/null 2>&1 \
  || die "not a readable decision file: $FILE" 66

TASK="$(jq -r '.task // ""' "$FILE")"
KIND="$(jq -r '.kind // "choice"' "$FILE")"
TITLE="$(jq -r '.title // ""' "$FILE")"
PR="$(jq -r 'if (.pr|type) == "number" then (.pr|tostring) else "" end' "$FILE")"
case "$KIND" in merge|choice) ;; *) KIND=choice ;; esac
# the task id is shown whatever it says, but it is only joined to a path when
# it looks like one of ours
TASKPATH="$TASK"
is_task_stem "$TASK" || TASKPATH=''

# ------------------------------------------------------------------ helpers

# The escape does not go through ${s//</&lt;}, because that expansion does not
# mean the same thing in the two bashes this repository runs on. bash 5.2
# turned patsub_replacement on by default: an unquoted & in the replacement
# now stands for the text the pattern matched. So that line writes <lt; on
# the runner's 5.2 and &lt; on the mac's 3.2, and a title of <script> reached
# the page as <lt;script>gt; - which holds neither &lt;script&gt; nor
# <script>, so the assertion looking for the escape failed while the one
# looking for the tag passed, and the pair read as a half-working escape
# rather than a broken one. There is no spelling that works in both: \& is
# the escape hatch in 5.2 and two literal characters in 3.2. sed has meant
# one thing by \& for thirty years, so the substitution happens there.
esc() {
  printf '%s' "$1" \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# The dictionary, read once per language into d_<key>. bash 3.2 ships no
# associative arrays, and printf -v sets a variable without handing its value
# back to the shell the way eval would.
load_dict() {
  local f="$1" k v
  # An absent dictionary and an absent key are different failures. A key the
  # dictionary does not answer renders as the key, which is a bug report on
  # the page. A dictionary file that is not there at all renders EVERY key
  # that way, and a whole page of `laneQueued` shipped with exit 0 is a
  # broken install that reads as a working one.
  [ -f "$f" ] || die "no dictionary at $f" 66
  while IFS=$'\t' read -r k v; do
    case "$k" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    printf -v "d_$k" '%s' "$v"
  done <<EOF
$(jq -r 'to_entries[]|[.key,.value]|@tsv' "$f")
EOF
}
# the key itself when the dictionary has no answer: a diagram with a visible
# key in it is a bug report, which beats a diagram with a hole in it
#
# A key the dictionary answers with the empty string is a key it answered,
# and it gets the empty string. `-n "${!n-}"` could not tell that from a key
# the dictionary never mentions, so a value someone deliberately blanked came
# out wearing the bug report meant for a value nobody wrote. `+x` asks
# whether the variable is set, which is exactly what load_dict records.
dget() { local n="d_$1"; if [ -n "${!n+x}" ]; then printf '%s' "${!n}"; else printf '%s' "$1"; fi; }
dsc()  { esc "$(dget "$1")"; }

# ------------------------------------------------- the authored drawing tier
#
# Q8: an authored drawing wins. WHICH drawing is decided once, for the whole
# decision, and that choice then has to answer every language.
#
# It used to be decided per language, one independent walk down
# <id>.<lang> -> <id> -> <task>.<lang> -> <task> for each of them. Every rung
# of that ladder can succeed for one language and fail for another, so a
# directory holding only D-011.en.html served English a hand drawing and both
# Chinese readers the built-in frame, with exit 0 and nothing said. The worse
# shape has no file missing anywhere: D-011.en.html beside T-004.zh-TW.html
# answers every language, with two different pictures under one decision.
# Neither is a lookup that failed. Both are lookups that succeeded,
# differently, which is why checking <id>.en and <id>.zh-TW for each other
# would have caught one of them and not the other.
#
# So the unit is the TIER: every file in design/diagrams/ whose stem is the
# decision, or failing that every file whose stem is the task. The first tier
# with anything at all in it is the tier - a half-drawn decision does not
# quietly become a task drawing - and a tier that cannot answer all of
# AUTHORED_LANGS is refused with its own number rather than served to
# whichever languages it happens to cover.
#
# zh-CN is not in that list because it is never authored: it is derived from
# zh-TW. So a hand-written D-011.zh-CN.html answers no language, and a tier
# holding only that one is a refusal - which is the loud end of the README's
# "never write a zh-CN file".
AUTHORED_LANGS="en zh-TW"

tier_files() {   # tier_files <stem> -> the authored files belonging to that stem
  local stem="$1" f
  for f in "$SRC/$stem.html" "$SRC/$stem".*.html; do
    [ -f "$f" ] && printf '%s\n' "${f##*/}"
  done
  return 0
}
tier_answer() {  # tier_answer <stem> <lang> -> the file that serves that language
  local stem="$1" lang="$2"
  [ -f "$SRC/$stem.$lang.html" ] && { printf '%s' "$SRC/$stem.$lang.html"; return 0; }
  [ -f "$SRC/$stem.html" ]       && { printf '%s' "$SRC/$stem.html";       return 0; }
  return 1
}
# the stem whose drawings this decision uses; empty means the built-in body
TIER=''
resolve_tier() {
  local stem lang unanswered=''
  for stem in "$ID" ${TASKPATH:+"$TASKPATH"}; do
    [ -n "$(tier_files "$stem")" ] || continue
    TIER="$stem"; break
  done
  [ -n "$TIER" ] || return 0
  for lang in $AUTHORED_LANGS; do
    tier_answer "$TIER" "$lang" >/dev/null || unanswered="$unanswered $lang"
  done
  [ -z "$unanswered" ] || die "design/diagrams/$TIER is drawn for some languages and not others:\
 nothing answers$unanswered (it has: $(tier_files "$TIER" | tr '\n' ' '))\
 - write $TIER.<lang>.html for each of $AUTHORED_LANGS, or one $TIER.html with no words in it" 65
}

fragment() {
  local lang="$1" f
  [ -n "$TIER" ] || return 1
  f="$(tier_answer "$TIER" "$lang")" || return 1
  cat "$f"
}

# ------------------------------------------------------------------- render

render() {  # render <html-lang> <dictionary> <fragment-language>
  load_dict "$2"
  local title frag=''
  title="$(esc "$TITLE")"
  [ -n "$title" ] || title="$(dsc waiting)"
  frag="$(fragment "$3")" || frag=''

  cat <<HTML
<!doctype html>
<html lang="$1">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$ID</title>
<style>
:root{--bg:#0e1720;--bg2:#16212c;--line:#213041;--fg:#e8eff7;--fg2:#93a7bd;
  --fg3:#5d7188;--brass:#d9a441;--ok:#3ecf8e;--warn:#f2b544;
  --mono:ui-monospace,SFMono-Regular,Menlo,monospace;
  --sans:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
*{box-sizing:border-box}html,body{margin:0}
body{background:var(--bg);color:var(--fg);font:13px/1.5 var(--sans);padding:14px}
.meta{margin:0;font:11px var(--mono);color:var(--fg3);letter-spacing:.04em}
.meta b{color:var(--brass);font-weight:700}
h1{margin:4px 0 12px;font-size:16px;line-height:1.35;font-weight:650}
.lanes{display:flex;flex-wrap:wrap;gap:4px;margin:0 0 12px;padding:0;list-style:none}
.lanes li{font:10.5px var(--mono);color:var(--fg3);background:var(--bg2);
  border:1px solid var(--line);border-radius:99px;padding:2px 9px}
.lanes li.here{color:#2a1c05;background:var(--brass);border-color:var(--brass);font-weight:700}
.gates{display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));
  gap:2px 12px;margin:0 0 12px;padding:0;list-style:none}
.gates li{font-size:12px;color:var(--fg2);display:flex;gap:7px}
.gates li i{font-style:normal;width:14px;text-align:center;color:var(--ok)}
.drawn{border:1px solid var(--line);border-radius:10px;background:var(--bg2);
  padding:10px;margin:0 0 12px;overflow:auto}
.answers{display:flex;flex-wrap:wrap;gap:7px;margin:0;padding:0;list-style:none}
.answers li{font:600 11.5px var(--sans);border:1px solid var(--line);
  border-radius:8px;padding:4px 12px;color:var(--fg2);background:var(--bg2)}
.answers li.go{color:#2a1c05;border-color:var(--brass);
  background:linear-gradient(180deg,#e0b055,#b8862c)}
</style>
</head>
<body>
<main class="card k-$KIND" id="$ID">
<p class="meta"><b>$(esc "$ID")</b>$([ -n "$TASK" ] && printf ' &middot; %s' "$(esc "$TASK")")$([ -n "$PR" ] && printf ' &middot; #%s' "$(esc "$PR")")</p>
<h1>$title</h1>
<ol class="lanes">
<li>$(dsc laneQueued)</li>
<li>$(dsc laneWorking)</li>
<li>$(dsc laneGate)</li>
<li>$(dsc laneReview)</li>
<li class="here">$(dsc laneCaptain)</li>
<li>$(dsc laneMerged)</li>
</ol>
HTML

  if [ -n "$frag" ]; then
    printf '<div class="drawn">\n%s\n</div>\n' "$frag"
  elif [ "$KIND" = merge ]; then
    printf '<ul class="gates">\n'
    for n in 1 2 3 4 5 6 7; do
      printf '<li><i>%s</i>%s</li>\n' "$n" "$(dsc "gate$n")"
    done
    printf '</ul>\n'
  fi

  printf '<ul class="answers">\n'
  if [ "$KIND" = merge ]; then
    printf '<li class="go">%s</li>\n' "$(dsc mergeInto)"
  else
    printf '<li class="go">%s</li>\n' "$(dsc chooseA)"
  fi
  printf '<li>%s</li>\n<li>%s</li>\n</ul>\n' "$(dsc sendBack)" "$(dsc hold)"
  printf '</main>\n</body>\n</html>\n'
}

# zh-CN is the zh-TW page with its text nodes converted. Everything between
# < and > is markup and is copied through untouched, as is anything inside a
# comment, a script or a style block.
#
# The board already applies this table, in board/public/index.html:
#
#   const cn = (x) => DICT.tw2cn.reduce((acc, p) => acc.split(p[0]).join(p[1]), x)
#
# and the honest question is why that is not simply called here. It converts
# a dictionary VALUE, one string at a time, before that string has met any
# markup; there is nothing in it that could tell a word from a tag, because
# nothing it is ever handed contains one. What this file has at the point of
# conversion is a finished document - and it has to be, because an authored
# drawing out of design/diagrams/ carries zh-TW that was never a dictionary
# value and so was never converted on the way in.
#
# So: same table, same substitution rule - row by row in file order, every
# occurrence of each, and no rescanning of what a row just wrote, which is
# what keeps a row whose output contains its input from looping - and a
# different unit of work. The rule is the
# part that could quietly drift, so tests/diagram.test.sh runs the real cn()
# lifted out of index.html and this awk over every value in the zh-TW
# dictionary and fails if they disagree on any of them.
#
# One difference that is not a difference: cn() reduces over a whole string
# and conv() runs on one line's worth of text node at a time. A match can
# only be lost at a line break if the row's own text spans one, and every row
# is a single tab-separated line - tests/i18n.test.sh fails the table if any
# row is not exactly two columns. A replacement cannot introduce a break
# either, for the same reason. tests/diagram.test.sh pins it with a text node
# that wraps mid-phrase, since the dictionary corpus is single-line by
# construction and so could never have shown it.
TEXTNODES='
function rep(s, a, b,   out, i) {
  out = ""
  while ((i = index(s, a)) > 0) { out = out substr(s, 1, i - 1) b; s = substr(s, i + length(a)) }
  return out s
}
function conv(s,   i) { for (i = 1; i <= n; i++) s = rep(s, from[i], to[i]); return s }
BEGIN {
  n = 0
  while ((getline ln < TBL) > 0) {
    if (ln ~ /^#/ || ln ~ /^[ \t]*$/) continue
    i = index(ln, "\t"); if (i == 0) continue
    n++; from[n] = substr(ln, 1, i - 1); to[n] = substr(ln, i + 1)
  }
  close(TBL)
  # The loader answers how many rows it found, and then stops. That is what
  # lets the pre-flight check below be a question put to THIS program rather
  # than a second copy of the row rule three lines above - the copy would go
  # on agreeing with itself for ever, including on the day one of them
  # changed.
  if (CHECK != "") { print n; exit }
  intag = 0; incomment = 0; skip = 0; inq = ""
  # written as a code point because this program is a single-quoted shell
  # string and an apostrophe would end it
  SQ = sprintf("%c", 39)
}
{
  line = $0; out = ""
  while (length(line) > 0) {
    if (incomment) {
      p = index(line, "-->")
      if (p == 0) { out = out line; line = "" }
      else { out = out substr(line, 1, p + 2); line = substr(line, p + 3); incomment = 0 }
    } else if (intag) {
      # A tag ends at the first > that is NOT inside an attribute value.
      # Ending it at the first > full stop is legal in exactly the documents
      # nobody authors by hand: <text data-note="a > b">, which SVG permits,
      # handed the tail of its own attribute to the converter as if it were a
      # text node. Authored fragments are cat-ed in verbatim, so they are the
      # one input on this path that was never written by this program.
      q = 1; L = length(line); closed = 0
      while (q <= L) {
        ch = substr(line, q, 1)
        if (inq != "") { if (ch == inq) inq = "" }
        else if (ch == "\"" || ch == SQ) { inq = ch }
        else if (ch == ">") { closed = 1; break }
        q++
      }
      if (closed) { out = out substr(line, 1, q); line = substr(line, q + 1); intag = 0 }
      else { out = out line; line = "" }
    } else {
      p = index(line, "<")
      if (p == 0) { out = out (skip ? line : conv(line)); line = "" }
      else {
        seg = substr(line, 1, p - 1)
        out = out (skip ? seg : conv(seg))
        rest = substr(line, p)
        if (substr(rest, 1, 4) == "<!--") { incomment = 1; out = out "<!--"; line = substr(rest, 5) }
        else {
          closing = (substr(rest, 2, 1) == "/")
          i = closing ? 3 : 2; tag = ""
          while (i <= length(rest) && substr(rest, i, 1) ~ /[A-Za-z]/) { tag = tag substr(rest, i, 1); i++ }
          tag = tolower(tag)
          if (tag == "script" || tag == "style") skip = closing ? 0 : 1
          intag = 1; out = out "<"; line = substr(rest, 2)
        }
      }
    }
  }
  print out
}
'

# Everything the render needs is checked before anything is written. render
# runs inside a subshell feeding a redirect, so a die in there would have
# created the file first and then been reported as the redirect's own 73 -
# the missing input would reach the caller wearing the wrong number and with
# half a page already on disk.
for f in "$I18N/ui.en.json" "$I18N/ui.zh-TW.json" "$I18N/tw2cn.tsv"; do
  [ -f "$f" ] || die "no $f: the three languages cannot be rendered without it" 66
done
# and present is not the same as readable. A dictionary jq cannot parse - or
# one that parses to something that is not an object - hands load_dict no
# rows at all, so every key renders as itself: the page of raw keys again,
# this time out of a root where all three files are sitting right there.
for f in "$I18N/ui.en.json" "$I18N/ui.zh-TW.json"; do
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 \
    || die "$f is not a readable dictionary" 66
done
# and the table is held to the same line, for the same reason. It used to be
# checked for existence alone - so a truncated, empty or all-comments
# tw2cn.tsv left the loader with no rows, made the conversion the identity,
# and shipped D-$ID.zh-CN.html with lang="zh-CN" over zh-TW words and exit 0.
# That is the broken input wearing a working input's face again, and it was
# guarded on the two dictionaries and not on the one file whose entire job is
# the zh-CN page. tests/i18n.test.sh lints the repository's own copy of the
# table, which is a different claim: it says this repository's table is good,
# not that the generator refuses an unusable one wherever it is run.
#
# "Readable", for a table, is "the loader finds at least one row in it", so
# the loader is what is asked. CHECK makes the awk program above print the
# number of rows it read and stop before the first line of input.
rows="$(awk -v TBL="$I18N/tw2cn.tsv" -v CHECK=1 "$TEXTNODES" < /dev/null 2>/dev/null)"
case "${rows:-x}" in ''|*[!0-9]*) rows=0 ;; esac
[ "$rows" -gt 0 ] || die "no usable rows in $I18N/tw2cn.tsv: zh-CN would be zh-TW under a zh-CN label" 66
# and the drawing this decision will use is chosen here, before the first
# redirect, because an unevenly authored tier is a refusal and a refusal must
# not arrive with one language already on disk
resolve_tier

mkdir -p "$OUT" || die "cannot create $OUT" 73

# a subshell per language: the dictionary is read into d_* names, and a key
# missing from one file must not be answered by the other file's value
( render en    "$I18N/ui.en.json"    en    ) > "$OUT/$ID.en.html"    || die "could not write $ID.en.html" 73
( render zh-TW "$I18N/ui.zh-TW.json" zh-TW ) > "$OUT/$ID.zh-TW.html" || die "could not write $ID.zh-TW.html" 73
( render zh-CN "$I18N/ui.zh-TW.json" zh-TW ) \
  | awk -v TBL="$I18N/tw2cn.tsv" "$TEXTNODES" > "$OUT/$ID.zh-CN.html" \
  || die "could not write $ID.zh-CN.html" 73

printf '%s\n' "$OUT/$ID.en.html" "$OUT/$ID.zh-TW.html" "$OUT/$ID.zh-CN.html"
