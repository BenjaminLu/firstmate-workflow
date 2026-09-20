# firstmate-workflow

One agent runs the crew. Three things make it up:

- **`skills/`** — the content. Every role's behaviour is plain Markdown, so
  changing a skill changes behaviour without touching code.
- **`bin/fm-*.sh`** — the law. Acceptance reads the filesystem and exit codes.
  It never reads what a model claims it did.
- **`board/`** — the captain's only console. Live state, open decisions, orders.

The agent CLI is a replaceable engine, not the system.

Spec: [`design/design.md`](design/design.md). Task DAG: [`design/tasks.json`](design/tasks.json).

## Rules that bind everyone

1. **Nobody writes to `main`.** Not firstmate, not a worker, not a reviewer.
   Branch, then open a pull request. Enforced by `bin/fm-guard.sh`, by the git
   hooks in `.githooks/`, and by branch protection on GitHub.
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
