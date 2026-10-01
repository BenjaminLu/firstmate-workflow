Baseline: `df2cf03f4bf39a40b0fa00fcc8f02adec4fb197c`. Static inspection only; no suites executed.

| Original suite | assert_* before/after | Playwright before/after | Python assertions before/after | Python tests before/after | Original test source and names |
|---|---:|---:|---:|---:|---|
| tests/worker.test.sh | 650/650 | 0/0 | 0/0 | 0/0 | preserved |
| tests/board.test.sh | 621/621 | 0/0 | 0/0 | 0/0 | preserved |
| tests/review.test.sh | 421/421 | 0/0 | 0/0 | 0/0 | preserved |
| tests/ci.test.sh | 199/199 | 0/0 | 0/0 | 0/0 | preserved |
| tests/adapter-contract.test.sh | 305/305 | 0/0 | 0/0 | 0/0 | preserved |
| tests/sandbox.test.sh | 441/441 | 0/0 | 0/0 | 0/0 | preserved |
| tests/herdr.test.sh | 0/0 | 0/0 | 455/455 | 92/92 | preserved |
| tests/e2e/board.spec.ts | 0/0 | 56/56 | 0/0 | 0/0 | preserved |

1200-line cap: 147 files inspected; 0 oversized.

Counts are static call sites, including embedded fixture source; parameterized tests remain parameterized. All original non-comment source lines, including full assertion arguments and test names, must be retained with multiplicity. Manifest exemptions name only replaced setup, cleanup, class declarations and runner scaffolding. New regression tests are counted separately from the moved suites. This does not establish runtime equivalence or model compliance.
