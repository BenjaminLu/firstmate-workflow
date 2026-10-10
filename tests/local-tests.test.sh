#!/usr/bin/env bash
# T-275: a worker round runs only the tests related to its change, inside its
# own sandbox, and reports the results as local evidence. Everything here goes
# through entry points the launcher already had: bin/fm-worker.sh in the
# worker fixture with a test adapter that reads the runner command from the
# round's prompt, bin/fm-sandbox.sh profile, and fm_policy. Fixture suites are
# generated in temporary directories; none is committed under tests/.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Helpers: tests/lib/local_tests.py, tests/lib/worker.sh, tests/lib/crew_blocks.py
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# shellcheck source=bin/fm-config.sh
. "$ROOT/bin/fm-config.sh"
H="$ROOT/tests/lib/local_tests.py"
SB="$ROOT/bin/fm-sandbox.sh"
TEMPLATE_PIN='case {file} in *.test.sh) bash {file} ;; esac'
TEMPLATE_CONFIG='case {file} in *.test.sh) bash {file} from-config ;; esac'
t="$(safe_tmpdir)"

# --- the crew policy's test_budget --------------------------------------------
policy_of() {   # policy_of <role> <config text> [project] -> the policy JSON; its exit code
  printf '%s' "$2" > "$t/config.yaml"
  fm_policy "$1" "${3:-}" "$t/config.yaml" 2>"$t/policy.err"
}
assert_eq 900 "$(policy_of worker 'vendor: mock
' | jq -r .test_budget)" "test_budget is 900 when no layer sets it"
assert_eq 120 "$(policy_of worker 'policy:
  worker:
    test_budget: 120
' | jq -r .test_budget)" "a worker test_budget of 120 is accepted"
for bad in 59 7201 abc; do
  policy_of worker "policy:
  test_budget: $bad
" >/dev/null
  assert_eq 65 "$?" "test_budget $bad is refused"
  assert_contains "$(cat "$t/policy.err")" "test_budget: must be a whole number of seconds from 60 to 7200" \
    "and the refusal names the key and the range ($bad)"
done
flat='policy:
  test_budget: 100
  worker:
    test_budget: 300
'
assert_eq 300 "$(policy_of worker "$flat" | jq -r .test_budget)" "worker: test_budget wins over the flat one"
assert_eq 100 "$(policy_of reviewer "$flat" | jq -r .test_budget)" "and the reviewer keeps the flat one"
assert_eq 200 "$(policy_of worker 'policy:
  test_budget: 100
projects:
  app:
    repo: .
    github: owner/app
    base: main
    required_check: ci
    policy:
      test_budget: 200
' app | jq -r .test_budget)" "a project test_budget wins over the top level"

# --- the sandbox grant ----------------------------------------------------------
run="$t/state/runs/worker-lt-t1-r1"
mkdir -p "$run/pinned" "$run/local-tests" "$t/root" "$t/tmp"
printf '{}' > "$run/pinned/spec.json"; chmod 444 "$run/pinned/spec.json"
printf 'runner\n' > "$run/local-tests/runner.py"; printf '{}\n' > "$run/local-tests/plan.json"
chmod 444 "$run/local-tests/runner.py" "$run/local-tests/plan.json"
chmod 755 "$run/local-tests"
printf 'vendor: mock\n' > "$t/config.yaml"; fm_policy worker "" "$t/config.yaml" > "$t/policy.json"
lt="$run/local-tests"
profile() {   # profile <os> [env...] -> the profile; its exit code
  local os="$1"; shift
  env -u FM_LOCAL_TESTS_DIR FM_SANDBOX_OS="$os" FM_RUN_DIR="$run" FM_PINNED_DIR="$run/pinned" "$@" \
    "$SB" profile --policy="$t/policy.json" --root="$t/root" --tmp="$t/tmp" --listening= 2>/dev/null
}
for os in darwin linux; do
  profile "$os" > "$t/unset.$os"
  profile "$os" FM_LOCAL_TESTS_DIR="$lt" > "$t/set.$os"; rc=$?
  assert_eq 0 "$rc" "$os: a valid local tests folder is granted"
  if [ "$os" = darwin ]; then
    at="$(grep -nxF "(deny file-write* (subpath \"$run/pinned\"))" "$t/unset.$os" | cut -d: -f1)"
    expected="$(awk -v k="${at:-0}" -v a="(allow file-read* (subpath \"$lt\"))" -v b="(deny file-write* (subpath \"$lt\"))" \
      '{ print } NR == k { print a; print b }' "$t/unset.$os")"
  else
    at="$(grep -nxF "$run/pinned" "$t/unset.$os" | tail -1 | cut -d: -f1)"
    expected="$(awk -v k="${at:-0}" -v d="$lt" '{ print } NR == k { print "--ro-bind"; print d; print d }' "$t/unset.$os")"
  fi
  assert_eq "$expected" "$(cat "$t/set.$os")" "$os: the grant is read-only, right after pinned/"
done
# each folder that is not this run's, in this shape, refuses the profile
refused() {   # refused <label> <dir> [env...]
  local label="$1" dir="$2" os; shift 2
  for os in darwin linux; do
    profile "$os" FM_LOCAL_TESTS_DIR="$dir" "$@" >/dev/null
    assert_ne 0 "$?" "$os: refused: $label"
  done
}
reset_folder() {
  chmod -R u+w "$lt" 2>/dev/null; rm -rf "$lt"; mkdir -p "$lt"
  printf 'runner\n' > "$lt/runner.py"; printf '{}\n' > "$lt/plan.json"
  chmod 444 "$lt/runner.py" "$lt/plan.json"; chmod 755 "$lt"
}
refused "a relative path" "state/runs/worker-lt-t1-r1/local-tests"
ln -s "$lt" "$t/linked-local-tests"; mkdir -p "$t/other/local-tests"
refused "a symlinked folder" "$t/linked-local-tests"
mkdir -p "$run/local-test"; refused "the wrong name" "$run/local-test"
mkdir -p "$t/state/runs/worker-lt-t2-r1/local-tests"
cp -p "$lt/runner.py" "$lt/plan.json" "$t/state/runs/worker-lt-t2-r1/local-tests/"
refused "a folder of another run" "$t/state/runs/worker-lt-t2-r1/local-tests"
for os in darwin linux; do
  env -u FM_LOCAL_TESTS_DIR -u FM_RUN_DIR FM_SANDBOX_OS="$os" FM_LOCAL_TESTS_DIR="$lt" \
    "$SB" profile --policy="$t/policy.json" --root="$t/root" --tmp="$t/tmp" --listening= >/dev/null 2>&1
  assert_ne 0 "$?" "$os: refused: an unset FM_RUN_DIR"
done
printf 'x' > "$lt/extra"; refused "an extra file" "$lt"; reset_folder
rm -f "$lt/plan.json"; refused "a missing file" "$lt"; reset_folder
rm -f "$lt/plan.json"; ln -s "$lt/runner.py" "$lt/plan.json"; refused "a child that is a symlink" "$lt"; reset_folder
rm -f "$lt/plan.json"; mkdir "$lt/plan.json"; refused "a child that is a directory" "$lt"; reset_folder
chmod 644 "$lt/plan.json"; refused "a file with mode 0644" "$lt"; reset_folder
chmod 775 "$lt"; refused "a group-writable folder" "$lt"; reset_folder
chmod 757 "$lt"; refused "an other-writable folder" "$lt"; reset_folder
# a folder another user owns: for real where this test can chown (as root in
# the Linux CI container), else the policy module with getuid stubbed (guard)
if [ "$(id -u)" = 0 ] && chown 4242 "$lt" 2>/dev/null; then
  refused "a folder another user owns" "$lt"
  chown 0 "$lt"
else
  python3 -B "$H" uid-guard "$ROOT" "$lt" "$run"
  assert_eq 0 "$?" "guard: the grant checks the folder's owner"
fi
# Without the variable both profiles are what the current base writes. The
# expected text comes from the base's own copy of the policy module.
base_rev="$(git -C "$ROOT" merge-base HEAD origin/main 2>/dev/null || git -C "$ROOT" merge-base HEAD main 2>/dev/null)"
if [ -n "$base_rev" ] && git -C "$ROOT" cat-file -e "$base_rev:bin/lib/fm_sandbox_policy.py" 2>/dev/null; then
  mkdir -p "$t/base-engine"
  cp -R "$ROOT/bin" "$t/base-engine/"
  git -C "$ROOT" show "$base_rev:bin/lib/fm_sandbox_policy.py" > "$t/base-engine/bin/lib/fm_sandbox_policy.py"
  for os in darwin linux; do
    env -u FM_LOCAL_TESTS_DIR FM_SANDBOX_OS="$os" FM_RUN_DIR="$run" FM_PINNED_DIR="$run/pinned" \
      "$t/base-engine/bin/fm-sandbox.sh" profile --policy="$t/policy.json" --root="$t/root" --tmp="$t/tmp" \
      --listening= > "$t/base.$os" 2>/dev/null
    assert_ok "cmp -s '$t/base.$os' '$t/unset.$os'" "$os: no folder: the profile is as on base"
  done
else
  echo "    (skipped: the base commit is not in this checkout's history)"
fi

# --- worker rounds --------------------------------------------------------------
# The test adapter does what a worker does: makes its change, reads the
# runner command from its prompt, and runs it from the worktree.
lt_adapter() {   # lt_adapter <repo>
  cat > "$1/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
out="$FM_LTX_OUT"; tree="$3"
cp "$2" "$out/prompt.md"
printf '%s\n' "${FM_LOCAL_TESTS_DIR-unset}" > "$out/env"
runner="$(sed -n 's/^    python3 \(.*\/runner\.py\) run$/\1/p' "$2" | head -1)"
if [ -n "$runner" ]; then
  folder="${runner%/runner.py}"
  python3 -c 'import os, sys; d = sys.argv[1]; print(" ".join("%s:%o" % (n, os.stat(os.path.join(d, n)).st_mode & 0o7777) for n in sorted(os.listdir(d)) + ["."]))' "$folder" > "$out/modes"
  cp "$runner" "$out/runner.py"; cp "$folder/plan.json" "$out/plan.json"
fi
[ -z "${FM_LTX_CHANGE:-}" ] || (cd "$tree" && eval "$FM_LTX_CHANGE")
if [ -n "$runner" ] && [ "${FM_LTX_RUN:-1}" = 1 ]; then
  # shellcheck disable=SC2086
  (cd "$tree" && python3 "$runner" run ${FM_LTX_ARGS:-} > "$out/run.out" 2>&1; echo "$?" > "$out/run.rc")
fi
[ -z "${FM_LTX_AFTER:-}" ] || (cd "$tree" && eval "$FM_LTX_AFTER")
exit 0
M
  chmod +x "$1/bin/adapters/mock.sh"
}
# A gh that records what it was asked, keeps every comment body, and refuses
# comments when told to.
lt_gh() {   # lt_gh <dir> -> the stub
  mkdir -p "$1/stub"
  cat > "$1/stub/gh" <<G
#!/usr/bin/env bash
echo "gh \$*" >> "$1/ghcalls"
prev=''
for a in "\$@"; do
  if [ "\$prev" = --body-file ]; then cat "\$a" >> "$1/bodies"; fi
  prev="\$a"
done
case " \$* " in
  *" pr list "*) echo null; exit 0 ;;
  *" pr comment "*) [ ! -e "$1/refuse-comments" ] || { echo "comment refused" >&2; exit 1; } ;;
esac
echo "https://example.invalid/pull/42"
G
  chmod +x "$1/stub/gh"; printf '%s' "$1/stub/gh"
}
lt_config() {   # lt_config <test template> [extra project lines]
  printf 'vendor: mock\nfallback:\n  - mock\nproject:\n  check: true\n  test: %s\n  tests:\n    - tests/**\n  docs:\n    - design/**\n%s' "$1" "${2-}"
}
lt_fixture() {   # lt_fixture -> a fixture with the pinned contract committed, sets d r GH
  d="$(fixture)"; r="$d/repo"; GH="$(lt_gh "$d")"
  mkdir -p "$d/out"
  lt_config "$TEMPLATE_PIN" > "$r/config.yaml"
  git -C "$r" add config.yaml; git -C "$r" commit -qm contract; git -C "$r" push -q origin main
  seed_spec_preflight "$r" T-Z; seed_self_pr_authoring "$r" T-Z
  # the working copy differs, so the plan shows which one it came from
  lt_config "$TEMPLATE_CONFIG" > "$r/config.yaml"
  lt_adapter "$r"
}
CHANGE_SUITE='mkdir -p src tests; printf "print(2)\n" > src/impl.py
printf "#!/usr/bin/env bash\nprintf \"    %%-52s%%s\\\\n\" \"the change works\" ok\n" > tests/w.test.sh'
lt_round() {   # lt_round [worker args...]; FM_LTX_* from the caller; sets rc
  (cd "$r" && FM_LTX_OUT="$d/out" FM_ROOT="$r" FM_GH="$GH" bin/fm-worker.sh --task T-Z "$@") > "$d/worker.out" 2>&1
  rc=$?
}
events_of() { jq -c "select(.data.evidence_event == \"local_tests\")" "$r/state/events.jsonl" 2>/dev/null; }
run_log() { cat "$r"/state/runs/worker-*/worker.log 2>/dev/null; }

# the main round: a change, a changed suite, the runner the prompt names
lt_fixture
FM_LTX_CHANGE="$CHANGE_SUITE" FM_LTX_ARGS='--case the-change-works' lt_round
assert_eq 0 "$rc" "a round that runs its local tests completes"
prompt="$(cat "$d/out/prompt.md")"
folder="$(cat "$d/out/env")"
assert_contains "$prompt" "# Local tests" "the prompt has a Local tests section"
assert_contains "$prompt" "    python3 $folder/runner.py run" "and names the runner in this run's folder"
assert_contains "$prompt" 'Name with `--case <name>` the test cases you added or changed' "and asks for --case names"
assert_contains "$prompt" "Never run \`bin/ci.sh\`, the project check or a whole test folder" "and never the whole check"
assert_matches "$folder" '^/.*/state/runs/worker-[a-z]+-tz-r1/local-tests$' "the adapter gets this run's folder"
assert_eq "plan.json:444 runner.py:444 .:755" "$(cat "$d/out/modes" 2>/dev/null)" "the folder holds exactly the two files, 0444"
assert_ok "test -s '$d/out/runner.py' && cmp -s '$d/out/runner.py' '$ROOT/bin/lib/fm_local_tests.py'" \
  "the runner is a byte copy of fm_local_tests.py"
plan="$(cat "$d/out/plan.json" 2>/dev/null)"
assert_eq "$TEMPLATE_PIN" "$(jq -r .test <<<"$plan" 2>/dev/null)" "the plan's contract comes from the pin"
assert_eq "false" "$(jq 'has("check")' <<<"$plan" 2>/dev/null)" "the plan has no check key"
assert_eq '1|["tests/**"]|["design/**"]|null|{}|900|[]|300' \
  "$(jq -rc '[.schema, (.tests|tojson), (.docs|tojson), .unrunnable, (.check_env|tojson), .budget_seconds, (.network|tojson), .suite_seconds] | map(tostring) | join("|")' <<<"$plan" 2>/dev/null)" \
  "the plan holds the contract, budget and limits"
assert_matches "$(jq -r .jobs <<<"$plan" 2>/dev/null)" '^[123]$' "the plan runs at most 3 jobs"
assert_eq "$(git -C "$r" rev-parse main)" "$(jq -r .base <<<"$plan" 2>/dev/null)" "the plan's base is the merge-base"
assert_eq 0 "$(cat "$d/out/run.rc" 2>/dev/null)" "the runner passed inside the round"
assert_contains "$(cat "$d/out/run.out" 2>/dev/null)" "| tests/w.test.sh | passed | " "and its table names the changed suite"
assert_contains "$(cat "$d/out/run.out" 2>/dev/null)" "case filter not supported: the-change-works" "with the --case name"
ev="$(events_of)"
assert_eq 1 "$(grep -c . <<<"$ev")" "one local_tests event"
assert_eq '{"passed":1,"failed":0,"timed_out":0,"not_runnable":0,"not_run":0,"budget_seconds":900,"changed_files":2}' \
  "$(jq -c '.data.local_tests | del(.used_seconds)' <<<"$ev" 2>/dev/null)" "carrying only the counts"
en="$(jq -r '.summary.en' <<<"$ev" 2>/dev/null)"; tw="$(jq -r '.summary["zh-TW"]' <<<"$ev" 2>/dev/null)"
assert_eq "Local tests: 1 passed, 0 failed, 0 timed out, 0 not runnable here, 0 not run" "$en" "the English summary"
assert_eq "本機測試：通過 1、未通過 0、執行過久 0、無法在此執行 0、未執行 0" "$tw" "the zh-TW summary"
assert_eq "本机测试：通过 1、未通过 0、执行过久 0、无法在此执行 0、未执行 0" "$(python3 -B "$H" zh-cn "$ROOT" "$tw")" \
  "the zh-TW summary converts to zh-CN"
assert_eq "本机测试：结果无法读取" "$(python3 -B "$H" zh-cn "$ROOT" '本機測試：結果無法讀取')" \
  "the unreadable summary converts to zh-CN too"
assert_contains "$(cat "$d/ghcalls")" "pr create" "results only: published as an empty note"
assert_lacks "$(cat "$d/ghcalls" 2>/dev/null)" "pr comment" "and no comment"
assert_lacks "$(jq -r .type "$r/state/events.jsonl" | tr '\n' ' ')" "worker_note_unsent" "and nothing unsent"
assert_ok "grep -rqF '<!-- fm-local-tests v1 -->' '$r/state/evidence'" "the whole note is kept as the round's report"
# Regression (it held on base): a report that asks and holds a block reaches
# a reviewer as the marker line alone.
printf 'ASK-PASS-CRITERIA:T-Z\n\n<!-- fm-local-tests v1 -->\n| tests/private-sentinel.test.sh | failed | 1 | |\n<!-- /fm-local-tests -->\n' > "$d/ask.md"
(cd "$r" && FM_ROOT="$r" bash bin/lib/fm-evidence.sh --task T-Z report --round 2 --actor worker-x \
  --head "$(git -C "$r" rev-parse main)" --file "$d/ask.md") >/dev/null 2>&1
history="$(cd "$r" && FM_ROOT="$r" bash bin/lib/fm-evidence.sh --task T-Z history 2>/dev/null)"
assert_contains "$history" "ASK-PASS-CRITERIA:T-Z" "regression: a reviewer sees the ASK marker"
assert_lacks "$history" "private-sentinel" "regression: and no suite name from the block"
runner="$d/out/runner.py"
keep_runner="$t/runner.py"; cp "$runner" "$keep_runner" 2>/dev/null
safe_rm_rf "$d"

# The scenarios below each run their own fixture round. They run side by
# side, at most four at once, and report in order; each is waited for.
bg_pids=(); bg_outs=(); bg_done=0
collect_one() {
  wait "${bg_pids[$bg_done]}" || _fails=$((_fails + 1))
  cat "${bg_outs[$bg_done]}"
  bg_done=$((bg_done + 1))
}
spawn() {   # spawn <scenario> [args...]
  [ $((${#bg_pids[@]} - bg_done)) -lt 4 ] || collect_one
  local out="$t/scenario.${#bg_pids[@]}"
  ( _fails=0; "$@"; [ "$_fails" -eq 0 ] ) > "$out" 2>&1 &
  bg_pids+=("$!"); bg_outs+=("$out")
}

# the runner's own behaviour, on the copy the round's prompt named
runner_scenario() {
  python3 -B "$H" runner "$ROOT" "$keep_runner"
  assert_eq 0 "$?" "the runner behaves as T-275 says"
}

# no pin: the contract comes from fm_project
no_pin_scenario() {
  lt_fixture
  printf 'vendor: mock\nfallback:\n  - mock\n' > "$r/config.yaml"
  git -C "$r" add config.yaml; git -C "$r" commit -qm 'no contract'; git -C "$r" push -q origin main
  seed_spec_preflight "$r" T-Z; seed_self_pr_authoring "$r" T-Z
  lt_config "$TEMPLATE_CONFIG" '  check_env:
    LTX_CHECK: on
' > "$r/config.yaml"
  FM_LTX_CHANGE="$CHANGE_SUITE" lt_round
  assert_ok "test ! -e '$r/state/pins/T-Z/1.json'" "a round whose pin could not be made has none"
  assert_eq "$TEMPLATE_CONFIG|on" "$(jq -r '.test + "|" + .check_env.LTX_CHECK' "$d/out/plan.json" 2>/dev/null)" \
    "no pin: the plan's contract is fm_project's"
  safe_rm_rf "$d"
}

# results only: with no pull request, with one, and with comments refused
results_only_scenario() {   # results_only_scenario <none|pr number> <refuse 0|1>
  lt_fixture
  [ "$2" = 0 ] || : > "$d/refuse-comments"
  args=(); [ "$1" = none ] || args=(--pr "$1")
  # the block goes straight into the note, so base, which reads any
  # non-empty note as the worker speaking, comments and goes red
  block "$good" > "$d/say-in"
  FM_LTX_CHANGE="$CHANGE_SUITE" FM_LTX_RUN=0 FM_LTX_AFTER="cp '$d/say-in' .fm-say.md" \
    lt_round ${args[@]+"${args[@]}"}
  label="no PR"; [ "$1" = none ] || label="a PR"; [ "$2" = 0 ] || label="comments refused"
  assert_eq 0 "$rc" "results only, $label: exits as if empty"
  assert_lacks "$(cat "$d/ghcalls" 2>/dev/null)" "pr comment" "results only, $label: no comment"
  assert_lacks "$(jq -r .type "$r/state/events.jsonl" | tr '\n' ' ')" "worker_note_unsent" "results only, $label: nothing unsent"
  assert_eq 1 "$(grep -c . <<<"$(events_of)")" "results only, $label: counts reported"
  safe_rm_rf "$d"
}

# no block: nothing on the board, one line in the round's log
no_block_scenario() {
  lt_fixture
  FM_LTX_CHANGE="$CHANGE_SUITE" FM_LTX_RUN=0 lt_round
  assert_eq 0 "$rc" "a round with no results publishes as before"
  assert_contains "$(cat "$d/ghcalls")" "pr create" "and opens its pull request"
  assert_eq "" "$(events_of)" "no block: no local_tests event"
  assert_contains "$(run_log)" "fm-worker: the round reported no local test results" "no block: one line in the round's log"
  safe_rm_rf "$d"
}

# a block that does not read: one valid:false event and nothing from it
good='{"passed":1,"failed":0,"timed_out":0,"not_runnable":0,"not_run":0,"budget_seconds":900,"used_seconds":3,"changed_files":2}'
block() {   # block <summary json> [start marker]
  printf '%s\n<!-- fm-local-tests-summary %s -->\n## Local tests\n| tests/private-sentinel.test.sh | passed | 1 | |\n<!-- /fm-local-tests -->\n' \
    "${2:-<!-- fm-local-tests v1 -->}" "$1"
}
invalid_block_scenario() {   # invalid_block_scenario <kind>
  local kind="$1"
  lt_fixture
  case "$kind" in
    extra-key) block "$(jq -c '. + {path:"/private/sentinel-path"}' <<<"$good")" ;;
    string) block "$(jq -c '.passed = "1"' <<<"$good")" ;;
    negative) block "$(jq -c '.failed = -1' <<<"$good")" ;;
    second-block) block "$good"; block "$good" ;;
    no-end) block "$good" | sed '$d' ;;
    v2) block "$good" '<!-- fm-local-tests v2 -->' ;;
  esac > "$d/say-in"
  FM_LTX_CHANGE="$CHANGE_SUITE" FM_LTX_RUN=0 FM_LTX_AFTER="cp '$d/say-in' .fm-say.md" lt_round
  ev="$(events_of)"
  assert_eq 1 "$(grep -c . <<<"$ev")" "$kind: exactly one local_tests event"
  assert_eq '{"valid":false}' "$(jq -c '.data.local_tests' <<<"$ev" 2>/dev/null)" "$kind: and it says the block does not read"
  assert_eq "Local tests: the results block does not read|本機測試：結果無法讀取" \
    "$(jq -r '.summary.en + "|" + .summary["zh-TW"]' <<<"$ev" 2>/dev/null)" "$kind: in both languages"
  assert_lacks "$(cat "$r/state/events.jsonl")" "sentinel" "$kind: nothing of the report in an event"
  safe_rm_rf "$d"
}

# a truncated block beside worker words: the note speaks as before
truncated_scenario() {   # truncated_scenario <none|pr number>
  lt_fixture
  { printf 'The worker says this.\n\n'; block "$good" | sed '$d'; } > "$d/say-in"
  args=(); [ "$1" = none ] || args=(--pr "$1")
  FM_LTX_CHANGE="$CHANGE_SUITE" FM_LTX_RUN=0 FM_LTX_AFTER="cp '$d/say-in' .fm-say.md" lt_round ${args[@]+"${args[@]}"}
  label="no PR"; [ "$1" = none ] || label="a PR"
  assert_eq 0 "$rc" "truncated, $label: completes as today"
  assert_contains "$(cat "$d/ghcalls")" "pr comment" "truncated, $label: the note is delivered"
  assert_contains "$(cat "$d/bodies" 2>/dev/null)" "The worker says this." "truncated, $label: with the worker's words"
  assert_contains "$(cat "$d/bodies" 2>/dev/null)" "private-sentinel" "truncated, $label: whole, as today"
  assert_eq '{"valid":false}' "$(events_of | jq -c '.data.local_tests' 2>/dev/null)" "truncated, $label: one valid:false event"
  safe_rm_rf "$d"
}

# a note that cannot be read: today's paths, plus the valid:false event
unreadable_scenario() {   # unreadable_scenario <none|pr number>
  lt_fixture
  args=(); [ "$1" = none ] || args=(--pr "$1")
  FM_LTX_CHANGE="$CHANGE_SUITE" FM_LTX_RUN=0 \
    FM_LTX_AFTER="printf 'unreadable words\n' > .fm-say.md; chmod 000 .fm-say.md" lt_round ${args[@]+"${args[@]}"}
  label="no PR"; [ "$1" = none ] || label="a PR"
  expected=70; [ "$1" = none ] || expected=73
  assert_eq "$expected" "$rc" "unreadable, $label: exits $expected as today"
  assert_contains "$(cat "$d/worker.out")" "local report retention failed" "unreadable, $label: retention fails as today"
  assert_lacks "$(cat "$d/ghcalls" 2>/dev/null)" "pr comment" "unreadable, $label: no comment"
  assert_eq '{"valid":false}' "$(events_of | jq -c '.data.local_tests' 2>/dev/null)" "unreadable, $label: one valid:false event"
  chmod 600 "$r"/state/worktrees/T-Z/.fm-say.md 2>/dev/null
  safe_rm_rf "$d"
}

# external projects, through the launcher's own note blocks
external_scenario() {
  python3 -B "$H" blocks "$ROOT"
  assert_eq 0 "$?" "external notes keep the block private"
}

# a folder that cannot be built: the round runs as before
lt_wrap() {   # lt_wrap <tool> <case pattern of the argument to refuse>
  local real; real="$(PATH="$suite_original_path" command -v "$1")"
  mkdir -p "$d/wrap"
  printf '#!/usr/bin/env bash\nfor a in "$@"; do case "$a" in %s) echo "%s: refused by the test" >&2; exit 1 ;; esac; done\nexec %s "$@"\n' \
    "$2" "$1" "$real" > "$d/wrap/$1"
  chmod +x "$d/wrap/$1"
}
fault_scenario() {   # fault_scenario <folder|copy|plan>
  local fault="$1" why
  lt_fixture
  case "$fault" in
    folder) lt_wrap mkdir '*/local-tests'; why='the folder' ;;
    copy) lt_wrap cp '*/local-tests/runner.py'; why='the runner could not be copied' ;;
    plan) lt_wrap jq '*fm-local-tests-plan*'; why='the plan could not be written' ;;
  esac
  (cd "$r" && PATH="$d/wrap:$PATH" FM_LOCAL_TESTS_DIR="$t/state/runs/worker-lt-t1-r1/local-tests" \
    FM_LTX_OUT="$d/out" FM_LTX_CHANGE="$CHANGE_SUITE" FM_ROOT="$r" FM_GH="$GH" bin/fm-worker.sh --task T-Z) > "$d/worker.out" 2>&1
  assert_eq 0 "$?" "$fault fault: the round still completes"
  assert_contains "$(cat "$d/out/prompt.md" 2>/dev/null)" "Local tests are unavailable in this round: $why" "$fault fault: the prompt says why"
  assert_contains "$(run_log)" "local tests are unavailable in this round: $why" "$fault fault: so does the round's log"
  assert_eq "unset" "$(cat "$d/out/env" 2>/dev/null)" "$fault fault: no FM_LOCAL_TESTS_DIR, not inherited"
  assert_eq "" "$(ls -d "$r"/state/runs/worker-*/local-tests 2>/dev/null)" "$fault fault: no folder is left"
  assert_contains "$(cat "$d/ghcalls")" "pr create" "$fault fault: publication is unchanged"
  safe_rm_rf "$d"
}

spawn runner_scenario
spawn no_pin_scenario
spawn results_only_scenario none 0
spawn results_only_scenario 9 0
spawn results_only_scenario 9 1
spawn no_block_scenario
for kind in extra-key string negative second-block no-end v2; do spawn invalid_block_scenario "$kind"; done
spawn truncated_scenario none
spawn truncated_scenario 9
if [ "$(id -u)" != 0 ]; then
  spawn unreadable_scenario none
  spawn unreadable_scenario 9
else
  echo "    (skipped: root reads a mode 000 file)"
fi
spawn external_scenario
for fault in folder copy plan; do spawn fault_scenario "$fault"; done
while [ "$bg_done" -lt "${#bg_pids[@]}" ]; do collect_one; done

safe_rm_rf "$t"
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
