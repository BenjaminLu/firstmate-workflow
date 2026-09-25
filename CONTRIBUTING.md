# Contributing

This repository is built by the crew it describes. Most pull requests are
opened by a worker agent that firstmate dispatched, and reviewed by a reviewer
agent; a human's pull request goes through exactly the same checks. This guide
says how that works, so a change from outside lands the way one from inside
does. The specification is [`design/design.md`](design/design.md); where this
guide and the design disagree, the design is right and this guide is a bug.

By taking part you agree to the [code of conduct](CODE_OF_CONDUCT.md).
Security problems go to [SECURITY.md](SECURITY.md), not to a public issue.

## A change starts from a task

Work is planned as tasks in [`design/tasks/`](design/tasks/), one file per
task: `design/tasks/<id>.json` holds its `id` (`T-xxx`), `title`,
`milestone`, `depends_on`, `scope`, `bootstrap` and `acceptance` criteria
(`design/design.md` section 14). There is no hand-kept table; `bin/fm.sh
tasks` prints one on demand. A pull request implements one task.

- **To propose work**, open a *task proposal* issue: the problem, the
  acceptance you would expect, the files you think it touches and the
  section of `design.md` it affects. The captain (the maintainer) decides
  whether it becomes a task.
- **To report a defect**, open a *bug* issue.
- **A new task defines itself on its own branch.** Its file
  `design/tasks/<id>.json` is committed in the same pull request that
  implements it. Gate 4 reads the scope from the branch under test.

## Who does what

- **The captain** is the maintainer. They green-light work, decide scope
  changes and merge, on the board (`board/`). A merge arrives as a decision
  card, never as a sentence in a conversation.
- **Firstmate** coordinates. `bin/fm-dispatch.sh` starts nothing until a
  `greenlit` event exists, then starts ready tasks up to `config.yaml`'s
  `concurrency`; `bin/fm-worker.sh` runs a worker in a worktree of its own and
  opens the pull request; `bin/fm-review.sh` runs a reviewer that sees the
  diff, the task spec and the acceptance criteria. When a
  change needs a file outside its scope, or is ready to merge, firstmate puts
  the question to the captain as a decision on the board (`bin/fm-decide.sh`).
- **Nobody writes to `main` or `master`**, including firstmate. Work happens
  on a branch and arrives as a pull request. Run `bin/fm-install-hooks.sh`
  once per checkout so the local hooks refuse a commit or push to a
  protected branch.

## The seven gates

Every pull request, human or agent, passes all seven gates of
`design/design.md` section 6 before it can merge. `bin/fm-gate.sh` checks
them; none of them reads what anyone said about their own work.

1. The branch exists and has commits on top of `main`.
2. It rebases onto `main` cleanly.
3. The declared project check exits 0 in a fresh worktree.
4. **The diff stays in scope**: every changed path matches a glob in the
   task's `scope` in `design/tasks/<id>.json`. If the work needs a file
   outside it, say so in the pull request and stop; widening scope is the
   captain's decision.
5. **The new tests are not vacuous**: revert the implementation and the new
   tests must go red. Write the test first and watch it fail. A change whose
   every non-test path matches the project's declared `docs` globs needs no
   new test.
6. **The required GitHub check** (`ci`) is green.
7. **A pull request comment contains `APPROVE:<task-id>`**, posted by the
   reviewer.

## The project check

What "green" means is not hard-coded. It is the `project:` block of
[`config.yaml`](config.yaml), described in the README: `setup` prepares a
fresh checkout, `check` is the gate, `tests` and `docs` classify changed
paths for gate 5. For this repository `check` is `bin/ci.sh`, the same file
GitHub Actions runs, and `setup` is `bun install --frozen-lockfile` followed by
the Playwright browser install. A fresh worktree has no `node_modules`; without
setup, `bin/ci.sh` skips its end-to-end stage instead of running it.

```sh
bin/fm-install-hooks.sh
bun install --frozen-lockfile && bunx playwright install chromium
FM_CI_MAX_SECONDS=600 bin/ci.sh
```

When `shellcheck`, `bun` or the Playwright install is missing, `bin/ci.sh`
reports the stage that needs it as skipped, and a skipped stage is not a
passed one: CI installs all of them, so it still runs on the pull request. Without
`FM_CI_MAX_SECONDS` the budget is 180 seconds; GitHub and the declared
`check_env` give it 600. Section 10 of the design describes its stages.

## Review, and round three

The reviewer's only pass signal is `APPROVE:<task-id>` in a pull request
comment. In rounds one and two the reviewer raises what it finds, and the
worker fixes the **class** each finding names, not just the instance: search
the repository for every occurrence, fix them all in the same round, and say
in the pull request what you searched for and how many you found.

From round three the review runs on a closed list (design section 7):

1. Before changing anything, if no closed list exists yet, the author posts
   `ASK-PASS-CRITERIA:<task-id>`. That asking round changes no implementation
   files.
2. The reviewer answers with a numbered list and `CRITERIA-COMPLETE:<task-id>`.
3. The author fixes the whole list in one pass. From then on the reviewer may
   raise only items from that list, or a newly introduced problem marked
   `REGRESSION:<task-id>`. The original list is kept; it is not asked for
   again or replaced.

## Language

Everything in the repository is English: code, comments, docs, skills,
commit messages, pull request bodies and reviews. The one exception is the
board, which is a three-language product. Anything a script writes to the
board's event log carries its summary in both `en` and `zh-TW` (through
`bin/fm-emit.sh`); `zh-CN` is derived from `zh-TW` through `i18n/tw2cn.tsv`.
Board UI text comes from the dictionaries in `i18n/`, never from a literal.

## License

This project is licensed under the [MIT License](LICENSE). Contributions are
accepted under the same license: by opening a pull request you agree that your
contribution is licensed under MIT.
