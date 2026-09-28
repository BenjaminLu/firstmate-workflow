#!/usr/bin/env bash
# A stand-in adapter for tests/canary.test.sh and fm-canary.sh's hostile
# workload (T-128): plays the part of code running inside a round that
# destroys its own tree - not a model, no network, deterministic - so the
# mirror-and-restore mechanism in fm-worker.sh can be proved without
# spending a real model call. Point FM_CODE_ROOT at the directory holding
# this fixture (its bin/adapters/) and dispatch --vendor mock-hostile, the
# same way a frozen snapshot is resolved.
#
# Every action below is built from $tree (this run's own worktree, handed
# in as $3, exactly as fm_run_chain hands every adapter its argv) or the
# round's own TMPDIR, never a bare empty variable with no root under it:
# `rm -rf "$EMPTY$tree"` reproduces the class of bug - a destructive
# command built by concatenating an empty variable - while never being
# able to resolve outside this round's own tree, whatever runs it. The one
# way to safely run the literal unconfined shape, `rm -rf "$EMPTY/"`, is
# inside a real OS sandbox that confines the blast radius to the write
# roots; tests/sandbox.test.sh's own real-sandbox check exercises that
# directly, gated on a real sandbox tool being available to nest in.
#
#   FM_HOSTILE_MODE=tree|git|empty-var|truncate|fill-tmp   (default: tree)
#   FM_HOSTILE_FILL_BYTES=<n>       how much to write under TMPDIR for fill-tmp
#   FM_HOSTILE_SLEEP_BEFORE=<secs>  pause after writing before-the-wreck.txt,
#                                   so a fast watcher can mirror it first
#   FM_HOSTILE_SLEEP_AFTER=<secs>   pause after the wreck, so a fast watcher
#                                   can restore it while this round still runs
set -uo pipefail
[ "${1-}" = run ] || { echo "usage: mock-hostile.sh run <prompt> <worktree> <log>" >&2; exit 64; }
prompt="${2-}"; tree="${3-}"; log="${4-}"
[ -f "$prompt" ] || { echo "mock-hostile: no prompt at $prompt" >&2; exit 64; }
[ -n "$tree" ] && [ -d "$tree" ] || { echo "mock-hostile: no worktree at $tree" >&2; exit 64; }

{
  echo "mock-hostile adapter"
  echo "mode: ${FM_HOSTILE_MODE:-tree}"
} >> "${log:-/dev/null}"

# present before the wreck, so a mirror generation exists that proves this
# round ran rather than one that never started, and, with
# FM_HOSTILE_SLEEP_BEFORE, that the watcher mirrored it before the wreck
: > "$tree/before-the-wreck.txt" 2>/dev/null
[ "${FM_HOSTILE_SLEEP_BEFORE:-0}" = 0 ] || sleep "$FM_HOSTILE_SLEEP_BEFORE"

case "${FM_HOSTILE_MODE:-tree}" in
  tree)
    rm -rf "$tree"
    ;;
  git)
    rm -rf "$tree/.git"
    ;;
  empty-var)
    EMPTY=""
    # never just "$EMPTY/" - see the header. Always this round's own tree.
    rm -rf "$EMPTY$tree"
    ;;
  truncate)
    for f in "$tree"/*; do [ -f "$f" ] && : > "$f"; done
    ;;
  fill-tmp)
    if [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ]; then
      head -c "${FM_HOSTILE_FILL_BYTES:-1048576}" /dev/zero > "$TMPDIR/fm-hostile-fill" 2>/dev/null
    fi
    ;;
  *)
    echo "mock-hostile: unknown FM_HOSTILE_MODE ${FM_HOSTILE_MODE:-}" >&2
    exit 64
    ;;
esac
[ "${FM_HOSTILE_SLEEP_AFTER:-0}" = 0 ] || sleep "$FM_HOSTILE_SLEEP_AFTER"
# left only if $tree exists again by now - the watcher's own restore, seen
# from inside a round that has not exited yet, telling "restored while this
# round still ran" apart from "restored once it ended"
[ -d "$tree" ] && : > "$tree/mid-run-restore-seen" 2>/dev/null
exit 0
