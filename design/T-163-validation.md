# T-163 validation handoff

The worker authors regression tests but does not execute suites. Syntax parsing
and whitespace checks are not runtime or sandbox evidence.

Firstmate owns the following acceptance evidence on the candidate head:

- Required repository CI and all applicable gates, including the fail-first
  comparison for `tests/codex-review.test.sh`.
- Independent bootstrap review. Codex support cannot authorize its own approval;
  Claude being quota-blocked is not permission for a silent vendor fallback.
- A verified immutable execution snapshot containing this candidate's adapter,
  transport, launcher and sandbox files. Record its relation to the candidate
  commit before starting a canary or review.
- The real macOS sandbox canary: authenticated and started receipts; denial of
  engine, worktree, state and original credential writes/forbidden reads;
  GitHub, board and unrelated loopback denial; read-only review git metadata.
- A small stock `fm-review.sh --vendor codex --pr ...` run, recording the actual
  isolated checkout and pinned head/base/patch, configured model, canonical
  reviewer identity, completed CLI answer and its transport digest/binding.
- Successful and failed launch cleanup, and retention while an execution owner
  remains live. Record the bounded retry outcome if one occurs.

None of those acceptance runs was performed or claimed by this worker.

## Supplied firstmate evidence and limits (round 3)

Firstmate reported a worker-role macOS vendor canary from immutable snapshot
`code-slcopsjz`, run `canary-20261001T152834Z-16712`, at
2026-10-01T15:28:59Z: Codex CLI 0.159.3, exit 0, started and authenticated.
Write-outside, GitHub, foreign loopback, Herdr socket, other-round temp,
gh-token, git-credential, keychain and pasteboard probes were blocked; own
loopback worked. SSH was blocked-or-absent, not proof of denial for a present
secret. Requested model was empty and actual model unknown. This was a worker
canary, not an isolated reviewer canary.

Firstmate also reported the stock isolated review by
`reviewer-nikhil-t163-r1`, whose supplied final answer rejects head
`71f0247851e9a5cd8c0981cd915c2e56f18e66e4`, base
`0ca49e39914eb664118fab3c825a3185989a695f`, patch
`c62dfce58e521c655ca290c199f5adb7d15c002a`. The supplied answer establishes
that reviewer's rejection; it does not approve the bootstrap dependency.
Raw checkout, configured-model, digest, confinement and cleanup receipts are
not supplied here. The worker has not independently executed these validations.

Standing criterion 5 remains **open**. After this remediation, firstmate must
refresh the complete evidence above against a newly verified immutable candidate.
The composed tests stub external services and cannot close this criterion.
