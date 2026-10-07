#!/usr/bin/env bash
# Observable services; this does not dispatch a fleet or authorize work.
set -uo pipefail
exec < /dev/null
_fm_lib="$(dirname "${BASH_SOURCE[0]}")/fm-config.sh"
[ -f "$_fm_lib" ] || { echo "fm-session: missing $_fm_lib" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$_fm_lib"
fm_args=("$@")
REPO="${FM_ROOT:-$(pwd)}"; MODE=start; DECISION=all; TIMEOUT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project) fm_need "fm-session" "$@"; export FM_PROJECT="${2-}"; shift 2 ;;
    start|status|wait|ack) MODE="$1"; shift ;;
    # T-151: nothing watches for a decision any more; the writer pushes the
    # wake, and `wait` is the caller's own foreground read of it
    watch|stop) echo "fm-session: $1 is gone (T-151): the board pushes every wake; run fm-session.sh wait to block on it" >&2; exit 64 ;;
    --repo) fm_need "fm-session" "$@"; REPO="$2"; shift 2 ;;
    --decision) fm_need "fm-session" "$@"; DECISION="$2"; shift 2 ;;
    --timeout) fm_need "fm-session" "$@"; TIMEOUT="$2"; shift 2
               [[ "$TIMEOUT" =~ ^[0-9]{1,6}$ ]] || { echo "fm-session: --timeout takes whole seconds" >&2; exit 64; } ;;
    *) echo "fm-session: unknown argument $1" >&2; exit 64 ;;
  esac
done
cd "$REPO" || exit 64
REPO="$(pwd -P)"
fm_storage_init "$REPO" || exit 65
fm_freeze "$0" "$REPO" ${fm_args[@]+"${fm_args[@]}"}
# Refresh only in firstmate's session, never when a board launches a round.
if { [ "$MODE" = start ] || [ "$MODE" = status ]; } &&
   [ -z "${FM_IN_ROUND:-}" ] && [ -z "${FM_RUN_DIR:-}" ]; then
  if ! python3 "${FM_CODE_ROOT:-$REPO}/bin/lib/fm_host.py" "$REPO" "$FM_STATE_DIR"; then
    if [ -e "$FM_STATE_DIR/session/host.json" ]; then
      recorded="$(jq -r '.harness // "unknown"' "$FM_STATE_DIR/session/host.json" 2>/dev/null)"
      echo "fm-session: host refresh failed; keeping the recorded host ${recorded:-unknown}" >&2
    else
      echo 'fm-session: host refresh failed; firstmate host is unknown' >&2
      # A failed informational collector must not destroy previously known facts.
      host_tmp=''
      if mkdir -p "$FM_STATE_DIR/session" &&
         host_tmp="$(mktemp "$FM_STATE_DIR/session/.host-XXXXXXXX")" &&
         printf '%s\n' '{"harness":null,"cli_version":null,"model":null,"model_source":null}' > "$host_tmp" &&
         mv -f "$host_tmp" "$FM_STATE_DIR/session/host.json"; then
        :
      else
        [ -z "$host_tmp" ] || rm -f "$host_tmp"
        echo 'fm-session: could not write the unknown host record' >&2
      fi
    fi
  fi
fi
if [ "$MODE" = start ] || [ "$MODE" = status ]; then
  jq -r 'select(.confirmed == false and .harness != null) |
    "fm-session: firstmate host record is unconfirmed: it says \(.harness) (recorded \(.unconfirmed_since // "unknown") by session \(.session.pid // "unknown")); this session could not detect its own harness. Run with FM_HARNESS=<claude|codex> bin/fm-session.sh status to confirm it."' \
    "$FM_STATE_DIR/session/host.json" >&2 2>/dev/null || true
fi
# The reviewer's engine is the captain's to choose. A project that names none
# is said out loud here, once per start, rather than reviewed by whatever the
# top-level vendor happens to be: firstmate asks on the board and the answer
# lands in config.yaml through a pull request.
if [ "$MODE" = start ]; then
  rv="$(fm_cfg_in reviewer vendor)"; rmodel="$(FM_EXTERNAL=0 fm_model reviewer config.yaml)"
  if [ -z "$rv" ] || [ -z "$rmodel" ]; then
    installed=''
    for a in "${FM_CODE_ROOT:-$REPO}"/bin/adapters/*.sh; do
      a="${a##*/}"; a="${a%.sh}"
      case "$a" in _*|mock) continue ;; esac
      command -v "$a" >/dev/null 2>&1 && installed="${installed:+$installed }$a"
    done
    missing=''
    [ -n "$rv" ] || missing=vendor
    [ -n "$rmodel" ] || missing="${missing:+$missing and }model"
    echo "fm-session: config.yaml names no reviewer $missing; the reviewer is the captain's choice - ask on the board (installed adapters: ${installed:-none})" >&2
  else
    fm_model_known "$rv" "$rmodel"
    [ $? -eq 1 ] && echo "fm-session: config.yaml's reviewer model '$rmodel' is not one $rv is known to accept; check it before dispatching (T-127)" >&2
  fi
  wv="$(FM_EXTERNAL=0 fm_role_vendor worker config.yaml)"; wmodel="$(FM_EXTERNAL=0 fm_model_for worker "$wv" config.yaml)"
  if [ -n "$wv" ] && [ -n "$wmodel" ]; then
    fm_model_known "$wv" "$wmodel"
    [ $? -eq 1 ] && echo "fm-session: config.yaml's worker model '$wmodel' is not one $wv is known to accept; check it before dispatching (T-127)" >&2
  fi
fi
# The hooks that wake firstmate (T-137) are armed from the first session:
# start installs them, for the harness it detects, into that harness's
# local, uncommitted config (bin/lib/fm_hooks.py, which the fm command
# line's hooks runs too). A harness it cannot name is said, and the session
# starts anyway.
if [ "$MODE" = start ]; then
  if ! python3 "${FM_CODE_ROOT:-$REPO}/bin/lib/fm_hooks.py" install --detect --repo "$REPO" >&2; then
    echo "fm-session: the hooks that wake firstmate were not installed; run bin/lib/fm_hooks.py install --harness claude|codex|cursor" >&2
  fi
  "${FM_CODE_ROOT:-$REPO}/bin/fm-doctor.sh" --hooks-only --repo "$REPO" >&2 ||
    echo "fm-session: hook guidance unavailable; run fm doctor --hooks-only" >&2
fi
if [ "$MODE" = start ] && [ -z "${FM_IN_ROUND:-}" ] &&
   { [ -z "${FIRSTMATE_CI_SESSION:-}" ] || [ "${FM_AUTOPILOT_TEST_ENABLE:-0}" = 1 ]; } &&
   [ -x "${FM_CODE_ROOT:-$REPO}/bin/fm-autopilot.sh" ]; then
  "${FM_CODE_ROOT:-$REPO}/bin/fm-autopilot.sh" ensure --all --repo "$REPO" >&2 ||
    echo 'fm-session: autopilot unavailable; inspect project state/autopilot/service.log' >&2
fi
# The board serves REPO/board, so build there, even with a frozen launcher.
if [ "$MODE" = start ] && [ -f "$REPO/games/voyage-2d/tools/prepare-board.sh" ]; then
  bash "$REPO/games/voyage-2d/tools/prepare-board.sh" "$REPO" >&2 || :
fi
exec python3 "${FM_CODE_ROOT:-$REPO}/bin/fm-herdr.py" session "$MODE" "$REPO" "$DECISION" "$TIMEOUT"
