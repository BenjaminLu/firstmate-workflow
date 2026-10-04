#!/usr/bin/env bash
# Feature dependencies: bin/ci.sh bin/lib/fm_ci_checks.py bin/lib/fm_prompt_context.py
# design/design.md tests/lib/design_anchors.py tests/fixtures/design-anchors-before-T189.json
# tests/lib/config-modules.sh
# T-189: design changes go into their numbered home section, never onto the
# end of design.md, and no heading a task prompt anchors may disappear.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
# shellcheck source=tests/lib/config-modules.sh
. "$ROOT/tests/lib/config-modules.sh"

fixture="$ROOT/tests/fixtures/design-anchors-before-T189.json"

# The permanent superset check: the references each spec carried when the
# fixture was taken still resolve every heading text they resolved then.
out="$(python3 "$ROOT/tests/lib/design_anchors.py" check "$fixture" "$ROOT/design/design.md" 2>&1)"
assert_eq 0 "$?" "every heading recorded before the T-189 move still resolves in design.md"
assert_contains "$out" ", 0 recorded headings lost" "and the check says how many it lost"

d="$(safe_tmpdir)"
# The check is not vacuous: a design that lost a recorded heading is refused.
sed 's/^### 15\.10 Concurrent projects$/### 15.10 Projects running at once/' \
  "$ROOT/design/design.md" > "$d/renamed.md"
out="$(python3 "$ROOT/tests/lib/design_anchors.py" check "$fixture" "$d/renamed.md" 2>&1)"
assert_eq 1 "$?" "a renamed anchored heading fails the superset check"
assert_contains "$out" "heading no longer resolves: 15.10 Concurrent projects" "and names the lost heading"

# The guard itself, on small designs. The last numbered section is §3.
layout() { python3 "$ROOT/bin/lib/fm_ci_checks.py" design-layout "$1" 2>&1; }
out="$(layout "$d/missing.md")"
assert_eq 0 "$?" "a missing design passes the layout check"
assert_eq "" "$out" "a missing design prints nothing"
base='# d\n\n## 1. One\n\n### What it is not\n\nprose\n\n## 2. Two\n\n### Unnumbered earlier\n\n## 3. Last\n\n### 3.1 Home\n\nbody\n'
printf '%b\n### Appended at the end (T-999)\n\nmore\n' "$base" > "$d/planted.md"
out="$(layout "$d/planted.md")"
assert_eq 1 "$?" "an unnumbered ### at the end of the last section is refused"
assert_contains "$out" "planted.md:19: ### Appended at the end (T-999)" "with its line and heading"
printf '%b\n```md\n### Appended at the end (T-999)\n```\n' "$base" > "$d/fenced.md"
out="$(layout "$d/fenced.md")"
assert_eq 0 "$?" "a ### line inside a fenced block is not a heading"
printf '%b\n~~~~md\n### Fenced heading\n~~~\n### Still fenced\n~~~~\n' "$base" > "$d/tilde.md"
out="$(layout "$d/tilde.md")"
assert_eq 0 "$?" "a shorter fence does not close the tilde block"
printf '%b\n#### Nested at the end (T-999)\n\n##### deeper\n' "$base" > "$d/nested.md"
out="$(layout "$d/nested.md")"
assert_eq 0 "$?" "#### and deeper headings at the end nest under the numbered home"
printf '# d\n\n## 1. One\n\n### What it is not\n\n## 2. Last\n\nonly prose\n' > "$d/flat.md"
out="$(layout "$d/flat.md")"
assert_eq 0 "$?" "a last section with no ### at all passes, and earlier unnumbered ### stay legal"
out="$(layout "$ROOT/design/design.md")"
assert_eq 0 "$?" "the moved design.md passes the guard"
assert_eq "" "$out" "and prints nothing"

# Through the hygiene stage of bin/ci.sh, on a fixture tree.
q="$(safe_tmpdir)"; mkdir -p "$q/bin"
cp "$ROOT/bin/ci.sh" "$ROOT/bin/fm-config.sh" "$q/bin/"; config_modules_fixture "$q/bin/"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" --stage fast 2>&1)"
assert_lacks "$out" "design layout" "a tree without design/design.md skips the check silently"
mkdir -p "$q/design"; cp "$d/planted.md" "$q/design/design.md"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" --stage fast 2>&1)"
assert_contains "$out" "x design layout: an unnumbered ### heading in the last section of design.md" \
  "a planted unnumbered ### at the end turns the hygiene stage red"
assert_contains "$out" "design/design.md:19: ### Appended at the end (T-999)" "and the stage names it"
cp "$ROOT/design/design.md" "$q/design/design.md"
out="$(FM_ROOT="$q" bash "$q/bin/ci.sh" --stage fast 2>&1)"
assert_contains "$out" "+ design layout" "the moved design.md is green in the hygiene stage"
assert_lacks "$out" "x design layout" "and nothing in it is refused"

safe_rm_rf "$q"
safe_rm_rf "$d"
finish
