#!/usr/bin/env bash
# Runs one task. Creates the worktree, hands the prompt to an adapter, and then
# does every git and gh operation itself - the adapter is never allowed near
# them, which is what lets a CLI with no repository access still be a worker.
#
#   fm-worker.sh --task T-004 [--repo .] [--vendor claude] [--name worker-1]
set -uo pipefail

REPO="${FM_ROOT:-$(pwd)}"; TASK=''; VENDOR=''; NAME=''
BASE="${FM_BASE:-main}"; GH="${FM_GH:-gh}"
while [ $# -gt 0 ]; do
  case "$1" in
    --task) TASK="${2-}"; shift 2 ;;
    --repo) REPO="${2-}"; shift 2 ;;
    --vendor) VENDOR="${2-}"; shift 2 ;;
    --name) NAME="${2-}"; shift 2 ;;
    *) echo "fm-worker: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -n "$TASK" ] || { echo "usage: fm-worker.sh --task <id> [--repo dir]" >&2; exit 64; }
cd "$REPO" || { echo "fm-worker: no repo at $REPO" >&2; exit 64; }
NAME="${NAME:-worker-$$}"
EMIT="$REPO/bin/fm-emit.sh"
emit() { FM_ROOT="$REPO" "$EMIT" --actor "$NAME" --task "$TASK" "$@" >/dev/null 2>&1 || true; }

cfg() { sed -n "s/^$1:[[:space:]]*//p" config.yaml 2>/dev/null | head -1 | tr -d '"'; }
fallbacks() { sed -n '/^fallback:/,/^[^ -]/p' config.yaml 2>/dev/null | sed -n 's/^[[:space:]]*-[[:space:]]*//p'; }

spec="$(jq -r --arg t "$TASK" '.tasks[]|select(.id==$t)' design/tasks.json 2>/dev/null)"
[ -n "$spec" ] || { echo "fm-worker: no task $TASK in design/tasks.json" >&2; exit 65; }

slug="$(printf '%s' "$TASK" | tr 'A-Z' 'a-z')"
branch="$slug-$(jq -r '.title' <<<"$spec" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | cut -c1-28 | sed 's/-*$//')"
tree="$REPO/state/worktrees/$TASK"

# --- a worktree of its own -----------------------------------------------
rm -rf "$tree"; mkdir -p "$REPO/state/worktrees"
git worktree prune >/dev/null 2>&1
git branch -D "$branch" >/dev/null 2>&1
git worktree add -q -b "$branch" "$tree" "$BASE" || { echo "fm-worker: could not create the worktree" >&2; exit 70; }

# --- the prompt: the task, the design that bears on it, and the skill ----
prompt="$tree/.fm-prompt.md"
{
  cat skills/worker/SKILL.md
  printf '\n---\n\n# Your task\n\n```json\n%s\n```\n' "$spec"
  printf '\nYour worktree is the current directory. Your branch is `%s`.\n' "$branch"
  printf 'Stay inside these paths:\n'
  jq -r '.scope[]|"  - " + .' <<<"$spec"
  printf '\n---\n\n# The design\n\n'
  sed -n '/^## 6\./,/^## 8\./p' design/design.md 2>/dev/null
} > "$prompt"

# --- the adapter, with fallback only on a vendor being unavailable -------
log="$REPO/state/worktrees/$TASK.log"; : > "$log"
vendors="${VENDOR:-$(cfg vendor)}"
[ -n "$vendors" ] || vendors=mock
for v in $vendors $( [ -n "$VENDOR" ] || fallbacks ); do
  a="$REPO/bin/adapters/$v.sh"
  [ -x "$a" ] || continue
  "$a" run "$prompt" "$tree" "$log"; rc=$?
  case "$rc" in
    2) emit --type vendor_unavailable --en "$v unavailable, trying the next" \
            --tw "$v 不可用，換下一家"; continue ;;
    *) break ;;
  esac
done
[ "${rc:-2}" = "2" ] && { echo "fm-worker: every vendor was unavailable" >&2; exit 2; }

rm -f "$prompt"
if [ -z "$(git -C "$tree" status --porcelain)" ]; then
  echo "fm-worker: the adapter changed nothing" >&2
  emit --type gate_failed --en "the adapter changed nothing" --tw "adapter 沒有改動任何檔案"
  exit 1
fi

# --- from here on it is the script's job, never the adapter's ------------
git -C "$tree" add -A
git -C "$tree" -c user.name=firstmate -c user.email=firstmate@local \
  commit -q -m "$TASK: $(jq -r .title <<<"$spec")"
emit --type commit_pushed --en "committed on $branch" --tw "已在 $branch 上 commit"
git -C "$tree" push -q -u origin "$branch" 2>/dev/null || {
  echo "fm-worker: could not push $branch" >&2; exit 71; }

pr="$($GH pr create --head "$branch" --base "$BASE" \
      --title "$TASK: $(jq -r .title <<<"$spec")" \
      --body "Dispatched by firstmate for $TASK. Acceptance is in design/tasks.json." \
      2>/dev/null | tail -1)"
emit --type pr_opened --en "opened $pr" --tw "已開 $pr"
printf '%s\n' "$branch"
[ "${rc:-1}" = "0" ] || exit 1
exit 0
