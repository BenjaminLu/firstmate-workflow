# T-167 validation handoff

The reported T-164/T-162 failure class is outage wording inside model/tool
payloads being read as CLI/provider failure. Managed Codex now classifies only
this invocation's typed error events and plain CLI diagnostics, preserves
launch and nonzero-exit handling, and requires a completed-turn final for
adapter success. Completion remains the transport's role/task-specific decision.
The existing T-163 final reader, reviewer binding and sandbox are unchanged.

## Fail-first evidence to collect in CI

Tests were written before implementation. Workers are forbidden to run suites
or models, so no red/green execution is claimed here.

`tests/codex-availability.test.sh:92` (`test_completed_worker_quotes_are_not_outages`)
feeds the adapter a completed worker JSONL stream containing six quoted
`eNotFound` occurrences, then the quoted login phrases from the second incident.
The return-code assertion at `tests/codex-availability.test.sh:87` expects adapter
0, and the following checks require CLI receipt 0 and final-only worker
completion. Reverting implementation should make that assertion fail with
adapter 2. The suite also covers actual provider errors, launch refusal,
nonzero CLI outcomes, absent/truncated finals, stale log/final-file evidence,
role/task marker mismatch, and legacy classification.

The existing adapter contract fixture had one shared generator printing only
`ran` for every vendor. It now emits completed-turn JSONL for Codex so its
managed environment checks continue to exercise a valid successful invocation.
Other vendors' fixture output is unchanged.

## Executed checks

- `bash -n` on both changed adapter scripts and both changed test scripts: passed.
- Python AST parsing of embedded Python in the new suite and adapter library: passed.
- `git diff --check`: passed.

No suite, CI, gate, model, commit, push or PR operation was executed by the worker.
A process-list inspection was denied by the sandbox; it was not retried or
worked around. This round does not claim live-process verification.

## Firstmate evidence still required

Run current-head CI and all six gates, including head/base fail-first evidence.
Run one real stock Codex worker from the immutable candidate snapshot with
quoted fixture/error text. Record actor, role, task, attempt, candidate head,
actual CLI exit 0, adapter exit 0, completed-turn final provenance and terminal
`WORKER_COMPLETE`, plus verified Herdr ownership, completion and close/retention
outcome. Mock tests cannot establish real CLI compatibility or Herdr ownership.
Independent review and captain approval remain required.
