#!/usr/bin/env bash
# Git hooks are not cloned, so every checkout has to opt in once.
#   bin/fm-install-hooks.sh          point this worktree at .githooks
#   bin/fm-install-hooks.sh --check  report whether it is pointed there
set -euo pipefail
root=$(git rev-parse --show-toplevel)
if [ "${1-}" = "--check" ]; then
  [ "$(git -C "$root" config --get core.hooksPath || true)" = ".githooks" ]
  exit $?
fi
git -C "$root" config core.hooksPath .githooks
printf 'fm-guard: hooks installed (core.hooksPath=.githooks)\n'
