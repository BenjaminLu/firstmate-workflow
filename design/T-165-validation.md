# T-165 validation and limits

The stock review launcher now composes five source files and passes them through
`bin/lib/fm_review_context.py` before any model attempt. Its final prompt limit is
524,288 UTF-8 bytes (512 KiB), half the observed vendor rejection threshold of
1,048,576 characters. Byte counting also bounds Unicode character counts. The
remaining half is conservative headroom for vendor/adapter framing, not a promise
about token limits or future vendor limits. Vendor/model selection is unchanged.
Prompts already within this limit remain byte-for-byte unchanged.

When necessary, the assembler removes only exact duplicate closed-list comment
bodies between their first and last occurrences. It retains every distinct body
verbatim, including the entire original first complete list, all changed item
dispositions, continuation text, new regression context, and verdict markers.
Repeated stale lists remain identifiable by their original chronological ordinals;
they cannot silently replace the original criteria. This intentionally does not
attempt semantic summarization. If distinct history or instructions cannot fit,
the round fails with exit 65 before invoking a model. No rejection is rewritten.
Only the previously selected closed-list/ask comments enter this assembly; worker
reasoning is still excluded. Firstmate evidence is not reclassified as reasoning.

Oversized fenced CI logs, gate summaries, and fail-first reports retain their
first and last 8 KiB with explicit excerpt/omission disclosure. Job results, URLs,
and unavailable-evidence prose remain intact. Full sources have paths, byte counts,
and SHA-256 provenance. In run mode the selected evidence is copied into a unique
`.fm-review-context-*` directory in the existing permitted checkout, without any
sandbox policy change. A checkout rebuild restores those same paths. These files
live for the review round, not as permanent CI artifacts. The launcher retains its
source components until its existing cleanup; they are not new durable evidence.

If needed, run mode replaces the entire inline diff with the exact pinned head,
merge base, patch ID, changed-path JSON index, and an explicit local `git diff`
command. Hunk ranges come from that actual diff. The reviewer must inspect every
changed path and disclose missing coverage. The checkout must match the pins,
including after a rebuild. Diff mode never substitutes such references for a patch:
if the complete patch plus retained context does not fit, it fails before launch.
Unique acceptance text and path indexes are never shortened just to obtain success.

## Regression evidence to obtain in CI

The tests were written before implementation. Per the dispatched worker rule,
no test suite or `ci.sh` was executed in this round. Shell syntax, Python syntax,
and `git diff --check` were checked; these do not establish behavioral acceptance.
A direct ShellCheck invocation exited 1 with informational SC1091, SC2329,
SC2016, and SC2012 findings on pre-existing lines; it reported no warning or
error severity findings.
CI and gate 5 must still show the tests passing on the head and red on restoration
of the implementation. In particular:

- `tests/review-context.test.sh`: `test_t130_oversize_repeats_stale_lists_and_ci`
  constructs the observed 2,719,034-character input size with a large diff,
  repeated/stale lists, distinct dispositions, regression continuation text, and
  CI logs. It requires the byte cap, original list, later list, exact pins,
  rejection marker, and visible trimming. This is a synthetic reproduction of
  the reported size and source classes, not a captured production T-130 request.
- `test_distinct_criteria_are_never_trimmed_to_fit` requires a truthful failure
  and no launchable prompt for an unrepresentable original list.
- `test_unicode_byte_cap_and_no_ci_fence_corruption` checks Unicode byte sizing,
  intact quote fences, and provenance; `test_small_is_byte_identical` guards the
  unchanged small-prompt contract.
- `tests/review.test.sh`: assertions `oversized stock diff context fails before
  vendor launch` and `an unrepresentable context spends no model call` exercise
  the real launcher with an adapter that would otherwise approve. The succeeding
  run-mode case requires the actual composed prompt to fit and carry exact pins.

No real vendor acceptance, GitHub CI result, gate result, commit, push, or PR action
is claimed. No candidate T-163 launcher was used in this worker round. If firstmate
uses that candidate for real T-130 acceptance, record its exact bootstrap revision
and the reviewed head alongside the resulting evidence; that remains outstanding.
T-135's broader worker evidence-pack feature is not implemented by this change.
