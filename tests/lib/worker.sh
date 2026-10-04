# shellcheck shell=bash
# Caller/consumer globals are checked when linting the feature suites.
# shellcheck disable=SC2034
# The worker runs an adapter and then does all the git itself. The adapter
# must never be near a repository operation.
set -uo pipefail
# A live managed worker exports FM_RUN_DIR / FM_ENTRY_* / FM_WORKER_TASK_LOCK_FD
# and Herdr pane ids into this shell. Suites must not inherit them or freeze,
# identity, locks and pushes bind to the outer run instead of the fixture.
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
export HERDR_ENV=0 FM_TRANSPORT=direct
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/stack-base-fixture.sh
. "$ROOT/tests/lib/stack-base-fixture.sh"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
isolate_tmpdir
# shellcheck source=tests/lib/path.sh
. "$ROOT/tests/lib/path.sh"
# shellcheck source=tests/lib/spec-preflight.sh
. "$ROOT/tests/lib/spec-preflight.sh"
suite_original_path="$PATH"
suite_tools="$(safe_tmpdir)"
fixture_path "$suite_tools" 'claude codex gemini cursor-agent agent gh herdr tmux cmux security secret-tool osascript xdg-open open' || exit 1
PATH="$suite_tools"; export PATH

# A simulated fetch failure must reject malformed arguments too: its normal
# nonzero status alone cannot distinguish the fixture response from rejection.
check_strict_run_stub() (
  local stub="$1" id="$2" response rc
  # Earlier fixture assertions may leave the caller in a removed worktree.
  cd "$ROOT" || return 1
  response="$("$stub" run view "$id" --log-failed --job 999 2>&1)"; rc=$?
  assert_eq "1" "$rc" "run $id stub rejects extra job selector"
  assert_eq "could not find any workflow run" "$response" "run $id extra selector cannot return fixture output"
  response="$("$stub" run view --job "$id" --log-failed 2>&1)"; rc=$?
  assert_eq "1" "$rc" "run $id stub rejects job namespace"
  assert_eq "could not find any workflow run" "$response" "run $id job namespace cannot return fixture output"
  response="$("$stub" run view "$id" 2>&1)"; rc=$?
  assert_eq "1" "$rc" "run $id stub requires log-failed flag"
  assert_eq "could not find any workflow run" "$response" "run $id missing flag cannot return fixture output"
)

fixture() {                     # a repo with a remote, a task, and the real scripts
  local d; d="$(safe_tmpdir)"; local bare="$d/remote.git" task="${1:-T-Z}"
  git init -q --bare "$bare"
  git init -q -b main "$d/repo"
  # Never leave the suite cwd inside a disposable fixture: later asserts use
  # `git --git-dir=...` and fail with "Unable to read current working directory"
  # once the fixture is rm -rf'd.
  (
  cd "$d/repo" || exit 1
  git config user.email a@b.c; git config user.name t
  mkdir -p bin design/tasks "$d/repo/skills/worker" state
  cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-worker.sh" \
     "$ROOT/bin/fm-checkpoint.sh" "$ROOT/bin/fm-guard.sh" "$ROOT/bin/fm-herdr.py" \
     "$ROOT/bin/fm-auth-probe.sh" "$ROOT/bin/fm-sandbox.sh" bin/
  cp -r "$ROOT/bin/adapters" bin/
  cp -R "$ROOT/bin/lib" bin/   # the lifeline a round's runner holds (T-151)
  stack_base_fixture bin
  cp "$ROOT/skills/worker/SKILL.md" "$d/repo/skills/worker/"
  printf 'vendor: mock\nfallback:\n  - mock\n' > config.yaml
  jq -n --arg task "$task" '{id:$task,title:"a mock task",scope:["src/**"],acceptance:["it exists"]}' \
    > "design/tasks/$task.json"
  printf '# design\n## 6. gates\nseven of them\n## 8. board\n' > design/design.md
  git add -A; git commit -qm base; git remote add origin "$bare"; git push -q -u origin main
  ) || return 1
  seed_spec_preflight "$d/repo" "$task" || return 1
  printf '%s' "$d"
}

ghstub() {                      # records what it was asked, invents a pull request url
  # `pr list` has to answer the way gh does: through `--jq
  # '.[0].number'` a branch with no open pull request is the literal
  # `null`, not silence, and the worker normalises it. A stub that
  # answers with nothing leaves that normalisation untested - and a
  # stub that answers every question with a url tells the worker a
  # pull request already exists and it never opens one.
  mkdir -p "$1/stub"
  cat > "$1/stub/gh" <<G
#!/usr/bin/env bash
echo "gh \$*" >> "$1/ghcalls"
case " \$* " in
  *" pr list "*) echo null; exit 0 ;;
esac
echo "https://example.invalid/pull/42"
G
  chmod +x "$1/stub/gh"; printf '%s' "$1/stub/gh"
}


