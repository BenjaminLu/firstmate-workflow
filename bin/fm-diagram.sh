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
# built-in one. Lookup runs decision before task, language before neutral.
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

# the id reaches the filesystem, so it is checked against a shape before it
# is ever joined to a path - the same shape the board's POST handler accepts
[ -n "$ID" ] || die "--decision is required"
grep -Eq '^D-[0-9]{1,6}$' <<<"$ID" || die "not a decision id: $ID"

FILE=''
for c in "$ROOT/state/pending/$ID.json" "$ROOT/state/decisions/$ID.json"; do
  [ -f "$c" ] && { FILE="$c"; break; }
done
[ -n "$FILE" ] || die "no decision $ID under state/pending or state/decisions" 66
command -v jq >/dev/null 2>&1 || die "jq is required" 69

TASK="$(jq -r '.task // ""' "$FILE")"
KIND="$(jq -r '.kind // "choice"' "$FILE")"
TITLE="$(jq -r '.title // ""' "$FILE")"
PR="$(jq -r 'if (.pr|type) == "number" then (.pr|tostring) else "" end' "$FILE")"
case "$KIND" in merge|choice) ;; *) KIND=choice ;; esac
# the task id is shown whatever it says, but it is only joined to a path when
# it looks like one of ours
TASKPATH="$TASK"
grep -Eq '^T-[A-Za-z0-9._-]{1,32}$' <<<"$TASK" || TASKPATH=''

# ------------------------------------------------------------------ helpers

esc() {
  local s="$1"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"
  printf '%s' "$s"
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
dget() { local n="d_$1"; if [ -n "${!n-}" ]; then printf '%s' "${!n}"; else printf '%s' "$1"; fi; }
dsc()  { esc "$(dget "$1")"; }

# Q8: an authored drawing wins. Decision before task, language before the
# language-neutral file - a drawing with no words in it serves all three.
fragment() {
  local lang="$1" f
  set -- "$SRC/$ID.$lang.html" "$SRC/$ID.html"
  [ -n "$TASKPATH" ] && set -- "$@" "$SRC/$TASKPATH.$lang.html" "$SRC/$TASKPATH.html"
  for f in "$@"; do
    [ -f "$f" ] && { cat "$f"; return 0; }
  done
  return 1
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
  close(TBL); intag = 0; incomment = 0; skip = 0
}
{
  line = $0; out = ""
  while (length(line) > 0) {
    if (incomment) {
      p = index(line, "-->")
      if (p == 0) { out = out line; line = "" }
      else { out = out substr(line, 1, p + 2); line = substr(line, p + 3); incomment = 0 }
    } else if (intag) {
      p = index(line, ">")
      if (p == 0) { out = out line; line = "" }
      else { out = out substr(line, 1, p); line = substr(line, p + 1); intag = 0 }
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

mkdir -p "$OUT" || die "cannot create $OUT" 73

# a subshell per language: the dictionary is read into d_* names, and a key
# missing from one file must not be answered by the other file's value
( render en    "$I18N/ui.en.json"    en    ) > "$OUT/$ID.en.html"    || die "could not write $ID.en.html" 73
( render zh-TW "$I18N/ui.zh-TW.json" zh-TW ) > "$OUT/$ID.zh-TW.html" || die "could not write $ID.zh-TW.html" 73
( render zh-CN "$I18N/ui.zh-TW.json" zh-TW ) \
  | awk -v TBL="$I18N/tw2cn.tsv" "$TEXTNODES" > "$OUT/$ID.zh-CN.html" \
  || die "could not write $ID.zh-CN.html" 73

printf '%s\n' "$OUT/$ID.en.html" "$OUT/$ID.zh-TW.html" "$OUT/$ID.zh-CN.html"
