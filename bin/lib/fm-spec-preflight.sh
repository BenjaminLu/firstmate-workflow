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
FM_SPEC_PREFLIGHT_MODE=1 fm_identity reviewer "$TASK" "$NAME" || exit 70
fm_record_vendor_resolution reviewer "$VENDOR"
export FM_MODEL_ROLE=reviewer FM_MODEL_CONFIG="$FM_CONFIG"
preflight="$FM_RUN_DIR/spec-preflight"
mkdir -p "$FM_RUN_DIR/pinned" "$preflight/out" || exit 70
cp "$SPEC_FILE" "$FM_RUN_DIR/pinned/spec.json" || exit 65
chmod 444 "$FM_RUN_DIR/pinned/spec.json"
export FM_PINNED_DIR="$FM_RUN_DIR/pinned"
export FM_SPEC_PREFLIGHT
FM_SPEC_PREFLIGHT="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$FM_PINNED_DIR/spec.json")" || exit 65
python3 "$preflight_py" prompt --task "$TASK" --spec "$FM_PINNED_DIR/spec.json" \
  --base "$base_head" > "$preflight/prompt.md" || exit 65
# An independent clone has no remote, linked git directory or mutable base ref.
checkout_root="$(mktemp -d "${TMPDIR:-/tmp}/fm-spec-preflight.XXXXXX")" || exit 70
checkout_root="$(cd "$checkout_root" && pwd -P)" || exit 70
checkout="$checkout_root/checkout"
printf '%s\n' "$checkout" > "$preflight/checkout-path"
# On interruption retain the isolated checkout rather than deleting under a
# runner whose termination has not yet been observed.
trap 'fm_record_end "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
git clone -q --no-checkout --no-hardlinks "$FM_TARGET_ROOT" "$checkout" &&
  git -C "$checkout" fetch -q origin "$base_head:refs/fm/head" "$base_head:refs/fm/base" &&
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
fm_run_chain "$code/bin/adapters" "$chain" "$preflight/prompt.md" \
  "$preflight/out" "$preflight/log" '' per-vendor
rc=$?
fm_record_end "$rc"
[ "$rc" = 0 ] || exit "$rc"
python3 "$preflight_py" retain --task "$TASK" --state "$FM_STATE_DIR" \
  --project "$(fm_evidence_project)" --spec "$FM_PINNED_DIR/spec.json" --base "$base_head" \
  --code "$code" --run "$FM_RUN_DIR" --attempt "$FM_CHAIN_ATTEMPT" --vendor "$FM_VENDOR_USED"
result=$?
rm -rf "$checkout_root"
exit "$result"
