# External roadmap adoption ledger

T-166 consolidates captain-approved direction from 2026-10-01. It changes no runtime or tests. The supplied T-166 spec is preserved unchanged. Existing PR 130/131/132 repairs and the task prerequisites must finish before external implementation. Planning references in that spec are historical drafts; the rewritten task files and design section 15 define the adopted contracts.

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
| T-138 | T-142 | Local authentic evidence and authoritative-head binding |
| T-135 | None | Bounded evidence packs and situation coverage |
| T-050 | T-049, T-138, T-139 | Six project-aware gates, checks and commit statuses |
| T-051 | T-049, T-142, T-163, T-167 | Stock live dispatch/lifeline integration, isolated execution, head synchronization |
| T-052 | T-051, T-139, T-135 | Portable bounded prompts, authoritative checkout/evidence context |
| T-053 | T-050, T-051, T-052 | Fair live-owned concurrency, exact identity and merge turns |
| T-055 | T-052, T-053, T-054, T-137, T-144 | Actual maker-founder basic pilot and retained real outputs |
| T-140 | T-138, T-139 | Advanced external reviewers and posting conventions |
| T-143 | T-051, T-139 | Advanced stacks and project-specific landing/retention |
| T-141 | T-138, T-140, T-143, T-144, T-151 | Advanced zero-model pushed supervision |

T-142 → T-166 and T-051 → T-167 are the deliberate additions to the approved draft dependency map, required by T-166 acceptance. T-138 and T-135 can proceed independently of conventions where their dependencies permit; shared worker/reviewer/library files require coordinated ownership and immutable execution snapshots. No dependency on the advanced stack is added to T-055. Existing T-054/T-137/T-144 remain pilot prerequisites.

## Rule reconciliation

| Old draft rule | Adopted contract |
|---|---|
| External designs/state inside engine | All private records under FM_HOME/projects/<name>; self paths unchanged |
| Private repos refused; unreadable protection treated as absent | Private accepted; unknown requires confirmed checks/policy |
| Seven gates / local gate 3 | Six gates 1,2,4,5,6,7; 3 retired |
| External spec must be committed on engine main | Approved local immutable snapshots with hashes and approval provenance |
| Reviewer transcript marker proves approval | Authenticated final assistant output, reviewer identity, verified head/patch; preserve closed list |
| Local task ref is current | Verify authoritative GitHub head, local ref and isolated checkout before evidence/card/merge |
| Only check-runs establish CI | Required check-runs plus commit statuses; pending differs from failure |
| Fixed squash/delete or unconditional task force push | Confirmed project merge/retention/stack policy; expected-head task leases only; no protected-base force push |
| Count historical PRs or dispatches | Count live owned runs under dispatch and identity locks |
| setsid/beacon/polling supervision | Lifelines and writer-pushed local wakes; only GitHub conditional polling |
| Worker checkpoint in target | Outside-round frozen launcher publishes; workers never commit/push/checkpoint |
| Mock-only external pilot | Real maker-founder bootstrap, approved task, live stock Codex Herdr run, isolated review, current evidence and cleanup |
| Full autopilot needed for basic pilot | T-140/T-143/T-141 remain advanced roadmap; core T-051 dispatch works first |
| Hard 240-second optimization gate | T-130 measurable optimization with reported estimates/actuals, no hard shard duration target |

T-163 supported Codex run mode retains confinement, isolated checkout, transport provenance and cleanup. T-167 retains real launch/provider failures while rejecting quoted-error false positives. T-164 loading, native exact trust and actual delivery are separate facts; no trust bypass or queue-only delivery claim. Neither this ledger nor a metadata check proves live behavior or model compliance.

## Verification boundary

This documentation-only consolidation adds no production scripts or tests. Workers do not run suites or ci.sh. Firstmate must obtain actual required CI and six-gate evidence on the authoritative head; declared docs classification is decided by the gate, not waived here. There is no new behavioral assertion to identify as fail-first for this prose-only diff. Runtime tasks retain feature-owned fail-first and real acceptance requirements.

Review the task JSON dependency graph for missing nodes/cycles; compare the approved dependency map with the two explicit additions above. Verify each task owns its spec and required runtime integration paths. Search rewritten contracts for stale storage, gate-3, public-only, checkpoint, detached/beacon and local-head assumptions. Check that T-166 remains byte-for-byte supplied, T-030 stays parked, and retired tasks are not reintroduced as runnable specs. Structural checks establish these properties only, not delivery, runtime compliance or gate success.
