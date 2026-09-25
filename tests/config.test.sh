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

# --- the project registry and the two roots (design 15.1, 15.2) ----------
# A refusal is asserted by its exit code, never by assert_fail: a resolver
# that does not exist fails too, and would pass every one of these.
r="$(mktemp -d)"
engine="$(cd "$r" && pwd -P)"
rc_of() { "$@" > "$r/out" 2> "$r/err"; printf '%s' "$?"; }
registry() {   # registry <example-app entry lines> ; the self entry is fixed
  { printf 'vendor: claude\ndefault_project: self-host   # the engine\n'
    printf 'projects:               # every repository\n'
    printf '  self-host:            # this one\n    repo: .\n'
    printf '    github: owner-a/engine\n    base: main\n    required_check: ci\n'
    printf '    design: design/design.md\n    tasks: design/tasks.json\n'
    printf '  example-app:\n%s\n' "$1"
    printf 'project:\n  setup: make deps && echo "$(not evaluated)"\n  check: make check\n'
    printf '  check_env:\n    BUDGET: "600"\n  tests:\n    - tests/**\n'
    printf '  test: bash {file}\n  docs:\n    - docs/**\n    - README.md\n'
    printf 'concurrency: 3\n'
  } > "$r/config.yaml"
}
app='    github: example-org/example-app
    base: trunk
    required_check: check
    project:
      check: npm test
      docs:
        - "*.md"'
registry "$app"
c="$r/config.yaml"

assert_eq "self-host
example-app" "$(fm_projects "$c")" "the registry lists every project, in order"
assert_eq "self-host" "$(fm_project_resolve '' "$c")" "no --project and no FM_PROJECT: default_project"
assert_eq "example-app" "$(FM_PROJECT=example-app fm_project_resolve '' "$c")" "FM_PROJECT beats the default"
assert_eq "self-host" "$(FM_PROJECT=example-app fm_project_resolve self-host "$c")" "--project beats FM_PROJECT"

# never inferred: a shell standing inside another project's managed clone,
# whose remote is that project's repository, still resolves the default
clone="$r/state/projects/example-app/repo"
mkdir -p "$clone"
git -C "$clone" init -q && git -C "$clone" remote add origin https://github.com/example-org/example-app.git
assert_eq "self-host" "$(cd "$clone" && fm_project_resolve '' "$c")" \
  "the current directory, its remote and its worktree choose nothing"

assert_eq "design/design.md" "$(fm_project_get self-host design "$c")" "a declared design path is read"
assert_eq "design/tasks" "$(fm_project_get self-host tasks "$c")" "a declared task list is read"
assert_eq "projects/example-app/design.md" "$(fm_project_get example-app design "$c")" "design defaults under projects/<name>"
assert_eq "projects/example-app/tasks" "$(fm_project_get example-app tasks "$c")" "and so does the task list"
assert_eq "example-org/example-app" "$(fm_project_get example-app github "$c")" "github is read"
assert_eq "trunk" "$(fm_project_get example-app base "$c")" "base is read"
assert_eq "check" "$(fm_project_get example-app required_check "$c")" "required_check is read"
assert_eq "." "$(fm_project_get self-host repo "$c")" "repo is read"
assert_eq "$engine" "$(fm_project_get self-host root "$c")" "repo . has the engine root as its project root"
assert_eq "$engine/state/projects/example-app/repo" "$(fm_project_get example-app root "$c")" \
  "any other project's root is its managed clone"
assert_eq "example-app|$engine/state/projects/example-app/repo" \
  "$( fm_project_use example-app "$c" && bash -c 'printf "%s|%s" "$FM_PROJECT" "$FM_PROJECT_ROOT"' )" \
  "fm_project_use exports the name and the root to children"

# the self entry's contract is T-043's top-level block, whole
for k in keys setup check test tests docs; do
  assert_eq "$(fm_project "$k" "$c")" "$(fm_project_contract self-host "$k" "$c")" \
    "the self contract's $k is the top-level block's"
done
assert_eq "$(fm_project check_env "$c" | tr '\0' '|')" \
  "$(fm_project_contract self-host check_env "$c" | tr '\0' '|')" "and so is its check_env"
assert_eq 'make deps && echo "$(not evaluated)"' "$(fm_project_contract self-host setup "$c")" \
  "a contract value comes back exactly as declared"
assert_eq "check
docs" "$(fm_project_contract example-app keys "$c")" "another project's contract is its own block"
assert_eq "npm test" "$(fm_project_contract example-app check "$c")" "and reads through the same parser"
assert_eq "*.md" "$(fm_project_contract example-app docs "$c")" "docs included"

# every refusal is 65 and names the project and the field
refused() {   # refused <label> <project> <field> <command...>
  local label="$1" name="$2" field="$3"; shift 3
  assert_eq "65" "$(rc_of "$@")" "$label: exit 65"
  assert_contains "$(cat "$r/err")" "project $name" "$label: names the project"
  assert_contains "$(cat "$r/err")" "$field" "$label: names the field"
}
refused "an unregistered --project" nosuch name fm_project_resolve nosuch "$c"
refused "an unregistered FM_PROJECT" ghost name env FM_PROJECT=ghost bash -c \
  '. "$1/bin/fm-config.sh"; fm_project_resolve "" "$2"' _ "$ROOT" "$c"
refused "a field lookup on an unregistered name" nosuch name fm_project_get nosuch base "$c"
refused "a name outside [a-z0-9-]" Bad_Name name fm_project_resolve Bad_Name "$c"
refused "a name longer than 24 characters" abcdefghijklmnopqrstuvwxy name \
  fm_project_resolve abcdefghijklmnopqrstuvwxy "$c"
assert_eq "self-host" "$(FM_PROJECT='' fm_project_resolve '' "$c")" "an empty FM_PROJECT is no project"

registry "$app"; printf '  Upper_Case:\n    github: a/b\n    base: main\n    required_check: ci\n' > "$r/extra"
sed '/^project:/,$d' "$c" > "$r/head"; sed -n '/^project:/,$p' "$c" > "$r/tail"
cat "$r/head" "$r/extra" "$r/tail" > "$c"
refused "a registered name outside [a-z0-9-]" Upper_Case name fm_projects "$c"
registry "$app"; printf '  a-name-of-twenty-five-chr:\n    github: a/b\n    base: main\n    required_check: ci\n' > "$r/extra"
cat "$r/head" "$r/extra" "$r/tail" > "$c"
refused "a registered name longer than 24" a-name-of-twenty-five-chr name fm_projects "$c"

# shellcheck disable=SC2088  # the literal, unexpanded tilde is the bad value
for bad in /Users/someone/example-app ../example-app example-app '~/src/app' '""'; do
  registry "    repo: $bad
    github: example-org/example-app
    base: main
    required_check: check"
  refused "repo $bad" example-app repo fm_project_get example-app root "$c"
done
registry "    repo: .
    github: example-org/example-app
    base: main
    required_check: check"
refused "a second project claiming the engine" example-app repo fm_projects "$c"

for bad in example-app example-org/ /example-app example-org/example-app/extra 'example org/app' ''; do
  registry "    github: $bad
    base: main
    required_check: check"
  refused "github [$bad]" example-app github fm_project_get example-app base "$c"
done
registry "    base: main
    required_check: check"
refused "a missing github" example-app github fm_project_get example-app base "$c"
registry "    github: example-org/example-app
    required_check: check"
refused "a missing base" example-app base fm_project_get example-app github "$c"
registry "    github: example-org/example-app
    base: main"
refused "a missing required_check" example-app required_check fm_project_get example-app github "$c"
# the whole registry is validated, not only the entry asked about
refused "a broken entry refuses every lookup" example-app required_check \
  fm_project_resolve self-host "$c"
# and that includes another project's nested contract, not only its scalars
registry "    github: example-org/example-app
    base: main
    required_check: check
    project:
      bogus: x"
refused "a malformed nested contract refuses every lookup" example-app bogus \
  fm_project_resolve self-host "$c"
refused "and its own contract lookup" example-app project fm_project_contract example-app check "$c"

# one source of truth: a self entry holding its own contract beside the
# top-level block is refused, so the two can never disagree
registry "$app"
while IFS= read -r line; do
  printf '%s\n' "$line"
  if [ "$line" = "    tasks: design/tasks.json" ]; then printf '    project:\n      check: make other\n'; fi
done < "$c" > "$r/both"; mv "$r/both" "$c"
assert_contains "$(cat "$c")" "      check: make other" "(the fixture now holds both blocks)"
refused "the top-level block and a self entry project:" self-host project fm_project_contract self-host check "$c"
refused "and it refuses any lookup, not only the contract" self-host project fm_project_resolve '' "$c"

# no default and nothing named
printf 'projects:\n  only-one:\n    github: a/b\n    base: main\n    required_check: ci\n' > "$c"
assert_eq "65" "$(rc_of fm_project_resolve '' "$c")" "nothing named and no default_project exits 65"
assert_eq "only-one" "$(fm_project_resolve only-one "$c")" "while a named project still resolves"

# a resolver whose parser is missing refuses, rather than dying in a traceback
mkdir -p "$r/lone/bin" && cp "$ROOT/bin/fm-config.sh" "$r/lone/bin/"
assert_eq "65" "$(rc_of bash -c '. "$1/lone/bin/fm-config.sh"; fm_project_resolve only-one "$2"' _ "$r" "$c")" \
  "no fm-herdr.py beside fm-config.sh: exit 65"
assert_contains "$(cat "$r/err")" "fm-herdr.py" "and the message names the missing parser"
assert_lacks "$(cat "$r/err")" "Traceback" "not a Python traceback"
# ...but with no config.yaml there is nothing to parse, so no parser is needed
assert_eq "0" "$(rc_of bash -c '. "$1/lone/bin/fm-config.sh"; fm_projects "$1/absent.yaml"' _ "$r")" \
  "no config and no fm-herdr.py: the registry is empty, exit 0"
assert_eq "" "$(cat "$r/err")" "and nothing is said about the parser"
assert_eq "65" "$(rc_of bash -c '. "$1/lone/bin/fm-config.sh"; fm_project_resolve x "$1/absent.yaml"' _ "$r")" \
  "while resolving a name against it is still refused with 65"
rm -rf "$r"

# --- self-hosting: this repository's own registry ------------------------
own="$ROOT/config.yaml"
assert_eq "firstmate-workflow" "$(fm_project_resolve '' "$own")" "this repository is the default project"
assert_eq "firstmate-workflow" "$(fm_project_resolve firstmate-workflow "$own")" "and resolves when named"
assert_eq ".|BenjaminLu/firstmate-workflow|main|ci|design/design.md|design/tasks" \
  "$(for k in repo github base required_check design tasks; do printf '%s|' "$(fm_project_get firstmate-workflow "$k" "$own")"; done | sed 's/|$//')" \
  "it is registered with its repo, github, base, check, design and tasks"
assert_eq "$(cd "$ROOT" && pwd -P)" "$(fm_project_get firstmate-workflow root "$own")" \
  "its project root is the engine root"
assert_contains "$(fm_project_contract firstmate-workflow keys "$own")" "docs" \
  "its contract is T-043's block, docs included"
for k in keys setup check test tests docs; do
  assert_eq "$(fm_project "$k" "$own")" "$(fm_project_contract firstmate-workflow "$k" "$own")" \
    "its contract's $k is the top-level block's"
done
assert_eq "bin/ci.sh" "$(fm_project check "$own")" "the top-level block still reads as before"
assert_eq "3" "$(fm_cfg concurrency "$own")" "and the registry swallows nothing after it"
# T-068: the community files are documentation to gate 5; config.yaml is not
# (each glob framed by newlines, so only a whole line matches)
own_docs=$'\n'"$(fm_project docs "$own")"$'\n'
for g in LICENSE CODE_OF_CONDUCT.md CONTRIBUTING.md SECURITY.md \
         '.github/ISSUE_TEMPLATE/**' .github/pull_request_template.md; do
  assert_contains "$own_docs" $'\n'"$g"$'\n' "its docs globs declare $g"
done
assert_lacks "$own_docs" $'\n'"config.yaml"$'\n' "and never exempt config.yaml"

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

# --- the task list: one file per task (T-090) ----------------------------
# Every pull request used to append to one array and one hand-kept table,
# so every merge turned every other open pull request into a conflict. A
# task is now design/tasks/<id>.json, and every reader goes through these.
t="$(mktemp -d)"; r="$t"   # rc_of writes beside the fixture
( cd "$t" && git init -q && git config user.name t && git config user.email t@t \
    && git commit -q --allow-empty -m root && git branch -M main )
fm_tasks_write /dev/stdin "$t/design/tasks" <<'J'
{"$schema":"./tasks.schema.json","concurrency":3,"tasks":[
  {"id":"T-002","title":"second","milestone":"M0","depends_on":["T-001"],"scope":["b/**"],"note":"ünïcode — kept"},
  {"id":"T-001","title":"first","milestone":"M0","depends_on":[],"scope":["a/**"]},
  {"id":"SK-001","title":"skill","milestone":"M2","depends_on":["T-002"],"n":1.5}]}
J
assert_eq "SK-001.json T-001.json T-002.json" "$(cd "$t/design/tasks" && echo *)" "one file per task, named by its id"
assert_eq '{"id":"T-001","title":"first","milestone":"M0","depends_on":[],"scope":["a/**"]}' \
  "$(jq -c . "$t/design/tasks/T-001.json")" "holding exactly its entry: same keys, same order, same values"
assert_eq "SK-001 T-001 T-002" "$(fm_tasks "$t/design/tasks" | jq -r .id | paste -sd' ' -)" \
  "fm_tasks lists every task, in id order"
assert_eq '["b/**"]' "$(fm_task T-002 "$t/design/tasks" | jq -c .scope)" "fm_task reads one task"
assert_eq "1" "$(rc_of fm_task T-404 "$t/design/tasks")" "a task with no file is not there"
assert_eq "1" "$(rc_of fm_task ../T-001 "$t/design/tasks")" "and an id that is a path is not an id"

# lossless: the files, concatenated in the old array's order, are the array
old="$(jq -c '.tasks' <<'J'
{"tasks":[{"id":"T-002","title":"second","milestone":"M0","depends_on":["T-001"],"scope":["b/**"],"note":"ünïcode — kept"},
  {"id":"T-001","title":"first","milestone":"M0","depends_on":[],"scope":["a/**"]},
  {"id":"SK-001","title":"skill","milestone":"M2","depends_on":["T-002"],"n":1.5}]}
J
)"
assert_eq "$old" "$(for id in T-002 T-001 SK-001; do cat "$t/design/tasks/$id.json"; done | jq -cs .)" \
  "the migration is lossless: files in the old order equal the old array"

# ...and so was this repository's own. The first commit that removed
# design/tasks.json is compared with its parent, whenever history reaches it:
# the first, because a branch brought over later may delete it again.
# GitHub's checkout is one commit deep; the gates run in the full repository.
mig="$(git -C "$ROOT" log --format=%H --diff-filter=D --reverse -- design/tasks.json 2>/dev/null | sed -n 1p)"
if [ -n "$mig" ] && git -C "$ROOT" cat-file -e "$mig^:design/tasks.json" 2>/dev/null; then
  was="$(git -C "$ROOT" show "$mig^:design/tasks.json" | jq -c '.tasks')"
  now="$(git -C "$ROOT" show "$mig^:design/tasks.json" | jq -r '.tasks[].id' | while IFS= read -r id; do
           git -C "$ROOT" show "$mig:design/tasks/$id.json" 2>/dev/null || echo '"missing"'
         done | jq -cs .)"
  assert_eq "$was" "$now" "this repository's migration: its files, in the old order, equal the old array"
else
  assert_eq "" "$(git -C "$ROOT" ls-files design/tasks.json 2>/dev/null)" \
    "(no history to compare against here; at least nothing still tracks design/tasks.json)"
fi

# reading a branch: the gate, the worker and the reviewer read the branch
# under test, not the working copy
( cd "$t" && git add design && git commit -q -m tasks )
( cd "$t" && git checkout -q -b t-003 && mkdir -p design/tasks \
    && printf '{"id":"T-003","title":"third","depends_on":[],"scope":["c/**"]}\n' > design/tasks/T-003.json \
    && git add design && git commit -q -m t3 && git checkout -q main )
assert_eq '["c/**"]' "$(cd "$t" && fm_task T-003 design/tasks t-003 | jq -c .scope)" "fm_task reads a task from a branch"
assert_eq "1" "$(cd "$t" && rc_of fm_task T-003 design/tasks main)" "and not from a branch that lacks it"
assert_eq "SK-001 T-001 T-002 T-003" "$(cd "$t" && fm_tasks design/tasks t-003 | jq -r .id | paste -sd' ' -)" \
  "fm_tasks lists a branch's tasks"

# A branch opened before T-090 has no design/tasks/, only its own old
# design/tasks.json. Its entry there is the task as that branch says it: a
# task defined only on the branch is found, and one the branch revised is
# read as revised, not as main's file has it.
( cd "$t" && git checkout -q -b old-branch main && git rm -q -r design/tasks && mkdir -p design \
    && printf '{"tasks":[{"id":"T-001","title":"first, revised on the branch","scope":["z/**"]},{"id":"T-OLD","title":"only here","scope":["o/**"]}]}\n' \
       > design/tasks.json && git add design && git commit -q -m old && git checkout -q main )
assert_eq '["o/**"]' "$(cd "$t" && fm_task T-OLD design/tasks old-branch 2>/dev/null | jq -c .scope)" \
  "fm_task finds a task defined only in a branch's old design/tasks.json"
assert_eq '"first, revised on the branch"' "$(cd "$t" && fm_task T-001 design/tasks old-branch 2>/dev/null | jq -c .title)" \
  "and reads a task the branch revised there as revised, not as main's file has it"
assert_eq "0" "$(cd "$t" && rc_of fm_task T-OLD design/tasks old-branch)" "(it is found)"
assert_contains "$(cat "$r/err")" "bin/fm.sh tasks split T-OLD" "and says it read the old array, and how to bring the branch over"
assert_eq "1" "$(cd "$t" && rc_of fm_task T-404 design/tasks old-branch)" "an id in neither is still not there"
assert_eq '"first"' "$(cd "$t" && fm_task T-001 design/tasks t-003 2>/dev/null | jq -c .title)" \
  "(a branch with the task's own file is read from that file)"

# All or nothing: a file that does not read is no task list, never the
# files that did. So is a directory that is not there.
assert_eq "1" "$(rc_of fm_tasks "$t/no-such-dir")" "a missing directory is no task list"
printf '{"id":"T-007",\n' > "$t/design/tasks/T-007.json"
assert_eq "1" "$(rc_of fm_tasks "$t/design/tasks")" "one file that does not parse fails the whole list"
assert_eq "" "$(cat "$r/out")" "and nothing is listed, not the files that did parse"
assert_contains "$(cat "$r/err")" "T-007.json" "and the file is named"
: > "$t/design/tasks/T-007.json"
assert_eq "1" "$(rc_of fm_tasks "$t/design/tasks")" "an empty file is not an empty task"
assert_eq "" "$(cat "$r/out")" "(nothing listed)"
printf '[{"id":"T-007"}]\n' > "$t/design/tasks/T-007.json"
assert_eq "1" "$(rc_of fm_tasks "$t/design/tasks")" "nor is a file that holds something other than one object"
rm -f "$t/design/tasks/T-007.json"
( cd "$t" && git checkout -q -b broken main && : > design/tasks/T-002.json && git add design \
    && git commit -q -m broken && git checkout -q main )
assert_eq "1" "$(cd "$t" && rc_of fm_tasks design/tasks broken)" "on a branch too: an empty blob does not just drop out"
assert_eq "" "$(cat "$r/out")" "(nothing listed from the branch)"
assert_contains "$(cat "$r/err")" "T-002.json" "(and the file is named)"
assert_eq "1" "$(cd "$t" && rc_of fm_tasks design/tasks old-branch)" "a branch with no design/tasks/ has no task list"

# order: ids compared as versions, not as text, which a list whose ids all
# have the same width cannot tell apart; a dotfile is not a task
o="$(mktemp -d)"
for id in T-10 T-9 T-2 SK-1; do printf '{"id":"%s"}\n' "$id" > "$o/$id.json"; done
printf 'junk' > "$o/.DS_Store"; printf 'junk' > "$o/.scratch.json"
assert_eq "SK-1 T-2 T-9 T-10" "$(fm_tasks "$o" | jq -r .id | paste -sd' ' -)" \
  "fm_tasks lists T-2, T-9, T-10 in that order, and skips dotfiles"
assert_eq "0" "$(rc_of fm_tasks_check "$o")" "and the check does not take a dotfile for a task"
rm -rf "$o"

# two branches that each add a task merge with no conflict: parallel work
# never writes the same text, which the one shared array could not promise
( cd "$t" && git checkout -q -b t-004 main && printf '{"id":"T-004","depends_on":["T-001"]}\n' > design/tasks/T-004.json \
    && git add design && git commit -q -m t4 && git checkout -q main \
    && git merge -q --no-edit t-003 && git merge -q --no-edit t-004 ) > "$t/merge.out" 2>&1
assert_eq "0" "$?" "two branches that each add a task merge into main with no conflict"
assert_eq "SK-001 T-001 T-002 T-003 T-004" "$(cd "$t" && fm_tasks | jq -r .id | paste -sd' ' -)" \
  "and main then lists both"
# the old shape, for contrast: two appends to the tail of one array collide
( cd "$t" && git checkout -q -b old-a main && printf '{"tasks":[\n{"id":"T-001"}\n]}\n' > tasks.json \
    && git add tasks.json && git commit -q -m base && git checkout -q -b old-b \
    && printf '{"tasks":[\n{"id":"T-001"},\n{"id":"T-005"}\n]}\n' > tasks.json && git commit -qam b \
    && git checkout -q old-a && printf '{"tasks":[\n{"id":"T-001"},\n{"id":"T-006"}\n]}\n' > tasks.json \
    && git commit -qam a && git merge -q --no-edit old-b ) > "$t/merge.out" 2>&1
assert_ne "0" "$?" "(while two appends to one shared array conflict)"
( cd "$t" && git merge --abort ) 2>/dev/null

# the check ci.sh runs: every file parses, names itself, depends on tasks
# that exist, and there is no cycle
assert_eq "0" "$(rc_of fm_tasks_check "$t/design/tasks")" "a sound task directory passes the check"
printf '{"id":"T-009"}\n' > "$t/design/tasks/T-008.json"
assert_eq "1" "$(rc_of fm_tasks_check "$t/design/tasks")" "an id that is not its file name fails"
assert_contains "$(cat "$r/out")" "T-008.json" "and the check names the file"
printf '{"id":"T-008",\n' > "$t/design/tasks/T-008.json"
assert_eq "1" "$(rc_of fm_tasks_check "$t/design/tasks")" "a file that does not parse fails"
printf '{"id":"T-008","depends_on":["T-404"]}\n' > "$t/design/tasks/T-008.json"
assert_eq "1" "$(rc_of fm_tasks_check "$t/design/tasks")" "a missing dependency fails"
assert_contains "$(cat "$r/out")" "T-404" "and the check names it"
printf '{"id":"T-008","depends_on":["T-010"]}\n' > "$t/design/tasks/T-008.json"
printf '{"id":"T-010","depends_on":["T-008"]}\n' > "$t/design/tasks/T-010.json"
assert_eq "1" "$(rc_of fm_tasks_check "$t/design/tasks")" "a cycle fails"
assert_contains "$(cat "$r/out")" "T-008 -> T-010 -> T-008" "and the check prints the cycle"
rm -f "$t/design/tasks/T-008.json" "$t/design/tasks/T-010.json"
printf '{"tasks":[]}\n' > "$t/design/tasks.json"
assert_eq "1" "$(rc_of fm_tasks_check "$t/design/tasks")" "a design/tasks.json left beside the directory fails"
assert_contains "$(cat "$r/out")" "tasks.json" "and the check says why"
rm -f "$t/design/tasks.json"
assert_eq "0" "$(rc_of fm_tasks_check "$t/design/tasks")" "(and the directory is sound again)"

# the registry names a project's task directory; a declared path in the old
# shape, design/tasks.json, names the directory beside it
c2="$t/config.yaml"
printf 'default_project: a\nprojects:\n  a:\n    repo: .\n    github: o/a\n    base: main\n    required_check: ci\n    tasks: design/tasks.json\n  b:\n    github: o/b\n    base: main\n    required_check: ci\n' > "$c2"
assert_eq "design/tasks" "$(fm_project_get a tasks "$c2")" "a declared task list in the old shape names its directory"
assert_eq "projects/b/tasks" "$(fm_project_get b tasks "$c2")" "and the default is projects/<name>/tasks"
rm -rf "$t"
finish
