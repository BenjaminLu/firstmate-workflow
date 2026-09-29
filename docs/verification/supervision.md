# Supervision: waking firstmate on every harness (T-137)

A turn never ends blind while work is in flight. The wake is pushed by
whoever writes the event that needs firstmate; only the way a harness is
woken differs, and that is what this file records. Nothing here is claimed
beyond what each entry says was checked, and how.

## What is common

- **Writers.** Each appends one item to `state/session/wake.jsonl` and rings
  every doorbell under `state/session/wake.d/`
  (`bin/lib/fm_lifeline.py push`, the T-151 doorbell). The line is what
  firstmate is woken with:

  | Writer | When | Line |
  |---|---|---|
  | `bin/fm-worker.sh` | a round ends, after its `agent_finished` | `finished: T-134 worker-mira-t134-r1 ok #9`, `failed: ... exit 1` |
  | `bin/fm-review.sh` | a review round ends | `review: T-134 APPROVE 4ea1ec2 #9`, `review: T-134 REJECT ...`, `review: T-134 no verdict exit 3 ...` |
  | `bin/fm-herdr.py` (deck reconcile) | a run is found lost | `lost: T-134 worker-mira-t134-r1` |
  | `bin/fm-emit.sh` | a `gate_passed`/`gate_failed` written by anyone but a crew round | `gate: T-134 failed gate 6 #9` |
  | `board/server.ts` (T-151) | a card is answered; a merge it started settles | `card: D-51 answered A`; `merge: D-51 merged`, `merge: D-51 failed` |

  A round's progress (`crew_status`) is never pushed. `bin/fm-decide.sh`
  records no answer (the board does); it is a waiter, not a writer. No fm
  script follows a pull request's required check to its end today:
  `bin/fm-gate.sh` reads it once, and `bin/fm-run.sh` emits no gate event.
  The `fm-emit.sh` writer is where such a follower's result wakes firstmate
  (T-141's autopilot, when it lands); until then a finished check wakes
  nobody by itself, and firstmate reads it at the merge gate as before.
- **The watch.** `bin/fm-watch-arm.sh` attaches to the one live watcher
  cycle of the repository, or starts one through the lifeline, owned by the
  harness session (`state/watch/cycle.lock` held by the live cycle; a
  generation number in `state/watch/generation`; `arm.lock` so only one arm
  starts one). A cycle (`bin/fm-watch.sh`) blocks on its doorbell until a wake
  is past the cursor (`state/watch/cursor`), takes it, starts its successor,
  and only then writes the wake (`state/watch/wake/<gen>.json`), which exactly
  one arm claims. A cycle whose lock the kernel has released is superseded
  by the next arm. The steps are journaled in `state/watch/journal`.
- **Who arms.** Only the primary: a crew round (`FM_IN_ROUND`), a checkout
  under `state/worktrees` or `state/projects`, and a linked git worktree
  never arm or wake, and every hook stands down while `state/away` exists
  (the away mode itself is a later task).
- **Installing.** `bin/fm.sh hooks install [--harness claude|codex|cursor]`
  merges the entries below into each harness's local config and prints what
  it changed; a second install changes nothing; `uninstall` removes exactly
  those entries. `bin/fm-session.sh start` installs them for the harness it
  detects (`FM_HARNESS`, else the session process's name, else
  `CLAUDECODE=1`). No harness config is committed: those files are listed in
  `.gitignore`.

## Claude Code

- **Config**: `.claude/settings.local.json` (Claude Code's local,
  uncommitted project settings).
  - `Stop`, synchronous: `bin/fm-turnend-guard.sh --hook claude`, timeout 30.
    With work in flight and no watcher it first tries to start one; if none
    can hold the watch it exits 2 with the order to park on
    `bin/fm-watch-arm.sh` on stderr. Never when `stop_hook_active` is set.
  - `Stop`, `asyncRewake: true`: `bin/fm-watch-arm.sh --hook claude`,
    timeout 86400. It parks on its doorbell and on its owning claude's exit
    (kqueue `NOTE_EXIT` on macOS, a pidfd on Linux, through
    `bin/lib/fm_lifeline.py`), exits 2 with the wake on stderr, and exits 0
    when its owner is gone, taking nothing. Its wait ends 60 s before the
    timeout; if work is still in flight then, it wakes the session once to
    say so, so that the next turn end parks again.
  - `UserPromptSubmit`: `bin/fm-watch-arm.sh --turn-start claude` adds what
    waits to the turn's context (`hookSpecificOutput.additionalContext`).
- **Measured by firstmate, 2026-09-29, Claude Code 2.1.284, this Mac**
  (recorded here from firstmate's brief on the pull request; the round that
  wrote this file could not drive an interactive session):
  1. An idle interactive session with a `Stop` hook configured as
     `{"type":"command","command":"<path>","asyncRewake":true,"timeout":600}`
     was woken when the hook exited 2 with a reason on stderr, and answered
     with its earlier context.
  2. The hook re-armed at the next turn end.
  3. A plain blocking hook was orphaned (ppid 1) when claude was SIGKILLed,
     kept reading the FIFO, and stole the next wake line.
  4. The verified shape that fixes it was a Python hook doing kqueue on
     (owner pid, FIFO fd), exiting 0 when the owner exits. The arm above has
     that shape; `tests/watch.test.sh` stands a stub session in for claude
     and checks each point against it.
- **Not yet verified live**: these hooks themselves, as installed by
  `fm hooks install` (the timeout of 86400 rather than the 600 measured;
  the guard; `UserPromptSubmit`). Firstmate verifies after merge and records
  it here.
- **Stub payloads** in the suite are the documented `Stop` fields
  (`session_id`, `transcript_path`, `hook_event_name`, `stop_hook_active`,
  `cwd`) and the `UserPromptSubmit` `prompt`; the exit-2/stderr contract is
  the one measured above.

## Codex

- **Config**: `.codex/hooks.json` in the repository (project-local hooks;
  listed in `.gitignore`, never committed). Version installed here:
  codex-cli 0.155.1.
  - `Stop`: `bin/fm-turnend-guard.sh --hook codex`, timeout 60. It answers
    `{"decision":"block","reason":...}` with whatever wake waits, or, with
    work in flight and nothing waiting, with the order to park on
    `bin/fm-watch-arm.sh --max-wait 3000` in the foreground. It says
    nothing when `stop_hook_active` is set.
  - `UserPromptSubmit`: `bin/fm-watch-arm.sh --turn-start codex`
    (`hookSpecificOutput.additionalContext`).
- **Checked here**: the codex 0.155.1 binary carries the strings
  `stop_hook_active`, `UserPromptSubmit`, `SessionStart`,
  `additionalContext` and `hookSpecificOutput`, and names `hooks.json`. That
  is all.
- **Unverified: firstmate verifies live after merge.** Whether Codex reads
  the project's `.codex/hooks.json` (or needs a feature flag), whether the
  `decision: block` answer continues the turn, and whether an outside client
  can push `turn/start` through `codex app-server` into the thread of an
  interactive TUI (so an idle Codex session can be woken at all). Until
  that is recorded here, an idle Codex session is not woken: what waits is
  read at its next turn start (and by `bin/fm-session.sh status`), and the
  board shows it waiting.

## Cursor

- **Config**: `.cursor/hooks.json` in the repository (`version: 1`; listed
  in `.gitignore`). Version installed here: cursor-agent 2026.09.23-86fc751.
  - `stop`: `bin/fm-turnend-guard.sh --hook cursor`, timeout 60,
    `loop_limit` 5. On a stop whose `status` is `completed` it answers
    `{"followup_message": ...}` with whatever wake waits, or the order to
    park, as for Codex; any other status is left alone.
- **Checked here**: the version only. The payload fields (`status`,
  `loop_count`, `conversation_id`, `generation_id`, `workspace_roots`) and the
  `followup_message` answer are from Cursor's hook documentation.
- **Unverified: firstmate verifies live after merge.** Until then an idle
  Cursor session is not woken; what waits is read at the next stop or turn
  start, and the board shows it waiting.

## Harnesses with no hook support

Named unsupported until one is verified. Firstmate there runs the watch in a
Herdr pane, `bin/fm-watch-arm.sh --follow`, which prints each wake and raises
a desktop notification (`FM_NOTIFY`, else `osascript` on macOS, else
`notify-send`); `--follow --background` starts the same through the
lifeline, owned by the session. Firstmate tells the captain it is on the
fallback.

## Recorded limits

- The cursor starts at the end of the queue the first time the watch runs:
  wakes pushed before are reported by `bin/fm-session.sh status`, not
  replayed.
- A wake is delivered once. If a harness loses it after the claim,
  `state/watch/last-wake.json`, the board's last-wake line and
  `bin/fm-session.sh status` still name it.
- A cycle killed outright (SIGKILL) cannot say when it ended; the board then
  counts the gap from when the work in flight began.
