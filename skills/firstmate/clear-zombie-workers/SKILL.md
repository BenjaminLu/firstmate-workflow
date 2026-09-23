---
name: clear-zombie-workers
description: Inventory and clear stuck or superseded worker/reviewer runtime state that blocks dispatch (task locks, dead pidfiles, orphan Cursor Agent adapter processes) without discarding open-PR worktrees or unrescued edits.
---

# Clear zombie workers

Use this when a task will not relaunch (`already has a live worker` /
`uncertain launch`), when pidfiles outlive their processes, or when events say
a run was superseded but processes or locks remain. This is firstmate
orchestration, not production implementation and not `bin/fm-cleanup.sh`
(that helper refuses open PR worktrees).

## Deck versus process (invariant)

The captain board paints **aboard** from `state/events.jsonl` only: an actor
stays aboard until that actor emits `agent_finished`. Task-level pidfiles
(`state/worktrees/T-NNN.pid`, `state/runtime/*.pid`) and T-017-style reconcile
do not close actor-keyed ghosts. Session bootstrap (`fm-session start` /
`status` → `retire_dead_crew`) is the durable fix: it emits `agent_finished`
with `data.status: process_gone` for dead worker/reviewer actors. Prefer that
path over hand-editing the log. Manual clearance below still applies when a
live process or lock blocks relaunch.

## Evidence before action

Collect all of the following. A historical `dispatched` event alone is not a
live worker.

1. **Pidfiles** — `state/runtime/*.pid` (worker, review, monitor). For each,
   read the PID and test `kill -0`.
2. **Task lock** — `state/runs/.worker-<TASK>.lock`. Use `lsof` (or equivalent)
   to see which PID still holds it.
3. **Processes** — any adapter CLI (Cursor Agent included) or `fm-worker.sh`
   whose cwd or open files are under `state/worktrees/<TASK>` or `state/runs/` /
   `state/runtime/archived-runs/` for that task.
4. **Herdr** — when `HERDR_ENV=1`, `herdr agent list` for panes still titled
   for the task. An internal chat subagent is not a Herdr worker.
5. **Events** — recent `state/events.jsonl` lines for the task (`dispatched`,
   `agent_finished`, `worker_crashed`, `superseded`).
6. **Worktree** — `git status` in `state/worktrees/<TASK>` and the published
   PR head OID when a PR is open.
7. **Run artifacts** — `result.json`, empty `cli.log`, and ownership receipts
   under `state/runs/` or `state/runtime/archived-runs/`.

## Live versus zombie

Treat a process as a **zombie** only when several signals agree:

| Signal | Zombie leaning |
| --- | --- |
| CPU / log growth | ~0% CPU and empty or frozen logs for many minutes |
| Events | marked `superseded`, `failed`, or cleared as ghost while the process remains |
| Artifacts | `result.json` already `failed`/`terminated`, or run dir already archived |
| Lock | holds `.worker-<TASK>.lock` but produces no new commits, say file, or events |
| Relaunch | new `fm-worker` refuses with live-worker / uncertain-launch because of it |

If the process is clearly writing, committing, or answering a live review,
**resume it** — do not kill it. Prefer one live owner per task lock.

## Clearance procedure

Do these steps in order. Prefer absolute `PATH` (`/usr/bin:/bin:/opt/homebrew/bin`)
so cleanup shells do not lose `git`/`rm`.

1. **Rescue first** — if the worktree has uncommitted work, copy it to
   `state/rescued/<TASK>-cleanup-<UTC stamp>` with `cp -a` before any kill or
   reset. Say where the rescue landed.
2. **Stop zombies only** — `kill` the PIDs that hold the task lock or are
   confirmed zombies; escalate to `kill -9` only if they survive a short wait.
   Do not kill unrelated Herdr/board processes.
3. **Dead pidfiles** — delete a pidfile only when its PID is gone. Never delete
   a pidfile whose process is still alive.
4. **Confirm lock release** — re-check `lsof` on `.worker-<TASK>.lock`. Absence
   of holders is required before the next dispatch.
5. **Worktree hygiene** — if the dirty tree was orphaned zombie output (for
   example mass deletions of unrelated shipped files) and a published PR head
   exists, `git reset --hard` to that head and `git clean` untracked junk
   (keep `.fm-say.md` if present). Do **not** remove an open-PR worktree with
   `fm-cleanup.sh`.
6. **Stale board cards** — pending merge/choice cards for long-finished tasks
   may be moved under `state/runtime/archived-pending/`; do not invent decision
   outcomes.
7. **Emit** — record what you cleared through `bin/fm-emit.sh` only
   (`agent_finished` or `dispatched` as appropriate), with both `en` and
   `zh-TW` summaries naming PIDs, lock, rescue path, and resulting head.
8. **Re-verify** — no matching task processes, no dead pidfiles left behind,
   lock not held, worktree matches the intended head. Then it is safe to
   relaunch via `bin/fm-worker.sh` / `bin/fm-review.sh`.

## Do not

- Claim clearance from events alone without process/lock checks.
- Kill a worker that is still making observable progress.
- Discard unrescued dirty trees.
- Use `fm-cleanup.sh` on a task whose branch still has an open PR.
- Edit live scripts a running worker is executing; use the normal snapshot path
  for new runs.
- Fabricate Herdr lifecycle events for log-only panes.

## After clearance

Resume the unfinished task through the normal scripts with the current closed
list / review context. Attach a monitor only when it waits on real pidfiles and
logs; a monitor whose worker pidfile is already dead is itself stale and should
be removed under the same rules.
