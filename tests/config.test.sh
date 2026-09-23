#!/usr/bin/env bash
# One reader, because five copies of the same sed were wrong in the same way.
set -uo pipefail
# A live managed worker exports FM_RUN_DIR / FM_ENTRY_* / FM_WORKER_TASK_LOCK_FD
# and Herdr pane ids into this shell. Suites must not inherit them or freeze,
# identity, locks and pushes bind to the outer run instead of the fixture.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
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

# --- the project contract: opaque command strings, never evaluated ------
p="$(mktemp -d)"
cat > "$p/config.yaml" <<'Y'
vendor: claude
project:                        # what the target project declares
  setup: pip install -r "requirements dev.txt" && touch "$(echo evaluated)"
  check: 'go vet ./... && go test -run ''TestA|TestB'' ./...'  # quoted whole
  check_env:
    GOFLAGS: -mod=mod
    BUDGET: "600"               # a quoted value with a comment
    SPACED: "a # not a comment"
  tests:
    - "**/*_test.go"
    - tests/**                  # the second glob
  test: python3 -m pytest -q {file} && echo "done: {file}"
concurrency: 3
Y
assert_eq 'pip install -r "requirements dev.txt" && touch "$(echo evaluated)"' \
  "$(fm_project setup "$p/config.yaml")" "setup keeps its quotes and && intact"
assert_fail "test -e '$p/evaluated'" "and reading it evaluated nothing"
assert_eq "go vet ./... && go test -run 'TestA|TestB' ./..." \
  "$(fm_project check "$p/config.yaml")" "a single-quoted check unquotes once, '' becomes '"
assert_eq 'python3 -m pytest -q {file} && echo "done: {file}"' \
  "$(fm_project test "$p/config.yaml")" "the test template keeps {file} and its quotes"
assert_eq '**/*_test.go
tests/**' "$(fm_project tests "$p/config.yaml")" "tests is a list of globs, comments stripped"
assert_eq 'GOFLAGS=-mod=mod|BUDGET=600|SPACED=a # not a comment|' \
  "$(fm_project check_env "$p/config.yaml" | tr '\0' '|')" "check_env is NUL-separated KEY=VALUE"
assert_eq 'setup
check
check_env
tests
test' "$(fm_project keys "$p/config.yaml")" "keys names what is declared"
assert_eq "3" "$(fm_cfg concurrency "$p/config.yaml")" "the block does not swallow what follows"

printf 'project:\n  check: make\n  docs:\n    - "docs/**"\n    - README.md   # the front page\n' > "$p/config.yaml"
assert_eq 'docs/**
README.md' "$(fm_project docs "$p/config.yaml")" "docs is a list of globs, comments stripped"
assert_eq 'check
docs' "$(fm_project keys "$p/config.yaml")" "and keys names it"
printf 'project:\n  check: make\n  docs: README.md\n' > "$p/config.yaml"
assert_fail "fm_project docs '$p/config.yaml'" "a docs scalar is refused: it must be a list"

printf 'vendor: claude\n' > "$p/config.yaml"
assert_eq "" "$(fm_project check "$p/config.yaml")" "an undeclared check reads empty"
assert_eq "" "$(fm_project keys "$p/config.yaml")" "and nothing is declared"
assert_ok "fm_project setup '$p/config.yaml'" "absence is not an error"

printf 'project:\n  chek: make test\n' > "$p/config.yaml"
assert_fail "fm_project check '$p/config.yaml'" "a misspelt key is refused, not ignored"
printf 'project:\n  check: make\n  test: pytest -q\n' > "$p/config.yaml"
assert_fail "fm_project test '$p/config.yaml'" "a test template without {file} is refused"
printf 'project:\n  check: "make test\n' > "$p/config.yaml"
assert_fail "fm_project check '$p/config.yaml'" "an unterminated quote is refused"
rm -rf "$p"

# --- the vendor chain, which the worker and the reviewer share -----------
d="$(mktemp -d)"
cat > "$d/config.yaml" <<'YAML'
vendor: claude
reviewer:
  vendor: cursor-agent
fallback:
  - claude
  - codex
  - mock
  - codex
YAML
# the worker passes a role, so that is the call the test has to make
( cd "$d" && . "$ROOT/bin/fm-config.sh"
  printf '%s' "$(fm_vendor_chain worker)" ) > "$d/worker.chain"
assert_eq "claude
codex
mock" "$(cat "$d/worker.chain")" "the worker leads with its vendor and no vendor runs twice"

( cd "$d" && . "$ROOT/bin/fm-config.sh"
  printf '%s' "$(fm_vendor_chain reviewer)" ) > "$d/rev.chain"
assert_eq "cursor-agent
claude
codex
mock" "$(cat "$d/rev.chain")" "the reviewer leads with its own vendor"

( cd "$d" && . "$ROOT/bin/fm-config.sh"
  printf '%s' "$(fm_vendor_chain reviewer gemini)" ) > "$d/exp.chain"
assert_eq "gemini" "$(cat "$d/exp.chain")" "an explicit vendor is the whole chain"

# a worker: block overrides the top level the same way reviewer: does
printf 'vendor: claude\nworker:\n  vendor: codex\nfallback:\n  - mock\n' > "$d/config.yaml"
( cd "$d" && . "$ROOT/bin/fm-config.sh"
  printf '%s' "$(fm_vendor_chain worker)" ) > "$d/w2.chain"
assert_eq "codex
mock" "$(cat "$d/w2.chain")" "a worker block names the worker's engine"
( cd "$d" && . "$ROOT/bin/fm-config.sh"
  printf '%s' "$(fm_vendor_chain reviewer)" ) > "$d/r2.chain"
assert_eq "claude
mock" "$(cat "$d/r2.chain")" "and leaves the reviewer on the top-level one"

# a chain of stub adapters: the first two are unavailable, the third works
mkdir -p "$d/ad" "$d/tree"; : > "$d/log"; echo p > "$d/prompt"
for v in a b; do
  printf '#!/usr/bin/env bash\necho "%s down" >> "$4"\nexit 2\n' "$v" > "$d/ad/$v.sh"
done
printf '#!/usr/bin/env bash\necho "c ran" >> "$4"\nexit 1\n' > "$d/ad/c.sh"
chmod +x "$d/ad"/*.sh
( . "$ROOT/bin/fm-config.sh"
  fm_run_chain "$d/ad" "a b c" "$d/prompt" "$d/tree" "$d/log"; rc=$?
  printf '%s %s %s\n' "$rc" "$FM_VENDOR_USED" "$FM_VENDOR_SKIPPED" ) > "$d/ran"
assert_eq "1 c a b" "$(cat "$d/ran")" "unavailable vendors are skipped, the next verdict stands"

( . "$ROOT/bin/fm-config.sh"
  fm_run_chain "$d/ad" "a b" "$d/prompt" "$d/tree" "$d/log"; printf '%s' "$?" ) > "$d/allout"
assert_eq "2" "$(cat "$d/allout")" "every vendor unavailable is itself unavailable"

# a head with no adapter is a typo in config.yaml and comes straight back
( . "$ROOT/bin/fm-config.sh"
  fm_run_chain "$d/ad" "nosuch c" "$d/prompt" "$d/tree" "$d/log"; printf '%s' "$?" ) > "$d/miss"
assert_eq "65" "$(cat "$d/miss")" "a head with no adapter is a configuration error"
# a fallback entry with no adapter is just skipped
( . "$ROOT/bin/fm-config.sh"
  fm_run_chain "$d/ad" "c nosuch" "$d/prompt" "$d/tree" "$d/log"; printf '%s' "$?" ) > "$d/miss2"
assert_eq "1" "$(cat "$d/miss2")" "a fallback entry with no adapter is passed over"
rm -rf "$d"
finish
