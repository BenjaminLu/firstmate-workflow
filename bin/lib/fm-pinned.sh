# shellcheck shell=bash
# Outside-round preparation. Never put private inputs into the target checkout.
fm_round_pinned() { # role spec; verified FM_SPEC_PIN_JSON belongs to the launcher
  local spec="$2"
  export FM_PINNED_DIR="$FM_RUN_DIR/pinned"
  if [ -n "${FM_SPEC_PIN_JSON:-}" ]; then
    python3 "${FM_CODE_ROOT:-$REPO}/bin/lib/fm_prompt_context.py" pin "$1" \
      <<<"$FM_SPEC_PIN_JSON" > "$FM_RUN_DIR/pinned-prompt.md"
  else
    if [ "${FM_EXTERNAL:-0}" = 1 ]; then
      fm_conventions "" >/dev/null || return 65
      FM_ROUND_CONVENTIONS="$(fm_project_get "$FM_PROJECT" conventions "$FM_CONFIG")" || return 65
      export FM_ROUND_CONVENTIONS
    fi
    python3 "${FM_CODE_ROOT:-$REPO}/bin/lib/fm_prompt_context.py" legacy "$1" \
      <<<"$spec" > "$FM_RUN_DIR/pinned-prompt.md"
  fi
}
