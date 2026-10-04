#!/usr/bin/env bash
# T-184: expose each legacy-pin case to changed-suite fail-first selection.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"

legacy_case() {
  python3 "$ROOT/tests/lib/spec_pins_cases.py" "$ROOT" "SpecPins.$1"
  assert_eq 0 "$?" "$2"
}

legacy_case test_legacy_cli_repin_replaces_authority_without_snapshot_change \
  'legacy repin resolves and gates on v2; decision reuse refuses'
legacy_case test_legacy_repin_rejects_wrong_authority_and_order \
  'legacy repin requires its own newer captain choice'
legacy_case test_legacy_ancestor_under_existing_v2_and_v3 \
  'legacy ancestors permit authorized later versions'
legacy_case test_legacy_migration_does_not_bypass_corruption \
  'legacy migration rejects corrupt snapshots'
legacy_case test_legacy_supersession_metadata_is_checked \
  'legacy supersession metadata remains validated'
legacy_case test_legacy_migration_preserves_history_hash_checks \
  'legacy migration preserves history hash validation'
legacy_case test_post_t171_cross_task_pin_is_not_legacy \
  'post-T171 cross-task approval cannot migrate'
finish
