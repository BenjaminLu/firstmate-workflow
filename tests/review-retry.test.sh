#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/review.sh
. "$ROOT/tests/lib/review.sh"
# --- the retry a round with no verdict gets, once (T-123) -------------------
# The reviewer judges CI evidence instead of running checks. An adapter can
# still end without a signed verdict; the launcher retries once before
# reporting failure, so a transient incomplete response can recover.
dret="$(fixture)"; rret="$dret/repo"; GHret="$(ghstub "$dret")"
tries="$dret/tries"; : > "$tries"
cat > "$rret/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
echo x >> "$FM_TRIES"
if [ "$(wc -l < "$FM_TRIES" | tr -d ' ')" -ge 2 ]; then
  printf 'APPROVE:T-Z\n' > "$3/verdict.txt"
else
  printf 'I have not finished assessing the supplied evidence.\n' > "$3/verdict.txt"
fi
exit 0
M
chmod +x "$rret/bin/adapters/mock.sh"
out="$(cd "$rret" && FM_ROOT="$rret" FM_GH="$GHret" FM_TRIES="$tries" \
  bin/fm-review.sh --task T-Z --branch work --pr 9 2>&1)"
assert_eq "0" "$?" "a round with no verdict on its first try still succeeds, after one automatic retry"
assert_contains "$out" "APPROVE:T-Z" "and the retry's own verdict is the one posted"
assert_eq "2" "$(wc -l < "$tries" | tr -d ' ')" "the adapter ran exactly twice: the try and its one retry"
board="$(jq -r 'select(.type=="crew_status")|[.data.activity.en,.data.activity["zh-TW"]]|join("|")' "$rret/state/events.jsonl" | tr '\n' ' ')"
assert_contains "$board" "retrying" "and the board is told, in English"
assert_contains "$board" "重試" "and in Chinese"
rm -rf "$dret"

# a second empty ending is reported exactly as an unretried one always was -
# never a third attempt, since a genuinely broken engine fails the same way
# every time
dret2="$(fixture)"; rret2="$dret2/repo"; GHret2="$(ghstub "$dret2")"
tries2="$dret2/tries"; : > "$tries2"
cat > "$rret2/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
echo x >> "$FM_TRIES"
printf 'Still assessing the supplied evidence.\n' > "$3/verdict.txt"
exit 0
M
chmod +x "$rret2/bin/adapters/mock.sh"
out2="$(cd "$rret2" && FM_ROOT="$rret2" FM_GH="$GHret2" FM_TRIES="$tries2" \
  bin/fm-review.sh --task T-Z --branch work --pr 9 2>&1)"
assert_eq "3" "$?" "a round with no verdict on either try is reported failed exactly as before"
assert_contains "$out2" "produced no review" "and says so the same way as always"
assert_eq "2" "$(wc -l < "$tries2" | tr -d ' ')" "and retried exactly once, never a second time"
rm -rf "$dret2"

# A round with nothing to retry: an adapter that produced no output at all -
# no bytes in the log, nothing in its own output directory - is never retried,
# unsigned or not. This is the shape a managed launch this round's own
# environment refused (a caller's changed focus, an uncertain pane) takes: no
# engine ever ran, so retrying would only ask the same refused environment
# again, and a stale refusal from the first attempt can even read as settled
# on a second, turning a real refusal into a false success (T-123 review round 2).
dret3="$(fixture)"; rret3="$dret3/repo"; GHret3="$(ghstub "$dret3")"
tries3="$dret3/tries"; : > "$tries3"
cat > "$rret3/bin/adapters/mock.sh" <<'M3'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
echo x >> "$FM_TRIES"
exit 0
M3
chmod +x "$rret3/bin/adapters/mock.sh"
out3="$(cd "$rret3" && FM_ROOT="$rret3" FM_GH="$GHret3" FM_TRIES="$tries3" bin/fm-review.sh --task T-Z --branch work --pr 9 2>&1)"
assert_eq "3" "$?" "a round whose adapter said nothing at all is reported failed on its first try"
assert_contains "$out3" "produced no review" "and says so the same way as always"
assert_eq "1" "$(wc -l < "$tries3" | tr -d ' ')" "and is never retried when nothing spoke at all"
rm -rf "$dret3"


finish
