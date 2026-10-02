# T-167 validation handoff

The reported T-164/T-162 failure class is outage wording inside model/tool
payloads being read as CLI/provider failure. Managed Codex now classifies only
this invocation's typed error events and plain CLI diagnostics, preserves
launch and nonzero-exit handling, and requires a completed-turn final for
adapter success. Completion remains the transport's role/task-specific decision.
The T-163 completed-turn state machine, reviewer binding and sandbox are
preserved; its Codex record delimiter is now LF.

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

## Round 3 framing repair (worker-shira-t167-r3c)

Standing-list item 1 from reviewer-nils-t167-r2 is implemented for independent
review. Captain decision D-firstmate-workflow-T167-1 authorized exactly
`bin/fm-herdr.py` as an additional scope path; the tracked task scope now includes
that file, with all acceptance criteria preserved.

Both `fm_adapter_codex_verdict` and the Codex branch of `cli_final` split records
on LF instead of Python's broader `splitlines()`. U+0085, U+2028 and U+2029 inside
valid JSON string payloads therefore cannot become plain CLI diagnostics or
cause a completed final item to disappear. Error signatures, typed error
handling, byte-offset slicing, turn state, receipt writers and sandbox policy
are unchanged. T-130's feature-owned suites and T-162's close receipts are
untouched by this repair.

SWEPT:T-167 JSONL framing in managed Codex availability and completion
  searched: `rg -n 'splitlines|split\(|cli_final|read_text|readline' bin/fm-herdr.py bin/adapters/_lib.sh bin/adapters/codex.sh`, then read the callers
  found 2 relevant record-framing instances, fixed 2

The audit also found four unrelated JSONL reads in `review_round`,
`crew_last_events`, `wakes` and `inspect` (the report's events list).
Those consume board/wake records, not vendor transcripts, and are outside this
original defect class. Plain-text configuration, process, answer-marker and
other-vendor helpers retain their existing behavior.

The feature-owned `tests/codex-availability.test.sh:101` regression was written
before the implementation edits. It serializes with `ensure_ascii=False` and
covers all 32 escaped ASCII controls, DEL, and literal U+0085/U+2028/U+2029 in
command arguments, command output, model text and the final answer. At line 120
it requires adapter0 through the assertion at line 87 and CLI0 at line 89;
lines 121–124 require exact final text and role/task-bound completion. Lines
127–133 require that earlier quoted completion markers do not complete an
unmarked final. Restoring the old classifier should fail adapter0 for literal
Unicode separators; restoring only the old completed-turn reader should lose
the exact final or fail adapter0 for final-message cases. These are expected
fail-first outcomes, not executed results. Existing real errors, nonzero exits,
launch refusal, stale evidence and malformed/truncated-stream guards remain.

This round executed source inspection, shell syntax checks for the adapter
library, Codex adapter and feature suite, AST parsing of `bin/fm-herdr.py` and
all embedded Python blocks in the changed shell files, and task JSON parsing.
All syntax checks passed. No suites, models, git/GitHub operations, CI, gates,
commits or pushes were run. Prior approval/CI and stock evidence do not validate
this revised candidate. Firstmate must collect new independent review,
current-head CI/gates and actual immutable-candidate stock evidence. Publication
and branch saving remain launcher-owned and are not observed here.
