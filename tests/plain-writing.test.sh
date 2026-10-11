#!/usr/bin/env bash
# T-270: specs and captain cards a person can read without decoding.
# Feature dependencies: bin/lib/fm_plain.py bin/lib/fm_ste.py bin/fm-decide.sh
# bin/lib/fm_merge_details.py bin/lib/fm_evidence.py bin/lib/fm_self_pr.py
# i18n/glossary.json skills/firstmate/plain-writing.md
# Shared fixtures: tests/lib/plain_writing.py tests/lib/ste_cases.py
# tests/decide.test.sh (its fixture prefix)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export HERDR_ENV=0

# The stock decide fixture (scripts, dictionaries, gh stub, binding service);
# it also sources tests/lib.sh.
eval "$(python3 -c 'import sys; print(open(sys.argv[1]).read().split("\nd=\"$(fixture)\"", 1)[0])' "$ROOT/tests/decide.test.sh")"

# --- interface and behavioural unit cases (labels inside the module) --------
python3 "$ROOT/tests/lib/plain_writing.py" "$ROOT"
assert_eq 0 "$?" 'plain-writing checks, check-plain, merge-card retention, comment privacy and PR body'

# --- fm-decide.sh --request: behavioural -------------------------------------
d="$(fixture)"
ste() { python3 "$ROOT/tests/lib/ste_cases.py" fixture "$1"; }
request() { FM_GH="$d/gh" FM_ROOT="$d" "$d/bin/fm-decide.sh" "$@"; }

# Change 19: fm-decide reads the glossary only from its own code tree. FM_ROOT
# names a valid checkout ($d); a missing or unreadable glossary in the code
# tree is refused by name and nothing is written.
for how in missing unreadable; do
  c0="$(fixture)" && [ -n "$c0" ] || exit 70; c="$(cd "$c0" && pwd -P)"
  case "$how" in
    missing) rm "$c/i18n/glossary.json" ;;
    unreadable) printf '\377\376 not text' > "$c/i18n/glossary.json" ;;
  esac
  out="$(FM_GH="$d/gh" FM_ROOT="$d" "$c/bin/fm-decide.sh" --request D-27090 --task T-031 --details "$c/details.json" 2>&1)"
  assert_eq 64 "$?" "fm-decide: a $how code-tree glossary is refused"
  assert_contains "$out" "$how $c/i18n/glossary.json" "fm-decide: the refusal names the code tree's $how glossary"
  assert_fail "test -e '$d/state/pending/D-27090.json' || test -e '$c/state/pending/D-27090.json'" \
    "fm-decide: a $how glossary writes no card"
  rm -rf "$c"
done

# Every kind refuses a card without how before anything is read or written.
# Controls: a full intent card that also carries how and glossary. The base
# accepts it (it reads neither key), so removing only how isolates the new
# refusal; nothing else about the card changes between the two requests.
pr_is "$d" 31 t-031-plain 'T-031: plain cards'
pr_is "$d" 32 hotfix-plain 'hotfix the board'
H=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
n=27100
for kind in choice merge merge-untracked; do
  case "$kind" in
    choice) ste pass > "$d/control.json"; args=(--task T-031) ;;
    merge) ste pass | jq '.en.title="MERGE CARD — merge PR #31: The check passes." | ."zh-TW".title="【合併卡】合併 PR #31：檢查通過。"' > "$d/control.json"
           args=(--expected-head "$H" --task T-031 --kind merge --pr 31) ;;
    merge-untracked) ste pass | jq '.en.title="MERGE CARD — merge PR #32: The check passes." | ."zh-TW".title="【合併卡】合併 PR #32：檢查通過。"' > "$d/control.json"
           args=(--expected-head "$H" --kind merge-untracked --pr 32) ;;
  esac
  jq 'del(.en.how)' "$d/control.json" > "$d/no-how.json"
  assert_eq "$(jq -S 'del(.en.how)' "$d/control.json")" "$(jq -S . "$d/no-how.json")" "$kind: the two requests differ only in how"
  n=$((n+1)); out="$(request --request "D-$n" "${args[@]}" --details "$d/control.json" 2>&1)"
  assert_eq 0 "$?" "$kind: the control card with how is accepted"
  assert_ok "test -f '$d/state/pending/D-$n.json'" "$kind: the control card is written"
  : > "$d/ghcalls"
  n=$((n+1)); out="$(request --request "D-$n" "${args[@]}" --details "$d/no-how.json" 2>&1)"
  assert_eq 64 "$?" "$kind: the same card without how is refused"
  assert_contains "$out" 'en.how: expected a nonempty list' "$kind: the refusal names the missing how"
  assert_fail "test -e '$d/state/pending/D-$n.json'" "$kind: the card without how is not written"
  assert_eq '' "$(cat "$d/ghcalls")" "$kind: the refusal reads nothing from GitHub"
done
# The deferred-validation path (a merge card whose intent is missing in one
# locale). No control there is accepted, on the base or here: the card is
# refused for its missing intent, after the pull request is read from GitHub.
# Without how, the card is refused earlier, before any GitHub read.
ste missing | jq '.en.title="MERGE CARD — merge PR #31: x" | ."zh-TW".title="【合併卡】合併 PR #31：x"' > "$d/deferred-control.json"
jq 'del(.en.how)' "$d/deferred-control.json" > "$d/deferred.json"
before="$(ls "$d/state/pending")"
: > "$d/ghcalls"
out="$(request --expected-head "$H" --request D-27004 --task T-031 --kind merge --pr 31 --details "$d/deferred-control.json" 2>&1)"
assert_ne 0 "$?" 'deferred path: the control without intent is refused'
assert_contains "$out" 'intent is required' 'deferred path: the control reaches the deferred intent check'
assert_ne '' "$(cat "$d/ghcalls")" 'deferred path: the control reads the pull request first'
: > "$d/ghcalls"
out="$(request --expected-head "$H" --request D-27004 --task T-031 --kind merge --pr 31 --details "$d/deferred.json" 2>&1)"
assert_eq 64 "$?" 'deferred path: the same card without how is refused'
assert_contains "$out" 'en.how: expected a nonempty list' 'deferred path: the refusal names the missing how'
assert_eq '' "$(cat "$d/ghcalls")" 'deferred path: without how, nothing is read from GitHub'
assert_eq "$before" "$(ls "$d/state/pending")" 'no refused request writes a pending card'

# A term the card text uses must be listed; the stored card explains it.
ste pass | jq '.en.how[0].text="The board shows the card." | ."zh-TW".how[0].text="看板顯示這張卡。"' > "$d/term.json"
out="$(request --request D-27005 --task T-031 --details "$d/term.json" 2>&1)"
assert_eq 65 "$?" 'a card term without its glossary id is refused'
assert_contains "$out" 'en.how: unexplained-term "board"' 'the refusal names the term'
jq '.en.glossary=["board"] | ."zh-TW".glossary=["board"]' "$d/term.json" > "$d/term-listed.json"
pending="$(request --request D-27006 --task T-031 --details "$d/term-listed.json")"
assert_eq 0 "$?" 'the same term with its id is accepted'
assert_eq '[{"id":"board","term":"board","text":"The board is the web page where the captain reads and answers cards."}]' \
  "$(jq -c '.details.en.glossary' "$pending")" 'fm-decide stores the English explanation'
assert_eq '看板' "$(jq -r '.details["zh-TW"].glossary[0].term' "$pending")" 'and the Traditional Chinese one'
assert_eq 'The board shows the card.' "$(jq -r '.details.en.how[0].text' "$pending")" 'the pending card keeps how'

# Request, answer, fallback merge card build and a second request.
before_cards="$(cd "$d/state" && find pending decisions -type f -name '*.json' -exec cksum {} + 2>/dev/null | sort)"
own="$(FM_ROOT="$d" "$d/bin/fm-decide.sh" --allocate --task T-001)"
jq '.en.title="Dispatch T-001: The check passes." | ."zh-TW".title="派工 T-001：檢查通過。"' "$d/term-listed.json" > "$d/dispatch.json"
pending="$(request --request "$own" --task T-001 --purpose dispatch --details "$d/dispatch.json")"
assert_eq 0 "$?" 'a dispatch card with why, how and glossary is raised'
jq '. + {chosen:"A"}' "$pending" > "$d/state/decisions/$own.json"
PYTHONPATH="$d/bin/lib" python3 -c '
import json, sys
from fm_merge_details import build
print(json.dumps(build(sys.argv[1], "firstmate-workflow", "T-001", 9)))' "$d/state" > "$d/built.json"
assert_eq 0 "$?" 'the fallback merge card builds from the answered dispatch card'
assert_eq '["board","six-gates","scope"]' "$(jq -c '.en.glossary' "$d/built.json")" 'stored glossary objects become ids and fixed sentences add theirs'
assert_eq 'Not reviewed for readability.' "$(jq -r '.en.notes[-1].text' "$d/built.json")" 'the fallback carries the caution'
pr_is "$d" 9 t-001-cache-index 'T-001: cache the index'
second="$(request --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --request D-27007 --task T-001 --kind merge --pr 9 --details "$d/built.json")"
assert_eq 0 "$?" 'the built merge card passes a second request'
assert_eq 'six-gates' "$(jq -r '.details.en.glossary[1].id' "$second")" 'the second request expands the ids again'
assert_eq "$before_cards" "$(cd "$d/state" && find pending decisions -type f -name '*.json' ! -name "$own.json" ! -name 'D-27007.json' -exec cksum {} + 2>/dev/null | sort)" \
  'existing pending and answered cards stay byte-identical'

# Regression: the legacy title-only D-SK path stays accepted, unchanged.
legacy="$(request --request D-SK-270 --task SK-270 --kind choice --title 'skill-update: worker')"
assert_eq 0 "$?" 'the legacy title-only skill request is still accepted'
assert_eq 'null' "$(jq -r .details "$legacy")" 'and it still invents no details'
rm -rf "$d"

finish
