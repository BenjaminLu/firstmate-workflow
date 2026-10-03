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
| cursor-agent | `--trust --sandbox enabled` instead of `-f`, no `--approve-mcps` | `--trust --sandbox disabled -f` inside the outer one: with its own sandbox off, print mode approves no shell command, so the OS sandbox confines what `-f` lets through; never under the hatch |
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

**Managed Codex JSONL (T-167)** uses a narrower classifier. Only top-level
`error` and `turn.failed` diagnostic fields, plus non-JSON CLI diagnostics,
are searched for outage signatures. Model messages, instructions, tool
arguments and tool results cannot announce a provider outage. Both the classifier
and the Codex completed-turn reader frame JSONL records on LF; literal Unicode
separators within JSON strings remain payload. Launch refusal
and unavailable exit codes still return `2`; other nonzero exits and structured
failures return `1`. A failed transcript writer still fails the adapter while
the separate CLI exit receipt preserves the CLI's own outcome.

Exit `0` additionally requires a nonempty final answer from the transport's
completed-turn reader. Malformed JSON, absent finals and unfinished turns
return `1`. Classification reads only the bytes appended by this invocation,
never an existing final file or an earlier attempt's receipt. It neither
creates completion evidence nor grants any new sandbox write roots. The
transport still binds final provenance and role/task completion separately;
a completed turn with a blocked or unmarked final is not completed role work.
Legacy Codex invocations and other vendors retain the signature contract above.

`mock.sh` is the exception, deliberately. It has no CLI to read a verdict
from: its exit code *is* the scenario a test asked for, and putting it on
`fm_adapter_verdict` would mean a suite could not ask for "exit 0 having
said nothing" without the library overruling it. It is the only adapter
whose verdict is an input rather than a judgement, which is why the
contract test exempts it by name and checks its scripted promises instead.

`fm_vendor_chain` builds the order and `fm_run_chain` runs it, both in
`bin/fm-config.sh`, so worker and reviewer share the same exit-2 behavior.
`opposite-of-host` resolves from `state/session/host.json`: Claude host to
Codex worker, Codex host to Claude worker, otherwise the configured fallback
head with a logged reason. The other main vendor precedes remaining fallbacks.
Named vendors keep their configured chain; `--vendor` selects only that vendor.
The launcher records host, rule and resolved head as `vendor_resolution` in
`identity.json`; adapters receive a concrete vendor, never the rule name.

The separation matters: if a model producing bad work looked the same as an
outage, an outage would look like the model failing and the crew would burn a
review round on nothing.

Every adapter passes `tests/adapter-contract.test.sh`. Add a vendor by adding a
file here and a line to `config.yaml`; nothing else in the system changes.

**The configured model is applied, not only recorded (T-127).** `config.yaml`'s
model names (`models.<vendor>`, and the top-level, `worker.model` and
`reviewer.model`) are each one vendor's own model name. A model is named per
vendor (T-146): `fm_run_chain` in `bin/fm-config.sh` resolves, for each
attempt, the model for the vendor that attempt runs (`fm_model_for <role>
<vendor>`), so `fm-worker.sh --vendor` and a fallback get their own vendor's
model, never the head vendor's, and hands it over as `FM_MODEL`, the way
`FM_POLICY` is handed over. Each adapter passes it with its CLI's own flag - claude and
cursor-agent `--model`, codex and gemini `-m` - through `fm_adapter_model_args`
in `_lib.sh`, and refuses a round whose `FM_ADAPTER_ARGS` also names one
(`--model`, `-m`, or claude's `--fallback-model`): config.yaml is the one
place a model is chosen, and an operator argument after it would otherwise
win silently. An adapter reached with no `FM_MODEL` passes none, and the CLI
runs on whatever it defaults to.

**Before the round, where the CLI can list its models.** cursor-agent is the
one vendor of the four that can (`cursor-agent --list-models`, once it holds
a real login): `fm_adapter_model_listcheck` in `_lib.sh` runs the list
command, parses the first column of each line (`id - Name`), and refuses the
round (64) when `FM_MODEL` names none of them. It is silent - the round
starts, unrefused - when the list command cannot be run, exits non-zero, or
prints nothing (no login yet); the CLI's own answer below, at round time,
stays the final word. codex and gemini document no listing command of their
own and get no such preflight.

After the round, a model the vendor does not recognise refuses it with a
usage error, loudly, rather than running on the CLI's default:
`fm_adapter_model_refusal` reads the CLI's own words in the slice of the log
this attempt wrote - but only when the attempt's own exit code is non-zero
(a completed round, exit 0, is never read as a refusal - see below) and that
slice reports no `"model":"..."` field of its own (a report of the model
that ran means a turn happened). claude's own answer is
`[claude-code:unrecognized_model]`, matched literally; the other three have
no such fixed token documented, so they are matched against one generic
phrase list instead, shared the way `_FM_SIG` is, anchored to the start of a
line (`Error: …`) so it cannot fire on prose that merely discusses a model in
passing. Either way the adapter exits 64 before `fm_adapter_verdict` runs, so
it is never read as the vendor being unavailable (which would fall back to
the next one, quietly, on another model) nor as a normal failed attempt.
When the caller set `FM_MODEL_REFUSED` to a file path, the adapter appends
`<vendor>\t<model>\t<message>` to it, the way `FM_POLICY_BLOCKED` records a
refused host, so `fm-worker.sh` and `fm-review.sh` can raise a bilingual,
board-visible event naming the vendor and the model rather than the generic
"adapter transport/configuration failed".

The exit-code and no-evidence guards exist because a broad, unconditional
phrase list would otherwise misread a genuinely completed round - real
edits, exit 0 - whose transcript happened to contain one of its ordinary
English phrases (review round 5, T-127): an ORM/data-model/ML change, or this
codebase's own prose about the check itself, saying "an invalid model" or
"no such model found" is not the CLI refusing to start.

**What the round ran on, read from the run itself (T-127).** Every adapter is
asked for JSON output (`--output-format json` for claude, cursor-agent and
gemini; `--json` for codex, alongside its own `--output-format` for the final
answer), unconditionally, whether or not a managed attempt reads the final
answer from it: it is also how the model the CLI actually used comes back.
`fm_vendor_model` in `bin/fm-config.sh` reads it in each vendor's recorded
shape. claude's `--output-format json` result carries no `"model"` field -
T-127 assumed it did, and recorded `unknown` for every claude round (T-146) -
but names the models the run used as the keys of `modelUsage`: the key the
round asked for when it is among them, otherwise the one with the most output
tokens, since claude runs a small model on the side. Before any result,
claude's stream `init` event names it. For the other vendors the *last*
literal `"model":"..."` field wins, so a later report in the same run - a
fallback model the CLI itself chose - wins over an earlier one. Empty when
the transcript says nothing, which the caller records as `unknown`, never a
guess. Per vendor, where the model comes from:

| vendor | where the model appears |
|---|---|
| claude | `--output-format json`'s result message: the keys of `modelUsage`, `{"type":"result",...,"modelUsage":{"claude-opus-5-5":{...}}}`; before any result, the stream's `init` event, `{"type":"system","subtype":"init","model":"claude-opus-5-5",...}` |
| codex | `--json`'s event stream: a `token_count` or `turn_completed` event carrying `"model":"..."` |
| cursor-agent | `--output-format json`'s result object: `{"type":"result",...,"model":"...",...}` |
| gemini | `--output-format json`'s result object: `{"response":"...","stats":{...},"model":"..."}` |

`fm_vendor_cli_version` reads the CLI's own version directly (`<cmd>
--version`, first line), never out of a transcript that may say nothing of
it; missing or silent is `unknown`. Both are recorded in `identity.json`
(`bin/fm-herdr.py record-model`), in the crew payloads `fm-worker.sh` and
`fm-review.sh` emit, and in `bin/fm-canary.sh`'s report, beside
`model_requested` (config's) and `model_mismatch` (true only when both are
known and differ).

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

### Codex run reviews (T-163)

Codex's run-review marker is admission to the vendor chain only. Execution
requires the managed transport's invocation record, matching reviewer identity,
an absolute fresh clone with its own `.git`, no remote, and the pinned head and
base refs. The launcher pins head/base/patch before cloning and uses those same
commits on recovery. Extra adapter arguments and the unsandboxed escape hatch
are refused for Codex run reviews.

The outer OS sandbox remains mandatory on macOS and Linux. The checkout and
round temp are the only writable roots; the checkout's `.git` is read-only,
repository `.codex` configuration is hidden, and Codex's project-document loading
is disabled. Model selection and the isolated login copy use the existing paths.
Transport records and final answers are outside model write roots.

The trusted transport reads `codex exec --json`: only the last completed
`agent_message` of a completed turn supplies the final answer. Tool output and
failed or unfinished turns supply none. It records the answer digest, provenance,
identity, chain attempt and review context. The review consumer requires that
binding, a standalone verdict and the final completion marker, and never falls
back to transcript or output-directory bytes for Codex. A CLI-written final file
is not reviewer evidence. Cleanup consults managed execution locks as well as
the launcher's owner lock; live or uncertain descendants retain their checkout.

Mocks exercise this contract but do not prove confinement or real CLI output
compatibility. Before acceptance, firstmate must run CI/gates, the real macOS
sandbox canary and a stock Codex run review through a verified immutable candidate
snapshot, recording authentication/start, checkout/head, denied access, final
provenance and cleanup. This change needs independent bootstrap review before
it can supply reviews for other changes; no fake approval, unsandboxed review or
silent Claude fallback resolves that dependency.

### Complete pinned round inputs (T-173)

Worker and reviewer launchers export `FM_PINNED_DIR`, an absolute path to their
own run's `pinned/` directory. The shared OS sandbox exposes exactly this folder
read-only after its state denials; adapters must preserve this environment
variable and must not grant the parent run or project directory. This applies
through `fm-sandbox.sh` to Claude, Codex, Cursor and Gemini alike. The mock is a
fixed file-writing fixture, with no model or arbitrary command execution.
The prompt indexes the files, their hashes, pin version and design anchors.
Files must be regular (no symlinks) and mode 0444. The folder must belong to
the current user and must not be writable by group or others; 0755 is valid
and allows launcher cleanup. The sandbox denies round writes regardless of
the owner's directory write bit. `spec.json` is required; `design.md`,
`contract.yaml` and `CONVENTIONS.md` are each optional for legacy inputs.
Missing folders, invalid ownership or permissions, and unexpected entries
refuse sandbox profile creation.

The sandbox launcher's Python lives in `bin/lib/fm_sandbox_policy.py`,
`fm_sandbox_forward.py` and `fm_sandbox_loopback.py` (T-177). Partial engine
copies must include these files beside `fm-sandbox.sh`; copies that launch
reviews also need `fm_review_runtime.py`. Copying the complete `bin/lib/`
directory, as managed snapshots and the shared round fixtures do, includes
them. The forwarding and loopback modules execute inside the sandbox from
source passed as an argument to a short loader, compiled with their module
filename. This requires no engine-directory read grant and no writable helper
copy. Arguments, policy and profile output retain their existing contracts.
