# firstmate-workflow

One agent runs the crew. Three things make it up:

- **`skills/`** — the content. Every role's behaviour is plain Markdown, so
  changing a skill changes behaviour without touching code.
- **`bin/fm-*.sh`** — execution and checks. They inspect repository state and
  command results; review checks also scan model-produced verdict markers.
  Firstmate must account for the enforcement gaps documented in the contract.
- **`board/`** — the captain's only console. Live state, open decisions, orders.

The agent CLI is a replaceable engine, not the system.

Spec: [`design/design.md`](design/design.md). Task DAG: [`design/tasks.json`](design/tasks.json).

## Starting a session

[AGENTS.md](AGENTS.md) routes top-level sessions directly to the canonical
[firstmate startup contract](skills/firstmate/SKILL.md). Codex reads AGENTS.md;
[CLAUDE.md](CLAUDE.md) imports the same entrypoint. Explicitly dispatched workers
and reviewers retain their supplied roles, including isolated review processes,
and never launch a crew.

Portable bootstrap is `bin/fm-session.sh start --repo <root>`. It inspects live
tasks/processes/panes, retires dead crew actors whose events still show them
aboard, starts or reuses the correct-root captain board, and starts or reuses a
cancellable decision watcher. It does not authorize work or invent success when
Herdr/transport is missing. Declared adapters only: do not claim arbitrary
engines load AGENTS.md.

When `HERDR_ENV=1`, managed Herdr transport is the default for real
`fm-worker` / `fm-review` / `fm-dispatch` / `fm-run` entrypoints: one dedicated
unfocused tab per run, canonical crew labels, ownership-safe close after a
positively completed final status. Outside that session, supported adapters and
vendor fallback still run; transport or empty/partial output is never reported
as fabricated success.

Explicit opt-outs (when applicable): `FM_TRANSPORT=direct` (with
`FM_ALLOW_DIRECT=1` if inside Herdr), `FM_AUTOCLOSE=0`, and `fm-session.sh stop`
for decision watching. Scope and merge approval still go through the captain
board.

Firstmate inspects existing work and live agents, then coordinates repository
scripts and remediation. Read the contract for retained authorization,
current-head verification and shipped script limitations. Runtime automation
does not yet ensure all these invariants; instruction checks validate metadata
and links, not model behavior. Neither lavish nor no-mistakes is a prerequisite;
their hooks are not part of startup or verification. `fm-decide.sh --request`
creates a card and returns; `--await` waits for the response. Firstmate must
verify current readiness and board approval: `fm-merge.sh` itself checks neither
decision approval nor the seven gates, and the board merge route does not rerun
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

## Getting set up

```sh
bin/fm-install-hooks.sh   # git hooks are not cloned; opt in once per checkout
bin/ci.sh                 # the one gate - CI runs this same file
```

## State

Spec is settled and the bootstrap is under way. `design/proposals/` holds the
board proposal the captain green-lit — a throwaway prototype, not the
implementation.

```sh
open design/proposals/2026-09-20-captain-board/prototype.html
```

Arrow keys switch the four presentation levels; the top right switches
EN / 繁 / 简.
