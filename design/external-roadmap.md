# External roadmap adoption ledger

T-166 consolidates captain-approved direction from 2026-10-01. It changes no runtime or production scripts. It adds `tests/skills-contract.test.sh` to check role-skill rules' structure and text, not model compliance; its assertions provide this change's fail-first evidence for the role-skill changes, which `config.yaml` classes as behaviour. The task spec includes the authorized scope addition for that suite. Existing PR 130/131/132 repairs and the task prerequisites must finish before external implementation. Planning references in that spec are historical drafts; the rewritten task files and design section 15 define the adopted contracts.

## Replacements and deferrals

Retirement is a planning decision, not a claim that the old feature shipped. These six task files are already absent in this checkout; do not recreate dispatchable work for them. Firstmate must reconcile board records with these retirements without treating retirement as a merged dependency.

| Retired task | Replacement / deferred remainder |
|---|---|
| T-072 | T-142; T-049 |
| T-094 | T-162; T-053 |
| T-095 | T-162 |
| T-097 | T-162; deferred board systems card |
| T-075 | T-142; deferred plugin distribution |
| T-076 | T-142; deferred read-only installation layout |

**T-030 stays parked and unsolved.** This change neither un-parks it nor resolves its lint acceptance. Its old spec remains a record, not new dispatch authority.

Deferred, not dropped or completed: T-087, T-124, T-129, T-131, T-132, T-133, T-136 full prose cleanup, T-149, T-150, T-077, T-079, T-080, T-081, T-082, T-083, T-100. Detached full cmux lifecycle remains explicitly deferred with T-162; retain cmuxOnly and visible Herdr dispatch. T-075 plugin distribution and T-076 read-only installation layout are not implied by T-142 storage.

## Adopted task order

| Task | Depends on | Ownership |
|---|---|---|
| T-142 | T-166 | Storage, validated paths, approved migration; depends on consolidation |
| T-139 | T-142 | Inspection, private conventions, empty-repo contract |
| T-049 | T-142, T-139 | Immutable approved private pins and hashes |
| T-138 | T-142, T-135 | External evidence extension, signing and authoritative-head/patch binding |
| T-135 | None | Local brief/review loop, bounded packs and situation coverage; first wave |
| T-050 | T-049, T-138, T-139 | Six project-aware gates, checks and commit statuses |
| T-051 | T-049, T-142, T-163, T-167 | Stock live dispatch/lifeline integration, isolated execution, head synchronization |
| T-052 | T-051, T-139, T-135 | Portable bounded prompts, authoritative checkout/evidence context |
| T-053 | T-050, T-051, T-052 | Fair live-owned concurrency, exact identity and merge turns |
| T-055 | T-052, T-053, T-054, T-137, T-144 | Basic external flow has run end to end on a private repository |
| T-140 | T-138, T-139, T-135 | Advanced external reviewers and posting conventions |
| T-143 | T-051, T-139 | Advanced stacks and project-specific landing/retention |
| T-141 | T-138, T-140, T-143, T-144, T-151 | Advanced zero-model pushed supervision |

T-142 → T-166 and T-051 → T-167 are the deliberate additions to the approved draft dependency map, required by T-166 acceptance. The 2026-10-02 captain revision additionally makes T-138 and T-140 depend on T-135. T-135 proceeds without conventions or external prerequisites; shared worker/reviewer/library files require coordinated ownership and immutable execution snapshots. No dependency on the advanced stack is added to T-055. Existing T-054/T-137/T-144 remain pilot prerequisites. Their operative contracts now use T-151 owned lifelines and pushed completion, T-162 visible Herdr/cmuxOnly routing, and T-164 truthful hook trust/delivery. Optional headless hosts and full detached cmux lifecycle remain deferred; no beacon/PID-polling or advanced-autopilot prerequisite returns.

## Rule reconciliation

| Old draft rule | Adopted contract |
|---|---|
| External designs/state inside engine | All private records under FM_HOME/projects/<name>; self paths unchanged |
| Private repos refused; unreadable protection treated as absent | Private accepted; unknown requires confirmed checks/policy |
| Old gate count including a separate local check | Six gates 1,2,4,5,6,7; 3 retired |
| External spec must be committed on engine main | Approved local immutable snapshots with hashes and approval provenance |
| Reviewer transcript marker proves approval | Authenticated final assistant output, reviewer identity, verified head/patch; preserve closed list |
| Local task ref is current | Verify authoritative GitHub head, local ref and isolated checkout before evidence/card/merge |
| Only check-runs establish CI | Required check-runs plus commit statuses; pending differs from failure |
| Fixed squash/delete or unconditional task force push | Confirmed project merge/retention/stack policy; expected-head task leases only; no protected-base force push |
| Count historical PRs or dispatches | Count live owned runs under dispatch and identity locks |
| setsid/beacon/polling supervision | Lifelines and writer-pushed local wakes; only GitHub conditional polling |
| Worker checkpoint in target | Outside-round frozen launcher publishes; workers never commit/push/checkpoint |
| Mock-only external pilot | Basic external flow has run: onboarding, captain-card dispatch, isolated rounds and review, authoritative-head gates and captain-card landing |
| Full autopilot needed for basic pilot | T-140/T-143/T-141 remain advanced roadmap; core T-051 dispatch works first |
| Hard 240-second optimization gate | T-130 measurable optimization with reported estimates/actuals, no hard shard duration target |

T-163 supported Codex run mode retains confinement, isolated checkout, transport provenance and cleanup. T-167 retains real launch/provider failures while rejecting quoted-error false positives. T-164 loading, native exact trust and actual delivery are separate facts; no trust bypass or queue-only delivery claim. Neither this ledger nor a metadata check proves live behavior or model compliance.

## Verification boundary

This consolidation changes no runtime or production scripts. It adds `tests/skills-contract.test.sh`, whose nine assertions check the structure and text of the role-skill rules: managed Codex admission and verdict provenance, approved local briefs with optional PR projection, reviewer provenance/private storage/read-only commands, and authoritative merge-head binding with restricted approval carry-forward. These assertions are this change's fail-first evidence for the role-skill changes because `config.yaml` classes skills as behaviour. They do not prove model compliance or runtime capabilities. Workers do not run suites or ci.sh. Firstmate must obtain actual required CI and six-gate evidence on the authoritative head, including the suite's head-pass/base-fail results for gate 5; CI's separate behaviour classification does not waive that gate. Runtime tasks retain feature-owned fail-first and real acceptance requirements.

Review the task JSON dependency graph for missing nodes/cycles; compare the approved dependency map with the two original additions and the two captain-authorized T-135 dependencies above. Verify each task owns its spec and required runtime integration paths. Search rewritten contracts for stale storage, gate-3, public-only, checkpoint, detached/beacon and local-head assumptions. Check that T-166 preserves the supplied spec apart from the authorized `tests/skills-contract.test.sh` scope addition, T-030 stays parked, and retired tasks are not reintroduced as runnable specs. Structural checks establish these properties only, not delivery, runtime compliance or gate success.

## Round-two contract reconciliation

Captain revision, 2026-10-02: “好 T135安排 解耦外部repo convention”, clarified by “不是這個意思 135做完後 review和brief機制要能不依賴外部repo允許我們張貼每一輪工作日誌”. The brief and review loop must work without permission to post round work logs. “現在是第一輪reviewer就要給過關條件” confirms complete pass criteria on every REJECT from round one.

T-135 runs in the first wave beside T-142 with no dependencies. It owns append-only state/evidence/<project>/<task>/ records for brief, pack, worker-report, ask and verdict, carrying project/task/round/actor/kind/head/time and authenticated final-answer provenance for verdicts. The worker reads local briefs and packs; reviewers receive prior rounds and standing lists from round two; gate 7 and fm-protocol.sh read local verdicts with latest-REJECT precedence. Ask only for a missing or unclear list before edits. The project comments/local switch defaults to comments for self compatibility; local mode posts nothing and completes the entire loop. T-138 depends on T-142 and T-135, extends the same records to private FM_HOME storage, adds signing/spec/patch binding and retains atomic merge-head enforcement. T-140 also gains T-135 and adds summary/check/threads projections. No external conventions or advanced stack are prerequisites for T-135. These are adopted implementation requirements, not claims that the readers already ship.

Captain-intent alignment preserves the existing T-034 interaction: selection
and custom typing stay local; a separate confirmation submits exactly the
selected choice. A custom order preserves literal bounded text for judgment,
never shell execution or implicit merge approval. T-059 readiness judgment and
its explicit direct-order exception remain: a direct order bypasses judgment
only, not dependencies, park/drop, greenlight or capacity. T-139 land/review/post
policy and T-141's no-auto-merge contract govern external cards; this task
introduces no new card model or UI. Recorded order acceptance is not successful
merge evidence.
