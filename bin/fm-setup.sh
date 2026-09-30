#!/usr/bin/env bash
# fm setup (T-121): the first-run wizard. It asks only what firstmate
# cannot find out for itself, each question with a recommended default that
# Enter accepts, writes config.yaml, then runs `fm doctor --sandbox`. It
# never asks for or stores a secret itself: for a key it prints the exact
# keychain command for the operator to run.
#
#   bin/fm-setup.sh [--answers FILE] [--repo DIR]
#
# --answers FILE holds "key: value" lines, one per question, read with
# fm_cfg - the same reader config.yaml has - instead of prompting for that
# key: how the wizard is driven non-interactively. A key the file does not
# name is still asked (empty input takes the default), so a file that names
# nothing at all is "every default".
set -uo pipefail
# The operator's typing is kept on fd 9 for the questions below; every
# child this script starts gets /dev/null, never the operator's input.
exec 9<&0
exec < /dev/null

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$HERE/fm-config.sh" ] || { echo "fm-setup: missing $HERE/fm-config.sh" >&2; exit 70; }
# shellcheck source=bin/fm-config.sh
. "$HERE/fm-config.sh"

answers=''; repo="${FM_ROOT:-$(pwd -P)}"
while [ $# -gt 0 ]; do
  case "$1" in
    --answers) fm_need "fm-setup" "$@"; answers="${2-}"; shift 2 ;;
    --repo) fm_need "fm-setup" "$@"; repo="${2-}"; shift 2 ;;
    *) echo "usage: fm-setup.sh [--answers FILE] [--repo DIR]" >&2; exit 64 ;;
  esac
done
repo="$(cd "$repo" 2>/dev/null && pwd -P)" || { echo "fm-setup: no repo at $repo" >&2; exit 64; }
[ -z "$answers" ] || [ -f "$answers" ] || { echo "fm-setup: no answers file at $answers" >&2; exit 64; }
cd "$repo" || exit 70

# --- asking: an answers file first, the operator (empty = the default) otherwise
ask() {  # ask <key> <prompt> <default> -> REPLY
  local key="$1" prompt="$2" default="$3" val=''
  [ -z "$answers" ] || val="$(fm_cfg "$key" "$answers")"
  if [ -z "$val" ]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
    IFS= read -r val <&9 || val=''
  fi
  REPLY="${val:-$default}"
}

# --- which vendors are here to choose from: the one list, fm_vendors --------
installed="$(fm_vendors | while IFS= read -r name; do
  command -v "$name" >/dev/null 2>&1 && printf '%s\n' "$name"
done)"
if [ -z "$installed" ]; then
  echo "fm setup: no vendor CLI found ($(fm_vendors | paste -sd ' ' -)); install at least one and run fm setup again" >&2
fi
# usable: installed, and its round's login answers `authenticated` to the
# same probe fm-worker.sh and fm-review.sh ask before a round
usable=''
if [ -x "$HERE/fm-auth-probe.sh" ] && [ -n "$installed" ]; then
  usable="$(while IFS= read -r name; do
    [ "$("$HERE/fm-auth-probe.sh" "$name" </dev/null 2>/dev/null | sed -n 's/^status: //p')" = authenticated ] \
      && printf '%s\n' "$name"
  done <<<"$installed")"
fi
# recommended: a usable vendor before one that is only installed
ranked="$(printf '%s\n%s\n' "$usable" "$installed" | awk 'NF && !seen[$0]++')"
worker_default="$(head -1 <<<"$ranked")"
worker_default="${worker_default:-claude}"
# a different vendor reviews independently, when a second one is there
reviewer_default="$(grep -vxF -- "$worker_default" <<<"$ranked" | head -1)"
reviewer_default="${reviewer_default:-$worker_default}"

ask worker_vendor "Which installed vendor crews as worker? ($(paste -sd ' ' - <<<"${installed:-none installed}"))" "$worker_default"
worker_vendor="$REPLY"
ask reviewer_vendor "Which installed vendor crews as reviewer? (a different one reviews independently)" "$reviewer_default"
reviewer_vendor="$REPLY"

# --- billing: subscription by default, api-key only if the operator says so
billing_done=''; billing_pairs=''
ask_billing() {
  local v="$1"
  case " $billing_done " in *" $v "*) return 0 ;; esac
  billing_done="$billing_done $v"
  login_note "$v"
  ask "billing_$v" "Does $v bill to your subscription, or per API use, inside the sandbox? [subscription/api-key]" "subscription"
  [ "$REPLY" = api-key ] && billing_pairs="$billing_pairs $v"
}
# How a round of <vendor> signs in inside the sandbox, and what it bills,
# said plainly; for a key, the exact command the operator runs - this
# wizard never reads or stores one.
login_note() {
  case "$1" in
    claude) echo "fm setup: a claude round signs in with a crew token of its own, billed to your Claude subscription; make it with 'claude setup-token', then keep it with: security add-generic-password -s firstmate-claude-token -a \"\$USER\" -w  (api-key instead bills per use to the ANTHROPIC_API_KEY in your shell)" >&2 ;;
    codex) echo "fm setup: a codex round signs in with a copy of ~/.codex/auth.json from 'codex login', billed to your ChatGPT plan  (api-key instead bills per use to OPENAI_API_KEY)" >&2 ;;
    cursor-agent) echo "fm setup: a cursor-agent round signs in with a Cursor API key, billed to your Cursor account ('agent login' does not work inside the sandbox); keep it with: security add-generic-password -s firstmate-cursor-api-key -a \"\$USER\" -w" >&2 ;;
    gemini) echo "fm setup: a gemini round signs in with ~/.gemini/oauth_creds.json from starting gemini once outside a round, billed to your Google account; its login cannot be verified, so rounds on it are refused for now" >&2 ;;
  esac
}
ask_billing "$worker_vendor"
ask_billing "$reviewer_vendor"

# --- the main repository and base branch ------------------------------------
default_github=''
if origin_url="$(git -C "$repo" remote get-url origin 2>/dev/null)"; then
  default_github="$(printf '%s\n' "$origin_url" \
    | sed -E 's#^(git@|https://)([^:/]+)[:/](.+/[^/]+?)(\.git)?$#\3#')"
fi
default_base=main
ref="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
[ -z "$ref" ] || default_base="${ref##*/}"

ask repo_github "Main repository (owner/repo)" "$default_github"
repo_github="$REPLY"
ask repo_base "Base branch" "$default_base"
repo_base="$REPLY"

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    echo "fm setup: gh is signed in" >&2
    if [ -n "$repo_github" ]; then
      perm="$(gh repo view "$repo_github" --json viewerPermission -q .viewerPermission 2>/dev/null)"
      case "$perm" in
        ADMIN|WRITE|MAINTAIN) echo "fm setup: push rights on $repo_github confirmed ($perm)" >&2 ;;
        '') echo "fm setup: could not read push rights on $repo_github from gh" >&2 ;;
        *) echo "fm setup: gh reports '$perm' on $repo_github; the crew needs write access to open pull requests" >&2 ;;
      esac
    fi
  else
    echo "fm setup: gh is not signed in; run 'gh auth login' before the crew can open pull requests" >&2
  fi
else
  echo "fm setup: gh is not installed; fm doctor says how to get it" >&2
fi

# The board's port and the language for cards and reports are not asked:
# nothing reads either as a setting yet, so an answer would change nothing
# (the captain moved both to T-154, 2026-09-29).

project_name="$(fm_cfg default_project config.yaml 2>/dev/null)"
[ -n "$project_name" ] || project_name="${repo_github##*/}"
[ -n "$project_name" ] || project_name="$(basename "$repo")"

# --- write it: only through fm_cfg_set, the one writer ---------------------
# It writes only what was answered or found out, and creates what is
# missing; every other key - the policy, the projects, a model, the
# reviewer's mode - and the comment structure are left as they were.
set_kv() { fm_cfg_set "$1" "$2" config.yaml || { echo "fm-setup: could not write config.yaml ($1)" >&2; exit 70; }; }

# What was there before, read before anything is written
old_vendor=''; old_reviewer=''; old_mode=''; old_model=''; old_reviewer_model=''
if [ -f config.yaml ]; then
  old_vendor="$(fm_cfg vendor config.yaml)"
  old_model="$(fm_cfg model config.yaml)"
  old_reviewer="$(fm_cfg_in reviewer vendor config.yaml)"
  old_reviewer_model="$(fm_cfg_in reviewer model config.yaml)"
  old_mode="$(fm_cfg_in reviewer mode config.yaml)"
fi

# No model is written: there is no model question, and a model name is the
# vendor's own. One already there that was chosen for another vendor is
# said, not changed.
[ -f config.yaml ] || printf '# firstmate-workflow\n\nvendor: %s\n' "$worker_vendor" > config.yaml

set_kv vendor "$worker_vendor"
set_kv reviewer.vendor "$reviewer_vendor"
if [ -n "$old_model" ] && [ -n "$old_vendor" ] && [ "$old_vendor" != "$worker_vendor" ]; then
  echo "fm setup: config.yaml's model '$old_model' was chosen for $old_vendor; check it names a $worker_vendor model" >&2
fi
if [ -n "$old_reviewer_model" ] && [ -n "$old_reviewer" ] && [ "$old_reviewer" != "$reviewer_vendor" ]; then
  echo "fm setup: config.yaml's reviewer model '$old_reviewer_model' was chosen for $old_reviewer; check it names a $reviewer_vendor model" >&2
fi
# The reviewer's mode is never asked and is kept as it is (diff when unset,
# fm-review.sh's default), with one exception found out rather than asked:
# a run-mode review goes only to an adapter that confines it (its
# `# fm:review-run` line), and fm-review.sh refuses every round otherwise,
# so a kept `run` with a reviewer that has no such adapter becomes `diff`,
# and the wizard says so.
if [ "$old_mode" = run ] && ! grep -q '^# fm:review-run' "$HERE/adapters/$reviewer_vendor.sh" 2>/dev/null; then
  set_kv reviewer.mode diff
  echo "fm setup: $reviewer_vendor cannot run a run-mode review (only an adapter that confines it can), so reviewer.mode is now diff" >&2
fi
for v in $billing_pairs; do set_kv "billing.$v" api-key; done
if [ -n "$repo_github" ]; then
  set_kv default_project "$project_name"
  set_kv "projects.$project_name.repo" .
  set_kv "projects.$project_name.github" "$repo_github"
  set_kv "projects.$project_name.base" "$repo_base"
fi

echo "fm setup: wrote config.yaml" >&2
[ -x "$HERE/fm-doctor.sh" ] || { echo "fm-setup: missing $HERE/fm-doctor.sh" >&2; exit 70; }
"$HERE/fm-doctor.sh" --sandbox --repo "$repo" </dev/null
exit $?
