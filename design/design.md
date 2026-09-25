# firstmate-workflow — design

> This is the single source of truth. `bin/fm-dispatch.sh` reads the task DAG
> from `design/tasks/`, one file per task; section 14 says how to print it and
> CI fails if it is not a sound DAG.
>
> **Language:** everything in this repository is written in English — this
> document, the skills, the code and its comments, commit messages, pull
> request bodies and reviews. The board's three locales are the one exception,
> and they are a product feature (section 9).

---

## 1. What this is

One agent, firstmate, runs a crew of other agents through software work. Three
things make it up:

1. **`skills/`** — the content. Every role's behaviour is plain Markdown.
   Changing a skill changes behaviour without touching code.
2. **`bin/fm-*.sh`** — the law. Acceptance reads the filesystem and exit codes.
   It never reads what a model claims about its own work.
3. **`board/`** — the captain's only console. Live state, open decisions,
   orders.

The agent CLI is a **replaceable engine**, not the system.

### What it is not

- Not an auto-merge bot. A human always presses merge.
- Not an agent that improves itself in place. Changes to `skills/` travel the
  same pull request and the same seven gates as any other code.
- Not snapshot-based. The event log is the truth (section 5.1).

---

## 2. Standing rules

These bind every actor, including firstmate itself.

1. **Nobody writes to `main` or `master`.** Work happens on a branch and
   arrives through a pull request. Enforced in three layers: `bin/fm-guard.sh`
   for the scripts, the hooks in `.githooks/` for anything driving git
   directly, and branch protection on GitHub with `enforce_admins` on — because
   firstmate runs on the captain's own credentials, an admin exemption would be
   an exemption for firstmate too. Branch protection is the authority; the
   hooks are an early warning: they refuse only a commit made on a protected
   branch and a push to one — not a commit on a detached HEAD, where
   `fm-worker.sh` rebuilds (T-093).
2. **English in the repository**, as stated above.
3. **Merging is the captain's**, and it arrives as a decision card on the
   board — never as a sentence in a conversation (section 5.2).
4. **An agent never runs `git` or `gh`.** The scripts do that (section 5.3).
5. **A review finding is a class, not an instance.** The worker sweeps the
   repository for every occurrence of the kind of problem named and fixes them
   in one round, and reports the search it used and the count it found. Fixing
   one instance per round is what turns a three-round review into a nine-round
   one, and it is the single most expensive habit this system can develop.

---

## 3. Settled decisions

| # | Decision | Outcome |
|---|---|---|
| Q0 | Where it lives | A new repository; nothing reused from earlier projects |
| Q1 | Execution substrate | Shell starts an independent agent process, one git worktree per task |
| Q2 | Shape of firstmate | A long-running session, with the board as a second input channel |
| Q3 | Source of truth | Local append-only `state/events.jsonl`; GitHub is the outward face |
| Q4 | Board to firstmate | Decision lands as a file; firstmate blocks on it (bun `fs.watch`, polling fallback) |
| Q5 | Board stack | Bun + SSE + vanilla HTML, no build step |
| Q6 | Where determinism ends | Scripts decide whether it ran; models only judge whether it is right |
| Q7 | Round three | `ASK-PASS-CRITERIA` plus a numbered, closed checklist |
| Q8 | Diagram scope | Only decisions the captain must rule on; reuse existing diagrams first |
| Q9 | Where pull requests live | `BenjaminLu/firstmate-workflow`, public so branch protection is available; under Q10 a task's pull request lives on its project's repository |
| Q10 | Which repositories firstmate drives | D-049, option B: one external installation — this repository holds the engine, every project's design and task list, and all runtime state, and drives registered target repositories that carry none of it (section 15) |
| R1 | Self-update | Skills define behaviour; writing them back travels a full pull request; external skills import read-only |
| R2 | What the reviewer sees | The diff, the task spec and the acceptance criteria, plus, given the pull request, the head's SHA, required check and gate summary (section 7) — never the worker's reasoning |
| R3 | Granularity | One task, one pull request, one worktree; `depends_on` forms a DAG; three in flight |
| R4 | Branching | Every task branches from `main` and targets `main`; the worker rebases its own conflicts |
| R5 | Writing the log | Only through `bin/fm-emit.sh` |
| R6 | Opening a file | `/open` hands it to the editor — localhost only, path must resolve inside the repo — plus a read-only viewer |
| R7 | CI | The local gate and GitHub Actions run the same `bin/ci.sh` |
| R8 | Recovery | Replay the event log, then reconcile on start |
| R9 | Hot reload | SSE pushes `reload` to the front end; `bun --watch` restarts the server |
| I1 | Dynamic board content | Agents write the tri-lingual payload at emit time |
| I2 | Where the three come from | Agents produce `en` and `zh-TW`; `zh-CN` is a table conversion |
| I3 | Language preference | `localStorage`, overridable with `?lang=`, default `zh-TW` |
| I4 | Diagram languages | `.en.html` and `.zh-TW.html`; `zh-CN` post-processed |
| I5 | e2e languages | Chrome snapshots in all three; interaction flows in `zh-TW` only |
| I6 | Working language | **Superseded.** Everything in the repository is English; only the board is tri-lingual |
| I7 | Source text on the board | The board shows the agent's tri-lingual summary plus a link to the pull request |
| V1 | Vendor abstraction | A shell adapter contract |
| V2 | Vendor per role | One vendor for the crew, with an optional reviewer override |
| V3 | Capability gaps | Adapters only produce file changes; the scripts do all git and gh |
| V4 | Prompt portability | Skills are plain Markdown; adapters translate; a lint blocks vendor-specific syntax |
| V5 | Proving portability | A `mock` adapter runs every e2e, plus one shared adapter contract test |
| V6 | Failure semantics | Exit 0 done, 1 attempted and failed, 2 vendor unavailable — only 2 falls back |
| V7 | What the board shows | The engine in the header, marked when the reviewer differs |
| V8 | Adversarial review | Information asymmetry, an opposed skill, and optionally a different vendor |

---

## 4. Roles

| Role | Shape | Lifetime | Touches git? |
|---|---|---|---|
| **captain** (you) | human | — | presses merge only |
| **firstmate** | long-running interactive session | always on | no |
| **worker** | independent process from `bin/adapters/<vendor>.sh` | one task, then gone | **no** |
| **reviewer** | same, independent process | one round, then gone | **no** |
| **board** | `bun --watch board/server.ts` | always on | no |

The portable [root router](../AGENTS.md) selects the canonical
[firstmate startup contract](../skills/firstmate/SKILL.md) immediately for
interactive sessions and preserves explicitly dispatched roles. The thin
[Claude entrypoint](../CLAUDE.md) imports the same router; Codex loads it directly.
[Worker](../skills/worker/SKILL.md) and [reviewer](../skills/reviewer/SKILL.md)
skills remain the dispatched role sources. Supply isolated reviewers with their
role and authoritative relevant design context in the prompt.

The startup contract specifies state inspection, board opening, visible managed
panes, retained authorization and explicit remediation coordination. It documents
current script gaps rather than promising unmerged reconciliation or runtime
transport. `fm-run.sh` reports failed gates; firstmate must coordinate subsequent
worker attempts. Static instruction validation does not prove agent behavior.
Neither lavish nor no-mistakes is a prerequisite; do not add their startup or
verification hooks. Use repository checks and actual GitHub CI evidence.

Workers and reviewers are stateless one-shot processes: read a prompt, change
files inside their own worktree, exit. Everything else — commit, push,
`gh pr create`, posting comments — is done by `bin/fm-*.sh`.

firstmate writes no code. It dispatches, it summarises, it puts decisions on
the board, and it waits for the captain.

---

## 5. Contracts

### 5.1 The event log, `state/events.jsonl`

Append-only. **Only `bin/fm-emit.sh` writes to it**, serialising with a `mkdir`
lock — `flock(1)` does not ship on macOS. `bin/ci.sh` fails if anything under
`bin/` or `board/` appends to the log directly.

```jsonc
{"ts":"2026-09-20T14:10:02Z","actor":"worker-2","task":"T-004","type":"gate_failed",
 "pr":9,"data":{"gate":5},
 "summary":{"en":"...","zh-TW":"..."}}
```

Types: `greenlit` `dispatched` `commit_pushed` `pr_opened` `gate_passed`
`gate_failed` `review_opened` `review_failed` `ask_pass_criteria`
`criteria_returned` `protocol_violation` `approved` `merged` `closed`
`decision_requested` `decision_made` `worker_crashed` `vendor_unavailable`
`agent_finished` `crew_status` `parked` `unparked` `spec_pinned`
`spec_repinned`.

An event may carry a top-level `project`, written by `fm-emit.sh --project`
and checked against the registry (an unknown name exits `65`). An event
without it belongs to the default project, so every line written before
projects existed stays valid (section 15.4). `spec_pinned` and
`spec_repinned` record a task's spec pin and its re-pin (section 15.5).

`parked` and `unparked` are the captain setting untouched work aside and
bringing it back (T-058); the last of the two for a task is the one that
counts. A task the captain drops is the existing `closed`. All three are
written by the board with actor `captain`; see §8, *Park and drop*.

`dispatched` and `agent_finished` bracket one run of one agent, and they
are what the board reads to decide who is aboard. An agent is running from
the first to the second; a run that ends any other way — killed, hung up —
still emits the second, from a trap. Without the closing one, "aboard"
degenerates into "ever touched a task that is not finished yet", and the
ship's crew becomes a record of everything that ever ran rather than of
what is running. Every script that emits under an actor of its own must
emit it; `tests/traps.test.sh` fails if one does not.

A `summary` carries `en` and `zh-TW` or it is rejected: half a translation
renders blank in one of the board's locales, which is worse than none.
`zh-CN` is derived at display time from `i18n/tw2cn.tsv` — a table lookup, no
model call.

Worker and reviewer lifecycle events retain the exact canonical run identity in
`actor` and state their role, the same canonical value as `data.crew_name`, and
an authored `data.activity` object with nonblank `en` and `zh-TW`. A task's valid
authored activity is preserved verbatim. A task without it receives the explicit
generic unavailable description; producers do not translate a scalar title or
invent task-specific progress. The board derives `zh-CN` through its existing
table semantics.

`review_failed` distinguishes a review verdict from a failed review attempt.
Only a completed signed rejection carries
`data.review_outcome: "rejected"`; that exact value is the authoritative reject
handoff. Missing or unsigned output uses `missing_review` when truthful, and
vendor/configuration/execution failure uses `infrastructure_error`. Consumers
must never treat an absent, legacy, or different value (including a generic
`data.outcome`) as a substantive rejection. Final-answer provenance remains the
adapter contract: built-in adapters retain extracted final output, while custom
adapters retain their documented combined-output limitation.

### 5.2 Captain decisions, `state/decisions/D-*.json`

`bin/fm-decide.sh --request <id>` writes a pending card, attempts its diagram
and returns without waiting. The board POST writes the response file;
`bin/fm-decide.sh --await <id>` waits for that file and returns its contents.
Receiving a response is not itself approval; inspect the chosen option and context.

```jsonc
{"id":"D-007","task":"T-004","kind":"choice","chosen":"B","note":"leave the schema alone","ts":"..."}
```

Two kinds. `choice` is an option card carrying a before/after diagram. **`merge`
is a request to merge**, carrying the seven-gate checklist, the diff stat, the
files touched and the pull request link, answered with merge, send back, or
hold. **Every merge goes through a card.** firstmate may not merge on its own
and may not ask for one in conversation.

Selecting an option is local; a separate CONFIRM submits it. A fourth custom
choice carries the captain's own bounded text,
stored as data under the distinct `chosen` value `custom`, not a note on
option A. Nothing is selected initially; selecting or typing performs no write.
Confirmation validates nonempty text and limits before storing the decision.
Custom text is escaped for display, preserved through the watch/storage path,
and never evaluated as shell input or treated as merge approval. The interface
localizes its labels and validation, not the captain's authored words. The
`text` field preserves literal whitespace, markup and Unicode, with a maximum
of 1000 Unicode code points; empty/whitespace-only input, control characters
other than tabs/newlines, and lone surrogates are rejected. Custom never calls
the merge helper. A/B/C keep their existing meanings.

New requests require `--details <file>` with this shared data contract:
`{en: Locale, "zh-TW": Locale}`, where each Locale contains nonempty strings
`title`, `explanation`, `before`, `after`, `outcome`, and `options.A/B/C`, each
with `description`, `pros`, `cons`. Each string is bounded to 2000 code points.
Firstmate authors both locales; the scripts do not infer them from task titles.
The board escapes data as text, diagrams use the authored before/after labels,
and zh-CN applies the same ordered TW-to-CN table as the UI. Invalid requests
fail before a pending record is written; existing IDs cannot be replaced.
Legacy scalar records remain readable with an explicit missing-details notice.
Trusted repository diagram fragments are assets, never fields in this input.

A new card's id names its owner, `D-<project>-<task>-<n>`, and is allocated by
`fm-decide.sh --allocate` before the card is requested (section 15.4).
`fm-run.sh` consumes `state/decision-details/<id>.json` after gates pass,
under the id it allocated for the task's merge card and names when details are
missing; a later turn reuses that id rather than taking another. Missing or
invalid authored input is reported as no card created. Only a successful
request is announced as asking the captain.

**Only a decision request rings (T-096).** A card the captain must answer can
sit unseen while the captain is not looking at the board, so inside Herdr
(`HERDR_ENV=1`, which Herdr exports and its own `herdr --skill` tests for) a
successful `fm-decide.sh --request`, of any kind, merge included, calls
`herdr notification show` once: the title names the project, the task and
the kind, the body is the card's one-line question in the captain's
language, `zh-TW`, the board's default locale (I3; the board's own choice
lives in `localStorage`, where no script can read it), and the sound is
`request`. The project is the one the card is filed under: the project it
records, else, as the board reads a card that records none, `default_project`,
else the self project. `FM_PROJECT` matters only through the card it chose.
A marker under
`state/runtime/notified/` makes it one per id, ever; an answered or withdrawn
card is never announced, and awaiting or answering one rings nothing.
`config.yaml`'s `notifications.herdr: false` turns it off and
`notifications.sound: false` sends `--sound none`; both default to true when
the keys are absent. The keys are read in a subshell, so the reader cannot
change the request's options or variables. A `config.yaml` whose reader
(`bin/fm-config.sh`) is missing fails closed: it rings nothing and says so,
because a `herdr: false` nobody could read still counts. Like the diagram,
it is decoration on the request. A `herdr` that fails, a Herdr with no
`herdr` command, and a `herdr` that has not answered after 10 seconds
(`FM_NOTIFY_SECONDS`) are each reported on standard error. The last is
reported as a timeout. In every case the card is still requested and the
request still exits 0. Outside Herdr nothing is called and nothing is written,
not even the marker directory. The tests' Herdr stub answers only what
herdr 0.8.0 was captured answering: a call, a refused sound (exit 2), no
server (exit 1).

Nothing else notifies. CI turning red, a worker blocking or crashing, a review
rejecting, a protocol violation: those are crew weather, and the board shows
them. Each is either handled by firstmate or ends in a decision card, and that
card is what rings. A sound for every event would teach the captain to ignore
the sound, and then the one that needs an answer is missed too.

The board atomically publishes a response, invokes `fm-emit.sh` once with
`decision_made` and `data.decision`, then handles any authorized A merge.
Awaiters only observe the record; they do not emit a second event. Repeating
the same response returns the stored outcome, while a conflicting response
is rejected. Failed merges are recorded and never automatically retried.

**The merge runs after the response, not inside it** (section 15.10 point 3;
the board implements it in T-054). For choice A on a merge card the board
first checks the card's project: if a merge in that project is already
running it refuses with `409`, publishes nothing and leaves the card pending.
Otherwise it publishes the response with `merge: "running"`, emits
`decision_made`, starts `fm-merge.sh --project` in the background under the
project's merge marker, and answers the POST at once. When the helper exits,
the board rewrites the stored record's `merge` to `"merged"` or to
`"failed"` with the helper's reason, and removes the marker; `fm-merge.sh`
still emits `merged` itself. The outcome is recorded in the decision record,
not in the POST's response; a failed merge is recorded and never retried,
exactly as before. Repeating the same response returns the stored record with
whatever `merge` it holds by then.

**A `running` merge whose outcome was never written is recovered by the
board.** The board is the only writer of `merge`, so it is the one that
repairs it; `fm-reconcile.sh` does not touch decision records. The helper is
started detached, and the project's merge marker records the decision id,
the helper's pid and its start time. On start, and again on every poll while
any record says `running`, the board reads each such record's marker:

- if that pid is alive and is still the helper it started (same start time),
  the merge is still going: the board leaves the record `running` and waits
  for that pid to exit, then reads the outcome as below;
- otherwise the helper is gone without a word, and the outcome is read, never
  guessed: a `merged` event in the log for the card's `(project, pr)` after
  the response makes it `merged`; failing that, `gh pr view --repo <the
  project's github> <pr> --json state` saying `MERGED` makes it `merged`
  (and `fm-reconcile.sh` repairs the missing event from GitHub, as it already
  does); `OPEN` or `CLOSED` makes it `failed` with the reason "the merge
  helper stopped before recording an outcome", never retried;
- if GitHub cannot be read, the record stays `running` and the board shows
  the card as "merge outcome unknown" by name; the project's turn stays held,
  because freeing it on a guess could card a branch against a `base` that has
  already moved. The next poll tries again.

A board that is down starts no merges, so a turn held while it is down holds
back nothing that could have run.

Await mode uses `bun run bin/watch-decisions.ts` (`fs.watch`) when bun and the
watcher script are present, and a one-second poll otherwise. Wake latency must
be measured, not inferred from the watcher mechanism. **No `fswatch` dependency.**

These are orchestration requirements, not enforcement inside `fm-merge.sh`.
The board calls that helper for choice A on a pending merge card. The helper
checks PR state and invokes GitHub merge, then attempts event emission and
cleanup; it does not read approval decisions or run the seven gates. The board
route does not rerun gates either. Firstmate must verify current-head gates, CI,
reviewer provenance and board approval, and coordinate fresh verification when
the head changes so a stale card is not treated as ready. `fm-run.sh` requests
cards after gate success; it neither awaits decisions nor performs merges.

### 5.2a Worktrees, and the one root they live under

Every worktree lives under `state/worktrees/<task-id>` — one root, inside the
repository, so the whole system is self-contained and nothing it creates ever
lands in a shared directory somewhere else on the machine.

That root is also what makes cleanup safe to automate. After a task's pull
request merges, `bin/fm-cleanup.sh` removes that task's worktree and only that
one. It refuses anything that does not resolve to a **direct child of the root**
— a path reaching out through `..`, a symlink pointing elsewhere, the
repository root itself, the main worktree, a worktree belonging to another
repository. A script that deletes directories has to be boring about which
ones, and the check is on the resolved path rather than the string it was
handed.

It also refuses while the pull request is still open. An unmerged branch is
someone's unfinished work.

### 5.3 The adapter contract, `bin/adapters/<vendor>.sh`

```
usage:   <vendor>.sh run <prompt-file> <worktree-dir> <log-file>
does:    hands the prompt to that vendor's CLI and lets it edit files in <worktree-dir>
must not: run git or gh; write anywhere outside <worktree-dir>
exits:   0  done
         1  ran, but did not achieve it (the model gave up, the output is unfit)
         2  vendor unavailable (not logged in, out of quota, network down)
```

Only `2` triggers the fallback list in `config.yaml`; `1` proceeds to the gates
and the reviewer like any other attempt. Every adapter passes
`tests/adapter-contract.test.sh`.

**The exit code is not the verdict.** A vendor can print `Authentication
required` and exit `0` — `cursor-agent` does. So what the run *said* decides
first, and one function decides it for every adapter (`bin/adapters/_lib.sh`):
an unavailability signature in the run's own output is a `2` whatever the exit
code was; exit `0` having said nothing at all is a `1`. Because the fallback
chain appends to one log, a verdict only reads the bytes its own run added.

`fm_vendor_chain <role>` builds the order and `fm_run_chain` runs it, both in
`bin/fm-config.sh`, so the worker and the reviewer fall back identically. Each
role may name its own engine — `reviewer:` and `worker:` blocks in
`config.yaml` — and whichever it names leads a chain that continues through
`fallback:`, with no vendor run twice. A reviewer whose engine is down is
therefore not a reviewer who never ran.

The reviewer's `vendor` and `model` are the captain's choice (T-066); this
repository names `claude` and `opus-5`, the worker's own. A project naming
neither is reported by `fm-session.sh start` and firstmate asks the captain
through a choice card; the answer lands as a `config.yaml` pull request.

`reviewer: mode:` sets how a review runs. `diff`, the default for a project
that declares nothing, is the prompt above and nothing else. `run` makes a
fresh clone of the pull request head under the system temp directory - never a
worktree, whose shared `.git` would let git inside it write outside it - with
the base at `fm/base`, the head at `fm/head` and no remote, and removes it
from the EXIT trap on every exit the shell handles; a SIGKILL runs no trap,
so the next run-mode round removes any `fm-review.*` checkout whose owning
process is gone. The prompt adds the branch's own
project contract and asks for `setup`, `check`, the touched suites, fail-first
against the base versions of the changed non-test files, and an **Executed**
/ **Read, not run** account. The adapter, not the prompt, confines the engine:
`FM_RUN_REVIEW=1` and `FM_REVIEW_CHECKOUT` tell it the round is a run-mode one,
and only an adapter carrying a `# fm:review-run` line may take it -
`fm_review_run_chain` drops the others from the chain, refuses a head that
lacks it with `65`, and `fm_adapter_context` refuses one before its CLI
starts. `claude` carries it. `--restricted`, `--strict-mcp-config` and
`--disable-slash-commands` load no user, project or local settings, MCP
servers or skills - the clone is the branch under review, and its `.claude/`
would otherwise add hooks and rules to the round - so only the adapter's
`--settings` and managed policy apply: `dontAsk`, file tools only in the clone
and the temp directory, shell commands only inside the sandbox, whose network
reaches only the hosts `reviewer: network:` declares for `setup`. Those are
plain domain names, and never one GitHub operates (`github.com`,
`github.io`, `github.dev`, `githubusercontent.com`, `githubassets.com`,
`githubapp.com`, `githubcopilot.com`, `ghcr.io`, `ghe.com` or any subdomain,
in any case) nor a wildcard, which could match one. One rule in
`bin/adapters/_lib.sh` (`fm_review_host_refusal`) decides it: `fm-review.sh`
refuses such a list with `65` before anything is built, and
`fm_adapter_context` refuses it with `64` before any CLI starts, however the
adapter was reached. The declared commands write their caches under
`$HOME` by default, where the sandbox refuses them, so the round exports
`XDG_CACHE_HOME`, `BUN_INSTALL_CACHE_DIR`, `PLAYWRIGHT_BROWSERS_PATH` and
`npm_config_cache` into its own temp directory; `setup` downloads afresh each
round. The engine starts without the launcher's `FM_*`, `HERDR_*`, `GIT_*`
and GitHub-token variables: `fm_identity` exports `FM_ROOT` at the task's
repository, and the clone's scripts choose their tree from it, so a `check`
the reviewer ran would otherwise gate another tree than the head under review.
The reviewer has no GitHub access at all, and needs none: it judges the head
by running it, so a run-mode round fetches no CI, no gate results and no pull
request state for it, and its prompt carries neither T-088's head section nor
any other CI listing (captain, 2026-09-25). CI and the gates are firstmate's
merge gate in both modes (§6, the merge double check). The only thing it
still reads from GitHub is the closed-list protocol's comments (§7), which
are not evidence about the head. What stops a push is the
missing remote and the unreachable GitHub; the deny list for push, gh writes
and raw HTTP matches a literal command prefix and is only a second guard.
Both modes emit `review_opened` and
`approved` or `review_failed` as the reviewer; `fm-review.sh` posts the verdict.

A round that produced no review exits `3` and emits `review_failed` with
`data.review_outcome` set to `missing_review` when an attempt completed without
a signed verdict, or `infrastructure_error` for vendor/configuration/execution
failure; it never reaches the pull request and never counts toward gate 7. A
verdict has to
carry exactly one unquoted `APPROVE:<task>` or `REJECT:<task>` in the final
assistant answer. Only that answer is the verdict; prompt echoes, intermediate
text, quoted examples and full CLI transcripts are not authoritative. Retain
reviewer identity and the reviewed head with the evidence. Built-in managed
adapters extract and retain the final answer. Custom adapters and the current
review launcher still scan combined output and do not establish final-answer
provenance; firstmate must identify and coordinate that gap rather than accept
a marker as proof.
The board therefore treats a legacy `review_failed` as missing-review/error,
not rejection. A directed rejection exists only when the event also carries
the additive `data.review_outcome: "rejected"` contract. T-035 owns emitting
that datum after it has authoritative final-answer evidence; old logs remain
truthful without it. Crew phase follows each actor's dispatched role, so a
reviewer is reviewing even while a worker on the same task has another phase.

The judgement about outages can never be right on wording alone, because
there is no phrase a model cannot write — this repository contains
"Authentication required" in two files, so any review of it quotes them. So
wording does not decide. The adapter is deliberately generous, and the caller
settles it: `fm_run_chain` takes a predicate answering *did this run produce
work?*, and work beats a signature. A worker asks whether the worktree
changed; the current reviewer predicate asks whether combined output carries a
verdict marker, a known gap from the final-answer contract above. Being
over-eager then costs one more vendor attempt and never the work — and a
proven final signed review is never thrown away, which would otherwise repeat the same
round forever with a reassuring message on it.

A vendor named at the head of the chain with no adapter behind it is a typo,
not an outage. It is caught before anything runs and exits `65`, so a human
fixes the configuration — and so the exit cannot throw away work a fallback
vendor had already done. A *fallback* entry with no adapter is simply
skipped.

An exit code never overrules produced work, in the callers any more than in
the adapters: a proven final signed review remains a review even on teardown failure,
and a changed worktree is work. And each attempt reads only its own output —
its own directory under the chain's, and its own slice of the shared log —
so a vendor that dies half way through cannot sign on the next one's behalf.

### 5.3.1 Every script refuses the same way

`shift 2` with one argument left does not shift. It returns 1 and leaves
`$@` alone, so `while [ $# -gt 0 ]` spins on the same flag for ever —
`bin/fm-emit.sh --type` was a busy loop rather than an error, in eleven
scripts at once. (T-016 had already found it in `fm-diagram`, one script
at a time, before it was known to be in all of them.) Every flag that
takes a value checks before it shifts, and exits `64`, which is what a
caller reads as "you called it wrong". Precisely: the check comes before
the `shift 2` **in the same `case` branch** — on a line of its own is
fine, in the branch above is not, and after the shift is not a check at
all, because by then the argument it was looking for is gone. That is
the whole of the rule here. Every OTHER kind of usage error exits `64`
too, in every script: T-029 converted the last one, `bin/fm-guard.sh`'s
unknown subcommand, which exited `2`.

No count belongs in this paragraph. How many scripts have an option
loop, how many carry a local copy of the guard, how many take it from
`bin/fm-config.sh`, and which files are exempt from the rule because
they hold it, are all pinned in `tests/option-loop.test.sh`, where a
number that stops being true turns the gate red; a number written here
would only ever be true on the day it was typed. The two halves have to
add up to the corpus, so a script cannot quietly leave one set without
joining the other.
`bin/ci.sh` fails on a `shift 2` that has not checked, and
`tests/option-loop.test.sh` runs every flag of every script with nothing
after it — under an alarm, because a test for a hang that simply calls the
script hangs the gate instead of failing it. Both read the same corpus
and the same idea of what a comment is, out of `bin/fm-config.sh`: the
suite exists to catch the gate missing a script, and a suite carrying
its own copy of the rule is a check that agrees with itself.

### 5.3.2 A later round has to know it is one

A worker asks GitHub for its branch's pull request before it builds the
prompt, not after the engine has run. The number is what makes a later
round a later round: the prompt carries what review has said and why the
required check is red, and `.fm-say.md` — the worker's one way to speak,
since it may not touch `gh` — has somewhere to go. Looked up afterwards,
a round dispatched from a task id alone was a first round wearing its
clothes. It rewrote what it had already written, and the question it
asked was dropped in silence; the run said `its question is on #`, with
nothing after the hash.

`fm-dispatch` cannot help: a task whose pull request is open counts as
in flight and is never restarted, and once it is settled it is merged or
closed and is not restarted either. There is no path through the
dispatcher that starts a task with a number to hand it, so the worker
finding its own is the only path there can be, and
`tests/dispatch.test.sh` asserts that rather than the design asserting
it.

What the worker is shown of a red check is the whole of its view of the
runner — it does not run `gh`, by the adapter contract — so that block
is never allowed to be empty. A check's link is
`…/actions/runs/<run>/job/<job>`, and the run is the part before the
job: reading the whole tail of it asked `gh run view` for something it
refuses, its complaint went to `/dev/null`, and the worker was handed a
blank block. The shape is checked rather than assumed — a required
check need not be an Actions run at all, and both shapes GitHub itself
uses count — `/actions/runs/<run>/job/<job>` and the older check-run
`/runs/<job>`. The legacy ID identifies a job, so it is passed to
`gh run view --job <job> --log-failed`; a modern link uses
`gh run view <run> --log-failed`. These IDs are different namespaces.
A blank block reads as a green run, so the round was
spent asking why the check was red.

The run or job id is the leading run of digits after `/runs/`, and what
follows it has to be a delimiter — the legacy url is served with a
query on that segment, and trimming at the next slash turned
`6789123?check_suite_focus=true` into something the digit check then
rejected. Query strings and fragments are stripped in either shape;
letters immediately after the digits are rejected. Fetch failures,
empty logs, and partial logs name the run or job actually requested.

The block is never blank, and it says which of four things happened,
because to the worker they mean different things: no run id could be
read out of the link, so the log is not something this script can
fetch; the fetch failed, and here is what `gh` said; or the fetch
succeeded and the run had no failing step log at all — a cancelled
run, or a job that died before anything logged — which "could not be
fetched" would misreport as GitHub's fault; or some of it came back
and `gh` failed anyway, a multi-job run with one job's log gone, where
the partial log is shown AND said to be partial. A partial log alone
reads as the whole of the failure. The first of those says
what the SCRIPT could not do rather than what the check is: it knows
it found no run id, and it does not know which CI produced the link.

Emptiness is decided on what reaches the fence rather than on what
`gh` returned — a log whose every line the column trim reduces to
nothing is not an empty capture, and it is an empty block — but the
filter that decides is not the thing printed, or every blank line
inside a traceback would be deleted on the way. Everything spliced
into that fence is bounded, `gh`'s complaints included.

The lookup keeps GitHub's exit status, because *no open pull request*
and *`gh` did not answer* are the same empty string and opposite
instructions. Answered-and-none is an ordinary state — a round that
pushed and then died before opening one leaves exactly that — and the
round carries on and opens it. Could-not-answer stops the run at `74`,
before the engine: the prompt would carry no review, and the push would
collide with a pull request nobody looked for. Both halves are in
`tests/worker.test.sh`, one asserting that the engine did not run and
one that it did.

Asking is the whole of a round that begins with a question, so a
question that could not be posted is a failed run — exit `73`, a
`worker_crashed` carrying the pull request number, and the text copied
to `state/unsent/`. Not left in the worktree: the next round removes
and recreates that from the branch, so a file kept where it was written
is gone as soon as anything runs again. `state/unsent/` sits beside
`state/rescued/`, which is where an interrupted run's files go — same
idea, different thing saved: one is work, the other is a message.
Nothing reaps either. They are under `state/`, which is not in the
repository, and a directory of questions nobody could post is a thing
to read rather than a thing to garbage-collect; the names carry the
task, a UTC stamp and the pid, so two failures in the same second do
not overwrite each other. (That recreation is also what
makes `.fm-say.md` a signal from the current round and not a stale one
from an earlier failure.) It used to be a line on standard error and an
exit 0: the reviewer waited for a question it would never see, the next
round asked it again, and the board showed a round that went fine.

This does not unstick the task, and the design should not claim it
does. Nothing reads `worker_crashed` and acts on it, and a task whose
pull request is open is not one the dispatcher restarts, so the round
still ends with a reviewer waiting. What changes is that the run no
longer says it went well: the failure is on the board, under the pull
request it happened on, with the text kept where the next round will
not delete it. Something that picks it up is its own task.

Nothing reads the worker's exit status either. `fm-dispatch` starts it
with `&` and never waits, so `73` is read by a person, and the one
event the round writes is the one the worker writes — there is no
second `worker_crashed` from a caller noticing the code. The codes a
worker can exit with are `1` a failed attempt, `2` no vendor was
available, `64` it was called wrong, `65` no such task in
`design/tasks/` or an unknown configured adapter, `70` something the run
needs and cannot have — no library, no worktree, nowhere to put a scratch file,
identity/snapshot failure, a live task lock, failed managed transport, a
round's commit that failed (nothing is pushed or reported after it), a new
script whose executable bit could not be set before it, or a
rebuild on the base that could not be made —
`71` the push failed — a rebuilt branch's lease refused included — `72` no
pull request number came back, `73` the worker had
something to say and there was nowhere to put it, `74` GitHub could not
say which pull request the branch has, `75` a rebuilt round was refused
before its commit — a conflict marker left, a conflict with no markers left
exactly as the merge left it, a HEAD no longer on the rebuild base, or the
task's own entry or table row not as the previous head had it — and nothing
was published, and `130`, `143` — a signal, 128
plus its number, from the INT/TERM traps that make a killed run stop
rather than carry on. `SIGHUP` is ignored (same as `fm-config.sh`) so a
managed transport wait and PR publish survive a launching agent shell
exiting; hangup is not an exit path.

`tests/worker.test.sh` compares that list against every `exit` in the
script, by identity: a code added correctly is not a failure and a code
that moves without the sentence moving is. That check compares numbers,
not meanings — a new failure reusing an existing code passes it in
silence, which is how `70` acquired a third meaning its sentence did
not mention. A code is a bucket, and widening the bucket is an edit to
this paragraph.

### 5.3.3 A later round starts from the current base

Firstmate may not run git, and a worker's adapter may not be able to run
anything, so when the base moves under an open task branch and the two
conflict, nothing else in the system can bring the branch up to date.
Firstmate was rebasing branches by hand, against its own skill, and
T-059 sat blocked on real code conflicts with T-058. `fm-worker.sh` owns
it (T-067).

Every round that continues a branch — `--pr`, or a task branch found and
reused — first fast-forwards the local branch to `origin`'s when it can
(never a rewind, never over a divergence), then fetches the base from
`origin` (the local base ref is never trusted or moved) and asks gate 2's
question the way gate 2 asks it: does the branch `git rebase` onto the base,
commit by commit, in a scratch worktree? A squashed patch can apply where
that replay does not, and a branch this step left alone while gate 2 stayed
red could never be fixed by anything. If it rebases, nothing changes: the
round builds on the branch as it is. If it does not, the branch is rebuilt.
The worktree is detached at the fetched base and the branch's own change,
`merge-base..branch`, is squash-merged onto it, three-way: clean files are
staged, conflicting files keep standard conflict markers, and the prompt
lists them by name with the rule for resolving them — keep the base's
change and the task's intent, never a whole side. A conflict git cannot
put markers into — a binary file, or one side deleted what the other
changed — is listed apart, with which side the merge left in the worktree,
because that side looks resolved and is not.

The rebuild is not attempted, and the round goes on with the branch as it
is, when the worktree is not clean (the rebuild's failure path is a hard
reset), the base cannot be fetched, the replay failed without stopping on
a conflict (that answers nothing about gate 2), the branch shares no
history with it, `origin` cannot say where the branch is, or `origin`'s
branch has commits
the local one lacks — the head the push would lease on must be inside
what is rebuilt, or the rebuild would overwrite it. Each says so. A
squash-merge that fails without leaving a conflict stops the round with
`70`, the worktree back on the branch, before any worker is started.

The branch ref does not move until origin has taken the rebuilt commit,
so a run that dies half way leaves the branch where it was, and `fm-checkpoint.sh` refuses
the detached worktree.

A rebuild that applied — nothing unresolved handed to the worker — is
always committed and pushed, whatever the worker did with the round:
changed files, changed nothing, left a note, or only asked, as the
round-three protocol requires (T-098). With no change of the worker's,
the commit is the rebuild alone; otherwise the worker's changes are in it
on top. An asking round is still reported as asked, and its question
still goes on the pull request: the one there is, or the one the push
opens. A note the pull request refuses is kept under `state/unsent/` at
once, and only once: it is never offered again, since a refusal can come
back for a comment GitHub stored. The rebuild is still pushed, and the
round then fails with `73`; a failure on the way to the push ends it with
that failure's own code instead, the note already kept. Such a round used
to publish nothing, and the branch stayed on its old head, `DIRTY` on
GitHub, until the captain pushed it by hand (T-089, T-086).

Unresolved is a conflict, with or without markers, and also the task's
own `design/tasks.json` entry or table row when the rebuild could not
keep it as the previous head had it — the prompt lists that file for the
worker to put back, and the check before the commit refuses the rebuild
as it stands, as it refuses a marker. An unresolved rebuild is never
published. A round that only asks about one completes as asked and
publishes nothing; one refused before its commit publishes nothing
either. The next round finds the
worktree dirty, copies it to `state/rescued/` as it does any interrupted
run, recreates the worktree from the unmoved branch and rebuilds again.

On a base that keeps one file per task (section 14) the task's own
business is one file, `design/tasks/<id>.json`, and it comes through
exactly as the branch had it — byte for byte from the branch's own file,
or from its entry in the branch's old array — wherever the merge changed
it. There is no table row to keep. A branch opened before that layout
still carries `design/tasks.json`; the rebuild brings it over without the
worker: every entry the branch added or changed since it left the base,
the task's own and any other (a design task writes other tasks' entries),
is written to its own file, an entry the branch removed is removed, and
the array goes. Where the base changed the same entry too, that file is
written with standard conflict markers, the base's text against the
branch's, and handed to the worker like any conflict; the task's own entry
is the branch's. Nothing the branch said is dropped without a word.

On a base that still keeps the one array, two design files are the task's
own business. Its `design/tasks.json`
entry comes through exactly: when that file conflicts, it is merged by
task id — the task's entry from the branch, entries only one side
touched from that side — and written back in `jq`'s layout, which is
only attempted when the base's copy already is in it; where both sides
changed the same other entry, the file goes to the worker. When it
merged cleanly but the task's entry changed, only that entry is put
back. In `design/design.md`, hunk by hunk: where both sides only
appended task-table rows at the same place, the union is taken — the
base's rows, then the task's — without the worker; every other hunk goes
to the worker like code, as a standard conflict, so one prose conflict
does not hand back the rows as well. The task's own table row is put back
exactly wherever the merge changed it. Each of these repairs is best
effort; what holds the round is the check below.

After the adapter returns, a rebuilt round is not committed while HEAD is
anything but the rebuild base, detached — a commit made on it mid-round
would sit under the round, outside every check — nor while any file it
carries, read against that base, has a line starting `<<<<<<<` or
`>>>>>>>`, nor while a conflict with no markers is byte for byte what the
merge left, nor while the task's entry (its own file, or its `tasks.json`
entry and table row on a base that still has them) differs
from the previous head's — however it got that way, including a worker
that rewrote it while resolving. In a rebuilt round the task's own entry
and row are therefore frozen: a change to either waits for a round that
is not a rebuild. The run names the files, publishes nothing and exits
`75`. Otherwise the rebuild and the round's work are one commit on the
base, so gate 2 holds by construction. The commit is made with `git
commit-tree` from the staged tree, parented on the fetched base, under
the identity a plain round's commit takes and signed when
`commit.gpgSign` says so, as `git commit` would sign it — never
`git commit` on the detached HEAD, which the repository's own pre-commit
hook used to refuse, and did, on every real rebuild (T-093). It runs no
hook and steps around none on a protected branch: until the push lands
it is on no branch at all, and then only on the task's. HEAD is then
moved onto it, detached, as a commit would leave it, so a round that stops
before the branch moves leaves a clean worktree, not a staged rebuild the
next round would rescue as crashed work. It is pushed by
its id with `--force-with-lease` against the branch head read before the
rebuild: anything pushed to the branch since is refused, never
overwritten. The local branch moves onto the commit only after origin has
taken it, so a refused push leaves it on its previous head; the next round
fast-forwards to what was pushed and rebuilds from there. While the push
is unconfirmed, `refs/fm-rebuilt/<branch>` names the commit. A run cut
short in that window — by a signal, from the EXIT trap, or by SIGKILL, at
the start of the next round — asks origin and settles on its answer: the
local branch moves onto the rebuilt commit if origin has it, and stays
where it was if not. `commit_pushed` is written only once a
push has landed, on every round. The pull request is updated in place; the previous head
goes into the round's `commit_pushed` (or `pr_opened`) event as
`data.rebuilt.previous_head`, and onto the pull request as a comment for
the reviewer, whose last reading of the branch no longer exists on it.

### 5.3.4 A new script is committed executable

The claude worker's sandbox refuses `chmod`, so every script a worker
added was committed `100644`, a suite that ran it by path failed with
`126`, and reviewers raised it every round (T-048 for five, T-059). So
before any round's commit, plain or rebuilt, `fm-worker.sh` sets the bit
itself (T-098), with `git update-index --chmod=+x`: the index needs no
permission of the worker's. It also sets it on disk where it can, so the
worktree agrees with the commit. It does so for a file that

- the round adds — absent from the commit the round started from. In a
  plain round that is `HEAD` as the adapter found it, so a script a
  mid-run `fm-checkpoint.sh` already committed without the bit is still
  one the round adds; in a rebuilt round it is the rebuild base, and the
  file must be absent from the previous head too;
- lies under `bin/` or `tests/`;
- is a script: its first two bytes are `#!`, whatever its extension, so a
  `.sh`, `.py` or `.ts` without a shebang line is left alone;
- sits in a directory that already holds an executable script in the
  commit the round started from. A directory whose only scripts are
  sourced or imported, or a new directory, says nothing, and is left
  alone.

A bit is never removed, and no file the round did not add is touched: an
existing `100644` script, such as a sourced library, stays as it is. The
run names each file it marked. If the index refuses, the round's commit
is not made and the run exits `70`; as on any exit before that commit, a
plain round's worktree is still saved by the exit's checkpoint — through
`fm-checkpoint.sh`, which commits the script without its bit — and a
rebuilt one publishes nothing.

### 5.4 The pull request protocol

Strings on a pull request are input to `bin/fm-gate.sh`. Wrong format means it
did not happen.

| String | Posted by | Meaning |
|---|---|---|
| `APPROVE:<task-id>` | reviewer | the only valid pass signal |
| `ASK-PASS-CRITERIA:<task-id>` | worker | the round-three question |
| `CRITERIA-COMPLETE:<task-id>` | reviewer | the numbered list that follows is the complete set |
| `REGRESSION:<task-id>` | reviewer | off-list but newly introduced, so admissible |

---

## 6. Lifecycle and the seven gates

```
grilling  ->  /prototype  ->  [captain green-lights]  ->  design.md + design/tasks/
                                       |
                        fm-dispatch.sh (ready tasks only, three at a time)
                                       |
              fm-worker.sh: worktree -> adapter -> commit -> pull request
                                       |
                          *  fm-gate.sh, the seven gates  *
                                       |
            fm-review.sh: reviewer sees the diff, the spec, the criteria
         (diff mode: and, given the PR, the head's check and gate results,
          as information; run mode: runs the tests in a fresh clone instead)
                                       |
     not passed -> worker revives and fixes (round 3+ asks first) -> back to the gates
                                       |
              APPROVE -> firstmate summarises -> [captain merges on the board]
```

**`fm-dispatch.sh` dispatches nothing until a `greenlit` event exists.**
It checks for any such event, not a match to the proposed work. Firstmate must
verify that authorization covers the work. Dependencies and capacity are read
from events, so reconcile these with current PRs and live processes before launch.

The captain's word on untouched work is read from events too (T-058). A task
whose last `parked`/`unparked` event is `parked` is never started, and starts
again only after an `unparked`. A `closed` task — which is what a drop on the
board writes — is never started, and an `unparked` does not bring it back.
Neither counts as merged, so a task that depends on one waits, and its backlog
card names the parked or dropped task as its blocker.

**A task that turns ready is judged before it is dispatched (T-059).** At startup
and after every merge firstmate runs `bin/fm-ready.sh list`, which prints the
tasks ready by the board's rule and marks those not yet judged. For each one it
re-reads the spec against current `main` and raises a choice card: A proceed,
B rescope, C park, D drop, with its recommendation and the evidence in `main`.
The card's id is allocated with `fm-decide.sh --allocate` like any other card's,
and a C or D is carried out as the `parked` or `closed` event the board's park
and drop write (T-058).
`fm-ready.sh judged --task <id> --decision <D-id>` records the card under
`state/ready/`, written to a temporary file and renamed into place. A record
belongs to one readiness episode — the task's dependency list and where in the
log the last of them merged, or the task was unparked — so a task that goes
back to backlog, or is parked, and returns is judged again. A trip can leave
the episode as it was: a dependency added and removed again before it merged.
So `list` and `cleared` also end every judgment whose task they see out of
ready or on another episode, replacing its record with one that names no
card. Firstmate runs `list` after every merge, which is how `design/tasks/`
changes, and `fm-dispatch.sh` runs `cleared` every tick; a trip made wholly
between two runs goes unseen. Like the board, it reads a park only on
untouched work. A decision card about a task does not take it off the list,
and the board keeps a ready task in the ready lane while its readiness card is
its only open card. `fm-dispatch.sh` starts only what `fm-ready.sh cleared`
lists: ready, judged this time, and answered A on the board, which offers D
only on a card that does. The A must be recorded for that task on a choice
card; an A on another task's card or on a merge card clears nothing. An
adopted skill update (SK-*) was judged by its own adoption card, D-SK-*,
answered A, so it gets no second card the first time it is ready; that
answer stands only while the task has not been unparked and has never been
seen with dependencies other than the ones it was adopted with. After either
it is unjudged, and it cannot get a readiness card: `fm-decide.sh` allocates
ids and takes authored details only for `T-*` tasks. So it stays held, and
firstmate tells the captain, until the captain orders it directly.
`fm-dispatch.sh` holds every other ready task, and
starts nothing if it cannot read the answers. A task the captain orders
directly, or a completed rescope, is started with
`fm-dispatch.sh --task <id>`: the order lifts the
judgment check and no other, so greenlit, dependencies, park, drop and the
concurrency limit still hold, and it says which one held the task.

| # | Gate | How it is checked |
|---|---|---|
| 1 | branch exists and has commits | `git rev-list --count main..<branch>` > 0 |
| 2 | rebase onto main is clean | attempt it in a scratch worktree; non-zero fails |
| 3 | the declared `project.check` exits 0 | `config.yaml`'s `setup`, then `check` with `check_env`, in a fresh worktree |
| 4 | the diff stays in scope | `git diff --name-only` within the task's `scope` globs |
| 5 | **the new tests are not vacuous** | classify by `project.tests`, revert the implementation, run `setup`, then each test through `project.test` (else `check`); it must go red |
| 6 | the required GitHub check is green | `gh pr checks <pr> --required` |
| 7 | a PR comment contains `APPROVE:<task-id>` | author filtered only if `FM_REVIEWER_LOGIN` is set |

Require all seven gates and current-head review evidence before treating a merge
card as ready. `fm-run.sh` requests a card after gate success, but `fm-review.sh`
can emit `approved` on an approval substring before that subsequent gate run.
Gate 7 neither binds approval to a head nor distinguishes final, quoted or stale
markers; a later rejection does not invalidate an earlier matching comment.
Firstmate must verify provenance and current readiness explicitly. Any red gate
requires remediation regardless of praise or an `approved` event.

**Round order and the merge double check (captain, 2026-09-25).** A review
round starts as soon as the worker hands back, through `fm-review.sh`, and
never waits on CI: CI and the seven gates are not a review criterion in
either mode. A merge card needs two independent checks on the same current
head: the reviewer's `APPROVE:<task-id>` for that head, and firstmate's own
reading of that head's required GitHub check (green) and the seven gates
(`fm-gate.sh`). Neither substitutes for the other - an approval is not green
CI, and green gates are not an approval - and a head that changes after
either check restarts both. `fm-run.sh`'s loop still sends a task to review
only once gates 1-6 are green; until it follows this order, firstmate starts
the round itself when the worker hands back.

Gates 3 and 5 name no toolchain. The target repository declares its own in
`config.yaml`'s `project:` block (`setup`, `check`, `check_env`, `tests`,
`test`, `docs`; see the README), and the gates run exactly that, read from the
branch under test; gate 4 decides whether a branch may change `config.yaml` at
all. Gate 5 asks for no new test only when every changed non-test path matches
the declared `docs` globs; with none declared, nothing is exempt.
An undeclared `check` or a failed `setup` fails the gate by name; a stage the
check skipped is not a stage that passed. `bin/fm-session.sh start` runs
`setup` once in the checkout and reports the contract; `status` only reports it.

---

## 7. The round-three protocol

Rounds one and two: the reviewer picks holes as usual.

**From round three:**

1. Before touching a line, if no original closed list exists, the worker posts
   `ASK-PASS-CRITERIA:<task-id>` in `.fm-say.md` for script publication and waits.
   That asking round changes no implementation files.
2. The reviewer answers with a **numbered list** and posts
   `CRITERIA-COMPLETE:<task-id>`.
3. Preserve that original list across subsequent rounds; do not ask again or
   replace it. Fix the whole list in one pass. After that the reviewer may raise
   only numbered items from that list, or a
   newly introduced regression marked `REGRESSION:`.
4. Report old off-list complaints to firstmate for board coordination.
   `bin/fm-protocol.sh` attempts a `protocol_violation` event for the violations
   its marker checks detect; it cannot determine every semantic violation.
   It accepts numeric-reference shapes without checking original item membership,
   does not authenticate ask/completion markers, can replace its list count on a
   later completion marker, and does not prove a marked regression is new.
   Firstmate must preserve and verify the original list; a passing protocol
   check does not establish compliance with this role contract.

The reviewer cannot see the pull request, so the launcher carries the protocol
across (T-073). From round three, given `--pr`, `fm-review.sh` reads the pull
request's comments with `gh` and quotes into the prompt, verbatim, first the
latest comment holding `ASK-PASS-CRITERIA:<task-id>`, then every comment whose
numbered list is followed by `CRITERIA-COMPLETE:<task-id>`, in the order
posted, whether before or after the ask. A
marker counts only as a line of its own and a comment that asks is never a
list, so a worker's numbered change log that mentions a marker in passing is
not taken for the closed list. Each quote is fenced with a per-run nonce, so a
comment cannot close its own quote, and printed straight from `jq`, so its
trailing newlines survive. It then says which case holds: a list (it is the
closed list; findings cite its items or are marked `REGRESSION:`), only an ask
(answer with the complete list), neither, or comments `gh` could not read, in
which case the round still runs.
No other comment enters the prompt, so the worker's reasoning stays out.
Rounds one and two get no closed-list section. Given `--pr`, they, like every
diff-mode round, do get the head section below; without `--pr` no round gets
either, and the prompt is unchanged.

A diff cannot show CI or gates, so a closed-list item asking for them could
never be closed (T-067, round nine). Current-head CI and gates are firstmate's
merge gate, not a review criterion (§6, the merge double check), so no
closed-list item may ask for them. In diff mode the launcher shows the
reviewer what exists for the head, as information only (T-088); a run-mode
round judges the head by running it and gets no head section and no CI from
GitHub (T-066). Given `--pr`, every diff-mode round's prompt gets a **The head under
review** section before the diff, verbatim and labelled: the head SHA, from
the local branch the diff is taken from; for each name `gh pr checks <pr>
--required --json name` lists, that check's name, conclusion and run URL from
GitHub's check runs for that exact commit (`gh api
repos/{owner}/{repo}/commits/<sha>/check-runs?check_name=<name>`), keeping
only a run whose `head_sha` is the head and the latest of those; and the
whole of `state/gates/<task-id>-<sha>.txt`, unfiltered and fenced with a
per-run nonce, when that file exists. Its lines are `fm-gate.sh`'s own
stdout: `  + gate N: …` or `  x gate N: …`. A required check that cannot be
read, a check with no run for this head, a missing gate summary, and each
gate the summary has no result line for (it stops at the first red gate, and
an empty one has none) are stated plainly. Nothing else is added, and a round
without `--pr` is unchanged.

The gate half is not closed yet. Nothing writes that gate summary:
`fm-run.sh` sends `fm-gate.sh`'s stdout to `/dev/null`, and it is outside
T-088's scope. Until a writer tees that stdout to
`state/gates/<task-id>-<sha>.txt`, every diff-mode prompt reports the head's
gate results as unknown, and firstmate reads the gates from `fm-gate.sh`
itself for the merge double check. The path
and the `  + gate N: …` / `  x gate N: …` lines of `fm-gate.sh`'s own `say()`
are the contract that writer must follow.

The point is to end the loop where each round fixes one thing and surfaces
another.

---

## 8. The captain's board

Bun, native SSE, vanilla HTML, **no build step**.

Captain decision D-047 (T-040) chose full layout parity with
`design/proposals/2026-09-20-captain-board/prototype.html`, without invented
percentages. The regions below are that layout.

| Region | What it holds |
|---|---|
| Header | brand, the engine badge, green-light state and the language switch |
| Sea header | merged / in flight / waiting on you / blocked / ready / backlog; waiting on you is the number of pending decisions |
| Decision deck | pending records first: the captain's portrait beside the first full card, further decisions as one-line strips that expand in place |
| The ship | a two-mast pirate vessel (three on the tallest rates) whose beam and decks track the crew |
| Deck | crew stand on the ship with name tags over their heads, poses driven by state, handoffs fly between them |
| Crew roster | two-column rows, shown by default and toggled from the ship's bar |
| Lanes | seven columns left to right: backlog, ready, work, gate, review, captain, merged; closed tasks, and every merged task, in the separate initially collapsed history; below the lanes, the initially collapsed parked group and the drop target |
| Live log | a full-width panel at the bottom; tri-lingual summaries from `events.jsonl` |

**Engine badge (V7).** The server reads `config.yaml` on every state request —
the top-level `vendor`, and `reviewer.vendor` when that block exists — and the
header shows the top-level vendor, marked `vendor ⇄ reviewer-vendor` when they
differ. Names are never hard-coded; no file or no top-level vendor is no badge.

**Lanes and cards.** The lane order is sent by the server (`lanes`) so the page
keeps no second copy. A task no event has moved yet is `ready` when every
`depends_on` has merged, so it could be dispatched now, and `backlog` while
any has not; a dependency the log has never heard of is not merged. The server
decides this from the same replay that fills `blocked_on`, and counts the two
separately, so a card moves from backlog to ready over the live stream the
moment its last dependency merges. A card shows the task id and title, the aboard crew's
names, the pull request, `blocked on T-xxx` for a backlog task whose
dependencies have not merged, and badges read only from events and pending
records: the failed gate's number when the `gate_failed` event carries
`data.gate`, an `ask_pass_criteria` not yet answered by `criteria_returned`,
and a pending decision with the number of options it actually lists. A task
absent from `design/tasks/` shows its id and an explicit missing-title
label. The merged lane shows the latest few merges, newest first, and counts
the rest into the history.

**Park and drop (T-058).** The captain takes work they do not want run off the
ready and backlog lanes on the board itself. Each card there offers two
actions, reachable both by dragging the card and by the `⋯` menu on it (the
menu is also the keyboard path):

- **park** — reversible. The card moves to the collapsed *parked* group below
  the lanes. It comes back by the same two routes — *unpark* in its menu, or
  dragged onto the ready or backlog lane — and lands in ready or backlog as its
  dependencies say, not as the lane it was dropped on says.
- **drop** — the task will not be done. The menu item, or dragging the card onto
  the drop target, opens one confirming step in the page (never a browser
  dialog); confirming it takes the task off the lanes into the closed history.

`POST /tasks {task, action}` writes the event through `bin/fm-emit.sh` with
actor `captain`, like every other board write: park is `parked`, unpark is
`unparked`, drop is the existing `closed`. The server says which actions each
card offers (`actions`): `park`/`drop` for ready and backlog, `unpark`/`drop`
for parked, none for a task in flight or later, which is neither draggable nor
given a menu. An action the card does not offer is refused with 409 and nothing
is emitted; an unknown task is 404, an unknown action 400, and a body not
declared `application/json` 415. The board never edits `design/tasks/`: a
drop leaves the task in the plan, and removing it from there, if the captain
wants that, is an ordinary pull request firstmate raises afterwards. A backlog
card whose dependency is parked or dropped says so beside the blocker's id
(`blocked on T-xxx (parked)`), from the `blocked_by` list the server sends.
Labels are the dictionaries' `park` / `unpark` / `drop` / `parked`
(擱置 / 恢復 / 不做 / 已擱置); zh-CN derives through `tw2cn.tsv`.

**Pull request links (T-069).** Every `#n` the board shows — the top right of
a lane card, a history row, the decision card's link, a roster row, and any
`#n` written in text: a log line, a task title, a decision's text, a
crewman's activity, the order feedback — links to that pull request, in a new
tab with `rel=noreferrer`. The one exception is a decision's option label,
which is a button and cannot hold a link. The server derives the URL from the
project registry (section 15.2): the project's `github` (`owner/repo`), read
through `bin/fm-config.sh`'s `fm_project_resolve` and `fm_project_get`. It
sends it as `pr_url` next to every `pr` it returns (tasks, decisions and
their responses, outcomes and the log), and as `pr_urls`, a map from every
`#n` written anywhere in `/api/state` to its URL. A pull request number has
one reading, the server's: a positive integer or the same digits as a
string. The page links a number only where the server gave it a URL, and
never judges one itself. Until T-054 gives events a project, that is
the default project; the server does not pass `FM_PROJECT` on, so the shell
that started it cannot change it. It reads the registry again whenever
`config.yaml` changes. No registry, no `github`, or a registry
`fm-config.sh` refuses is no URL, and the page shows the number as plain text,
never a guessed link; no owner or repository name is a literal under `board/`.
A press that starts on a card's `#n` is a click on the link: it never starts
the card's drag or opens its menu.

**Refused merges.** The feedback for a refused merge names the decision and
the task. The server flags a refusal as `superseded` once a `merged` event for
the same task or pull request — or a later successful merge response — is
recorded afterwards, and the page stops showing it; a reload cannot bring it
back.

**Roster and tags.** Roster rows carry a status dot, the crew name, a stage
pill and the pull request, over the task id and title and the authored
activity. A bar appears only for bounded `{done,total}` progress; no
percentage is shown anywhere. The prototype's crew percentages and its random
progress tick were demonstration only and do not ship. The ship's bar carries
the roster toggle and the AHOY and order demonstrations, which play the
effect locally and record nothing.

### The ship

Decks and hull come out of **one lens curve in one SVG** — the deck is the
foreshortened plan, the hull is that same curve extruded down — in the same
projection as the voxel crew. Mixing an elevation with perspective decks was
what made earlier versions read as a drawing of a ship next to some slabs.

The hull is a warm-black silhouette and **brass is the only accent in the whole
scene**, so the crew are the brightest layer. That is the hierarchy the board
wants.

| Crew | Rate | Masts | Decks | Beam |
|---|---|---|---|---|
| ≤3 | cutter | 1 | 1 | 42% |
| 4–5 | schooner | 2 | 1 | 54% |
| 6–8 | frigate | 3 | 2 | 66% |
| 9–12 | ship of the line | 4 | 2 | 74% |
| 13–18 | flagship | 5 | 3 | 82% |
| 19–24 | man-o'-war | 6 | 4 | 90% |

**A crowd goes up, not lengthwise.** Upper decks are shorter; firstmate always
holds the topmost deck and the reviewer the one below. Hull, decks, crew and
bubbles all align to `--deckY0 + row * --rowStep`, and every deck plate is the
same height or the crew plant to different depths on each level. Each deck
carries a bulwark and a riser wall down to the deck below, which is what makes
a level read as a level.

Mast height and scene height derive from `headroom()` so the **whole sail hangs
above the tallest crewman's head** — otherwise the crew stand inside the
canvas. Mast spacing is a fraction of the **topmost** deck's width, since that
is what they are stepped on; using the hull's widest point puts the outer masts
off the edge.

**The bow faces left**, the end firstmate stands on. That is a narrative choice,
not a nautical one — the helm belongs aft on a real ship — but the person
leading should be at the head of it. Gilded figurehead and bowsprit to port,
stern lantern to starboard. **The whole broadside points one way**, toward the
bow: barrel, port lid, muzzle flash and smoke all agree.

Gun ports and the figurehead are drawn in **HTML at fixed pixel sizes, not
SVG** — the hull's viewBox stretches horizontally with beam and not vertically,
which flattened a cutter's ports into slots.

### The crew

Twelve actions, pooled by deck and chosen by a hash of the crew id so they stay
put: helm, lookout, signal, point and log on the quarterdeck; haul, capstan,
carry and climb amidships; hammer, saw, swab and carry on the main deck. **Idle
crew get their own pool** — with a concurrency of three, most of a large crew
has no task, and one shared idle pose turns them into a row of broken statues.

**Every action holds or stands at something**; nobody mimes. Tools follow the
job, not the role. State still wins over action: a worker stopped at the gate
slumps, a reviewer raises a spyglass.

Legs alternate a weight shift at a per-crewman cadence, and each hops every
7–15 seconds on its own offset. The hop animates the `translate` property
rather than `transform`, so it composes with the pose animations instead of
replacing them. **Shoes animate with their leg** — otherwise the leg turns
while the shoe stays nailed to the deck and all you see is a bobbing body.

**Each crewman carries a bubble above his head**: identity and task, with full
localized work and lifecycle phase in the accessible figure label and readable
roster. The tag carries no progress and no percentage; the roster draws a
bar only for explicit bounded progress data, with the border colour carrying
state. A landing handoff pulses the recipient's
bubble. Deck spacing must exceed body height plus bubble height or a bubble
covers the crew on the deck above.

### The captain

The human captain is always visible on the ship's top deck, including startup
with zero pending decisions and after the final acknowledgement. There is one
captain aboard. While a decision is pending, the decision deck also shows his
portrait beside the first card (D-047); it is a picture of the same captain in
the same pose, not a second figure aboard, and it disappears with the last
card. He is excluded from agent counts.
The shared deck coordinate system anchors his feet; firstmate and the helm
remain at the original left/bow anchor, with the stern on the right. Three
poses remain: sheathed without a choice, half drawn on local selection, raised
on explicit confirmation and through recorded acknowledgement, then idle.
He is draggable like the crew; orientation does not replace sword poses.

Primary task, decision, tradeoff and event text is at least 16 CSS pixels;
secondary labels are at least 13 pixels and decision titles at least 20 pixels.
Choice and confirmation targets are at least 44 pixels high. Wrapped content
and flexible columns support 320-pixel screens and enlarged text. Completed
history uses a native keyboard-operable disclosure, with distinct merged and
closed counts. Its open state survives refresh and locale changes; new merges
do not open it. Pending decisions come from pending records, not task stages.

Crew payloads add `activity: {en, "zh-TW"}`, `crew_name` and optional bounded
`progress` without changing canonical actor IDs or roles. Replay retains each
actor's dispatch/activity description and last applicable lifecycle phase
across technical events, independently of the 40-event recent list. Localized
task activity takes precedence when available; scalar titles are not guessed
translations. Missing descriptions and unknown phases are explicitly labeled.
Finished actors cannot reappear through late technical events; a new dispatch
starts fresh activity. Producers lacking authored summaries need firstmate
coordination with the owning task, not fabricated board descriptions.

### Ahoy

| Trigger | Response |
|---|---|
| A merge | the broadside fires gun by gun with cannon reports, the ship heels, every crewman's arms go up, `AHOY! / MERGED INTO MAIN` |
| An order | the helm spins twice and the visible crew acknowledges, `AYE, CAPTAIN! / ORDERS AWAY` |

The later captain override disables Ahoy-related speech, bell and whistle
audio. No substitute cue or global mute implements that choice. Confirmed
merges retain their synthesised lowpassed-noise cannon reports; there are no
audio files or network requests. Persistent mute silences those reports,
browsers may require a gesture, initial history is silent and event identities
deduplicate playback. The board never touches the browser speech queue.

The full outcome stream supplies stable decision IDs and merge identities
(PR, or task/event fallback). Initial history is silent, new outcomes queue,
and refreshes/reconnects cannot replay handled identities. The 3.2-second
effect deadline survives ordinary state rendering; retained animations keep
their running timeline while elapsed offsets apply only to newly mounted effect
nodes. Crew data continues updating, and the captain persists with feedback
after the last card disappears. Reduced motion keeps static acknowledgement
and independently honors audio preference. Only confirmed `merged` events
fire the merge salute; recording an order or a failed helper cannot do so.

**One gun list** (`portList()`) drives the ports, the flash positions and the
sound schedule: one gun, one flash, one report, the same `GUN_DELAY` apart.
**The shout stays in English in every
locale** — it is a cry, not a label.

Celebration must not hide what is being celebrated: the banner sits clear of
the ship.

### Interaction

Drag a figure to turn it, drag the deck to turn the whole crew, double-click to
reset. Every pose is a `.fig.s-<state>` class, so **e2e asserts classes rather
than diffing screenshots**.

The renderer patches existing figures, preserving pointer capture and rotation.
Full event replay supplies directed `handoffs` with event identities: dispatch
or recorded order from firstmate to a worker, PR/review handoff to a reviewer,
approval to firstmate and rejection to the worker. Peer resolution requires
one known active participant on the same task; ambiguous or missing recipients
produce static unavailable feedback. Initial history is silent and duplicate
snapshots do not replay cues. Travel uses current rendered anchors for 1.4
seconds, then a receiving reaction and bubble pulse, with cleanup at 2.3 seconds.
Reduced motion retains localized directed text. Handoffs emit no events, POSTs
or success audio. Browser checks measure travel, endpoints and drag ownership,
in addition to pose classes; source text alone does not establish behavior.

**Hot reload:** a change under `board/public/**` pushes `reload` over SSE; a
change to `board/server.ts` restarts under `bun --watch` and the client
reconnects. Decisions are already on disk, so a restart loses none.

**`/open`:** `GET /open?path=` hands the file to the editor. Localhost only,
and `realpath` must resolve inside the repository or it is a 403. A read-only
diff viewer covers the case where you would rather not leave the board.

**One source for shared numbers.** CSS custom properties are written from the
JavaScript constants. `--rowStep` once drifted from `ROWSTEP` and the decks were
drawn on one grid while the crew stood on another — by the fourth level they
were 102px below their own deck.

The production board is **rewritten** from the prototype in
`design/proposals/`, not promoted from it: that prototype was written with no
tests and no error handling.

---

## 9. Three languages

Only the board is tri-lingual. The repository is English (section 1).

- Agents write `en` and `zh-TW` into the `summary` field through
  `bin/fm-emit.sh`.
- `zh-CN` is produced by table conversion through `i18n/tw2cn.tsv`, covering
  script and vocabulary both. The reverse is not attempted: 程序 is both
  *program* and *procedure* in `zh-CN` and cannot be mapped back.
- UI chrome comes from `i18n/ui.*.json`. A lint fails the build on any UI
  string that is not in the dictionary.
- Diagrams render `.en.html` and `.zh-TW.html`; `zh-CN` post-processes the text
  nodes.
- The preference lives in `localStorage`, `?lang=` overrides it, default
  `zh-TW`.

---

## 10. CI

The local gate and GitHub Actions run **the same** `bin/ci.sh`.

The elapsed-time limit defaults to 180 seconds. Set `FM_CI_MAX_SECONDS` to a
plain decimal integer from 1 to 3600, without leading zeros, to select an
explicit budget; invalid or empty values exit 64 with guidance. The gate
reports the effective budget and elapsed time, and exceeding the budget
still fails after all functional checks. This is an elapsed-time check, not
a process timeout; selecting a larger budget does not waive functional failures.
GitHub sets `FM_CI_MAX_SECONDS=600`; its separate `timeout-minutes: 10` covers
the entire job, including setup, so the script may have less than 600 seconds
before GitHub cancels it. For T-017, Firstmate runs the same full local gate
with `FM_CI_MAX_SECONDS=600 bash bin/ci.sh` before publication. Since T-043
that budget is this repository's declared `project.check_env`, and gate 3 runs
the declared `setup` first, so a fresh worktree has the dependencies and
browser the end-to-end stage needs instead of skipping it. A functional
pass at 208 seconds is within that authorized budget, but exceeds the default.

```
shellcheck        ->  single-writer lint  ->  bash suites
                  ->  bun test            ->  playwright
```

That is the order the stages are **reported** in, not the order they run in
(T-065). The bash suites run through a bounded pool: the job count is the
online CPU count capped at 6, printed as `ci: bash suites: N at a time`, and
`FM_CI_JOBS` (a decimal integer from 1 to 99; anything else exits 64)
overrides it. `FM_CI_JOBS=1` is the one-at-a-time run in glob order. With
more than one job the slowest suites start first — herdr, reconcile and
worker by name, the rest by size. Each suite keeps `LC_ALL=''
LC_MESSAGES=C` and `</dev/null`, and writes to its own log in a `mktemp`
directory outside `FM_ROOT`; nothing the gate writes lands in the tree it
judges. When every suite has finished, the results print in glob order with
the same pass, flunk and noise-check lines as before. The shellcheck and
end-to-end stages run beside the pool and print in their usual places; the
pool polls rather than using `wait -n`, which bash 3.2 lacks. Playwright
runs `fullyParallel` with no retries, so no browser test may change state
another one reads: a test that writes to its board starts its own. Its
config asks for 4 workers; beside the pool, `ci.sh` gives it half the online
CPUs instead (at least 1, at most 4), printed as `ci: end-to-end: N workers`,
because four browsers beside four suites on a 4-vCPU runner starved the
browsers. Every background job and the gate itself trap INT, TERM and HUP,
so an interrupted gate takes its suites, browsers and logs with it.

Running in parallel changes no threshold: the budget, every stage, every
suite, every assertion and the per-suite noise check are what they were.
What it does demand of the suites is that none of them leans on the machine
being idle. A suite that starts a board takes its port from the kernel
(`FM_PORT=0`, then the port from the `board on http://127.0.0.1:PORT` line
the server prints), because the old `RANDOM` ranges overlapped and a
readiness loop could reach another suite's server. A positive wait is for
its real condition against a deadline wide enough for a loaded machine, and
returns the moment the condition holds; that includes the browser tests'
expect and test timeouts, and an animation a test steps through runs on a
paused clock rather than on real time. A negative window ("nothing was
started within N seconds") is wall clock, never a count of sleeps, and may
only grow: reconcile's is 5 seconds.

Each stage skips cleanly when its subject does not exist, so the gate is green
from an empty tree onward. **Every e2e uses the `mock` adapter** — no model
call, so it is fast, free and deterministic. Real vendors run in a nightly
smoke job.

`ci` is a required status check on `main`, and a branch must be up to date
before it can merge.

---

## 11. Self-update

#### Mid-run progress (truthful; T-036)

Captains need more than “wait for the final result,” but the board must not
invent motion. The throwaway prototype under
`design/proposals/2026-09-20-captain-board/prototype.html` randomly ticks
`pct` for demo only; that behaviour is not product truth and must not be
ported into production percentages.

Three layers, coarsest first:

1. **Phase** — mechanical lifecycle labels emitted only from script-known
   nodes (adapter started, tests running, commit pushed, review opened,
   verdict signed, and similar). Vendors share the same producers.
2. **Activity** — authored `data.activity` `{en, "zh-TW"}` describing what is
   observably underway. Prefer script and artifact evidence over model prose.
3. **Bounded progress** — optional `{done, total}` on the event and crew
   payload only when a real denominator exists (closed-list items, gates). The
   board never accepts a bare percentage. No denominator means no progress bar
   and no percentage.

Pane heartbeats and vendor JSON buffers are not board state until a producer
writes through `bin/fm-emit.sh`. High-frequency `crew_status` updates are
coalesced per actor: identical activity/progress payloads inside the throttle
window are dropped; within a window only `FM_CREW_STATUS_BURST` distinct payloads
may write so varying heartbeat text cannot flood the log; a changed bounded
progress always writes. The
UI hides progress chrome when bounded progress is absent; mapping coarse stage
names to fixed percentages is forbidden.

Mid-run branch saves use `bin/fm-checkpoint.sh`: after each logical commit the
worker commits (if dirty) and immediately pushes the feature branch. Waiting
until `WORKER_COMPLETE` for the only push is forbidden. Checkpoint never
merges, never writes `main`/`master`, and never opens a pull request;
`fm-worker.sh` may still run a final sweep through the same helper.

### Managed session defaults

`bin/fm-session.sh start --repo <root>` is the portable service bootstrap.
It reports actual recorded process liveness, worktrees, pending decisions and
(inside `HERDR_ENV=1`) observed Herdr panes. It starts or reuses the correct-root
board and a cancellable decision watch. It does not dispatch work or invent a
captain choice. Firstmate reconciles legacy/unrecorded processes and existing
authorization before dispatch; stopped work is preserved for explicit resumption.
Before the board is shown, and again on `status`, session bootstrap runs deck
reconcile: for each non-`firstmate` actor whose last event is not
`agent_finished`, it corroborates that actor against `state/runs/<actor>/`
process receipts (not task-level pidfiles). Actors with no live process receive
`agent_finished` under that exact actor with `data.status: process_gone`, so the
event-sourced crew list matches process reality. Task-level reconcile alone
cannot clear these ghosts. `status` and `start` report the reconcile result as
`deck_reconcile`. `status` reads the live process receipts and durable watch
results. `watch` and `stop`, optionally with `--decision D-id`, manage the
watcher independently.

Board reuse is verified with a fresh random file under the requested root and
the board's existing `/file?path=<relative-path>` endpoint. An HTTP response on
the configured port is insufficient; a different or unverifiable root is refused.
The bootstrap verifies HTTP page retrieval and reports whether `open` or
`xdg-open` was invoked. It cannot verify browser navigation. Bun is required for
the board. The watch polls `state/decisions/*.json` directly into durable
observation receipts; it does not invoke `fm-decide.sh --await`, so it neither
rejects non-numeric ids nor rewrites `events.jsonl`. It has a real PID and
process identity. Its continuous mode scans pending IDs between bounded waits;
it is not a sub-200ms guarantee across multiple IDs. It never wakes a completed
API conversation. Firstmate keeps pending authorized work actively monitored or
explicitly hands it off before ending the turn.

The normal `fm-run`, `fm-dispatch`, `fm-worker` and `fm-review` entrypoints freeze
`bin/` and `skills/` from the entrypoint's own code tree into a private per-launch
snapshot with a hash manifest before doing work. Invoking a checkout script against
a sparse `--repo` fixture snapshots the checkout, not the fixture. Nested launches
use that same frozen execution path. New sessions take a new snapshot; source changes
cannot replace scripts a running shell is reading. Do not alter retained snapshots.
Runtime events, current task specs and worktrees remain in the requested repository.
All five frozen entrypoints resolve relative `--repo`/`FM_ROOT` once in the caller's
directory and replay the canonical root. Relative script paths retain their original
code directory across that change.
A worker holds an advisory task lock through orchestration. Each supported adapter
execution also reserves its attempt before launch and holds a separate lifetime lock
in the pane runner, adapter and inherited CLI descendants. Retry checks these
reservations under task exclusion before touching the worktree. Timeout, interrupted
transport or launcher death cannot release the surviving execution's exclusion.
Session status distinguishes orchestration liveness, actual execution liveness and
uncertain pending launches, retaining canonical actor and actual adapter PID evidence.
A pending launch without proof it started, or an unfinished legacy attempt lacking
lifetime metadata, blocks recreation until its termination is established; it is not
reported as a verified live PID. These observations describe this implementation;
T-017 PID/flock reconciliation integration requires separate validation.
Concurrent reviewers and worker/reviewer runs have distinct artifacts and actors.

Every new worker/reviewer obtains one canonical human-readable machine label,
such as `worker-mira-t035-r2` or `reviewer-noah-t018-r8`. Labels retain role prefixes,
fit Herdr's 32-character syntax and include task/run identity. A locked repository
counter disambiguates concurrent runs, retries and repeated requested aliases;
normalization and the requested alias are recorded in `identity.json` and printed
at launch. Extremely long task labels retain a digest and the full original task
in metadata. The exact canonical actor appears in invocation context, Herdr tab,
pane and agent names, board events, log paths and result receipts. Existing live actors
are not renamed. A foreign Herdr name collision is a reported transport failure,
not a silently different sidebar identity.

The name in the label is a crew member from one fleet roster (T-089), shared by
workers and reviewers: `DEFAULT_ROSTER` in `bin/fm-herdr.py`, or config.yaml's
`roster:` list of short given names. Under the identity lock a run takes a name
no live run holds. A run is live while it is unfinished — it has no
`orchestration-result.json` — unless it is proven over: its `process.json`
launcher no longer matches and every attempt it recorded has terminated. A run
with neither record is starting, not over: `fm_identity` writes `process.json`
immediately after allocation and `transport()` writes its attempt, so no clock
decides it. Reserved, unstarted and legacy attempts count as live, as they do
for recreation. `identity.json` records the crew member whole as `name`, and the
actor carries exactly that name; runs from before T-089 have none, so their name
is read from the actor. Every comparison — live, previous round, other role,
reuse — is on the whole name. A task's worker and reviewer are never the same
crew member: a name either role of the task has used is not offered to the
other. A task keeps its previous round's name while that name is free;
otherwise it takes the first free name. When no name is left for the run the
allocator reuses one as `<name><n>`, records `reused` in `identity.json`, and
says why: `every roster name is live (N); reusing <name> as <name><n>` when all
are live, or `no roster name is free for this task (L of N live, <names> held
by its other role); reusing …` when the only free names are the other role's. An explicit alias wins but is refused, exit 70
with one line, while that name is live or is the task's other role's. A name is
never cut: one that does not fit the room the final `-<task>-r<n>` suffix
leaves, measured again on each retry, is refused, so the actor stays within 32
characters and no label can stand for two crew members. An empty `roster:` is
refused like any other invalid roster, not replaced by the default.

In `HERDR_ENV=1`, Codex, Claude, Cursor Agent and Gemini adapters use shipped
`bin/fm-herdr.py` to execute the real CLI in a dedicated new tab containing one
owned root pane. `herdr tab create --workspace <caller-workspace> --cwd <tree>
--label <canonical-actor> --no-focus` uses the installed supported interface;
creation IDs come from `result.tab` and `result.root_pane`. Never split the caller's
view. Record caller tab/pane and observed UI focus before and after creation;
changed or unknown focus refuses launch without taking focus back from the user.
The process receives its owned tab/pane/workspace context, not the caller's IDs.
It uses installed Herdr pane/agent commands, not an ignored wrapper or a tail-only
pane. A known caller pane is required. Missing or unsupported transport fails
clearly; it never silently falls back to invisible execution. Inside
`HERDR_ENV=1`, `FM_TRANSPORT=direct` is refused (exit 70) unless
`FM_ALLOW_DIRECT=1` for isolated tests — live Claude, Codex and Cursor sessions
must not set it. Outside Herdr, in-process adapter execution remains the default.
Firstmate *stock launch* is only `bin/fm-worker.sh` / `bin/fm-review.sh`; session
wrappers and hand-started vendor CLIs are protocol violations.
Adapters still tee vendor transcripts into `cli.log` while leaving stdout on the
owned pane. Vendors that buffer until completion (for example cursor-agent `-p`
JSON) do not stream progress; `pane-child` therefore prints a start line, periodic
`[fm] … still running` heartbeats (interval `FM_HEARTBEAT_SECS`, default 15, `0`
disables), and a finish line so a captain watching the Herdr tab can see liveness
without opening log files.
The scripted mock adapter remains a non-model test adapter. Dependencies are
Python 3.9+ (standard library), existing shell/jq tools and the chosen vendor CLI;
Herdr and Bun are needed only for their respective features. No model/network
API is required by the managed test suites. The isolated crew-end-to-end fixture
must copy the actual shipped `fm-herdr.py` dependency alongside worker/config/emit
and adapters, use default snapshot/identity startup without outer-checkout helpers,
and retain the real worker-to-board identity and exact actor-removal assertions.
D-335 approves that fixture path only; repository/account boundaries may be mocked.

All four supported model adapters receive the explicit role skill and canonical
identity through their actual launcher prompt, regardless of native instruction
loading. Claude/Codex native root files remain thin routes; an explicitly
dispatched role always wins. This does not claim other engines automatically load
AGENTS.md. Codex final output comes from `--output-last-message`; Claude/Cursor
use a complete JSON result object, and Gemini a complete JSON response object.
Malformed, partial or mixed result output remains inspectable and cannot establish
final-answer provenance. Existing CLI availability and fallback verdict rules
remain in the shared adapter library. Raw CLI exit and adapter verdict exit are
retained separately. Custom/test adapters retain their existing contract; the
launcher cannot infer final provenance from arbitrary custom transcripts.

Vendor fallback retains one logical actor and one owned tab/root pane. Before reusing it,
the launcher rechecks the previous attempt's task/run/terminal/shell identity and
shell-only state, the previous durable ownership receipt and unchanged tab
membership. A tab must still have exactly its owned pane, the canonical label,
workspace identity and no splits. Caller tabs, added panes, moved/reused/shared
resources and unknown topology refuse reuse. Attempts have separate immutable prompts, invocation metadata,
private environment, CLI log, final answer and result JSON under
`state/runs/<actor>/`. A blocked or unavailable attempt is kept there even if a
later vendor completes. Any ownership uncertainty stops reuse. Worker and reviewer
`agent_finished` events retire exactly their run actor; neither event means the
task was accepted. Orchestration exit receipts also remain under the actor. Each chain invocation has
an attempt token; both reviewer output selection and orchestration recording accept
managed receipts only with that current token. A custom/mock fallback reads its own
output files/log slice and records unknown final provenance, preserving the previous
built-in receipt as evidence without adopting its status.

Automatic close defaults on only for a positively completed owned run. The
final assistant answer must end with exactly one standalone
`WORKER_COMPLETE:<task>` or `REVIEWER_COMPLETE:<task>` status marker. Blocked,
failed, incomplete, missing and ambiguous statuses retain the pane even at exit
zero. A completed review may reject the PR. Result JSON, final text, logs and exit
evidence are persisted before close. Immediately before the close command, the
launcher rechecks its ownership record, caller exclusion, canonical label,
run/task tokens, terminal ID, shell PID and nonempty shell-only foreground state.
It also verifies the created tab identity and unchanged single-owned-pane layout
through the installed snapshot API. Ownership records bind tab/workspace and
caller tab/pane IDs to run/task/actor/terminal/shell identities. No whole-tab close
is authorized: a positively verified owned pane may close and its single-pane
tab may disappear as Herdr's normal consequence. Shared or moved resources stay.
Changed, busy, unowned, caller or uncertain panes are never intentionally targeted.
Herdr does not expose atomic compare-and-close: an unrelated external client can
change the pane between observation and close. This is an observed checked-close
policy, not an atomicity or race-free guarantee. `FM_AUTOCLOSE=0` retains all panes.
`FM_HERDR_TIMEOUT` (seconds, default 21600) bounds waiting; a timeout preserves the
process and evidence for inspection, never kills an uncertain pane.

`FM_WATCH=0` opts out of automatic watch startup; stop an already-running watch
explicitly. Watch identity and results live under `state/session/`; a stopped
watch can be restarted, and continuous observation receipts survive restarts.
No global hooks, lavish or no-mistakes installation is needed. Existing user
authorization persists, while scope/product choices and merge approval remain
captain board decisions. The self-update request is not a fabricated board choice.

Decision content should include bespoke before/after diagrams, concrete option
tradeoffs and authored English/Traditional Chinese summaries with derived
Simplified Chinese. The current generic generator does not establish that content
quality. Board diagrams, locale and effects changes are separately T-034 and are
not shipped by this task. Firstmate's decision instructions must integrate the
final T-034 `fm-decide.sh`/`fm-run.sh` contract after firstmate identifies that
version: authored `--details`, exact field types/bounds, honest refusal handling,
custom captain choices and full dynamic locale content. A title-only request is
not an acceptable substitute for that integration; source verification remains
a dependency until the final T-034 version is supplied.
Current-head gate/reviewer verification and original
closed-list protocol remain firstmate/reviewer responsibilities; a successful
process or status marker is never PR acceptance.

`skills/` defines behaviour; changing a skill changes behaviour without
touching code.

After a round, firstmate may open a `skill-update` task — **but it travels the
same pull request, reviewer and seven gates as anything else.** The system
cannot quietly edit itself.

`fm.sh sync-skills` imports from an external skills directory into
`skills/vendor/`, read-only, never writing back, never polluting the user's
global skills.

---

## 12. Failure and recovery

- The truth is `state/events.jsonl`; state is rebuilt by replaying it on start.
  No snapshots.
- `fm-reconcile.sh` walks `state/worktrees/` and `gh pr list` looking for
  orphans, tests worker liveness by pid file, and marks the dead
  `worker_crashed` for redispatch.
- `bin/fm-sync-prs.sh` polls GitHub and writes pull request events back into
  the same log. **A merge the captain performs on GitHub must be noticed by the
  system itself**, not reported to it by a person.
- An adapter exiting `2` moves to the next vendor in `config.yaml` and emits
  `vendor_unavailable`.
- Compaction waits until the log is large enough to slow a replay.

---

## 13. Security

- `/open` accepts localhost only, and the resolved path must sit inside the
  repository.
- Adapters may not run git or gh; a worker never holds a GitHub token.
- The board binds `127.0.0.1` and opens no external port.
- The repository is public so that branch protection is available, which means
  nothing secret may enter it — no local paths, no credentials, no customer
  content. That includes the design and task list of every registered project;
  section 15.8 names the captain decision private projects are waiting on.
- Every crew round runs under one permission policy fm owns (13.1).

### 13.1 Crew permissions (T-105)

A worker used to inherit the operator's personal CLI settings: on the
captain's machine that allowed gh-axi, Herdr, a browser, reading any path
and editing `~/.claude/skills`, and refused bun, npm, python and chmod.
cursor-agent ran with `-f` and no sandbox; codex and gemini ran on vendor
defaults. Now every round, worker or reviewer, whatever its vendor, runs
under one policy fm owns.

**The policy.** `fm_policy <role>` in `bin/fm-config.sh` resolves it from
`config.yaml`'s `policy:` block, flat keys for both roles or a `worker:` /
`reviewer:` block for one, with the project's `projects.<name>.policy:` over
it. The keys are `network` (the registries the round's commands may reach;
default none; a later layer replaces an earlier one), `read` and
`never_read` (added to, never replacing) and the `procs` / `cpu` ulimits.
Everything else is a floor no key loosens:

- writes: the worktree or checkout, and TMPDIR;
- reads: default-deny outside the write roots and the toolchain; never
  `~/.ssh`, `~/.config/gh`, cloud credentials, any vendor's home but for that
  vendor's own auth, fm's `state/` and the other worktrees in it;
- commands: allowed inside the sandbox; git push, gh, Herdr, browsers and
  MCP refused;
- network: the declared registries only; GitHub and loopback are refused
  as values, and refused again by the proxy whatever a policy file says;
- no unix sockets; `GH_TOKEN`, `GITHUB_TOKEN`, `SSH_AUTH_SOCK` and cloud
  credentials scrubbed; the repository's `.claude/`, `.mcp.json`, `.cursor/`
  and `GEMINI.md` not loaded.

Before T-105 the run-mode reviewer's hosts were `reviewer: network:`; that
key still counts for a reviewer when no policy layer declares a network.

**Two layers.** An adapter translates the policy into its CLI's own flags
and declares which of the eight dimensions (`write read network sockets env
repo-config refuse ulimit`) they enforce. `bin/fm-sandbox.sh` runs the CLI
inside an OS sandbox built from the same policy: `sandbox-exec` on macOS,
which covers all eight - the network is a per-round proxy that allows the
declared registries and the vendor's own service, and is the only address
the profile lets the round reach - and `bwrap` on Linux, which mounts only
what the round may read but shares the network, so network, sockets and
the refused operations stay the vendor's. Before the CLI starts the adapter
checks the union; a dimension neither covers refuses the round with 2, the
fallback chain moves on, and nothing runs less confined than its policy.

A seatbelt cannot be applied inside another, so under macOS's sandbox the
vendors' own seatbelt sandboxes (claude's, codex's workspace-write,
cursor-agent's) are switched off and the outer one confines their commands;
their permission rules stay. On Linux they stay on. claude reuses T-066's
settings builder for every round; cursor-agent drops `-f` for `--trust
--sandbox`; gemini's flags enforce no OS dimension, so it runs only where
the OS sandbox covers them all.

**A blocked host.** The proxy records every host it refused to the round's
`FM_POLICY_BLOCKED` file. `fm-worker.sh` and `fm-review.sh` report them on
stderr and on the board, and append one record to
`state/policy/blocked-hosts.jsonl`; firstmate raises a choice card to add a
host to the project's `policy: network:`. The crew never widens its own
policy. The board event and firstmate's card step are outside T-105's
scope: `fm-emit.sh` has no event type for it yet, and the firstmate skill
does not read the record yet.

**Evidence.** `tests/adapter-contract.test.sh` and `tests/sandbox.test.sh`
check each vendor's flags and the sandbox profile against the policy, that a
vendor missing a dimension without the OS sandbox is refused, that declared
registries reach both layers, and that loopback and GitHub never do - with a
stand-in for the sandbox binary, since a runner cannot be relied on to have
one. `bin/fm-canary.sh`, not part of CI, runs one real round per installed
vendor that tries to write outside, read `~/.ssh`, reach github.com and
127.0.0.1:4173 and connect to the Herdr socket, and records the result per
vendor and version in `state/canary/results.jsonl`.

---

## 14. The task DAG

The task list is `design/tasks/`, one file per task: `design/tasks/<id>.json`
holds that task's entry and nothing else, with `id`, `title`, `milestone`,
`depends_on`, `scope`, `bootstrap` and `acceptance`. `scope` is the glob
allowlist gate 4 enforces. There is no table here: `bin/fm.sh tasks` prints
it on demand, grouped by milestone, with id, title and dependencies. Nothing
generated is committed.

Tasks marked `bootstrap` are built by hand: they are the dispatcher and its
gates, and the dispatcher cannot dispatch itself.

**Why one file per task (T-090).** The list used to be one array in
`design/tasks.json` plus a hand-kept copy of it as a table in this section.
Every pull request that added or revised a task appended to the tail of the
same array and the same table, so with `main` requiring up-to-date branches
every merge turned every other open pull request into a conflict, resolved by
hand and force-pushed — once dropping a design section on the way. Parallel
work must never write the same text: adding a task adds a file, revising one
edits only its file, and two branches that each add a task merge cleanly.

**Readers.** Every reader goes through `bin/fm-config.sh`: `fm_tasks [dir]
[rev]` lists every task (one JSON object per line, in id order), `fm_task <id>
[dir] [rev]` reads one, and `fm_tasks_write` writes entries out as files. With
a `rev`, they read a branch rather than the working copy — gate 4, the worker
and the reviewer read the branch under test. The board reads the list through
the same `fm_tasks`. `bin/ci.sh`'s DAG stage runs `fm_tasks_check` on every
registered task directory: every file parses, its `id` is its file name, every
dependency has a file, no task waits on itself through any chain, and no
`design/tasks.json` is left beside the directory.

**Order.** `fm_tasks` lists tasks by id, compared as versions (`sort -V`):
`T-2` before `T-9` before `T-10`, `SK-001` before `T-001`. The old array's
order was the order entries were appended, and nothing else kept it; it is
gone with the array. That order is the dispatcher's: when there are fewer
free slots than ready tasks, the ready tasks earliest in it start first.

**All or nothing.** A task file that does not read as one JSON object, or a
missing directory, is no task list: `fm_tasks` prints nothing, names the
file and returns 1, and every caller refuses rather than act on the files
that did read — the dispatcher dispatches nothing (`65`), `self-update`
takes no id, `bin/fm.sh tasks` prints no table and the board shows no task.
A name that starts with a dot (`.DS_Store`, an interrupted `--adopt`'s
scratch) is not a task file and is not read or checked.

**Bringing over a branch opened before this.** A branch cut before this
landed still carries `design/tasks.json`, and nobody has to run anything
for it:

- *Reading it.* With a branch to read, `fm_task` takes the task's own file
  there and, when the branch has none, its entry in that branch's
  `design/tasks.json`, saying so on stderr. So the worker, the reviewer and
  gate 4 read a task defined only on its branch, or revised there, as that
  branch says it, never as `main` has it or not at all.
- *Moving it.* The first round that finds such a branch no longer rebasing
  onto `main` rebuilds it (section 5.3.3), and the rebuild moves every
  entry the branch added or changed since it left `main` into its own file,
  removes any it removed, and deletes the array. An entry `main` changed
  too is handed to the worker with conflict markers, never dropped. Rows
  the branch added to the old table go with the table.
- *Scope.* A branch whose scope names `design/tasks.json` keeps its right
  to carry its own entry: gate 4 reads that glob as `design/tasks/<id>.json`,
  that task's file and no other. A design task that also wrote other tasks'
  entries now touches their files, which gate 4 names; widening its scope
  to `design/tasks/**` is the captain's call, as any scope change is.

By hand, the same move is `bin/fm.sh tasks split <id>` for each entry the
branch added or changed. T-090's own branch was the first to come over.

**The migration.** It was mechanical: each entry of the array written,
unchanged, to its own file, which is what `bin/fm.sh tasks split` does. The
array's two top-level keys went with it: `$schema` named a
`tasks.schema.json` that never existed, and `concurrency` had no reader —
the dispatcher's limit is `config.yaml`'s. A test compares the first commit
that removed `design/tasks.json` with its parent: the files, in the old
array's order, are the old array. That comparison needs history, so it runs
under gate 3 and locally, not on the required GitHub check, whose checkout
is one commit deep; there the test asserts only that nothing still tracks
`design/tasks.json`. The test that the split itself loses nothing — a
fixture array, unicode and key order included — runs everywhere.

---

## 15. Driving other repositories (the external model)

Captain decision D-049 chose option B: **one external installation.** This
repository holds the engine (`bin/`, `skills/`, `board/`), the design and task
list of every project, and all runtime state under `state/`. It drives target
repositories, which receive only the branches and pull requests of their own
tasks and carry nothing of firstmate's.

This section is the plan; the M3 tasks in `design/tasks/` implement it. Until each
one merges, sections 5 to 12 describe the running system. Every M3 task keeps
self-hosting working on its own: this repository is registered as a project,
it is the default, and a script called without `--project` behaves exactly as
it does today.

### 15.1 Two roots, and how a script learns which is which

There are three trees, of which two are roots:

| Tree | What it is | How a script finds it |
|---|---|---|
| code tree | the frozen snapshot of `bin/` and `skills/` a launch runs from (section 11) | `FM_CODE_ROOT`, unchanged |
| **engine root** | this repository's checkout: `config.yaml`, every project's design and task list, `state/` | `--repo` / `FM_ROOT`, unchanged in meaning |
| **project root** | the git repository a task's diff lands in | only from the registry, via `--project` / `FM_PROJECT` |

`--repo` and `FM_ROOT` keep meaning *where the configuration, the task lists
and the state are*. Every caller, fixture and hook that passes them today is
already passing the engine root, so none of them changes meaning.

The project is always named, never inferred. One library function in
`bin/fm-config.sh` resolves it: `--project <name>` wins, then `FM_PROJECT`,
then `default_project` from `config.yaml`. No script reads the project from the
current directory, a git remote or the worktree it happens to be in — a run
must not change project because a shell was somewhere else. A name the registry
does not hold exits `65`, like an unknown task. Scripts export `FM_PROJECT` and
the resolved `FM_PROJECT_ROOT` to their children so nested launches cannot
disagree; adapters still receive only their worktree.

A project's root is either the engine root itself (`repo: .`, which is how
this repository hosts itself) or an **engine-managed clone** at
`state/projects/<name>/repo`, cloned from the project's GitHub repository.
Managed clones, rather than a path to the captain's own checkout, because:

- the engine repository is public (section 13), so no local absolute path may
  be committed into its registry;
- the captain's own checkout of a target is never touched — no worktree
  metadata, hooks or branches appear in it;
- firstmate owns the clone's fetch and prune life cycle, as it owns
  `state/worktrees/` today.

### 15.2 The registry

`config.yaml` gains `default_project` and a `projects:` map:

```yaml
default_project: firstmate-workflow
projects:
  firstmate-workflow:                     # this repository, hosting itself
    repo: .
    github: BenjaminLu/firstmate-workflow
    base: main
    required_check: ci
    design: design/design.md
    tasks: design/tasks                   # a directory, one file per task (T-090)
    project:                              # T-043's contract, whole, from T-050 on
      ...
  example-app:                            # an external target
    github: example-org/example-app
    base: main
    required_check: check
    # design and tasks default to projects/example-app/design.md and .../tasks/
    project:                              # T-043's contract, whole
      ...
```

| Field | Meaning | Rule |
|---|---|---|
| name (the key) | the project's identity everywhere: events, decisions, pins, paths | `[a-z0-9-]`, at most 24 characters |
| `repo` | `.` for the engine itself; absent means the managed clone | any other value is refused (exit `65`) — a committed local path would publish one |
| `github` | `owner/repo` pull requests are opened on | required |
| `base` | the branch tasks branch from and target | required; gates 1, 2 and the guard use it instead of a literal `main` |
| `required_check` | the status check name branch protection requires | required; gate 6 and target verification read it |
| `design`, `tasks` | paths **relative to the engine root**; `tasks` is a directory, one file per task (T-090) | default `projects/<name>/design.md` and `projects/<name>/tasks`; a `tasks` value in the old shape, `<path>.json`, names the directory `<path>` beside it |
| `project` | T-043's `project:` block, every field of it | T-043's merged text and the README define the fields and their meaning; this section only moves the block under a project and never re-lists it, so a field T-043 has or later gains — `docs` included — moves with it |

**Where gates 3 and 5 read the contract.** From the task's spec pin (15.5),
which records the contract verbatim next to the spec. Nothing else: not the
branch under test, which in a target has no `config.yaml`, and not the engine's
working copy, which can change during a run. The pin takes the contract from
the engine's `main` head at pin time — also for a self-hosted task whose spec
is pinned from its own branch — because the contract a task is judged by must
be one the captain has already merged. This replaces T-043's rule that the
contract is read from the branch under test. T-043's gate-4 rule survives in
its narrower form: a branch may change `config.yaml` only if its pinned scope
names it, and such a change never alters its own gates; it applies to tasks
pinned after T-049 merges.

**One source of truth during the transition.** The contract is written in
exactly one place at every commit. Until T-050, that is T-043's top-level
`project:` block: the self entry carries no copy, `bin/fm-config.sh` resolves
the default project's contract to the top-level block, and gates 3 and 5 keep
T-043's behaviour. T-049's pins record that resolved contract. T-050 moves the
block, unchanged, to `projects.firstmate-workflow.project` and deletes the
top-level one in the same commit, and switches gates 3 and 5 to the pin. A
`config.yaml` holding both the top-level block and the self entry's is refused
(exit `65`), so the two can never disagree. Re-deriving a pinned contract
(15.5 step 3) reads the block wherever the recorded commit's `config.yaml`
holds it: the top-level `project:` block if that commit has one, otherwise
the project's registry entry. A pin recorded before T-050 therefore still
verifies after T-050 merges, with no repin, and a task in flight across that
merge keeps the contract it was pinned with.

`bin/ci.sh`'s DAG check (section 14) runs once for every registered task
directory and names the project on failure; a registered directory that does
not exist is red, not skipped. A tree with no `projects:` map (the test
fixtures) keeps the one `design/tasks` directory.

**The interface (T-046).** `bin/fm-config.sh` holds the resolver every later
task calls; each function takes the engine's `config.yaml` as its last,
optional argument, and the directory holding it is the engine root:

| Function | Answers |
|---|---|
| `fm_project_resolve [explicit]` | the project: `explicit` (a script's `--project`), else `FM_PROJECT`, else `default_project` |
| `fm_project_get <name> <field>` | `repo`, `github`, `base`, `required_check`, `design`, `tasks` (with the defaults above), or `root` |
| `fm_project_contract <name> <field>` | the fields `fm_project` answers, for that project; the self entry reads the top-level block |
| `fm_project_use [explicit]` | resolves and exports `FM_PROJECT` and `FM_PROJECT_ROOT` |
| `fm_projects` | every registered name, in file order |

Every call validates the whole registry first, each entry's nested `project:`
block included, so one malformed entry refuses every lookup (exit `65`, naming the project and field) rather than only the
lookups that touch it. Besides the rules in the table, it refuses an unknown
field in an entry, a name registered twice, a second entry with `repo: .`, and
a `design` or `tasks` path that is absolute or climbs out with `..` — the same
reasoning as `repo`: nothing outside the engine root may be named.

### 15.3 Where each project's things live

| What | Self project | Any other project |
|---|---|---|
| design | `design/design.md` | `projects/<name>/design.md` (engine root, committed) |
| task list | `design/tasks/` | `projects/<name>/tasks/` (engine root, committed) |
| checkout | the engine root | `state/projects/<name>/repo` |
| worktrees | `state/worktrees/<task>` | `state/projects/<name>/worktrees/<task>` |
| spec pins | `state/pins/<name>/<task>/` | `state/pins/<name>/<task>/` |
| events | `state/events.jsonl` | the same log, carrying `project` |
| decisions | `state/decisions/D-*.json` | the same directory, carrying `project` |
| runs, reviews, unsent, rescued | `state/runs/<actor>/` and siblings | the same, with `project` in `identity.json` |

The self project keeps its current paths so no merged test, cleanup rule or
recovery path moves. Each worktree root keeps section 5.2a's rule — cleanup
removes only a direct child of **that project's** root.

Task ids are unique within a project, not across projects: the key is
`(project, task)`. One event log, not one per project, because it keeps one
writer lock, one replay and one board; a per-project log would multiply every
recovery path in section 12.

### 15.4 How the log, the board and decisions name the project

- **Events** gain a top-level `project` field, written by `fm-emit.sh
  --project` and validated against the registry (unknown exits `65`). An event
  without it belongs to the default project, so every line already in the log
  stays valid. Every event about a non-default project carries it. `pr` stays
  a number; `(project, pr)` is the key.
- **Decisions** carry `project` in the request and the response. Captain
  decision D-1015 (option A) chose the id scheme: **every new decision id
  names its owner**, `D-<project>-<task>-<n>`, for example
  `D-firstmate-workflow-T047-1`. `<project>` is the resolved project's
  registry name (`--project`, then `FM_PROJECT`, then the default); `<task>`
  is the task id without its hyphen (`T047`); `<n>` starts at 1 and counts
  only within that project's task. `fm-decide.sh --allocate` takes the next
  free `n` — past every `n` that task already has, reserved, pending,
  answered or archived — under that task's own lock and reserves it under
  `state/decision-ids/<project>/<task>/<n>.json`, so the details and any
  authored drawing can be written under the id before `--request` publishes
  it; `--request` refuses an owned id nobody allocated. There is no global
  counter and no lock across tasks or projects. Merge cards and hand-raised
  cards use the same form: `fm-run.sh` allocates its merge card's id this way
  and never derives `D-<task digits>` again. A project name is `[a-z0-9-]`
  and the task part starts with an upper-case `T`, so the id splits one way
  only; the board shows the project and task read out of it. Ids made before
  this — `D-<digits>` and `D-SK-<n>` — stay valid wherever an id is read and
  are never renamed or moved: no id a new card takes can equal one, so
  nothing old has to leave. Every parser of ids and every store keyed by one
  (`state/pending/`, `state/decisions/`, `state/decision-details/`,
  `board/public/diagrams/`, `design/diagrams/`, the watcher's receipts)
  accepts both forms. Merge cards name the project and link the pull request
  on the project's GitHub repository. A tree with no `projects:` map (every
  tree before the registry, and the test fixtures) is the engine hosting
  itself. Its ids are owned by `firstmate-workflow`. Its cards and their
  events record no project, because there is no registry to validate one
  against, and naming any other project there exits `65`. The board passes a
  card's recorded project to `fm-merge.sh`, never the owner read from its id.
- **`fm-sync-prs.sh`** polls every registered project's repository
  (`gh --repo`) and writes what it finds with that project; one project it
  cannot read does not stop the others. **`fm-merge.sh --project`** merges on
  that project's repository and writes its `merged` event with the project.
  `(project, pr)` is the key: a pull request number in one project never
  matches another project's event. `fm-run.sh` resolves its project once and
  advances only that project's `pr_opened` and `merged` events. An event with
  no project counts as the default project's. So another project's #7 is never
  gated, carded or merged as this project's #7.
- **The board** shows a project chip on lane cards, crew bubbles and decision
  cards, and filters with `?project=`; without it, it shows all projects. Chip
  labels come from the UI dictionaries; a project's name is data and is not
  translated. Dynamic summaries still carry `en` and `zh-TW`.
- **Crew identity** is unchanged: the locked run counter already makes labels
  unique across projects. `identity.json` records the project.

### 15.5 Gate 4 under the external model

Today gate 4 reads the task's scope from its own file, `design/tasks/<id>.json`,
**on the task's own branch**, falling back to the working copy (T-090). Under option B a target's
branch has no task list, and the engine's working copy can change during a
run. Both sources go.

1. **Source.** The scope comes from the project's task list in the engine
   repository, at a **pinned engine commit** — never from the target branch and
   never from the engine's working copy.
2. **Pinning.** On a task's first round `fm-worker.sh` writes
   `state/pins/<project>/<task>/1.json` holding the project, task, engine
   commit, task-list path, the spec verbatim, its SHA-256, the design path, the
   target base commit, and the project's T-043 contract verbatim with the
   engine `main` commit it was read from and its SHA-256 (15.2), and emits
   `spec_pinned`. The engine commit is the
   engine's `main` head, which must contain the task. The self project has
   one exception, because that is how a self-hosted task arrives today, this
   one included: a task not yet on `main` is pinned from its own branch's
   commit if the entry is there, and otherwise from the engine's working copy
   with `engine_commit: null`. Such a task must commit that same entry on its
   own branch, which self-hosted acceptance already requires.
3. **Reading.** Every later round, gate run and review reads the highest
   numbered pin. With an engine commit, it re-derives the spec from
   `git show <commit>:<tasks path>`; a hash mismatch fails the gate, so an
   edited pin file is caught. Without one, the branch's own entry must match
   the pin's hash; that is the only tamper check such a pin has — nothing ties
   it to a commit, so an edit made to the pin file and the branch entry
   together passes the gates, and the captain reading that entry in the pull
   request's diff is the remaining check. The contract is
   re-derived and hash-checked the same way from its own commit, which always
   exists, reading the block from wherever that commit holds it (15.2). Later commits to the engine's `main` do not reach a pinned
   run. Pin files are append-only and never rewritten.
4. **Changing scope.** The worker still says so and stops. Firstmate raises a
   `choice` card. If the captain authorizes it, the new spec is committed to
   the engine repository through an ordinary engine pull request, merged on a
   merge card. Then `fm-project.sh repin --task <t> --decision D-<n>` writes
   the next pin citing both, with spec and contract read afresh from that
   commit. It refuses unless the decision record is a
   `decision_made` for that project and task with the authorizing option, and
   the new commit is on the engine's `main` with a spec that differs. It emits
   `spec_repinned`. The decision records who authorized the change; the commit
   records what was authorized.
5. **Failing.** Gate 4 fails with no pin, with a mismatched pin, with a changed
   file outside the pinned scope, and — for a self-hosted task — when the
   branch's own task-list entry differs from its pin. The last one is new: a
   self-hosted pull request can no longer widen its scope by editing its own
   entry. In a target it also fails on any firstmate artifact (15.6),
   whatever the scope says.
6. **What the reviewer and the gates see.** `fm-review.sh` builds its prompt
   from the pinned spec and the project's design at the pin's commit (15.7).
   The pull request body on the target carries the task id, title, acceptance,
   scope and `spec pin: <project>/<task>#<n> <sha256 prefix>`, so a person on
   the target sees what the reviewer saw. Gate 7 keeps its marker and reads
   the target pull request's comments.

`spec_pinned` and `spec_repinned` join the event types in section 5.1.

### 15.6 Git and GitHub for a target

Pull requests open on the project's `github` repository against its `base`,
from the managed clone, with `gh … --repo <owner/repo>`. Merge, sync and
cleanup name the same repository.

**What a target needs**, checked by `fm-project.sh verify <name>` before any
dispatch to it; a failure refuses dispatch with exit `70` and names the item:

- `base` protected, `enforce_admins` on, the branch required to be up to date,
  and `required_check` a required status check;
- a workflow on the target that runs the declared `check` under the
  `required_check` name. It arrives through the target's own review — added by
  its owner, or by a firstmate task whose pinned scope names it — never as a
  side effect of other work;
- the fm-guard hooks active in the managed clone: `core.hooksPath` in the
  clone's local git config points at the engine's `.githooks/`, and the guard
  protects `main`, `master` and the project's `base`. The hooks are never
  copied into the target's tree;
- the captain's credentials able to push branches and open pull requests.

`fm-project.sh sync <name>` makes the clone that way (T-048): it clones
`<owner>/<repo>` from `FM_GITHUB_URL` (GitHub unless a fixture stands in),
or fetches and prunes the clone already there; sets `core.hooksPath` to the
engine root's `.githooks/` and `firstmate.base` to the project's `base` in
the clone's local config; and adds `.fm-*` to its `.git/info/exclude`. It
runs git only in a directory that is its own repository, reached without a
symlink, under `state/projects/<name>/`, whose `origin` is the project's
repository; anything else is refused with exit `70`. The guard and both
hooks read `firstmate.base` and protect it on top of `FM_PROTECTED`
(`main master`), so a checkout without the key — the self project's among
them — keeps exactly that set, and a task worktree of the clone shares it.
`verify` checks the protection, public-only (15.8) and guard items above,
through `gh api` for the base's protection and the repository. It also
checks the clone's `origin`, since a guarded clone of another repository
guards nothing of the target's, and takes the hooks directory from git
itself, which expands `~` and reads a relative path from the clone. It
names every missing one before it exits `70`. The workflow and the
credentials are not machine-checked yet. For the self project both
subcommands are no-ops that succeed.

**What firstmate never writes into a target:**

- a commit to `base` or any protected branch, or a force-push to anything but
  the task's own branch;
- any of its own artifacts: designs, task lists, pins, state, events,
  decisions, skills, `config.yaml`, prompts, logs, `.fm-say.md`,
  `.fm-prompt.md`. The clone's `.git/info/exclude` keeps `.fm-*` local, and
  gate 4 fails on any `.fm-*` path;
- repository settings, branch protection, secrets, labels, webhooks, releases
  or tags;
- committed git configuration or hooks, or changes to the target's own
  `AGENTS.md`, `CLAUDE.md` or CI workflows, unless the pinned scope names them;
- anything outside the pinned scope.

The self project follows the same rules, except that its design and task list
legitimately live in its own tree.

### 15.7 Roles when the checkout is not this repository

Routing does not depend on the checkout. Section 11 already delivers the role
skill and canonical identity through each adapter's launcher prompt, so a
target without firstmate's `AGENTS.md` routes the same. A target's own
`AGENTS.md` or `CLAUDE.md` are that project's coding instructions; the
explicitly dispatched role still wins, as it does here.

The prompt carries from the engine side what the checkout cannot:

- the role skill and the pinned spec, as today;
- the project's design context: the design file at the pin's commit, bounded
  in size, with any truncation stated in the prompt rather than silent;
- the project's gate facts: `base` and the pinned T-043 contract that gates 3
  and 5 will apply;
- the absolute path of the checkpoint helper in the frozen code tree, because
  a target has no `bin/fm-checkpoint.sh`.

The worker and reviewer skills stop pointing at repository-relative files
(`design/design.md`, `design/tasks/`, `bin/fm-checkpoint.sh`) and refer to
"the design, scope and checkpoint command in your prompt". The self project
gets the same prompt shape. The reviewer still sees the diff, the spec and the
design, and given the pull request the head's CI and gate evidence (section
7) — never the worker's reasoning (R2). Firstmate itself always runs in
the engine root and names the project on every script it calls.

### 15.8 Open captain decision: private projects

Section 13 keeps the engine public so branch protection is available, and
D-049 puts every project's design and task list in the engine. A private
target's design would therefore be published. This design does not guess:
until the captain decides, **only projects whose GitHub repository is public
may be registered**, and `fm-project.sh verify` refuses a private one.

The card to raise when a private project is wanted:

- **A** — the engine stays public; a private project's design and task list
  live in a separate private repository that the registry names;
- **B** — the engine repository becomes private, which needs a plan that
  offers branch protection on private repositories;
- **C** — keep today's interim: public targets only.

### 15.9 Order of work

The M3 tasks in `design/tasks/` carry the exact scopes and acceptance. The order
follows one rule: each merges on its own, and after each one this repository,
as its own default project, still drives itself with no change to any caller.

1. T-046 the registry and root resolution — nothing reads them yet.
2. T-047 `project` on events and decisions — absent means default.
3. T-048 `fm-project.sh` clone, verify and guard — nothing dispatches yet.
4. T-049 pins and the new gate 4 — the self project is pinned too.
5. T-050 the other gates read the project and the pinned contract; the
   contract block moves under the self entry — its values are today's.
6. T-051 the worker and the reviewer in a target checkout.
7. T-052 prompts carry the engine-side design.
8. T-053 dispatch, run and session across projects.
9. T-054 the board shows which project.
10. T-055 a fixture target driven end to end, and the README for registering one.

T-047, T-052, T-053, T-054 and T-055 each carry their part of section 15.10
in their acceptance and depend on T-056, which wrote that section and changed
no code.

### 15.10 Several projects at the same time

The captain runs work in several projects at once from one board. This is a
requirement, not a consequence of the rest of section 15, and T-053, T-054 and
T-055 each prove their part of it with a test that has two registered projects
live at the same time.

**1. Runs in different projects are live together, up to the one global
limit.** `config.yaml`'s `concurrency` stays one number for the whole
installation, counted over every project: a run in `example-app` and a run in
`firstmate-workflow` each take one slot of the same limit. Nothing
project-scoped is shared or locked across projects:

| Thing | Scoped to | Why it cannot collide |
|---|---|---|
| spec pins | `state/pins/<project>/<task>/` | the path carries the project |
| worktrees | each project's own worktree root (15.3) | cleanup removes only a direct child of that project's root |
| checkout | the engine root, or `state/projects/<name>/repo` | one clone per project; its fetch and prune never touch another |
| guard | `core.hooksPath` in each checkout's local config, protecting that project's `base` | a hook runs in the repository it guards and nowhere else |
| panes and runs | one tab and one owned pane per run actor (section 11) | the locked run counter makes actors unique across projects |
| decisions | one card per request, carrying `project` | every id names its project and task, `D-<project>-<task>-<n>`, with `n` allocated under that task's own lock (below) |
| merges | the project's own `github` repository | see point 3 |

The decisions row was checked because the old scheme did collide.
`fm-run.sh` derived `D-<task digits>` with no lock, and cards firstmate raised
by hand took numbers from the same `D-<n>` range, so by 2026-09-24 the
derived ids of every task from T-046 to T-057 were held by records raised for
other tasks (T-043's hand-raised `D-056` among them), and `fm-run.sh`, finding
the file, took it for the task's own card and silently raised none.

Captain decision D-1015 (option A) settled it with one rule instead of two
spaces and a migration: **every new id names its owner**,
`D-<project>-<task>-<n>` (section 15.4).

- **nothing is shared.** `(project, task)` is unique, and `n` counts only
  within it, so two projects' `T-004` get `D-a-T004-1` and `D-b-T004-1`, and
  two tasks never share an id. `fm-decide.sh --allocate` takes the next free
  `n` under that task's own lock (`state/decision-ids/<project>/<task>.lock`)
  and reserves it; there is no global counter and no cross-project or
  cross-task lock. Merge cards (`fm-run.sh`) and hand-raised cards take their
  ids the same way.
- **nothing old moves.** A project name is `[a-z0-9-]` and the task part
  starts with an upper-case `T`, so an owned id can never equal a
  `D-<digits>` or `D-SK-<n>` id. Old records therefore keep their ids and
  every store keyed by them; nothing is renumbered, no map is kept, and no
  reader has to resolve one id through another. `fm-run.sh` looks only at ids
  naming the task's own project and task, so an old record at the id the task
  used to derive — T-043's `D-056` beside T-056 — is never read, moved or
  overwritten, and T-056 gets `D-firstmate-workflow-T056-1`.
- **every reader takes both forms.** `fm-decide.sh`, `fm-diagram.sh`, the
  board's response listing and decision route, `board/public/diagram.js` and
  the page accept an owned id alongside the old ones and refuse anything else
  (a bad project name, no task, `n` of 0, path characters) before an id is
  joined to a path. The stores keyed by an id — `state/pending/`,
  `state/decisions/`, `state/runtime/archived-pending/`,
  `state/decision-details/`, `board/public/diagrams/`, `design/diagrams/` and
  the watcher's `state/session/` receipts — take the new form as a file name
  unchanged (`tests/session.test.sh` observes, lists and acknowledges an owned
  id). The watcher's own check is only `[A-Za-z0-9_-]+`: it refuses path
  characters, but it does not hold the id grammar, so it would also take a
  malformed id such as `D-Bad_Name-T047-1`. No writer produces one, since
  every card is requested through `fm-decide.sh`, which does hold it.
  Tightening the watcher is `bin/fm-herdr.py`'s work, outside T-047.
- **authored content is written under the allocated id.** `--allocate` comes
  first, so firstmate writes `state/decision-details/<id>.json` and any
  `design/diagrams/<id>.*` under the id the card will carry, then requests
  it. `fm-run.sh` names the id it allocated when details are missing and
  reuses it on a later turn.

The stores keyed by a decision id were found by a search a reader can re-run
from the repository root:

  ```
  grep -rnE 'state/(pending|decisions|decision-details|session)|(public|design)/diagrams|watch-|observed|acknowledged|decision:' bin board skills tests
  grep -rhoE '(state|board/public|design)/[A-Za-z0-9_./-]*' bin board skills tests | sort | uniq -c
  ```

  The first finds every place that builds a path or identity from a
  decision id. The second lists every runtime path the code names at all, so
  a store under an unexpected directory would show up; each was read to see
  what keys it. On 2026-09-24 the hits were:

  | Where | What is keyed by the decision id |
  |---|---|
  | `bin/fm-decide.sh` | `state/pending/<id>.json` written, `state/decisions/<id>.json` awaited |
  | `bin/watch-decisions.ts` | `state/decisions/<id>.json` awaited (not a hit itself: `fm-decide.sh` hands it the directory and the id) |
  | `bin/fm-run.sh` | `state/pending/`, `state/decisions/`, `state/decision-details/<id>.json` |
  | `bin/fm-diagram.sh` | reads `state/pending/` or `state/decisions/<id>.json`; authored `design/diagrams/<id>.*` beats the task stem; writes `board/public/diagrams/<id>.*` |
  | `bin/fm-herdr.py` | `state/session/observed/<id>.json` (`watch_child`), `state/session/acknowledged/<id>.json` (`acknowledge`, `unacknowledged`), `state/session/watch-<id>.json` and its directory (`watch_start`, `watch_stop`, `status`) |
  | `bin/fm.sh` | `state/decisions/D-SK-<n>.json` for self-update, a shape an owned id cannot take |
  | `board/server.ts` | `state/pending/<id>.json`, `state/decisions/<id>.json` and its `.tmp`, `identity` `decision:<id>`, `decision_made` events by `data.decision` |
  | `board/public/index.html` | `seen` set and the order animation, keyed by `identity` |
  | `skills/firstmate/SKILL.md` | the same stores named for firstmate: `design/diagrams/<decision>.*`, `board/public/diagrams/`, `state/decision-details/<decision-id>.json`, `fm-session.sh ack --decision <id>` |
  | `skills/firstmate/clear-zombie-workers/SKILL.md` | `state/runtime/archived-pending/<id>.json`: step 6 moves a stale pending card there by hand, under its own name (found by the second search, not the first) |
  | `tests/` | fixtures of those same stores (`decide`, `decisions`, `diagram`, `board`, `session`, `selfupdate`, `i18n`, `e2e-loop`, `e2e/board.spec.ts`, `e2e/fixture.ts`); none names another |
  | `tests/dispatch.test.sh`, `skills/worker/SKILL.md` | the word "observed" in prose; not a store |

  The other runtime paths the second search listed on 2026-09-24, each read
  where it is written, and what keys them: by task, `state/worktrees/<task>`
  and its `.pid`, `state/dispatch/<task>.log` (`fm-dispatch.sh`),
  `state/rescued/<task>-<stamp>` (`fm-worker.sh`, clear-zombie-workers) and
  `state/unsent/<task>-…`; by run actor, `state/runs/<actor>/`,
  `state/runtime/archived-runs/`, `state/runtime/run-*.sh` and
  `state/runtime/*.pid` (dispatch-crew and clear-zombie-workers skills) and
  `state/.crew-status-throttle/<actor>` (`fm-emit.sh`); by task and round,
  `state/reviews/<task>-r<n>.log`; by a fresh temporary name,
  `state/snapshots/code-*` (`fm-herdr.py` `snapshot`); by nothing, the
  single files `state/events.jsonl`, `state/.events.lock`,
  `state/session/board.log` and `state/session/project-setup.log`; and by
  `SK-<n>`, `state/skill-updates/`. `state/merge-calls` and `state/e2` exist
  only in tests (a stub's log and a temporary copy of the event log). That
  is every path the search printed; nothing under `state/runtime/` other
  than the four named was read, because the code names no other. Every
  store keyed by a decision id takes an owned id as a file name as it is, so
  none of them changed; `state/decision-ids/<project>/<task>/`, the
  allocator's reservations, is the one store this adds, and it is keyed by
  project and task, not by id. Nothing is renumbered, so nothing in this list
  is moved, and the event log's `data.decision` and the board's
  `decision:<id>` identity keep meaning the id they were written with.

Three things are deliberately global, and each is a short critical section,
not a lock held for the length of a run: the event log's writer lock
(`fm-emit.sh`), the run-counter lock that numbers run actors (section 11), and a
**dispatch slot lock** that `fm-dispatch.sh` holds only while it counts live
runs and emits `dispatched`. The slot lock is new. Without it two dispatches
started at once — one per project, which is now the ordinary case — can each
count the same free slot and together exceed the limit. Everything slow
happens before it is taken: `fm-project.sh verify` (a GitHub call), reading
each project's task list and the `greenlit` check pick the candidates first,
and under the lock `fm-dispatch.sh` only recounts live runs, takes the free
slots and emits. Live runs are counted by `(project, task)`, not by task id,
because two projects can both have a `T-004` live.

**2. The limit has no per-project share; free slots are filled fairly.** A
reserved share would idle slots: with the default limit of three and two
projects, any split leaves a slot empty whenever one project has no ready
work, and a share per project has to be re-cut every time a project is
registered. Fair filling gives the same protection against starvation without
idling anything.

Fair fill is the normal path, not an option someone has to remember.
`fm-dispatch.sh` with no `--project` dispatches across every registered
project and fills free slots one at a time: each slot goes to the registered
project, among those with a ready task whose `greenlit` matches it and whose
`fm-project.sh verify` passes, that has the fewest live runs; a tie goes to
the project whose name sorts first. With only the default project registered
that is exactly today's dispatch, so no existing caller changes. The caller is
firstmate, at every dispatch step of its loop — after a green light and
whenever a run ends — and the firstmate skill says to dispatch with no
`--project` (T-052). `--project <name>` dispatches only that project, within
the same global limit and under the same slot lock; it is a deliberate
override that bypasses fair fill, so firstmate uses it only when the captain
asks for one project's work, never as its routine dispatch.

So one project can hold every slot only while no other project has ready
work, and it loses the next freed slot as soon as another does. There is no
preemption: a live run is never stopped to make room. Starvation is therefore
bounded by run length, not removed — a project whose task becomes ready while
every slot is busy waits until the first live run anywhere ends, and then
takes that slot, because it has fewer live runs than the project holding them.
The default is therefore **no share, fair fill**. A per-project cap or a
reserved share is a captain decision only if the captain later asks for one
(for example to keep a slot free for one project); this design does not need
it and does not add the knob.

**3. Merge cards: parallel across projects, one at a time within one.** Two
projects' merge cards may be pending at once: they target different
repositories, a merge in one changes nothing another's branch is based on, and
neither needs the other rebased. Within one project merges stay one at a time,
because `base` is required to be up to date (15.6): each merge moves `base`,
so every other open pull request in that project must be rebased onto it and
gated again at its new head before it can be carded (section 6). A card raised
before that would be stale the moment the first one merges. The rule:

- **at most one merge in flight per project.** A project's merge turn is
  taken when its merge card is requested and freed only when `base` has
  settled: by a send back or a hold, which merge nothing, or, for a merge,
  only once the stored record says `merge: "merged"` or `"failed"` (5.2). It
  is not freed when the captain answers merge, because `base` moves when the
  merge completes, not when it is chosen, and a branch gated in between would
  be gated against the old `base`. A merge whose helper died before writing
  its outcome does not hold the turn for ever: the board reads the real
  outcome on start and on every poll (5.2) and only then frees it.
- **`fm-run.sh` cards only against a settled `base`.** It notes the project's
  `base` commit before it runs the gates. After they pass it takes a lock
  under `state/` named for the project and requests a merge card only if the
  project's turn is free and `base` is still the commit it gated against.
  Otherwise it requests none, says whether the card waits for the project's
  pending or running merge or for a regate on the new `base`, and leaves the
  branch to be rebased and gated again on a later turn.
- **the board never serializes one project's merge behind another's.** The
  merge route follows 5.2's outcome contract: it runs `fm-merge.sh` with the
  card's `--project` in the background, answers at once, and records the
  outcome in the decision record. A second merge in the same project while one
  is running is refused before anything is published, so that card stays
  pending and nothing is emitted; the one-card rule means this only guards
  against a stray or hand-raised card. A merge in another project runs
  alongside it. Today's synchronous `Bun.spawnSync` call blocks the whole
  board while one merge runs, which is exactly the cross-project coupling this
  section rules out.

**4. The captain sees and answers several projects' cards together.** Without
`?project=` the board shows every project (15.4): lane cards, crew bubbles and
decision cards of all projects on one page, each with its project chip. The
deck holds every pending card of every project in one list, oldest request
first, so a card never hides behind another project's; the pending count counts
all projects, or only the filtered one under `?project=`. Each card is answered
on its own — ids are global, so answering needs no project — and answering one
never changes, reloads away or reorders another project's pending card. There
is no bulk answer: every merge still goes through its own card (5.2).

Who proves what:

| Task | Its part of this section |
|---|---|
| T-047 | the decision ids of point 1 (D-1015 = A): every new id is `D-<project>-<task>-<n>`, allocated by `fm-decide.sh --allocate` under that task's own lock, merge cards included; old ids stay valid wherever they are read and are never moved; every parser accepts both forms |
| T-052 | point 2's caller: the firstmate skill dispatches with no `--project`, and names `--project` for dispatch only when the captain asks for one project; hand-raised cards take ids from `fm-decide.sh --allocate` |
| T-053 | points 1–3 in the scripts: the global count by `(project, task)`, the slot lock taken after verify, fair fill as the no-flag path, and the merge turn in `fm-run.sh` freed only when `base` has settled |
| T-054 | points 3 and 4 on the board: 5.2's background merge and recorded outcome, recovery of a `running` record whose helper died, the same-project refusal before publishing, and several projects' live work and cards at once |
| T-055 | the whole section end to end: the external project's task runs while a self-hosted task is live, and both merge cards are pending together |

Each of these depends on T-056, so none is pinned on its acceptance from
before this section. No task needs a file outside its existing scope for this:
the slot lock, the merge-turn lock, the merge marker and the decision-id
reservations live under `state/`, rendered pages under
`board/public/diagrams/`, all runtime output, not scoped files. Nothing is
renamed, so T-047 needs no `design/diagrams/` scope.
