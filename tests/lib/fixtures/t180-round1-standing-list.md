I'm rejecting T-180. The core of the change does what the spec asks, but it breaks an existing suite, which is why CI is red. It also replays an ASK the old code already delivered, once, when the new code is deployed.

**What holds up**
- **Task resolution:** `Pilot.task()` now tries the branch/title grammar, then the spec committed at the PR head (checking the id, and fetching through a private ref only when the head object is missing), then the latest authorized pin. The `tasks/` folder in the main checkout is no longer a precondition.
- **Unresolvable PRs:** they are recorded under `pulls` with their head, branch and reason, and only rewritten when one of those changes.
- **ASK freshness:** ASK and SCOPE-BLOCKED records must match the PR head and be newer than the saved T-172 `tracking_started`. A draft PR no longer widens the match.
- **Briefs:** a later authorized firstmate brief clears earlier asks. The record shape matches `fm_evidence.py:198-199,295`.
- **Fail-first:** the new suite `tests/autopilot-task-resolution.test.sh` is red on base and green on head. Its cases cover the three required behaviours with stubs that behave like the real `git` and `gh`.
- **Scope:** every file the diff touches is inside the declared scope.

**Findings**

1. **The change breaks an existing suite that drives a real `Pilot`.** CI shard 2 is red on `tests/run-project-turns.test.sh`, and I reproduced it on this head: 2 of 2 tests fail. `test_run_holds_only_its_project_until_merge_outcome` gets 0 merge cards where it expects 1. `test_run_captures_base_before_gating_and_refuses_moved_base` gets `'{}'` with no "regate on the new base" wake.
   - **Cause:** the fixture's PR head is `'fixture-head'`. On base, the fixture's `tasks/<task>.json` resolved the task. On head, `read_head_spec` calls `fm_binding.sha('fixture-head')`, which raises "missing or invalid full head SHA". There is no pin either, so `task()` returns `''` and `advance()` returns before any gate runs.
   - **Class:** existing suites that build a real `A.Pilot` and call `pull`/`advance`/`task` relied on the checkout task file. The diff updated `autopilot_cases.py`, `autopilot_loop.py` and `autopilot_sync.py`, but not `tests/lib/run_project_turns.py:84-114`.
   - **Sweep:** every `A.Pilot(` in `tests/`: `autopilot_jobs.py`, `autopilot_startup_cache.py`, `autopilot_turn.py`, `autopilot_cases.py:103,269`, `run_project_turns.py`.

2. **The ASK wake identity changes with no carry-over, so deploying this replays an already-delivered ASK.**
   - **Old key:** `attention('ask', …)` built `ask-{pr}-{head}` (`fm_autopilot_loop.py:67-68`).
   - **New key:** `ask-{pr}-{key(ask)}` (`fm_autopilot_loop.py:178`).
   - `queue()` deduplicates only on the exact key (`fm_autopilot.py:127-133`). So when the saved state is loaded after this change, an ASK the T-175 code already woke under the old key gets queued again as a fresh wake. That needs the ASK to be at the PR head, newer than `tracking_started`, and with no later brief. This is the "restart replays an old ASK" behaviour the task is meant to remove.
   - **Coverage gap:** no test seeds a legacy ask wake.
   - **Class:** changing a saved dedupe key without migrating the keys already saved.

**Executed**
- `git log` / `git diff --stat fm/base...fm/head`, and greps for `tracking_started`: the boundary is set once with `setdefault` and kept across restarts (`fm_autopilot.py:63`).
- Reading `state/autopilot/state.json` from the live engine: refused by the sandbox, so I could not confirm the live `tracking_started` or the T-055 records.
- `bash tests/run-project-turns.test.sh` on head: FAILED (failures=2), output quoted in finding 1.
- `git worktree add` to run the same suite on base: refused by the sandbox.
- Greps for `Pilot(` and `read_head_spec` across `tests/`: list as in finding 1.

**Read, not run**
- The base pass of `run-project-turns` is inferred from base `task()` reading `tasks/<task>.json`, which the fixture writes at `run_project_turns.py:84`. It is not run.
- How `fm_binding.sha`/`fetch_ref`, the `Pins` constructor and `resolve(if_present=True)`, and the `fm_evidence` record shape, append order and time format work.
- `pull()` now checks state and policy before resolving the task. An unresolved `pulls` entry is harmless to `observed_closure` and `closed_pull`.
- Fail-first report: the new suite is red on base. Helper modules show no assertions under the project's `test` template.

1. Make every existing test that builds a real `Pilot` and reaches `task()` give the task a committed head spec, an authorized pin, or an explicit `read_head_spec` stub. `tests/run-project-turns.test.sh` must pass again, with no other `A.Pilot(` fixture in `tests/` relying on the checkout `tasks/` file (class: fixtures relying on the checkout task file).
2. Keep ASKs that were already delivered under the legacy `ask-{pr}-{head}` key from being queued again under the new per-record key after an upgrade restart. Add a test that loads saved state holding a legacy ask wake plus the matching fresh ASK and asserts nothing is queued (class: changed saved dedupe key without migration).

CRITERIA-COMPLETE:T-180
REVIEWER_COMPLETE:T-180
REJECT:T-180

