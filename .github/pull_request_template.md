<!--
One pull request implements one task, design/tasks/T-xxx.json. Pull requests
opened by bin/fm-worker.sh carry a one-line body instead ("Dispatched by
firstmate for T-xxx. Acceptance is in design/tasks/T-xxx.json."); a worker's
notes, when it leaves any, arrive as comments. Write in English. Delete any
comment you have answered.
-->

## Task

T-xxx — implements design/design.md section N (<section title>)

## What changed

<!-- What the change does, in a few sentences. The acceptance criteria are in
the task entry; say how this meets them, not what they are. -->

## Scope

<!-- Gate 4 compares every changed path with the task's `scope` globs in
design/tasks/T-xxx.json, read from this branch. -->

- [ ] Every changed file is inside the task's `scope`. If the work needs a file
      outside it, it is named here with the reason, and the change stops until
      the captain decides.

## Evidence

<!-- Which tests are new or changed, and that each one failed before the
implementation existed. A change whose every non-test path matches
config.yaml's `docs` globs needs no new test; say so if that is the case. -->

- Fail-first:
- Required check:

## Captain decisions

<!-- Cite each decision this change relies on by id (D-xxxx = option), or write
"none". A scope change is a decision, never an agreement in a conversation. -->

## Gates

<!-- bin/fm-gate.sh checks these (design/design.md section 6). Gate 7 matches
the marker in any comment unless FM_REVIEWER_LOGIN is set, and does not tie it
to the current head; the approval that counts is the reviewer's, on this head. -->

- [ ] 1. The branch has commits on top of `main`.
- [ ] 2. It rebases onto `main` cleanly.
- [ ] 3. In a fresh worktree, `setup` succeeds and the declared
      `project.check` (`bin/ci.sh`) exits 0.
- [ ] 4. The diff stays inside the task's `scope`.
- [ ] 5. With the non-test changes reverted, at least one changed test goes
      red; or every non-test change is declared `docs`.
- [ ] 6. The required GitHub check `ci` is green.
- [ ] 7. A comment contains `APPROVE:T-xxx`, posted by the reviewer for this
      head.
