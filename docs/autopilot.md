# Autopilot

`bin/fm-session.sh start` starts scripted supervision for registered projects.
`bin/fm.sh autopilot status --all` reports each service; `ensure --all` starts
missing services. Subsequent `fm` commands reconnect previously started services
after a crash. Each service runs from a frozen engine snapshot through the
T-151 lifeline, owned by the fm session. Owner exit stops the service and its
descendants. Kernel locks exclude duplicate services; there is no PID polling.
No launchd/systemd installation is implicit. An operator choosing such an owner
must explicitly arrange its lifetime and invoke `ensure` with that session owner.

Local event writers append first and ring the owned FIFO. The service reads
complete lines on startup and on notifications. GitHub alone is polled, using
per-endpoint ETags, convention cadence and bounded exponential network backoff.
Reviews and review comments close a separate quiet-period batch per PR/reviewer.
Idle polling does not run a model. Observed head changes can start a needed
review through the existing visible Herdr launcher; current authenticated patch
coverage suppresses unnecessary local reviews. A failed launcher queues judgment.

Mechanical actions update only mergeable, behind task branches after rechecking
the observed head and mergeability; restacking delegates to the existing policy and lease checks. Returning
reviewers receive re-check requests when publication policy permits it; local
mode retains a request for firstmate. Ready tasks receive bilingual choice cards
with proceed, rescope, park and drop effects. These are intent cards, not merge
approval. Landing remains the captain's card or the team's handoff under the
project conventions. Autopilot neither runs gates nor claims an approval, current
CI, six-gate readiness or permission to merge.

Service state and write-ahead action records live in `state/autopilot/` for the
self project, or `FM_HOME/projects/<name>/state/autopilot/` externally. Judgment
records live in the corresponding `state/wake-queue/`, then enter T-137's
`state/session/wake.jsonl` transport. CI failures, findings, failed/lost rounds,
B/C answers, convention changes and ambiguous mechanical outcomes carry reason
lines. Overdue items produce bilingual board events and desktop notifications.
An action interrupted after its write-ahead record is held for reconciliation;
it is never blindly replayed. The service's log names failures before startup.

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
crash recovery, owner exit and writer notification. Workers author these tests
without running them; CI and the gates establish red/base and green/head evidence.
