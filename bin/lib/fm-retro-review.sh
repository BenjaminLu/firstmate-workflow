#!/usr/bin/env bash
# One retrospective round (T-273), reached from bin/fm-review.sh --retro
# before any pull request, pin or ordinary verdict logic:
#
#   fm-review.sh --retro <run-id> --project <name>   one project's round
#   fm-review.sh --retro <run-id> --retro-cross      the cross-project round
#
# The round's inputs travel in its prompt, which bin/lib/fm_retro.py built
# and kept in the project's own records; the reviewer reads the engine's base
# commit in a fresh clone, under the reviewer sandbox policy of that project
# with every state directory unreadable. It runs on config.yaml's retro:
# vendor and model only, under the same lifeline, run directory and
# final-answer selection reviews use. An external project's run directory
# and answer stay in that project's private state.
set -uo pipefail
exec < /dev/null
code="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[ "${FM_EXTERNAL:-0}" != 1 ] || {
  echo 'fm-review: a retrospective round starts with the self project'"'"'s context, not FM_EXTERNAL=1' >&2; exit 64; }
# shellcheck source=bin/fm-config.sh
. "$code/bin/fm-config.sh" || exit 70
# shellcheck source=bin/adapters/_lib.sh
. "$code/bin/adapters/_lib.sh" || exit 70
RUN=''; CROSS=''; NAME_ARG=''; ALIAS=''; REPO="$code"
while [ $# -gt 0 ]; do
  case "$1" in
    --retro) [ $# -ge 2 ] || { echo 'fm-review: --retro needs a value' >&2; exit 64; }
             RUN="$2"; shift; shift ;;
    --retro-cross) CROSS=1; shift ;;
    --project) [ $# -ge 2 ] || { echo 'fm-review: --project needs a value' >&2; exit 64; }
               NAME_ARG="$2"; shift; shift ;;
    --repo) [ $# -ge 2 ] || { echo 'fm-review: --repo needs a value' >&2; exit 64; }
            REPO="$2"; shift; shift ;;
    --name) [ $# -ge 2 ] || { echo 'fm-review: --name needs a value' >&2; exit 64; }
            ALIAS="$2"; shift; shift ;;
    --vendor) echo 'fm-review: a retrospective round runs on config.yaml retro: only' >&2; exit 64 ;;
    *) echo "fm-review: --retro takes --project <name> or --retro-cross, not $1" >&2; exit 64 ;;
  esac
done
[[ "$RUN" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$ ]] || { echo 'fm-review: --retro needs a run id' >&2; exit 64; }
{ [ -n "$CROSS" ] && [ -z "$NAME_ARG" ]; } || { [ -z "$CROSS" ] && [ -n "$NAME_ARG" ]; } || {
  echo 'fm-review: --retro takes exactly one of --project <name> and --retro-cross' >&2; exit 64; }
REPO="$(cd "$REPO" && pwd -P)" || exit 64
[ "${FM_CREW_UNSANDBOXED:-}" != 1 ] || { echo 'fm-review: a retrospective round requires the reviewer OS sandbox' >&2; exit 65; }
for _fm_k in FM_PROJECT FM_STATE_DIR FM_TASKS_DIR FM_TARGET_ROOT FM_DESIGN FM_EXTERNAL FM_BASE GH_REPO; do
  unset "$_fm_k"
done
py="$code/bin/lib/fm_retro.py"
info="$(python3 "$py" round-info --engine "$REPO" --run "$RUN" ${CROSS:+--cross} ${NAME_ARG:+--project "$NAME_ARG"})" || exit $?
LABEL="$(jq -r .label <<<"$info")"; PROJECT_NAME="$(jq -r .name <<<"$info")"; PROMPT="$(jq -r .prompt <<<"$info")"
# The retro: section names the vendor and model; no other vendor stands in.
vendor="$(fm_cfg_in retro vendor "$REPO/config.yaml")"
model="$(fm_cfg_in retro model "$REPO/config.yaml")"
[ -n "$vendor" ] || { echo 'fm-review: config.yaml has no retro.vendor' >&2; exit 65; }
[ -n "$model" ] || { echo 'fm-review: config.yaml has no retro.model' >&2; exit 65; }
# The one commit the run resolved from the self project's configured base:
# the prompt names it, the checkout reads it, the round's record carries it.
engine_base="$(jq -r '.base_commit // empty' <<<"$info")"
[[ "$engine_base" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]] && git -C "$REPO" cat-file -e "$engine_base^{commit}" 2>/dev/null || {
  echo 'fm-review: this retrospective run resolved no base commit the engine holds' >&2; exit 65; }
# The project's own context, named explicitly.
fm_storage_init "$REPO" "$PROJECT_NAME" || exit 65
project_events=()
[ -z "$PROJECT_NAME" ] || project_events=(--project "$PROJECT_NAME")
if review_owner="$(python3 "$code/bin/lib/fm_lifeline.py" session-owner 2>&1)"; then
  export FM_SESSION_PID="$review_owner"
else
  echo "fm-review: no session owns this retrospective round: $review_owner" >&2
  exit 75
fi
NAME=''
retro_emit() {
  local kind="$1" en="$2" tw="$3" extra="${4:-}" data
  [ -n "$extra" ] || extra='{}'
  data="$(jq -cn --arg name "$NAME" --argjson identity "$(fm_crew_identity)" --arg label "$LABEL" \
    --arg base "$engine_base" --argjson extra "$extra" \
    '{role:"reviewer",crew_name:$name,identity:$identity,mode:"retro",retro_label:$label,base_commit:$base} + $extra')" || return
  FM_CREW_STATUS_SECS=0 "$code/bin/fm-emit.sh" ${project_events[@]+"${project_events[@]}"} --actor "$NAME" --task retro \
    --type "$kind" --data "$data" --en "$en" --tw "$tw" >/dev/null
}
started=0; accepted=1; checkout_root=''
# The checkout and, for a self or cross round, the run directory's retained
# answer are released only once every managed process of this round has
# ended (bin/lib/fm_retro.py release reads that from the run directory, as
# review checkouts do). On any exit the shell handles - success, failure,
# INT, TERM, HUP - a round whose child may still be live keeps both.
release_round() {
  local contained=() released
  [ "$LABEL" = self ] || [ "$LABEL" = firstmate ] && contained=(--contain)
  released="$(FM_EXTERNAL=0 python3 "$py" release --engine "$REPO" --run-dir "$FM_RUN_DIR" \
    ${checkout_root:+--checkout "$checkout_root"} ${contained[@]+"${contained[@]}"})" || released=''
  [ "$(jq -r '.released // false' <<<"$released" 2>/dev/null)" = true ] ||
    echo "fm-review: a process of this round may still run; kept ${checkout_root:-its run directory} as it is" >&2
}
finished() {
  local rc=$? result=failed
  fm_record_end "$rc"
  [ "$rc" = 0 ] && [ "$accepted" = 0 ] && result=ok
  retro_emit agent_finished "Retrospective round finished: $result" "回顧回合結束：$result" \
    "$(jq -cn --arg result "$result" --argjson started "$started" '{result:$result,started:($started == 1)}')"
  release_round
}
fm_identity reviewer retro "$ALIAS" || exit 70
trap finished EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
fm_record_requested "$vendor" "$model"
retro_prepare() {
  retro_emit crew_status 'Reviewing recent work' '回顧近期工作' \
    '{"phase":"review","activity":{"en":"Reviewing recent work","zh-TW":"回顧近期工作"}}'
}
retro_prepare
export FM_MODEL_ROLE=retro FM_MODEL_CONFIG="$REPO/config.yaml"
out="$FM_RUN_DIR/retro"
mkdir -p "$out/out" || exit 70
# An independent clone of the engine's base: no remote, no linked git
# directory, nothing the round writes reaches the engine or any state.
made="$(mktemp -d "${TMPDIR:-/tmp}/fm-retro-review.XXXXXX")" || exit 70
checkout_root="$(cd "$made" && pwd -P)" || exit 70
checkout="$checkout_root/checkout"
git clone -q --no-checkout --no-hardlinks "$REPO" "$checkout" &&
  git -C "$checkout" fetch -q origin "$engine_base:refs/fm/head" &&
  git -C "$checkout" checkout -q --detach refs/fm/head &&
  git -C "$checkout" remote remove origin || exit 70
export FM_RUN_REVIEW=1 FM_REVIEW_CHECKOUT="$checkout"
export FM_REVIEW_HEAD="$engine_base" FM_REVIEW_BASE="$engine_base" FM_REVIEW_PATCH=''
policy="$out/policy.json"
fm_policy reviewer "$PROJECT_NAME" "$FM_CONFIG" > "$policy" || exit 65
python3 - "$policy" "$info" <<'PY' || exit 65
import json, sys
from pathlib import Path
path = Path(sys.argv[1]); policy = json.loads(path.read_text())
policy['review_root_readonly'] = True
policy['review_git_readonly'] = True
# no state directory is readable: neither the self state nor any project's
policy['never_read'] = sorted(set(policy.get('never_read', [])) | set(json.loads(sys.argv[2])['never_read']))
path.write_text(json.dumps(policy))
PY
export FM_POLICY="$policy"
FM_REVIEW_NETWORK="$(python3 "$code/bin/lib/fm_review_network.py" "$policy")"; export FM_REVIEW_NETWORK
chain="$(fm_auth_filter_chain "$code" "$vendor" "$out/auth-notes")"
cat "$out/auth-notes" >&2 2>/dev/null
chain="$(fm_review_run_chain "$code/bin/adapters" "$chain")" || exit 65
[ "$chain" = "$vendor" ] || { echo "fm-review: the retro vendor $vendor is not available for a sandboxed round" >&2; exit 65; }
started=1
fm_run_chain "$code/bin/adapters" "$chain" "$PROMPT" "$out/out" "$out/log" '' per-vendor retro_prepare
rc=$?
fm_record_end "$rc"
[ "$rc" = 0 ] || exit "$rc"
FM_EXTERNAL=0 python3 "$py" accept --engine "$REPO" --run "$RUN" --label "$LABEL" \
  --run-dir "$FM_RUN_DIR" --attempt "$FM_CHAIN_ATTEMPT" --vendor "$FM_VENDOR_USED" >/dev/null
accepted=$?
exit "$accepted"
