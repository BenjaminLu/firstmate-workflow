# shellcheck shell=bash
# Fixture-only dispatch authority; production never fabricates a greenlight.
seed_spec_pin() { # engine fixture, task; approved sources already committed
  local repo="$1" task="$2"
  mkdir -p "$repo/state"
  printf '{"type":"greenlit","actor":"captain","ts":"2026-10-03T00:00:00Z"}\n' >> "$repo/state/events.jsonl"
  (
    unset FM_PROJECT FM_EXTERNAL FM_BASE
    . "$ROOT/bin/fm-config.sh"
    fm_storage_init "$repo" || exit
    fm_pin create --task "$task" >/dev/null
  )
}
