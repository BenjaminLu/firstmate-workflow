<img src="design/marketing/banner.webp" width="100%" alt="A voxel-art frigate under a blue 'firstmate-workflow' sail, its captain pointing the way while an AI crew of workers and reviewers keeps the deck, beside the headline 'MORE MINDS HIGHER IMPACT'.">

# firstmate-workflow

One agent runs the crew. Three things make it up:

- **`skills/`** — the content. Every role's behaviour is plain Markdown, so
  changing a skill changes behaviour without touching code.
- **`bin/fm-*.sh`** — execution and checks. They inspect repository state and
  command results; review checks also scan model-produced verdict markers.
  Firstmate must account for the enforcement gaps documented in the contract.
- **`board/`** — the captain's only console. Live state, open decisions, orders.

The agent CLI is a replaceable engine, not the system.

Spec: [`design/design.md`](design/design.md). Task DAG: [`design/tasks/`](design/tasks/),
one file per task; `bin/fm.sh tasks` prints it as a table.

## Starting a session

[AGENTS.md](AGENTS.md) routes top-level sessions directly to the canonical
[firstmate startup contract](skills/firstmate/SKILL.md). Codex reads AGENTS.md;
[CLAUDE.md](CLAUDE.md) imports the same entrypoint. Explicitly dispatched workers
and reviewers retain their supplied roles, including isolated review processes,
and never launch a crew.

Portable bootstrap is `bin/fm-session.sh start --repo <root>`. It inspects live
tasks/processes/panes, retires dead crew actors whose events still show them
aboard, and starts or reuses the correct-root captain board, owned by the
session and ending with it. Nothing watches for decisions: the board pushes
each wake as it writes one, ringing every waiter's own doorbell (T-151), and
the harness's hooks hand it to firstmate (T-137; see below): firstmate keeps
no waiter of its own running. `fm-session.sh wait` is a tool for scripts
that block on a wake.
`bin/fm.sh board` signs the captain's browser in to the board with a
one-time address, sending the tab already on the board there (Chrome, Safari,
Arc or Brave on macOS) rather than opening another, and says which it did
(T-145). A tab that cannot write says why in a banner, and its "Sign in
again" button has the board run the same opener, so the terminal is not needed.
Every background process fm starts goes through `bin/lib/fm-lifeline.sh`,
has an owner and ends with it. It does not authorize work or invent success when
Herdr/transport is missing. Declared adapters only: do not claim arbitrary
engines load AGENTS.md.

Crew rounds run headless: `fm-worker` / `fm-review` / `fm-dispatch` / `fm-run`
start each round as a process group fm supervises itself (a session of its
own, owned by the fm session through `bin/lib/fm_lifeline.py`, output in
the run's `run.log`, `runner.pid` and `runner.exit` beside it), so no terminal
host is needed. `host:` in `config.yaml` (`none|herdr|cmux|tmux`, detected when
unset) only opens a window for people to watch: with Herdr, one dedicated
unfocused tab per run with the canonical crew label, showing the run's live log
and closed, ownership-safe, after a positively completed final status; cmux and
tmux get the same window. A closed or crashed window never affects the round,
and a window that cannot be opened is skipped; each round's `window.json` says
which window it had, `none` included. `bin/fm.sh follow <actor>` shows a round's
log without a window, and `bin/fm.sh stop <actor>` or `stop --task <id>` stops
rounds by their process groups, the same stop the board's park and drop use.
Transport or empty/partial output is never reported as fabricated success.

Options: `FM_TRANSPORT=direct` (no window), `FM_HOST`, `FM_AUTOCLOSE=0`, and
`FM_STOP_GRACE` (seconds between a stop's TERM and KILL, default 5). A round
belongs to the session and ends with it (T-151). Nothing watches for
decisions: the board pushes the wake, and the hooks hand it to firstmate. Scope and
merge approval still go through the captain board.

Firstmate inspects existing work and live agents, then coordinates repository
scripts and remediation. Read the contract for retained authorization,
current-head verification and shipped script limitations. Runtime automation
does not yet ensure all these invariants; instruction checks validate metadata
and links, not model behavior. Neither lavish nor no-mistakes is a prerequisite;
their hooks are not part of startup or verification. `fm-decide.sh --request`
creates a card and returns; `--await` waits for the response. Firstmate must
verify current readiness and board approval: `fm-merge.sh` itself checks neither
decision approval nor the gates, and the board merge route does not rerun
them.

## Rules that bind everyone

1. **Nobody writes to `main`.** Not firstmate, not a worker, not a reviewer.
   Branch, then open a pull request. `bin/fm-guard.sh` and installed hooks provide
   local checks; GitHub branch protection must be configured and verified.
   Their presence in the repository does not prove they are active.
2. **English in the repository.** README, design docs, skills, code, comments,
   commit messages, pull request bodies and reviews. The board's three
   languages are a product feature and are the one exception.
3. **Merging is the captain's.** It arrives as a decision card on the board,
   never as a sentence in a conversation.

How to propose and land a change is in [CONTRIBUTING.md](CONTRIBUTING.md).

## Getting set up

```sh
bin/fm-install-hooks.sh   # git hooks are not cloned; opt in once per checkout
bin/ci.sh                 # the one gate - CI runs this same file
```

## Declaring a project

Firstmate can run a crew on any repository. It knows nothing about that
repository's toolchain; the repository says what it needs in the `project:`
block of its `config.yaml`, and the gates and `bin/fm-session.sh start` run
exactly that.

| key | required | meaning |
|---|---|---|
| `setup` | no | shell command that prepares a fresh checkout, such as installing dependencies |
| `check` | yes | shell command whose exit status means green |
| `check_env` | no | map of environment variables set for `check` and `test` |
| `tests` | no | list of globs saying which changed files are tests; defaults to `tests/**`, `*.test.*`, `*.spec.*` |
| `test` | no | command template that runs one test file; `{file}` becomes the shell-quoted path |
| `docs` | no | list of globs for changes that need no test of their own; undeclared exempts nothing |

Values are opaque shell command strings, run with `bash -c` from the checkout
root. They are read, never evaluated, so quotes, `&&` and `{file}` arrive as
written; quote a value in YAML only if it contains ` #` or starts with a YAML
indicator such as `*`. An unknown key, a `test` without `{file}` or a malformed
block is an error, not an empty declaration.

- **No gate runs the whole `check`** as a matter of course. The gates are
  numbered 1, 2, 4, 5, 6 and 7: gate 3, which ran `check` locally, is
  retired, because the required GitHub check runs it on the same head and
  gate 6 reads that.
- **Gate 5** classifies the diff with `tests`, reverts the implementation, runs
  `setup`, then runs through `test` only the suites the diff touches: each
  changed test, then each other test file that names one of them (a suite
  sourcing a changed helper). It requires red. When no suite can be run that
  way — no `test` declared, or no touched test left in the tree — it runs the
  whole `check` instead and says so. A missing `check` there, or a failing
  `setup`, fails the gate and says so. A diff whose every non-test path
  matches `docs` needs no new test; any other path still does.
- **Gate runs are serialized** on one machine by a kernel lock on a file
  (`FM_GATE_LOCK`, by default `/tmp/fm-gate.lock`, whatever `TMPDIR` is): a
  second run waits for the first, and the lock goes with the run that held
  it, however it ended. A gate run inside one holding the same lock is
  refused, so a test suite that runs the gate sets its own `FM_GATE_LOCK`.
- **`fm-session.sh start`** runs `setup` once in the repository checkout and
  reports a `project` block: the declared keys, setup's exit status and a short
  error. A failed setup is reported as not ready; startup carries on.
  `status` reports the same declaration and never runs `setup`.

A Go project:

```yaml
project:
  setup: go mod download
  check: go vet ./... && go test ./...
  tests:
    - "**/*_test.go"
  test: go test ./$(dirname {file})
```

A Python project:

```yaml
project:
  setup: python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
  check: .venv/bin/python -m pytest -q
  check_env:
    PYTHONDONTWRITEBYTECODE: 1
  tests:
    - "tests/**"
    - "**/test_*.py"
  test: .venv/bin/python -m pytest -q {file}
```

A project with nothing to install:

```yaml
project:
  check: make check
```

This repository declares its own: `setup` installs Bun dependencies and the
Playwright browser (without them a fresh worktree's `bin/ci.sh` skips its
end-to-end stage), `check` is `bin/ci.sh` with `FM_CI_MAX_SECONDS=600`, and
`test` runs a changed `*.test.sh` with bash. Its `docs` are `design/**`,
`README.md`, `LICENSE`, `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`,
`.github/ISSUE_TEMPLATE/**` and `.github/pull_request_template.md`; skills
are behaviour, so they are not docs.

### The reviewer

`config.yaml`'s `reviewer:` block names the reviewer's `vendor` and `model`,
and they are the captain's choice: this repository reviews with `claude` and
`opus-5`, the worker's own, so review adds no second vendor. Other vendors
stay in `fallback:` and `--vendor`. A project that names no reviewer vendor or
model is reported by `fm-session.sh start`, and firstmate asks the captain on
the board; the answer lands as a `config.yaml` change in a pull request.

`mode:` says what the reviewer may do. `diff`, and a project that declares
nothing, shows it the skill, the task and the diff. `run` adds a fresh clone
of the pull request head outside every worktree, removed when the round ends
(or, after a SIGKILL, by the next run-mode round),
where the reviewer may check a claim with a small command - reading,
grepping, git, a single script invocation. It runs no suite: the machine does
(T-153). The adapter confines it with the vendor CLI's
own permission flags - no settings, hooks or MCP servers from the clone or the
operator, no writes outside the clone and the temp directory, and no network
beyond the hosts `network:` lists for `setup` (plain domain names only: never
a domain GitHub operates and never a wildcard, so no push and no comments;
`fm-review.sh` and the adapter apply the same rule) - so only an adapter
carrying `# fm:review-run` takes a run-mode round; today that is `claude`.
Because the sandbox writes only in the clone and the temp directory, the
round points `XDG_CACHE_HOME`, bun's install cache, Playwright's browsers and
npm's cache into its own temp directory, so `setup` downloads them each round.
The engine starts without the launcher's `FM_*`, `HERDR_*`, `GIT_*` and
GitHub-token variables, so a command run in the clone acts on the clone, not
the repository the review was launched from.

The machine runs the tests and the reviewer judges (T-153). Every pull
request's `fail-first` CI job runs `bin/fm-failfirst.sh`, which puts the
change's non-test files back as the base has them, runs the changed suites on
both trees and reports each assertion that went red on base, and each guard
that stayed green. Given `--pr`, `fm-review.sh` waits, bounded
(`FM_REVIEW_CI_WAIT`, 1200 seconds by default), for the head's required
checks, and hands the reviewer, in either mode, every CI job's result, the
failing assertions from the failed jobs' logs and the fail-first report. The
reviewer itself has no GitHub access. Green CI and the gates are firstmate's
merge gate, not a review criterion: a merge card needs the reviewer's
approval and firstmate's own check of CI and the gates, both on the same
head. `fm-review.sh` posts the verdict and emits the review's
events in both modes. This repository declares `run`.

## Firstmate is never blind

A turn never ends while work is in flight and nothing can wake firstmate
(T-137). The wake is pushed, never watched: whoever writes an event that
needs firstmate puts it on the wake queue, `state/session/wake.jsonl`, and
rings every doorbell (`bin/lib/fm_lifeline.py push`). The writers are a
round's end (`fm-worker.sh`; `fm-review.sh` with its verdict), a run found
lost (the session's deck reconcile), a gate result from outside a round
(`fm-emit.sh`), and the board, for a card answered and a merge settled or
failed. `bin/fm-watch-arm.sh` keeps one watcher (`bin/fm-watch.sh`) per
repository and hands it on before each wake goes out; nothing polls.

`bin/fm-session.sh start` installs the hooks for the harness it runs in,
into that harness's local, uncommitted config (`bin/fm.sh hooks
install|uninstall`). What has been verified, per harness and version, is in
[docs/verification/supervision.md](docs/verification/supervision.md): the
Claude Code mechanism these hooks use was measured live on 2.1.284; the
hooks themselves, and the Codex and Cursor paths, are not yet verified live,
and nothing claims they work until they are. The board shows whether firstmate is watched, the last wake,
what waits, and any gap.

## State

Spec is settled and the bootstrap is under way. `design/proposals/` holds the
board proposal the captain green-lit — a throwaway prototype, not the
implementation.

```sh
open design/proposals/2026-09-20-captain-board/prototype.html
```

Arrow keys switch the four presentation levels; the top right switches
EN / 繁 / 简.

Driving other repositories from this one installation is designed in section
15 of the design and not yet built: until the M3 tasks land, firstmate drives
only this repository.

## License

MIT (SPDX: `MIT`). See [LICENSE](LICENSE).
