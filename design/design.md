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
| Q9 | Where pull requests live | `BenjaminLu/firstmate-workflow`, public so branch protection is available |
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

### 5.2 Captain decisions, `state/decisions/D-*.json`

The board POSTs one; `bin/fm-decide.sh` blocks until it appears.

```jsonc
{"id":"D-007","task":"T-004","kind":"choice","chosen":"B","note":"leave the schema alone","ts":"..."}
```

Two kinds. `choice` is an option card carrying a before/after diagram. **`merge`
is a request to merge**, carrying the seven-gate checklist, the diff stat, the
files touched and the pull request link, answered with merge, send back, or
hold. **Every merge goes through a card.** firstmate may not merge on its own
and may not ask for one in conversation.

Waiting is `bun run bin/watch-decisions.ts` (`fs.watch`, millisecond wake) when
bun is present, and a one-second poll otherwise. **No `fswatch` dependency.**

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

A round that produced no review exits `3` and emits `review_failed`; it never
reaches the pull request and never counts toward gate 7. A verdict has to
carry `APPROVE:<task>` or `REJECT:<task>`, because a real reviewer's verdict
*is* its standard output and without a marker a crashed engine's stack trace
looks exactly like a damning review.

The judgement about outages can never be right on wording alone, because
there is no phrase a model cannot write — this repository contains
"Authentication required" in two files, so any review of it quotes them. So
wording does not decide. The adapter is deliberately generous, and the caller
settles it: `fm_run_chain` takes a predicate answering *did this run produce
work?*, and work beats a signature. A worker asks whether the worktree
changed; a reviewer asks whether the output carries a verdict marker. Being
over-eager then costs one more vendor attempt and never the work — and a
signed review is never thrown away, which would otherwise repeat the same
round forever with a reassuring message on it.

A vendor named at the head of the chain with no adapter behind it is a typo,
not an outage. It is caught before anything runs and exits `65`, so a human
fixes the configuration — and so the exit cannot throw away work a fallback
vendor had already done. A *fallback* entry with no adapter is simply
skipped.

An exit code never overrules produced work, in the callers any more than in
the adapters: a signed review is a review whatever the engine exited with,
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
the whole of the rule here: whether every OTHER kind of usage error
exits `64` too is T-029, and nothing in this section says it does.

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
check need not be an Actions run at all, and one that is not says so
rather than asking for a run called `https:`. A blank block reads as a
green run, so the round was spent asking why the check was red.

The block is never blank, and it says which of three things happened,
because to the worker they mean different things: the check is not an
Actions run and its log is not ours to fetch; the fetch failed, and
here is what `gh` said; or the fetch succeeded and the run had no
failing step log at all — a cancelled run, or a job that died before
anything logged — which "could not be fetched" would misreport as
GitHub's fault. Emptiness is decided on what reaches the fence rather
than on what `gh` returned: a log whose every line the column trim
reduces to nothing is not an empty capture, and it is an empty block.

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
`design/tasks.json`, `70` something the run needs before it starts and
cannot have — no library, no worktree, nowhere to put a scratch file —
`71` the push failed, `72` no pull request number came back, `73` the worker had
something to say and there was nowhere to put it, `74` GitHub could not
say which pull request the branch has, and `129`, `130`, `143` — a
signal, 128 plus its number, from the traps that make a killed run stop
rather than carry on.

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

**`fm-dispatch.sh` dispatches nothing until a `greenlit` event exists** for the
work. That is the eighth gate, and it stops work starting before the captain
has seen a proposal.

| # | Gate | How it is checked |
|---|---|---|
| 1 | branch exists and has commits | `git rev-list --count main..<branch>` > 0 |
| 2 | rebase onto main is clean | attempt it in a scratch worktree; non-zero fails |
| 3 | `bin/ci.sh` exits 0 | the same script GitHub Actions runs |
| 4 | the diff stays in scope | `git diff --name-only` within the task's `scope` globs |
| 5 | **the new tests are not vacuous** | revert the implementation hunks; the new tests must go red |
| 6 | the required GitHub check is green | `gh pr checks <pr> --required` |
| 7 | the reviewer posted `APPROVE:<task-id>` | and from the configured reviewer account |

All seven green before an `approved` event and a merge card. Any one red and
nothing the reviewer said in praise counts.

---

## 7. The round-three protocol

Rounds one and two: the reviewer picks holes as usual.

**From round three:**

1. Before touching a line, the worker posts `ASK-PASS-CRITERIA:<task-id>`.
2. The reviewer answers with a **numbered list** and posts
   `CRITERIA-COMPLETE:<task-id>`.
3. After that the reviewer may raise only numbered items from that list, or a
   newly introduced regression marked `REGRESSION:`.
4. An old off-list complaint makes `bin/fm-protocol.sh` emit
   `protocol_violation`. It does not count toward the gates, and it goes on the
   board so the captain can see the reviewer drip-feeding.

The point is to end the loop where each round fixes one thing and surfaces
another.

---

## 8. The captain's board

Bun, native SSE, vanilla HTML, **no build step**.

| Region | What it holds |
|---|---|
| Sea header | merged / in flight / awaiting you / blocked, and the engine chip — marked when the reviewer runs a different vendor |
| The ship | a pirate vessel whose size tracks the crew, one mast to six |
| Deck | crew stand on the ship, poses driven by state, handoffs fly between them |
| Decision deck | the captain drawn at the left; the card to the right — options, before/after diagram, or the seven-gate checklist for a merge |
| Crew roster | opens when the deck is too crowded for the bubbles to carry the work |
| Lanes | queued / working / gate / review / captain / merged |
| Live log | tri-lingual summaries from `events.jsonl` |

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

**Each crewman carries a bubble above his head**: id, task, progress, percent,
with the border colour carrying state. A landing handoff pulses the recipient's
bubble. Deck spacing must exceed body height plus bubble height or a bubble
covers the crew on the deck above.

### The captain

Drawn at the left of the decision deck on a lit stage — red coat, gold sash,
tricorn and plume, eye patch, cutlass. Three poses: sheathed while nothing is
chosen, half drawn once an option is picked, raised when the order goes out.
Draggable like the rest of the crew.

### Ahoy

| Trigger | Response |
|---|---|
| A merge | the broadside fires gun by gun, the ship heels, every crewman's arms go up, the bell rings, `AHOY! / MERGED INTO MAIN` |
| An order | bell and bosun's whistle, the helm spins twice, `AYE, CAPTAIN! / ORDERS AWAY` |

Sound is synthesised at runtime through Web Audio — the bell two partials on a
long decay, the cannon a lowpassed noise burst, the whistle a swept sine — so
there are no audio files and no network. Mute lives in the header and persists;
browsers require a gesture before the first sound. Honours
`prefers-reduced-motion`.

**One gun list** (`portList()`) drives the ports, the flash positions and the
sound schedule: one gun, one flash, one report, the same `GUN_DELAY` apart. The
bell waits until the last gun has spoken. **The shout stays in English in every
locale** — it is a cry, not a label.

Celebration must not hide what is being celebrated: the banner sits clear of
the ship.

### Interaction

Drag a figure to turn it, drag the deck to turn the whole crew, double-click to
reset. Every pose is a `.fig.s-<state>` class, so **e2e asserts classes rather
than diffing screenshots**.

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

The local gate and GitHub Actions run **the same** `bin/ci.sh`:

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
  content.

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
