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
