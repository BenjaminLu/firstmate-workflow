#!/usr/bin/env bash
# The worker runs an adapter and then does all the git itself. The adapter
# must never be near a repository operation.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

fixture() {                     # a repo with a remote, a task, and the real scripts
  local d; d="$(mktemp -d)"; local bare="$d/remote.git"
  git init -q --bare "$bare"
  git init -q -b main "$d/repo"
  cd "$d/repo" || return 1
  git config user.email a@b.c; git config user.name t
  mkdir -p bin design skills/worker state
  cp "$ROOT/bin/fm-config.sh" "$ROOT/bin/fm-emit.sh" "$ROOT/bin/fm-worker.sh" bin/
  cp -r "$ROOT/bin/adapters" bin/
  cp "$ROOT/skills/worker/SKILL.md" skills/worker/
  printf 'vendor: mock\nfallback:\n  - mock\n' > config.yaml
  cat > design/tasks.json <<'JSON'
{"tasks":[{"id":"T-Z","title":"a mock task","scope":["src/**"],"acceptance":["it exists"]}]}
JSON
  printf '# design\n## 6. gates\nseven of them\n## 8. board\n' > design/design.md
  git add -A; git commit -qm base; git remote add origin "$bare"; git push -q -u origin main
  printf '%s' "$d"
}

ghstub() {                      # records what it was asked, invents a pull request url
  mkdir -p "$1/stub"
  printf '#!/usr/bin/env bash\necho "gh $*" >> "%s/ghcalls"\necho "https://example.invalid/pull/42"\n' "$1" > "$1/stub/gh"
  chmod +x "$1/stub/gh"; printf '%s' "$1/stub/gh"
}

d="$(fixture)"; r="$d/repo"; GH="$(ghstub "$d")"
out="$(cd "$r" && FM_ROOT="$r" FM_GH="$GH" bin/fm-worker.sh --task T-Z --name worker-1 2>&1)"; rc=$?
assert_eq "0" "$rc" "a clean run exits 0"
branch="$(printf '%s' "$out" | tail -1)"
assert_contains "$branch" "t-z" "it names the branch after the task"
assert_ok "test -d '$r/state/worktrees/T-Z'" "it made a worktree of its own"
assert_ok "git -C '$r' rev-parse --verify '$branch'" "the branch exists"
assert_eq "1" "$(git -C "$r" rev-list --count "main..$branch")" "exactly one commit"
assert_ok "git -C '$r/state/worktrees/T-Z' show --stat HEAD | grep -q mock.txt" "the adapter's file is in it"
assert_ok "git --git-dir='$d/remote.git' rev-parse --verify '$branch'" "it pushed to the remote"
assert_contains "$(cat "$d/ghcalls")" "pr create" "it opened a pull request"

log="$r/state/events.jsonl"
assert_contains "$(jq -r .type < "$log" | tr '\n' ' ')" "commit_pushed" "it emitted commit_pushed"
assert_contains "$(jq -r .type < "$log" | tr '\n' ' ')" "pr_opened" "it emitted pr_opened"

# the prompt carries the task and the skill, and is not left lying around
assert_fail "test -f '$r/state/worktrees/T-Z/.fm-prompt.md'" "the prompt is cleaned up"

# an adapter that cannot reach its vendor falls through to the next one
d2="$(fixture)"; r2="$d2/repo"; GH2="$(ghstub "$d2")"
( cd "$r2" && FM_ROOT="$r2" FM_GH="$GH2" FM_MOCK_EXIT=2 bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
assert_eq "2" "$?" "every vendor unavailable exits 2"
assert_contains "$(jq -r .type < "$r2/state/events.jsonl" | tr '\n' ' ')" "vendor_unavailable" \
  "it emitted vendor_unavailable"
assert_eq "" "$(cat "$d2/ghcalls" 2>/dev/null)" "an unavailable vendor opens no pull request"

# an adapter that ran and failed still goes to the gates: commit, push, pull request
d3="$(fixture)"; r3="$d3/repo"; GH3="$(ghstub "$d3")"
( cd "$r3" && FM_ROOT="$r3" FM_GH="$GH3" FM_MOCK_EXIT=1 bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
assert_eq "1" "$?" "a failed attempt exits 1"
assert_contains "$(cat "$d3/ghcalls")" "pr create" "a failed attempt still opens a pull request"

# the adapter never touches the repository
# a comment may mention git; a call may not
assert_fail "grep -vE '^[[:space:]]*#' '$ROOT/bin/adapters/mock.sh' | grep -qE '\\b(git|gh)\\b'" \
  "the mock adapter calls no git and no gh"
rm -rf "$d" "$d2" "$d3"
finish
