# Autopilot

`bin/fm-session.sh start` starts scripted supervision for registered projects.
`bin/fm.sh autopilot status --all` reports each service; `ensure --all` starts
missing services. Subsequent `fm` commands reconnect previously started services
after a crash. Each service runs from a frozen engine snapshot through the
T-151 lifeline, owned by the fm session. Owner exit stops the service and its
descendants. Kernel locks exclude duplicate services; there is no PID polling.
No launchd/systemd installation is implicit. An operator choosing such an owner
must explicitly arrange its lifetime and invoke `ensure` with that session owner.
Crew rounds never start supervision. Test sessions carrying
`FIRSTMATE_CI_SESSION` skip startup and automatic resume unless a feature test
explicitly sets `FM_AUTOPILOT_TEST_ENABLE=1`. Resume without an owner receipt
does not start a service or acquire service locks.
The service records its `bin/` and `skills/` tree identities. Once firstmate
fast-forwards the engine checkout after a merge, the next `ensure` requests a
reload when those committed trees differ. It drains running or consuming jobs,
batches and unpushed wakes, then its old code hands off to a
fresh snapshot without killing the service. If the new service cannot start,
the old snapshot resumes and queues one bilingual failure wake; that failed
code identity is never retried. Dirty code keeps the running snapshot, and the
next operator `fm` command reports the reload outcome. Session startup uses the
session's frozen copy, taken from the engine checkout moments earlier. HEAD
can move between freezing and recording the identity; the next `ensure` detects
subsequent differences and reloads. If committed autopilot code cannot import,
`fm` reports autopilot unavailable and takes a fresh snapshot on each command,
while the old service keeps serving. A pre-T-203 service needs one manual
restart when no job is running or consuming; thereafter it reloads itself.

Local event writers append first and ring owned FIFOs under
`state/session/autopilot.d/`. Firstmate retains `session/wake.d/`; semantic
wake writers notify both channels, while raw events notify only autopilot. The service reads
complete lines on startup and on notifications. GitHub alone is polled, using
per-endpoint ETags, convention cadence and bounded exponential network backoff.
Reviews and review comments close a separate quiet-period batch per PR/reviewer.
Idle polling does not run a model. A base-only head change starts a review through the visible Herdr launcher
only when the latest verdict is APPROVE and gate 6 cannot carry it because it
is unsigned legacy evidence or its spec, contract or conventions hash changed.
Worker edits, standing rejections and carried approvals do not start rounds. A failed launcher queues judgment.

Mechanical branch updates use GitHub's REST compare-and-swap with the observed
head SHA, only for open, non-draft, mergeable, behind task branches. Live rounds
and busy autopilot jobs defer updates silently. An accepted update suppresses
another request for 20 polls; head races are reconsidered on the next poll.
Other failures retry at poll offsets 0, 1 and 3, then wake once.
Before advancing, the service privately fetches a changed head and fast-forwards
an ancestor local task ref when no round or job is active and its tracked
worktree is clean. Active work holds silently; an idle dirty worktree wakes once
after three held polls. Unpublished divergent work is retained for judgment.
Restacking delegates to the existing policy and lease checks. Returning
reviewers receive re-check requests when publication policy permits it; local
mode retains a request for firstmate. Ready tasks hold and queue a bilingual request for firstmate to re-read the
spec against main and author the recommendation, evidence and readiness card.
The card retains proceed, rescope, park and drop effects; it authorizes no merge. Landing remains the captain's card or the team's handoff under the
project conventions. Autopilot neither runs gates nor claims an approval, current
CI, six-gate readiness or permission to merge.

Service state, branch retry/pending records and jobs live in `state/autopilot/` for the
self project, or `FM_HOME/projects/<name>/state/autopilot/` externally. Judgment
records live in the corresponding `state/wake-queue/`, then enter T-137's
`state/session/wake.jsonl` transport. CI failures, findings, failed/lost rounds,
B/C answers, convention changes and ambiguous mechanical outcomes carry reason
lines. Overdue items produce bilingual board events and desktop notifications.
Branch update steps no longer write reconciliation records: they are re-decided
from observed GitHub state. Gate advancement is also re-decided from its observed
fingerprint without a write-ahead record, marking the PR's head and fingerprint
only after the gate job starts. Identical evidence holds across restarts;
changed evidence gates again. An authoritative head race is re-read on the next
poll without a wake or retry. Gate-step failures retry at poll offsets 0, 1 and 3,
then wake once with the error. A changed fingerprint starts a fresh retry series
with its own wake.
PR events are decided by the event log alone: an event already in
`events.jsonl` is never written again; a failed write retries at poll offsets
0, 1 and 3, then wakes once. Terminal PRs are marked finished immediately;
`event_pending` retains an unfinished event write until success or the third
failure, including after the PR leaves the recent-closures list. Reviewer
re-check requests are recorded per PR head in `rechecked` and completed when
GitHub returns 201 or lists the reviewer as already requested, or the reviewer
has reviewed that head. A 422 refusal wakes once with GitHub's message without
retry; other failures retry at offsets 0, 1 and 3, then wake once.
Review launch is decided from the review job recorded for that PR head, in any
state: at most one autopilot-launched review per head. Gate 6 can request a
review even with a same-head verdict whose binding is stale. A failed start
marks the job uncertain (or records an uncertain job if launch failed before
recording one) and wakes firstmate once; later gate results do not retry it.
Legacy jobs without kind/PR/head fields match through their packet files.
The autopilot keeps no write-ahead action ledger: per-PR records (`updates`,
`holds`, `advanced`, `rechecked`, `restacks`), shared `retries` and `jobs` remain.
The one-time `migrated_t205` upgrade removes the legacy ledger and obsolete
undelivered action wakes, restores terminal PRs' unfinished `event_pending`,
and preserves reconciliation wakes and uncertain review holds for interrupted
or uncertain launches; delivered wake files and old migration flags stay unchanged.
Restack keeps one per-PR-head record in `restacks`, with `head`, `parent`, `task`
and outcome `started`, `done`, `moved`, `conflict` or `published`. Eligible children
are reconsidered under the expected-head lease and worker exclusion.

Restack helper exits distinguish completion (0), refusal (65), rebase conflict
(66), GitHub head movement (67), a stale local ref (68), publication without
completion (69), an unknown push outcome (71), and a live worker (75).
Autopilot holds active work silently and tries 75 again next poll. It accepts
67 silently only when a fresh GitHub read confirms the head changed; otherwise
it retries. Conflicts and unfinished publication wake firstmate immediately
once. Exits 64, 65, 68 and 70 retry at poll offsets 0, 1 and 3, then wake once
with the last stderr line. Normal local synchronization can heal 68 between
attempts. Exit 71, timeout, kill or an unrecognized status retains `started`,
wakes once with “outcome unknown”, and requires reconciliation before review.
Startup also wakes once for every `started` restack, regardless of the PR's
current base. `started` and `published` holds survive head changes; they end
when the PR closes or firstmate finishes by hand, moving the child's base off
the merged parent so autopilot no longer restacks it. Other records clear on
head changes. A cleanup failure preserves the publication/unknown outcome,
or appears as `tree_cleanup` in a successful helper result.

Job recovery is unchanged. A gate, protocol or review result
for a PR that has merged, or that has a captain merge chosen A at that head
which is running or merged, is dropped without a wake; such a PR is not gated.
The service's log names failures before startup.

Native source loading, enablement, exact-definition trust, reload and model
receipt remain separate T-164 facts. A FIFO notification, queued record,
acknowledgement or running service does not prove conversational delivery or
start an idle Codex conversation. Use the existing project-aware hooks and
session status/wait tools; firstmate must verify delivery in the actual harness.

The self project uses its existing defaults: comments, captain cards, fm review,
held stacking, a 60-second GitHub cadence and 180-second reviewer debounce.
External policy comes only from the validated, captain-confirmed private
`CONVENTIONS.md`. Unknown private protection is not permission and does not
reject the repository. No private acceptance text is projected to GitHub.

`tests/autopilot.test.sh` drives recorded events and REST payloads.
`tests/autopilot-lifecycle.test.sh` covers real owned startup, singleton reuse,
crash recovery through `fm.sh`, owner exit and isolated writer notification.
`tests/autopilot-entrypoints.test.sh` covers session-start wiring, registry
fan-out, resume holds, frozen launch arguments and round exclusion. Workers author these tests
without running them; CI and the gates establish red/base and green/head evidence.

Tests that drive `pull()` directly advance `data["poll_seq"]` themselves.
