# The adapter contract

An adapter is the only place a vendor's name appears. Everything above it —
dispatch, gates, review, merge — is vendor-agnostic, and stays that way because
an adapter is allowed to do exactly one thing.

```
usage:    <vendor>.sh run <prompt-file> <worktree-dir> <log-file>
          <vendor>.sh dimensions
does:     hands the prompt to that vendor's CLI and lets it edit files in <worktree-dir>,
          confined to the round's permission policy (FM_POLICY)
must not: run git or gh
must not: write anywhere outside <worktree-dir> and <log-file>
exits:    0  done
          1  ran, but did not achieve it (the model gave up, the output is unfit)
          2  vendor unavailable (CLI missing, not logged in, out of quota, network down),
             or the round's policy has a dimension neither its flags nor the OS sandbox enforce,
             or the OS sandbox failed before it started the CLI
```

Only `2` falls back to the next vendor in `config.yaml`. A `1` is a normal
failed attempt and goes to the gates and the reviewer like any other.

**Every round runs under one policy fm owns (T-105, T-117).** `fm_policy` in
`bin/fm-config.sh` resolves it per role from `config.yaml` (`policy:`, with
a project's `projects.<name>.policy:` over it), and `fm-worker.sh` and
`fm-review.sh` hand it over as `FM_POLICY`. The operator's own CLI settings
are no part of it. It has eight dimensions: `write`, `read`, `network`,
`sockets`, `env`, `repo-config`, `refuse`, `ulimit`. An adapter translates
the policy into its CLI's own flags and says which dimensions those flags
enforce (`<vendor>.sh dimensions` prints them); `bin/fm-sandbox.sh` runs the
CLI inside an OS sandbox built from the same policy - `sandbox-exec` on
macOS, `bwrap` with a network namespace of its own on Linux - which covers
all eight on both. Before the CLI starts, `fm_adapter_confine` in `_lib.sh`
checks the union: a dimension neither covers refuses the round with `2`, so
the fallback chain moves on, and nothing degrades to an unconfined round.
Reading is default-deny only in the OS sandbox, so no round runs on a host
without one. An adapter reached without `FM_POLICY` takes the engine's own
policy for its role, never none. `fm_adapter_policy` also gives the round a
temp directory of its own, its `TMPDIR`, removed when the adapter exits; the
caller's is never a root. When the sandbox fails before it starts the CLI -
the vendor's login missing, its proxy, its profile, the process count, the
sandbox binary - the adapter's verdict is `2`, not the launcher's exit code
read as a model giving up: `fm-sandbox.sh --started` writes `started` from
inside the sandbox just before the CLI, and a round without it never ran.

**The vendor's login (T-117).** A round reaches the login the operator
already uses, and nothing more. Where that login lives out of the round's
reach - claude's in the macOS keychain, beside gh's token and git's -
`fm-sandbox.sh` reads exactly the vendor's own item or file, named in the
policy's `vendors.<name>.login`, outside the sandbox, and hands it in as a
variable (never a refresh token): claude's access token as
`CLAUDE_CODE_OAUTH_TOKEN`, with a config directory (`CLAUDE_CONFIG_DIR`)
and temp directory (`CLAUDE_CODE_TMPDIR`) of the round's own. cursor-agent
reads `agent login`'s token through the keychain API, which nothing inside
a round can answer for, so its round signs in with a Cursor API key the
operator keeps once for the crew - fm's keychain item
`firstmate-cursor-api-key`, or `~/.config/firstmate/cursor-api-key` at mode
600 - handed in as `CURSOR_API_KEY`. A login kept in a file - codex's
`auth.json`, gemini's `oauth_creds.json` - is never read in place, since
each holds a refresh token: fm writes a copy with the refresh token emptied
into the round's temp directory, and the adapter points its CLI there
(`CODEX_HOME`, gemini's `HOME`). The keychain's mach services stay denied
to every round. No login refuses the round with `77`,
which the adapter reads as unavailable. Design 13.1 names each vendor's
path, item and service, and why.

**Every location a round is handed is one it may write (T-117).**
`fm_adapter_policy` points the toolchain's caches (`FM_ROUND_CACHES`:
`XDG_CACHE_HOME`, bun's, Playwright's, npm's, pip's, Go's) into the round's
own temp directory, whatever the caller set them to, and every config home
an adapter hands its CLI is there too; the directory a CLI writes its final
answer to is passed as `--write`. A new location goes inside one of those,
or is a `--write` of its own: `tests/adapter-contract.test.sh` checks every
directory the CLI is handed against the profile and the bwrap arguments.

**The operator's escape hatch (T-117).** `FM_CREW_UNSANDBOXED=1` in the
operator's own shell makes `fm-worker.sh` and `fm-review.sh` set
`FM_ROUND_UNSANDBOXED=1` for the adapter, which then runs the CLI through
`fm-sandbox.sh plain` - the scrub, the ulimits and the login, no OS sandbox -
and says so on stderr. The vendors' own sandboxes come back on where the
adapter has one to turn on: claude's with T-066's settings (enabled, every
command inside it, none let out, the policy's registries as its
`allowedDomains`), codex's `workspace-write`, cursor-agent's `--sandbox
enabled`. gemini has none: the adapter never turns on its container or
seatbelt, so under the hatch its commands are confined only by the scrub
and the ulimits. The scripts say
so in the round's log and on the board. `fm-sandbox.sh` marks every round
`FM_IN_ROUND=1` and scrubs both names, and an adapter or script that sees
`FM_IN_ROUND` ignores the hatch, so no round can take it.

| vendor | Linux (bwrap) | macOS (sandbox-exec) |
|---|---|---|
| claude | T-066's settings for every round: `--restricted --strict-mcp-config --disable-slash-commands`, dontAsk, file rules on the worktree and the round's own TMPDIR, deny rules; its own sandbox off, the shell allowed under the OS one; a config and temp directory of the round's own | the same |
| codex | `--sandbox workspace-write` with its network switch on (the OS sandbox limits it), approval never, the scrub list as `shell_environment_policy.exclude`, no MCP servers, a `CODEX_HOME` of the round's own | `--sandbox danger-full-access` inside the outer one; the rest the same |
| cursor-agent | `--trust --sandbox enabled` instead of `-f`, no `--approve-mcps` | `--trust --sandbox disabled` inside the outer one |
| gemini | `--approval-mode yolo --extensions none`, no MCP server | the same |

claude's, codex's and cursor-agent's own sandboxes are seatbelts on macOS,
and a seatbelt cannot be applied inside another. claude's is off on Linux
too: its commands would reach the network through claude's own proxy, which
has no way out of the round's namespace and names no host it refuses.

A host the round's proxy refused lands in `FM_POLICY_BLOCKED`; the calling
script reports it and records it in `state/policy/blocked-hosts.jsonl`
(design 13.1), and the crew never widens its own policy. `bin/fm-canary.sh`
runs one real round per installed and logged-in vendor, reports it
started / authenticated / refused / skipped, and records, per vendor and
version, whether each probe was blocked.

**The exit code is not the verdict.** `cursor-agent` prints
`Authentication required` and exits `0`; a vendor that is out of quota or off
the network can do the same. An adapter that trusted the exit code would
report done, the gates would run against an untouched worktree, and the
reviewer would spend a round on nothing. So the verdict is decided by what
the CLI *said*, in `_lib.sh`, in one place for every adapter:

- the run's own output matches an unavailability signature -> `2`, whatever it exited
- the OS sandbox never started the CLI (no `started` line) -> `2`
- the exit code is one vendors use for unavailable (`2 4 41 69 75`) -> `2`
- a non-zero exit -> `1`
- exit `0` having said nothing at all -> `1`
- otherwise -> `0`

The fallback chain appends to one log, so a verdict only ever reads the bytes
its own run added - the previous vendor's auth error must not condemn the
next one.

`mock.sh` is the exception, deliberately. It has no CLI to read a verdict
from: its exit code *is* the scenario a test asked for, and putting it on
`fm_adapter_verdict` would mean a suite could not ask for "exit 0 having
said nothing" without the library overruling it. It is the only adapter
whose verdict is an input rather than a judgement, which is why the
contract test exempts it by name and checks its scripted promises instead.

`fm_vendor_chain` builds the order and `fm_run_chain` runs it, both in
`bin/fm-config.sh`, so the worker and the reviewer fall back identically.

The separation matters: if a model producing bad work looked the same as an
outage, an outage would look like the model failing and the crew would burn a
review round on nothing.

Every adapter passes `tests/adapter-contract.test.sh`. Add a vendor by adding a
file here and a line to `config.yaml`; nothing else in the system changes.

The four shipped model adapters also participate in the
[managed session contract](../../design/design.md#managed-session-defaults).
With a dispatched run identity, their launcher owns private per-attempt artifacts
under `state/runs/<actor>` in addition to the adapter's worktree/log outputs.
In Herdr this launcher creates a dedicated tab with `--no-focus` and runs the same
adapter CLI in its single owned root pane, using one canonical actor for tab, pane,
sidebar, process and durable artifacts. It verifies caller focus and tab membership;
added/shared/moved/reused or uncertain resources are retained. Checked completion
closes only the verified pane, never a whole tab unconditionally. Direct mode still injects the portable role context and retains final/exit evidence.
Codex final output and complete vendor JSON results establish final-answer
provenance; arbitrary custom adapters and the scripted mock do not inherit that
guarantee. Transport/configuration failures return 70 and are not vendor outages
or successful work. Successful CLI/adapter exit is distinct from explicit task
completion, a reviewer verdict, gates and captain acceptance.
