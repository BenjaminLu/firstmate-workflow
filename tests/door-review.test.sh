#!/usr/bin/env bash
# T-303: the reviewer of a two-way head checks correctness and scope only, and a
# REJECT goes back to the worker under the same round budget as a one-way head;
# a one-way head gets the full review.
# Feature dependencies: bin/fm-review.sh bin/lib/fm_door.py bin/lib/fm_spec_pins.py
# bin/lib/fm_round_budget.py
# Shared fixtures: tests/lib/review.sh tests/lib/spec-pins.sh tests/lib.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/review.sh
. "$ROOT/tests/lib/review.sh"
# shellcheck source=tests/lib/spec-pins.sh
. "$ROOT/tests/lib/spec-pins.sh"

# review_prompt <door JSON>: the prompt the reviewer of a pinned head is given
review_prompt() {
  d="$(fixture)"; repo="$d/repo"; GH="$(ghstub "$d")"
  printf 'vendor: mock\nproject:\n  check: true\n' > "$repo/config.yaml"
  printf 'state/\n' > "$repo/.gitignore"
  printf '# Approved design\n' > "$repo/design/design.md"
  git -C "$repo" add config.yaml .gitignore design/design.md; git -C "$repo" commit -qm contract
  jq --argjson door "$1" '.door = $door' "$repo/design/tasks/T-Z.json" > "$d/spec.json"
  cp "$d/spec.json" "$repo/design/tasks/T-Z.json"
  seed_spec_pin "$repo" T-Z
  cat > "$repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
cp "$2" "$FM_SEEN/prompt.md"
printf 'APPROVE:T-Z\n' > "$3/verdict.txt"
M
  chmod +x "$repo/bin/adapters/mock.sh"
  (cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-review.sh --task T-Z --branch work) > "$d/out" 2>&1
  review_rc=$?
}

# --- door: two-way review checks correctness and scope ---------------------
review_prompt '{"kind":"two-way","reason":"A revert of the merge undoes it."}'
assert_eq 0 "$review_rc" 'the two-way head is reviewed'
prompt="$(cat "$d/prompt.md" 2>/dev/null)"
# Fail-first: main gives every reviewer the same prompt and names no door.
assert_contains "$prompt" 'This head takes the two-way path: A revert of the merge undoes it.' \
  'door: two-way review checks correctness and scope'
assert_contains "$prompt" 'Check correctness and scope only' 'the review checks correctness and scope only'
assert_contains "$(tr '\n' ' ' <<<"$prompt")" 'Ask for no fail-first evidence, style or migration.' \
  'it asks for no fail-first evidence, style or migration'
assert_contains "$(tr '\n' ' ' <<<"$prompt")" 'A REJECT goes back to the worker as for a one-way head, under the same round budget.' \
  'a REJECT goes back to the worker under the same round budget'
assert_lacks "$prompt" 'stops it for the captain' 'a REJECT does not stop the task'
budget="$(cd "$repo" && python3 -c 'import sys; sys.path.insert(0, "bin/lib"); import fm_round_budget as R
b = R.Budget("state", "self", "T-Z", "config.yaml"); print(b.state_of()["budget"] == b.config["rounds"])')"
assert_eq True "$budget" 'a two-way task has the same round budget as a one-way task'
safe_rm_rf "$d"

# --- a one-way head gets the full review -----------------------------------
review_prompt '{"kind":"one-way","reason":"It changes a stored record format."}'
assert_eq 0 "$review_rc" 'the one-way head is reviewed'
prompt="$(cat "$d/prompt.md" 2>/dev/null)"
assert_contains "$prompt" 'This head takes the one-way path: It changes a stored record format.' 'the one-way prompt names its door'
assert_lacks "$prompt" 'Check correctness and scope only' 'a one-way head gets the full review'
safe_rm_rf "$d"
finish
