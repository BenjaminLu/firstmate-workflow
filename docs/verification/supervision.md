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

T-164 separates configuration, loading, feature policy, definition trust and
model delivery. Installing files establishes only configuration.

- **Configuration:** `bin/fm.sh hooks install --harness codex` merges our
  three handlers into `.codex/hooks.json`. It creates a comment-only
  `.codex/config.toml` discovery layer when absent. Both files are ignored;
  existing configuration, custom hooks and explicit `hooks = false` survive.
  Uninstall removes our handlers and only an untouched, firstmate-created
  discovery layer. It never changes global configuration or trust records.
- **Evidence supplied by firstmate, 2026-10-02:** codex-cli 0.159.3, fresh
  app-server stdio `initialize` and `hooks/list`, without starting a model
  or thread, reported this repository's UserPromptSubmit and Stop handlers
  loaded and enabled, but **untrusted**. Two trusted global SessionStart
  handlers did not establish project-definition trust. This is the verified
  cause of skipped project hooks. It does not verify this candidate's added
  SessionStart handler or any conversational delivery.
- **Installed schema evidence from the earlier worker round:** generated
  app-server schema exposed `sourcePath`, `currentHash`, `enabled` and
  `trustStatus` (`managed`, `untrusted`, `trusted`, `modified`). Version and
  feature probes reported 0.159.3 and `hooks stable true`. Binary strings
  are not evidence of loading.
- **Diagnostics:** `bin/fm.sh hooks status --harness codex --client cli
  --evidence /path/to/hooks-list-result.json` consumes the JSON **result
  object**, with `data` entries for this repository's absolute `cwd`.
  Collect it using the target client's supported `hooks/list` request with
  `cwds` naming this checkout. The report matches source, event, command,
  timeout and enabled/trust status. Its `ready` field describes that supplied
  snapshot plus the local CLI feature probe, not a running conversation or
  model receipt. An app-server client may have different effective settings;
  check those in that target too. Absent evidence remains unverified.

The [official hook contract](https://learn.chatgpt.com/docs/hooks) requires
an active project config layer and separate review of exact hook definitions.
In the CLI, open `/hooks`, inspect this checkout's source, and trust the
current SessionStart, UserPromptSubmit and Stop definitions. Changed hashes
require review again. Restart/resume if the new source is absent; no current
conversation hot reload is established. When disabled or refused by managed
policy, inspect `features.hooks` and `allow_managed_hooks_only` in effective
requirements; involve the administrator instead of overriding policy.
Unsupported clients cannot be repaired by writing more configuration.

SessionStart (including resume) and UserPromptSubmit reconnect the kernel-owned
watcher and output `hookSpecificOutput.additionalContext`. Stop uses
`decision: block` with a continuation reason; an already-active Stop hook,
crew/away context or idle session with no pending work returns no output.
These shapes follow the official contract. Background completion does not
start an idle turn, so no idle push is promised.

The watcher stages queue items without acknowledgement in `.staged` files,
which arms cannot claim while their publisher holds its per-generation kernel
lock. An arm recovers an abandoned stage after that lock is released; it
reconnects a watcher before returning the recovered wake. A parked arm also
subscribes to the staged publisher’s process exit, even when its successor is
already running. No PID polling or file-age timeout decides abandonment.
After the successor startup completes (or reports
failure), it publishes the structured handoff as `.json` and rings the arms.
Structured handoffs contain queue items, without the legacy display-only
`lines` field: the board already counts their unacknowledged queue IDs.
An ending generation records its end time before closing its doorbell, even
if it released the watch lock but failed to start a successor; it preserves
the successor's owner record when that successor did start. Published records
remain reachable until acknowledgement succeeds. Legacy claim/take paths
preserve generation order, and all shared acknowledgements are bounded by
the supplied wake timestamp, including explicit session acknowledgements.
Legacy hook text includes every claimed line; it does not hide acknowledged
lines behind a presentation limit. Legacy claims still acknowledge before
harness output, so they do not guarantee recovery from a later output failure
or prove model receipt.

Shared consumers now commit each returned batch through a durable undo journal
under the acknowledgement lock. During an incomplete batch, shared readers see
the pre-batch watermarks; the next writer restores those values before proceeding.
Claims gather all eligible generations before committing, and legacy pending
combines staged and directly queued items into that same batch. A failed later
write therefore cannot hide an earlier, unreturned item. Direct queue takes and
Codex output use the same transaction; explicit session acknowledgement also
recovers any interrupted transaction. Per-ID files remain the board's existing
format, but the board's raw-file projection does not read the undo journal and
may temporarily show partial acknowledgement until recovery. This is not model
delivery evidence. The transaction commit is still the legacy claim boundary:
process death after commit but before harness receipt cannot be resolved without
a delivery receipt. No exactly-once harness delivery is claimed.

Codex reads the durable queue, bounds each output batch, and acknowledges only emitted wake timestamps
after stdout flush succeeds. Failed writes and watcher startup failures retain
pending items. A crash between flush and acknowledgement can replay output;
exactly-once model receipt is not guaranteed by a pipe write. The last-wake
record explicitly labels model delivery unverified.

### Required disposable smoke (firstmate, before declaring repair)

Use an isolated disposable checkout with its own state and supported Codex
client configuration. Keep the running supervisor on its immutable snapshot.
Do not use a raw vendor launcher, captain-pane input, forged trust records or
a trust bypass. Firstmate coordinates the normal supported launch and operator
review through `/hooks`.

1. Record the candidate head, client surface/version, effective feature and
   policy, and actual loaded source path plus each current hash/trust status
   from `hooks/list`. Review the fixture's exact definitions, then restart or
   resume through the supported session path if needed.
2. Answer a fixture decision with a unique ID through the normal board writer.
   Capture the real SessionStart/resume or UserPromptSubmit event and the
   model's visible receipt of that ID and answer. Fire another user turn and
   record that the same wake is not repeated.
3. During an active turn, queue another decision and capture the real Stop
   event, its continuation reason, and the model handling that exact ID.
   Record duplicate hook firing with one live watcher and owner termination
   with no surviving watcher. Do not substitute a queue entry, cursor move,
   acknowledged file or synthetic hook subprocess for model receipt.
4. Record disconnected-output recovery, the current conversation's reload
   limit, and a separate Claude regression check with version, event, wake ID,
   visible receipt and cleanup. Existing Claude mechanism evidence below/above
   is historical; it is not a regression run of this candidate.

**Still missing:** firstmate's real trusted hook events and delivery evidence,
owner cleanup, current-head CI/gates, and current-candidate Claude smoke. The
worker authored regressions but did not run suites. The supplied shard 4 CI
excerpt ends at the aggregate failure and does not identify its failing test.

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
