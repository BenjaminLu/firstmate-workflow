<!--
Firstmate authors new self PR subjects and operational prose before dispatch.
Subjects use an allowed action verb and named object, one printable ASCII line,
1–70 characters and at most 12 words. Final titles are T-id: subject (<=85).
Small changes use connected problem/result prose, proposed approach, observed
scope, validation status, dispatch provenance and recorded door/rollback.
Complex changes use the four sections below. Size is authored.

New task specs are local files, ignored by Git and never committed; specs
committed before T-256 stay tracked. Reviewers read the pinned spec supplied
in their prompt.

The launcher binds prose to stock approved snapshots; scope comes from the
exact-head diff and gate 3 uses the approved pin, never a mutable branch spec.
The approved narrow legacy exception explicitly labels absent publication pin
and scope-gate authority; it is neither sealing nor approval.
CI, review and all six gates are pending/not collected at creation; local
validation is not recorded. Check current CI and review at this PR. Creation
prose is not readiness evidence. Do not assert executed tests without evidence.
Existing/human/adopted metadata stays unchanged. External templates remain
upstream. Question drafts publish only the bounded clarification purpose.
-->

## Problem and result

<!-- Explain the concrete problem and expected behavior. -->

## Approach and scope

<!-- Proposed approach until firstmate verifies it. Include observed exact-head
files and approved task identity, rather than copying the task's entire title. -->

## Approved intent and evidence

<!-- Summarize referenced approved purposes. Intent indices are zero-based
acceptance array indices. Include timestamp and exact head; required CI, review
and the six gates start pending/not collected; local validation not recorded.
Fail-first assertions belong in the worker report with file:line; the gates own
red/base and green/head execution. Never turn initial prose into a pass claim. -->

## Decision, migration and rollback

<!-- Cite verified retained dispatch reference, otherwise not recorded. State
recorded door reason and rollback trigger/action/owner/limits; omissions are
not recorded. Preserve existing metadata and frozen-code migration boundaries. -->
