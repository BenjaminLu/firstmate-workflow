# Source scope (nonnormative)

T-260 modifies the self scheduler, branch updater and delayed mechanical loop,
with a data-only queue validator/status helper. Existing stock approval, pin,
gate, binding, decision, merge, service-lock and lifeline primitives retain
authority. No board, event-enum, root configuration or external policy changes.

Regression inventory: autopilot cases, loop, jobs, entrypoints, reload,
merge-path and external adoption/stacking/restack/reviews/PR-format fixtures.
Root-import fixtures need no copy-list change. The entrypoint fixture uses
selected shell/storage modules and a replacement engine; lazy queue imports
preserve it. Branch fixture is a probe, project-storage copies only storage,
and reload copies all bin modules. Retained and refreshed reload snapshots
must import the helper from their own pinned code root.

The queue suite uses disposable state and mocked GitHub. Its ordinary
production assertion counts one PUT across three behind PRs and identifies the
numeric front. Its all-PR admission mutation retains the complete harness/API
and demonstrates the wrong three-update count rather than an import failure.
No current-head CI or gate success is established by authoring these tests.
