#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# --- the round's permission policy (T-105) ------------------------------------
# The worker hands its adapter the policy config.yaml resolves for a worker,
# never the operator's own settings, and reports - does not allow - a host
# the round's proxy refused. The mock stands in for the proxy by writing to
# the file it is handed.
dPol="$(fixture)"; rPol="$dPol/repo"; GHPol="$(ghstub "$dPol")"
printf 'vendor: mock\nfallback:\n  - mock\npolicy:\n  network: registry.npmjs.org\n  worker:\n    cpu: 600\n' \
  > "$rPol/config.yaml"
cat > "$rPol/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = "run" ] || exit 64
cp "$FM_POLICY" "$FM_T_POL/seen-policy.json"
cp "$2" "$FM_T_POL/prompt.md"
printf '%s\n' "${FM_ROUND_UNSANDBOXED:-}" > "$FM_T_POL/hatch"
printf 'npm.evil.example\nnpm.evil.example\n' >> "$FM_POLICY_BLOCKED"
# T-147: OpenAI's user file store, twice over, as the first codex round met it
printf 'sdmntprsouthcentralus.oaiusercontent.com\nsdmntprnortheu.oaiusercontent.com\nsdmntprnortheu.oaiusercontent.com\n' >> "$FM_POLICY_BLOCKED"
mkdir -p "$3/src"; printf 'work\n' > "$3/src/work"
M
chmod +x "$rPol/bin/adapters/mock.sh"
outPol="$(cd "$rPol" && FM_ROOT="$rPol" FM_GH="$GHPol" FM_T_POL="$dPol" bin/fm-worker.sh --task T-Z 2>&1)"
assert_eq "0" "$?" "a round under the crew policy runs"
assert_eq "worker" "$(jq -r .role "$dPol/seen-policy.json" 2>/dev/null)" "the adapter is handed the worker's policy"
assert_eq '["registry.npmjs.org"]' "$(jq -c .network "$dPol/seen-policy.json" 2>/dev/null)" \
  "with the registries config.yaml declares"
assert_eq "600" "$(jq -r .cpu "$dPol/seen-policy.json" 2>/dev/null)" "and the worker's own limits"
assert_eq "" "$(cat "$dPol/hatch" 2>/dev/null)" "and, the operator having asked for nothing, the OS sandbox"
assert_contains "$outPol" "refused undeclared hosts: npm.evil.example" "a host the round was refused is reported"
assert_eq "worker T-Z npm.evil.example" \
  "$(jq -r '"\(.role) \(.task) \(.hosts | join(" "))"' "$rPol/state/policy/blocked-hosts.jsonl" 2>/dev/null)" \
  "once, in the record firstmate raises its choice card from"
assert_eq 'policy.network ["registry.npmjs.org"] proxy' \
  "$(jq -r '"\(.add_to) \(.declared | tojson) \(.source)"' "$rPol/state/policy/blocked-hosts.jsonl" 2>/dev/null)" \
  "which names the key a card would add the host to and what the round already had"
assert_contains "$(jq -r 'select(.type=="crew_status") | .data.activity.en' "$rPol/state/events.jsonl")" \
  "Refused undeclared hosts: npm.evil.example" "and the board is told"
# T-147: OpenAI's user file store is a known refusal, the captain's
# decision: reported once in the round as expected, never as undeclared,
# and never a host a card would offer to add
assert_eq "1" "$(grep -c 'known refusal, expected: sdmntprsouthcentralus.oaiusercontent.com, sdmntprnortheu.oaiusercontent.com - OpenAI' <<< "$outPol")" \
  "OpenAI's user file store is reported once, as a known, expected refusal"
assert_lacks "$outPol" "refused undeclared hosts: npm.evil.example sdmntpr" "and not as an undeclared one"
assert_lacks "$(jq -r 'select(.type=="crew_status") | .data.activity.en' "$rPol/state/events.jsonl")" \
  "oaiusercontent" "nor on the board as one"
assert_eq '["sdmntprsouthcentralus.oaiusercontent.com","sdmntprnortheu.oaiusercontent.com"]' \
  "$(jq -c '.expected' "$rPol/state/policy/blocked-hosts.jsonl" 2>/dev/null)" \
  "the record keeps them apart from the hosts a card would add"
# T-117: the round cannot write the worktree's git directory or reach
# GitHub, so the prompt gives it no save to make: the skill's mid-run
# checkpoint is overridden, after the skill, and saving is fm-worker.sh's
pPol="$(cat "$dPol/prompt.md" 2>/dev/null)"
assert_contains "$pPol" "# Saving your branch in this round" "the prompt says who saves the branch"
assert_contains "$pPol" "do not run \`fm-checkpoint.sh\`" "and tells the round not to checkpoint, which it cannot"
assert_contains "$pPol" "fm-worker.sh alone saves this branch" "since fm-worker.sh saves it"
n_skill="$(grep -n 'Mid-run checkpoint (required)' "$dPol/prompt.md" 2>/dev/null | head -1 | cut -d: -f1)"
n_save="$(grep -n '# Saving your branch in this round' "$dPol/prompt.md" 2>/dev/null | head -1 | cut -d: -f1)"
assert_eq "1" "$([ -n "$n_save" ] && { [ -z "$n_skill" ] || [ "$n_save" -gt "$n_skill" ]; } && echo 1)" \
  "after the skill's checkpoint instruction, which it overrides"
# Invalid host policy and no-CLI refusal are owned by adapter-contract.test.sh.

# --- the operator's escape hatch (T-117) --------------------------------------
# A broken sandbox must never again stop every worker with no way to ship
# its own fix. FM_CREW_UNSANDBOXED=1 in the operator's own shell runs the
# round without the OS sandbox (the adapter reads FM_ROUND_UNSANDBOXED), and
# says so on stderr, in the round's log and on the board, in both languages.
hatch_round() {   # hatch_round <dir> <env...> -> stdout+stderr; the mock's view in <dir>/hatch
  local dd="$1" rr="$1/repo" gg; shift
  gg="$(ghstub "$dd")"
  printf 'vendor: mock\nfallback:\n  - mock\n' > "$rr/config.yaml"
  cp "$rPol/bin/adapters/mock.sh" "$rr/bin/adapters/mock.sh"
  (cd "$rr" && env FM_ROOT="$rr" FM_GH="$gg" FM_T_POL="$dd" "$@" bin/fm-worker.sh --task T-Z 2>&1)
}
dHat="$(fixture)"
outHat="$(hatch_round "$dHat" FM_CREW_UNSANDBOXED=1)"
assert_eq "0" "$?" "a round under the operator's hatch runs"
assert_eq "1" "$(cat "$dHat/hatch" 2>/dev/null)" "and its adapter is told to run without the OS sandbox"
assert_contains "$outHat" "WITHOUT the OS sandbox" "which is said on stderr"
assert_contains "$(cat "$dHat"/repo/state/runs/*/worker.log 2>/dev/null)" "WITHOUT the OS sandbox" \
  "in the round's log"
assert_contains "$(jq -r 'select(.type=="crew_status") | .data.activity.en' "$dHat/repo/state/events.jsonl")" \
  "WITHOUT the OS sandbox (FM_CREW_UNSANDBOXED)" "and on the board"
assert_contains "$(jq -r 'select(.type=="crew_status") | .data.activity["zh-TW"]' "$dHat/repo/state/events.jsonl")" \
  "未使用 OS 沙箱" "in both languages"
# only the operator's own variable opens it: an inherited internal one is
# dropped, and inside a crew round - which fm-sandbox.sh marks - neither is read
dHat2="$(fixture)"
outHat2="$(hatch_round "$dHat2" FM_ROUND_UNSANDBOXED=1)"
assert_eq "0" "$?" "a round that inherited only the internal variable runs"
assert_eq "" "$(cat "$dHat2/hatch" 2>/dev/null)" "under the OS sandbox"
assert_lacks "$outHat2" "WITHOUT the OS sandbox" "and says nothing of a hatch"
dHat3="$(fixture)"
outHat3="$(hatch_round "$dHat3" FM_CREW_UNSANDBOXED=1 FM_IN_ROUND=1)"
assert_eq "" "$(cat "$dHat3/hatch" 2>/dev/null)" "a worker started inside a crew round cannot take the hatch"
assert_contains "$outHat3" "ignoring it" "and says it ignored it"
assert_lacks "$(jq -r 'select(.type=="crew_status") | .data.activity.en' "$dHat3/repo/state/events.jsonl" 2>/dev/null)" \
  "WITHOUT the OS sandbox" "and the board is not told a round ran unconfined"
rm -rf "$dPol" "$dHat" "$dHat2" "$dHat3"


cd "$ROOT" || exit 1
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
