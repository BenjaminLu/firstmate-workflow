#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# --- T-036: mid-run checkpoint (commit then push; never main / never PR) ---
assert_ok "test -x '$ROOT/bin/fm-checkpoint.sh'" "fm-checkpoint.sh is the stock mid-run save helper"

dc="$(safe_tmpdir)"; barec="$dc/remote.git"; rc="$dc/repo"
cd "$ROOT" || exit 1
git init -q --bare "$barec"
git init -q -b main "$rc"
git -C "$rc" config user.email a@b.c; git -C "$rc" config user.name t
mkdir -p "$rc/bin" "$rc/design" "$rc/state/worktrees"
# shellcheck source=tests/lib/config-modules.sh
. "$ROOT/tests/lib/config-modules.sh"
cp "$ROOT/bin/fm-checkpoint.sh" "$ROOT/bin/fm-guard.sh" "$ROOT/bin/fm-config.sh" \
   "$ROOT/bin/fm-emit.sh" "$rc/bin/"; config_modules_fixture "$rc/bin/"
printf 'base\n' > "$rc/README"; git -C "$rc" add README; git -C "$rc" commit -qm base
git -C "$rc" remote add origin "$barec"; git -C "$rc" push -q -u origin main
git -C "$rc" branch -q t-ck-branch
git -C "$rc" worktree add -q "$rc/state/worktrees/T-CK" t-ck-branch
printf 'unit\n' > "$rc/state/worktrees/T-CK/work.txt"
assert_ok "FM_ROOT='$rc' '$rc/bin/fm-checkpoint.sh' --task T-CK --repo '$rc' --message 'checkpoint unit'" \
  "checkpoint commits dirty work on a feature branch"
assert_ok "cd '$ROOT' && git --git-dir='$barec' rev-parse --verify t-ck-branch" \
  "checkpoint pushes the feature branch immediately"
assert_contains "$(git -C "$rc/state/worktrees/T-CK" log -1 --pretty=%s)" "T-CK: checkpoint unit" \
  "checkpoint commit uses the supplied message"
# --repo may be the worktree itself (not the session root).
printf 'via-repo\n' > "$rc/state/worktrees/T-CK/via.txt"
assert_ok "FM_ROOT='$rc' '$rc/bin/fm-checkpoint.sh' --task T-CK --repo '$rc/state/worktrees/T-CK' --message 'via worktree as repo'" \
  "checkpoint accepts the worktree path as --repo"
assert_ok "cd '$ROOT' && git --git-dir='$barec' cat-file -e t-ck-branch:via.txt" \
  "worktree-as-repo checkpoint pushed the file"
# --dir form (cwd-agnostic).
printf 'via-dir\n' > "$rc/state/worktrees/T-CK/via-dir.txt"
assert_ok "'$rc/bin/fm-checkpoint.sh' --dir '$rc/state/worktrees/T-CK' --message 'via --dir'" \
  "checkpoint --dir commits and pushes"
assert_ok "cd '$ROOT' && git --git-dir='$barec' cat-file -e t-ck-branch:via-dir.txt" \
  "--dir checkpoint reached the remote"
# The identity comes from the repo being committed to, not from the caller's
# cwd: this fixture's a@b.c is local to $rc, so a cwd lookup would sign with
# whatever the caller has (the operator's own address, or nothing on CI).
assert_eq "a@b.c" "$(git -C "$rc/state/worktrees/T-CK" log -1 --pretty=%ae)" \
  "--dir checkpoint signs with the repo's own identity"
# Refuse protected / non-feature tips. main is already the primary checkout,
# so attach a detached worktree at main's tip (refuses as HEAD).
git -C "$rc" worktree remove -f "$rc/state/worktrees/T-CK"
git -C "$rc" worktree add -q --detach "$rc/state/worktrees/T-CK" main
printf 'nope\n' > "$rc/state/worktrees/T-CK/bad.txt"
assert_fail "FM_ROOT='$rc' '$rc/bin/fm-checkpoint.sh' --task T-CK --repo '$rc' --message 'should refuse main'" \
  "checkpoint refuses to write on main"
assert_fail "grep -qx bad.txt <<<\"\$(git --git-dir='$barec' ls-tree -r main --name-only)\"" \
  "refused main checkpoint pushes nothing"
# Unset clears the shared repo local config (worktrees share it). On a CI
# runner with no global fallback that poisons every later commit in this
# fixture unless restored immediately after the negative case.
git -C "$rc/state/worktrees/T-CK" config --unset user.name 2>/dev/null || true
git -C "$rc/state/worktrees/T-CK" config --unset user.email 2>/dev/null || true
unset FM_GIT_NAME FM_GIT_EMAIL
printf 'orphan\n' > "$rc/state/worktrees/T-CK/orphan.txt"
assert_fail "FM_ROOT='$rc' FM_GIT_NAME= FM_GIT_EMAIL= '$rc/bin/fm-checkpoint.sh' --dir '$rc/state/worktrees/T-CK' --message 'no identity'" \
  "checkpoint refuses commit when git identity is missing"
git -C "$rc" config user.email a@b.c
git -C "$rc" config user.name t
# Re-attach a feature worktree: the prior block left T-CK detached on main.
git -C "$rc" worktree remove -f "$rc/state/worktrees/T-CK" 2>/dev/null || true
git -C "$rc" worktree add -q "$rc/state/worktrees/T-CK" t-ck-branch
# A tip that already tracks .fm-say.md must be purgeable: reset must not
# resurrect the file when the working tree deleted it.
printf 'round notes\n' > "$rc/state/worktrees/T-CK/.fm-say.md"
git -C "$rc/state/worktrees/T-CK" add -f .fm-say.md
git -C "$rc/state/worktrees/T-CK" commit -qm 'fixture: tracked say'
git -C "$rc/state/worktrees/T-CK" push -q origin t-ck-branch
rm -f "$rc/state/worktrees/T-CK/.fm-say.md"
printf 'after-purge\n' > "$rc/state/worktrees/T-CK/after.txt"
assert_ok "'$rc/bin/fm-checkpoint.sh' --dir '$rc/state/worktrees/T-CK' --message 'drop tracked say'" \
  "checkpoint commits when a tracked .fm-say.md was deleted"
assert_fail "cd '$ROOT' && git --git-dir='$barec' cat-file -e t-ck-branch:.fm-say.md" \
  "checkpoint removes a mistakenly tracked .fm-say.md from the tip"
assert_ok "cd '$ROOT' && git --git-dir='$barec' cat-file -e t-ck-branch:after.txt" \
  "purge commit still pushes the accompanying work"
# Present on-disk notes still never reach the tip.
printf 'live notes\n' > "$rc/state/worktrees/T-CK/.fm-say.md"
printf 'keep\n' > "$rc/state/worktrees/T-CK/keep.txt"
assert_ok "'$rc/bin/fm-checkpoint.sh' --dir '$rc/state/worktrees/T-CK' --message 'keep notes local'" \
  "checkpoint with a live .fm-say.md still saves other work"
assert_fail "cd '$ROOT' && git --git-dir='$barec' cat-file -e t-ck-branch:.fm-say.md" \
  "live .fm-say.md contents are never re-committed"
assert_ok "cd '$ROOT' && git --git-dir='$barec' cat-file -e t-ck-branch:keep.txt" \
  "non-ephemeral files still checkpoint beside a live .fm-say.md"
rm -rf "$dc"

# --- T-270: commit subjects a person can read --------------------------------
# A mid-run checkpoint keeps the worker's own message; an already prefixed
# message is not prefixed twice.
dp="$(safe_tmpdir)"; barep="$dp/remote.git"; rp="$dp/repo"
git init -q --bare "$barep"; git init -q -b main "$rp"
git -C "$rp" config user.email a@b.c; git -C "$rp" config user.name t
mkdir -p "$rp/bin" "$rp/state/worktrees"
cp "$ROOT/bin/fm-checkpoint.sh" "$ROOT/bin/fm-guard.sh" "$ROOT/bin/fm-config.sh" \
   "$ROOT/bin/fm-emit.sh" "$rp/bin/"; config_modules_fixture "$rp/bin/"
printf 'base\n' > "$rp/README"; git -C "$rp" add README; git -C "$rp" commit -qm base
git -C "$rp" remote add origin "$barep"; git -C "$rp" push -q -u origin main
git -C "$rp" branch -q t-cs-branch
git -C "$rp" worktree add -q "$rp/state/worktrees/T-CS" t-cs-branch
wt="$rp/state/worktrees/T-CS"
printf 'one\n' > "$wt/one.txt"
assert_ok "'$rp/bin/fm-checkpoint.sh' --dir '$wt' --message 'Save the parser before the refactor'" 'mid-run checkpoint commits'
assert_eq 'T-CS: Save the parser before the refactor' "$(git -C "$wt" log -1 --pretty=%s)" 'a mid-run checkpoint keeps the worker message'
printf 'two\n' > "$wt/two.txt"
assert_ok "'$rp/bin/fm-checkpoint.sh' --dir '$wt' --message 'T-CS: Keep the prefixed message'" 'prefixed checkpoint commits'
assert_eq 'T-CS: Keep the prefixed message' "$(git -C "$wt" log -1 --pretty=%s)" 'a prefixed message is not prefixed twice'
# The stop and recovery checkpoint that fm-worker.sh requests says what
# happened in plain words, and keeps the task prefix parsers read.
publish="$(awk '/^publish_wip_if_dirty\(\) \{/{on=1} on{print} on&&/^}/{exit}' "$ROOT/bin/fm-worker.sh")"
assert_contains "$publish" 'publish_wip_if_dirty' 'the stop checkpoint function is found'
printf 'three\n' > "$wt/three.txt"
(cd "$rp" && FM_CODE_ROOT="$rp" REPO="$rp" tree="$wt" branch=t-cs-branch TASK=T-CS _fm_wip_done=0 bash -c \
  'fm_publication_policy() { return 0; }; eval "$1"; publish_wip_if_dirty exit-1' _ "$publish") >/dev/null 2>&1
assert_eq 'T-CS: Save unfinished work after the round stopped (exit-1)' "$(git -C "$wt" log -1 --pretty=%s)" \
  'the stop checkpoint subject says the round stopped and why'
# The round commit and the rebuild commit-tree share one subject; its
# generic fallback reads as a sentence.
assert_contains "$(grep -n 'commit_msg=' "$ROOT/bin/fm-worker.sh")" "commit_msg=\"\$TASK: Save the round's changes\"" \
  'the generic fallback subject is a plain sentence'
assert_contains "$(grep -n 'commit-tree' "$ROOT/bin/fm-worker.sh")" '-m "$commit_msg"' \
  'the rebuild commit-tree uses the same subject'

# --- T-270: commit messages get the advisory plain-writing lint -------------
# A message with a glued number and a slash chain is still committed, and the
# findings reach firstmate's log (state/runtime/plain-writing.jsonl), for the
# checkpoint commit, the ordinary round commit and the rebuilt round commit.
mkdir -p "$rp/i18n"
cp "$ROOT/bin/lib/fm_plain.py" "$rp/bin/lib/"; cp "$ROOT/i18n/glossary.json" "$ROOT/i18n/tw2cn.tsv" "$rp/i18n/"
lint_log="$dp/state/runtime/plain-writing.jsonl"
lint_found() {  # lint_found <source>: the log's findings for that source, one "check match" per line
  python3 - "$lint_log" "$1" <<'PY'
import json, sys
from pathlib import Path
log = Path(sys.argv[1])
for line in (log.read_text().splitlines() if log.exists() else []):
    row = json.loads(line)
    if row['source'] == sys.argv[2]:
        for f in row['findings']: print(f['check'], f['match'])
PY
}
bad='Fix All13 in kind/purpose/chosen'
printf 'four\n' > "$wt/four.txt"
assert_ok "FM_STATE_DIR='$dp/state' '$rp/bin/fm-checkpoint.sh' --dir '$wt' --message '$bad'" \
  'a checkpoint with plain-writing findings still commits'
assert_eq "T-CS: $bad" "$(git -C "$wt" log -1 --pretty=%s)" 'the checkpoint message is committed unchanged'
assert_contains "$(lint_found checkpoint-commit)" 'glued-number All13' 'the checkpoint message finding reaches the log'
assert_contains "$(lint_found checkpoint-commit)" 'slash-chain kind/purpose/chosen' 'the checkpoint slash chain reaches the log'
lint_fn="$(awk '/^plain_lint\(\) \{/{on=1} on{print} on&&/^}/{exit}' "$ROOT/bin/fm-worker.sh")"
commit_block="$(awk '/^rebuilt_head=.*commit_ok=0$/{on=1} /^if \[ "\$commit_ok" != 1 \]; then/{exit} on{print}' "$ROOT/bin/fm-worker.sh")"
assert_contains "$commit_block" 'fm_git_commit "$tree" "$commit_msg"' 'the round commit block is found'
run_commit() {  # run_commit <rebuilt 0|1>: the fm-worker.sh round commit block, as written
  (cd "$rp" && FM_CODE_ROOT="$rp" REPO="$rp" FM_STATE_DIR="$dp/state" tree="$wt" branch=t-cs-branch \
     rebuilt="$1" commit_msg="T-CS: $bad" rb_name=t rb_email=a@b.c rebuild_base="$(git -C "$wt" rev-parse HEAD)" \
     bash -c '. "$1/bin/fm-config.sh"; first_round_question() { return 1; }; eval "$2"; eval "$3"; echo "commit_ok=$commit_ok"' \
     _ "$rp" "$lint_fn" "$commit_block" 2>/dev/null)
}
printf 'five\n' > "$wt/five.txt"; git -C "$wt" add -A
before="$(git -C "$wt" rev-parse HEAD)"
assert_contains "$(run_commit 0)" 'commit_ok=1' 'the ordinary round commit happens despite the findings'
assert_eq "$before" "$(git -C "$wt" rev-parse HEAD~1)" 'the ordinary round commit is on the branch'
assert_contains "$(lint_found round-commit)" 'glued-number All13' 'the ordinary round commit finding reaches the log'
printf 'six\n' > "$wt/six.txt"; git -C "$wt" add -A
before="$(git -C "$wt" rev-parse HEAD)"
assert_contains "$(run_commit 1)" 'commit_ok=1' 'the rebuilt round commit happens despite the findings'
assert_eq "$before" "$(git -C "$wt" rev-parse HEAD~1)" 'the rebuilt commit sits on the rebuild base'
assert_eq "T-CS: $bad" "$(git -C "$wt" log -1 --pretty=%s)" 'the rebuilt commit keeps the message unchanged'
assert_contains "$(lint_found rebuilt-commit)" 'slash-chain kind/purpose/chosen' 'the rebuilt commit finding reaches the log'

# --- T-270: the rebuild comment states what the finished round did ----------
# It runs after the round, when the worker has resolved every conflict and the
# rebuilt commit is published; it never says the work is still to come.
rebuild_block="$(awk '/^# The reviewer reads the pull request, and after a rebuild/{on=1} /^# The held note now has a PR/{exit} on{print}' "$ROOT/bin/fm-worker.sh")"
assert_contains "$rebuild_block" 'fm_github pr comment' 'the rebuild comment block is found'
(cd "$rp" && FM_CODE_ROOT="$rp" REPO="$rp" FM_STATE_DIR="$dp/state" tree="$wt" branch=t-cs-branch BASE=main \
   rebuilt=1 FM_EXTERNAL=0 num=7 rebuild_base=abc1234 rebuild_prev=def5678 out="$dp/rebuild-comment" \
   bash -c 'rebuild_conflicts=(bin/a.sh); fm_github() { printf "%s" "$5" > "$out"; }; eval "$1"; eval "$2"' \
   _ "$lint_fn" "$rebuild_block" 2>/dev/null)
rebuild_comment="$(cat "$dp/rebuild-comment" 2>/dev/null)"
assert_contains "$rebuild_comment" 'The worker resolved any conflicts listed below in this round. The pull request is ready for CI.' \
  'the rebuild comment describes the finished round'
assert_lacks "$rebuild_comment" 'next round' 'the rebuild comment never says the work is still to come'
assert_contains "$rebuild_comment" 'Previous head: `def5678`' 'the rebuild comment keeps the previous head line'
assert_contains "$rebuild_comment" "New head: \`$(git -C "$wt" rev-parse HEAD)\`" 'the rebuild comment keeps the new head line'
assert_contains "$rebuild_comment" 'Conflicts handed to the worker: `bin/a.sh`' 'the rebuild comment lists the conflicts'
assert_contains "$(lint_found rebuild-comment)" 'unexplained-term round' 'the rebuild comment is linted before it is posted'
safe_rm_rf "$dp"


cd "$ROOT" || exit 1
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
