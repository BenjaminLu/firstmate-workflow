#!/usr/bin/env bash
# One reader, because five copies of the same sed were wrong in the same way.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=bin/fm-config.sh
. "$ROOT/bin/fm-config.sh"

f="$(mktemp)"
cat > "$f" <<'Y'
vendor: claude          # every role uses this unless overridden
model:  "opus-5"
reviewer:
  vendor: cursor-agent  # a different engine buys real adversarial value
  model:  composer
concurrency: 3          # workers in flight at once
editor: code
fallback:               # tried in order on exit 2
  - claude
  - cursor-agent        # second choice
  - gemini
Y

assert_eq "claude"  "$(fm_cfg vendor "$f")"      "a value with a trailing comment"
assert_eq "opus-5"  "$(fm_cfg model "$f")"       "a quoted value"
assert_eq "3"       "$(fm_cfg concurrency "$f")" "the number that broke the dispatcher"
assert_eq "code"    "$(fm_cfg editor "$f")"      "a plain value"
assert_ok "[ \$(( $(fm_cfg concurrency "$f") + 1 )) -eq 4 ]" "and it survives arithmetic"

assert_eq "cursor-agent" "$(fm_cfg_in reviewer vendor "$f")" "a nested value with a comment"
assert_eq "composer"     "$(fm_cfg_in reviewer model "$f")"  "a nested value without one"
assert_eq "" "$(fm_cfg_in reviewer nothere "$f")" "a nested key that is absent"

assert_eq "claude
cursor-agent
gemini" "$(fm_cfg_list fallback "$f")" "a list, comments stripped per item"

assert_eq "" "$(fm_cfg nothere "$f")" "an absent key is empty, not an error"
assert_fail "fm_cfg vendor /no/such/file" "a missing file is an error"

# the nested reader must not reach past its section
cat > "$f" <<'Y'
reviewer:
  vendor: cursor-agent
concurrency: 9
Y
assert_eq "" "$(fm_cfg_in reviewer concurrency "$f")" "it stops at the end of the section"
assert_eq "9" "$(fm_cfg concurrency "$f")" "and the top level still reads"

# nobody parses config.yaml by hand any more
strays="$(grep -ln "config.yaml" "$ROOT"/bin/*.sh | while read -r s; do
  grep -qE "sed .*config\.yaml|awk .*config\.yaml|grep .*config\.yaml" "$s" && basename "$s"; done)"
assert_eq "" "$strays" "no script parses config.yaml on its own"
rm -f "$f"
finish
