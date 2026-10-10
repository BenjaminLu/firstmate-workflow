#!/usr/bin/env bash
# T-272: a rejecting reviewer attaches a fix to every open finding, and the
# review after a REJECT goes to another reviewer name.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/review.sh
. "$ROOT/tests/lib/review.sh"
# Shared Python fixtures: tests/lib/review_fixes.py, tests/lib/autopilot_branch_fixture.py
python3 "$ROOT/tests/lib/review_fixes.py" "$ROOT"
assert_eq 0 "$?" 'fix parsing, protocol, patch checks, drafts, rotation and autopilot cases pass'

d="$(fixture)"; rd="$d/repo"
cp "$ROOT/bin/fm-protocol.sh" "$rd/bin/"
cat > "$rd/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$2" "$FM_CAPTURE"
{
  printf '1. open the helper keeps the worker text\n'
  if [ "$FM_TEST_FIX" = with ]; then
    printf '```diff fix-1\n--- a/src/a\n+++ b/src/a\n@@ -1 +1 @@\n-SECRET_WORKER_REASONING\n+fixed\n```\n'
  fi
  printf 'CRITERIA-COMPLETE:T-Z\nREJECT:T-Z\n'
} > "$3/verdict.txt"
M
chmod +x "$rd/bin/adapters/mock.sh"
review() {   # review <round> [--name n]
  local round="$1"; shift
  ( cd "$rd" && FM_ROOT="$rd" FM_CAPTURE="$d/prompt-r$round.md" \
      bin/fm-review.sh --task T-Z --branch work --round "$round" "$@" 2>&1 )
}
latest() { jq -s -r "sort_by(.time) | map(select(.kind==\"verdict\")) | last | $1" "$rd"/state/evidence/*/T-Z/*.json; }
protocol() { ( cd "$rd" && FM_ROOT="$rd" bin/fm-protocol.sh check --task T-Z --repo "$rd" "$@" 2>&1 ); }

FM_TEST_FIX=with review 1 >/dev/null
assert_contains "$(cat "$d/prompt-r1.md" 2>/dev/null)" 'carries exactly one fix proposal - a fenced `diff fix-<N>` unified diff' \
  'the round-one prompt asks for a fix proposal for each open item'
assert_contains "$(cat "$d/prompt-r1.md" 2>/dev/null)" 'one indented line DECISION:T-Z <question>' \
  'and names the indented decision line'
assert_eq '1|complete|applies' "$(latest '[.fix_protocol, .fix_checks.status, .fix_checks.items["1"].apply] | map(tostring) | join("|")')" \
  'the live retain path records the protocol version and the patch check against the reviewed head'
first="$(latest .reviewer.name)"
protocol --round 1 >/dev/null
assert_eq 0 "$?" 'a REJECT whose open item carries a patch satisfies the protocol'

out="$(FM_TEST_FIX=with review 2 --name "$first")"
assert_ne 0 "$?" 'an explicit --name equal to the rejecting reviewer is refused'
assert_contains "$out" 'reviewed the REJECT this round answers' 'and the refusal says why'

FM_TEST_FIX=without review 2 >/dev/null
second="$(latest .reviewer.name)"
assert_ne "$first" "$second" 'the review after a REJECT gets a different reviewer name'
assert_contains "$(cat "$d/prompt-r2.md" 2>/dev/null)" 'the helper keeps the worker text' \
  'and the rotated reviewer receives the prior standing list'
out="$(protocol --round 2)"
assert_eq 3 "$?" 'a new REJECT whose open item has no proposal fails the protocol'
assert_contains "$out" 'open item 1 has no fix proposal or DECISION' 'and the diagnostic names the item'
signature="$(latest .signature)"

FM_TEST_FIX=with review 3 >/dev/null
assert_ne "$second" "$(latest .reviewer.name)" 'the next rejection rotates again'
protocol --round 3 >/dev/null
assert_eq 0 "$?" 'without --signature the latest valid list is judged, as before'
out="$(protocol --round 2 --signature "$signature")"
assert_eq 3 "$?" 'with --signature a later valid record does not mask the triggering REJECT'
assert_contains "$out" 'open item 1 has no fix proposal or DECISION' 'and the bound diagnostic names the item'
rm -rf "$d"
finish
