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
assert_fail "jq -r '.[]' '$en' | grep -q '^$'" "no English value is empty"
assert_fail "jq -r '.[]' '$tw' | grep -q '^$'" "no Chinese value is empty"

# every key the page asks for has to exist
missing=''
# a word boundary, or the t at the end of get(" matches too
for k in $(grep -oE '[^A-Za-z0-9_]t\("[a-zA-Z0-9]+"\)' "$ROOT/board/public/index.html" \
           | sed 's/^.*t("//;s/")//' | sort -u); do
  case "$k" in gate*) continue ;; esac
  jq -e --arg k "$k" 'has($k)' "$en" >/dev/null 2>&1 || missing="$missing $k"
done
assert_eq "" "$missing" "every key the page asks for is in the dictionary"
for n in 1 2 3 4 5 6 7; do
  assert_ok "jq -e 'has(\"gate$n\")' '$en' >/dev/null" "gate $n has a label"
done

# the table covers the terms that actually differ between the two vocabularies
for term in 程式 函式 相依 佇列 唯讀; do
  assert_ok "grep -q '^$term	' '$tbl'" "the table converts $term"
done
assert_fail "grep -vE '^#|^$' '$tbl' | awk -F'\t' 'NF!=2' | grep -q ." "every table row is exactly two columns"
assert_fail "grep -vE '^#|^$' '$tbl' | cut -f1 | sort | uniq -d | grep -q ." "no term is listed twice"

# applying the table to the zh-TW dictionary must change something and break nothing
cnout="$(jq -r '.gate4' "$tw")"
while IFS=$'\t' read -r a b; do
  case "$a" in '#'*|'') continue ;; esac
  cnout="${cnout//$a/$b}"
done < "$tbl"
assert_ne "$(jq -r '.gate4' "$tw")" "$cnout" "converting zh-TW actually produces zh-CN"

# the page carries no Chinese of its own: it all comes from the dictionary
# comments included on purpose: the page must carry no Chinese at all, so
# this one counts rather than filtering - and counting keeps the hygiene lint
# from reading it as the usual comment-satisfied grep
# a bracket range over CJK depends on the locale: it passed on macOS and
# failed on the CI runner. \p{Han} does not.
cjk="$(perl -CSD -ne 'print if /\p{Han}/' "$ROOT/board/public/index.html" | wc -l | tr -d ' ')"
assert_eq "0" "$cjk" "the page holds no hardcoded Chinese, comments included"
finish
