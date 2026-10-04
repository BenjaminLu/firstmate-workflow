#!/usr/bin/env bash
# Feature dependencies: bin/lib/fm-spec-preflight.sh bin/lib/fm_spec_preflight.py
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/review.sh
. "$ROOT/tests/lib/review.sh"
d="$(fixture)"; repo="$d/repo"
# Inject boundary failures in foreground functions. No vendor or background
# process is started: this isolates the launcher's trap ordering and signals.
for boundary in before_emit copy term failed; do
  FM_ROOT="$repo" bash -s -- "$repo" "$boundary" > "$d/$boundary.log" 2>&1 <<'S'
set -uo pipefail
REPO="$1"; boundary="$2"; cd "$REPO" || exit 1
. "$REPO/bin/fm-config.sh"
. "$REPO/bin/adapters/_lib.sh"
fm_storage_init "$REPO" || exit 1
TASK=T-Z; NAME=''; VENDOR=claude; PR=''; BRANCH=''; BASE=main
SPEC_FILE="$REPO/design/tasks/T-Z.json"; project_events=()
fm_record_vendor_resolution() { if [ "$boundary" = before_emit ]; then exit 65; fi; }
cp() { if [ "$boundary" = copy ]; then return 1; fi; command cp "$@"; }
fm_auth_filter_chain() { : > "$3"; printf 'claude\n'; }
fm_run_chain() {
  if [ "$boundary" = term ]; then kill -TERM "$$"; fi
  return 65
}
. "$REPO/bin/lib/fm-spec-preflight.sh"
S
  rc=$?
  outcome=refused; expected=65
  if [ "$boundary" = term ]; then outcome=interrupted; expected=143; fi
  if [ "$boundary" = failed ]; then outcome=failed; fi
  assert_eq "$expected" "$rc" "$boundary keeps the launcher's exit status"
  assert_eq "$outcome failed" "$(jq -sr '.[-1].data|"\(.preflight_outcome) \(.result)"' "$repo/state/events.jsonl")" "$boundary emits the matching closing outcome"
  assert_eq agent_finished "$(jq -sr '.[-1].type' "$repo/state/events.jsonl")" "$boundary leaves no boarded actor"
done
rm -rf "$d"
finish
