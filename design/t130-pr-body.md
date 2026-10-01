# Split tests by feature and distribute CI across six shards

Large shared suites serialized CI and made unrelated features edit the same files. This change splits worker, board, review, browser, adapter, CI, sandbox and Herdr coverage into feature-owned files, moves shared fixtures into tests/lib/ and tests/e2e/lib/, and configures six bash and fail-first shards. Suite discovery stays glob-based; helper linting and touched-suite selection remain covered. New features must add tests to their own feature file, and test files are capped at 1,200 lines.

## Standing criteria

1. **Done:** Worker feature split and shared fixtures; longest historical split estimate 83.2 seconds, below 150.
2. **Done:** Board, review and browser feature splits with shared helpers.
3. **Done:** Static audit checks 147 files; none exceeds 1,200 lines.
4. **Done:** Assertion and test-name/source preservation against rebuilt main df2cf03f4bf39a40b0fa00fcc8f02adec4fb197c. Shell counts before/after: worker 650/650, board 621/621, review 421/421, CI 199/199, adapter 305/305, sandbox 441/441. Herdr retains 455 assertions and 92 methods; browser retains 56 declarations. Explicit scaffolding exceptions do not remove assertions.
5. **Done:** Glob discovery, pattern ordering, allocation lint and shared-helper consumer selection retained.
6. **Remediation complete in proposed evidence:** Six shards and predictions paired with observations from the same identified PR run/head appear below. Comparable required-check latency falls from 450 to 307 seconds. The rebuilt static plan is refreshed separately. No hard duration limit applies. Firstmate must inspect and publish this proposed body; publication and review acceptance are not claimed.
7. **Done:** Worker skill and design require feature-owned tests and shared fixtures. Prose validation cannot establish future model compliance.

## Rebuild preservation

Earlier rebuilds preserved T-161's variable-boundary and bounded-wait assertions, T-163's managed-context checks, current-attempt verdict recovery, and Codex event-stream fixtures in their feature owners. The latest rebuild onto main `df2cf03f4bf39a40b0fa00fcc8f02adec4fb197c` restored one deleted monolith, `tests/review.test.sh`, because T-165 added bounded-context coverage there. All 11 new assertions and their fixture setup now live intact in `tests/review-diff.test.sh`; the monolith is removed. The existing shared review fixture supplies the copied runtime libraries and isolated temporary directory. Main's `tests/review-context.test.sh` and updated `tests/codex-review-integration.test.sh` match accepted main byte-for-byte. No assertion, budget, sandbox or skip policy is relaxed. The frozen task spec is unchanged.

SWEPT:T-130 accepted main test changes across the feature split
  searched: all test changes between the former audit base and rebuilt main; full eight-suite source inventory against rebuilt main
  found 3 changed/new test files, including 1 conflicted monolith; migrated its 11 assertions and verified the other 2 files byte-for-byte

## Validation and limits

Latest rebuild validation: static preservation audit, static timing planner, shell syntax check of the resolved feature suite, conflict-marker scan, unchanged-main test comparisons, frozen-spec byte comparison, and document consistency checks. Read-only Git history was used for conflict resolution and these comparisons. No suites, ci.sh, models, browser sessions, GitHub operations, commits, pushes or PR operations were run.

Existing fail-first assertion tests/ci-feature-suites.test.sh:15 requires a 90-second inherited estimate from a 120-second parent at a 0.75 share; reverting the estimator should make it red. Line 35 covers the PATH helper lint correction. The rebuild relocated main's existing assertions; this remediation transfers T-165’s existing coverage and refreshes evidence without changing production behavior. Gate 5 is not waived. Firstmate supplied prior differential gate evidence, but nonzero local head/base exits do not prove local success. Earlier CI success is bound to the identified pre-rebuild head. Current-head verification and signed independent review remain required before acceptance.

## Performance evidence

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

## Separate rebuilt static plan

`python3 tests/lib/split_timings.py` now predicts shard loads of 282.5, 281.5, 281.6, 281.7, 282.6 and 281.9 seconds, totaling 1691.8 seconds before display rounding, with mean 282.0 and longest suite 83.2 seconds. All shards are within mean + longest (365.1 seconds). The complete refreshed suite assignment is in [design/t130-timings.md](design/t130-timings.md). These estimates use the current rebuilt suite files, historical main timing artifact and unchanged migration shares; they are separate from the identified PR run's logged predictions above. Independent rounding explains why displayed shard values need not sum to the displayed total.

SWEPT:T-130 incomplete performance-evidence provenance and stale static estimates
  searched: task-specific reports for old shard totals, prediction-log availability and reproducibility claims
  found 2 affected documents, corrected both; regenerated the full static assignment table
