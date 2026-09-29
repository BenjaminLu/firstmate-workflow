---
name: dispatch-crew
description: Stock-only launch of workers and reviewers through fm-worker.sh / fm-review.sh. Use whenever firstmate dispatches or relaunches crew inside or outside Herdr.
---

# Stock crew dispatch

*Stock launch* is the only allowed way to start a worker or reviewer. Claude,
Codex and Cursor follow this recipe the same way. Session wrappers,
`run-*.sh` sidecars, `herdr pane run` of raw adapters, and inventing a
parallel launcher are protocol violations. Rounds run headless under fm's own
supervision; a Herdr, cmux or tmux window is only a view of the run's log.

## Recipe (worker)

From the firstmate Herdr pane (or any shell with `HERDR_ENV=1` and a known
`HERDR_PANE_ID`), launch through a durable process group so the orchestrator
survives the agent shell exiting (SIGHUP). Managed transport also ignores
SIGHUP on the waiter and pane-child, but `setsid` is still required for
background dispatch from a conversational agent:

```bash
setsid bin/fm-worker.sh --task <TASK> --repo <root> [--pr <N>] [--vendor <adapter>] [--name <alias>] </dev/null >/tmp/fm-worker-<TASK>.log 2>&1 &
```

Do not set `FM_TRANSPORT`. Do not write a wrapper script. Do not pre-create
the worker tab; managed transport creates the owned tab/root pane.

**Failure mode without setsid:** a background `bin/fm-worker.sh ... &` from an
agent tool shell often receives SIGHUP when that shell ends. The pane-child can
still finish and write `last-result.json` / autoclose, but the caller-side
commit/push/PR comment path is orphaned until a later recovery. Prefer `setsid`
(or equivalent new session) for every stock background launch.

**Done when:** `herdr agent list` (or `bin/fm-session.sh status --repo <root>`)
shows the canonical actor for that task as live/`working`, and
`state/runs/<actor>/` exists with a live process receipt.

## Recipe (reviewer)

```bash
setsid bin/fm-review.sh --task <TASK> --branch <branch> --repo <root> [--pr <N>] [--round <N>] [--vendor <adapter>] [--name <alias>] </dev/null >/tmp/fm-review-<TASK>.log 2>&1 &
```

Same rules: no `FM_TRANSPORT`, no wrappers, no raw adapter panes. Use `setsid`
for background launches for the same SIGHUP reason.

**Done when:** a review round artifact exists under the run dir and events
show `review_opened` / completion for that exact actor — or a truthful
`review_failed` from the script, not from a hand-rolled pane.

## Outside Herdr

Rounds are headless and owned by fm; a terminal host is only a window onto
them (`host:` in `config.yaml`). When `HERDR_ENV` is unset or not `1`, the same
stock commands run the same round with no Herdr pane. That is the default, not
an invented bypass; a window that cannot open never stops a round.

## Failure table (stop — do not invent)

| Observation | Action |
| --- | --- |
| `no herdr window (...)` / retained pane | The round ran without its window (`window.json` in the attempt says why); report it, do not write `run-*.sh` |
| `already has a live worker` / uncertain launch | Follow [clear-zombie-workers](../clear-zombie-workers/SKILL.md); resume the live actor if real |
| Adapter/vendor failure from stock script | Use configured fallback via the same stock script; do not open a manual agent pane |
| Task branch conflicts with its base (gate 2 red, base moved) | Relaunch the worker recipe above with `--pr <N>`; the script rebuilds the branch on the base and hands the conflicts to the worker. Never rebase, merge or push the branch by hand |
| Worker exits `75` after a rebuild | The rebuilt round was refused before its commit (the run names why) and nothing was pushed; relaunch with `--pr <N>` (the next round copies the worktree to `state/rescued/` and rebuilds from the branch) |

## Do

- Reuse a live actor for the same task when evidence shows it is working.
- Keep caller focus; let managed transport use `--no-focus` tab create.
- Record the canonical actor from script output / `identity.json`.

## Do not

- Create `state/runtime/run-*.sh` or monitor wrappers to host the worker.
- Run `cursor-agent` / `claude` / `codex` directly in a pane for crew work.
- Claim dispatch succeeded without the completion checks above.
