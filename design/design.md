# firstmate-workflow — design

> This is the single source of truth. `bin/fm-dispatch.sh` reads the task DAG
> from `design/tasks.json`; section 14 mirrors that file and CI fails if the two
> disagree.
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
   an exemption for firstmate too.
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
| R2 | What the reviewer sees | The diff, the task spec and the acceptance criteria — never the worker's reasoning |
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
`agent_finished`.

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

`fm-run.sh` consumes `state/decision-details/D-<task-number>.json` after gates
pass. Missing or invalid authored input is reported as no card created. Only
a successful request is announced as asking the captain.

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
`design/tasks.json` or an unknown configured adapter, `70` something the run
needs and cannot have — no library, no worktree, nowhere to put a scratch file,
identity/snapshot failure, a live task lock, or failed managed transport —
`71` the push failed, `72` no pull request number came back, `73` the worker had
something to say and there was nowhere to put it, `74` GitHub could not
say which pull request the branch has, and `130`, `143` — a signal, 128
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
grilling  ->  /prototype  ->  [captain green-lights]  ->  design.md + tasks.json
                                       |
                        fm-dispatch.sh (ready tasks only, three at a time)
                                       |
              fm-worker.sh: worktree -> adapter -> commit -> pull request
                                       |
                          *  fm-gate.sh, the seven gates  *
                                       |
            fm-review.sh: reviewer sees the diff, the spec, the criteria
                                       |
     not passed -> worker revives and fixes (round 3+ asks first) -> back to the gates
                                       |
              APPROVE -> firstmate summarises -> [captain merges on the board]
```

**`fm-dispatch.sh` dispatches nothing until a `greenlit` event exists.**
It checks for any such event, not a match to the proposed work. Firstmate must
verify that authorization covers the work. Dependencies and capacity are read
from events, so reconcile these with current PRs and live processes before launch.

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
| Lanes | seven columns left to right: backlog, ready, work, gate, review, captain, merged; closed tasks, and every merged task, in the separate initially collapsed history |
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
absent from `design/tasks.json` shows its id and an explicit missing-title
label. The merged lane shows the latest few merges, newest first, and counts
the rest into the history.

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

---

## 14. The task DAG

`design/tasks.json` is the machine-readable form, with `id`, `title`,
`milestone`, `depends_on`, `scope`, `bootstrap` and `acceptance`. `scope` is
the glob allowlist gate 4 enforces.

Tasks marked `bootstrap` are built by hand: they are the dispatcher and its
gates, and the dispatcher cannot dispatch itself.

### M0 — the frame (bootstrap)

| id | title | depends on |
|---|---|---|
| T-001 | repo skeleton, the one gate, a bash test harness | — |
| T-002 | `fm-emit.sh`, the only writer of the event log | T-001 |
| T-019 | `fm-sync-prs.sh`, noticing a merge on its own | T-002 |
| T-020 | `fm-guard.sh` and hooks: nobody writes to main | T-001 |
| T-003 | the adapter contract, `mock.sh`, the contract test | T-001 |
| T-004 | `fm-gate.sh`, the seven gates | T-002, T-003 |
| T-005 | `fm-worker.sh`: worktree, adapter, commit, pull request | T-003, T-004 |
| T-006 | `fm-review.sh`: the reviewer sees only the diff | T-005 |
| T-007 | `fm-dispatch.sh`: the DAG, the limit, the green-light gate | T-005, T-006 |
| T-008 | `fm-decide.sh`: decisions land, firstmate wakes | T-002 |
| T-023 | `fm-cleanup.sh`: a worker removes its own worktree and nothing else | T-005 |
| T-024 | `fm-run.sh`: one turn of the whole loop, proved end to end | T-007, T-013, T-015 |

### M1 — the board

| id | title | depends on |
|---|---|---|
| T-009 | board server: SSE, static, hot reload | T-002 |
| T-010 | board UI: the ship, the crew, the deck, the lanes, the log | T-009 |
| T-011 | i18n: dictionaries, `tw2cn.tsv`, the hardcoded-string lint | T-009 |
| T-012 | `/open` and the read-only diff viewer | T-009 |
| T-013 | the decision API, including merge cards | T-008, T-009 |
| T-014 | the board in a browser, and the gate that runs it | T-010, T-011, T-013 |
| T-025 | the adapter verdict: a vendor that fails silently is not one that worked | T-003, T-006, T-024 |
| T-026 | the option loop: a flag with no value must not spin for ever | T-017 |
| T-027 | the crew are agents, not pull requests | T-010 |

### M2 — protocol and self-update

| id | title | depends on |
|---|---|---|
| T-015 | `fm-protocol.sh`: round three and its violations | T-006 |
| T-016 | `fm-diagram.sh`: decision diagrams, and the board embed | T-010 |
| T-017 | `fm-reconcile.sh`: reconciling after a crash | T-007 |
| T-018 | self-update and `sync-skills` | T-007, T-015 |
| T-029 | one exit code for a usage error, in every script | T-026 |
| T-030 | the lints are blind to the files that carry them | T-026 |
| T-031 | a second round the worker cannot see, and a question nobody hears | T-007 |
| T-032 | the red check reaches the worker as an empty block | T-031 |
| T-033 | firstmate startup contract | T-007, T-006, T-013 |
| T-034 | clear localized captain decisions and reliable outcome effects | T-010, T-013, T-014 |
| T-035 | managed firstmate session defaults | T-033, T-003, T-008, T-009 |
| T-036 | truthful crew progress | T-034, T-002, T-010 |
| T-037 | fm-worker.sh must reuse an existing task branch, not re-derive its name | (none) |
| T-039 | fm-gate.sh's gate 3 must run the full local gate at the budget design.md already authorizes | — |
| T-041 | firstmate never loses a captain order it did not act on | T-035 |
| T-042 | a worker that changed files still opens its PR when it also leaves a note | T-005, T-031 |
| T-044 | a completed run's pane actually closes | T-035 |
| T-040 | captain's board layout parity with the 2026-09-20 prototype | T-034, T-036 |
| T-043 | the project declares its setup and checks; the gates stop hard-coding this repo's toolchain | T-041, T-039 |
| T-057 | the board separates ready work from backlog | T-040 |

### M3 — driving other repositories

| id | title | depends on |
|---|---|---|
| T-045 | design: firstmate drives other repositories from one external installation | T-043 |
| T-046 | the project registry and the two roots | T-043, T-045 |
| T-047 | the project on events, decisions and pull request sync | T-046, T-056 |
| T-048 | fm-project.sh: managed clones, target verification and the guard | T-046 |
| T-049 | spec pins: gate 4 reads a pinned scope, not the branch | T-047, T-048 |
| T-050 | project-aware gates 1–3 and 5–7 | T-049 |
| T-051 | the worker and the reviewer in a target checkout | T-049 |
| T-052 | role prompts carry the project's design from the engine side | T-051, T-056 |
| T-053 | dispatch, run and session across projects | T-050, T-051, T-056 |
| T-054 | the board shows which project | T-047, T-056 |
| T-055 | the first external project, proved end to end | T-052, T-053, T-054, T-056 |
| T-056 | design: the board dispatches to several projects at the same time | T-045 |

---

## 15. Driving other repositories (the external model)

Captain decision D-049 chose option B: **one external installation.** This
repository holds the engine (`bin/`, `skills/`, `board/`), the design and task
list of every project, and all runtime state under `state/`. It drives target
repositories, which receive only the branches and pull requests of their own
tasks and carry nothing of firstmate's.

This section is the plan; the M3 tasks in section 14 implement it. Until each
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
    tasks: design/tasks.json
    project:                              # T-043's contract, whole, from T-050 on
      ...
  example-app:                            # an external target
    github: example-org/example-app
    base: main
    required_check: check
    # design and tasks default to projects/example-app/design.md and .../tasks.json
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
| `design`, `tasks` | paths **relative to the engine root** | default `projects/<name>/design.md` and `projects/<name>/tasks.json` |
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

`bin/ci.sh`'s agreement check between a design's task table and its task list
runs once for every registered `(design, tasks)` pair and names the project on
failure; a registered pair whose files do not exist is red, not skipped. A tree
with no `projects:` map (the test fixtures) keeps the one
`design/design.md`/`design/tasks.json` pair it always had.

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
| task list | `design/tasks.json` | `projects/<name>/tasks.json` (engine root, committed) |
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
- **Decisions** carry `project` in the request and the response. Ids stay
  global, and there are exactly two ways to make one, which never meet
  (section 15.10's decisions row gives the reasons). A merge card's id is
  derived from `(project, task)` with no lock: `D-<task-number>` for the
  default project, as today, and `D-<project>-<task-number>` for any other,
  because two projects can both have a `T-004`. Every other card's id is
  allocated by `fm-decide.sh` under the decision-id lock, from `D-1000` up.
  Records below `D-1000` that do not own their id are renumbered into that
  space once, with everything keyed by the id and a recorded map (15.10).
  Merge cards name the project and link the pull request on the project's
  GitHub repository.
- **`fm-sync-prs.sh`** polls every registered project's repository and writes
  what it finds with that project.
- **The board** shows a project chip on lane cards, crew bubbles and decision
  cards, and filters with `?project=`; without it, it shows all projects. Chip
  labels come from the UI dictionaries; a project's name is data and is not
  translated. Dynamic summaries still carry `en` and `zh-TW`.
- **Crew identity** is unchanged: the locked run counter already makes labels
  unique across projects. `identity.json` records the project.

### 15.5 Gate 4 under the external model

Today gate 4 reads the task's scope from `design/tasks.json` **on the task's
own branch**, falling back to the working copy. Under option B a target's
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
(`design/design.md`, `design/tasks.json`, `bin/fm-checkpoint.sh`) and refer to
"the design, scope and checkpoint command in your prompt". The self project
gets the same prompt shape. The reviewer still sees the diff, the spec and the
design — never the worker's reasoning (R2). Firstmate itself always runs in
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

The M3 tasks in section 14 carry the exact scopes and acceptance. The order
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
| decisions | one card per request, carrying `project` | merge-card ids derive from `(project, task)`; every other id is allocated from `D-1000` up (below) |
| merges | the project's own `github` repository | see point 3 |

The decisions row was checked against both allocators, because today they
share one space and do collide. `fm-run.sh` derives `D-<task digits>` with no
lock, and cards firstmate raised by hand took numbers from the same `D-<n>`
range. On 2026-09-24 `state/decisions/` (runtime, not in git) held these
records under ids they do not own by the ownership rule below — each is a
choice card, or a card raised for a task other than the one its id derives
from:

| Id | Raised for | Id | Raised for |
|---|---|---|---|
| D-034, D-035 | not a merge card for T-034, T-035 | D-048 | T-041 |
| D-038 | T-017 | D-049 | T-045 |
| D-039 | T-018 | D-050, D-051 | T-043 |
| D-040, D-041 | T-034 | D-052 | T-042 |
| D-042 | T-036 | D-053, D-054 | T-044 |
| D-043 | T-037 | D-055 | T-040 |
| D-045 | T-039 | D-056 | T-043 |
| D-046 | T-035 | D-057 | T-045 |
| D-047 | T-040 | D-334, D-335, D-338 | T-034, T-035, T-017 (choice cards) |

So every task from T-046 to T-057 — T-046, T-047 and T-056 among them — has
its merge-card id taken, and T-334, T-335 and T-338 would have theirs taken
too. D-034 and D-035 hold T-034's and T-035's own ids without being their
merge cards; they fail the ownership test like the rest and are moved with
them. Today `fm-run.sh` finds the file, takes it for its
own card and silently raises none (`bin/fm-run.sh`, the `[ -f
state/decisions/$id.json ] && continue` line). This table is a snapshot, not
the rule: the remedy below reads ownership from each file, so a record added
later is caught the same way. The fix keeps one scheme per kind, puts them in
spaces that cannot meet, and moves every record already in the wrong space:

- **merge cards are derived, never allocated.** `(project, task)` is unique,
  so the id needs no lock: `D-<task digits>` for the default project (today's
  id, so self-hosting and `state/decision-details/<id>.json` are unchanged)
  and `D-<project>-<task digits>` for any other. A project name is
  `[a-z0-9-]` (15.2) and task digits never contain `-`, so the id splits at
  its last `-` into one project and one task; it cannot equal a default id,
  which has a single `-`, or a `D-SK-<n>` skill card, whose `SK` is upper case.
- **every other card is allocated, never derived.** `fm-decide.sh` takes the
  next free number under the decision-id lock, starting at `D-1000`. Task ids
  are `T-` and three digits, so a derived default id is at most `D-999` and
  allocation can never reach one.
- **an existing file is not proof of ownership.** A record owns a derived id
  only when its `kind` is `merge` and its `task` and `project` (absent means
  the default project) are the ones the id derives from. `fm-run.sh` applies
  that test to `state/pending/<id>.json`, `state/decisions/<id>.json` and
  `state/runtime/archived-pending/<id>.json` before it says a card is
  waiting or already answered, or raises one.
- **a record in the wrong space is moved out of it, once, with everything
  keyed by its id.** Every record at or below `D-999` that does not own its
  id is renumbered into the allocated space: `fm-decide.sh --renumber <id>`
  takes the next free number from `D-1000` under the decision-id lock and
  moves every store keyed by a decision id, not only the record. The list of
  stores comes from the search below, not from memory, and names nine:
  `state/pending/<id>.json`, `state/decisions/<id>.json`, the archived cards
  `state/runtime/archived-pending/<id>.json`,
  `state/decision-details/<id>.json`, the rendered pages
  `board/public/diagrams/<id>.*`, the authored drawings
  `design/diagrams/<id>.*`, and the watcher's three,
  `state/session/observed/<id>.json`, `state/session/acknowledged/<id>.json`
  and `state/session/watch-<id>.json` (with the watch directory it points at,
  whose `observed/<id>.json` and `result.json` name the id). Two identities
  are keyed by it as well: the record's stored `identity`, `decision:<id>`,
  and the `data.decision` of events in the log. The authored drawings and the
  watcher's stores are the two that hurt when missed. `bin/fm-diagram.sh`
  serves an authored drawing whose stem is the decision before one whose stem
  is the task, so a drawing left at the old stem would be shown on the owning
  task's new card. On 2026-09-24 `design/diagrams/` held authored `D-047`,
  `D-049`, `D-050` and `D-051` (the choice drawings for T-040, T-045 and
  T-043), all untracked; left there, T-047's merge card would show T-040's
  board layout. An untracked authored drawing is moved. A tracked one is not
  renamed by the script, because renaming a tracked file in the engine
  checkout is a change to `base` outside a pull request: `--renumber` stops
  before moving anything, names the file, and the rename lands through a
  pull request, after which `--renumber` completes.
  The watcher (`bin/fm-herdr.py`, behind `fm-session.sh`) skips for ever an
  id that already has `state/session/observed/<id>.json`, and lists as
  unacknowledged every observation without a matching
  `state/session/acknowledged/<id>.json`. The local checkout holds both for
  every id in the table above. Left behind, they would make the owning
  task's answer under its derived id — the captain's merge answer on T-056's
  own `D-056` card — never observed, so it never wakes firstmate. So
  `--renumber` carries both to the new id. It rewrites the observation
  receipt's `id`; it rewrites the acknowledgement record's own `id` field as
  well as recomputing its `observation` hash over the rewritten receipt, and
  it writes the acknowledgement under `state/session/.ack.lock`, the lock
  `fm-session.sh ack` takes, so an `ack` running at the same moment neither
  writes a receipt for the old id after the move nor reads a half-written
  one. An observation not yet acknowledged stays unacknowledged under the
  new id. It copies them first, then renames the record, then deletes the old
  receipts, so a continuous watch polling in between sees an observation for
  whichever name the record has and never observes T-043's old answer a
  second time. A `state/session/watch-<id>.json` whose process is still live
  (the same `process_matches` test the watcher uses) is waiting on that id:
  `--renumber` refuses, names the watch, and moves nothing until it is
  stopped. A dead one is renamed to `watch-<new>.json` with its `decision`
  and its directory's receipts rewritten, so `fm-session.sh status` does not
  report T-043's answer as a watch on `D-056`.
  Not stores and not moved: `state/skill-updates/` is keyed by `SK-<n>`,
  outside the renumbered range; the board's `.<id>.<uuid>.tmp` in
  `state/decisions/` exists only for the length of one write, which is
  renamed onto the record; the browser's `seen` set is in memory and keys
  by identity, covered below.

  The search, so a reader can re-run it from the repository root:

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
  | `bin/fm.sh` | `state/decisions/D-SK-<n>.json` for self-update, outside the renumbered range |
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
  than the four named was read, because the code names no other. A store
  added later that is keyed by a decision id joins `--renumber`'s list in
  the same pull request that adds it.
  The record's `id` becomes
  the new id and its stored `identity` becomes `decision:<new>`. The map
  entry `{old, new, task, ts}` is appended to
  `state/decision-renumbered.json` before any file moves, so an interrupted
  renumber is finished by the next run under the same new id, never repeated
  under a second one. The event log is append-only and keeps the old id; a
  reader that pairs an event with a record resolves the old id through that
  map. That includes the board's outcome identity: an old `decision_made`
  event for `D-056` is T-043's answer, and the board (T-054) keys it as
  `decision:<new>` through the map, so the owning task's later answer under
  `D-056` gets an identity of its own. Until T-054 lands the board keys
  outcomes by the raw id, so the two answers share `decision:D-056` and the
  board's `seen` set swallows the second one's animation; no card, answer or
  merge is affected, only that animation. The watcher is not part of this
  gap: its receipts moved with the record, so the second answer is observed
  under `D-056` and listed as unacknowledged. Renumbering moves only a
  record that has a response. A foreign record still pending is left where
  it is, because an `--await` on its id would never wake; `fm-run.sh` names
  it and raises nothing until the captain answers it, and then moves it on
  its next turn. An archived card is the one exception: firstmate moves a
  pending card to `state/runtime/archived-pending/` only for a long-finished
  task, after clearing its processes (clear-zombie-workers step 6), so
  nothing awaits its id and no answer will ever come. A foreign archived
  card at a derived id is therefore renumbered without a response — moved to
  `state/runtime/archived-pending/<new>.json` with its `id` and `identity`
  rewritten and its details and drawings moved with it — rather than left to
  share the id with the owning task's new pending card. Left in place it
  would escape the "named and left in place" rule, because it is not under
  `state/pending/`, and `fm-run.sh` would raise the owning card under an id
  that still names another task's card on disk. An archived card that owns
  its id is the task's own stale merge card; it is left where it is and
  does not block a new card for that task. After the move the derived id is free and the owning task's
  card is raised there, so the task gets its card rather than a report.
- **who moves them, before and after T-047.** Once T-047 lands, `fm-run.sh`
  does it: finding an answered foreign record at its derived id, it calls
  `fm-decide.sh --renumber` for that id and requests its own card in the same
  turn. Before T-047 lands, nothing in `bin/` knows to, and T-046, T-047 and
  T-056 need cards before then — T-056's own id, `D-056`, is held by T-043's
  record. So firstmate renumbers by hand now, before the next merge card is
  due: every answered record in the table above and every foreign card under
  `state/runtime/archived-pending/` at or below `D-999`, by the same steps —
  every store listed above, the untracked authored drawings in
  `design/diagrams/` and the watcher's `state/session/observed/` and
  `acknowledged/` receipts included (the acknowledgement's `id` and hash
  rewritten under `.ack.lock`), in the same copy, rename, delete order, with
  no live watch on the id — and into the same map, taking numbers from `D-1000` up. `--renumber` then finds
  those done and stops at the map, so doing it by hand first costs nothing
  later. Until T-047 lands, firstmate also checks each task's derived id by
  the ownership test before it tells the captain a card is waiting.
- **hand-raised cards use the allocated space from now on.** Until T-047's
  allocator exists firstmate picks the next unused number from `D-1000` up
  itself; `fm-decide.sh` already accepts that shape. After T-047 it lets
  `fm-decide.sh` allocate. It never raises a card by hand at or below
  `D-999` again (T-052 puts this in the firstmate skill).

Four things are deliberately global, and each is a short critical section,
not a lock held for the length of a run: the event log's writer lock
(`fm-emit.sh`), the run-counter lock that numbers run actors (section 11), the
decision-id lock that allocates the next non-merge card (above), and a
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
| T-047 | the decision ids of point 1: merge cards derived per `(project, task)`, other cards allocated from `D-1000` under the lock, the ownership test in `fm-run.sh`, and `fm-decide.sh --renumber` moving an answered or archived foreign record and every store keyed by its id, authored drawings and the watcher's receipts included, refusing while a watch on the id is live, so the owning task gets its own card and its answer wakes firstmate |
| T-052 | point 2's caller: the firstmate skill dispatches with no `--project`, and names `--project` for dispatch only when the captain asks for one project; hand-raised cards take ids from `D-1000` up |
| T-053 | points 1–3 in the scripts: the global count by `(project, task)`, the slot lock taken after verify, fair fill as the no-flag path, and the merge turn in `fm-run.sh` freed only when `base` has settled |
| T-054 | points 3 and 4 on the board: 5.2's background merge and recorded outcome, recovery of a `running` record whose helper died, the same-project refusal before publishing, the widened decision-id pattern and the renumbering map, and several projects' live work and cards at once |
| T-055 | the whole section end to end: the external project's task runs while a self-hosted task is live, and both merge cards are pending together |

Each of these depends on T-056, so none is pinned on its acceptance from
before this section. No task needs a file outside its existing scope for this:
the slot lock, the merge-turn lock, the merge marker and the renumbering map
live under `state/`, rendered pages under `board/public/diagrams/`, all
runtime output, not scoped files. The authored drawings `--renumber` moves
are untracked files; a tracked one is renamed through a pull request, never
by the script, so T-047 needs no `design/diagrams/` scope.
