# T-130 performance evidence

The captain-approved revision of 2026-10-01 requires measurable optimization, with no hard predicted or actual shard duration limit. Six shards, coverage preservation and mean + longest packing remain required.

## Identified observations and predictions

Firstmate supplied verified GitHub run/head and job/step timestamps for baseline [run 36803506144](https://github.com/BenjaminLu/firstmate-workflow/actions/runs/36803506144), main `0dd2ddaa3a8f63941be54779618af06c215ef5d3`, and PR [run 36877214170](https://github.com/BenjaminLu/firstmate-workflow/actions/runs/36877214170), reviewed head `ba0861a6cbaaea20cd3ad435d7763f0db11b4994`. Firstmate reports all 18 checks succeeded on that PR head. The worker did not query GitHub. These observations belong to that exact head, not the subsequent rebuild onto `df2cf03f4bf39a40b0fa00fcc8f02adec4fb197c`.

| Shard | Suites | Same-run predicted summed seconds | Observed PR bash stage seconds | Observed PR job seconds |
|---|---:|---:|---:|---:|
| 1/6 | 14 | 289.3 | 140 | 156 |
| 2/6 | 15 | 289.4 | 137 | 146 |
| 3/6 | 15 | 288.5 | 98 | 113 |
| 4/6 | 15 | 288.1 | 108 | 123 |
| 5/6 | 15 | 288.6 | 115 | 125 |
| 6/6 | 15 | 288.3 | 103 | 119 |

Firstmate extracted these predictions from the actual bash-shard logs of run 36877214170, head `ba0861a6cbaaea20cd3ad435d7763f0db11b4994`, and joined them with that identical run/head's job and step timestamps. Both predictions and observations in this table belong to that run. The displayed predictions total 1732.2 seconds; the logged mean is 288.7 seconds. Summed suite load is neither stage nor job elapsed time; parallel execution and setup affect the latter. The separately reproduced static plan uses older main timings and the rebuilt suite composition, so it is not this CI run's prediction. No CI success for subsequent documentation or rebuilt heads is claimed.

## Comparable elapsed-time improvement

| Metric | Baseline four shards | PR six shards | Reduction |
|---|---:|---:|---:|
| Longest bash stage | 427 s | 140 s | 287 s (67.2%) |
| Longest bash job | 441 s | 156 s | 285 s (64.6%) |
| Workflow creation to required `ci` completion | 450 s | 307 s | 143 s (31.8%) |
| `ci` aggregator job itself | 3 s | 4 s | No reduction |

Baseline workflow creation was 2026-10-01T01:56:55Z and required-check completion was 2026-10-01T02:04:25Z. PR workflow creation was 2026-10-01T14:33:03Z and required-check completion was 2026-10-01T14:38:10Z. Required-check wall-clock here means that timestamp difference, including workflow waiting and dependencies; it is not the aggregator's own execution time or the sum of parallel jobs.

Baseline shards 1–4 had stage durations 427, 159, 242, 166 seconds and job durations 441, 171, 259, 182 seconds. Thus the comparison uses stage-to-stage and job-to-job, replacing the earlier mixed comparison with T-144's 467-second job.

These observations demonstrate measurable CI latency improvement across the identified runs. Revisions, suite composition and shard count differ, runner conditions are uncontrolled, and repeated fixture startup is not isolated. Original coverage is preserved by the static inventory audit; that audit does not prove runtime equivalence. These are not controlled same-workload speedups or evidence of reduced total CPU consumption. Current rebuilt-head CI, gates and independent review remain firstmate's responsibility; the earlier local nonzero head/base suite exits are not successful local executions.

## Reproducible static plan for the rebuilt tree

`python3 tests/lib/split_timings.py` reproduces the estimates and suite assignments below using the current rebuilt test tree, `design/t130-main-timings.txt` and the unchanged `tests/lib/suite-splits.tsv`. This refresh replaces the stale pre-rebuild table. It combines historical timing inputs with current suite files, including T-165’s context suite and updated Codex integration coverage on main; it does not reproduce the observed PR run's predictions. Displayed rows are rounded independently; totals use unrounded estimates.

Timing evidence supplied by firstmate: main `0dd2ddaa3a8f63941be54779618af06c215ef5d3`, run [36803506144](https://github.com/BenjaminLu/firstmate-workflow/actions/runs/36803506144). The dispatch supplied the artifact values and abbreviated SHA, resolved against local Git history; the worker did not fetch GitHub.

Method: allocate each old suite’s measured seconds in proportion to the new feature files’ source lines, including the Python file executed by a Herdr wrapper. Shared helper setup is amortized in those shares; repeated setup overhead is unmeasured. Shares conserve the full parent duration. Direct new-path recordings supersede these migration estimates. New suites with no parent use CI’s median seconds-per-byte fallback.

| Shard | Predicted summed seconds | Observations for this static plan |
|---|---:|---|
| 1/6 | 282.5 | Not measured; separate from identified PR run |
| 2/6 | 281.5 | Not measured; separate from identified PR run |
| 3/6 | 281.6 | Not measured; separate from identified PR run |
| 4/6 | 281.7 | Not measured; separate from identified PR run |
| 5/6 | 282.6 | Not measured; separate from identified PR run |
| 6/6 | 281.9 | Not measured; separate from identified PR run |

Total predicted: 1691.8 s; mean: 282.0 s; longest suite: 83.2 s. Every shard is within mean + longest (365.1 s).

Historical static plan only. The captain-approved revision of 2026-10-01 requires measurable optimization, with no hard predicted or actual shard duration limit. Splitting conserves parent estimates; this plan alone does not demonstrate runtime savings. See design/t130-timings.md for separately supplied CI observations and their limitations.

| New suite | Predicted seconds | Shard |
|---|---:|---:|
| tests/adapter-login.test.sh | 33.8 | 5 |
| tests/adapter-policy.test.sh | 21.8 | 5 |
| tests/adapter-protocol.test.sh | 36.5 | 3 |
| tests/adapter-shell.test.sh | 8.2 | 6 |
| tests/adapter-verdict.test.sh | 20.7 | 4 |
| tests/auth-probe.test.sh | 14.5 | 6 |
| tests/board-auth.test.sh | 5.9 | 5 |
| tests/board-card-effects.test.sh | 6.8 | 3 |
| tests/board-identity.test.sh | 5.2 | 3 |
| tests/board-pr-links.test.sh | 2.2 | 5 |
| tests/board-progress.test.sh | 3.1 | 6 |
| tests/board-projects.test.sh | 6.0 | 2 |
| tests/board-readiness.test.sh | 4.4 | 1 |
| tests/board-state.test.sh | 9.3 | 1 |
| tests/board-task-actions.test.sh | 2.4 | 4 |
| tests/board-task-grammar.test.sh | 2.1 | 5 |
| tests/board-wake.test.sh | 2.4 | 1 |
| tests/canary.test.sh | 59.2 | 5 |
| tests/ci-budget.test.sh | 18.0 | 6 |
| tests/ci-feature-suites.test.sh | 3.7 | 2 |
| tests/ci-lints.test.sh | 81.7 | 2 |
| tests/ci-pool.test.sh | 22.0 | 3 |
| tests/ci-sharding.test.sh | 30.5 | 2 |
| tests/ci-workflow.test.sh | 6.3 | 2 |
| tests/cleanup.test.sh | 0.2 | 3 |
| tests/codex-review-integration.test.sh | 13.2 | 2 |
| tests/codex-review.test.sh | 13.1 | 3 |
| tests/config.test.sh | 13.8 | 4 |
| tests/crew-end-to-end.test.sh | 12.2 | 4 |
| tests/decide.test.sh | 30.1 | 1 |
| tests/decisions.test.sh | 2.6 | 3 |
| tests/diagram.test.sh | 6.1 | 3 |
| tests/dispatch.test.sh | 16.3 | 2 |
| tests/doctor.test.sh | 8.4 | 4 |
| tests/e2e-loop.test.sh | 27.6 | 2 |
| tests/emit.test.sh | 1.9 | 1 |
| tests/failfirst.test.sh | 62.2 | 3 |
| tests/gate.test.sh | 25.9 | 6 |
| tests/guard.test.sh | 0.7 | 3 |
| tests/herdr-agentlost.test.sh | 24.4 | 5 |
| tests/herdr-credentials.test.sh | 28.2 | 6 |
| tests/herdr-emitstatus.test.sh | 25.2 | 4 |
| tests/herdr-handoff.test.sh | 29.5 | 5 |
| tests/herdr-lifecycle.test.sh | 28.8 | 4 |
| tests/herdr-roster.test.sh | 41.1 | 3 |
| tests/herdr-transport.test.sh | 28.0 | 3 |
| tests/herdr-windows.test.sh | 37.2 | 6 |
| tests/i18n.test.sh | 0.7 | 2 |
| tests/lib.test.sh | 4.1 | 5 |
| tests/lifeline.test.sh | 5.7 | 1 |
| tests/merge.test.sh | 7.9 | 5 |
| tests/open.test.sh | 2.6 | 2 |
| tests/option-loop.test.sh | 3.7 | 5 |
| tests/pipefail-grep.test.sh | 2.4 | 6 |
| tests/project.test.sh | 17.7 | 4 |
| tests/protocol.test.sh | 1.3 | 6 |
| tests/ready.test.sh | 5.6 | 4 |
| tests/reconcile.test.sh | 47.1 | 6 |
| tests/review-checkout.test.sh | 61.1 | 4 |
| tests/review-context.test.sh | 4.9 | 4 |
| tests/review-diff.test.sh | 12.9 | 5 |
| tests/review-evidence.test.sh | 27.5 | 1 |
| tests/review-retry.test.sh | 6.6 | 1 |
| tests/review-temp-safety.test.sh | 3.8 | 2 |
| tests/review-verdict.test.sh | 53.7 | 6 |
| tests/sandbox-kernel.test.sh | 3.2 | 3 |
| tests/sandbox-login.test.sh | 22.3 | 1 |
| tests/sandbox-os.test.sh | 18.1 | 2 |
| tests/sandbox-policy.test.sh | 5.2 | 6 |
| tests/selfupdate.test.sh | 18.9 | 1 |
| tests/session.test.sh | 16.8 | 5 |
| tests/settings.test.sh | 5.1 | 6 |
| tests/setup.test.sh | 3.3 | 1 |
| tests/skills.test.sh | 0.1 | 2 |
| tests/sync-prs.test.sh | 3.0 | 4 |
| tests/traps.test.sh | 1.0 | 4 |
| tests/watch.test.sh | 15.4 | 1 |
| tests/worker-auth.test.sh | 13.2 | 1 |
| tests/worker-branch-recovery.test.sh | 22.7 | 2 |
| tests/worker-checkpoint.test.sh | 12.5 | 6 |
| tests/worker-ci-evidence.test.sh | 44.3 | 5 |
| tests/worker-executable.test.sh | 14.1 | 5 |
| tests/worker-exits.test.sh | 32.5 | 4 |
| tests/worker-lifecycle.test.sh | 38.2 | 1 |
| tests/worker-liveness.test.sh | 9.2 | 2 |
| tests/worker-mirror.test.sh | 39.0 | 2 |
| tests/worker-notes.test.sh | 44.3 | 4 |
| tests/worker-policy.test.sh | 13.9 | 3 |
| tests/worker-rebuild-publication.test.sh | 23.2 | 3 |
| tests/worker-rebuild.test.sh | 83.2 | 1 |
| tests/worker-retry.test.sh | 19.5 | 6 |
| tests/worker-scratch.test.sh | 16.8 | 3 |
