# Supervision: waking firstmate on every harness (T-137)

A turn never ends blind while work is in flight. One watcher does the
watching for every harness; only the way it wakes the session differs, and
that is what is recorded here. Nothing below is claimed that is not marked
verified, and each entry says how it was checked.

## What is common

- `bin/fm-watch.sh` blocks until one event needs firstmate and prints one
  line: `finished: T-134 worker`, `lost: T-134`, `crashed: T-134`,
  `review: T-134 APPROVE 4ea1ec2`, `gate: T-134 fail 5`,
  `card: D-... answered A`, `merged: #106`, `ci: #106 failure`,
  `protocol: T-134`, `vendor: T-134`. Progress of a round still running is
  absorbed. `state/watch/cursor` makes an event wake at most once;
  `state/watch/beacon` is touched every pass.
- `bin/fm-watch-arm.sh` keeps one watcher cycle per repository (a lock, and a
  generation number in `state/watch/owner`), hands the watch to the next
  generation before it lets a wake out, and prints the wake once, to
  whichever arm claimed it.
- `bin/fm-turnend-guard.sh` exits 2 while work is in flight and no watcher is
  alive (after trying to start one).
- Crew rounds (`FM_IN_ROUND`, a path under `state/worktrees` or
  `state/projects`, or any git worktree that is not the repository's own
  checkout) never arm; while `state/away` exists every hook stands down.

## Installing the hooks

`.codex/hooks.json` is in the repository. The Claude Code and Cursor
configurations live in `bin/hooks/` as templates and are copied into place
once, from the repository root:

    mkdir -p .claude .cursor
    cp bin/hooks/claude-settings.json .claude/settings.json
    cp bin/hooks/cursor-hooks.json .cursor/hooks.json

They could not be committed in place by the round that wrote them: its
sandbox refuses to create a `.claude` or a `.cursor` directory. Where a
`.claude/settings.json` already exists, merge the `Stop` entries in.

## Claude Code

- Protocol: a `Stop` hook with `"asyncRewake": true` runs in the background
  after the turn ends; when it exits 2, its output is delivered to the model
  and wakes an idle session. A synchronous `Stop` hook that exits 2 blocks the
  stop and returns stderr to the model; `stop_hook_active` in its payload says
  the stop is already a hook's doing.
- Ours: `bin/hooks/claude-stop-arm.sh` (asyncRewake, timeout 86400, parks on
  `fm-watch-arm.sh --max-wait 85000`, exits 2 with the reason on stderr) and
  `bin/hooks/claude-stop-guard.sh` (synchronous, timeout 30, refuses while
  work is in flight and no watcher is alive; never twice in a row).
- Version: Claude Code 2.1.284.
- Checked here: the installed binary carries the `asyncRewake` hook option and
  the text "asyncRewake hook exits with code 2". Its Stop hook payload and
  exit-2 contract are those of the hook documentation; the suite
  (`tests/watch.test.sh`) exercises both scripts against that payload and
  exit-code contract.
- Live verification of an idle session being woken: **not yet done**. The
  round that wrote this had no way to run an interactive Claude Code session.
  It is to be recorded here, with the version, by whoever installs the
  template: start a session, dispatch a task, let the turn end, and see the
  session wake on `finished:`.

## Codex

- Protocol: a `Stop` hook in `.codex/hooks.json` receives a payload with
  `stop_hook_active`, and answering `{"decision":"block","reason":...}`
  continues the turn with the reason as what the model reads next. It cannot
  wake an idle session; the wake is the hook itself, parked at the end of the
  turn.
- Ours: `bin/hooks/codex-stop.sh` (timeout 3600). While work is in flight it
  parks on the arm for up to 3300 s and answers with what woke it; if the park
  runs out first it answers with the instruction to park as a foreground call
  (`bin/fm-watch-arm.sh`), unless the stop is already a hook's continuation.
  With nothing in flight it only makes sure a watcher is running.
- Version: codex-cli 0.155.1.
- Checked here: the installed binary contains `stop_hook_active` and reads
  `hooks.json`. The `decision: block` answer is from the hook documentation.
- Live verification: **not yet done** (the same reason). Until it is, an idle
  Codex session with nothing in flight is not woken: the hook runs only at the
  end of a turn.

## Cursor

- Protocol: a `stop` hook in `.cursor/hooks.json` receives `status` and
  `loop_count`; a `followup_message` in its output is submitted as the next
  message, at most `loop_limit` times.
- Ours: `bin/hooks/cursor-stop.sh` (timeout 3600, `loop_limit` 20). Same park
  as Codex, answering `{"followup_message": ...}`; an aborted or errored stop
  is not parked on.
- Version: cursor-agent 2026.09.23-86fc751.
- Checked here: the version only. The payload and output shape are from the
  hook documentation.
- Live verification: **not yet done**.

## Harnesses with no hook support

Named unsupported until one is verified. Firstmate there runs
`bin/fm-watch.sh` in a Herdr pane, in a loop, and raises a desktop
notification with what it prints (`osascript -e 'display notification ...'`
on macOS, `notify-send` on Linux); it says to the captain that it is on the
fallback.

## Recorded gaps

- No harness has been driven live for this task; the entries above say so.
- `state/watch/cursor` starts at the end of the log the first time a watcher
  runs: events from before the first arming are not replayed.
- A wake is delivered once. If the harness loses it in flight, the event is
  not offered again; `state/watch/last-wake.json` and the board's last-wake
  line still name it.
