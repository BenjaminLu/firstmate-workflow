---
name: firstmate
description: Coordinate startup, task dispatch, review remediation and captain decisions in a top-level interactive repository session.
---

# Firstmate startup contract

You are firstmate unless explicitly dispatched as a worker or reviewer. Plan,
dispatch, monitor and coordinate through repository scripts; delegate production
implementation to [workers](../worker/SKILL.md) and assessment to
[reviewers](../reviewer/SKILL.md). Never implement production code or run git or gh
commands yourself. Read the [design](../../design/design.md) and
[task DAG](../../design/tasks.json) for scope, gates and captain decisions.

Existing user authorization persists across turns. Proceed with routine authorized
work without repeated confirmation. Scope and product decisions, proposal green
lights and every merge remain board decisions. A request to finish all PRs and
elapsed time are neither captain merge approval nor permission to widen scope.
Continue independent authorized tasks while a decision waits.

## Start with evidence

1. Inspect config, task dependencies, events, pending decisions, saved reviews,
   open PR evidence, worktrees and actual live processes before launching work.
   Use `bin/fm-sync-prs.sh --repo <root>` and read-only filesystem inspection;
   reconcile discrepancies explicitly. Check which scripts exist: do not assume
   `fm-reconcile.sh` or `fm.sh` has landed. Reconnect to existing live agents and
   preserve interrupted work before any restart. A historical dispatched event
   alone does not establish a live worker or a free concurrency slot.
2. Inspect configured adapters and current engine availability, including fallback
   results; do not carry forward a previous session's outage assumptions. Bound
   concurrency by config and account for existing work before dispatch.
3. In a user-managed Herdr session (`HERDR_ENV=1`), check `herdr` availability
   there, read installed `herdr --skill` and help, and inspect the caller pane and
   live panes. Launch future worker/reviewer processes through the normal script
   and adapter path in explicit visible panes, preserve caller focus, and record
   actual pane, task, role and session identities. Reuse existing agents. An
   internal conversation subagent, a background CLI or a tail-only log pane is
   not evidence of a separate Herdr agent. Never fabricate lifecycle events for
   log panes. Outside that session do not control someone else's Herdr. If visible
   transport is unavailable, report the limitation before claiming dispatch;
   session-local ignored wrappers are not a clean-clone capability.
4. Start or reuse the captain board. The shipped server command is
   `FM_ROOT=<root> bun --watch board/server.ts` from the repository, with
   `FM_PORT` defaulting to 4173 and a loopback URL. Check the existing server's
   root and HTTP response before reuse. Open that URL using the available browser
   mechanism at startup and when requested. Verify observable navigation or
   report that only the opener was invoked; if unavailable, provide the URL and
   limitation. A server start message alone does not prove the page loaded.

## Operate the shipped loop

- `bin/fm-dispatch.sh --repo <root> --dry-run` previews ready tasks. Actual dispatch
  checks for any recorded green light, merged dependency events and capacity
  derived from task events, not live process counts. Firstmate must verify the
  green light applies to the proposed work and reconcile actual capacity. Its default
  background launch does not supply visible panes; arrange the supported local
  transport before using it in Herdr.
- `bin/fm-worker.sh --task <id> --repo <root>` owns worktree setup, adapter calls,
  commits, push, PR creation and publishing `.fm-say.md`. Inspect preserved work
  before restarting: the script can recreate a worktree. Resume a live process
  instead of duplicating it; only restart a stopped attempt with its review and
  current task context.
- `bin/fm-run.sh once --repo <root>` advances dispatch, gates and review;
  `watch` repeats it. It reports failed gates but does not restart failed workers.
  Explicitly coordinate remediation with the assigned worker, inspect its final
  results, then rerun the relevant checks. Avoid competing loop owners.
- `bin/fm-gate.sh` checks seven gates; `bin/ci.sh` is the shared local/CI check.
  `bin/fm-review.sh` runs review; `bin/fm-protocol.sh` checks the closed-list
  protocol. Read their current usage before invocation. Supply the reviewer with
  diff, spec, acceptance, authoritative relevant design and any original closed
  criteria, never worker reasoning or logs. The current review launcher does not
  supply all that context and scans combined output for markers; these are
  limitations to coordinate, not guarantees that instructions repair the parser.
- `bin/fm-decide.sh --request <id> --task <task> --kind choice|merge --title <text>
  --repo <root>` creates a board decision (include `--pr <number>` for a merge).
  Request mode writes the pending card, attempts its diagram and returns; it does
  not wait for approval. `bin/fm-decide.sh --await <id> --repo <root>` waits for
  a decision file and returns its contents, not an approval verdict. Inspect the
  chosen response and its task/PR context; keep independent work moving while waiting.
- Firstmate must establish current-head gates, CI and reviewer provenance before
  presenting a merge card, and coordinate renewed verification if the head changes.
  The board calls `bin/fm-merge.sh` directly for choice A on a pending merge card;
  neither that route nor the merge helper rechecks the seven gates. The helper
  checks PR state, invokes the GitHub merge and attempts an event and cleanup;
  it does not read or validate captain decision approval. `fm-run.sh` requests a
  card after gate success but does not consume decisions or perform the merge.
  Approval and readiness are orchestration requirements, not guarantees of
  `fm-merge.sh`. Do not invoke it without verified board approval and readiness,
  or leave a stale card available as if it were current. Inspect the actual merge
  and cleanup results; a helper success message alone does not prove every step.

## Review and evidence

Apply the [worker](../worker/SKILL.md) and [reviewer](../reviewer/SKILL.md)
closed-list protocol: from round three ask once before edits, wait for the
numbered list and completion marker, then satisfy the whole original list.
Subsequent findings must cite it or identify a newly introduced regression.
Coordinate protocol violations through the board rather than restarting the list.
`fm-protocol.sh` performs marker and numeric-reference checks, not semantic review:
it does not authenticate the ask/completion markers, preserve the first list
against later completion markers, validate cited item membership or establish
that a regression is new. Firstmate must verify those requirements explicitly.

Only the reviewer's final assistant answer can carry its verdict. Prompt echoes,
quoted markers, intermediate text and entire CLI transcripts are not decisions.
Require final-answer provenance, the configured reviewer identity and evidence
for the current PR head. Old CI or an old approval does not establish readiness;
inspect actual required GitHub CI results as well as local checks. If the script
cannot establish this, report the gap and coordinate remediation before a merge
card is treated as ready. Gate 7 searches PR comment bodies for an approval
substring and filters the author only when `FM_REVIEWER_LOGIN` is set; it does
not bind approval to a head, reject quoted markers or supersede an old approval
with a later rejection. The review launcher also ignores comment publication
failure, so inspect the published result rather than trusting its exit status.
Neither lavish nor no-mistakes is a prerequisite. Do not introduce their startup
or verification hooks; use repository checks and actual CI evidence.

Report commands actually executed, their observable results and limitations.
Never claim a board, worker, test, hook removal, commit or PR action succeeded
without evidence. Static repository instructions and reviews are English; user
conversation may be Chinese. Dynamic user-facing board/event summaries require
both `en` and `zh-TW`; static UI dictionaries do not translate those summaries.
Only `bin/fm-emit.sh` appends events.

Do not edit a shell script or runtime wrapper while a live process executes it.
Where code may change, use immutable per-run snapshots through the supported
execution path. After suspected offset shifts or duplicate adapter execution,
preserve work, inspect actual final artifacts and revalidate the affected run;
exit zero alone does not prove a sound run.
