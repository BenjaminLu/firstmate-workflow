# T-162 host integration handoff

The 2026-10-01 dispatch supplies installed cmux 0.62.2 (77) evidence:
`capabilities` reports `cmuxOnly`; foreground ping returns PONG; ping after
`fm-lifeline.sh --session` and the invoking shell's exit reports
`Error: Failed to write to socket`. Both worker window logs show the same
error from the supported `new-workspace --cwd ... --command ...` invocation.
The kernel lifetime owner does not establish socket authorization.

The nested conversation was verified in Herdr w4S:p1, tab w4S:t1, workspace
w4S. Inherited CMUX_WORKSPACE_ID resolved to an unrelated workspace:9;
focused workspace:1 was not caller evidence either. Use the explicitly
verified Herdr context with FM_HOST=herdr for this deployment. The original
launchers ran immutable snapshots code-axfr4lrn and code-wjllzuna. Worktree
edits do not repair already executing snapshots.

## Independent corrections

Inherited cmux IDs no longer select a host. Explicit FM_HOST overrides
config; FM_TRANSPORT=direct still disables windows. Explicit cmux selection
requires FM_CMUX_CALLER_WORKSPACE, an operator-verified workspace UUID or
reference. Its membership is checked through structured workspace listing;
this verifies existence, not that the conversation belongs to it. Firstmate
must establish that relationship before setting it. host.json explains the
selection and window.json retains the caller and observed access mode.

The command runs its capabilities probe at the actual point of use. Failures
include host stderr and remediation, with the configured environment password
redacted. Workspace creation retains the returned reference, rejects existing
identities, verifies the label, and restores focus only if this creation took
it. Partial creations have status none and are retained for inspection.
Cleanup compares the receipt, workspace identity, label and full tree before
closing. Observation failure or any difference retains the workspace. This
is conservative and can retain a window after harmless tree changes.

## Current deployment and validation (captain direction, 2026-10-01)

Retain cmuxOnly. Firstmate runs in Herdr and must dispatch worker log windows
there, with explicit FM_HOST=herdr and the verified HERDR_PANE_ID,
HERDR_TAB_ID and HERDR_WORKSPACE_ID. Missing inherited HERDR_* variables
must be resolved from independently verified conversation context, not guessed
from focus or stale outer cmux IDs. Password mode is not a prerequisite.

The stock Herdr path verifies caller membership, opens a dedicated labelled
tab with --no-focus, records owned pane/tab and caller identity, and checks
focus and ownership. Existing completion cleanup retains uncertain, adopted,
shared or changed resources. Worker computation is supervised independently
of its log window; failures must remain visible in window.json and diagnostics.

Firstmate must validate this repair through a fresh immutable snapshot and the
stock session-owned Herdr worker launch. Retain evidence of:

- Independently verified conversation pane/tab/workspace and effective host.json.
- Actual visible worker tab, canonical label and live run.log content.
- Captain focus before and after creation; actual owned pane/tab receipts.
- Positive completion closing only the unchanged owned pane, and changed or
  failed-window resources retained without misreporting worker computation.
- Kernel owner identity and bounded process shutdown without crew policy changes.

CI/gates and independent current-change review are still required. Workers do
not run suites. No real-host validation was performed in this round; firstmate
owns this evidence. Historical snapshots code-axfr4lrn and code-wjllzuna are
not repaired by source edits.

## Optional authenticated external automation

Firstmate supplied official installed-version source evidence on 2026-10-01:
[TerminalController.swift](https://github.com/manaflow-ai/cmux/blob/v0.62.2/Sources/TerminalController.swift)
(handleClient lines 1391–1445; authResponseIfNeeded lines 1162–1176) applies
ancestry rejection to cmuxOnly and password authentication to password mode.
[SocketControlSettings.swift](https://github.com/manaflow-ai/cmux/blob/v0.62.2/Sources/SocketControlSettings.swift)
(lines 49–60) assigns password mode 0600 permissions and requiresPasswordAuth.
Password mode is a separate operator configuration, not an override of cmuxOnly.
This capability is optional and not proposed for the current nested deployment.

Explicit cmux creation probes capabilities at the actual point of use and
accepts authorized cmuxOnly or password responses. It rejects off, allowAll and
unknown modes. Missing/wrong authentication preserves the host error without
creation. Supported saved CLI authentication need not use an environment secret.
fm does not change settings, retrieve credentials, inject controls into captain
panes or widen crew policy. Any future password deployment requires separately
approved operator configuration and authenticated supervised preflight. Never
put credentials in command arguments, receipts or evidence.

## T-162-CMUX-FOLLOWUP — deferred acceptance, not completed

Captain deferred the full cmux lifecycle on 2026-10-01 in favor of the actual
Herdr deployment. This record preserves the original acceptance for a separately
authorized follow-up; it does not create or dispatch another task.

1. Establish a supported host-side control lifetime preserving authentic cmuxOnly
   ancestry across invoking-shell exit, kernel-bound to the fm session, with no
   orphan controller, control injection, access-mode weakening or crew bypass.
2. Verify installed structured-response schemas and exclusive foreground-process
   and resource ownership. Current identity/label/tree comparison is observational,
   not an atomic ownership lease; it cannot establish unchanged foreground jobs.
3. Implement safe unchanged-resource closure on completion and owner termination,
   including interruption during creation, bounded shutdown and hard-kill recovery.
   Current TERM/INT handling records retention without cleanup RPCs; KILL may
   preempt even that receipt. It is not successful owner-exit closure.
4. Add real process/owner-death regression coverage. Current tests model the
   foreground/supervised access transition and signals; they do not prove real
   reparenting, macOS ancestry, owner-death cleanup or window visibility.
5. Firstmate runs the full real macOS cmux smoke through a fresh immutable snapshot
   and the session-owned path after the invoking shell returns. Record version,
   access mode, verified caller and kernel owner without credentials; observe a
   temporary uniquely labelled workspace and live log, actual UUID/reference and
   preserved captain window/workspace focus. On completion and owner exit only
   unchanged diagnostic resources close, with no surviving processes. Renamed,
   adopted or expanded resources must be retained. Mocked CI is insufficient.

Authorized foreground cmuxOnly operations are not rejected merely because the
full detached lifecycle is deferred. Foreground success also does not establish
that deferred lifecycle. Keep these claims separate in future handoffs.
