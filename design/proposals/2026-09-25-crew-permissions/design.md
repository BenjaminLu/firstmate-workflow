# Crew permissions: one policy, every vendor

Status: proposal for the captain (decision D-1033). Nothing is dispatched until
he chooses. Task: T-105. Redone as T-117 after T-105 locked every vendor out on
macOS; section 8 says what changed.

## 1. Why

A worker today is `claude -p --permission-mode acceptEdits` in its worktree.
It has no permissions of its own. It inherits whatever the operator's personal
Claude settings allow. On this machine, that is both too much and too little.

Too much, because the inherited allow list has these holes:

- `gh-axi:*`. A worker or reviewer can comment on, close or merge a pull
  request as the captain. That breaks two rules: "the adapter never touches
  gh" and "merges only through the board".
- `find:*`, `sed:*`, `awk:*`. `awk 'BEGIN{system(...)}'`, `find -exec` and
  `sed -i <any path>` together make the whole list meaningless.
- `cat:*` with any path. `~/.config/gh/hosts.yml` and `~/.ssh` can be read.
  With the first hole, they can then be posted to a pull request.
- `additionalDirectories` is inherited, and acceptEdits applies there. A
  worker can edit `~/.claude/skills` (firstmate's own skill), firstmate's
  scratchpad and other repositories.
- `herdr:*` and `chrome-devtools-axi:*`. A worker can drive other panes and a
  browser.
- The repository's own `CLAUDE.md`, `.claude/settings.json` and `.mcp.json`
  are loaded as configuration. A third-party repository can widen its
  worker's permissions or inject instructions.

Too little, because a command allow list cannot foresee a repository:

- `bun`, `npm`, `python` and `chmod` are refused. A task that needs
  `bun add`, codegen or a formatter hand-edits a lockfile or stalls. T-098
  worked around chmod through git's index.
- A diff-mode reviewer cannot read the repository. That is the loop T-066
  ends for reviewers.
- The allow list lives in one person's home directory. On another machine,
  the same task runs under different rules.

The other vendors are no better, and none of them agrees with another:

| vendor | adapter passes | effect |
|---|---|---|
| claude | `acceptEdits` | operator's allow list, no sandbox |
| codex | no `-s` | vendor default plus the operator's config |
| cursor-agent | `-f` | `--force`: every command allowed unless denied, no sandbox. The adapter comment says `-f` trusts the workspace. It does not; that flag is `--trust` |
| gemini | nothing | non-interactive default; edits may be refused |

## 2. The principle: bound the effect, not the command

A command allow list decides which program may start. Once a program runs, it
reaches everything the operator's account reaches. So one permissive entry
undoes the list, and every new toolchain needs a new entry.

A sandbox decides what the whole process tree may touch. The OS enforces it at
the system-call boundary: Seatbelt on macOS, bubblewrap on Linux. No wrapper
or subprocess gets around it. So inside the sandbox every command may run,
and no command can reach past it:

| in the sandbox | result |
|---|---|
| `awk 'BEGIN{system("rm -rf ~/x")}'` | rm runs; deleting outside the worktree is refused |
| `cat ~/.ssh/id_ed25519` | refused |
| `curl https://api.github.com` | refused |
| `bun install`, `chmod +x`, the suites | allowed: they touch only the worktree and the declared registries |

"Every command inside the sandbox" is not "every permission". It is safe only
if the sandbox itself has no holes, and §3 closes the known ones.

## 3. The policy

fm owns one vendor-neutral policy per role. Its defaults live in
`config.yaml`, and a project may narrow or extend it.

| dimension | worker | reviewer (run mode) |
|---|---|---|
| write | its worktree, TMPDIR | its checkout, TMPDIR |
| read | default deny outside the worktree; allow the toolchain (runtime, package caches, system libraries) | same, on its checkout |
| never readable | `~/.ssh`, `~/.config/gh`, `~/.aws`, `~/.claude`, `~/.codex`, `~/.cursor`, `~/.gemini` except the vendor's own auth, other worktrees, fm's `state/` | same |
| commands | any, inside the sandbox | same |
| refused outright | `git push`, `gh`, `herdr`, browsers, MCP servers | same |
| network | only the project's declared package registries; never GitHub, never loopback (the board at 127.0.0.1:4173 can merge) | same |
| unix sockets | none (Herdr, docker, ssh-agent) | same |
| environment | scrub `GH_TOKEN`, `GITHUB_TOKEN`, `SSH_AUTH_SOCK`, cloud credentials | same |
| repository config | not loaded (`.claude/`, `.mcp.json`, `.cursor/`, `GEMINI.md`); `CLAUDE.md` and `AGENTS.md` are handed over as data | same |
| resources | wall-clock timeout (exists), plus ulimit on processes and CPU time | same |

Registries are declared per project, for example
`permissions.network: [registry.npmjs.org]`. A fresh repository declares none,
so a round that needs a registry fails and names the blocked host. Firstmate
then raises a choice card to add it. The crew never widens its own policy.

A registry is a possible exfiltration path: publishing to npm is still an
upload. The mitigations are that no token reaches the round, and that the
list names download hosts only.

## 4. One policy, many vendors: translate, then wrap

Each adapter translates the policy into its CLI's own flags. That keeps the
vendor from prompting a human who is not there. It is also the first layer of
enforcement:

| vendor | translation |
|---|---|
| claude | `--restricted --strict-mcp-config --disable-slash-commands --permission-mode dontAsk --settings <fm-generated>`: sandbox enabled, write roots, `allowedDomains`, deny rules. T-066 already does this for reviewers. |
| codex | `-s workspace-write`, approval `never`, `shell_environment_policy` scrub, no user profile. Network is all or nothing, so the domain list is a gap. |
| cursor-agent | drop `-f`; `--trust --sandbox enabled`; no `--approve-mcps` |
| gemini | `--sandbox --approval-mode auto_edit --policy <fm-generated> --allowed-mcp-server-names` (empty) |

A CLI's own flags cannot express everything, and they differ by version.
So fm adds a second, uniform layer: it runs the CLI inside an OS sandbox
profile generated from the same policy. That profile is `sandbox-exec` on
macOS and `bwrap` on Linux. The outer layer is what makes vendors equal.
codex's missing domain list, for example, is enforced there.

Each adapter declares which dimensions it enforces natively. Before a
round, fm checks that every dimension is enforced by the adapter or by the
outer layer. If one is not, the adapter refuses and the fallback chain moves
on. This is T-066's rule ("a vendor that cannot confine the round is
refused"), extended to workers. It never degrades to an unconfined run.

## 5. How it is proven

- Adapter contract tests (CI): for each vendor, the generated flags and
  profile match the policy. A vendor missing a dimension with no outer layer
  is refused. A project's registry list reaches both layers.
- Canary (not CI, because it calls real models): on adding or upgrading a
  vendor, one scripted round per vendor tries to write outside the worktree,
  read `~/.ssh`, reach github.com, reach 127.0.0.1:4173, and connect to the
  Herdr socket. All five must be refused. Its script lives in `bin/`, and its
  last result is recorded per vendor and version.
- Regression: T-098's chmod workaround stays, but `chmod` works in the
  sandbox. A worker may install dependencies from a declared registry.

## 6. What a fresh repository meets

- Most "too little" cases go away: installs, chmod, codegen and suites run.
- An undeclared host (for example a private registry) stops the round with
  the blocked host named. A card asks the captain.
- An empty repository with no base branch, or no required check, is still
  refused at dispatch. Those gaps belong to gates 2 and 6, not to this task.
- A hostile repository can at worst wreck its own worktree. It cannot read a
  credential, reach GitHub or the board, write elsewhere, or drive another
  agent.

## 7. Order and overlap

T-105 touches `bin/adapters/*.sh`, `bin/adapters/_lib.sh`, `bin/fm-worker.sh`
and `config.yaml`, the same files as T-066 (#74). It starts after T-066
merges and reuses T-066's claude settings builder and refusal rule. It has no
overlap with T-103 or T-104.

## 8. T-117: T-105 again, with every vendor able to start on macOS

T-105 merged on 2026-09-26 and locked every vendor out on the captain's
Mac. claude could not start (`EPERM ... open '/tmp/claude-501'`: it keeps a
directory under `/tmp` whatever `TMPDIR` says), and claude and
cursor-agent could not sign in: both keep their login in the macOS
keychain, and the profile denies the keychain so that gh's token and git's
credentials are out of reach. CI runs only the Linux path and saw none of
it. The captain reverted it (PR 96) and asked for it again with:

- each vendor starting and signing in with the login the operator already
  uses, and nothing more. The keychain stays denied to every round - there
  is no rule for one item, and gh's token is one `security` call away once
  the keychain is reachable - so fm reads the vendor's own item outside the
  round and hands its access token in, never a refresh token. cursor-agent
  reads `agent login`'s token through the keychain API, which nothing in a
  round can answer for, so its round signs in with a Cursor API key the
  operator keeps once for the crew, handed in as `CURSOR_API_KEY`. A login
  kept in a file (codex's, gemini's) holds a refresh token too, so no round
  reads it in place: fm hands in a copy with the refresh token emptied, in
  the round's own temp directory. claude gets a
  config directory and temp directory of the round's own, plus the one
  directory it keeps under `/tmp`. Design section 13.1 names every path,
  item and service per vendor;
- a canary that runs each installed, logged-in vendor for real on the
  operator's Mac and says started / authenticated / refused, or skipped,
  whose output firstmate puts in the pull request before the merge card;
- an operator-only escape hatch, `FM_CREW_UNSANDBOXED=1` in the operator's
  own shell, that runs a round without the OS sandbox and says so on
  stderr, in the round's log and on the board, and that no round can take,
  so that a broken sandbox can never again stop every worker with no way to
  ship its own fix. Under it claude's, codex's and cursor-agent's own
  sandboxes come back on (claude's with T-066's settings); gemini has none;
- every location a round is handed - its temp directory, the toolchain's
  caches, the vendors' config homes - inside a write root, so a round's
  `setup` can install; and saving the branch left to `fm-worker.sh`, since a
  round can neither write the git directory nor reach GitHub (design 13.1).
