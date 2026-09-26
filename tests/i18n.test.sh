#!/usr/bin/env bash
# Three languages, two files. zh-CN is derived, so there is no third
# dictionary to fall out of step with the other two.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

en="$ROOT/i18n/ui.en.json"; tw="$ROOT/i18n/ui.zh-TW.json"; tbl="$ROOT/i18n/tw2cn.tsv"
assert_ok "test -f '$en' && test -f '$tw' && test -f '$tbl'" "the dictionaries and the table exist"

ke="$(jq -r 'keys[]' "$en" | sort)"; kt="$(jq -r 'keys[]' "$tw" | sort)"
assert_eq "$ke" "$kt" "both dictionaries hold exactly the same keys"
# fed by process substitution, not a pipe (under pipefail jq can die of
# SIGPIPE once grep -q has left) and not a here-string: $(...) would strip
# the trailing empty lines this is looking for
assert_fail "grep -q '^$' < <(jq -r '.[]' '$en')" "no English value is empty"
assert_fail "grep -q '^$' < <(jq -r '.[]' '$tw')" "no Chinese value is empty"

# every key the page asks for has to exist
missing=''
# a word boundary, or the t at the end of get(" matches too
# the authored pages, not everything that ends up under board/public. A
# generated diagram is Chinese on purpose - it is produced FROM the
# dictionaries - and scanning it would make the lint red whenever a
# decision is pending.
#
# A function, and not an expression written out at each use, because the
# exclusion is the whole of acceptance criterion six and the exercise at the
# bottom of this file has to be able to run THIS scan rather than a copy of
# it. A copy would still say "the scan walks past diagrams/" on the day
# someone deleted the -not -path from the line the lint actually uses.
page_files() {  # page_files <root> -> the files the hardcoded-string lint scans
  find "$1/board/public" -type f \( -name '*.html' -o -name '*.js' \) \
    -not -path '*/diagrams/*' | sort
}
pages="$(page_files "$ROOT")"
assert_ok "test \"$(printf '%s\n' \"$pages\" | wc -l | tr -d ' ')\" -ge 2" "the scan covers every page file"
for k in $(grep -ohE '[^A-Za-z0-9_][tT]\("[a-zA-Z0-9]+"\)' $pages \
           | sed 's/^.*("//;s/")//' | sort -u); do
  case "$k" in gate*) continue ;; esac
  jq -e --arg k "$k" 'has($k)' "$en" >/dev/null 2>&1 || missing="$missing $k"
done
assert_eq "" "$missing" "every key the page asks for is in the dictionary"

# The page shows a refusal by the code the server sends (T-122's 403s among
# them), so every code the server can send is a key in both dictionaries.
codes="$(grep -oE 'refuse\("[A-Za-z]+"|code: "[A-Za-z]+"' "$ROOT/board/server.ts" \
  | sed -E 's/^.*"([A-Za-z]+)"$/\1/' | sort -u)"
assert_contains "$codes" "writeCredential" "the scan finds the server's refusal codes"
missing=''
for k in $codes; do
  jq -e --arg k "$k" 'has($k)' "$en" >/dev/null 2>&1 || missing="$missing en:$k"
  jq -e --arg k "$k" 'has($k)' "$tw" >/dev/null 2>&1 || missing="$missing zh-TW:$k"
done
assert_eq "" "$missing" "every code the server refuses with is translated in both dictionaries"
assert_ok "jq -e 'has(\"readOnly\")' '$en' >/dev/null && jq -e 'has(\"readOnly\")' '$tw' >/dev/null" \
  "the read-only line is in both dictionaries"
for n in 1 2 3 4 5 6 7; do
  assert_ok "jq -e 'has(\"gate$n\")' '$en' >/dev/null" "gate $n has a label"
done

# the table covers the terms that actually differ between the two vocabularies
for term in 程式 函式 相依 佇列 唯讀; do
  assert_ok "grep -q '^$term	' '$tbl'" "the table converts $term"
done
assert_fail "grep -q . <<<\"\$(grep -vE '^#|^$' '$tbl' | awk -F'\t' 'NF!=2')\"" "every table row is exactly two columns"
assert_fail "grep -q . <<<\"\$(grep -vE '^#|^$' '$tbl' | cut -f1 | sort | uniq -d)\"" "no term is listed twice"

# applying the table to the zh-TW dictionary must change something and break nothing
cnout="$(jq -r '.gate4' "$tw")"
while IFS=$'\t' read -r a b; do
  case "$a" in '#'*|'') continue ;; esac
  cnout="${cnout//$a/$b}"
done < "$tbl"
assert_ne "$(jq -r '.gate4' "$tw")" "$cnout" "converting zh-TW actually produces zh-CN"

# Authored oracle, deliberately independent of the table under test. This
# catches both overlap order (船員 before 船員名冊) and displayed characters
# that a self-derived expectation silently preserves.
displayed='船員名冊 · 讀取變數 · 每張任務卡片 · 任務檔案'
displayed_cn="$displayed"
while IFS=$'\t' read -r a b; do
  case "$a" in '#'*|'') continue ;; esac
  displayed_cn="${displayed_cn//$a/$b}"
done < "$tbl"
assert_eq '船员名册 · 读取变量 · 每张任务卡片 · 任务文件' "$displayed_cn" \
  "displayed CN vocabulary matches an independently authored oracle"

# the page carries no Chinese of its own: it all comes from the dictionary
# comments included on purpose: the page must carry no Chinese at all, so
# this one counts rather than filtering - and counting keeps the hygiene lint
# from reading it as the usual comment-satisfied grep
# a bracket range over CJK depends on the locale: it passed on macOS and
# failed on the CI runner. \p{Han} does not.
cjk="$(perl -CSD -ne 'print if /\p{Han}/' $pages | wc -l | tr -d ' ')"
assert_eq "0" "$cjk" "the page holds no hardcoded Chinese, comments included"

# The exclusion above is load-bearing, and an exclusion nobody exercises is a
# line of prose. So: generate a real diagram, confirm it is full of Chinese -
# it is produced FROM the dictionaries, so it could not be anything else -
# and confirm the scan walks past it. Without the -not -path the lint would
# go red the moment a decision was pending, which is the moment the board is
# most needed.
#
# Everything below runs page_files, the function the lint itself runs, over a
# tree that has a generated diagram in it. Nothing here writes a find of its
# own: an assertion about a find the test wrote is an assertion about the
# test.
d="$(mktemp -d)"
mkdir -p "$d/bin" "$d/i18n" "$d/state/pending" "$d/design/diagrams" "$d/board/public"
# no 2>/dev/null on the fixtures: a copy that silently did not happen makes
# every assertion under it a report about the fixture
cp "$ROOT/bin/fm-diagram.sh" "$ROOT/bin/fm-emit.sh" "$d/bin/"
cp "$en" "$tw" "$tbl" "$d/i18n/"
# the directory, not a list of names. A list drifts: it was index.html and
# ship.js, so diagram.js - added by the same change this block was written
# for - was never in the tree, and "while still covering the authored pages"
# passed without covering the new one. Any diagrams already sitting in the
# developer's own board/public go, because the point below is a tree where
# THIS run generated the only one.
cp -R "$ROOT/board/public/." "$d/board/public/"
rm -rf "$d/board/public/diagrams"
printf '%s\n' '{"id":"D-001","task":"T-001","kind":"merge","title":"merge it","pr":1}' \
  > "$d/state/pending/D-001.json"
"$d/bin/fm-diagram.sh" --decision D-001 --repo "$d" >/dev/null 2>&1
assert_eq "0" "$?" "the generator ran in the scratch tree"
gen="$d/board/public/diagrams/D-001.zh-TW.html"
assert_ok "test -s '$gen'" "a decision really does generate a diagram under board/public"
genhan="$(perl -CSD -ne 'print if /\p{Han}/' "$gen" 2>/dev/null | wc -l | tr -d ' ')"
assert_ne "0" "$genhan" "and that diagram is Chinese, which is the point of it"

# the diagram is inside the tree the lint walks - that is what makes the
# exclusion do any work at all, and without this line the assertions below
# would also pass on a tree where no diagram was ever written
everything="$(find "$d/board/public" -type f \( -name '*.html' -o -name '*.js' \) | sort)"
assert_contains "$everything" "diagrams/D-001.zh-TW.html" \
  "the generated diagram is under the directory the lint walks"

scanned="$(page_files "$d")"
assert_lacks "$scanned" "diagrams/" "the lint's own scan walks past generated diagrams"
# every page the real scan covers, named by the real scan. "covering the
# authored pages" asserted against a hand-written list is an assertion about
# the list.
assert_eq "$(page_files "$ROOT" | sed "s|^$ROOT/||")" "$(page_files "$d" | sed "s|^$d/||")" \
  "while still covering every authored page the lint scans in the repository"
assert_ne "$everything" "$scanned" "so the exclusion is what is keeping it out, not luck"
scanhan="$(perl -CSD -ne 'print if /\p{Han}/' $scanned 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$scanhan" "so a pending decision cannot turn the lint red"
rm -rf "$d"
finish
