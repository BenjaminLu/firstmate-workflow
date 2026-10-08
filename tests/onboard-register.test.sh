#!/usr/bin/env bash
# bin/lib/fm_private_names.py
# Registry insertion follows the reader's block boundaries without changing routing.
set -uo pipefail
for k in $(env | sed -nE 's/^(FM_[^=]*|HERDR_[^=]*|GH_REPO)=.*$/\1/p'); do unset "$k"; done
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
t="$(safe_tmpdir)"; eng="$t/engine"; fresh="$t/fresh"
mkdir -p "$eng" "$fresh"
export FM_HOME="$t/private"
cat > "$t/answers.json" <<'JSON'
{"confirmed":true,"policy_confirmed":true,"captain":"captain","intent":"Start product","product":"Private product brief","repository":"owner/product","visibility":"private","base":"main","bootstrap_authorized":true,"merge_method":"squash","available_merge_methods":["squash"],"delete_branch":false,"required_checks":["ci"],"contract":{"unrunnable":"Missing test credentials","setup":"npm ci","check":"npm test","test":"bash {file}","tests":["tests/*.sh"],"check_env":{"MODE":"private"}}}
JSON
cat > "$t/self" <<'YAML'
  self:
    repo: .
    github: owner/engine
    base: main
    required_check: ci
    policy:
      network: registry.npmjs.org
                        # continuation belongs to self and must stay intact
YAML
cat > "$t/entry" <<'YAML'
  seed:
    github: "owner/product"
    base: "main"
    required_check: "ci"
YAML
fixture() {
  printf 'vendor: mock\nprojects:               # every repository firstmate drives; design section 15.2\n' > "$eng/config.yaml"
  cat "$t/self" >> "$eng/config.yaml"
}
add_seed() {
  "$ROOT/bin/fm-project.sh" add "$fresh" --name seed --repo "$eng" --answers "$t/answers.json" > "$t/out" 2> "$t/err"
}
routing() {
  bash -c '. "$1/bin/fm-config.sh"; fm_project_get seed "$3" "$2/config.yaml"' _ "$ROOT" "$eng" "$1"
}

# (a) The production header shape must not create an invisible second block.
fixture
cp "$eng/config.yaml" "$t/expected"
cat "$t/entry" >> "$t/expected"
add_seed
assert_eq 0 "$?" 'commented header accepts a new project'
assert_contains "$(cat "$t/err")" 'fm-onboard: private-name digests updated (3 added); commit tests/fixtures/private-name-digests.txt through a task PR' 'registration reports digest additions'
python3 - "$eng" <<'PYTEST'
import hashlib
from pathlib import Path
import sys
lines = (Path(sys.argv[1]) / 'tests/fixtures/private-name-digests.txt').read_text().splitlines()
assert {hashlib.sha256(n.encode()).hexdigest() for n in ('seed', 'owner/product', 'product')} == {s for s in lines if not s.startswith('#')}, 'onboarding records external names but excludes self owner'
PYTEST
assert_eq 0 "$?" 'onboarding writes the new project digests'

assert_eq 1 "$(grep -c '^projects:' "$eng/config.yaml")" 'commented header retains exactly one projects block'
assert_eq owner/product "$(routing github)" 'new github routing is visible through fm_project_get'
assert_eq main "$(routing base)" 'new base routing is visible through fm_project_get'
sed -n '/^  self:/,/^  seed:/{ /^  seed:/d; p; }' "$eng/config.yaml" > "$t/self-after"
assert_ok 'cmp "$t/self" "$t/self-after"' 'every self entry line remains byte-identical'
assert_ok 'cmp "$t/expected" "$eng/config.yaml"' 'entry is appended after the indented comment continuation'

assert_eq 'Missing test credentials' "$(bash -c '. "$1/bin/fm-config.sh"; fm_project unrunnable "$2"' _ "$ROOT" "$FM_HOME/projects/seed/state/config.yaml")" 'onboarding writes an unrunnable reason that the contract parser reads back'

# (d) Re-onboarding preserves the complete file, including its comments.
cp "$eng/config.yaml" "$t/once"
add_seed
assert_eq 0 "$?" 'same binding can be onboarded twice'
assert_ok 'cmp "$t/once" "$eng/config.yaml"' 'second onboarding is byte-identical'

# (b) Blank lines and column-zero comments preceding a top-level key stay after seed.
fixture
cp "$eng/config.yaml" "$t/expected"
cat > "$t/tail" <<'YAML'

# Choose the default project below.
default_project: self
YAML
cat "$t/tail" >> "$eng/config.yaml"
cat "$t/entry" "$t/tail" >> "$t/expected"
add_seed
assert_eq 0 "$?" 'block followed by a top-level key accepts seed'
assert_ok 'cmp "$t/expected" "$eng/config.yaml"' 'seed precedes the following top-level comment and key'
assert_eq owner/product "$(routing github)" 'routing stops at the following top-level key'

# (c) Refuse ambiguity before writing any bytes, for bare and commented headers.
for second in 'projects:' 'projects: # duplicate'; do
  fixture
  printf '\n%s\n  other:\n    github: owner/other\n    base: main\n    required_check: ci\n' "$second" >> "$eng/config.yaml"
  cp "$eng/config.yaml" "$t/before"
  add_seed; status=$?
  assert_ok "[ $status -ne 0 ]" 'two projects blocks refuse onboarding'
  assert_contains "$(cat "$t/err")" 'more than one projects: block' 'duplicate-block refusal explains manual repair'
  assert_ok 'cmp "$t/before" "$eng/config.yaml"' 'duplicate-block refusal preserves config bytes'
done

# (e) A commented existing name cannot be rebound, including a base-only change.
for binding in github base; do
  fixture
  printf '  seed:   # pilot\n' >> "$eng/config.yaml"
  if [ "$binding" = github ]; then
    printf '    github: owner/other\n    base: main\n' >> "$eng/config.yaml"
  else
    printf '    github: owner/product\n    base: release\n' >> "$eng/config.yaml"
  fi
  printf '    required_check: old-check\n' >> "$eng/config.yaml"
  cp "$eng/config.yaml" "$t/before"
  add_seed; status=$?
  assert_ok "[ $status -ne 0 ]" "commented existing name refuses changed $binding"
  assert_contains "$(cat "$t/err")" 'existing registry binding differs' 'existing binding refusal remains explicit'
  assert_ok 'cmp "$t/before" "$eng/config.yaml"' 'binding refusal preserves config bytes'
done
fixture
printf '  seed:   # pilot\n    github: owner/product\n    base: main\n    required_check: old-check\n' >> "$eng/config.yaml"
cp "$eng/config.yaml" "$t/before"
add_seed
assert_eq 0 "$?" 'commented matching name remains idempotent'
assert_ok 'cmp "$t/before" "$eng/config.yaml"' 'matching name retains its existing required_check and comment'

# (f) With no registry, retain the existing append behavior.
printf 'vendor: mock\n' > "$eng/config.yaml"
printf 'vendor: mock\n\nprojects:\n' > "$t/expected"
cat "$t/entry" >> "$t/expected"
add_seed
assert_eq 0 "$?" 'config without a projects block accepts seed'
assert_eq 1 "$(grep -c '^projects:' "$eng/config.yaml")" 'missing block is appended exactly once'
assert_ok 'cmp "$t/expected" "$eng/config.yaml"' 'no-block append preserves existing text'
assert_eq owner/product "$(routing github)" 'appended entry can be read back'

# An empty block inserts at the header, and unterminated lines gain one newline.
for shape in empty header-eof entry-eof crlf; do
  case "$shape" in
    empty)
      printf 'projects: # empty\n' > "$eng/config.yaml"
      cp "$eng/config.yaml" "$t/expected"
      printf '# Other settings.\nlanguage: en\n' > "$t/empty-tail"
      cat "$t/empty-tail" >> "$eng/config.yaml"
      cat "$t/entry" "$t/empty-tail" >> "$t/expected"
      ;;
    header-eof)
      printf 'projects: # empty' > "$eng/config.yaml"
      printf 'projects: # empty\n' > "$t/expected"
      cat "$t/entry" >> "$t/expected"
      ;;
    entry-eof)
      fixture
      python3 - "$eng/config.yaml" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_bytes(path.read_bytes().rstrip(b'\n'))
PY
      cp "$eng/config.yaml" "$t/expected"
      printf '\n' >> "$t/expected"
      cat "$t/entry" >> "$t/expected"
      ;;
    crlf)
      fixture
      python3 - "$eng/config.yaml" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_bytes(path.read_bytes().replace(b'\n', b'\r\n'))
PY
      cp "$eng/config.yaml" "$t/expected"
      cat "$t/entry" >> "$t/expected"
      ;;
  esac
  add_seed
  assert_eq 0 "$?" "$shape accepts seed"
  assert_ok 'cmp "$t/expected" "$eng/config.yaml"' "$shape preserves surrounding bytes and separates the new entry"
  assert_eq owner/product "$(routing github)" "$shape routing is readable"
done
# A destination that cannot be replaced must not interrupt private setup.
fixture
rm "$eng/tests/fixtures/private-name-digests.txt"
mkdir "$eng/tests/fixtures/private-name-digests.txt"
rm "$FM_HOME/projects/seed/CONVENTIONS.md" "$FM_HOME/projects/seed/state/config.yaml"
add_seed
assert_eq 0 "$?" 'digest write failure does not fail onboarding'
assert_contains "$(cat "$t/err")" 'fm-onboard: private-name digests not updated:' 'digest failure is reported'
assert_contains "$(cat "$t/err")" "run python3 bin/lib/fm_private_names.py update --repo $eng" 'digest failure supplies recovery command'
assert_eq owner/product "$(routing github)" 'routing survives digest failure'
assert_ok 'test -s "$FM_HOME/projects/seed/CONVENTIONS.md" && test -s "$FM_HOME/projects/seed/state/config.yaml"' 'private setup survives digest failure'
safe_rm_rf "$t"
finish
