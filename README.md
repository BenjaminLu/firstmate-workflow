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
and closed, ownership-safe, after a positively completed final status. tmux
gets a log window; cmux requires explicit verified caller configuration and
remains subject to the supervised-access limitations below. A closed or crashed window never affects the round,
and a window that cannot be opened is skipped; each round's `window.json` says
which window it had, `none` included. `bin/fm.sh follow <actor>` shows a round's
log without a window, and `bin/fm.sh stop <actor>` or `stop --task <id>` stops
rounds by their process groups, the same stop the board's park and drop use.
Transport or empty/partial output is never reported as fabricated success.

cmux is never selected solely from inherited socket/workspace variables.
Set `FM_HOST=cmux` and `FM_CMUX_CALLER_WORKSPACE` only after verifying the
conversation's actual caller; the focused workspace is not that evidence.
In nested Herdr sessions use `FM_HOST=herdr` and verified `HERDR_*` context.
`host.json` records effective selection; cmux `window.json` records observed
identity, access mode and creation outcome. Label failures are not open windows.
The supplied cmux 0.62.2 `cmuxOnly` reproduction rejects the session-owned
launch after the tool shell exits even though foreground ping succeeds.
For this nested deployment retain **cmuxOnly** and dispatch into Herdr with
`FM_HOST=herdr`, `HERDR_PANE_ID`, `HERDR_TAB_ID` and `HERDR_WORKSPACE_ID`
verified against the conversation. The outer cmux workspace is not a dispatch
target. No password-mode configuration is required. Explicit cmux use probes
access at the point of use and preserves actual socket/auth errors; authorized
foreground cmuxOnly calls are allowed. Detached cmuxOnly control and safe cmux
owner-exit closure are deferred, not claimed supported by foreground success.
Password mode remains an optional operator-configured capability; fm does not
change settings or retrieve secrets. Never enable allowAll or change socket
permissions. Use `FM_HOST=none` and `fm follow` if no caller can be verified.
See [the T-162 handoff](design/cmux-lifecycle.md) for the required real Herdr
validation and traceable deferred cmux acceptance. A mock pass is insufficient.

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
mise install               # the toolchain pinned in mise.toml: bun, node, python, jq, gh, shellcheck
bin/fm-setup.sh             # first run: asks only what it cannot find out, writes config.yaml
bin/fm-doctor.sh --sandbox  # every dependency and every vendor login, and how to fix each
bin/fm-install-hooks.sh     # git hooks are not cloned; opt in once per checkout
bin/ci.sh                   # the one gate - CI runs this same file
```

Necessary agent hooks are a standing startup/setup rule (T-164). Both paths
reach doctor's read-only guidance; use `bin/fm-doctor.sh --hooks-only --repo <root>`
to repeat it without login probes or model sessions. It lists the vendor registry,
configured role vendors and detected harness, checks firstmate definitions in the
actual local source, and prints a scoped installation command. Files configured
is not readiness: loading, effective enablement/policy, native authorization and
real delivery are separate observations, marked unverified without evidence.

For Codex CLI/app-server, inspect this checkout's SessionStart, UserPromptSubmit
and Stop definitions in native `/hooks`, review/trust them, and re-review changed
hashes; restart/resume if the source is missing. For Claude Code, inspect the
local settings source in `/hooks`, review project trust and effective
`disableAllHooks`/managed policy; its hook browser is not Codex hash trust.
For Cursor, use workspace trust, Customize > Hooks and the Hooks output channel;
restart if automatic config reload did not load the source. Follow the target's
native approval controls. Doctor does not override explicit disablement, custom
or global settings, or managed policy; administrative refusals need the admin.
Unsupported/unverified vendors get `bin/fm-watch-arm.sh --max-wait 3000` in the
foreground, or `bin/fm-session.sh status` on each manual turn. Guidance adds no
sessions or prompts to crew rounds. Recorded `--facts` setup passes facts to
doctor without live probes/canaries; run `fm doctor --sandbox` separately when
ready. Installation and authorization still need real event/model-visible wake
and owner-cleanup evidence from [the smoke procedure](docs/verification/supervision.md).

Native mechanisms: [Codex hooks](https://learn.chatgpt.com/docs/hooks),
[Claude hooks](https://code.claude.com/docs/en/hooks),
[Cursor hooks](https://cursor.com/docs/hooks).

`fm setup` asks which installed vendor crews as worker and as reviewer, whether
each bills to its subscription or per API use inside the sandbox, and the main
repository and base branch, board port (4173), and language (`en` or `zh-TW`,
default `en`) - each with a recommended default that Enter
accepts - then writes only those answers to `config.yaml` (a model, the
reviewer's mode and everything else there are left as they were) and runs
`fm doctor --sandbox`. `board.port` sets the listening address and the address
`fm board` signs into; `FM_PORT` overrides it for one-offs. Setup refuses an
occupied port unless it verifies this repository's board. `language` sets the
board's initial language, the first language of decision cards, and firstmate's
reports; a viewer's saved toggle or `?lang=` overrides their own display.
The answers file keys are `board_port` and `language`. Re-running setup keeps
both saved values as the Enter defaults. Restart the board after changing its
settings. It never asks for or stores a
secret itself: for a key (cursor-agent's, say) it prints the exact keychain
command to run. `fm doctor` alone checks the same toolchain and vendor logins
on demand, and `--fix` installs a missing pinned tool through `mise`, asking
before each one. Each tool, herdr and vendor CLI is `ok`, `missing` or `wrong
version` (a vendor CLI older than the oldest release known to have the status
check below, herdr older than 0.9.1), with the one line that fixes it; each
worktree under `state/worktrees` whose `git status` shows an untracked build
cache is flagged. `fm doctor --sandbox` is also the merge gate for any change
to the sandbox or an adapter.

A round never runs on a login nobody checked: `bin/fm-auth-probe.sh <vendor>`
resolves the login a round of that vendor would get - the crew's own token or
key, exactly as `fm-sandbox.sh` hands it in, never your own interactive
session - and asks the vendor's own status check about that login alone: a
fixed command, closed stdin, a scrubbed environment, a time limit. It answers
`authenticated`, `unauthenticated`, `expired`, `quota-exhausted`,
`indeterminate`, `timeout` or `unavailable`. `fm-worker.sh` and `fm-review.sh`
run it for every vendor in their chain before any of them sees a prompt.
Only `authenticated` is usable: anything else - `indeterminate` and `timeout`
included - is moved past the same way an outage is, with the probe's status
and reason on the board, and the chain tries its next vendor. gemini has no
documented status command, so its login cannot be verified and rounds on it
are refused until it can be.
The claude, codex and
gemini adapters also shed the environment variables each vendor documents as
outranking its stored login (`ANTHROPIC_API_KEY` among them) before every
round, unless `config.yaml`'s `billing:` block names that vendor for api-key
billing on purpose.

## Declaring a project

Firstmate can run a crew on any repository. It knows nothing about that
repository's toolchain. The self contract is declared once in
`config.yaml` under `projects.firstmate-workflow.project`. Historical top-level
`project:` contracts remain readable; declaring both is an error. Session
start/status use the same parser. External contracts are approved privately
under `FM_HOME/projects/<name>/state/config.yaml`, never in the public registry.

Gate 5 reads the complete verified contract snapshot in the task's approved
pin, including `docs` and `check_env`. It never reads the tested branch's
contract or the mutable engine config. Old self pins read their recorded
commit and location without repinning. Allowing a task to edit config does
not allow that task to change its own gates. The examples below show the
contract body in the historical/private `project:` form; for the self registry,
nest that block beneath `projects.firstmate-workflow`.

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
  sourcing a changed helper). It requires green on head and red on base. When no suite can be run that
  way — no `test` declared, or no touched test left in the tree — it runs the
  whole `check` instead and says so. A missing `check` there, or a failing
  `setup`, fails the gate and says so. A diff whose every non-test path
  matches `docs` needs no new test; any other path still does.
- **Current-head evidence** uses the selected project's repository and PR base,
  including a stacked base. Before a full gate run, GitHub's head and fetched
  head must match the local task ref; the isolated rebase checkout must match
  too. Required check-runs and commit statuses must both be green on that SHA.
  Names combine readable protection with captain-confirmed conventions;
  unreadable protection needs confirmed checks and policy. Missing or running
  evidence is pending, failures are failed, unreadable evidence is unknown.
  Gate transcripts and signed readiness also bind the exact PR base tip;
  head/base movement invalidates readiness. Gate 7 reads signed local final
  verdicts under the project review policy; comments alone carry no authority.
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
carrying `# fm:review-run` takes a run-mode round; today those are `claude` and `codex`. Codex requires the outer OS sandbox
and a managed invocation bound to the isolated checkout and pinned head. Its
verdict comes only from the completed final assistant output, with transport
identity and digest checks. An unsigned retry or vendor fallback into Codex
recreates the pinned checkout; cleanup retains checkouts with live or uncertain
execution owners.
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
and nothing claims they work until they are. Codex installation now includes
SessionStart/resume and separate loading/trust diagnostics via `fm.sh hooks
status --harness codex`. Firstmate has verified loaded but untrusted project
hooks on 0.159.3; the operator must review current definitions in `/hooks`.
Real model delivery and reload behavior remain to be measured in the disposable
smoke documented above. The board shows whether firstmate is watched, the last wake,
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

## External repositories: approved roadmap

[Design section 15](design/design.md#15-driving-other-repositories-approved-plan-runtime-not-yet-accepted)
and the [adoption ledger](design/external-roadmap.md) describe the approved
T-166 roadmap; this documentation does not declare external execution complete.
External private repositories will keep clone, worktrees, CONVENTIONS.md, tasks,
design and state under `FM_HOME/projects/<name>/` (default `~/.firstmate`), outside
the engine. Self-project compatibility remains. Migration requires approval;
unreadable protection is unknown and requires confirmed project checks/policy.

Acceptance binds GitHub's authoritative PR head to the local task ref, isolated
checkout, check-runs plus commit statuses, six gates (1,2,4,5,6,7), authenticated
review and merge candidate. Private local evidence is authoritative; GitHub
posting follows project conventions. Merge/handoff, retention and stacking obey
the approved contract, with captain approval and no automatic merge.

The basic pilot is the actual empty `/Users/benjamin/Desktop/maker-founder` repo,
observed with HEAD master and no commits or remote. Its product/remote contract
and bootstrap must be approved before a real scoped task is dispatched via
the stock dispatcher to a visible owned Codex Herdr run. Capture isolated review,
checks/gates, outputs and cleanup/retention evidence. A mock fixture or manual
relaunch after dead dispatch is insufficient. Advanced external reviewers,
stacking and autopilot (T-140/T-143/T-141) remain planned after the basic pilot.

### External project storage (T-142)

`FM_HOME` selects an absolute directory outside the engine checkout; otherwise
`home:` in engine `config.yaml` is used, then `~/.firstmate`. Each external
project stores its managed clone at `projects/<name>/repo`, worktrees at
`projects/<name>/worktrees`, and local specs at `tasks/`, `design.md`, and
`CONVENTIONS.md`. Execution records live under that project's `state/`.
Self projects (`repo: .`) keep their existing layout.

`bin/fm.sh project sync <name>` refuses an existing legacy
`state/projects/<name>` store. After the operator approves migration, pass
`--migrate`. Migration uses a same-filesystem atomic rename and retains the
source on refusal; registered worktrees and live or indeterminate ownership
records must first be reconciled. It does not silently copy and delete records
across filesystems.
`bin/fm.sh project history on <name>` initializes local spec history with no
remote and excludes clones, worktrees, and execution state.

Private visibility is accepted. When GitHub protection cannot be read,
verification remains unknown unless the captain has confirmed the repository,
base, required checks and policy in local
`state/protection-confirmation.json` (`repository`, `base`, `required_checks`,
`captain_confirmed: true`, `policy_confirmed: true`). This record cannot turn an
explicitly unprotected branch into a protected one.

External merges remain refused pending T-139's conventions policy reader; they
never fall back to self-project squash/delete behavior. External task-branch
force pushes are also refused until a confirmed project policy can be read.

Until that reader is installed, external worker publication and review-comment
posting stay local as well. This is a deliberate policy hold: a local commit or
review log is not a published PR, a verified verdict, or an accepted external
execution. No environment switch grants publication permission.

Approved migration consolidates separately stored project specs and records,
including owned lines in shared event and wake logs, completed run directories,
decisions, diagrams, mirrors, pins, evidence and recovery records. It checks the
transfer plan before mutation, verifies retained bytes, and keeps a recovery
journal outside the engine. A failure rolls back the clone and record transfers.
Live IPC, active or indeterminate owners, registered worktrees and ambiguous
destination collisions are refused; reconcile those with firstmate before retrying.

The engine-wide board projects external task IDs, statuses, crew identity and PR
links. Select a project to read its local descriptions and decision details;
those records are read in place, not copied into the engine's public tree.
