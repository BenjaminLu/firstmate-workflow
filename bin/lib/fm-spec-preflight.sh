# shellcheck shell=bash
# fm:sourced
# shellcheck disable=SC2154  # values validated by the sourcing launcher
# Dedicated launcher path; sourced by the frozen fm-review.sh after routing.
# No PR, pin, ordinary verdict or implementation review is created here.
[ -n "$SPEC_FILE" ] && [ -f "$SPEC_FILE" ] || {
  echo 'fm-review: --spec-preflight requires --spec <file>' >&2; exit 64; }
[ -z "$PR" ] && [ -z "$BRANCH" ] || {
  echo 'fm-review: spec preflight uses the current base, not --pr or --branch' >&2; exit 64; }
[ "${FM_CREW_UNSANDBOXED:-}" != 1 ] || {
  echo 'fm-review: spec preflight requires the reviewer OS sandbox' >&2; exit 65; }
code="${FM_CODE_ROOT:-$REPO}"
preflight_py="$code/bin/lib/fm_spec_preflight.py"
base_head="$(git -C "$FM_TARGET_ROOT" rev-parse "$BASE^{commit}")" || exit 65
# Arm the close immediately after allocation, including setup refusals. On
# interruption retain the checkout: the runner may not yet have terminated.
preflight_started=0
preflight_emit() {
  local kind="$1" en="$2" tw="$3" extra="${4:-}" data
  [ -n "$extra" ] || extra='{}'
  data="$(jq -cn --arg name "$NAME" --argjson identity "$(fm_crew_identity)" \
    --argjson extra "$extra" \
    '{role:"reviewer",crew_name:$name,identity:$identity,mode:"spec-preflight"} + $extra')" || return
  # These are lifecycle/attempt transitions, never periodic heartbeats.
  FM_CREW_STATUS_SECS=0 "$code/bin/fm-emit.sh" ${project_events[@]+"${project_events[@]}"} --actor "$NAME" --task "$TASK" \
    --type "$kind" --data "$data" --en "$en" --tw "$tw" >/dev/null
}
finished() {
  local rc=$? outcome result=failed
  fm_record_end "$rc"
  outcome="$(python3 "$preflight_py" outcome --task "$TASK" --state "$FM_STATE_DIR" \
    --project "$(fm_evidence_project)" --actor "$NAME" --sha "${FM_SPEC_PREFLIGHT:-}" \
    --exit-code "$rc" --started "$preflight_started")" || outcome=failed
  case "$outcome" in spec-ok|spec-gaps|rewrite-refused) result=ok ;; esac
  preflight_emit agent_finished "Spec preflight finished: $outcome" "規格預檢結束：$outcome" \
    "$(jq -cn --arg outcome "$outcome" --arg result "$result" \
      '{preflight_outcome:$outcome,result:$result}')"
}
FM_SPEC_PREFLIGHT_MODE=1 fm_identity reviewer "$TASK" "$NAME" || exit 70
trap finished EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
fm_record_vendor_resolution reviewer "$VENDOR"
head_vendor="$(fm_vendor_chain reviewer "$VENDOR" | head -1)"
fm_record_requested "$head_vendor" "$(fm_model_for reviewer "$head_vendor" "$FM_CONFIG")"
preflight_prepare() {
  preflight_emit crew_status 'Checking the proposed spec' '檢查提議的規格' \
    '{"phase":"review","activity":{"en":"Checking the proposed spec","zh-TW":"檢查提議的規格"}}'
}
preflight_prepare
export FM_MODEL_ROLE=reviewer FM_MODEL_CONFIG="$FM_CONFIG"
preflight="$FM_RUN_DIR/spec-preflight"
mkdir -p "$FM_RUN_DIR/pinned" "$preflight/out" || exit 70
cp "$SPEC_FILE" "$FM_RUN_DIR/pinned/spec.json" || exit 65
chmod 444 "$FM_RUN_DIR/pinned/spec.json"
export FM_PINNED_DIR="$FM_RUN_DIR/pinned"
export FM_SPEC_PREFLIGHT
FM_SPEC_PREFLIGHT="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$FM_PINNED_DIR/spec.json")" || exit 65
# T-270: a dispatch or repin card and the pull-request draft are reviewed in
# the same run, from read-only pinned copies whose hashes the receipt binds.
preflight_inputs=()
pin_input() {  # pin_input <file> <pinned name> <flag> <env>
  [ -n "$1" ] || return 0
  cp "$1" "$FM_PINNED_DIR/$2" || exit 65
  chmod 444 "$FM_PINNED_DIR/$2"
  printf -v "$4" '%s' "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$FM_PINNED_DIR/$2")" || exit 65
  export "${4?}"
  preflight_inputs+=("$3" "$FM_PINNED_DIR/$2")
}
pin_input "${CARD_FILE:-}" card.json --card FM_SPEC_PREFLIGHT_CARD
pin_input "${PR_AUTHORING_FILE:-}" pr-authoring.json --pr-authoring FM_SPEC_PREFLIGHT_PR_AUTHORING
if [ "${FM_EXTERNAL:-0}" = 1 ]; then
  if ! pr_format="$(fm_conventions pr_format 2>/dev/null)"; then
    echo 'fm-spec-preflight: cannot read the PR format' >&2
    exit 65
  fi
  FM_PR_TITLE="$(jq -r '.pr_title' <<<"$pr_format")" || exit 65
  export FM_PR_TITLE
fi
python3 "$preflight_py" prompt --task "$TASK" --spec "$FM_PINNED_DIR/spec.json" --code "$code" \
  ${preflight_inputs[@]+"${preflight_inputs[@]}"} \
  --base "$base_head" --state "$FM_STATE_DIR" --project "$(fm_evidence_project)" > "$preflight/prompt.md" || exit 65
# An independent clone has no remote, linked git directory or mutable base ref.
checkout_root="$(mktemp -d "${TMPDIR:-/tmp}/fm-spec-preflight.XXXXXX")" || exit 70
checkout_root="$(cd "$checkout_root" && pwd -P)" || exit 70
checkout="$checkout_root/checkout"
printf '%s\n' "$checkout" > "$preflight/checkout-path"
fm_git_transfer git clone -q --no-checkout --no-hardlinks "$FM_TARGET_ROOT" "$checkout" &&
  fm_git_transfer git -C "$checkout" fetch -q origin "$base_head:refs/fm/head" "$base_head:refs/fm/base" &&
  git -C "$checkout" checkout -q --detach refs/fm/head &&
  git -C "$checkout" remote remove origin || exit 70
# Keep the clone as evidence. Nothing the round writes can alter it or state.
export FM_RUN_REVIEW=1 FM_REVIEW_CHECKOUT="$checkout"
export FM_REVIEW_HEAD="$base_head" FM_REVIEW_BASE="$base_head" FM_REVIEW_PATCH=''
policy="$preflight/policy.json"
fm_policy reviewer "" "$FM_CONFIG" > "$policy" || exit 65
python3 - "$policy" <<'PY' || exit 65
import json, sys
from pathlib import Path
path = Path(sys.argv[1]); policy = json.loads(path.read_text())
policy['review_root_readonly'] = True
policy['review_git_readonly'] = True
path.write_text(json.dumps(policy))
PY
export FM_POLICY="$policy"
FM_REVIEW_NETWORK="$(python3 "$code/bin/lib/fm_review_network.py" "$policy")"; export FM_REVIEW_NETWORK
chain="$(fm_vendor_chain reviewer "$VENDOR")"
chain="$(fm_auth_filter_chain "$code" "$chain" "$preflight/auth-notes")"
cat "$preflight/auth-notes" >&2
chain="$(fm_review_run_chain "$code/bin/adapters" "$chain")" || exit 65
[ -n "$chain" ] || { echo 'fm-review: no available sandboxed preflight vendor' >&2; exit 65; }
# The same managed transport, lifeline and authenticated final selector as reviews.
# Unlike ordinary review no automatic unsigned retry is a second crew round.
preflight_started=1
fm_run_chain "$code/bin/adapters" "$chain" "$preflight/prompt.md" \
  "$preflight/out" "$preflight/log" '' per-vendor preflight_prepare
rc=$?
fm_record_end "$rc"
[ "$rc" = 0 ] || exit "$rc"
python3 "$preflight_py" retain --task "$TASK" --state "$FM_STATE_DIR" \
  --project "$(fm_evidence_project)" --spec "$FM_PINNED_DIR/spec.json" --base "$base_head" \
  ${preflight_inputs[@]+"${preflight_inputs[@]}"} --out "$preflight/out" \
  --code "$code" --run "$FM_RUN_DIR" --attempt "$FM_CHAIN_ATTEMPT" --vendor "$FM_VENDOR_USED"
result=$?
rm -rf "$checkout_root"
exit "$result"
