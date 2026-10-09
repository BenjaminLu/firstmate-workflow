# Self integration queue pilot

This proposal is nonnormative background. The approved T-260 task pin contains
the requirements. Capability ships off; implementation approval is not rollout
approval. Phase two, batching, promotion and GitHub queue settings are excluded.

Firstmate proposes two or three independent self PRs and records a baseline of
persisted automatic update identities and exact-head gate invalidations. Publish
a reviewable stock purpose-decision card naming repository, base, exact cohort
and canonical policy digest. A has hold effect: approval authorizes only that
policy, never dispatch or merge. The notes array contains exactly one object
`{"kind":"note","text":"Queue policy SHA-256: <D>"}`. D hashes compact UTF-8
sorted-key JSON containing version, strategy, enabled, repository, base, sorted
numeric cohort, depth and batch. After the captain's actual A and successful
event, stage `state/autopilot/queue-policy.json` with the decision id and use
normal resident-service reload. Never launch a second coordinator.

```json
{"version":1,"strategy":"self-front","enabled":true,"repository":"owner/self","base":"main","cohort":[101,102],"captain_authorization":"D-firstmate-workflow-T260-2","depth":1,"batch":1}
```

The front retains reservation through CI, stock review and captain wait. Failure
does not silently retry an unchanged head. A resume requires another genuine
purpose-decision captain A/hold record and event with one note or caution:
`Queue resume: PR N head H failed fingerprint F`. Parking a task alone leaves
its pending merge authority intact. Cancellation requires a separate successful
captain B/C hold answer to that merge card, no pending record and no possibly
running merge helper. Unknown outcomes hold; disable drains recognized owned
work before legacy scheduling resumes. External policy remains independent.

Read-only operator status:

```sh
python3 <FM_CODE_ROOT>/bin/lib/fm_autopilot_queue.py status --state <absolute-engine-state> --format json
python3 <FM_CODE_ROOT>/bin/lib/fm_autopilot_queue.py status --state <absolute-engine-state> --format text
```

JSON fields: version, repository, base, enabled, generation, front, members,
counters and ci_runner_minutes. The front contains PR/task/state/H/B/generation/
reason; ordered members add sequence. Text resembles
`#101 T-101: waiting-ci (required-checks-pending); H=<40hex> B=<40hex> generation=1`.
Exit codes: 0 valid/off, 3 not initialized, 64 bad argv, 65 invalid/nonself/newer/
symlinked state. No paths, operator identities, logs or authorization prose are
printed. There are no locks, writes, network reads or process probes.

Counter definitions: automatic_updates_requested counts persisted request
identities once; completed_landings counts authoritative remote merge plus
canonical merged-event reconciliation once; invalidated_gate_jobs counts one
completed owned job whose bound H/B differs before readiness use;
captain_wait_seconds and front_seconds account wall-clock transition intervals
once with nonnegative clamping; duplicate_effects_observed counts confirmed
duplicate identities only. CI runner-minute data is unavailable. Do not label
predicted savings as measured results. Compare pilot counters against its
recorded baseline before proposing any broader rollout.
