#!/usr/bin/env bash
# T-052 portable launcher context; tests/lib/role_prompts.py owns each case.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib.sh"
for case_name in \
  design_is_bounded_without_trimming_contract_or_conventions \
  small_design_and_legacy_design_use_same_cap \
  run_mode_contract_uses_pin_over_target_config \
  context_identity_for_self_default_explicit_and_external \
  external_fetched_update_refuses_stale_ref \
  self_fetched_update_refuses_stale_ref \
  legacy_binding_resolves_repository \
  self_unknown_remote_refused_before_review \
  pinned_design_keeps_required_sections \
  legacy_design_keeps_required_sections \
  required_sections_over_cap_refuse_instead_of_trimming; do
  python3 "$ROOT/tests/lib/role_prompts.py" "$ROOT" "Prompts.test_$case_name"
  assert_eq 0 "$?" "role prompt: $case_name"
done
finish
