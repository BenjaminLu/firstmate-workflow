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
  same pull request and the same gates as any other code.
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
| Q4 | Board to firstmate | Decision lands as a file; the board pushes the wake as it writes it, and every waiter's own doorbell is rung (T-151; nothing polls) |
| Q5 | Board stack | Bun + SSE + vanilla HTML, no build step |
| Q6 | Where determinism ends | Scripts decide whether it ran; models only judge whether it is right |
| Q7 | First REJECT (SK-007) | Complete numbered standing list from round one; ask only if missing or unclear |
| Q8 | Diagram scope | Only decisions the captain must rule on; reuse existing diagrams first |
| Q9 | Where pull requests live | `BenjaminLu/firstmate-workflow`, public so branch protection is available; under Q10 a task's pull request lives on its project's repository |
| Q10 | Which repositories firstmate drives | D-049 chose one engine installation; captain revision 2026-10-01 keeps external private designs, tasks and runtime state under FM_HOME outside the engine, with self compatibility (section 15) |
| R1 | Self-update | Skills define behaviour; writing them back travels a full pull request; external skills import read-only |
| R2 | What the reviewer sees | The diff, the task spec and the acceptance criteria, plus, given the pull request, the head's SHA, required check and gate summary (section 7) — never the worker's reasoning |
| R3 | Granularity | One task, one pull request, one worktree; `depends_on` forms a DAG; three in flight |
| R4 | Branching | Every task branches from `main` and targets `main`; the worker rebases its own conflicts |
| R5 | Writing the log | Only through `bin/fm-emit.sh` |
| R6 | Opening a file | `POST /open` hands it to the editor — the captain's credential, localhost only, path must resolve inside the repo — plus a read-only viewer |
| R7 | CI | The local gate and GitHub Actions run the same `bin/ci.sh` |
| R8 | Recovery | Replay the event log, then reconcile on start |
| R9 | Hot reload | SSE pushes `reload` to the front end; `bun --watch` restarts the server |
| I1 | Dynamic board content | Agents write the tri-lingual payload at emit time |
| I2 | Where the three come from | Agents produce `en` and `zh-TW`; `zh-CN` is a table conversion |
| I3 | Language preference | `localStorage`, overridable with `?lang=`, default from config `language` (`en` when absent) |
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

### Firstmate host and worker vendor (T-174)

The shipped worker vendor is `opposite-of-host`: a Claude firstmate starts
Codex workers, and a Codex firstmate starts Claude workers. The other main
vendor comes next, followed by the remaining `fallback:` entries in their
configured order (currently cursor-agent, then gemini). Only an unavailable
adapter (exit 2, including quota/rate-limit refusal) advances the chain.
An unknown or other host uses the configured fallback head and logs why.
A named worker vendor retains its existing chain; explicit `--vendor` selects
that vendor alone. The reviewer remains explicitly `vendor: claude`.

`fm-session.sh start` and `status` refresh `state/session/host.json` beside
the other session records, except when `FM_IN_ROUND` or `FM_RUN_DIR` is non-empty:
rounds never refresh it. Positive detection replaces the record with
`confirmed: true`, including when firstmate switches harnesses. Unknown detection
never replaces a known harness with null: the same known session leaves the file
byte-identical; another or unknown session keeps the recorded facts and marks
`confirmed: false`, retaining the first `unconfirmed_since` time. Collector
failure also preserves an existing record. A legacy record without `confirmed`
is treated as confirmed; no migration is needed.
The record includes `session` (owner pid and process start time), detection
`source` (`env`, `owner`, `claudecode`, or null), and `written_by` (writer pid and
up to 200 characters of its parent's command). Unknown detection across sessions
adds `last_unknown` without replacing the original provenance. Session start/status
and `opposite-of-host` resolution warn on stderr about an unconfirmed known host;
the board marks its vendor unconfirmed in the roster. Routing
still uses that recorded harness. External project records live under
`FM_HOME/projects/<name>/state/session/host.json`, never in the target repository.
Board launches use the board's owning session record across projects; other
launches use their project's record, falling back to the engine session's.
The collector reuses `fm_hooks.detect_source()` (`FM_HARNESS` overrides detection),
records the CLI's own version output, and reads models only from harness-owned
settings with a `model_source`. Claude settings are read in user, project,
then local order; Codex reads its own `CODEX_HOME/config.toml` (default
`~/.codex/config.toml`). These are configured models, not proof of the model
serving the current turn; an unobservable model stays unknown. Crew model
settings in `config.yaml` never supply firstmate's model.

The board shows the recorded harness, model (or localized unknown) and CLI
version through its existing crew fields; a legacy session with no record
has no host fields. Board-dispatched rounds read the stored host, never the
board process's harness environment. Each round logs its resolution and keeps
`vendor_resolution` (host, rule, resolved head) in `identity.json`, alongside
the current vendor, which can change on fallback.


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
transport. `fm-autopilot.sh` reports failed gates; firstmate must coordinate subsequent
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
 "pr":9,"data":{"gate":"fail-first"},
 "summary":{"en":"...","zh-TW":"..."}}
```

Types: `greenlit` `dispatched` `commit_pushed` `pr_opened` `gate_passed`
`gate_failed` `review_opened` `review_failed` `ask_pass_criteria`
`criteria_returned` `protocol_violation` `approved` `merged` `closed`
`decision_requested` `decision_made` `worker_crashed` `worker_note_unsent` `vendor_unavailable`
`agent_finished` `crew_status` `parked` `unparked` `spec_pinned`
`spec_repinned` `autopilot_waiting` `conventions_drift`.

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
The board also preserves the pending card's optional `details`, `purpose`,
`title` and `ste` report in the answered record (T-230). Existing records stay
unchanged on disk. A shared `publicDecision` projection removes those fields
from every record, including records written before T-230, in
`/api/state.responses`, SSE state, POST `/decisions` responses (including
repeat answers), and `session/wake.jsonl`. Only `/api/task` exposes this authored
history among board outputs. `fm-decide.sh --await` prints the record unchanged,
including those fields, in firstmate's own terminal.
Receiving a response is not itself approval; inspect the chosen option and context.

```jsonc
{"id":"D-007","task":"T-004","kind":"choice","chosen":"B","note":"leave the schema alone","ts":"..."}
```

Two kinds. `choice` is an option card carrying a before/after diagram. A choice
card may record a purpose (dispatch, repin, scope, skill, decision) with
`--purpose`, and the board shows every card's kind and purpose as a coloured
badge, falling back to the title for cards raised before T-227. **`merge`
is a request to merge**, carrying the gate checklist, the diff stat, the
files touched and the pull request link, answered with merge, send back, or
hold. **Every merge goes through a card.** firstmate may not merge on its own
and may not ask for one in conversation.

**A merge card merges only the pull request of its own task (T-119).** On
2026-09-26 a card for #96, the captain's revert of T-105, was raised under
T-117; the captain clicked it, and `fm-merge.sh` merged #96 and wrote
`merged` for T-117 while T-117's own #97 was open. Nothing compared the
card's task with the pull request's. Now a merge card names its pull request
and its task, and they must agree. A pull request's task is its head
branch's, and its title's `T-xxx:` or `SK-xxx:` prefix only when the branch
names none, read by the one task-id grammar (below). `fm-decide.sh --request
--kind merge` reads the pull request (`gh pr view --json headRefName,title`,
on the card's project's repository, else the checkout's) before any card
exists, and refuses, non-zero and naming both, a pull request of another
task, of no task, or one `gh` cannot read. `fm-merge.sh` reads it again at
merge time, because the branch can change between card and click: a
`--task` that is not the pull request's task, or a pull request of no task
without `--untracked`, is refused before anything merges, and the board
records the failed outcome with that reason. It never writes `merged` for
another task, and it checks before its "already merged" answer, which would
otherwise settle the wrong card. Given no `--task`, it merges as the pull
request's own task.

A pull request that belongs to no task (a revert, a hotfix) gets a card of
its own kind, **`merge-untracked`**: `fm-decide.sh --request <D-digits>
--kind merge-untracked --pr <n> --details <file>`, with no `--task`. It names
no task, so no task can own its id and it takes a hand-raised `D-<digits>`;
`--allocate` refuses the kind. The board answers A on it by running
`fm-merge.sh --untracked`, handing no task whatever the card's file says,
and the merge writes `merged` with no task and `data.untracked: true`, which
moves no task's card; `fm-emit.sh` refuses a `merged` event that says
`untracked` and names a task. The pairing holds in this direction too: a
task's own pull request merged as untracked would write no task, and that
task's card would never move (`fm-autopilot.sh` sees the merge as already
recorded). So `fm-decide.sh --kind merge-untracked` reads the pull request
the same way and refuses, before any card exists, one whose branch or title
names a task, pointing at that task's `--kind merge` card; and
`fm-merge.sh --untracked` refuses it at the click, pointing at `--task`.
#96 itself is such a pull request: GitHub holds its branch as
`t-105-revert` and its title as `T-105: revert the crew sandbox, …` (main's
squash commit carries git's `Revert "…"` subject instead), so by the grammar
it is T-105's, and its card is a merge card for T-105. The board hands a task's merge card to
`fm-merge.sh` only with a task the grammar holds, and refuses the answer
(`409`, with no code of its own, so the page reports it as a failed order
with the server's reason) otherwise.

**One task-id grammar (T-119).** Which ids are tasks, and which task a branch
or title names, is written once, in `bin/lib/fm-task-grammar.sh`, a library
that only defines the grammar. `fm-emit.sh` sources it, so `fm-decide.sh`,
`fm-merge.sh`, `fm-diagram.sh` and the autopilot still get the grammar by
sourcing `fm-emit.sh` (which runs nothing past its grammar block when sourced).
Reconcile sources the library itself, never the event writer.
`board/server.ts` carries its TypeScript twin between `// --- task grammar
(T-119) ---` markers, which `tests/board.test.sh` lifts out and runs against
the shell functions over one table. A task is `T-<3+ digits>` or
`SK-<3+ digits>`, the only prefixes `design/tasks/`, the branches and the
merged pull requests use. A branch names its task with the prefix in either
case, the hyphen after it optional as in the earliest `t004-…`, and the whole
run of digits: `t-117-…` is T-117, `sk-001-…` is SK-001, `t-1170-…` is
T-1170, never T-117. One optional leading `[A-Za-z0-9._-]+/` segment is
allowed (T-250): `feature/t-001-x` names T-001 and `feature/sk-002-y`
names SK-002. Two segments, `/t-001` and `hotfix/x` name no task.
This attribution also applies to human branches: adoption by a different task
is refused, including at the next round of an existing adoption. A title leads with the task and a colon; GitHub's
`Revert "T-105: …"` names none. A decision id holds a task's key, the task
without its hyphen (`T047`, `SK001`); card ids have always taken
`T-<letters and digits>` too, and the fixtures (`T-A`, `T-1`) still do, so a
key is that or a task. `fm-emit.sh` reads a `merged` event's task through the
grammar: a value it reads a task out of without its being that task id - a
branch name such as `t-117-…`, a title such as `T-117: …` - is refused,
naming the task it holds. Any other name passes, because the suites write
`merged` for fixture tasks named `A`, `C` and `D`; `fm-merge.sh`, the one
writer of `merged` outside the suites and `fm-autopilot.sh`, already refuses
a task that is not the pull request's. It checks no other event's task.
T-250 makes `bin/fm-reconcile.sh` source the library for branch attribution,
so it reads SK merges and whole numbers such as T-1170. The remaining open
item is its pid-file `is_task_id` at `bin/fm-reconcile.sh:136`, which still
accepts only `T-<3 digits>`. All four stacking branch readers allow the
same optional segment; protected branch and expected-head deletion rules remain.
Unprefixed branches, self branch names, PR titles, gates and T-119's merged-event
refusal semantics are unchanged.

So a skill update merges through the board like any task: an approved,
green SK-* task gets an owned merge card, `D-<project>-SK<n>-<m>` from
`fm-decide.sh --allocate --task SK-<n> --kind merge`; A runs `fm-merge.sh`,
which writes `merged` for SK-<n>; and `fm-autopilot.sh` reads `sk-<n>-…`
branches like any other. Its card is drawn and embedded like a T task's:
`fm-diagram.sh` reads owned ids through the grammar's `FM_OWNED_ID`, and the
page's `diagram.js` through `taskGrammar()`, the board's twin, which the
server puts in front of that file when it serves it, so neither holds a
copy of the id's shape (section 15.4).

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
the merge helper. A/B/C keep their existing meanings when all confirmation
answers are Yes. Cards with questions store `answers` in question order as
`{index, ok: true}` or `{index, ok: false, text}`; each No text obeys the custom
text limits. Any No stores `chosen: "change"`, the selected option or `custom`
in `picked`, and custom `text` when present. Such a record has `effect: null`,
`effect_outcome: "recorded"` and `merge: null`: it requests a spec revision and
grants no dispatch, merge, park, drop or send-back authority. Never act on
`picked`. An identical selected option, custom text and answers is idempotent;
a different submission conflicts with the recorded answer.

New requests require `--details <file>` with this shared data contract:
`{en: Locale, "zh-TW": Locale}`, where each Locale contains nonempty strings
`title`, `explanation`, `before`, `after`, `outcome`, and `options.A/B/C`, each
with `description`, `pros`, `cons`. Each string is bounded to 2000 code points.
Firstmate authors both locales on dispatch cards; the self-project merge fallback
reuses those approved details, rather than inferring intent from task titles.
The board escapes data as text, diagrams use the authored before/after labels,
and zh-CN applies the same ordered TW-to-CN table as the UI. Invalid requests
fail before a pending record is written; existing IDs cannot be replaced.
Legacy scalar records remain readable with an explicit missing-details notice.
Trusted repository diagram fragments are assets, never fields in this input.
The built-in diagram tier draws `before_nodes`/`after_nodes` when present, with
a legend and optional change table; authored drawings still win, and the board
records confirmation answers on the decision.

Intent cards add locale fields (T-210, T-228): `intent`, `why`, `done` and
`questions` hold `{kind: "step"|"fact", text}` items; `notes` holds
`{kind: "note"|"caution", text}` items. These arrays hold 1–12 items, except
questions hold 1–6. `scope_in` and `scope_out` are arrays of plain strings,
each 1–200 code points. `before_nodes` and `after_nodes` hold 1–8
`{state, label}` items: `same` in either, `gone` only before, `new` only after.
`change_table` holds 1–8 `{text, A, B, C}` rows with marks `✓`, `—` or `?`.
Other new text is 1–2000 code points; prohibited controls and lone surrogates
are refused. Each field is present in both locales or neither; questions,
node arrays and change-table rows have matching counts. Any new field requires
`intent` and `done` in both locales. Every intent item N (1-based in each locale)
has an alignment item in that locale's `done` starting with `Intent N:` (en)
or `意圖 N：` / `意圖 N:` (zh-TW), with one ASCII space before N. It names
the mechanism step that meets the intent and its evidence; only the prefix is
enforced, while the claim needs manual review. Other done items remain allowed.
The other fields are optional except on merge intent cards, as below.
Unknown locale keys remain forward compatible.

A task spec may also carry an optional bilingual `explain` block (T-230), with
`intent`, `why`, `scope_in`, `scope_out`, `done`, `notes`, `before_nodes` and
`after_nodes`. It excludes decision questions and change tables. Both locales
need intent, aligned done items and both node lists. `fm_ste.py check-explain
<spec.json>` shares the field, sentence and node-label rules above; structural
errors exit 64 and STE failures exit 65. No explain prints `{"explain": false}`
and exits zero. Task validation and spec preflight import the checker lazily
only for specs with explain, so older specs and isolated config readers keep
working. After successful preflight, firstmate runs `fm-diagram.sh --task <id>
[--project <name>]` to draw the explain nodes in all three locales. Task drawings
use `task-<project>-<id>.<lang>.html`, or `task-<id>.<lang>.html` for a nameless
default project, in the same self/external diagram stores as decision drawings.

`bin/lib/fm_ste.py` is the single writing-rule and glossary source. Its
`check-details [--kind <kind>] <file>` CLI validates the new fields and checks intent-card prose and
node labels before `fm-decide.sh` binds or writes a request. Malformed fields
exit 64; STE failures exit 65 with each failing sentence and rule. Warnings do
not refuse a card. A passing request stores the report in `ste` beside
`details`, for read-only display. `rules` exports the bilingual rule table,
limits and word lists. With `--kind merge` or `--kind merge-untracked`, an intent
card must carry `intent`, `why`, `scope_in`, `scope_out`, `done`, `questions`,
`before_nodes`, `after_nodes`, and `change_table` in both locales; `notes` is
optional. The title starts with `MERGE CARD — ` in en and `【合併卡】` in zh-TW.
Missing fields or labels exit 64. Legacy details without any intent-card fields
bypass this check and receive no `ste` key. Already-pending and decided records
are never re-checked; no records are migrated. These rules apply at the next
`--request`. Previously authored, unrequested `state/decision-details/` files
must be rewritten and checked with `check-details --kind merge` before the
autopilot requests them, or it reports the request's exit 64 refusal.

The five defaults, each changeable by a later card, are: enforce STE when an
intent card is raised; turn “No, change it” into a spec-change request (T-211);
use the captain-approved Chinese Z1–Z8 rules and glossary from `fm_ste.py`;
apply this standard to cards only, not PR bodies or worker briefs; and, following
the captain's board prototype approval on 2026-10-07 ("看板樣式可以了, 可以以這個版本開發"),
provide a light theme and a per-viewer toggle, keeping dark as the first-visit
theme when the system scheme is dark. STE has no Chinese standard; these Chinese rules are the
approved equivalent. Mechanical checks do not prove meaning or the rules
marked “checked by eye”.

A new card's id names its owner, `D-<project>-<task>-<n>`, and is allocated by
`fm-decide.sh --allocate` before the card is requested (section 15.4).
`fm-autopilot.sh` consumes `state/decision-details/<id>.json` after gates pass,
under the id it allocated for the task's merge card; a later turn reuses that
id rather than taking another. Authored details always win and are never
overwritten. For the self project, when no authored file exists, the autopilot
builds details from the highest-numbered answered dispatch card with chosen A
for that task. It copies both locales' intent fields and checks the result with
`fm_ste.py check-details --kind merge` before writing
`state/decision-details-built/<id>.json`. Built files stay outside the gate
fingerprint's inputs, so a write or a refused request starts no new gate run.
An external project still needs authored details. A failed build wakes firstmate
with the reserved id and the missing-card or checker diagnostic. Invalid
authored input is reported as no card created. Only a successful request is
announced as asking the captain.

**Only a decision request rings (T-096).** A card the captain must answer can
sit unseen while the captain is not looking at the board, so inside Herdr
(`HERDR_ENV=1`, which Herdr exports and its own `herdr --skill` tests for) a
successful `fm-decide.sh --request`, of any kind, merge included, calls
`herdr notification show` once: the title names the project, the task and
the kind, the body is the card's one-line question in the captain's
language as originally implemented, `zh-TW` (this notification still uses
that fixed locale; T-154 changes the board and authored report defaults,
not the notification script), and the sound is
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
started through T-151's lifeline with the board service as named owner, and
the project's merge marker records decision, project and owned run identity.
T-054's adopted recovery contract replaces the older PID-polling proposal:
completion is writer-pushed, with one reconciliation of durable completion and
ownership evidence on restart, never a PID/directory polling loop.

- live or uncertain ownership leaves the record `running` and the project
  turn held until confirmed completion or abandoned ownership;
- after confirmed completion or abandoned ownership, the outcome is read, never
  guessed: a `merged` event in the log for the card's `(project, pr)` after
  the response makes it `merged`; failing that, `gh pr view --repo <the
  project's github> <pr> --json state` saying `MERGED` makes it `merged`
  (and `fm-reconcile.sh` repairs the missing event from GitHub, as it already
  does); `OPEN` or `CLOSED` makes it `failed` with the reason "the merge
  helper stopped before recording an outcome", never retried;
- if GitHub cannot be read, the record stays `running` and the board shows
  the card as "merge outcome unknown" by name; the project's turn stays held,
  because freeing it on a guess could card a branch against a `base` that has
  already moved. A later pushed reconciliation or bounded GitHub retry may
  resolve it; no local liveness polling is introduced.

The board's existing re-read of its own decision records, looking only for a
record still saying `running`, never stops the board on failure: a failed read
skips that tick (logged once per distinct error) and retries on the next; this
is a read of the board's own records, not liveness polling of a helper or its
directories, so completion and ownership remain writer-pushed as stated above.

A board that is down starts no merges, so a turn held while it is down holds
back nothing that could have run.

Await mode blocks on a doorbell of its own (T-151, "Owners and wakes"):
`fm-decide.sh --await` registers one under `state/session/wake.d/`, looks
for the answer file once it has, and looks again each time the board rings,
which it does whenever it writes an answer. Any number of waiters each hear
every ring. Nothing polls `state/decisions/`; an answer that arrives with
no ring is not found until the next one. Wake latency must be measured, not inferred from the
mechanism. **No `fswatch` dependency.** T-157 removes the obsolete decision
watcher; the doorbell is the only wait mechanism.

These are orchestration requirements, not enforcement inside `fm-merge.sh`.
The board calls that helper for choice A on a pending merge card. The helper
checks that the pull request is the card's task's (or, `--untracked`, that
its branch and title name no task), checks PR state and invokes GitHub merge, then
attempts event emission and cleanup; it does not read approval decisions or
run the gates. The board
route does not rerun gates either. Firstmate must verify current-head gates, CI,
reviewer provenance and board approval, and coordinate fresh verification when
the head changes so a stale card is not treated as ready. `fm-autopilot.sh` requests
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

**A new task's spec comes with its worktree (T-147).** Firstmate writes a new
task's `design/tasks/<id>.json` in its own working tree, and the task's new
branch, made from the base, does not carry it: T-157's codex round was told
the file "is committed on this branch", found it was not, and stopped. So
when `fm-worker.sh` makes a new branch's worktree and the file is not in it,
it copies the spec it read from the dispatching repository in, uncommitted,
and the prompt says it is there and goes out with the round's commit. The
copy is not the round's work: a round that leaves it as it was and changes
nothing else changed nothing. A later round's branch carries the file
already; a pinned round's file follows the latest approved pin (15.5),
while an unpinned rebuilt round's entry stays frozen to the previous head
(5.3.3), so only a new unpinned branch gets the dispatch copy.
`tests/worker.test.sh` covers a new task whose spec is untracked in the repository.

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
role may name its own engine — `reviewer:` and `worker:` blocks in the
engine `config.yaml`, with private external-project overrides below. Named
vendors lead their configured fallback chain. The shipped
worker rule `opposite-of-host` resolves from the recorded firstmate host and
puts both main vendors before the remaining fallbacks (§4), with no vendor
run twice. A reviewer whose engine is down is
therefore not a reviewer who never ran.

External projects may override either role's `vendor:` in the `worker:` or
`reviewer:` block of private `FM_HOME/projects/<name>/state/config.yaml`.
A named private vendor records `rule=project`; private `opposite-of-host`
keeps that rule, and explicit `--vendor` still wins and records `explicit`.
A non-empty private `fallback:` list in `- item` line form replaces only the
engine fallback list; the opposite-of-host pair step still comes before it.
Empty or missing private lists use the engine list. Inline values such as
`fallback: [codex]` are reported and ignored. Models stay in the engine config:
role/top-level model overrides belong to the vendor the engine alone resolves;
other vendors use `models.<vendor>`, with no private model override.
The shared resolver applies this policy to dispatch, autopilot and hand launches.
A dispatched task reads changed private vendor settings at its next launch
without a re-gate: its contract pin stays fixed. Before dispatch, changing the
private file changes its contract digest and requires fresh readiness judgment.
Re-running onboarding rewrites the private file from the contract and drops
these hand-added keys; add them again afterward. The board vendor badge still
shows the engine rule.

The reviewer's `vendor` and `model` are the captain's choice (T-066); this
repository names `claude` and `claude-opus-5-5` for review. Since T-174 the
worker uses `opposite-of-host`, with the selected vendor's own model (T-146). A project
naming neither is reported by `fm-session.sh start` and firstmate asks the
captain through a choice card; the answer lands as a `config.yaml` pull
request. **`model` is applied, not only recorded (T-127)**: since T-146 it
is resolved per vendor, not per role - `fm_run_chain` in `bin/fm-config.sh`
hands each attempt the model for the vendor that attempt runs as `FM_MODEL`
(below), and each adapter passes it with its CLI's own flag; section 11 above and `bin/adapters/_contract.md` have the
whole of it, including what refuses a round whose model the vendor does not
recognise, and what the run records once it has actually run on one.

**A model is named per vendor (T-146).** A model name belongs to one
vendor, and T-127 resolved one per role: a round moved to another vendor -
`fm-worker.sh --vendor`, a fallback in the chain - was handed the first
vendor's name and refused (found 2026-09-29, when the captain asked for codex
workers). So `config.yaml` names each vendor's own model:

```yaml
vendor: opposite-of-host
models:
  claude: claude-opus-5-5
  codex:  gpt-6-astra
reviewer:
  vendor: claude
```

and `fm_run_chain` hands every attempt the model for the vendor it runs
(`fm_model_for <role> <vendor>` in `bin/fm-config.sh`), when the caller names
its role in `FM_MODEL_ROLE`, as `fm-worker.sh` and `fm-review.sh` do. The
order is: the role's own `model:`, only when the vendor is the role's own
vendor (`worker.vendor`/`reviewer.vendor`, else the top-level one); then
`models.<vendor>`; then the top-level `model:`, only when the vendor is the
top-level vendor, so a config written before `models:` reads as it did. A
vendor with none of these gets no model flag and runs on its CLI's default,
which the round records from its transcript; `model_requested` is then
empty. `fm_model <role>` is `fm_model_for` for the role's own vendor.

`reviewer: mode:` sets how a review runs. An external project may override
it in private `FM_HOME/projects/<name>/state/config.yaml`; an absent or empty
private value uses the engine setting. Invalid values name their source file.
The self project reads only the engine setting. `diff`, the default when no
mode is declared, is the prompt above and nothing else. `run` makes a
fresh clone of the pull request head under the system temp directory - never a
worktree, whose shared `.git` would let git inside it write outside it - with
the base at `fm/base`, the head at `fm/head` and no remote, and removes it
from the EXIT trap on every exit the shell handles; a SIGKILL runs no trap,
so the next run-mode round sweeps any `fm-review.*` checkout its owning round
no longer holds a kernel `flock` on (T-123; §13.1 says why not a pid), not
one whose recorded pid merely fails `kill -0`. The prompt adds the branch's own
project contract and asks the reviewer to read what CI found on the head,
judge the diff with it, and check a claim with a small command where reading
is not enough - never the full `check`, never a suite that starts rounds, a
board or a browser, and never fail-first by hand, which the `fail-first` CI
job does (T-153) - every command run to completion in the foreground, since
the round's one turn ends when its answer does and a backgrounded job is
never checked on (T-123) - and an **Executed** / **Read, not run** account. The adapter, not the prompt, confines the engine:
`FM_RUN_REVIEW=1` and `FM_REVIEW_CHECKOUT` tell it the round is a run-mode one,
and only an adapter carrying a `# fm:review-run` line may take it -
`fm_review_run_chain` drops the others from the chain, refuses a head that
lacks it with `65`, and `fm_adapter_context` refuses one before its CLI
starts. `claude` and T-163 `codex` carry it. Codex additionally requires the
outer OS sandbox and trusted managed context bound to the isolated checkout;
final output has transport identity/digest verification, and live/uncertain
execution owners retain their checkout. A marker alone cannot admit it.
For Claude, `--restricted`, `--strict-mcp-config` and
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
repository, and the clone's scripts choose their tree from it, so a script
the reviewer ran would otherwise act on another tree than the head under review.
The reviewer has no GitHub access at all, and needs none: `fm-review.sh`,
outside the round, reads what CI found on the head and puts it in the prompt,
in either mode (§7; T-153). Green CI and the gates are still firstmate's
merge gate in both modes (§6, the merge double check), not a review
criterion. What stops a push is the
missing remote and the unreachable GitHub; the deny list for push, gh writes
and raw HTTP matches a literal command prefix and is only a second guard.
Both modes emit `review_opened` and
`approved` or `review_failed` as the reviewer; `fm-review.sh` posts the verdict.

A round that produced no review exits `3` and emits `review_failed` with
`data.review_outcome` set to `missing_review` when an attempt completed without
a signed verdict, or `infrastructure_error` for vendor/configuration/execution
failure; it never reaches the pull request and never counts toward gate 6. A
verdict has to
carry exactly one unquoted `APPROVE:<task>` or `REJECT:<task>` in the final
assistant answer. Only that answer is the verdict; prompt echoes, intermediate
text, quoted examples and full CLI transcripts are not authoritative. Retain
reviewer identity and the reviewed head with the evidence. Built-in managed
adapters extract and retain the final answer. T-163 managed Codex run mode binds completed final output to transport identity
and digest in its isolated checkout. Legacy/custom paths retain their selected final answer with explicit `legacy`
provenance (captain, 2026-10-02). They cannot claim managed authentication;
T-135 accepts their locally retained, head/patch-bound verdicts alongside
`authenticated` managed Codex verdicts. This local
binding does not establish authoritative remote-head freshness (§15.5).
The board therefore treats a legacy `review_failed` as missing-review/error,
not rejection. A directed rejection exists only when the event also carries
the additive `data.review_outcome: "rejected"` contract. T-035 owns emitting
that datum after it has authoritative final-answer evidence; old logs remain
truthful without it. Crew phase follows each actor's dispatched role, so a
reviewer is reviewing even while a worker on the same task has another phase.

A round's result records its wall-clock (T-153): every `approved` and
`review_failed` a round emits carries `data.wall_clock {started, ended,
seconds, ci_wait}` - epoch seconds from just before its `review_opened` to
the verdict, and how many of them it spent waiting for the head's CI.
`/api/state` gives each task `last_review {actor, seconds, outcome}` for its
latest ended round: the verdict's own `wall_clock.seconds` where it carries
one, else the log's time from that reviewer's `review_opened` to its verdict;
`null` before any round has ended. The task's card on the board shows it
(T-145) as one line, "last review 17:05 · changes requested" - minutes and
seconds, with hours in front past the hour, and the outcome as approved,
changes requested, or no verdict for any other end - in `en` and `zh-TW`; a
task with `last_review` null shows none.

The judgement about outages can never be right on wording alone, because
there is no phrase a model cannot write — this repository contains
"Authentication required" in two files, so any review of it quotes them. So
wording does not decide. The adapter is deliberately generous, and the caller
settles it: `fm_run_chain` takes a predicate answering *did this run produce
work?*, and work beats a signature. A worker asks whether the worktree
changed; legacy reviewer predicates may scan combined output, which is not proof of a
final verdict. T-163 managed Codex requires authenticated final-output evidence;
T-167 classifies actual CLI/provider errors for the current attempt rather than
quoted error strings in model/tool text. Being
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

For the self project, a note beside worker changes that are published is a
recoverable side issue: its original bytes are kept under `state/unsent/`,
with a `.md.json` sidecar recording task, PR, round, actor, marker and saved time.
The sidecar's `head` stays null until the push succeeds. Only then is it updated
to the pushed head and `worker_note_unsent` emitted with the PR and bilingual
summary; the round ends successfully. A failed push keeps its own exit code and emits
no unsent-note event. A copy that cannot be kept emits `worker_crashed`; the
work still publishes and the round ends `73`. Sidecar-writing failures warn
without changing the outcome. Known-PR question failures also get a sidecar;
notes never offered have no marker. External private recovery is unchanged.

`bin/fm.sh unsent` lists kept notes in name order, including old files with
no PR recorded and unpublished notes. `bin/fm.sh unsent --post` resolves the
installation's default self project, requires comments projection, and uses
that repository as cwd. It skips legacy files without a PR and null heads,
looks up the marker before posting, and moves delivered `.md`/`.json` pairs to
`state/unsent/posted/`; it deletes nothing. A failed lookup or post leaves the
copy for recovery. An external default lists nothing and refuses `--post`.
The autopilot persists one judgment wake for `worker_note_unsent`, even while
the task is busy, naming `bin/fm.sh unsent --post`; restart does not repeat it.
Failed rounds also enter the autopilot's judgment path. Neither event itself
restarts a worker or establishes delivery to firstmate. The new note event
changes neither the board lane nor the voyage's crash state.

Nothing reads the worker's exit status either. `fm-dispatch` starts it
through a session-owned lifeline keeper and does not wait for completion,
so `73` is read by a person, and the one
event the round writes is the one the worker writes — there is no
second `worker_crashed` from a caller noticing the code. The codes a
worker can exit with are `1` a failed attempt, `2` no vendor was
available, `64` it was called wrong, `65` no such task in
`design/tasks/`, an unknown configured adapter, refused external routing or
policy, an unverifiable external PR head, or staged private artifacts,
`70` something the run
needs and cannot have — no library, no worktree, nowhere to put a scratch file,
identity/snapshot failure, a live task lock, failed managed transport, a
round's commit that failed (nothing is pushed or reported after it), a new
script whose executable bit could not be set before it, or a
rebuild on the base that could not be made —
`71` the push failed — a rebuilt branch's lease refused included — `72` no
pull request number came back, `73` the worker had
a question that could not be posted, a refused rebuild-only note, or a note
that could neither be posted nor kept (a kept note beside published worker
changes ends successfully), `74` GitHub could not
say which pull request the branch has, `75` a rebuilt round was refused
before its commit — a conflict marker left, a conflict with no markers left
exactly as the merge left it, a HEAD no longer on the rebuild base, or the
task's own entry not as the pin has it (the previous head for an unpinned
round) — and nothing was published, and `130`, `143` — a signal, 128
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
red could never be fixed by anything. For self projects, if it rebases, nothing
changes: the round builds on the branch as it is. If it does not, the branch
is rebuilt. External projects also rebuild a clean branch that is behind, as
described below.
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
standing-list protocol (§7) requires of a worker who finds no list (T-098). With no change of the worker's,
the commit is the rebuild alone; otherwise the worker's changes are in it
on top. An asking round is still reported as asked, and its question
still goes on the pull request: the one there is, or the one the push
opens. A note the pull request refuses is kept under `state/unsent/` at
once, and only once. For self-project comments, the posted body ends with
`<!-- fm-note sha256=<hex> -->`, hashing the original file bytes without changing
the kept file. Only GitHub's transient GraphQL execution error and HTTP
500/502/503/504 are retried, at most twice (default delays 2 and 5 seconds).
Each retry follows a marker lookup: found means delivered; lookup failure
stops; absent permits retry. A lookup may lag GitHub's store, so this narrows
duplicate risk rather than proving no copy exists. Other refusals and external
comments are never retried.

The rebuild is still pushed. With worker changes, a kept note gets its sidecar
and `worker_note_unsent` only after publication, and the round ends successfully. With
no worker changes, the refused note still ends `73`, including a note held
for the PR this rebuild opens. A failure on the way to the push keeps its own
code and the already-kept note; a changed-work note's sidecar still has
`head: null` and emits no unsent-note wake. A refused rebuild-only round used
to publish nothing, and the branch stayed on its old head, `DIRTY` on
GitHub, until the captain pushed it by hand (T-089, T-086).

Unresolved is a conflict, with or without markers, and also the task's
own `design/tasks/<id>.json` file when the rebuild could not
keep it as the pin has it (or the previous head in an unpinned round) —
the prompt lists that file for the worker to put back, and the check before
the commit refuses the rebuild
as it stands, as it refuses a marker. An unresolved rebuild is never
published. A round that only asks about one completes as asked and
publishes nothing; one refused before its commit publishes nothing
either. The next round finds the
worktree dirty, copies it to `state/rescued/` as it does any interrupted
run, recreates the worktree from the unmoved branch and rebuilds again.

The task's own file, `design/tasks/<id>.json` (section 14), comes through
as the latest approved pin has it, byte for byte; an unpinned round keeps
it as the previous head had it. Restoration is best effort; the pre-commit
check holds the round if it fails or the worker changes the frozen file.
Other files are merged normally, with unresolved conflicts handed to the
worker. Legacy array and task-table migration is retired (T-157).

After the adapter returns, a rebuilt round is not committed while HEAD is
anything but the rebuild base, detached — a commit made on it mid-round
would sit under the round, outside every check — nor while any file it
carries, read against that base, has a line starting `<<<<<<<` or
`>>>>>>>`, nor while a conflict with no markers is byte for byte what the
merge left, nor while the task's own file differs
from the pin's bytes (or the previous head's in an unpinned round) —
however it got that way, including a worker that rewrote it while resolving.
In a rebuilt round the task's own entry is therefore frozen: a pinned
entry changes only through a captain-approved repin, and an unpinned
entry's edit waits for a round that is not a rebuild. The run names the
files, publishes nothing and exits `75`. Otherwise the rebuild and the round's work are one commit on the
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

An external round uses this same rebuild only when the project's confirmed
conventions set `force_with_lease: true` (T-223; captain 2026-10-06,
D-firstmate-workflow-T223-2). Its lease is the PR head the round was bound to;
the rebuilt branch is pushed to the same PR with `--force-with-lease`, never
to a protected base. With `force_with_lease: false`, the branch is held as
before. The context pack, prompt identity and private worker report retain
the previous PR head; progress projection waits for the pushed head. The
rebuild note with previous head, new head and conflicts is retained privately
rather than posted to the external PR. An external branch that only falls
behind is rebuilt the same way (T-231), with an empty conflict list. Its prompt
says the replay was clean: change nothing unless the brief asks for it. The
agent still runs, so the existing commit, lease push, private note and worker
report keep one evidence chain; a clean rebuild publishes even without edits.

Autopilot judges external PRs by fetched commit ancestry, because repositories
without branch protection do not report `behind`. Open, non-draft PRs with
mergeability true or unknown can update when the fetched base is not an
ancestor of the verified fetched head; a conflicting PR is held. Confirmed
`force_with_lease: true` selects a GitHub rebase with `expectedHeadOid`;
otherwise `merge_method: merge` selects REST update-branch. Conventions allowing
neither queue one bilingual hold per head. Unknown ancestry retries without an
update. After a rebase, the local task ref follows only when it still equals
the recorded old head, with no live round or busy job and no dirty worktree.
A worktree uses `reset --keep`; a bare ref uses compare-and-swap. The pending
rebase record survives the remote head change until synchronization or closure.
Self updates retain their mergeable-and-behind REST path.

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

A question round opens its pull request as a draft and records firstmate's
ownership in project runtime state at `drafts/<task>-<number>`. A later round
that delivers work (including a rebuilt round), asks no question and uses the
existing, non-adopted PR marks that draft ready for review. Success removes
the marker; failed reads or ready writes warn without failing already pushed
work. A hand-made draft, an adopted PR or a draft from before these markers
existed stays as it is; firstmate raises a captain card for an older draft
that needs to become ready. Draft creation during a question round is unchanged.

| String | Posted by | Meaning |
|---|---|---|
| `APPROVE:<task-id>` | reviewer | the only valid pass signal |
| `ASK-PASS-CRITERIA:<task-id>` | worker | finds no standing list, or an unclear one, and asks for it |
| `CRITERIA-COMPLETE:<task-id>` | reviewer | closes every `REJECT`, from round one: the numbered list before it is the task's standing list |
| `REGRESSION:<task-id>` | reviewer | labels a new item on the standing list: newly introduced by the latest change |
| `NEW-GROUND:<task-id>` | reviewer | labels a new item on the standing list: the latest change touched code the list never covered |

---

## 6. Lifecycle and the gates

```
grilling  ->  /prototype  ->  [captain green-lights]  ->  design.md + design/tasks/
                                       |
                        fm-dispatch.sh (ready tasks only, three at a time)
                                       |
              fm-worker.sh: worktree -> adapter -> commit -> pull request
                                       |
                          *  fm-gate.sh, the six gates  *
                                       |
    fm-review.sh: given the PR, waits (bounded) for the head's required checks;
       the reviewer sees the diff, the spec, the criteria and what CI found -
          every job, the failing assertions, the fail-first report - and
         judges; run mode adds a fresh clone to check claims in (T-153)
                                       |
     not passed -> worker revives and fixes the closed list -> back to the gates
                                       |
              APPROVE -> firstmate summarises -> [captain merges on the board]
```

**A first round has a way forward (T-160).** Before reusing a branch,
`fm-worker.sh` resolves its open PR. With no PR, an attached clean leftover
whose head is an ancestor of the current base starts fresh on that base and
receives the new task spec. Branch existence alone does not make the prompt
a retry. Commits beyond the base are preserved; unpublished dirty work stays
in its attached worktree with a recovery copy. Existing PR and detached
rebuild recovery keep their rescue-and-recreate behavior.

While a new task's commits touch only its own spec, the dispatching
repository's revised spec is copied into the branch and prompt, including
when the spec already has a draft PR. An uncommitted change is never replaced
this way, and implementation commits keep the branch spec authoritative.

A no-PR round that only asks with a standalone `SCOPE-BLOCKED:<task>` or
`ASK-<reason>:<task>` marker in `.fm-say.md` opens a draft PR and posts that
note after creation. The spec supplies the diff when available; a task already
on the base gets `design/questions/<task>.md` carrying the question so GitHub
has a real diff to open. Firstmate must resolve that draft's scope (including
removing or authorizing the question record) before the gates and merge.
The transient `.fm-say.md` is never committed. Publication failures retain
the note through the existing `state/unsent/` recovery path. Ordinary notes
without a request marker and without work retain the premature-note failure.

**`fm-dispatch.sh` requires a project-store `greenlit` event or the captain's A
on the task's readiness card, using the same rule as pin `approval(None)`.**
A project-wide event need not match the proposed work; firstmate must verify
that authorization covers it. Dependencies, parks, closed and in-flight tasks,
readiness clearance and live owned capacity still govern launch.

The captain's word on untouched work is read from events too (T-058). A task
whose last `parked`/`unparked` event is `parked` is never started, and starts
again only after an `unparked`. A `closed` task — which is what a drop on the
board writes — is never started, and an `unparked` does not bring it back.
Neither counts as merged, so a task that depends on one waits, and its backlog
card names the parked or dropped task as its blocker.

**Autopilot holds readiness for firstmate (T-141).** The scripted service
queues "T-xxx ready: readiness card needed", deduplicated by readiness episode,
and leaves the task unjudged. Firstmate re-reads the spec against main, authors
the recommendation and evidence, and raises the captain's choice card under
the rule below. Autopilot supplies no boilerplate judgment and raises no card.
Existing T-118 card effects may carry out the captain's answer mechanically.

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
an SK task its merge card's id (T-119), but `fm-ready.sh judged` takes only a
`T-*` task's owned id. So it stays held, and
firstmate tells the captain, until the captain orders it directly.
`fm-dispatch.sh` holds every other ready task, and
starts nothing if it cannot read the answers. A task the captain orders
directly, or a completed rescope, is started with
`fm-dispatch.sh --task <id>`: the order lifts the
judgment check and no other, so greenlit, dependencies, park, drop and the
concurrency limit still hold, and it says which one held the task.

| # | Gate | How it is checked |
|---|---|---|
| 1 | **branch** — branch exists and has commits | `git rev-list --count main..<branch>` > 0 |
| 2 | **rebase** — rebase onto main is clean | attempt it in a scratch worktree; non-zero fails |
| 3 | **scope** — the diff stays in approved scope | shared verified pin resolver; changed files within pinned `scope`, unchanged self task entry, no `.fm-*` paths |
| 4 | **fail-first** — **the new tests are not vacuous** | classify by `project.tests`, revert the implementation, run `setup`, then only the suites the diff touches through `project.test`; the whole `check` only when none can be determined, said so; it must go red |
| 5 | **ci** — the required GitHub check is green | `gh pr checks <pr> --required` |
| 6 | **approval** — the latest verdict is an `APPROVE:<task-id>` for this change | its `REVIEWED:` line names the current head, or the same patch-id, merge-base to head, with no later `REJECT` (below); author filtered only if `FM_REVIEWER_LOGIN` is set |

Gate 3 (a local whole-project check) was retired on 2026-09-26 (T-114); T-232 (2026-10-06) renumbered the gates 1-6 and named them (old 4-7 are new 3-6). Records written before T-232 keep the old numbers and are read through bin/lib/fm_gates.json legacy.
A merge card stores gates by name; the board reads a legacy 7-slot array through the legacy map.
The autopilot and its gate jobs run the same frozen code snapshot, so their exit codes always use the same numbering. New transcripts carry `GATES:2` after `HEAD` and `BASE`; readiness stores gate names. Old transcripts, readiness records, decisions and events are never rewritten.

**Gate 4 delegates to `fm-failfirst.sh --gate --head=<branch>` (T-157).**
The shared engine prepares and runs both the head and the reverted tree, and
requires evidence that passes on the head and goes red on the base. The gate
keeps its declared-docs classification and its explicit `project.check`
fallback; CI keeps the behavior-path classification described in §7. Worktree
restoration, suite execution and assertion comparison have one implementation.
When the pinned contract declares a nonempty one-line `unrunnable` reason,
gate 4 runs no project commands and reports `! gate 4 (fail-first): ... not
runnable: <reason>` with a successful gate-run exit. Readiness accepts this
warning only for gate 4 and only with that pinned declaration, recording
`not_runnable: {"fail-first": "<reason>"}` in readiness and the candidate.
The merge card stays raisable and displays the reason plus a reminder that
the project's required CI checks are the only remaining test evidence for
this change: confirm they are green before choosing A. This result never
blocks the merge card; red or missing CI still does. Ordinary pins and CI-mode
fail-first behavior are unchanged.

A new feature's tests go in a new file named for that feature, or in the
file that already owns the feature; never append them to an unrelated suite.
Keep every file under `tests/` at 1200 lines or fewer. Shared shell and Python
fixtures belong in `tests/lib/`; shared browser fixtures in `tests/e2e/lib/`.
Name helper dependencies literally so gate 4 can select their consuming
suites. Split files must run independently and preserve existing assertions
and test names.

**Gate 4 runs only the touched suites (T-114).** On each tree it runs,
through `project.test`, every test file the diff changes, then every other
test file that names one of them by path or file name - the suites that
source a changed helper. A name counts only standing alone, with no other
file-name character either side, so `helper.sh` is not named by
`fm-helper.sh`. An unchanged suite that names only changed
implementation is not run: in the reverted tree it is the base's test of the
base's code, and could go red only for a reason other than the diff. When no
suite can be determined that way - no `project.test` declared, or no touched
test file left in the tree - gate 4 runs the whole `check` and says so on
stderr, as it says which suites it ran.

**Gate runs are serialized on one machine (T-114).** A run holds a kernel
`flock` on the file `FM_GATE_LOCK` (default `/tmp/fm-gate.lock`) from start to
exit; a second run waits and says whose run it waits for, from the pid the
holder writes in the file. The default is one path for the machine and does
not follow `TMPDIR`, which is per user on macOS and per sandbox. The kernel
releases the lock when the holder exits, however it exits, so no run judges
whether another is alive and no lock is ever removed: a killed run, a reused
pid, another user's run and a lock file that names no holder cannot be
misread. The suites the gate runs do not inherit the descriptor. The path
sits where every user writes, so it is opened once, by perl, refusing a
symlink and anything but a regular file with that one name, and every read
and write of it goes through that descriptor; a planted link cannot make a
gate run create, truncate or write another file, and the run exits 70 naming
the file instead. A run
started inside a run holding the same lock (it inherits
`FM_GATE_LOCK_HELD`) is refused with exit 70 rather than waiting for ever or
running unlocked, so every suite that runs the real gate sets its own
`FM_GATE_LOCK`, and `tests/gate.test.sh` checks that each one does.

Require all six gates and current-head review evidence before treating a merge
card as ready. `fm-autopilot.sh` requests a card after gate success, but `fm-review.sh`
can emit `approved` on an approval substring before that subsequent gate run.
Historical transport until T-135 lands: Gate 6 reads the verdict comments (the reviewer's only, when
`FM_REVIEWER_LOGIN` is set) and takes the latest; a later rejection supersedes
an earlier approval. It does not distinguish final from quoted markers, and an
`APPROVE` with no `REVIEWED:` line (one posted by hand, or before T-113) is
still read as before and binds to no head, which the gate says. Firstmate must
verify provenance and current readiness explicitly. Any red gate
requires remediation regardless of praise or an `approved` event.

**Round order and the merge double check (captain, 2026-09-25).** A review
round starts through `fm-review.sh` after the worker hands back and the
autopilot observes gates 1, 2, 3, 4 and 5 green. Given
`--pr`, the round itself waits for the head's required checks, bounded, before
it starts the reviewer, so the reviewer is handed their results (T-153; §7);
the launcher retains this wait for explicitly requested rounds too. Green CI and the gates are not a review
criterion in either mode. A merge card needs two independent checks on the same current
head: the reviewer's `APPROVE:<task-id>` for that head, and firstmate's own
reading of that head's required GitHub check (green) and the six gates
(`fm-gate.sh`). Neither substitutes for the other - an approval is not green
CI, and green gates are not an approval. A head that changes after either
check requires fresh gates, with the approval carry rule below. The autopilot
sends a task to review once every gate before 6 is green. Firstmate writes
the brief for any subsequent worker round.

**The approval binds to the change; CI and the gates bind to the head
(T-113, captain, 2026-09-26).** Strict branch protection moves every open
head after each merge, and `gh pr update-branch` then forced a second review
of a change that was identical. So the two checks bind to different things.
`fm-review.sh` ends every verdict it posts with one line of its own, after
the reviewer's words:

```
REVIEWED:<task-id> verdict=<APPROVE|REJECT> head=<sha> base=<merge-base> patch=<patch-id> files=<JSON array>
```

`verdict` is the last `APPROVE:<task-id>` or `REJECT:<task-id>` that stands
on a line of its own in the reviewer's answer, never a marker mentioned in
passing; an answer with no standalone marker is recorded as `REJECT`. The
same reading decides the `approved` or `review_failed` event, so the event
and the line gate 6 trusts cannot disagree.

`base` is the head's merge-base with `main`; `patch` is `git patch-id
--stable` of the diff between them, taken with `git diff-tree -p
--no-renames`, which reads no user configuration; `files` lists every path
that diff touches. Gate 6 accepts the latest `APPROVE` when its `head` is the
current head, or when both of these hold:

1. the current change's patch-id, merge-base to head, equals the approved one;
2. no later `REJECT` supersedes the approval.

Otherwise it fails and names the condition, so firstmate knows a real
re-review is needed. A conflict resolution or any worker edit changes the
patch-id, and so always needs a new review. An APPROVE carries forward across
any update of the branch from its base as long as the change itself is
unchanged - the patch-id of merge-base..head equals the approved one; a
conflict that had to be resolved changes the patch and needs a review
(captain, 2026-09-29; SK-008). Base commits touching files the change
reviewed no longer void the approval, so `gh pr update-branch` is allowed
before or after an APPROVE and during a running review round. CI and the six
gates always rerun on the head being merged, since they test the change
combined with the current `main`.

Gate 4 names no toolchain. It reads the complete verified task pin's contract
(`setup`, `check`, `check_env`, `tests`, `test`, `docs`, optional `unrunnable`) through the shared
fail-first engine. Neither the tested branch nor a mutable engine copy can
change that contract. A scoped config edit cannot alter its own gates.
The self contract lives once at `projects.firstmate-workflow.project` in
`config.yaml` (T-170). Both shell and Python readers (including session
start/status) also accept the historical top-level `project:` block and refuse
a duplicate. Old pins retain their recorded commit
and location without repinning. External contracts remain approved private
snapshots.
Gate 4 asks for no new test only when every changed non-test path matches
the pinned `docs` globs; with none declared, nothing is exempt.
An undeclared `check` where gate 4 must fall back to it, or a failed `setup`,
fails the gate by name; a stage the
check skipped is not a stage that passed. `bin/fm-session.sh start` runs
`setup` once in the checkout and reports the contract; `status` only reports it.

### Spec preflight and migration (T-185)

Before every dispatch and repin, firstmate runs
`bin/fm-review.sh --spec-preflight --task <task> --spec <file>` with the selected
project. The reviewer gets an independent read-only checkout of the current base
and the exact proposed bytes, not a worker report or implementation verdict.
It checks each acceptance line for scope feasibility; every affected caller,
mirror, fixture and test; existing ids, formats, paths and interfaces; and an
explicit, tested migration for validation, lint, gate, schema or record changes.
Check 5 (T-189): when the scope lists design/design.md, the acceptance names the
numbered section (§N or §N.M) it edits and adds nothing after the last one.
The first final is one exhaustive numbered checklist (T-248), with at least one
item per acceptance line and coverage of why and its references, each Change,
callers/fixtures/mirrors, scope completeness, new-behaviour versus regression
test labels, migration of records/pins/tasks in flight, the named design section,
i18n and lint reachability, and external-project privacy. Each item starts
`N. ok:` or `N. gap:`, cites file:line, and states the expected spec change for
a gap. Bold or heading markup around the number (T-206) and bold status words
are allowed. A standalone `PREFLIGHT-COMPLETE:<task>` closes the checklist
immediately before `SPEC-OK:<task>` or `SPEC-GAPS:<task>`, unquoted, unfenced and
last; blank lines between the two markers are allowed.

Every later preflight re-issues the latest stored standing list, even after
SPEC-OK or changed spec bytes. It keeps all earlier numbers: gap/open becomes
done/open; ok/done becomes ok/open. It appends only the next numbers, marked
`gap NEW-GROUND:` for amended text or `gap MISSED:` for something the earlier
pass should have caught. Every gap belongs in the first report. Retention checks
the final contiguous numbered block, acceptance count, numbering, transitions
and verdict consistency: SPEC-GAPS requires a gap/open item, SPEC-OK forbids one.
The signed receipt adds `standing` (number, status, label and verbatim first line)
and `missed` (the count of MISSED items); the original answer preserves complete
continuation text for the next prompt. Readers take no write lock or directory
creation step. These structural checks do not prove exhaustive model inspection
or that a NEW-GROUND/MISSED label is substantively correct.

Existing preflight records stay immutable and their exact-byte SPEC-OK remains
valid: the legacy decision parser is unchanged. Records without `standing` do
not seed a list; their next preflight starts a first pass. A vendor run begun
with the old prompt that reaches the new retention check fails with exit 65
naming PREFLIGHT-COMPLETE; firstmate reruns it. Running workers are unaffected.

The launcher retains signed `spec-preflight` evidence in the same project-local
store as briefs and verdicts, bound to the spec SHA-256 and observed base. Managed
Codex retains authenticated final provenance with explicit mode and spec binding;
other supported vendors remain labelled legacy and use their actual final output.
Ordinary reviewer completion, approval and authentication rules are unchanged.
Preflight identities carry `mode: spec-preflight` and use a separate `-sp-`
actor namespace with their own attempts. They do not advance ordinary review
rounds or attempts. Older preflight directories remain readable and are excluded
from ordinary attempt counting without rewriting their identity records.
No preflight result is gate 6 approval, CI evidence or permission to merge.

Every new worker invocation requires SPEC-OK for its exact pinned bytes. Missing,
different or changed bytes exit 65 with the preflight command. A read-only
prospective-pin check runs before freezing the launcher, allocating a crew
identity, publishing a PID or dispatch event, creating a branch/worktree, or
arming the EXIT checkpoint. Resumed self tasks read the captain-approved branch
spec directly from git; legacy unpinned inputs still require their exact bytes.
SPEC-GAPS requires
an amended spec, not an override on the same bytes. A repin therefore needs fresh
preflight when its spec changes. Existing records and pins are not rewritten or
grandfathered: export their exact spec bytes and preflight them before the next
worker dispatch. Already running rounds finish with frozen code; no live launcher
is edited. Tests cover missing and mismatched receipts, exact-byte admission,
changed pins, existing pins without receipts, and mode-bound final selection.
Missing or untested migration in a rule-changing diff is a REJECT finding.

---

## 7. The standing list

**The list comes with the first REJECT (captain, 2026-09-29; SK-007).**
Every `REJECT`, from round one, ends with the task's standing list: the
numbered, complete set of changes that would make this head pass, closed by
`CRITERIA-COMPLETE:<task-id>` on a line of its own, before the verdict line -
what the round-three answer used to be. T-126 took ten rounds, one new finding
per round from round seven on.

The standing list is the last contiguous numbered block ending at
`CRITERIA-COMPLETE:<task-id>` (T-181). Earlier numbered summaries, Executed
sections and unfenced code are not standing items. Use bullets, not numbers,
for summaries. A list restarting at `1.` after a blank line or an unindented
non-item label (such as `**Standing list**`, with or without surrounding blank
lines) starts a new block. Wrapped
lines, indented continuation paragraphs and blank lines inside an item belong
to that item. Duplicate or skipped numbers inside the block remain errors;
an APPROVE need not re-issue the list.

1. The first REJECT creates the standing list. Each later REJECT re-issues it:
   the same numbering, each earlier item marked **done** or **open**, and any
   new item appended with the next number and a label.
2. A new item is admissible only as `REGRESSION:<task-id>`, newly introduced
   by the latest change, or `NEW-GROUND:<task-id>`, the latest change touched
   code the list never covered. Nothing else can be added; an unlabelled new
   objection is a protocol violation.
3. The latest list is the standing one. It never drops an open item; an item
   leaves only by being marked done. The worker fixes every open item in one
   pass.
4. `ASK-PASS-CRITERIA:<task-id>` stays for a worker who finds no list, or an
   unclear one after a REJECT. Before edits, without a delayed round threshold, the worker writes it in
   `.fm-say.md` for script publication before touching a line and waits; that
   asking round changes no implementation files. The reviewer answers with the
   complete numbered list and `CRITERIA-COMPLETE:<task-id>`.
5. Report protocol violations to firstmate for board coordination.
   Historical implementation until T-135: `bin/fm-protocol.sh` gates from round three on a standing list:
   any comment with a numbered list before a standalone
   `CRITERIA-COMPLETE:<task-id>`. It exits 3 only when there is no list and no
   ask, 4 when the worker asked and no list followed, 6 when a re-issued list
   drops an earlier item number, and 5 when a re-issued list appends an item
   without `REGRESSION:<task-id>` or `NEW-GROUND:<task-id>` on its line, or a
   later reviewer verdict - a comment with a standalone `REJECT:<task-id>` or
   `REVIEWER_COMPLETE:<task-id>` - cites no item and carries none of
   `APPROVE:`, `REGRESSION:` or `NEW-GROUND:` with the task id. Only a verdict
   is policed: every other comment after the list - the worker's notes, its
   `.fm-say.md`, firstmate's briefs - is skipped, whoever posted it, because
   `fm-autopilot.sh` runs the check with no `FM_REVIEWER_LOGIN`; when that login is
   set it narrows the verdicts read to that author's. It emits a
   `protocol_violation` event for each. That historical reader collected every
   numbered line before the marker; T-181 limits it to the final block. It
   cannot determine every semantic violation: it does not check that a
   finding matches the item it cites, does not authenticate the markers, and
   does not prove that a regression or new ground is real. A passing protocol
   check does not establish compliance with this role contract.

T-135 replaces the following historical T-073 comment transport with local
records. Every REJECT supplies criteria from round one; every reviewer from
round two receives the local standing list and relevant prior rounds, with
worker reasoning excluded. Gate 6 and fm-protocol.sh consume provenance-labelled
local verdicts, retain latest rejection precedence and fail with a reason when
the local verdict is missing; optional comments never replace local authority.
Until T-135 lands, the legacy launcher carries the protocol as follows (T-073). From round two (SK-007), given `--pr`, `fm-review.sh` reads the pull
request's comments with `gh` and quotes into the prompt, verbatim, first the
latest comment holding `ASK-PASS-CRITERIA:<task-id>`, then every comment whose
numbered list is followed by `CRITERIA-COMPLETE:<task-id>`, in the order
posted, whether before or after the ask. A
marker counts only as a line of its own and a comment that asks is never a
list, so a worker's numbered change log that mentions a marker in passing is
not taken for the closed list. Each quote is fenced with a per-run nonce, so a
comment cannot close its own quote, and printed straight from `jq`, so its
trailing newlines survive. It then says which case holds: a list (the latest
is the standing list; findings cite its items, and a `REJECT` re-issues it
with new items labelled `REGRESSION:` or `NEW-GROUND:`), only an ask
(answer with the complete list), neither, or comments `gh` could not read, in
which case the round still runs; in the last two a `REJECT` still ends with
its complete list.
No other comment enters the prompt, so the worker's reasoning stays out.
Round one gets no closed-list section. Given `--pr`, it, like every
diff-mode round, does get the head section below; without `--pr` no round gets
either, and the prompt is unchanged.

A diff cannot show CI or gates, so a closed-list item asking for them could
never be closed (T-067, round nine). Current-head CI and gates are firstmate's
merge gate, not a review criterion (§6, the merge double check), so no
closed-list item may ask for them. The launcher shows the reviewer what
exists for the head, in either mode (T-088; T-153). Given `--pr`, every
round's prompt gets a **The head under
review** section before the diff, verbatim and labelled: the head SHA, from
the local branch the diff is taken from; the required checks' names and
where they came from (T-155, below); for each of them, its name, conclusion
and run URL from
GitHub's check runs for that exact commit (`gh api
repos/{owner}/{repo}/commits/<sha>/check-runs?check_name=<name>`), keeping
only a run whose `head_sha` is the head and the latest of those; and the
whole of `state/gates/<task-id>-<sha>.txt`, unfiltered and fenced with a
per-run nonce, when that file exists. Its lines are `fm-gate.sh`'s own
stdout: `  + gate N (name): …` or `  x gate N (name): …`. A required check that cannot be
read, a check with no run for this head, a missing gate summary, and each
gate the summary has no result line for (it stops at the first red gate, and
an empty one has none) are stated plainly. A round without `--pr` is
unchanged.

**The machine runs the tests; the reviewer judges (captain, 2026-09-29;
T-153).** On 2026-09-29 review rounds took 17 minutes to over two hours
(T-121 r9's ran past 1h50m), most of it re-running suites inside the round's
sandbox that start rounds of their own. macOS will not apply a sandbox inside
a sandbox (`sandbox_apply: Operation not permitted`), so those suites failed
or waited out timeouts there, while GitHub's runner, which has no outer
sandbox, runs them correctly in minutes. Rounds 1 and 2 of T-153 let a round
nest inside a round, and review found that it widened trust and loosened the
sandbox; that work was reverted. Instead:

1. **fm-review.sh waits for the head's CI.** Given `--pr`, in either mode,
   before the prompt is built it asks GitHub for every required check's runs
   for the head, and waits until the latest run of each is `completed`, for
   at most `FM_REVIEW_CI_WAIT` seconds (default 1200), asking every
   `FM_REVIEW_CI_POLL` (default 30). A check whose runs cannot be read is not
   waited on; it is stated unknown. While it waits the board is told, in `en`
   and `zh-TW`. The launcher's `crew_status` explicitly carries
   `phase: waiting_ci`, `window_expected: false` and `ci_pending` naming the
   pending checks (T-159). It refreshes when that list changes, not on each
   poll. The card, roster and ship distinguish this from reviewing; the card
   says that no window is expected until review starts. Reaching the bound
   emits a bilingual explanation with `ci_wait_bound: true`. After the wait,
   `phase: review` restores the usual reviewer state before launch. These
   transitions bypass heartbeat coalescing; ordinary heartbeats retain phase.
   Past the bound the round starts anyway, and the head section
   names every required check still running, or not yet started. The verdict
   event's `data.wall_clock` carries `ci_wait`, the seconds of the round
   spent waiting.

   **The names are what is required, not what exists (T-155).** On
   2026-09-30 T-145's first review started while its CI still ran and told
   the reviewer the required check could not be read: the names came from
   `gh pr checks --required`, which lists only checks that already exist on
   the pull request, and right after the worker's push GitHub has created
   none. So the names are read once per round, from the first source that
   names any: the base branch's protection (`gh api
   repos/{owner}/{repo}/branches/<base>/protection/required_status_checks`,
   its `.contexts` and `.checks[].context`), then `gh pr checks --required`,
   then config.yaml's `required_check` for the project. A required check
   with no run for the head yet is waited on as missing, within the same
   bound. Only when no source names any required check is the wait skipped,
   and the head section then says so plainly; otherwise it names the checks
   and the source they came from.
2. **The head section carries what CI found**, after the required check:
   every CI job of the head (`gh api .../commits/<sha>/check-runs?per_page=100`,
   the latest run of each name whose `head_sha` is the head) with its result
   and run; for each job that failed or timed out, the failing lines of its
   log (`gh run view --job <id> --log-failed`: each assertion line ending
   `FAIL` with the detail line under it, each red suite or stage `  x …`,
   and the runner's `##[error]` lines, timestamps and colour codes removed,
   at most 80 lines), fenced with a per-run nonce; and the fail-first report,
   the `fail-first-report` artifact of the run the `fail-first` job's URL
   names (`gh run download`), fenced the same way. A job list, a log or a
   report that cannot be read is stated. The three sections are always
   there: when the job list cannot be read, the failing-assertions and
   fail-first sections each say "Not available" and why, so the prompt
   never reads as "nothing failed" from evidence it did not fetch.
3. **The reviewer judges with that evidence** (skills/reviewer/SKILL.md). It
   never runs the full check, nor a suite that starts rounds, a board or a
   browser; it may run small commands that need no second sandbox - reading,
   grepping, git, a single script invocation - and lists them under
   **Executed**. Fail-first by hand is no longer its step: it reads the
   report and challenges a test the report lists only as a guard.

**Fail-first in CI (T-153).** `bin/fm-failfirst.sh <base-ref>` asks gate 4's
question on GitHub's runner, as the `fail-first` job of every pull request,
which the required `ci` job needs. From the merge-base of the base ref and
the head it splits the change into test files (the declared `tests` globs;
`tests/*`, `*.test.*`, `*.spec.*` when none) and the rest. Behaviour is a
non-test file under `bin/`, `board/` or `adapters/`. It makes two worktrees of
the head; in the base one every changed non-test file is restored from the
merge-base and every file the change adds is removed, while the head's tests
stay. The declared `setup` - or `--setup`, which CI sets to the dependency
install alone - runs in each, then every changed test file runs in both,
through the declared `test` template, at most six at a time, each run with a
session of its own (T-151). The head is re-run there, beside the base, rather
than read from CI's shards, so both runs see the same runner. Assertion lines
(`    <name>    ok|FAIL`, tests/lib.sh's shape) are compared by name and
occurrence: one that passes on the head and fails on the base, or is never
reached there because the base run failed, **went red on base**; one that
passes on both is a **guard**; one failing on the head is listed apart and
counts neither way. A suite that prints no assertion line counts as red only
when its base run fails and its head run passes.

The verdict is **not applicable** (exit 0) when the change touches no
behaviour - docs, skills, tests or CI only - and says why; **fail** (exit 1)
when it touches behaviour and adds or changes no suite, when no `test` is
declared, or when no assertion of a changed suite went red on base, naming
the guards; **pass** (exit 0) when at least one went red. The one reading
T-153's spec leaves open is taken this way: a behaviour change with no test
change fails, as gate 4 fails it, rather than being not applicable. The
report - per suite, the exit of each tree, the assertions red on base by
name and the guards - goes to stdout, to `--report` (the artifact) and to
`$GITHUB_STEP_SUMMARY`. It exits 70 when it cannot run (no merge-base, a
worktree it cannot make, a setup that fails) and 64 on bad usage.

T-157 shares changed-test selection with gate 4: an unchanged suite that
names a changed test helper by a whole filename is selected too. A reference
to changed implementation alone does not select a suite.

**Fail-first is sharded like the bash suites (T-158).** On 2026-09-30
T-121 changed 18 test files; the one `fail-first` job ran every one of them
on the head and again on the base, and was cancelled at its 10-minute limit
twice (616 s). That left the required `ci` check red on a change whose
shards were green, and any large change would hit the same limit. So CI
runs it in three steps, all on pull requests only:

1. **`fail-first timings`** reads the suite timings once, the way the
   `bash timings` job does for the bash shards (the last green run on `main`,
   best effort), and hands the same text to every shard. If a green run on `main` finished between two
   shards' own downloads, they would get two different splits, and a suite
   could land in no shard at all.
2. **`fail-first shard i/6`**, a matrix of 6, the bash shards' count. It
   runs `fm-failfirst.sh --shard=i/6 --part=<file>`. Its share of the
   changed test files is what `bin/ci.sh --plan i/6 -- <files>` gives: the
   same estimates from the same `FM_CI_TIMINGS_IN`, and the same
   longest-first packing that `--shard` applies to the bash suites (T-148).
   Every given file is packed, suite or not, and each lands in exactly one
   shard. The shard runs its share on the head and the base as above. It
   writes a JSON part (its shard, head, merge-base, the files it was given,
   and for each one the exits, the assertions red on base, the guards and
   those failing on the head) and uploads it as `fail-first-part-<i>`. A
   shard decides no verdict. It exits 0 once its share has run. A shard with
   no changed suite of its own is not applicable: it makes no worktree, runs
   no setup and succeeds at once. A shard exits 70 when it cannot run, and
   its part then names the files it was given and why. Values for `--shard`,
   `--part` and `--merge` go after `=` in one word, as `bin/ci.sh`'s
   `--shard=` does.
3. **`fail-first`**, the job the `ci` job needs and whose
   `fail-first-report` artifact `fm-review.sh` reads, unchanged in name,
   file (`fail-first.md`) and format. It runs whatever the shards did
   (`always()`) and runs `fm-failfirst.sh --merge=<dir>`, which runs no
   suite. It classifies the change again from the checkout and renders the
   one report from every part under the directory. A single, unsharded run
   renders its own part through the same code, so the merged report is the
   single job's report for the same change. A part for another head or
   merge-base is ignored. A changed test file that no part reports turns
   the verdict to **fail** and is named with its reason: the shard that had
   it could not run it (and why), or no report came from shard k. A merge
   with no parts at all fails the same way. It never falls back to an empty
   pass.

**Predicted, not promised.** Every shard says, in its log and job summary,
what it is predicted to take beside the heaviest bash shard, using one rule
for both. A pool of `--jobs` runs (the runner's CPUs, at most 6) takes the
longer of two figures: its longest run, or its whole load spread over the
pool. A fail-first shard's load counts each suite twice, once for the head
and once for the base. On `main`'s recorded timings (run 36511784453),
T-121's 18 files come out as `worker.test.sh` alone in one shard, predicted
539 s beside the bash shards' longest of 539 s, and the other three at 278,
128 and 89 s. `tests/failfirst.test.sh` pins this. The rule is not a bound.
A change heavy enough that one shard's doubled load, spread over the pool,
outweighs the heaviest bash shard is predicted over it. The shard then says
`predicted OVER it` in its log rather than hiding it.

The autopilot retains child output in durable job receipts, and `fm-gate.sh`
writes its own head-bound report under `state/gates/<task-id>-<sha>.txt`.
A missing report remains unknown; a receipt alone never proves green gates. The path
and the `  + gate N (name): …` / `  x gate N (name): …` lines of `fm-gate.sh`'s own `say()`
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
| Header | brand, the engine badge, green-light state, the theme toggle and the language switch |
| Sea header | merged / in flight / waiting on you / blocked / ready / backlog; waiting on you is the number of pending decisions |
| Decisions tab | pending records first: the captain's portrait beside the first full card, further decisions as one-line strips that expand in place; each card and strip starts with a coloured kind badge (T-227) |
| Voyage | the 2.5D stage (T-125) is the only ship view; crew, captain, handoffs and merge salvos live there |
| Summary bar | crew button with aboard count, and log button with the latest event; each opens a modal sheet |
| Fleet tab | seven columns left to right: backlog, ready, work, gate, review, captain, merged; closed tasks, and every merged task, in the separate initially collapsed history; below the lanes, the initially collapsed parked group and the drop target |
| Log sheet | tri-lingual summaries from `events.jsonl`, with a Load older control and client pages of 12 lines |

**Shell themes and stage (T-241).** `board.css`, loaded after the inline style,
provides one token system. `board.js` sets `html[data-theme]` from `board.theme`
in localStorage, falling back to the system colour scheme. The top bar's 32px
half-circle icon toggles the theme and remembers it per viewer. Its title and
accessible label follow the language switch. Storage reads and writes for the
theme and language tolerate denied storage and keep working for the session.

| Token | Light | Dark |
|---|---|---|
| `--chart` | #EEF2F0 | #0E1824 |
| `--hull` | #FFFFFF | #16222F |
| `--hull2` | #F6F8F7 | #1C2A39 |
| `--harbour` | #10233B | #E6EDF1 |
| `--fog` | #5B6B7A | #93A3B1 |
| `--line` | #CBD5D2 | #26384A |
| `--signal` | #F2B90F | #F0B429 |
| `--flag-red` | #C2372C | #E35D4F |
| `--flag-blue` | #1D4F91 | #6EA8E8 |
| `--kelp` | #2F7D5B | #4FB286 |

The existing background variables map to chart/hull/hull2; foreground maps to
harbour, muted foreground to fog, and brass/ok/bad/accent to
signal/kelp/flag-red/flag-blue. Light text accents override brass #7A5600,
warn #8A4B00, wait #6B2FA0, ok #1E6B47, bad #B3261E and accent #1D4F91
for at least 4.5:1 contrast on all three light surfaces. A light-only rule set
covers literal roster and count text colours. Kind badges, pressed buttons,
the portrait gradient and the gold action gradient keep their original colours;
the portrait label keeps its original brass ink. `ship.css` stays unchanged.
Type tokens are 13/15/17/21/26/33/41px, spacing is 4/8/12/16/24/32/48px,
and chip/panel radii are 4/8px. The shell adds no shadows.

The voyage stays above the cards at every width. Its expanded stage is
`clamp(270px, 36vh, 440px)` above 650px and 270px below. An icon in its bar
shrinks it to 88px (72px at widths up to 650px). With no stored choice the
stage follows the viewport live: strip on narrow screens, expanded on wide
screens. Pressing the control stores `board.voyage.size` as `strip` or
`full-size` and ends automatic switching. The narrow default panel, including
margins, is at most 160px tall so the first card starts within an 844px viewport.
The size control is hidden in full and hidden modes. Full mode always fills
the screen and restores the panel size on exit; existing mode/hidden keys,
drawer homes and Escape handling stay intact. Reduced motion disables the
size transition. The captain cards retain their T-245 layout.

**Tabs and sheets (T-246).** Below the pinned voyage, `#tabs` is a tablist
with Decisions and Fleet at the same level. Decisions holds `#deckwrap` and
`#capstage`; Fleet holds the full-width `.lanes-wrap`, including parked cards,
the drop target and confirmation, and history. Decisions shows the pending
count when positive. On load, any pending card selects Decisions; otherwise
`board.tab` restores the viewer's choice, defaulting to Decisions. Storage
failures leave session navigation working. The game keeps its region homes
inside these panels when moving workflow regions into and out of its drawer.

`#secbar` holds the crew button and aboard count plus the log button and latest
event. Crew and log start closed and open as modal dialogs, with titled headers,
close buttons and Escape dismissal; focus returns to the opener. Opening a
sheet or switching tabs first closes Fleet detail. A sheet takes Escape before
a decision details sheet, and prevents the voyage's double-Escape gesture.
Roster rows and log lines do not open task details. Below 760px the tabs and
the summary bar share one compact row, so the first decision card stays in
the phone's first screen; the latest event shortens to fit that row.

Both sheets are 96vw wide, capped at 1480px; the log is 80vh tall. Below 760px
they fill the width. The crew sheet uses 15px text and uncapped row heights,
with readable names, tasks and columns; a project chip stays on one line
and its column is as wide as the chip; below 760px each member is a stacked
block without horizontal scrolling. Opening crew sets `SHIP.rosterOn` true;
legacy `board.roster=hidden` no longer hides its rows, and the board never
writes that key. Sort and grouping preferences remain unchanged.

History retains its closed default and its open state across renders. Its
client pages show 12 cards, parked pages show 6, and log pages show 12 across
the live and loaded older lists. Each pager has first, previous, next and a
position label. Load older still appends events with the existing cursor API;
paging changes display only.

**Engine badge (V7).** The server reads `config.yaml` on every state request —
the top-level `vendor`, and `reviewer.vendor` when that block exists — and the
header shows the top-level vendor resolved as the launcher would, marked
`vendor ⇄ reviewer-vendor` when the resolved names differ. A rule such as
`opposite-of-host` resolves from the recorded host and appears in the tooltip.
Crew vendor and model always come from the run's identity, in the board and
in the voyage. Names are never hard-coded; no file or no top-level vendor is
no badge.

**Lanes and cards.** Clicking a card, or pressing Enter/Space on it, opens one
task detail panel (T-230); another card replaces it. Close or Esc returns focus
to its card. Menu buttons, PR links and dragging do not open the panel. It is a
sibling of `#lanes`, outside the patched tree, and stays open through state
updates. At 760px and above, Fleet places the list on the left and `#taskDetail`
on the right without an overlay, and its close control keeps the name "Close
task detail". Below 760px detail replaces the list, and the same control is a
visible Back, named Back, that restores the list's scroll position; its name
follows the width while detail is open. Escape closes detail only
when no crew or log sheet is open. Ready and finished tasks, including history cards, use the same panel.

The panel reads GET `/api/task?project=<name>&id=<T-or-SK-id>&lang=<locale>`.
An absent or empty project selects the default, including a nameless self
installation; unknown project/task is JSON 404 and non-GET is 405. The read is
open like `/api/state`. It joins that project's spec, pending and answered
cards (not withdrawn archives), planned unique `test/` and `tests/` paths from
acceptance then scope, readiness and round metadata. Evidence comes only through
`fm_evidence.py summary`, which verifies `Store.records()` before projecting
metadata and the latest brief's first line. No report/verdict body, readiness
`review`, session data or credentials enter the response. A failed evidence read
leaves readiness/brief null and event-only rounds with null heads, plus a bounded
error note. The evidence namespace is the project name, default name, or `self`.
Push events never supply a head: worker-report and verdict evidence do.

The detail header shows lane, identity, project, PR, checks and the chosen
source's stored STE status. It then uses `intentBody` in its existing order:
intent, how, alignment, scope, notes; followed by Spec, Tests with readiness,
and Progress with round actors/vendors/heads/verdicts, card choices and No-texts,
and the brief headline. The newest dispatch/repin/merge card with details wins;
otherwise the spec explain supplies the explanation. Legacy sources without a
report show no STE badge; absent explanations and records have explicit empty
notes. The diagram appears only when its locale file exists. Acceptance lines
clamp to two lines and their expansion keys survive updates and locale changes.
The open project/task key lives in page state; only changes to stage, PR,
last review, crew or badges trigger another task read. Browser tests verify
interaction, focus, redraw persistence and the 390px viewport; bash tests supply
the fail-first proof for the endpoint, validators, projections and diagrams.

**State cost.** A steady `/api/state` build targets less than 500 ms at the
current live data size. Four process-local caches check the registry once per
request, reuse committed wake acknowledgements until their inputs change,
refresh changed task lists asynchronously through the canonical `fm_tasks`
reader after the first read, and parse event-log appends incrementally (with a
4096-byte prefix check and full replay on replacement). HTTP requests and open
streams share one build per project filter when the complete input stamp and
write generation match and the result is less than 1000 ms old. Directory
stamps include the files read beneath them, including pin subdirectories;
storage validation still runs on every request, and watch liveness is always
read afresh. No cache writes stored state. `FM_BOARD_COLD=1` disables these
optimizations at startup. `FM_BOARD_BUDGET_MS` defaults to 1000; slower builds
log `fm-board: /api/state build N ms (events A ms, tasks B ms, watch C ms, rest D ms)`
once per 60 seconds, including in cold mode. The `fm_lifeline.py acknowledged`
CLI retains its JSON output but exits 75 when the nonblocking acknowledgement
lock is busy, so that unknown snapshot is never cached; library callers keep
their existing conservative result. The reader resolves the record root once
per call.

**State windows and log pages (T-243).** After replay, counts, derived values
and project filtering, `/api/state` keeps every response with a running or
unknown merge, every failed merge even when superseded, and every failed effect
not yet superseded, plus the newest 50 other answered records. Responses are
emitted in `(ts, id)` order. Outcomes keep every `merged` entry and the newest
200 `decision_made` entries, preserving their existing output order. A
response-derived outcome uses its decision record's own `ts`. Both windows
compare `Date.parse(ts)` milliseconds, missing or invalid timestamps before all
dated entries, with plain-string ties by response id or outcome identity.
`windows: {responses: {shown, total}, outcomes: {shown, total}}` reports returned
lengths and totals before windowing. PR link maps are built from the returned
lists; state memoization and SSE use this windowed value. Tasks, counts, pending,
crew, watch, projects and all handoffs remain unchanged. The voyage reads no
responses or decision outcomes; its full handoffs and merged outcomes remain
available. No stored record or log changes, and task detail stays complete.
External clients that consumed full responses or decision outcomes now receive
these windows and their totals.

`GET /api/events?before=<cursor>&limit=<n>[&project=]` is an open read like
`/api/state`. It returns `{events, next, pr_urls_by_project}` in the live log's
shape, newest first, with the same project filter and lost-run folding. Limit
defaults to 40 and is clamped to 1–200. Without a cursor its default page equals
`recent`; before a cursor it returns events preceding that event. `next` is the
oldest returned event's cursor, or null when nothing is older. Both `recent`
and paged events carry a cursor `<store>:<index>:<sha>`: the first 12 hex digits
of SHA-256 of the absolute store directory, the zero-based parsed event index
within that store (invalid JSON lines skipped), and the first 12 hex digits
of SHA-256 of its raw line without newline. Neither paths nor project names
appear in cursors. Appending to any store leaves older cursors stable. A
missing store or malformed cursor returns 400 `badCursor`; a store no longer
holding the same raw line hash at that index returns 409 `staleCursor`. The
page link map scans all mentions per project, including PRs named only in old
summary text.

The log keeps `#log` inside `.logwrap` as the live newest-40 list. Load older
captures its oldest cursor as the anchor, appends pages to a separate older
list, and merges page link maps for rendering through `said()`. Further clicks
use the oldest older event. The button hides at the end. When the anchor leaves
`recent`, older rows clear and the button returns; pending fetches for that
anchor are discarded. Bad/stale cursors clear older rows; other failures show
`logLoadFailed` while preserving rows for retry. Locale keys include
`logLoadOlder`, `logLoadFailed`, `badCursor` and `staleCursor` in both dictionaries.
On the unfiltered board, stores remain joined in `stores()` order, as in
`recent`: an event appended to an earlier store after paging past its boundary
is not shown in older rows until they are cleared and loaded again.

The lane order is sent by the server (`lanes`) so the page
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
and a pending decision with the number of options it actually lists. A task's
title comes first from its `design/tasks/` definition, then its newest numeric
dispatch pin, then its skill-update proposal, then the earliest
`decision_requested` English summary (first line, dispatch and task-id prefixes
removed, at most 200 characters plus an ellipsis), else the explicit missing-title
label. Titles are read from the task's own project state. The board is a local
page on `127.0.0.1` for the captain alone: its one main page shows and answers
every registered project's records in full, including external titles and
bilingual decision details. `?project=` is an optional filter only. Each card's
design link uses its project's `design_docs` entry when the document exists;
`designDoc` and `designPath` remain for compatibility.
`title_tw` carries the Chinese summary when the title came from a decision,
and is null for the other sources; the page converts it for zh-CN. The merged
lane shows the latest few merges, newest first, and counts the rest into the
history.

**Park and drop (T-058, T-118).** The captain takes work they do not want run
off the lanes on the board itself. Each unfinished card listed in the plan
offers two actions, reachable both by dragging the card and by the `⋯` menu
on it (the menu is also the keyboard path):

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
card offers (`actions`). Since T-118 the captain can set aside any unfinished
task listed in the plan: `park`/`drop` in every lane but merged and closed
(backlog, ready, work, gate, review and the captain's), `unpark`/`drop` for
parked, and only `reopen` (below) for merged and closed. A task the log knows but the plan does
not list offers only `drop` (no park) in an active lane, `unpark` and `drop`
if parked (for example by a card effect), and `reopen` once final, so the
captain can clear stale definition-less work through the same confirmed path.
A task with crew aboard or a pull request open (`confirm: true` on the card)
is set aside only once the captain has confirmed it in the page: the confirming
step says whose crew is
stopped and that the pull request stays open, and the server refuses the
request without `confirm: true` (409, `code: confirmRequired`); a reopening
with no usable reason is 400, `code: reopenNeedsReason`. Every refusal code
the server sends has its own text in both dictionaries, and the page shows a
refused action by that text, falling back to the generic line only for a
code it does not know. Setting it
aside writes the event and then stops its crew through fm's one stop path,
`bin/fm-herdr.py stop --task` (T-144; `bin/fm.sh stop --task <id>` runs the
same): SIGTERM to the round's own script, whose pid `bin/fm-worker.sh`
publishes at `state/worktrees/<task>.pid` and whose TERM trap saves and
pushes the worktree; each round's own process group, by its `runner.pid`,
TERM then KILL after a grace; SIGTERM to the script each run of the task
names in its `process.json`; and, for a round from before T-144 with no
runner, to the vendor CLI its `execution.json` names - each only while `ps`
still shows the program it was recorded for. The pull request is
never closed: nothing closes it without the captain. An action the card does
not offer is refused with 409 and nothing is emitted; an unknown task is 404,
an unknown action 400, and a request without the captain's credential, the
board's own `Origin` or a body declared `application/json` 403, before
anything else is read (the trust boundary, below). The board never edits
`design/tasks/`: a
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

**Lane derivation (T-118).** Every card sits where its task really is. The
server derives each task's lane from the log and the pending cards on disk,
and nothing else. The events that give a lane:

| Event | Lane it gives |
|---|---|
| `dispatched`, `commit_pushed` | working |
| `pr_opened`, `gate_passed`, `review_opened`, `approved` | review |
| `gate_failed`, `review_failed`, `worker_crashed` | gate (blocked) |
| `agent_lost` | gate (blocked), unless the task was given a lane since the lost actor last spoke; a spec preflight loss only removes its crewman |
| `merged` | merged (final) |
| `closed` (a drop) | closed (final) |
| `parked` / `unparked` | the parked group, until unparked / the lane the other events give |
| `reopened` (captain only, with a reason) | none: it clears merged or closed, and later events place the task |

Every other event - `decision_requested`, `decision_made`, `greenlit`,
`ask_pass_criteria`, `criteria_returned`, `protocol_violation`,
`vendor_unavailable`, `agent_finished`, `crew_status`, `spec_pinned`,
`spec_repinned` - gives no lane. In particular no event gives the captain's
lane. `decision_requested` and `approved` once did, and nothing took it away
again, so an answered card left its task there until something else moved it
(T-030, T-060, T-064). `decision_requested` is out of `STAGE`, and an
approval waits in review for firstmate's merge card. A task no event has
moved is untouched: backlog or ready by its dependencies, as above.

Precedence, highest first:

1. **Reopened.** The captain's `reopened` (below) is folded in where it
   stands in the log, and is the only event that moves a task out of merged
   or closed. The task then starts again from nothing: its later events
   place it, and with none it is untouched.
2. **Final.** A merged or closed task stays there; nothing said afterwards -
   a late review round, a sync, a pending card - moves it. A pending card on
   a final task is shown, with a note that the task is final (below).
3. **Pending card.** The captain's lane means a pending card and nothing
   else: while a card for the task is pending in `state/pending/` (the
   `awaiting` set), the task is there, whatever the log says after it; once
   the card is answered or withdrawn it is where the rest says. A readiness
   card that is the task's only card leaves it in ready (T-059).
4. **Park.** The last of `parked` / `unparked` wins, for any unfinished task.
   A task parked while its card is pending stays in the captain's lane, by
   rule 3: its crew is stopped at once, the card carries a `parked` badge,
   and it offers what a parked task offers (`unpark`, `drop`), never a
   second park. The confirming step in that lane says so
   (`parkConfirmCaptain`) rather than promising the task leaves the lanes.
   Once the card is answered or withdrawn, the park places it.
5. **Liveness.** A crewman's `agent_lost` (below) blocks its task, with a
   `lost` badge naming the actor, unless the task was given a lane after the
   crewman last spoke - a redispatch, another round's review. A spec preflight
   loss only removes its crewman, with no task lane change or lost badge.
6. **The log.** Otherwise the lane of the task's last lane-giving event.

**Crew liveness (T-118).** A crewman is aboard only while its run is alive,
and the launcher side, never the model and never the board, says when it is
not. There is no heartbeat. `bin/fm-herdr.py`'s deck reconcile, which
`fm-session.sh start` and `status` already run (below, managed session
defaults), checks each aboard actor against its recorded process -
`process.json`'s pid and token, or a live attempt lock. A run whose process is
gone and that never said `agent_finished` gets one `agent_lost` under that
exact actor through `bin/fm-emit.sh`, in English and Traditional Chinese,
followed by the `agent_finished` (`data.status: process_gone`) that has always
closed a ghost. The board takes the run off the deck at `agent_lost`, shows
the loss once in the log and not the close after it, and blocks the task by
the rule above. An `agent_finished` arriving after the loss changes nothing:
the run is already off the deck and the task is where its events put it. A
loss already written is not written again. A `dispatched` brings the actor
back aboard, as it always has. A spec preflight's loss only removes the
crewman: none of that actor's events changes a task's stage or lost-round mark.

**Card effects (T-118).** An answer does what its option says, carried out
by the one script that owns the effect, and the outcome is recorded on the
`decision_made` event (`data.effect`, `data.outcome`, `data.reason`) and on
the decision record (`effect`, `effect_outcome`, `effect_reason`): `done`,
`failed` with the reason, `running` for a merge until its helper exits, or
`recorded` for an option with no effect. A card names its effects in
`details.effect`, a map from option to effect, which `bin/fm-decide.sh`
refuses unless every key is an option the card offers and every value is one
of these:

| Effect | Carried out by | Result |
|---|---|---|
| `merge` | `bin/fm-merge.sh`, in the background (merge cards only) | `merged`; the record says merged or failed |
| `hold` | nothing | done: the task stays where its events put it |
| `park` | `bin/fm-emit.sh` `parked`, then the crew stopped | the parked group |
| `drop` | `bin/fm-emit.sh` `closed`, then the crew stopped | closed |
| `dispatch` | `bin/fm-dispatch.sh --task <id>`, the captain's order | working once the worker starts; failed with the dispatcher's reason when it holds the task |
| `send_back` | `bin/fm-worker.sh --task <id> --pr <n>`, owned by the session (T-151) | another round on the same pull request; failed with the worker's words when its lock refuses |

The card kinds and their effects: a **merge card** (`--kind merge`) that
names none merges on A and holds on B and C, as it always has; sending work
back starts a worker, so only a card that says so does it. An **untracked
merge card** (`--kind merge-untracked`, T-119) is read the same way, and its
merge hands `fm-merge.sh` `--untracked` and no task; it has no task to park,
drop, dispatch or send back, so any of those fails with that reason. A
**readiness card** (T-059) names `{"A":"dispatch","C":"park","D":"drop"}`;
its B, rescope, has no effect and is recorded. A **choice card** has only
the effects it names. A **skill-update card** (`D-SK-<at least three digits>`) supplies
bilingual proposal details and A (adopt), B (leave), C (revise) tradeoffs.
Missing proposal text is explicitly disclosed. Legacy title-only callers
remain supported. The generated choice card names no automatic effects and
only records the answer. A skill merge card merges on A and holds on B and C
like any merge card. For revision, the captain names what to change; firstmate
revises the proposal and raises it again for a new decision. Shell consumers
(`fm-decide.sh`, `fm-ready.sh`, `fm-diagram.sh`) use `fm_decision_id` in
`bin/fm-emit.sh`, beside `FM_OWNED_ID`, without depending on the optional
config reader; the board retains
its TypeScript twin. A custom answer never has an effect. An effect that failed stays on the board
with its reason until what it asked for has happened some other way, and is
never shown as done.

**Reopening a wrong final state (T-118).** Preventing a merge card from
merging under the wrong task is T-119's; this is the way back when it has
happened. `reopened` is the captain's event, with a `data.reason`, and the
board honours it only from the captain and only with a reason; the log takes
it from anyone, like every type. It is the only event that moves a task out of
merged or closed, and the task then starts again from nothing: its later
events place it, and with none it is untouched, in ready or backlog by its
dependencies, showing the pull request it opened itself rather than the one a
wrong card merged. The board offers it as `reopen` on merged and closed
cards, behind a confirming step that takes the reason. A pending card whose
task is merged or closed is never hidden: it is listed with `task_final`, and
the card says the task is already final, so a card raised under the wrong
task - the merge card for #96 filed under T-117 on 2026-09-26 - stays where
the captain can see it. A card for a pull request that has merged is still
withdrawn from the deck.

**The standing reconcile reads the captain's words too (T-118).**
`bin/fm-reconcile.sh`, which revives a worker whose pid is gone, reads a park
and a reopening as the board does. Setting a task aside stops its worker with
SIGTERM, and `fm-worker.sh` keeps its pid file on any exit but 0, so the next
reconcile finds a dead pid on a parked task: it retires the pid file, keeps
the worktree, and neither records a crash nor revives the task until an
`unparked`. A task the captain reopened, with a reason, is not over: a dead
worker on it is a crash and is revived, on the pull request the task opened
itself. A `reopened` that is not the captain's, or has no reason, changes
nothing. `bin/fm-autopilot.sh`, `bin/fm-dispatch.sh` and `bin/fm-ready.sh` keep
their own readings and are not changed by this task.

**The one-time card repair (T-118).** There is no standing sweep: the rules
above make the old inconsistencies impossible, and `fm-autopilot.sh` already
brings GitHub's state in. What the old board left in the log is repaired once,
by `bin/fm-reconcile.sh --repair-cards`, a dry run unless given `--apply`,
which writes only through `bin/fm-emit.sh`. It reads the log and the records
beside it and fixes two things, one line each in English and Traditional
Chinese:

- an answered card whose chosen park or drop never happened (T-030, T-060,
  T-064): it writes the `parked` or `closed` the answer asked for, as the
  captain whose answer it was, naming the card. What an option did is read
  from the decision record's `effect`, from a readiness card's record under
  `state/ready/` (C park, D drop), or from `--effect D-id=park|drop` for a
  hand-raised card whose options the log never kept; an answer whose meaning
  none of these gives is not guessed at. An answer the task has moved on
  from since - dispatched, answered again, set aside another way - or whose
  task is already final is listed and left alone.
- a task marked merged by a pull request other than the one it opened
  (T-117, merged by the card for #96 while its own #97 was open): it writes
  the captain's `reopened`, with the reason.

**Roster.** Each row carries the crew name, role, project, vendor, model,
CLI version, round and attempt, state and pull request, with the task id,
title and authored activity. A bar appears only for bounded `{done,total}`
progress; no percentage is shown. The summary bar shows the crew count against
the server's deck limit and opens the crew sheet. It starts closed, ignores
legacy `board.roster` visibility, and never writes that key; there are no AHOY
or order demonstrations.

### The ship

The board draws no ship. The 2.5D voyage is its only ship view, with its own
crew, human captain, handoffs and merge salvos. Closing the voyage leaves no
ship, salute or audio. The board retains the crew roster and decision deck.

### The crew

**Spec preflight visibility (T-191).** A preflight boards as a reviewer in
phase `review`, using neutral `crew_status` events with `mode: spec-preflight`.
Its first event carries its recorded name, vendor and requested model; each
vendor attempt refreshes these through the chain's prepare callback. Every
payload reads the run's identity afresh. The roster and task
card crew chip show `spec preflight` (`預檢`, derived `预检`) in place of the
round and attempt; round sorting treats it as no round (-1). Aggregation keeps
`mode`. The crewman carries its task id as text even when that task has no card.

An actor is a preflight if any event carries that mode, never because its name
contains `-sp-`. Preflight events create no task card, move no task stage and
cause no lost-round badge. The board's handoff `peer()` excludes them; voyage
marks them as preflights and its reviewer lookup excludes them from review
scrolls and approval rituals while still showing their lookout action.

`agent_finished` removes the crewman on every exit after identity allocation.
The matching actor/spec-SHA evidence gives `preflight_outcome: spec-ok` or
`spec-gaps`, both with `result: ok`. Without that receipt, signal exits are
`interrupted`, exits before the vendor chain starts are `refused`, and other
exits are `failed`, all with `result: failed`. No `review_opened` is emitted:
review counters, gate 6 and a task's first real review round remain unchanged.
The watch counts a live preflight as in-flight crew until its closing event.

Crew figures and their animations belong only to the voyage. The board's
roster carries every crew fact formerly shown in deck detail cards, including
the CLI version and the no-window explanation while `waiting_ci`. Unknown
fields say unknown. Firstmate without a host record has no vendor, model or
CLI cells. Known roles have distinct marks; an unknown role has a warning mark.

**The roster shows separate columns** under one header. The project column
appears with one project as with several, using `SHIP.projectColor` consistently
with card project chips; only a multi-project board adds the project-chip frame
and title. A card header stays one line high: the task id never wraps or
shrinks, and the project chip is a one-line pill that truncates, or moves to
its own line in a narrow card. Header buttons sort the sortable columns; CLI
is a non-sortable header. A toggle groups rows by project. Both choices survive reload through
`board.rosterSort` and `board.rosterGroup`. Below 760px the same labelled cells
stack in one readable block per member without horizontal scrolling. Task cards keep their separate name, role and round
chips. There are no deck tags, detail cards, hover, tap or figure-drag controls.

**What the round actually ran on, read from the run itself, never guessed
(T-127).** `vendor` is the adapter; `model` is what the vendor's own CLI
reported it used, read from its transcript, section 5.3 below; `model_requested`
is what `config.yaml` asked for; `cli_version` is the CLI's own version
string. All four ride the crew payload's `identity` (section 11) beside
`name`, `project`, `round` and `attempt`, and always unknown for a run
recorded before T-127. `vendor` and `model_requested` are known from the
round's start (T-146); `model` and `cli_version` once the round has run, and
until then the crewman's `model` is its `model_requested`, with
`model_source` saying which it is (`reported` or `requested`).

**The board keeps the last known value of each field (T-146).** It reads a
crewman's identity from its events, and on 2026-09-29 every crewman's
vendor, model and CLI were blank: the latest event, a `crew_status`, carried
only the six T-116 fields, and replaced the identity that had them. Now every
crew event a round emits carries all eleven, read fresh from `identity.json`
(`fm_crew_identity`, and `IDENTITY_FIELDS` in `bin/fm-herdr.py` for a Herdr
round's `crew_status`), and the board merges field by field under two rules.
Within one vendor, an event that lacks a field, or says `unknown`, keeps the
value an earlier event gave. An event that names another vendor - a fallback
starting, whose `record_requested` clears what the vendor before reported, or
`record-model`'s `unknown` when every vendor was unavailable - resets
`model`, `model_requested`, `cli_version` and `model_mismatch` to what that
event says, null or empty meaning cleared, so one vendor is never shown with
another vendor's model, requested model, CLI version or mismatch. A vendor
of `unknown` is sent to the page as null, shown as unknown, and not counted
by the engine badge. A new `dispatched` still starts a crewman afresh.
When `model` differs from `model_requested`, `model_mismatch` is `true` and
the roster's Model field carries the warning colour, with both
names in the text (`modelMismatch`, en and zh-TW).

**The header's engine badge shows the vendors actually running now**, such as
"claude ×2 · cursor-agent ×1" - counted from the crew aboard, whichever
project, read at request time from the crew list the way the fields above are
- and falls back to `config.yaml`'s configured default (as it did before
T-127) only when no crew is aboard whose vendor is known.

The new labels (`roleWorker`, `roleReviewer`, `crewName`, `crewRole`,
`crewTask`, `crewRound`, `crewAttempt`, `crewPr`, `crewState`,
`crewActivity`, `crewUnknown`, `rosterSort`, `rosterGroup`,
`crewVendor`, `crewModel`, `crewCli`, `modelMismatch`, `engineLive`) come
from the board's dictionaries in English and 繁體中文, like every other label.

### The captain

The human captain belongs to the 2.5D voyage and is excluded from agent
counts. While a decision is pending, his portrait sits beside the first card
(D-047). It is a picture of that same captain, using `/voyage2d/captain.webp`
from the Live build, and disappears with the last card. The board commits no
second copy of the art. Without a Live build it renders only the localized
label and requests no voyage asset; a failed image load also leaves the label.

`#capstage[data-pose]` is the single portrait pose signal: idle is plain,
ready has a brass glow when a local choice is selected, and order adds a 6px
lift while an answer is posting and for 3.2 seconds after recorded, custom
recorded, effect-done or merge-running feedback. A change request or refused
merge/effect gives no order acknowledgement. Reduced motion removes the lift.
The label remains capDeciding, capReady or capOrder. Hiding the voyage hides
the portrait as before; its DOM and pose still follow board state.

Primary task, decision, tradeoff and event text is at least 16 CSS pixels;
secondary labels are at least 13 pixels and decision titles at least 20 pixels.
Choice and confirmation targets are at least 44 pixels high. Wrapped content
and flexible columns support 320-pixel screens and enlarged text. Completed
history uses a native keyboard-operable disclosure, with distinct merged and
closed counts. Its open state survives refresh and locale changes; new merges
do not open it. Pending decisions come from pending records, not task stages.

Crew payloads add `activity: {en, "zh-TW"}`, `crew_name`, the run's
`identity` (T-116, section 11) and optional bounded `progress` without
changing canonical actor IDs or roles. Replay retains each
actor's dispatch/activity description and last applicable lifecycle phase
across technical events, independently of the 40-event recent list. Localized
task activity takes precedence when available; scalar titles are not guessed
translations. Missing descriptions and unknown phases are explicitly labeled.
Finished actors cannot reappear through late technical events; a new dispatch
starts fresh activity. Producers lacking authored summaries need firstmate
coordination with the owning task, not fabricated board descriptions.

### Ahoy

The board plays no audio and draws no salute. The voyage owns handoffs,
merge salvos and their audio; closing it leaves no salute or sound. The board
keeps decision feedback, including the English order cry for accepted orders,
and the portrait's timed acknowledgement. The old `board.muted` preference is
harmless and unused; no stored records need migration.

### Interaction

Captain intent cards show the kind badge and header STE count, then Intent,
How it works, Scope and Notes. A done item prefixed `Intent N:` or `意圖 N：`
(or the ASCII colon) nests beneath visible intent N. Unprefixed items, missing
parents and parents hidden by the six-intent cap remain plain rows afterward.
The check glyph means listed, not satisfied. Done items retain their independent
six-row cap and Show more count. Alignment remains the list's accessible label.
Scope-in chips are solid; scope-out chips are outlined. How it works retains the
full-width diagram and adjacent before/after fallback; no change table is shown.
Explanation, why and outcome sit behind one Why you see this disclosure. Other
card kinds keep their explanation visible. Every sentence remains available,
without sentence STE chips on captain cards. Task details retain the Intent,
How it works, Alignment, Scope, Notes order and stored sentence chips.

The current card's slim decision bar sticks to the viewport bottom; expanded
strips keep their bars inline. The card reserves at least the bar's height below
its content. Option buttons, custom text, validation, refusal and confirm stay
in the bar. Decision details opens a dialog sheet with option pros/cons and
questions. Escape or Close details closes it and returns focus to the opener.
Disclosure state is keyed by decision id and survives state and locale changes;
focus inside an open sheet returns to the same control or its close button.
Bar and sheet use solid theme colours. Header STE counts still use stored
reports; server reports and task-detail chips are unchanged.

Each question offers “Yes, correct” and “No, change it”; No opens a bounded
correction field. Confirm remains disabled until every question has a valid
answer and an option or custom choice is selected. Draft answers survive card
refreshes and language switches, and locked/read-only cards disable all controls.
An answered card stays locked from the confirm click until it leaves the deck
and unlocks only on a refusal.
Any No records a spec-change request (§5.2), wakes firstmate, and shows only
“Change requested — firstmate revises the spec”. It carries out no option,
shows no order cry or authored outcome, and queues no order animation in any
tab or project view. All-Yes answers retain existing effects. Cards already
pending without intent fields keep their current rendering and answer behavior.

Hand-offs are drawn only by the voyage. The board has no handoff flights,
on-deck stations, receiving pulses or `handoffUnavailable` notice.

Full event replay still supplies directed `handoffs` with stable event
identities: dispatch or recorded order from firstmate to a worker, PR/review
handoff to a reviewer, approval to firstmate and rejection to the worker.
Peer resolution requires one known active participant on the same task and
names none otherwise. Each handoff retains `from_role` and `to_role`: firstmate,
the role recorded in `data.role` or at dispatch, or the canonical actor role
for legacy runs. These server payloads are unchanged and consumed by the
voyage; the board does not infer a role from an actor name.

**Hot reload:** a change under `board/public/**` pushes `reload` over SSE; a
change to `board/server.ts` restarts under `bun --watch` and the client
reconnects. Decisions are already on disk, so a restart loses none.

**`/open`:** `POST /open {path}` hands the file to the editor. Starting a
program is a write, so it takes the credential, the Origin and the JSON body
every write takes (below); a `GET /open`, which any link or image could make,
is 405 and starts nothing (T-122). Localhost only, and `realpath` must resolve
inside the repository or it is a 403. A read-only viewer (`/file`) covers the case where you would rather not
leave the board, and is available to a tab without the credential.

**The board's trust boundary (T-122).** Only the captain's browser, and
firstmate's own scripts on the operator's machine, change the board or start a
program through it. A crew round can reach the board's port, and so can any
web page open in the captain's browser; neither can write.

- *Why the OS sandbox cannot do this.* The macOS canary for T-117 (PR #97,
  2026-09-26) showed a crew round inside the sandbox fetching the live board:
  `curl --noproxy '*' http://127.0.0.1:4173/` answered 200. Measured with
  `sandbox-exec` on macOS 15.7.9: once a profile allows
  `(remote ip "localhost:*")`, a `(deny network-outbound (remote ip
  "localhost:4173"))` never takes effect, placed before it or after it, and
  neither does a `require-not` carve-out. Only a positive list of ports
  narrows loopback, and a round's own test servers need arbitrary loopback
  ports. So the board refuses the round itself.
- *Who may write.* Every route that changes state or starts a process -
  `POST /decisions`, `POST /tasks`, `POST /open`, `POST /drain`, and any writing route added
  later - requires, all three: an `Authorization: Bearer` holding either the
  captain's tab token or the secret itself; an `Origin` equal to the board's
  own (`http://127.0.0.1:<port>`, or `http://localhost:<port>`); and a body
  declared `application/json`. Anything missing or wrong is 403 with a `code`
  the page translates (`writeCredential`, `writeOrigin`, `writeJson`), and
  nothing is written, emitted, merged or spawned. The Origin refuses a page
  served by a crew round's test server, and the JSON rule refuses a form.
  `POST /drain` alone also requires the secret itself, never the tab token.
- *Why there is no cookie.* Browsers do not keep cookies apart by port: a
  cookie set by `127.0.0.1:4173` goes with every request the browser makes to
  any `127.0.0.1:<port>`, and `SameSite=Strict` does not help, because every
  loopback port is the same site. A crew round's dev server that the captain
  opens would receive the cookie in its request headers and could replay it
  with curl, sending any `Origin` it liked (`Origin` binds only browsers).
  So the board sets no cookie and reads none. The captain's tab holds a
  token in its `sessionStorage`, which belongs to one origin, port included,
  and one tab. No other server ever receives it, and the browser never sends
  it by itself: the page adds it as a header on each write.
- *The secret.* When the board starts it reads, or makes when missing, 256
  random bits as hex in `$XDG_CONFIG_HOME/firstmate/board-<port>.secret`
  (`~/.config/firstmate/board-<port>.secret` when `XDG_CONFIG_HOME` is not an
  absolute path), mode 0600, in a directory made 0700. It is outside the
  repository, `state/` and every temp directory, and the board refuses to
  start if the directory resolves inside its root. It is made once, through a
  link from a file written whole, and kept: a restart reuses it, so an open
  tab keeps working, and a new one is made only when the file is missing. It
  is never printed, logged, emitted, written under `state/`, or put in a URL
  that stays in history or in any response.
- *Revoking.* Every token and every bearer is derived from, or is, the
  secret. Deleting the secret file and restarting the board makes a new
  secret, and every token a tab holds and every copy of the old secret is
  refused from then on. The board has no other revocation, and a token
  otherwise lives as long as the secret does.
- *The one-time open.* `bin/fm.sh board` (and `fm-session.sh start`, through
  `bin/fm-herdr.py` `board_start`) sends the browser to `/login#<code>`, the
  code `<issued ms>.<nonce>.<HMAC-SHA256(secret, "login:<origin>:<issued>.<nonce>")>`.
  The board takes a code once, within 60 seconds of its issue, and never one
  issued before it started, so a restart cannot replay one.
  `FM_BOARD_CODE_TTL_MS` can shorten the 60 seconds, never lengthen them; it
  exists so a test sees expiry apart from the start-time rule. The page at
  `/login` posts the code (with its Origin, as JSON) and gets back, in the
  JSON body, the tab's token `HMAC-SHA256(secret, "session:<origin>")`. It
  replaces its address with the board's own, `/`, before it sends the code
  (T-145), so a reload while the code is on its way, or the reused tab's
  history, lands on the board and never sends a used code again; it keeps
  the token in `sessionStorage` (`board.token`), so the code stays in neither
  the address bar nor the history. A used, expired or wrong code is 403 and gives nothing. No
  response ever carries `Set-Cookie`. The token belongs to the tab: a
  reload, a navigation within the board and a board restart keep it, but a
  new tab or window is read-only until the board is opened through a new
  one-time address. This is by design (not `localStorage`, which every tab of
  the origin would share for ever). On macOS the address goes to `osascript` on
  stdin, never in an argument list, because `ps` shows every process's
  arguments to every other and a code read there could be redeemed first; the
  record in `state/session/board.json` holds the board's plain URL only. When
  no secret can be read or no program can open a browser, nothing is opened,
  the record carries `sign_in_error` (never the secret's path), and
  `bin/fm.sh board` says so in one `fm board:` line and exits non-zero, as
  it does when the board cannot start. On
  Linux `xdg-open` takes it as an argument, which `ps` can show for the moment
  it runs.
- *One tab (T-145).* On 2026-09-29 the captain twice could not merge from
  the board: the tab in use held no token (a fresh tab, a bookmark, or
  `localhost` instead of `127.0.0.1`) while the signed-in tab was elsewhere.
  So the opener (`board_open`, which `board_start` and the re-login route
  both run) first looks for a tab already on the board - its address, or any
  page under it, as `127.0.0.1` or `localhost`, on the board's port exactly -
  and sends that tab to the fresh `/login#<code>` and brings it and its window
  to the front, rather than opening another. On macOS it asks Chrome, Brave,
  Arc and Safari, by bundle id and only those already running (so none is
  started), each in an AppleScript of its own on `osascript`'s stdin; the
  running ones are found with the ids read at run time, since a literal id is
  resolved when the script compiles and one browser not installed would fail
  the whole question. A browser that cannot be scripted (not permitted, an
  error, or no answer within its timeout) is passed over. With no such tab,
  off macOS, or when nothing could be scripted, it opens a new tab as before.
  The record and `bin/fm.sh board`'s output say which: `tab` is `reused`
  (with `browser`) or `new`, and `said` puts it in words; neither holds the
  address. The opener is bounded by the limits around it. A code lives 60
  seconds, and the re-login route stops the opener after 60. So no code is
  minted before the search: each is made just before the one question that
  carries it, whether a browser's tab script or the new tab. Every question
  has its own timeout: 5 seconds for which browsers run, 8 for each
  browser's tabs, and 10 for the new tab. The search ends 35 seconds in
  (`OPENER_BUDGET` 45 less the new tab's 10), so the whole run ends within
  45 seconds. A code is at most one question's timeout old when a browser
  gets it. A first run held up on macOS's Automation prompt therefore falls
  back to a new tab with a fresh code, not an expired one.
- *Signing in again from the page (T-145).* `POST /relogin` makes the board
  run the same opener, `bin/fm-herdr.py board-login <port>` on its own port,
  so the one-time code goes from that script to the browser and nowhere else:
  the route answers only `ok`, `opened`, `tab`, `browser` (one of the four
  names) and a fixed `reason`, reads the script's output and prints none of
  it, and drops its stderr. It takes no credential - asking for one is its
  point - and keeps T-122's other rules: the board's own `Origin` (403
  `writeOrigin`) and a body declared JSON (403 `writeJson`) that parses to an
  object (400). It is rate-limited in the board's memory: one sign-in in any
  10 seconds, and while one is running (429 `reloginTooSoon`, with
  `Retry-After`), and no more than 12 in any hour (429 `reloginHourly`); a
  refused request is not counted, and the credential lifts neither limit.
  `FM_BOARD_RELOGIN_GAP_MS` can shorten the 10 seconds, never lengthen them, so
  a test reaches the hourly cap; nothing changes the cap. The opener runs
  under T-151's keeper (`bin/lib/fm_lifeline.py keep`), with the board as its
  owner and in a process group of its own. The route stops it after 60
  seconds, which `FM_BOARD_RELOGIN_TIMEOUT_MS` can shorten, never lengthen.
  That stop, or the board's own end, takes every `osascript` or desktop
  opener it started with it. An opener that did not open, or was stopped,
  is 502 `reloginFailed`. At worst a caller that forges the Origin
  (curl on the operator's machine; a crew round cannot reach loopback) makes
  the captain's browser show the board's sign-in: the code never reaches the
  caller.
- *Scripts.* A script on the operator's machine reads the secret file and
  sends it as `Authorization: Bearer`, with the board's Origin and a JSON
  body, keeping the secret out of every argument list: for curl,
  `-H @<(printf 'Authorization: Bearer %s\n' "$(cat <file>)")`.
- *What stays readable.* `/`, the page's files, `/api/state`, `/api/i18n`,
  `/events`, `/file` and `/api/session` (whether this request may
  write: a yes or a no) answer anyone on the machine, as before. None carries
  the secret, a token or a code. `/file` reads only
  paths that resolve inside the repository, and the page's files are served
  only when their real path is inside `board/public/`, so a symlink to the
  secret is refused.
- *A tab without the credential.* The page asks `/api/session` when it loads
  and after the stream reconnects, sending its token if it holds one. Without
  one, or after a write is refused for want of it, it shows a banner, in
  `en` and `zh-TW`, naming why (T-145): this tab holds no sign-in; or it was
  opened as `localhost`, whose storage is not `127.0.0.1`'s, with a link to
  the same page at `http://127.0.0.1:<port>`. The banner's button, "Sign in
  again", posts `/relogin` and says what the board did (the board's tab
  reused, a new one opened, too soon, the hourly cap, or failed), then waits
  out the 10 seconds before it can be pressed again. Every write control is
  visibly disabled with the reason as its tooltip: each option, the custom
  answer and its text, the confirm button, and each card's action menu,
  shown greyed rather than removed; no card can be dragged to park or drop.
  Opening a file falls back to the read-only viewer.
- *Crew rounds cannot read the secret* only while the OS sandbox denies reads
  of the home directory outside named toolchain and auth paths. On `main` that
  sandbox (T-105) was reverted and T-117 has not merged, so today a crew
  round running as the operator can read `~/.config`: the credential keeps
  other web pages out now, and keeps crew rounds out once T-117 lands and
  names this path in its never-readable list.

The production board is **rewritten** from the prototype in
`design/proposals/`, not promoted from it: that prototype was written with no
tests and no error handling.

### T-125: Live voyage seam

The flat 2D ship was removed in T-215; this is the board's only ship view.

The v2d-15 2.5D stage is a panel above v1's workflow, or the same iframe enlarged
with the existing workflow DOM in a drawer. F toggles size; Esc returns to the
panel. Mode uses sessionStorage. A double Esc within 400 ms, including from the
iframe, removes the iframe entirely. The browser-wide hidden preference uses
localStorage. No stage animation or audio survives that document's removal.

`BoardSource` consumes the host's existing `/api/state` and `/events` snapshots
through a same-origin subscription. It does not open a second subscription or
fetch an unfiltered project. Project keys identify tasks; real crew drive the
ship. The adapter derives review streaks from every project's event/handoff
records; external handoff identities retain the original event like self ones. The
recent-event window may have gaps, so task snapshots reconcile parked/final
states. Approvals alone unlock Live victory; simulated ticks cannot approve,
dispatch or merge real work. Playground staging hooks and mini-games are absent
from Live operation.

The drawer reuses the board's cards, named effects, task actions, confirmations
and translated refusals. Its writes remain `POST /decisions` and `POST /tasks`,
with the tab bearer token, browser Origin and the card's own project. Fight actions never write; the board
remains usable during a fight. An answerable board card for a gripped task
suppresses the shared monster’s fight prompt and target without releasing its arms. The Live-only adapter has the same narrow command seam;
it never interprets an option letter as an effect. Live bundles have no remote
fonts or other third-party requests. Playground builds refuse network code.

`tools/build.py --live` generates the gitignored `board/public/voyage2d/index.html`
and atomically writes `captain.webp` beside it from the baked front-facing whole
captain sprite. Playground builds write no portrait. A failed preparation removes
both files. The static route serves WebP as `image/webp`.
The existing static-file route serves it. CI builds Live before starting browser
workers or game tests, then builds Playground and runs the vendored node tests.
Session startup builds Live before starting the board; failure is reported and
removes stale output, so the board serves its workflow without loading the game
controller. E2e fixtures locate the built artifact or build in isolated scratch.
The panel sits above the decisions at every width, retaining its DOM home
below the top bar and above the counts. The frozen 3D application stays outside this integration;
any 3D follow-up requires its own approved scope.

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
- The preference lives in `localStorage`, and `?lang=` overrides it. Without
  either, `config.yaml`'s `language` (`en` or `zh-TW`, default `en`) applies.
  The configured language comes first in the language choices and authored
  decision details. The board also orders each pending card's translated
  details with that language first in its state response, preserving the
  other translations and metadata without rewriting the authored file.
  Firstmate reports to the captain in that language unless
  explicitly asked otherwise; both translations remain required on cards.
- `board.port` (default 4173) selects the board listener and `fm board`'s
  login address, credential file and tab reuse. `FM_PORT` overrides it;
  only a directly started server accepts `FM_PORT=0` for an ephemeral test
  port. Restart the server after changing settings.

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
that budget is this repository's declared `project.check_env`, and a fresh
worktree that runs the check - gate 4's fallback - runs the declared `setup` first, so it has the dependencies and
browser the end-to-end stage needs instead of skipping it. (The retired local whole-project gate ran the
whole check this way until T-114 retired it.) A functional
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

One job of the workflow is not a stage of `bin/ci.sh`: `fail-first` runs
`bin/fm-failfirst.sh` on a pull request's head against its base (§7, T-153),
with the history (`fetch-depth: 0`) to find the merge-base, and uploads its
report as the `fail-first-report` artifact. The `ci` job needs it with the
others; it alone may be `skipped`, and only on an event other than a pull
request, where there is no base to revert to.

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

No script and no suite feeds `grep -q` or `grep -c` through a pipe (T-103).
Under `pipefail`, `grep -q` leaving on its first match can kill the producer
with SIGPIPE, and the pipeline then reports a match as a miss; a loaded
runner loses that race where an idle laptop does not, which is how
adapter-contract's completeness loop failed on CI with a different signature
each run. The data goes in by here-string (or process substitution, where
`$(...)` would strip trailing lines the check is looking for). The hygiene
lint enforces it over every `*.sh` below `bin/` and `tests/`, and it catches
exactly the shapes listed here, no others. It reads
commands, not one spelling: comments off, continuation lines (a trailing `|`
or `\`) joined, a backslash-newline with nothing between as bash joins it,
`||` not a pipe, and every command a single `|` or `|&`
starts is judged, inside `$(...)` too. It is looking for `grep`, `egrep` or
`fgrep`, by path too, past `!`, `{`, `(`, leading assignments, and the
wrappers `env`, `nice`, `time`, `timeout`, `stdbuf`, `exec`, `command`,
`builtin` and `nohup` with their own options and those options' values
(`env -u NAME`, `nice -n 5`, `timeout -s KILL 5`, `stdbuf -o L`). It flags
`-q`/`-c` (a digit is an option too: `-2q`) or `--quiet`/`--silent`/`--count`
among grep's words, stepping over
the value of `-e`, `-f`, `-m`, `-A`, `-B`, `-C`, `-d`, `-D` and every long
option that takes one, and stopping at `--`. Options are read the way getopt
reads them, on the wrappers' side and on grep's: a cluster whose last letter
takes a value takes the next word (`env -iu NAME`, `timeout -vs KILL 5`), and
a long option may be any prefix that names one option (`grep --quie`,
`env --un NAME`); a prefix of more than one (`grep --co`, `grep --exc`) is
refused by grep and not flagged. Quotes and backslashes are transparent,
because an assertion
string is eval'd, so grep's words end at the first `|`, `;`, `&`, `)` or
backtick, quoted or not. A file that declares `# fm:lint-source` is skipped. Each of
these shapes has its own plant in `tests/ci.test.sh`, named by its line. Any
other spelling is not caught: in front of grep the reader steps over only the
words named above, and the first word it does not know ends its search. Such
a spelling relies on review.

The sweep that brought the suites under the lint (T-103) changed 27 sites in
11 files under `tests/`: adapter-contract 1, board 2, cleanup 1, decide 3,
dispatch 2, i18n 4, `lib.sh` 1, open 1, review 3, sync-prs 1, worker 8; and 1
in `bin/ci.sh` itself, which the lint skips by its marker. A here-string
appends a newline, so empty input becomes one empty line; every converted
site was checked for input that can be empty meeting a pattern that can
match an empty line. One changed its result, `tests/lib.sh`'s
`assert_matches`, and it reads `< <(printf '%s' "$1")` instead, with
`tests/lib.test.sh` proving `""` no longer matches `'^$'`. The rest are safe:
the `grep -c .` and `grep -q .` sites (`.` never matches an empty line), the
`-qx` sites (a non-empty literal), the fixed non-empty patterns
(adapter-contract, board, cleanup, decide, open, sync-prs, worker, and the
here-string loop in `tests/pipefail-grep.test.sh`), and i18n's two `'^$'`
checks, which use `< <(jq ...)` because `$(...)` would strip the trailing
empty lines they look for.

```
SWEPT:T-103 pipelines into grep -q / grep -c in the test suites
  searched: the round-1 regex, then the command-reading lint, over every *.sh
    below bin/ and tests/ (62 files; bin/ci.sh, bin/fm-config.sh and
    tests/pipefail-grep.test.sh skipped by their lint-source marker)
  found 27 in 11 files under tests/, fixed 27: adapter-contract 1, board 2,
    cleanup 1, decide 3, dispatch 2, i18n 4, lib.sh 1, open 1, review 3,
    sync-prs 1, worker 8; plus bin/ci.sh 1
SWEPT:T-103 converted sites where empty input meets a pattern matching an empty line
  searched: every <<< and < <( line the branch added under tests/ and in bin/ci.sh
  found 1 (tests/lib.sh assert_matches), fixed 1
SWEPT:T-103 option spellings getopt accepts that the lint's readers missed
  searched: each option reader in the lint (wrappers and grep) against
    clusters ending in a value letter, attached values and long-option prefixes
  found 2 (wrapper clusters like env -iu NAME; abbreviated long options on
    both sides like grep --quie), fixed 2, each planted in tests/ci.test.sh
SWEPT:T-103 statements in the lint's hazard(), lkind() and per-line rules
    that no plant pins
  searched: deleted each statement alone, by reading, and asked which plant
    in tests/ci.test.sh flips; the option tables are data, pinned by their
    value and quiet/count entries
  found 19. 9 now pinned by new plants: the single-quote, double-quote
    and backslash strips; the word cut (one plant per character); a
    wrapper's --; the first operand ending a wrapper's options; the
    wrapper long-option continue; the END flush; the joined line's printed
    text. 10 dead and removed: the =VALUE strip and both = checks,
    lkind's empty-name return and its "?" mapping, the j > ntok test,
    END's buf test, the trailing-backslash sub, the space the | join
    added, and the continue after grep's long options. Reading them also
    turned up 3 wrong reads, fixed and planted: the space the backslash
    join added (bash joins -\ and q into -q), a digit that was not a grep
    option (-2q), and a prefix of several options that all take a value
    (--exc), read as one where getopt_long refuses it
```

Each stage skips cleanly when its subject does not exist, so the gate is green
from an empty tree onward. **Every e2e uses the `mock` adapter** — no model
call, so it is fast, free and deterministic. Real vendors run in a nightly
smoke job.

`ci` is a required status check on `main`, and a branch must be up to date
before it can merge.

**GitHub Actions runs the same stages as separate, parallel jobs (T-134).**
On 2026-09-28 the one serial job on `main` took about 8 minutes of its
10-minute limit, and two pull requests were cancelled at the limit for
adding tests. `bin/ci.sh` gained two flags so a workflow job can ask for its
own slice of one gate run instead of all of it:

- `--stage fast|bash|bun|e2e` — run only that group of stages. `fast` is
  shellcheck, lint, hygiene, stdin, assertions and dag; the other three name
  themselves. With neither flag, every stage runs in one process, exactly
  as a plain `bin/ci.sh` always has — nothing above this paragraph describes
  a changed default.
  The three portability lints cover literal ampersands in pattern replacements,
  escaped JSON with commas in quoted command substitutions, and non-ASCII
  variable boundaries under `bin/`, `tests/` and `.githooks/`; the first two
  scan shell files, skip comments and files declaring `# fm:lint-source`, and
  allow a line immediately after `# fm:allow-portability: <reason>` with a
  non-empty reason, while the boundary lint scans all text without exemptions.
  `hygiene` includes the design-layout check (T-189): outside fenced code,
  every `###` heading in the last `## N.` section of design/design.md starts
  with `N.`, so new material nests under a numbered home instead of landing
  on the end of the file; a tree without design/design.md skips it silently.
- `--shard i/n` — inside `--stage bash` only, run the *i*-th of *n* shards of
  `tests/*.test.sh`. Assignment is longest-processing-time bin packing:
  suites are taken slowest-first and each goes to whichever shard is
  lightest so far, so the shards come out balanced rather than merely
  evenly counted, and every suite lands in exactly one shard (`i`, `n`
  themselves are validated the way `FM_CI_JOBS` is — a decimal `i/n` with
  `i` from 1 to `n`, or exit 64). Every suite's weight is in one unit,
  seconds (T-148). A suite `FM_CI_TIMINGS_IN` names (a "`path seconds`"
  line per suite, from a previous green run's artifact) takes that value,
  zero included: a suite recorded at 0 is fast, not unknown. A suite the
  file does not name — new, or the file absent — is estimated in seconds
  as its byte size times the median seconds-per-byte of the recorded
  suites; only when no suite is recorded at all is every weight its byte
  size, and then no two units meet in one sort. So a newly added suite
  still gets a duration and a deterministic shard, with no file to update
  by hand. On `main` 9e4194d the two units were mixed: timings were whole
  seconds, three ten-second suites were recorded as 0, read as unknown and
  weighed as their thousands of bytes, and took three shards alone while
  the other 31 suites ran on the fourth for 9m13s. Each shard prints one
  line, `ci: shard i/n: K suites, predicted Xs; mean Ys; longest suite
  <path> Zs`, so a shard's predicted load and a suite too long for any
  split (T-130's input) are readable from the job log. Longest-first
  packing keeps every shard within the longest single suite of the mean.

The bash stage records what each suite actually took, one "`path seconds`"
line per suite with millisecond resolution (`12.345`; bash 5's
`EPOCHREALTIME`, else perl's `Time::HiRes`), to `FM_CI_TIMINGS_OUT` when
that variable is set — never
under `FM_ROOT`, so the gate still leaves nothing behind in the tree it
judges — and only then: the plain, flag-less run pays for none of the timing
calls. `.github/workflows/ci.yml` runs four kinds of job: `fast`; `bash`, a
matrix of six shards; `bun`; and `e2e`. One `bash-timings` job reads the
previous successful main run's timings artifacts once and hands the same
text to all six bash shards (best effort — a first run, a fork with no read
access, or a `gh` failure leaves all shards using the same size fallback).
Each uploads its observed timings as `suite-timings-<shard>`, so a slow suite
is visible by name. Independent downloads raced in run 37218411231: 36 suites
ran in no shard, while all six shards were green (T-196). Sharing one read
prevents different partitions when main finishes a run during shard startup.
Each shard also writes `FM_CI_ASSIGNED_OUT` before its pool starts, including
an empty shard: `# shard i/n` followed by its assigned suite paths. This output
is local to the invocation: suites that run CI on fixtures do not inherit it
and cannot overwrite the parent assignment. Relative output paths stay
relative to the caller, even with `FM_ROOT`. Each shard uploads that file as `suite-assigned-<shard>`, even when a suite fails. The `ci` job
checks out `bin/` and `tests/` of the run's own default ref (the merge ref on
a pull request, the pushed commit on main) and runs `bin/ci.sh --coverage`
over the downloaded assignments. On both pull requests and pushes to main,
coverage fails unless all shard headers agree, each shard occurs once, and
every `tests/*.test.sh` appears exactly once with no unknown suite. Invalid
headers and out-of-range shards are excluded entirely before checking the
remaining assignments. Coverage runs no stage; assigned suites that fail or
never finish still fail their bash shard. The final job named `ci` — the
required check's own name — `needs` all four and fails if any of them failed or was skipped, so
branch protection and gate 5 read exactly what they read before. Every job
keeps its own 10-minute `timeout-minutes`. Sharding turned the one
`bun install` main had into eight — the six `bash` shards, `bun` and `e2e` —
so every one of those jobs, not just one, caches bun's install cache
(`~/.bun/install/cache`, keyed on `hashFiles('bun.lock')` and the runner
OS) ahead of its `bun install` step; `e2e` also keeps the pre-existing
Playwright-browser cache the one job had. `tests/ci-sharding.test.sh` proves the
flags' validation, that `--stage` runs only its own group of stages, that
`--shard`'s shards union to exactly `tests/*.test.sh` with no suite in two
(including a suite added after the fixture was first split), that
`FM_CI_TIMINGS_OUT` is written only when asked and in milliseconds, that
`FM_CI_TIMINGS_IN`'s recorded duration — not a suite's real size — decides
the split, and, from timings with zeros and a missing suite, that no shard
is left holding only zero-timed suites and no shard's recorded load exceeds
the mean by more than the longest suite. Its coverage tests prove shared
and mixed timings, missing and duplicate shards, malformed and out-of-range
headers, disagreeing counts, unknown and newly added suites, optional and
unsharded assignment output, and coverage usage errors. `tests/ci-workflow.test.sh`
reads the workflow for job names, the shard flag, the final `ci` job's `needs`,
the per-job timeout, and a `bun.lock`-keyed cache before every `bun install`.
It also pins the single bash timings read, assignment uploads, coverage on
both events, and the default checkout ref; mutations that reintroduce a
per-shard download or a head-ref override must fail those pins.

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
`fm-worker.sh` may still run a final sweep through the same helper. A crew
round inside the OS sandbox (13.1) can neither write the git directory nor
reach GitHub, so there saving is `fm-worker.sh`'s alone - its final sweep
and its EXIT trap - and the prompt it builds tells the round not to
checkpoint (13.1, "Saving the branch").

### Managed session defaults

`bin/fm-session.sh start --repo <root>` is the portable service bootstrap.
It reports actual recorded process liveness, worktrees, pending decisions and
(inside `HERDR_ENV=1`) observed Herdr panes. It starts or reuses the correct-root
board, owned by the session; it starts no watcher (T-151). It does not dispatch work or invent a
captain choice. Firstmate reconciles legacy/unrecorded processes and existing
authorization before dispatch; stopped work is preserved for explicit resumption.
Before the board is shown, and again on `status`, session bootstrap runs deck
reconcile: for each non-`firstmate` actor whose last event is not
`agent_finished`, it corroborates that actor against `state/runs/<actor>/`
process receipts (not task-level pidfiles). Actors with no live process receive
one `agent_lost` (T-118, crew liveness above) and then `agent_finished`, both
under that exact actor with `data.status: process_gone`, so the
event-sourced crew list matches process reality. For a spec preflight, the
run's identity.json supplies `mode: spec-preflight` to both `agent_lost` and
its closing `agent_finished`; its loss pushes no `lost:` wake and rings no
firstmate doorbell. Task-level reconcile alone
cannot clear these ghosts. `status` and `start` report the reconcile result as
`deck_reconcile`. `status` reads the live process receipts and the wake
queue. `wait`, optionally with `--decision D-id` and `--timeout <seconds>`,
is the caller's own foreground wait on a doorbell of its own: it returns (exit 0,
the items as JSON) as soon as an unacknowledged wake is on the queue, and
exits 1 when the timeout ends first. `watch` and `stop` are gone and say so.

Board reuse is verified with a fresh random file under the requested root and
the board's existing `/file?path=<relative-path>` endpoint. An HTTP response on
the configured port is insufficient; a different or unverifiable root is refused.
`fm board` and session start wait for a busy board: each try lasts up to five
seconds, repeated only after a timed-out try, for up to twenty seconds in all,
because the board answers nothing while it builds `/api/state`. Each try uses
the same nonce and at most the remaining budget; no new try starts after the
deadline, but a reply from a started try is judged on its body even if it arrives
after the deadline. Any answer other than the nonce, an HTTP error, any other
connection failure (refused, reset or denied), or a malformed address ends the
check at once as unverified, and so do twenty seconds of silence. Setup's port
check keeps a single two-second try.
A verified board retains its recorded `board/` and `i18n/` tree identities on
reuse. If the clean checkout differs, `fm board` or session start asks the
verified board to drain through secret-only `POST /drain`. A running merge in
any project or an answer in flight refuses with `409 drainBusy`; the answer
counter spans dispatch completion and the send-back start check. While draining,
`/decisions`, `/tasks` and `/open` refuse with `503 boardRestarting` before any
effect. Only a session-owned board is stopped, and its replacement retains the
same live session owner, falling back to the caller's session only if that owner
is gone. The port counts as free only when a TCP connect is refused; even an
HTTP error means it is still occupied. A listener that does not answer the root
check in time is never mistaken for a free port. When it cannot replace that
listener, `fm board` refuses with exit 70 and names its pid, when known, and the
manual step (`kill <pid>`, then `fm board`) in English and Chinese; without a
pid it asks to stop the process listening on the port. Replacement and browser
sign-in run under the board lock, with one browser open against the surviving
board. A hand-started
board, or an older board without `/drain`, keeps the English and Chinese notice
to restart by hand, naming `kill <pid>` when the pid is known. A board that
will not stop within ten seconds is released and named in the notice, also
with `kill <pid>` when known. A drain also releases itself after 30 seconds if its
caller disappears. Unknown, dirty or equal checkout code triggers no drain.
A reused board with unknown previous code (no record, no `code` key, or
`code: null`) and a known clean checkout also remains undrained and is not
marked stale. It gets a bilingual `code_unknown_reason` notice naming its pid
when known and the manual restart step if recent changes are missing; `fm board`
prints that notice after the JSON and still exits 0.
`board.json` retains the board's owner and code; a successful replacement adds
`replaced` (old and new short code) and bilingual `replaced_reason`, with no
stale notice. No stored record is migrated, and autopilot never starts or
replaces the board.
The bootstrap verifies HTTP page retrieval and reports whether `open` or
`xdg-open` was invoked. It cannot verify browser navigation. Bun is required for
the board. Nothing watches `state/decisions/`: the board pushes each wake as
it writes the decision (below), and neither rewrites `events.jsonl`. A wake
never reaches a completed API conversation by itself; firstmate keeps
pending authorized work actively monitored - a `wait` running as the
harness's own background task is how a turn is told - or explicitly hands it
off before ending the turn.

### Owners and wakes (T-151)

**The rule: every background process has an owner and ends with it; a wake
is pushed by the writer, never found by polling; a process that outlives its
owner is a bug.** On 2026-09-29 the captain's machine held 207 orphaned
processes, 192 of them `watch-child` watchers from suite runs inside crew
rounds, some over a day old, polling a fixture directory that had been
deleted. A watcher whose only exit is SIGTERM, started in a session of its
own so that nothing dying takes it along, cannot be fixed by stopping it
more carefully; it has to be unable to outlive what needs it.

*The lifeline.* `bin/lib/fm_lifeline.py` (and `bin/lib/fm-lifeline.sh`, its
command line) is the one way fm starts a background process. The owner
keeps the write end of a pipe and the child the read end, and the child's
loop blocks on that descriptor together with its own work; it reads EOF
when every holder of the write end has died, which the kernel delivers for
SIGKILL as for anything else, and across setsid. An owner fm did not start
- the harness's session - is watched by its pid instead: kqueue
`EVFILT_PROC NOTE_EXIT` on macOS, a pidfd on Linux, both blocking until the
kernel reports the exit. No liveness is ever decided by polling a pid or a
directory. A program that cannot watch a descriptor runs under the keeper,
`fm_lifeline.py keep`: in a session of its own, with the program in a
process group of its own below it; when the owner goes it sends the group
SIGTERM, then SIGKILL after `FM_LIFELINE_GRACE` seconds (5), and when the
program ends first, whatever it left in its group goes too. The keeper's
pid stands for the program and exits with its status. An owner already gone
starts nothing, and says so.

*Owners.* Each start names its owner:

| Start | Owner |
|---|---|
| `bin/fm-herdr.py` board start (`fm-session.sh start`, `fm.sh board`) | the session: it outlives the command on purpose |
| the pane-child's closer (`close_from_child`) | the pane-child, by a forked lifeline; it closes once that exits |
| `board/server.ts`'s `fm-merge.sh` (a merge the captain clicked) and `fm-worker.sh` (send back); `fm-dispatch.sh` (dispatch answer) | merges and send-backs: the session the board belongs to; the board itself when it was started by hand. Dispatch: the board's own process group, which is why the board drains before it is replaced |
| firstmate's stock crew launch (`dispatch-crew`) | the session, through `bin/lib/fm-lifeline.sh --session` |
| T-144's round runner (`spawn_runner`, the `pane-child`) | the session: a round outlives the fm-worker.sh that launched it on purpose (retained, to be stopped or resumed) |

The runner is fm's own Python, so it holds its lifeline itself rather than
under a keeper: `start(..., direct=True)` starts it in a session of its own
and hands the line over, and the runner's `hold()` blocks on it in a thread
and, when the owner is gone, ends the round's process group - SIGTERM, then
SIGKILL after the grace, from a helper outside the group. Its pid and group
stay the round's, which `fm.sh stop` and the board's park and drop signal.

The session is `FM_SESSION_PID` when set, else `FIRSTMATE_CI_SESSION`
(below), else the nearest ancestor that is not a shell or an interpreter -
the harness, not the short-lived tool shell. The walk reads each parent
from the kernel: `/proc` on Linux, libproc `PROC_PIDTBSDINFO` on macOS,
`ps` only where there is neither, since a sandbox may refuse it. It never
guesses: when a parent cannot be read, the walk reaches pid 1, or it runs
64 hops, it refuses (`session-owner` exits 70) and nothing is started, so
a long-lived process never ends up owned by the shell that launched it. A keeper watching a pid exports it as `FM_SESSION_PID`, so the board
hands its own owner on to what it starts. A process that must outlive its
starter names the longer-lived owner it belongs to, never none.
A review resolves `session-owner` before its first managed launch and before
spec preflight or identity allocation, then exports the returned pid as
`FM_SESSION_PID`. Later launches retain that owner even if the starting shell
exits. A refusal (the resolver's exit 70) becomes `fm-review.sh` exit 75 with
guidance: start in the foreground of the session, use the harness's background
mode, or explicitly name the owner with `FM_SESSION_PID`.
`tests/lifeline.test.sh` fails on any `start_new_session`, `setsid`,
`nohup`, `disown` or `detached: true` in the code of `bin/`, `board/` or the
skills outside the primitive. `bin/fm-worker.sh`'s mirror watcher (13.1) still
checks its parent with `kill -0` once a second; it is a plain `&` child that
ends with its round, and moving it onto the lifeline is `fm-worker.sh`'s
work, outside T-151's scope.

*The wake.* The watcher is deleted: `watch-child`, the decision watch and
`fm-session.sh watch`/`stop` are gone. Whoever writes a decision delivers
the wake at write time - the board, on the captain's click and again when a
merge it started settles. It appends the item to the wake queue,
`state/session/wake.jsonl` (`{id, reason, decision, woken}`), which is read
again at every session start and status, and then rings every waiter's
doorbell. A FIFO hands each line to exactly one reader, so one shared FIFO
loses a wake as soon as two waiters hold it - and firstmate routinely has
several (review round 1 of T-151 lost one to a second `--await`). So each
waiter has a bell of its own, and all three steps live in
`bin/lib/fm_lifeline.py` (`Doorbell`, `ring`, `await`), which the board, `fm-decide.sh`
and `fm-herdr.py` share:

1. *Register.* A waiter makes its own FIFO under a temporary name, opens it
   `O_RDWR` (so no closing writer is ever an end-of-file), and only then
   renames it to `state/session/wake.d/<pid>-<random>.fifo`, so a ringer
   never finds a registered bell nobody holds. It removes the bell when it
   exits, on TERM, INT and HUP too.
2. *Check after registering, before blocking.* The waiter reads the durable
   state for its own condition once: the answer file for `--await <id>`,
   unacknowledged queue items for `session wait`. A wake written between
   that read and the registration is therefore found, never missed.
3. *Ring every bell.* A writer appends to the queue first, then opens every
   `wake.d/*.fifo` `O_WRONLY|O_NONBLOCK` and writes one line: `ENXIO` is a
   bell nobody holds any more (a waiter killed outright), and is unlinked;
   `EAGAIN` is a bell already full, so already rung. Ringing never blocks.

On any ring each waiter reads the durable state again and returns or blocks
again; the line's content is a hint, never the answer. The waiters are
`fm-session.sh wait` and `fm-decide.sh --await`, tools for scripts that
block on an answer; firstmate itself keeps none running, because the
harness's hooks hand it every wake (T-137, below). `fm-decide.sh` writes no
decision - it requests cards and awaits answers - so it is a waiter, not a
writer. `status` and `start` list every
wake not delivered since it was pushed; `ack` records one, and a later
wake for the same id (its merge settled) lists it again. There is one record
of delivery, `state/session/acknowledged/<id>.json`, written by
`fm_lifeline.py acknowledge`: `ack` writes it, and so does the watch
below when it takes a wake, so a wake the hook delivered is neither listed
nor returned by `wait` again, and one acknowledged here is not handed to
the hook. Observations the
retired watcher wrote under `state/session/observed/` are still read. Their current
decision fields replace the frozen receipt fields when readable. A chosen decision
is omitted when its merge is `merged` with `merge_settled`, or its task has a
`merged`/`closed` event with no later captain `reopened` event carrying a non-empty
reason. Unanswered or unsettled decisions stay listed; missing or unreadable
decisions retain the receipt's fields. This read never writes acknowledgements or
edits, moves or deletes observations. Wake-queue items are not filtered this way.

*Waking the harness (T-137).* Every event that needs firstmate is pushed by
its writer through `fm_lifeline.py push` (append, then ring): `fm-worker.sh`
and `fm-review.sh` at a round's end, after its `agent_finished`
(`finished: T-134 <actor> ok`, `failed: ... exit 1`, `review: T-134 APPROVE
<head> #9`); the deck reconcile for a lost run (`lost: T-134 <actor>`);
`fm-emit.sh` for a gate result written from outside a round
(`gate: T-134 failed gate 5 (ci) #9`); and the board, as above (`card: D-51
answered A`, `merge: D-51 failed`). A wake pushed into an external project's
store is also forwarded to the engine queue as one bounded item: `reason`
`forwarded`, `origin_project`, `origin_reason`, and a line naming the project,
with a namespaced id and timestamp. Its whitespace is collapsed and its line
is limited to 300 characters. Only the engine's firstmate doorbells are rung,
not its autopilot doorbells, so one watch hears every project. The original
project queue and doorbells remain unchanged; existing wakes are not backfilled.
A lost spec preflight is the exception:
the deck reconcile writes `agent_lost` and its closing `agent_finished` with
`data.mode: spec-preflight`, but pushes no `lost:` wake. The autopilot likewise
queues no lost/failed-round wake for an actor whose event history carries that
mode; firstmate reads the preflight's result directly. Sandbox warning status
events copy mode from identity.json, preserving that classification.
A crew wake carries its `line`, and
`status` lists it beside the decisions. A round's progress is never pushed.
The harness side is `bin/lib/fm_watch.py`. One watcher cycle per repository
(`bin/fm-watch.sh`, started by `bin/fm-watch-arm.sh` through the lifeline,
owned by the harness session) holds `state/watch/cycle.lock`, so whether
one lives is the kernel's answer; `arm.lock` lets one arm at a time start
one, and a generation number counts them. The cycle blocks on its doorbell
until a wake is past `state/watch/cursor` and not yet delivered, takes it
(acknowledging it), starts its successor,
and only then writes it for an arm to claim - a rename, so exactly one arm
does. An arm parks on its doorbell, its owner's exit and the live cycle's
exit together; it exits when its owner does and takes nothing, which is
what a plain FIFO-reading hook orphaned by a SIGKILLed claude failed to do
(measured on Claude Code 2.1.284). Each harness's hook speaks that
harness's protocol - Claude Code's asyncRewake exit 2, Codex's `decision:
block`, Cursor's `followup_message` - and a synchronous guard refuses a
turn end that would be blind. Crew rounds, crew worktrees, linked git
worktrees and an away captain (`state/away`) never arm.
`bin/lib/fm_hooks.py install` (the fm command line's `hooks`) writes the hooks into each harness's local, uncommitted config,
and `fm-session.sh start` runs it for the harness it detects. What is
verified per harness is in `docs/verification/supervision.md`; the board
shows the watch, the last wake, what waits and any gap.

*Tests are contained.* `bin/ci.sh` runs every suite - each bash suite, the
bun tests and the browser suite - with a scope marker,
`FIRSTMATE_CI_SCOPE`, in its environment, inherited across setsid, and with
the suite's own runner named as its session twice: `FM_SESSION_PID`, and
`FIRSTMATE_CI_SESSION`, which the suites that scrub `FM_*` keep. So nothing
a suite starts under "the session" belongs to the operator's. Each suite also gets a temp
root of its own (`TMPDIR`), under which every fixture it makes lives. When
the suite ends it lists the processes still carrying the marker, or naming
that root in their command line - `/proc` on Linux, libproc on macOS -
kills them, and the suite is red, naming each one. macOS withholds the
environment of its own platform binaries (`/bin/bash`, `/bin/sleep`), so
there the marker cannot see a leaked bash `fm-worker.sh` or mock adapter;
their argv is visible, and the root finds them. What that still misses on a
Mac - a platform binary with no fixture path in its argv - the gate says
once per run, never passing as having looked: `leak check: macOS hides the
environment of /bin binaries; matched by fixture root as well - the
required check (Linux) is authoritative`. A test that starts a
background process on purpose stops it or ends its owner. The ops-side sweep
firstmate runs is a fuse that should reap zero; anything it reaps is a bug
to be found by this rule.

The normal `fm-autopilot`, `fm-dispatch`, `fm-worker` and `fm-review` entrypoints freeze
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
`<role>-<name>-<task slug>-r<round>[<attempt mark>]`, such as
`worker-mira-t035-r2` or `reviewer-noah-t018-r3b`. Labels retain role prefixes,
fit Herdr's 32-character syntax and include task/run identity. **The `r<n>` is
the task's review round (T-116)**, the round the pull request's review is on,
so `r3` reads as round three: `fm-review.sh --round <n>` names it (as
`FM_ROUND`), and otherwise it is one past the `review_opened` events the log
holds for the task in the run's project. A worker's first run is round 1, and
the review that follows is round 1 too. The autopilot counts only the
project's `review_opened` events for that task and passes the next `--round`
explicitly. The same task id in another project never increments it.
Before T-116 the `r<n>` was a global run counter (`state/runs/counter.json`,
472 on 2026-09-26), which read as round 465 on a task in its first round; the
counter no longer appears in any actor. A second run of the same role, task,
project and round is a retry and gets the next attempt with a short mark:
`r12`, `r12b`, `r12c`, … `r12z`, `r12aa`. A run directory that already exists
(a pre-T-116 actor whose counter equals the round, or a racing retry) also
moves to the next attempt, so every run keeps a distinct identity. Allocation
is under one lock; the 32-character room is measured against the final suffix,
mark included, and a name with no room is refused, never cut.

`identity.json` records the run's identity as separate fields, and these are
what the board reads: `name` (the roster name, `mira`), `role`, `project` (the
resolved project, `FM_PROJECT` else `default_project`, the default included;
`null` when neither names one), `task`, `round` and `attempt`. For example:

```json
{"actor": "reviewer-noah-t018-r3b", "name": "noah", "role": "reviewer",
 "project": "firstmate-workflow", "task": "T-018", "round": 3, "attempt": 2}
```

`fm-worker.sh` and `fm-review.sh` carry the same six fields as `data.identity`
on every crew payload they emit, and `fm-herdr.py emit-status` does for a run
that recorded them. No consumer parses them out of the actor. A run recorded
before T-116 has no such fields and still loads: the board takes its name from
the old actor (the one place an actor is read, `fm-herdr.py`'s `ACTOR` and the
server's `legacyName`, both accepting `-r<n>` with or without a mark) and shows
its round and attempt as unknown, never the counter. Normalization and the
requested alias are recorded in `identity.json` and printed at launch. Extremely long task labels retain a digest and the full original task
in metadata. The exact canonical actor appears in invocation context, Herdr tab,
pane and agent names, board events, log paths and result receipts. Existing live actors
are not renamed. A foreign Herdr name collision is a reported transport failure,
not a silently different sidebar identity.

**What the round actually ran on (T-127)**, added to `identity.json` once the
adapter has run - `bin/fm-herdr.py record-model`, called by `fm-worker.sh` and
`fm-review.sh` after `fm_run_chain` returns. Since T-146 `vendor` and
`model_requested` are there from the round's start too (`record-requested`,
`fm_record_requested`): the vendor the chain starts on and its model, just
after allocation, and again for each fallback vendor as its attempt starts,
which clears any `model`, `cli_version` and `model_mismatch` until
`record-model` writes them. The fields: `vendor` (the adapter that ran, e.g.
`claude`), `model_requested` (`config.yaml`'s for that vendor, via
`fm_model_for` in `bin/fm-config.sh`), `model` (what the vendor's own CLI
reported using, read from the slice of its log this attempt wrote,
`fm_vendor_model`; `"unknown"` when the transcript says nothing, never a
guess), `cli_version` (`<vendor> --version`, `fm_vendor_cli_version`;
`"unknown"` when the command is missing or silent), and `model_mismatch`
(`true` only when both `model_requested` and `model` are known and differ).
For example, continuing the record above:

```json
{"vendor": "claude", "model_requested": "claude-opus-5-5",
 "model": "claude-sonnet-5", "cli_version": "2.1.0", "model_mismatch": true}
```

These five ride `data.identity` on every crew payload, read fresh from
`identity.json` for each one (T-146), the same way the six above always
have; a payload emitted before the round has run carries `model`,
`cli_version` and `model_mismatch` as `null`, and a run recorded before
T-127 never gains them. `model_mismatch` costs the round nothing extra to
raise on the board: the board reads it straight off `data.identity` the way it
already reads `round` and `attempt`, on whichever payload happens to carry it.
It is also its own `model_mismatch` event type, in `bin/fm-diagram.sh`'s
`ROUTINE` list (the acceptance names it explicitly) and `bin/fm-emit.sh`'s
`TYPES`, which that list must equal exactly (`tests/diagram.test.sh`); the
worker and the reviewer emit it, `--data` carrying `vendor`, `model_requested`
and `model`, alongside the `crew_status` line that already carries
`data.identity` and already refreshes the board's activity line with the
same news.

**Where `model` comes from, per vendor**, is what `bin/adapters/_contract.md`
documents: every adapter is asked for JSON output unconditionally now (not
only when a managed attempt reads its final answer from it), and
`fm_vendor_model` reads it in each vendor's recorded shape. claude's
`--output-format json` result carries no `"model"` field - T-127 assumed it
did, and recorded `unknown` for every claude round (T-146) - but names the
models the run used as the keys of `modelUsage`: the key the round asked for
when it is among them, otherwise the one with the most output tokens, since
claude runs a small model on the side. Before any result, claude's stream
`init` event (`{"type":"system","subtype":"init","model":...}`) names it.
Otherwise the *last* literal `"model":"..."` field wins - cursor-agent's and
gemini's own `--output-format json` result, codex's `--json` event stream -
so a later report in the same run, such as a fallback model the CLI itself
chose, wins over an earlier one. `fm_adapter_model_refusal` reads a
non-empty `modelUsage` as a turn that happened, as it reads a `"model"`.

**A wrong model name refuses the round before it does anything, loudly
(T-127)**, the same way a missing login or a policy that will not read does.
Two checks, one before the round starts and one after:

`cursor-agent` is the one vendor of the four whose CLI can list its own
models offline (`cursor-agent --list-models`, once it is given a `CURSOR_API_KEY`);
`fm_adapter_model_listcheck` in `bin/adapters/_lib.sh` runs it before the
round, and `bin/adapters/cursor-agent.sh` calls it right after the
`FM_ADAPTER_ARGS` model-flag check, before `fm_adapter_policy`: a lightweight
call that touches no worktree and needs no confinement of its own, the same
way `command -v cursor-agent` above it is unconfined. When the list command
itself cannot be run, exits non-zero, or says nothing, the
check is silent and the round starts anyway; the CLI's own answer at round
time, below, stays the final word. With `AGENT_CLI_CREDENTIAL_STORE=memory`,
run before the round's key is handed in, this check is normally silent.
codex and gemini document no listing
command of their own, so they get no preflight, and this is stated here
rather than left for a reader to wonder whether one was missed.

After the round, `fm_adapter_model_refusal` in `bin/adapters/_lib.sh` reads
the CLI's own words in the slice of the log this attempt wrote. Unlike
`_FM_SIG`'s outage check, which the caller's evidence predicate can still
rescue (work beats a signature), a model refusal must never discard a
completed round: review round 5 found a broad, exit-code-blind phrase list
would misread a transcript that merely discussed "an invalid model" or "no
such model found" - ordinary English, including in this very codebase's own
prose - as a configuration failure. So the check fires only when the
attempt's own exit code is non-zero (a completed round, exit 0, is never
read as a refusal) and the log slice reports no `"model":"..."` field at all
(a report of the model that ran means a turn happened, whatever text follows
it). claude names its refusal exactly - `[claude-code:unrecognized_model]` -
read literally; codex, cursor-agent and gemini have no such fixed token
documented, so they are read against one generic, vendor-agnostic phrase
list instead, the way `_FM_SIG` is for an outage, but anchored to the start
of a line (`Error: …`) - the shape a CLI's own one-line usage error has,
which ordinary prose discussing models in passing does not. Either way the
adapter exits 64 rather than reaching `fm_adapter_verdict`: never read as the
vendor being unavailable (which would quietly fall back to another vendor,
on another model) and never as a normal failed attempt that would still
reach the gates. The message, naming the vendor and the model, is written to
`FM_MODEL_REFUSED` when the caller set one - the same pattern
`FM_POLICY_BLOCKED` uses for a refused host - and `fm-worker.sh`/
`fm-review.sh` raise it on the board (bilingual, both languages naming the
vendor and the model) via the existing `worker_crashed` / `review_failed`
types.

`fm-session.sh`'s startup report, which already said when a project names no
reviewer vendor or model, now also says when the configured model is not one
the vendor is known to accept (`fm_model_known` in `bin/fm-config.sh`, a
small offline catalogue for claude - the CLI itself, at round time, is
always the final word for a name not yet in it). cursor-agent's own list
needs a live login this config check has no session to ask for, so it stays
uncatalogued (rc 2) here, the same as codex and gemini; its check is the
round-time preflight above.

**Applied, not only recorded.** `config.yaml`'s `model` (top level,
`worker.model`, `reviewer.model` - `fm_model` resolves a role's own over the
top-level one, exactly as `vendor` does) is the vendor's own model name;
since T-146 it is named per vendor, `models.<vendor>`, and resolved per
attempt for the vendor that attempt runs (section 5.3, "A model is named
per vendor"). `fm_run_chain` hands it to whichever adapter runs as
`FM_MODEL`; each adapter passes it with its own
CLI's flag - claude and cursor-agent `--model`, codex and gemini `-m` - and
refuses a round whose `FM_ADAPTER_ARGS` also names one (`--model`, `-m`,
claude's `--fallback-model`), so `config.yaml` is the one place a model is
ever chosen. `config.yaml`'s own values were `claude-opus-5-5`, top level and
reviewer, per the captain (2026-09-28); since 2026-09-29 (T-146) the workers
run codex on `gpt-6-astra` and the reviewers claude on `claude-opus-5-5`,
under `models:`.

The name in the label is a crew member, and a name always means one role
(T-104). A crew member's name, rank and service record belong to one role:
workers rise by merged tasks, reviewers by approvals that were never
overturned, so a name that served as a worker on one task and a reviewer on
the next would be two careers under one name. There are therefore two rosters,
24 workers and 24 reviewers, drawn at random once per installation: 48
distinct names taken uniformly from `POOL` in `bin/fm-herdr.py`, at least 200
short given names of varied origin, the first 24 to workers and the rest to
reviewers. The draw is written once to `state/crew/rosters.json`
(`{"workers": [...], "reviewers": [...], "drawn_at": ...}`); `state/` is
gitignored, so each installation has its own crew. The installation is the
first time firstmate runs in a checkout until the plugin installer
(T-075/T-076 retired; T-077..T-083 deferred, see the adoption ledger)
would call the same step: `fm-session.sh start` draws when the file
is missing, and so does every allocation, so no run lacks a crew.
`bin/fm.sh roster` prints both rosters, `roster init` draws them if missing
and refuses to redraw an existing crew, and `--redraw` draws again only when
asked, saying that ranks and service records keyed by the old names stay with
the old names. A crew file that is not two disjoint lists of names is refused,
not quietly redrawn. `FM_ROSTER_SEED` seeds the draw and exists only for
tests. config.yaml may pin names under `rosters:` with `workers:` and
`reviewers:` lists, validated as T-089 validated `roster:`; any other key
under `rosters:`, or an inline `rosters: {…}`, is refused by name; a pinned list
replaces that role's drawn names, a drawn name pinned to the other role is
dropped, and a name in both lists is refused with a message naming it. The
old single `roster:` is still read: its names are workers, with one warning
line.

A worker takes a name only from the worker roster and a reviewer only from the
reviewer roster; an explicit `--name` on the other role's roster is refused.
The rosters say which role a name has now; the runs say which role it has
served. Every `identity.json` records `role` and `name`, and a run allocated
under this rule also records `one_role: true`. A name keeps the role of its
earliest such run and is never used for the other: an explicit `--name` on
neither roster is refused once it has served the other role, a roster name
that served the other role (moved in config.yaml, say) is skipped, and a draw
or `--redraw` never deals a name to the role it did not serve. So one name
never holds a worker record and a reviewer record from here on. Runs without
`one_role` were written under T-089, which let one name serve both roles;
they bind no name, because history is not judged by a rule it was not written
under. Otherwise an installation that used the old `roster:` would find every
name that had served both roles refused for both. A name's first run under
the rule decides its role.
When every name of a role is taken the run fails, exit 70, with `the <role>
roster ran out: …, and a name of the other role is never borrowed`; it never
borrows and never reuses a name with a number. Within each roster the T-089
rules hold. Under the identity lock a run takes a name
no live run holds. A run is live while it is unfinished — it has no
`orchestration-result.json` — unless it is proven over: its `process.json`
launcher no longer matches and every attempt it recorded has terminated. A run
with neither record is starting, not over: `fm_identity` writes `process.json`
immediately after allocation and `transport()` writes its attempt, so no clock
decides it. Reserved, unstarted and legacy attempts count as live, as they do
for recreation. `identity.json` records the crew member whole as `name`, and the
actor carries exactly that name; runs from before T-089 have none, so their name
is read from the actor. Every comparison — live, previous round, other role —
is on the whole name. A task's worker and reviewer are never the same crew
member: a name either role of the task has used is not offered to the other.
A task keeps its previous round's name while that name is free; otherwise it
takes the first free name in its roster. An explicit alias wins but is
refused, exit 70 with one line, when that name is on the other role's roster,
has served the other role, is the task's other role's, or is live, and the
line names the first of these that holds, in that order. A refusal that never
lifts is named before one that lifts when a run finishes, so a crew member is
not told to wait for a name their role can never take. A name is
never cut: one that does not fit the room the final `-<task>-r<n>` suffix
leaves, measured again on each retry, is refused, so the actor stays within 32
characters and no label can stand for two crew members. An empty `roster:`,
`rosters.workers:` or `rosters.reviewers:` is refused like any other invalid
list, not replaced by the drawn crew.

**A round is headless and fm's own; a terminal host is a window onto it
(T-144, captain, 2026-09-29).** Codex, Claude, Cursor Agent and Gemini adapters
run through shipped `bin/fm-herdr.py` `transport`, which starts the real CLI as a
supervised process group of fm's own: a session of its own, started through
the lifeline and owned by the fm session (T-151), its stdout and stderr in the
attempt's `run.log`, its pid in `runner.pid` and its exit code in `runner.exit`,
with the same sandbox, `FM_HERDR_TIMEOUT` and lifetime lock as before. It is
never a child of a pane, so a pane that closes or crashes cannot end a round, and a
machine with no Herdr, cmux or tmux runs the same round with no window at all.
`bin/fm-herdr.py stop` is the one way fm stops crew. `stop <root> <actor>`
ends that actor's live rounds by their process groups (TERM, then KILL after
`FM_STOP_GRACE` seconds, default 5); a group whose every member has exited,
zombies included, is gone. A round is live while its runner still runs
`fm-herdr.py`, or while its lifetime lock (`execution.lock`) is held, or, until
it has a `runner.exit` or `result.json`, while any member of its group lives: a
killed runner can leave its adapter running, and that round is stopped by its
group all the same, reported as `<actor> <pid> (runner gone)`, and then its
CLI by the pid `execution.json` names. `follow` judges the end of a round by
the same rule, never by the runner's pid alone. `stop <root> --task <id> [--project P] [--default D]` stops a whole task:
TERM to its `fm-worker.sh` (`state/worktrees/<id>.pid`, whose trap saves and
pushes the worktree), then each of the project's runs on it, by group, and the
script that launched it (`process.json`), by TERM. A round from before T-144,
with no runner, has its vendor CLI sent TERM by the pid `execution.json` names.
Every pid is signalled only while `ps` shows the program it was recorded for.
It prints `{"stopped": [...], "failed": [...]}` and exits 1 when anything could
not be stopped. The board's park and drop run it with the board's own rule for
a run's project, and `bin/fm.sh stop <actor>` / `stop --task <id>` is the
operator's way to it. A runner that is gone with no live descendant and no
`result.json` was lost: transport writes that result with `status: lost` and
exit 70. Nothing refuses a round for lacking Herdr, and `FM_TRANSPORT=direct`
merely asks for no window (`fm_refuse_herdr_bypass` is retained as a no-op).

`host:` in `config.yaml` (`none|herdr|cmux|tmux`; `FM_HOST` overrides; detected
when unset from `HERDR_ENV=1`, then cmux's `CMUX_WORKSPACE_ID`, then `TMUX`) picks
the host that opens a window. The window is opened before the round starts, is
labelled with the canonical actor, and runs `fm-herdr.py follow <attempt>`: the
run's log from its start, followed until the round ends. It is the same stream a
pane showed before, now read from the log; `bin/fm.sh follow <actor>` runs the
same follower on the actor's latest round for anyone without a window. Opening a
window is best effort. Every attempt's `window.json` records the window it got:
`{"host": "none", "status": "none"}` when there is no host, so no window is
recorded, never inferred from a missing file. Any failure or uncertainty is
written there with its reason, the pane is left alone, and the round runs
without one. A Herdr window that fails after the round was handed its pane
gives the pane back: the round's `HERDR_PANE_ID`, `HERDR_TAB_ID` and
`HERDR_WORKSPACE_ID` (and `environment.json`) are the caller's again, and the
disowned pane is reported `idle`, best effort, so it is not left `working`. The round's own transport closes the window when the round ends,
and closing a window stops nothing.

tmux gets `new-window -d -P -F '#{window_id}' -n <actor> -c <tree> <follower>`,
the form tmux(1) documents: `-d` leaves the caller's window current, `-P -F`
prints the new window's `@N` id, and the window closes itself when the follower
ends. cmux's `new-workspace` takes no name: its help (the installed cmux,
2026-09-29) is `new-workspace [--cwd <path>] [--command <text>]`, where
`--command` types the text and Enter into the new workspace's shell. So the
workspace is opened with `--cwd <tree> --command <follower>`, its ref read
from the reply (output "defaults to refs", `workspace:N`; a UUID is accepted
too), labelled with `rename-workspace --workspace <ref> <actor>`, and closed at
the round's end with `close-workspace --workspace <ref>`. A reply naming no
workspace is a failed window; a workspace that opened but could not be labelled
is still closed at the end. Those command lines are checked against the tools'
own help. Not verified: the exact text of cmux's `new-workspace` reply, since a
real cmux socket could not be reached where this was written, and tmux on a
real server. The stand-ins in `tests/herdr.test.sh` take only the flags that
help lists and refuse any other.

With Herdr, `herdr tab create --workspace <target-workspace> --cwd <tree>
--label <canonical-actor> --no-focus` uses the installed supported interface;
creation IDs come from `result.tab` and `result.root_pane`. An external project's
new crew tabs use the workspace labelled with the project name: reuse a matching
workspace (including one made by hand), choosing the lowest workspace number if
labels repeat, or create it with `--no-focus`. A project-private lock serializes
this lookup and creation. Sync also ensures the workspace; round preparation
leaves this to the window lookup. Lookup failure is logged and falls back to the
caller workspace. The self project stays in the caller workspace, and a recorded
pane keeps its recorded workspace on reuse. No workspace is closed, renamed or
focused by fm; its initial shell belongs to the captain. Never split the caller's
view. Record caller tab/pane and observed UI focus before and after creation;
changed or unknown focus opens no window and takes no focus back from the user.
The round receives its owned tab/pane/workspace context, not the caller's IDs.
A known caller pane is required to open a tab; without one, or without a
`herdr` command, there is no window.
Firstmate *stock launch* is only `bin/fm-worker.sh` / `bin/fm-review.sh`; session
wrappers and hand-started vendor CLIs are protocol violations.
Adapters still tee vendor transcripts into `cli.log`; their stdout is `run.log`.
Vendors that buffer until completion (for example cursor-agent `-p`
JSON) do not stream progress; the runner therefore prints a start line, periodic
`[fm] … still running` heartbeats (interval `FM_HEARTBEAT_SECS`, default 15, `0`
disables), and a finish line so a captain watching a window can see liveness
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
later vendor completes. Any ownership uncertainty stops reuse of the pane, and
the attempt then runs with no window. Worker and reviewer
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

There is no watch to opt out of (T-151): the wake queue and the waiters'
doorbells live under `state/session/`, the queue survives restarts, and
nothing runs to keep it.
No global hooks, lavish or no-mistakes installation is needed. Existing user
authorization persists, while scope/product choices and merge approval remain
captain board decisions. The self-update request is not a fabricated board choice.

Decision content should include bespoke before/after diagrams, concrete option
tradeoffs and authored English/Traditional Chinese summaries with derived
Simplified Chinese. The current generic generator does not establish that content
quality. Board diagrams, locale and effects changes are separately T-034 and are
not shipped by this task. Firstmate's decision instructions must integrate the
final T-034 `fm-decide.sh`/`fm-autopilot.sh` contract after firstmate identifies that
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
same pull request, reviewer and gates as anything else.** The system
cannot quietly edit itself.

`fm.sh sync-skills` imports from an external skills directory into
`skills/vendor/`, read-only, never writing back, never polluting the user's
global skills.

---

## 12. Failure and recovery

Git network calls inherit stall bounds from `fm-config.sh`: SSH appends
`-o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4`
to an existing `GIT_SSH_COMMAND` unless it already contains
`ServerAliveInterval`. An explicit `GIT_SSH` executable is left alone.
Otherwise the base is `git config --get core.sshCommand`, or `ssh`.
HTTPS defaults to `GIT_HTTP_LOW_SPEED_LIMIT=1000` and
`GIT_HTTP_LOW_SPEED_TIME=60`, preserving values already set. A stalled
transfer typically ends within 60–80 seconds; a slow but live transfer can
run longer. The SSH base is resolved once in the repository sourcing config:
a later `git -C` call overrides that clone's own `core.sshCommand` with the
exported value. Managed clones set none today; a project needing a deploy key
uses `GIT_SSH_COMMAND` or a global `core.sshCommand` instead.

`fm_github` and the round launchers' direct `fm_gh_read` calls bound each gh
attempt to `FM_GH_TIMEOUT` seconds (default 120). The foreground Perl runner
owns the command group: a timeout sends TERM, then KILL after two seconds,
and returns 124. TERM, INT and HUP forward to that group with the same cleanup
and return 128 plus the signal; an unexecutable command returns 127.
Only read calls retry a timeout, up to two times after `FM_GH_RETRY_DELAYS`
(default `5 15`). Reads are PR view/list/checks, run view/list, and API GET:
field/input flags imply a write unless an explicit GET method is supplied.
Other failures return immediately. Writes and file downloads never retry.
Each read attempt buffers stdout; only the last attempt is printed.
The worker context pack also uses `FM_GH_TIMEOUT` for git evidence, gh JSON
and failed-job logs, without retries; a timeout records missing evidence and
the pack is still written. Existing bounded autopilot and project-check
calls retain their limits. Short operator calls in `fm-merge.sh`,
`fm-cleanup.sh`, `fm-decide.sh`, `fm-reconcile.sh`, `fm-project.sh`,
`lib/fm-stack.sh` and `fm.sh` remain follow-up work for gh bounds.

- The truth is `state/events.jsonl`; state is rebuilt by replaying it on start.
  No snapshots.
- `fm-reconcile.sh` walks `state/worktrees/` and `gh pr list` looking for
  orphans, tests worker liveness by pid file, and marks the dead
  `worker_crashed` for redispatch.
- `bin/fm-autopilot.sh` polls GitHub and writes pull request events back into
  the same log. **A merge the captain performs on GitHub must be noticed by the
  system itself**, not reported to it by a person.
- An adapter exiting `2` moves to the next vendor in `config.yaml` and emits
  `vendor_unavailable`.
- A review round that ends its one turn with no signed verdict is retried
  once, automatically, by `fm-review.sh` itself, before it is reported
  failed, and says so on the board (en and zh-TW). This is what a
  backgrounded check left the round without: a run-mode reviewer that starts
  a long check in the background and ends its turn waiting on it gets no
  later turn to check back on it, since the round is one headless
  invocation - it happened three times (T-119 r1, T-119 r6, T-122 r2). The
  retry is gated on `fm_run_chain`'s own `FM_VENDOR_SPOKE`: only an attempt
  that produced some output - bytes in the log, or, per vendor, in its own
  output directory - and still ended without a verdict is retried. One that
  produced nothing at all is not: that is an environment this round's own
  launch was refused by (a caller's changed focus, an uncertain pane, a
  vanished caller), which reads the same way twice, and re-reading it can
  even turn a real refusal into a false success - the environment "changed"
  once and then stays changed, so a second, fresh reading of it no longer
  differs from itself and the retry's own launch goes on to succeed where
  the first was rightly refused (T-123 review round 2). A second empty
  ending, from an attempt that did speak, is reported exactly as an
  unretried one always was (T-123).
- Compaction waits until the log is large enough to slow a replay.

---

## 13. Security

- `/open` accepts localhost only, and the resolved path must sit inside the
  repository.
- Every board route that writes or starts a program takes the captain's
  credential, the board's own Origin and a JSON body (section 8, the board's
  trust boundary; T-122). The secret lives in the operator's config
  directory, never in the repository or `state/`.
- Adapters may not run git or gh; a worker never holds a GitHub token.
- The board binds `127.0.0.1` and opens no external port.
- The engine repository is public; credentials, customer content and private
  external designs/task lists must not enter it. The former public-only project
  restriction is retired: section 15 accepts private repositories and keeps
  their records under FM_HOME. Unreadable protection is unknown and requires
  confirmed project checks/policy before readiness.
- Every crew round runs under one permission policy fm owns (13.1).

### 13.1 Crew permissions (T-105, T-117)

A worker used to inherit the operator's personal CLI settings: on the
captain's machine that allowed gh-axi, Herdr, a browser, reading any path
and editing `~/.claude/skills`, and refused bun, npm, python and chmod.
cursor-agent ran with `-f` and no sandbox; codex and gemini ran on vendor
defaults. Now every round, worker or reviewer, whatever its vendor, runs
under one policy fm owns.

**T-105 once, and why it came back as T-117.** T-105 (PR 90) merged on
2026-09-26 and locked every vendor out on macOS: claude failed at start
with `EPERM: operation not permitted, open '/tmp/claude-501'`, because it
keeps a directory under `/tmp` whatever `TMPDIR` says and the profile let
the round write only its roots; and claude and cursor-agent could not sign
in, because both keep their login in the macOS keychain, whose mach
services the profile denies so that gh's token and git's credentials stay
out of reach. CI runs only the Linux (bwrap) path, and saw none of it. PR 96
reverted it. T-117 is the same change with each vendor's start and login
provided for (below), a canary that runs the real vendors on the operator's
Mac, and an escape hatch so that a broken sandbox can never again stop every
worker with no way to ship its own fix.

**The policy.** `fm_policy <role>` in `bin/fm-config.sh` resolves it from
`config.yaml`'s `policy:` block, flat keys for both roles or a `worker:` /
`reviewer:` block for one, with the project's `projects.<name>.policy:` over
it. The keys are `network` (the registries the round's commands may reach;
default none; a later layer replaces an earlier one), `read` and
`never_read` (added to, never replacing) and the `procs` / `cpu` ulimits.
Everything else is a floor no key loosens, the OS sandbox itself included:

- writes: the worktree or checkout, and a temp directory of the round's
  own, which is its TMPDIR. Never the caller's TMPDIR or `/tmp`: every round
  shares those, and run-mode review checkouts are made there, so a root
  naming them would let one round read or rewrite another's code;
- every location a round is handed through its environment is inside a
  write root. The toolchain's caches live under the operator's home by
  default - bun's install cache, Playwright's browsers, npm's, pip's, Go's,
  anything following `XDG_CACHE_HOME` - where a round may neither read nor
  write, so `setup` or an end-to-end check would be refused. The adapter
  points each of them (`FM_ROUND_CACHES` in `bin/adapters/_lib.sh`) into the
  round's own temp directory, for both roles, whatever the caller or the
  operator's shell set it to: an inherited value names a directory the
  policy never made writable, as the one `fm-review.sh` used to make beside
  its run-mode checkout did. The vendors' config homes (`CLAUDE_CONFIG_DIR`,
  `CODEX_HOME`, gemini's `HOME`) are there
  too, and the directory a CLI writes its final answer to is a write root of
  its own (`--write`). The price: every round starts from empty caches and
  downloads what its `setup` installs, from the registries the policy
  declares, and no round reads a cache another wrote.
  `tests/adapter-contract.test.sh` checks every such location, for every
  vendor, both roles and both platforms, against the generated profile and
  bwrap arguments, and every other directory the round is handed with it;
- reads: default-deny outside the write roots and the toolchain; never
  `~/.ssh`, `~/.config/gh`, `~/.netrc`, `~/.git-credentials`, cloud
  credentials, any vendor's home, fm's `state/` and the other worktrees in
  it. A vendor's own round gets back only what it needs to start and sign
  in, named per vendor below; none of it is another vendor's, a setting, a
  hook, a skill or an MCP server;
- commands: allowed inside the sandbox; git push, gh, Herdr, browsers and
  MCP refused; signals and `ps` are refused too, which is why nothing here
  reads a sibling process's liveness by pid. `fm-review.sh`'s run-mode
  checkout is owned by a kernel `flock` its round holds on the checkout's own
  `owner` file for as long as it runs, never a pid `sweep_checkouts` sends
  `kill -0`: inside this sandbox that signal is refused whatever it is aimed
  at, so a live sibling's pid fails it exactly as a dead one's would, and a
  sweep run from inside a round would read a checkout still in use as
  abandoned and delete it (T-123, the first round after T-117 merged, PR
  #98 rounds r8 and r8b). The kernel drops the lock the moment its last open
  reference to the file closes, a SIGKILLed round's included, which is the
  one liveness signal this sandbox cannot fake. The owner file is built and
  locked under a name `sweep_checkouts`' glob never matches, and made
  visible under the name it does match only by a same-filesystem rename
  once the lock is already held - never created under the visible name
  first and locked a moment later, which would leave a window in which a
  concurrent sweep's own non-blocking flock on the same unlocked file
  succeeds and it deletes the checkout before its owner ever gets to it
  (found in review round 2 of T-123 itself);
- a suite that builds its own scratch directories for `bin/fm-review.sh` to
  run against never does so with a bare `mktemp -d` and a later `cd "$var"`:
  a `mktemp -d` this sandbox refuses prints nothing and exits nonzero, and
  `cd ""` on that empty result succeeds in bash and simply stays where it
  already was, so the very worktree or checkout the suite runs from came
  back as the value of that variable, for a later `rm -rf "$var"` to remove
  (a T-121 worker worktree, and, running `bin/ci.sh`, a T-107 review
  checkout, both lost this way on 2026-09-27). `tests/lib.sh` adds two
  helpers for it: `safe_tmpdir`, which takes an explicit template under
  `$TMPDIR` (or `/tmp`) and exits 70 the moment `mktemp` itself fails,
  instead of handing back an empty result for `cd` to turn into "here"; and
  `safe_rm_rf`, which refuses to remove an empty path, the current
  directory, the repository root, or anything that does not resolve
  strictly inside `$TMPDIR`, whatever the caller passes it (T-123).
  `tests/adapter-contract.test.sh`, `tests/sandbox.test.sh` and
  `tests/project.test.sh` all use both, closing every instance of the shape
  found by grepping every suite for a variable both assigned from a bare
  `mktemp -d` and later resolved by `cd`-ing into itself (the exact shape a
  third worktree, T-126's, was lost to the same day); `bin/ci.sh`'s test
  hygiene stage now refuses that self-resolving shape in any `tests/*.test.sh`
  it lints, in either mode, so it cannot come back unnoticed (T-123 round 4);
- the mktemp refusal the fix just above was itself built around: on macOS,
  `mktemp -d`'s bare form, and its `-t`, both ask
  `confstr(_CS_DARWIN_USER_TEMP_DIR)` for where to create, not `$TMPDIR` - a
  directory outside every root a round may write, so the call is refused
  there rather than landing anywhere `TMPDIR="$tmp"` says (round 6's own
  reproduction, on the reviewer's host: `mkdtemp failed on
  /var/folders/.../T/tmp.xxx: Operation not permitted`, a path under
  neither the round's TMPDIR nor the caller's). Only an explicit template
  already worked, which is what `safe_tmpdir` builds by hand.
  `bin/fm-sandbox.sh run` closes it at the root instead, for every
  command a round runs, not only the ones this repository's own suites
  happen to call through a helper: on darwin it puts a small stand-in ahead
  of the real tool on the round's own `PATH`, under the round's own `$tmp`,
  that turns a bare call or `-t` into the one form that already worked - an
  explicit template under `$TMPDIR` - and hands anything else (an explicit
  template, `-p`, or a flag it does not recognise) straight to the real
  `/usr/bin/mktemp`, unchanged. Linux needs none of this: GNU's own
  `mktemp`, which bwrap gives a round, already honours `$TMPDIR`.
  `tests/sandbox.test.sh` runs a bare `mktemp -d`, `-t`, and an explicit
  template through `fm-sandbox.sh run` on both platforms and checks where
  each one landed (T-123 round 7). The same emptied `mktemp -d` result is
  also what `tests/ci.test.sh`'s own `fixture()` fed to `FM_ROOT`, which
  `bin/ci.sh` then read with `${FM_ROOT:-...}` - empty and unset look the
  same to that form - and ran the whole gate against the real tree instead
  of the fixture, recursively, from inside a live review round (round 5,
  which lost its own checkout to exactly this). `fixture()` now uses
  `safe_tmpdir`, and `bin/ci.sh` refuses an `FM_ROOT` that is set but empty
  rather than defaulting to the tree it lives in;
- the stand-in above still left four call sites unconverted, and round 6's
  reviewer lost a live checkout to exactly this while running the project's
  own suites: `fixture()`, `recover` and `victim_root` in
  `tests/review.test.sh`, and the top-level scratch root in
  `tests/crew-end-to-end.test.sh`, all a bare, template-less `mktemp -d`
  with nothing guarding a refused result. All four now go through
  `safe_tmpdir` (round 7). `bin/ci.sh`'s test hygiene stage widens from
  banning only the self-resolving `cd` shape to banning a bare,
  template-less `mktemp -d` or `mktemp -t` on its own, with no `cd`
  anywhere in sight, over every suite `bin/ci.sh` already lints plus the
  bin/ scripts most likely to build one (`bin/ci.sh`, `bin/fm-review.sh`,
  `bin/fm-sandbox.sh`, and every adapter). A named, commented list in the
  stage itself (`mktemp_pending`) carries the roughly one hundred sites in
  some two dozen other files the captain judged, on 2026-09-27, better left
  to the `fm-sandbox.sh` stand-in above than converted one call at a time;
  a file not on that list is held to the new check like any other, so it
  cannot silently regrow where this round already closed it. The lint's own
  match is anchored to where `mktemp` is actually about to run - the start
  of a line, after `;`, `|` or `&`, or straight inside a `$(...)` - so a
  comment or an assertion's own message that merely mentions the words
  never trips it, matching how the pattern-widening this round needed for
  `tests/sandbox.test.sh`'s and `tests/ci.test.sh`'s own fixtures, which
  must keep writing a genuinely bare call for the round or suite they
  build to run against, threads the literal words through a variable
  instead of writing them out whole, the same way the self-resolving-`cd`
  check's own fixture already had to (T-123 round 7);
- the round's own temporary directory - where the mktemp stand-in above
  lives - is never nested under `--ctl`: fm's own control files (the
  profile, a vendor's login copy, the proxy's port or socket) live under
  `--ctl`, and nothing of fm's belongs on the round's own `PATH`. A test
  helper that omits `--tmp` gets the fallback `$work/tmp`, which the round's
  `--ctl` genuinely contains; `tests/sandbox.test.sh`'s `kc()` now passes
  its own `--tmp`, as every real caller already does, so that assertion
  keeps meaning what it says (T-123 round 9);
- a directory a round's own temp directory holds is only guaranteed to
  exist for the life of the round: `fm-sandbox.sh run`'s own exit trap
  removes it, `--ctl` included, the moment the round ends. A test that
  asked `test -d` on a path under it after `"$SB" run` had already returned
  was asking whether cleanup it elsewhere asserts had somehow not
  happened; the mktemp stand-in's own tests now check what a round made
  from inside the round, while it is still there to look (T-123 round 9);
- a name that is only data - a path listed as a value, never invoked - can
  still read as a call to a naive, repository-wide text sweep for one:
  `bin/ci.sh`'s own list of files still left to `mktemp_pending` names
  `bin/fm.sh` as one of them, which is exactly the shape
  `tests/decide.test.sh`'s sweep for "what raises a card" is watching for,
  so it assembles that one name from a variable rather than spelling it
  whole, the same way a fixture that must write a genuinely bare `mktemp`
  call already threads it (T-123 round 9);
- a fixture that builds its own throwaway repository and `cd`s into it,
  then writes a relative `skills/reviewer` path there, reads to a
  repository-wide lint elsewhere (the skills self-update feature's bounded
  writer check, `bin/fm.sh lint`) exactly like a write to this checkout's
  own `skills/reviewer` - that lint's own narrow recognition of a fixture's
  `cd` looks for the literal `mktemp -d` shape safe_tmpdir now replaces
  everywhere, so it no longer sees this one as a fixture at all.
  `tests/review.test.sh`'s fixture writes those two paths through its own
  root variable instead (`"$d/repo/skills/reviewer"`), which that lint
  already treats as a fixture path on its own terms, rather than teaching
  it a second way to recognise `safe_tmpdir` (T-123 round 9);
- `safe_rm_rf`'s own test for a path outside its TMPDIR asked for a
  `TMPDIR` that was never created, so the function's first guard - that
  `TMPDIR` itself resolves - refused it before the "outside" comparison the
  test claimed to exercise ever ran (round 7 review). The test now creates
  that directory first, so the branch it names is the one that returns 70
  (T-123 round 9);
- the `kc()` helper in `tests/sandbox.test.sh` (round 9) passes its own
  `--tmp` on every call, so the round's own temp directory is never the
  `ctl/fm-sb.*/tmp` fallback shape several assertions still assumed after that
  change: the profile's own `(subpath ...)` line, and the codex/gemini x
  linux/darwin login-copy check (four times), each hard-coded that fallback
  layout regardless of what `--tmp` was actually given. Fixed at the root: one
  variable (`kctmp`) records the one path `kc()` actually passes, and every
  assertion reads it from there instead of re-deriving or re-guessing the
  shape (T-123 round 11);
- that `kctmp` variable (round 11) was assigned inside `kc()`, and every
  call to `kc()` is itself wrapped in `$(kc ...)` to capture its echoed
  exit code - a command substitution, which bash always runs in a
  subshell. A plain assignment made there never reaches back into the
  script's own variables, so every assertion after the first `kc()` call
  that read `$kctmp` was reading one `set -u` had never actually seen set
  in this shell - `kctmp: unbound variable`, on the real CI runner, not
  this suite's own author's machine, where nothing forced the read to
  happen before some other assignment coincidentally supplied a value.
  `kctmp` is now declared once, at the top level before any `kc()` call,
  and `kc()` only clears and recreates the directory it already names
  (T-123 round 13);
- a `never_read` policy path that is an ancestor of the round's own work
  or temp directory must not become a blanket deny of everything under
  it: claude's own deny rule beats its `Read(/$work/**)` /
  `Read(/$tmp/**)` allow rule, so denying a repo-relative ancestor such
  as `state` (whose own `state/worktrees/<task>` is a worker's tree or a
  reviewer's checkout on the self project) denied the round's own tree
  too, and refused a live reviewer's own checkout under `main`'s policy
  (round 12). The claude adapter now carves around it instead of
  denying it whole: it walks from that ancestor down to the round's own
  tree and denies every other entry at each level - a sibling worktree,
  `state/runs`, `state/events.jsonl` - and never the branch that leads to
  `$work` or `$tmp` themselves (T-123 round 13);
- the decoy this suite plants in the real `TMPDIR` to prove isolation
  (above) was built with an already-reaped pid, the same shape as the
  suite's own *stale* fixture - proving TMPDIR isolation, not that a
  genuinely in-use checkout survives, which is what the acceptance text
  asks for. It now holds a real kernel `flock` the same way the
  `fm-review.live` fixture does; the mark file it waits on is a bare path,
  never `mktemp`-created, since `mktemp` itself creates an empty file at
  that name immediately, which made the wait succeed before the lock was
  ever taken (T-123 round 13);
- network: the declared registries only; GitHub and loopback are refused
  as values, and refused again by the proxy whatever a policy file says.
  The list names whatever the check actually fetches (Playwright's
  Chromium comes from `storage.googleapis.com`, for one);
- loopback: a round may open ports of its own and connect to them, which
  every suite that starts a server needs, but never the board's port
  (`FM_PORT`, 4173) nor any port that was listening when the round started.
  On macOS the profile says so port by port, and if the listeners cannot be
  read no loopback port but the proxy is reachable. A per-port denial is a
  rule the kernel applies, not one fm can read back, and the canary on
  2026-09-26 found a claude round reaching the live board through a profile
  that denied its port. So before every macOS round `fm-sandbox.sh` tries
  the profile: behind it, it connects to each port that was listening but
  the proxy's. A connection that gets through means the round's would, and
  the round is given a profile with no loopback but the proxy instead - its
  own servers go with it, and it says so on stderr and in the round's log; a
  profile that lets one through even then refuses the round (70). A check
  that could not run behind the profile tightens it the same way. On the
  captain's Mac (macOS 15.7.9) firstmate measured that a port-specific deny
  never carves a port out of a `localhost:*` allow, in either order, so
  there every round gets the profile with no loopback but the proxy.
  Binding is the other half (T-153). On 2026-09-29, with the captain's board
  down, a review round ran `tests/board.test.sh`, and a fixture board bound
  127.0.0.1:4173 - the board's own address - because the suite's `start_k`
  passed `FM_PORT="$PORTK"` with `PORTK` empty and Bun reads a variable set
  but empty as unset; the captain's answers went to the fixture. So the
  profile also denies `network-bind` and `network-inbound` on the board's
  port and on every port listening when the round started, after the
  loopback allow, and writes the board's deny even when the listeners could
  not be read. While nothing holds the board's port, `run` also binds it
  behind the profile before the round: a bind that gets through is treated
  like a connection that does, the round getting no loopback but its proxy,
  or being refused. Whether something holds the board's port is asked of
  the port - a plain connect outside the profile - not read from netstat,
  whose listing can miss it; a port that answers is treated as listening,
  tried by connecting and never bound. That is macOS only, where loopback is the host's; on
  Linux the round's network namespace makes any bind the round's own. At the
  other end `board/server.ts` refuses `FM_PORT` set but not a port, empty
  included, with exit 64 - it reads the variable through libc's `getenv`,
  since Bun drops an empty one from `process.env` - and the board suite's
  helpers refuse an empty port. Every
  macOS round says in one `fm-sandbox: loopback:` line which profile it got
  - its proxy and ports of its own, with the ports tried and closed to it,
  or its proxy alone - and the canary prints that line per vendor, so what
  a round could reach is never inferred from a note that is not there. The
  canary's own listeners count only requests carrying the round's nonce,
  so `fm-sandbox.sh`'s check, which connects before the round starts, is
  never read as the round reaching them. On Linux the round's loopback is
  its own network namespace's, where no host listener is;
- secrets a system service hands out: on macOS the keychain (gh's token,
  git's osxkeychain helper, every saved password, and the vendors' logins),
  the pasteboard, the Internet Accounts and Apple ID stores, Kerberos
  tickets and Touch ID are out of every round's reach, since no file rule
  covers a credential served over mach. The list is `SECRET_SERVICES` in
  `bin/fm-sandbox.sh`; the profile starts from `(allow default)` and names
  what it denies, because an allow list of services would break toolchains
  in ways only the canary could find, and what it leaves open hands out no
  credential. No round is given back any of them: a vendor that keeps its
  login there is handed that one login by fm (below). TLS roots come from
  `/etc/ssl/cert.pem` (`SSL_CERT_FILE`) for a tool that would have asked the
  keychain;
- the process ulimit is `procs` more than the user already runs, since
  the kernel counts every process the user owns; a count that cannot be
  taken refuses the round rather than guessing. The limits as set reach the
  round as `SANDBOX_ROUND_LIMITS`: macOS may enforce a lower process limit
  than it was given, and reports that one back to `ulimit -u`;
- no unix sockets; `GH_TOKEN`, `GITHUB_TOKEN`, `SSH_AUTH_SOCK`, cloud
  credentials and the escape hatch's own variables scrubbed; the
  repository's `.claude/`, `.mcp.json`, `.cursor/` and `GEMINI.md` not
  loaded.

Before T-105 the run-mode reviewer's hosts were `reviewer: network:`; that
key still counts for a reviewer when no policy layer declares a network.

**Two layers.** An adapter translates the policy into its CLI's own flags
and declares which of the eight dimensions (`write read network sockets env
repo-config refuse ulimit`) they enforce. `bin/fm-sandbox.sh` runs the CLI
inside an OS sandbox built from the same policy, which covers all eight on
both platforms. The network is a per-round proxy that allows the declared
registries and the vendor's own service; it is the only way off the
machine, and it records every host it refuses. On macOS that sandbox is
`sandbox-exec`, whose profile lets the round reach the proxy's loopback
port and nothing else off the machine. On Linux it is `bwrap`, which mounts
only what the round may read, gives it a `/tmp` of its own and a network
namespace of its own (`--unshare-net`), and binds the proxy's unix socket
into it; a small forwarder serves that socket on the round's own loopback
and points the proxy variables at it. Reading is default-deny only in the
OS sandbox, so no round runs on a host without one, but for the escape
hatch below. Before the CLI starts the adapter checks the union; a
dimension neither covers refuses the round with 2, the fallback chain moves
on, and nothing runs less confined than its policy. When the sandbox itself
fails before it starts the CLI - the vendor's login, its proxy, its
profile, the process count, the sandbox binary - that is 2 as well, not the
launcher's exit code read as a model giving up: `fm-sandbox.sh --started`
writes `started` from inside the sandbox just before the CLI, and a round
without that line never ran. The file is emptied right after the options,
so every earlier exit leaves it empty. fm-sandbox's own files (the profile,
the proxy's port or socket, the login it hands in) go under `--ctl`, the
adapter's control directory beside the round's temp directory and outside
every write root; never a fixed `/tmp`, which a confined caller (a run-mode
reviewer, a worker running the suites) cannot write.

**Each vendor's start and login (T-117).** Each round reaches the login the
operator already uses for that vendor, and nothing more. No round reads a
login where the operator keeps it. Where it is in the keychain,
`fm-sandbox.sh` reads exactly the vendor's own item, outside the sandbox,
with `/usr/bin/security find-generic-password -s <service> -a <account> -w`
(one item, never a search), and hands its access token in as a variable.
cursor-agent is the exception: it reads `agent login`'s token through the
keychain API, which nothing inside a round can answer for, so its round
signs in with a Cursor API key the operator keeps once for the crew (below).
Where it is a
file, fm reads the file and writes a copy with its refresh token emptied
into the round's own temp directory, where the adapter points the CLI; the
operator's file is neither readable in the round nor bound into it. The
refresh token is never handed in: a round that refreshed a login would
rotate the operator's out from under them, and one that refreshed it but
could not write the result back (the file read-only, as T-117's first round
had it for codex and gemini) would spend a single-use refresh token and
log the operator out. A copy that still holds a field named like a refresh
token (`refresh_token`, `refreshToken`, any case) that the policy does not
empty refuses the round with 65, so a CLI that moves its refresh token is
refused rather than handed it. A login past its expiry, or none at all,
refuses the round with 77 before the sandbox starts, which the adapter reads
as the vendor unavailable: an expired access token is refreshed by running
the CLI once outside a round, never inside one. Per vendor, from `VENDORS`
in `bin/fm-config.sh`:

| vendor | its login, read by fm outside the round | handed in as | what of its own the round opens | temp | mach services |
|---|---|---|---|---|---|
| claude | a `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` already in the operator's environment is used as is; else the crew's own long-lived token (T-126), made once with `claude setup-token`: macOS keychain item `firstmate-claude-token`, account the operator's user; else, when `secret-tool` is on the operator's PATH, the libsecret item `firstmate-claude-token`/account the operator's user (T-126 round 2, Linux's rough equivalent of the keychain; its absence is skipped, not refused); else `~/.config/firstmate/claude-token`, refused unless its mode is the operator's alone (600). Only with none of those does it fall back to the operator's own interactive login as before T-126 - macOS keychain item `Claude Code-credentials`, account the operator's user; elsewhere `~/.claude/.credentials.json` - field `claudeAiOauth.accessToken`, refused past `claudeAiOauth.expiresAt`; that fallback warns, in the round's log and on the board, that the round can die when that login refreshes | `CLAUDE_CODE_OAUTH_TOKEN`, exported, not on a command line | nothing of `~/.claude` or `~/.claude.json`: its config directory is one of the round's own (`CLAUDE_CONFIG_DIR`, in the round's temp directory), holding its sessions, todos, caches and `.claude.json` | the round's own (`CLAUDE_CODE_TMPDIR`); and `/tmp/claude-<uid>`, read and written, on macOS only, because claude opens it whatever `TMPDIR` says (T-105's EPERM). On Linux the round's `/tmp` is its own, so the directory is made afresh there | none |
| cursor-agent | the crew's Cursor API key, which the operator makes once in Cursor's dashboard and keeps for fm outside every round: macOS keychain item `firstmate-cursor-api-key`, account the operator's user; else `~/.config/firstmate/cursor-api-key`, refused unless its mode is the operator's alone (600). A `CURSOR_API_KEY` already set is used as is. Never `agent login`'s own items (`cursor-access-token`, `cursor-refresh-token`) or `~/.config/cursor/auth.json`, which hold its refresh token. With none, the refusal says the one-time step | `CURSOR_API_KEY`, exported, not on a command line; the variable cursor-agent documents in its own `Authentication required` message; with `AGENT_CLI_CREDENTIAL_STORE=memory`, so cursor keeps the login in memory and never in the keychain (plan B, 2026-10-05) | nothing of `~/.config/cursor` or `~/.config/firstmate`; `~/.cursor/chats`, `~/.cursor/projects`, `~/.cursor/cli-config.json`, `~/.cursor/statsig-cache.json` read and written | the round's own | none |
| codex | `~/.codex/auth.json`, field `tokens.access_token` or `OPENAI_API_KEY`; the file holds `tokens.refresh_token` too. A `CODEX_API_KEY` already set is used as is only when `config.yaml`'s `billing:` chose api-key for codex; otherwise the round sheds it (T-121) | a copy of the file with `tokens.refresh_token` emptied, as `auth.json` in the round's own `CODEX_HOME`, so no `config.toml` or profile of the operator's is read either | nothing of `~/.codex/auth.json`; `~/.codex/sessions`, `log`, `history.jsonl`, `version.json`, `models_cache.json` read and written | the round's own | none |
| gemini | `~/.gemini/oauth_creds.json`, field `access_token`, refused past `expiry_date`; the file holds `refresh_token` too. A `GEMINI_API_KEY` or `GOOGLE_API_KEY` already set is used as is only when `config.yaml`'s `billing:` chose api-key for gemini; otherwise the round sheds it (T-121) | a copy of the file with `refresh_token` emptied, at `.gemini/oauth_creds.json` under a `HOME` (and `GEMINI_CLI_HOME`) of the round's own, with `GOOGLE_GENAI_USE_GCA=true` when no API key is set. The commands gemini runs inherit that `HOME` | nothing of `~/.gemini/oauth_creds.json`; `~/.gemini/tmp`, `history`, `google_accounts.json`, `installation_id`, `user_id` read and written | the round's own | none |

claude's round also carries `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`,
the variable claude documents for turning off its own non-essential network
traffic - telemetry and error reporting - never set for another vendor. A
review round used to have the proxy refuse `http-intake.logs.us5.datadoghq.com`
as an undeclared host and report it as one the project's network policy
must add; the traffic that host was for is now off at the source, and the
proxy's refusal of anything else claude asks for is unchanged (T-123).

A Google access token lasts an hour, so a gemini round started more than an
hour after gemini last ran outside one is refused as not logged in until the
operator runs gemini once; that is the price of never letting a round
refresh the operator's login. What only the canary proves: that codex reads
`auth.json` from `CODEX_HOME` and signs in with the access token alone, that
gemini takes its home from `HOME` and its login type from
`GOOGLE_GENAI_USE_GCA`. A wrong guess shows as `authenticated=no`, never as
a refresh token handed in.

Why a variable and not the keychain: once a round may look up
`com.apple.SecurityServer`, any process in it can ask for any item whose
access list trusts a program the round can run. gh stores its token through
`security(1)`, so `security find-generic-password -s gh:github.com -w`
would print it, and git's helper answers for github.com the same way. There
is no profile rule for one item. So the keychain stays denied to every
round, and fm reads the one item a vendor's round needs itself and hands it
in as a variable. T-117's fourth and fifth rounds served cursor-agent's
`agent login` token through a stand-in for `security(1)` first on the
round's `PATH`; the canary on 2026-09-26 showed cursor-agent never asking
it, since it reads that token through the keychain API, which no program
on the `PATH` can answer for. A refresh-token-free way into `agent login`'s
own login does not exist from inside a round, so cursor-agent signs in with
an API key instead, which is also a credential the operator can revoke on
its own without logging their own Cursor out. The one-time step, which the
refusal and `fm-sandbox.sh login-source` both print:

```
security add-generic-password -s firstmate-cursor-api-key -a "$USER" -w
```

(`-w` last, so `security` asks for the key rather than taking it on the
command line), or the key alone in `~/.config/firstmate/cursor-api-key` at
mode 600. `~/.config/firstmate` is never readable in a round.

**Claude signs in with a crew token of its own, not the operator's
interactive login (T-126).** On 2026-09-27 two crew rounds died mid-run with
`API Error: 401 OAuth access token has been revoked` - T-125 round 1's
worker and T-123 round 2's reviewer: `fm-config.sh` handed the round the
access token of the operator's own interactive login, and when the
operator's own Claude sessions refreshed that login, the old access token
was revoked out from under every round still holding it. The fix Anthropic
documents for unattended use is a long-lived token from `claude setup-token`
(https://code.claude.com/docs/en/authentication: one year, bills to the
subscription, model requests only), kept the way T-117 keeps cursor-agent's
Cursor key: macOS keychain item `firstmate-claude-token`, account the
operator's user, made once with
`security add-generic-password -s firstmate-claude-token -a "$USER" -w`; off
macOS, when `secret-tool` (libsecret) is installed, the same-named item made
once with `secret-tool store --label=firstmate-claude-token service
firstmate-claude-token account "$USER"` (T-126 round 2: the captain raised
Linux's own keychain-equivalent case on 2026-09-28, since a file was the
only crew-token option there before); else the token alone in
`~/.config/firstmate/claude-token` at mode 600. The captain approved the
crew-token design on 2026-09-27. `fm-config.sh`'s login lookup for claude
now tries, in order: an explicit `CLAUDE_CODE_OAUTH_TOKEN` or
`ANTHROPIC_API_KEY`, used as is; then the crew's keychain item (macOS); then
its secret-tool item, when the tool is present; then its file; only with
none of those does it fall back to the operator's own interactive login as
before T-126 - never silently: it says so, in the round's log and on the
board (`en` and `zh-TW`), as a warning that the round can die when that
login refreshes. Every read has three outcomes, found, missing or failed
(T-126 round 7), and only missing lets the lookup go on: `security` exiting
44 (no such item), `secret-tool` exiting 1 with nothing on stderr (no such
item) or not installed at all, and a file that is not there. A crew entry
that exists but fails - `security` exiting anything else (36, "User
interaction is not allowed"), a keychain read that times out (30 seconds),
`secret-tool` saying why on stderr (a locked collection), a `claude-token`
file others can read, one that cannot be opened (mode 000, a directory) or is
empty - refuses the round outright, naming the source and its error, the way
an expired or malformed login always has, and nothing after it is read:
`Claude Code-credentials` is never asked for. A secret store that cannot be
reached at all - `secret-tool` saying on stderr it has no D-Bus session or
no secret service, or timing out on a hung bus, as on a headless or SSH Linux
host - says nothing about whether the crew token is in it, so it is a fourth
outcome, unreachable (T-126 round 10): the lookup goes on to the next crew
source, the file, and says in the round's log that it did; if no crew source
answers, the round is refused, naming the unreachable store, and never falls
back to the interactive login. `bin/fm-sandbox.sh login-source` prints one line on stdout,
`tier=<primary|fallback> source=<source>`, never the login, and
`bin/fm-canary.sh` reads that line alone, never stderr, and turns the tier
into `crew-token` or `interactive-fallback` for claude specifically, on its
status line and as `login_source` in its results; firstmate
runs `fm doctor --sandbox`, which runs the canary, at the merge gate for a
change here, and workers do not run it themselves. The operator revokes the crew token at claude.ai, Settings,
Claude Code.

What stays unreachable, whatever the vendor: gh's token (keychain denied,
`~/.config/gh` never readable, `GH_TOKEN` and `GITHUB_TOKEN` scrubbed),
git's credentials (keychain denied, `~/.git-credentials` and `~/.netrc`
never readable), and every other keychain item: nothing on a round's `PATH`
or in its profile answers for the keychain. `tests/sandbox.test.sh` runs
rounds with a stand-in for the operator's keychain holding claude's login,
the crew's Cursor key, `agent login`'s own items and gh's token, and checks
that fm read the vendor's one item only, that the round is given its access
token or key and never a refresh token, `agent login`'s token or gh's, and
that the profile still denies the keychain's mach services. It also runs
codex's and gemini's rounds with login files holding refresh tokens and
checks that the round finds a copy with the access token, never the
refresh token, and that the operator's file is neither readable nor bound;
`tests/adapter-contract.test.sh` checks the same through each adapter,
where its CLI looks.

**A round's recorded environment is an allowlist (T-156).** On 2026-09-30
a worker round's `environment.json` on the captain's Mac held the whole
of the launcher's environment, the operator's own
`CLAUDE_CODE_MESSAGING_TOKEN` included; a `GH_TOKEN` would have landed there
too. So `fm-herdr.py transport` writes that file from one list,
`ROUND_ENV_NAMES` and `ROUND_ENV_PREFIXES` beside `round_environment()`,
never from `os.environ`: `FM_*` (the round's identity, paths and fm's own
settings), `PATH`, `HOME`, `TMPDIR`, `LANG`, `LC_*`, `TERM`, `TZ`, `USER`,
`LOGNAME`, `SHELL`, the Herdr window's `HERDR_ENV`, `HERDR_PANE_ID`,
`HERDR_TAB_ID` and `HERDR_WORKSPACE_ID`, the CA-bundle variables, and the
session bus `fm-sandbox.sh` reads a libsecret login over, each with its reason
in a comment. Of the vendors' login variables the round gets only its own
vendor's, and of those only the first one set, which is the one
`fm-sandbox.sh` takes as the login; `ROUND_LOGIN` carries the policy's
`given` lists, and `tests/herdr.test.sh` holds the two equal. The runner
reads the file back through the same allowlist before it starts the
adapter, so a file an older launcher wrote hands the adapter no more.
A name the runner needs is added to the list, with its reason; the
sandbox's scrub stays the second line.

**The trade-off accepted (captain, 2026-09-26, option A).** The vendor's
own token is readable by the model in the round; no other credential is.
A round's `CLAUDE_CODE_OAUTH_TOKEN`, `CURSOR_API_KEY`, or codex's or
gemini's access-token copy is in its environment or its own temp
directory, where the model can read it and send it out through the
vendor's own service. GitHub and git credentials never enter a round,
pushing and pull requests stay with `fm-worker.sh` outside the sandbox,
all outbound traffic goes through fm's proxy, and loopback is closed but
for the proxy wherever the per-port denials do not hold. No credential
broker or TLS interception is built. For cursor-agent the amended
acceptance takes the crew's Cursor API key in place of `agent login`'s
own login.

**The escape hatch (T-117).** `FM_CREW_UNSANDBOXED=1`, set in the
operator's own shell - never a `config.yaml` key, which a branch can change
- makes `fm-worker.sh` and `fm-review.sh` run the round without the OS
sandbox: the adapter goes through `fm-sandbox.sh plain` (the scrub, the
ulimits and the vendor's login), and what is left in place is, per vendor:

- claude: its own sandbox back on with T-066's settings - `enabled`,
  `autoAllowBashIfSandboxed`, `allowUnsandboxedCommands: false`, and
  `network.allowedDomains` the policy's registries - so every shell command
  runs inside it and none is let out; no rule allows the shell on its own.
  The permission rules, `--restricted` and the deny list stay;
- codex: its own `workspace-write` sandbox, with its network switch on;
- cursor-agent: its own `--sandbox enabled`;
- gemini: no sandbox of its own. The adapter never turns on its container
  or seatbelt, so under the hatch a gemini round's commands run with the
  operator's own permissions, confined only by the scrub and the ulimits.
  An operator who needs the hatch and cannot accept that takes gemini out of
  the chain for the while.

The round says so loudly - on stderr, as the first line of the round's log
(before the vendor's first byte, so no verdict reads it), and on the board
for the round (`Adapter running on T-… WITHOUT the OS sandbox`, en and
zh-TW). A review round under the hatch keeps its log in `state/reviews/`
whatever its verdict, as the record that the hatch was used. `fm-sandbox.sh` marks every round `FM_IN_ROUND=1` and scrubs
`FM_CREW_UNSANDBOXED` and `FM_ROUND_UNSANDBOXED` from it, and a script or
adapter that sees `FM_IN_ROUND` ignores the hatch and says so: a round
cannot switch its own sandbox off, nor a nested fm run inside one. It is
off by default and is for one thing: letting a fix to a broken sandbox
ship when every sandboxed round fails. Unset it once the fix is merged.

The vendors' own flags, against the proposal's section 4
(`design/proposals/2026-09-25-crew-permissions/design.md`):

| vendor | Linux | macOS | where it departs from section 4, and why |
|---|---|---|---|
| claude | `--restricted --strict-mcp-config --disable-slash-commands --permission-mode dontAsk --settings`: file rules on the worktree and the round's TMPDIR, deny rules, the shell allowed | the same | its own sandbox is off, so the settings carry no `allowedDomains` (under the escape hatch it is on, with them). On macOS it is a seatbelt, which cannot be applied inside another. On Linux its commands would reach the network through claude's own proxy, which has no way out of the round's namespace and names no host it refuses. The registries are enforced by the OS layer's proxy instead |
| codex | `--sandbox workspace-write` with its network switch on, `approval_policy="never"`, the scrub list as `shell_environment_policy.exclude`, `mcp_servers={}`, a `CODEX_HOME` of the round's own holding a copy of the login less its refresh token, so no user profile | `--sandbox danger-full-access` (a seatbelt cannot nest); the rest the same | the network switch is on because codex has only on and off, and off would keep its commands from the proxy |
| cursor-agent | `--trust --sandbox enabled`, `-f` dropped, no `--approve-mcps` | `--trust --sandbox disabled -f` (a seatbelt cannot nest) | on macOS `-f` comes back, inside the OS sandbox only: with its own sandbox off, a print-mode round approves no shell command, and the canary on 2026-09-26 saw cursor-agent sign in, exit 0 and never run its probe. The OS sandbox confines what `-f` lets through, as it does claude's shell; under the escape hatch there is no OS sandbox, so its own is on and `-f` is not passed. On Linux, if cursor's own sandbox cuts the network off before the proxy sees a request, that refusal names no host; the canary shows it per version |
| gemini | `--approval-mode yolo --extensions none --allowed-mcp-server-names fm-none` | the same | no `--sandbox`: it is a container or a seatbelt, neither of which starts inside the OS sandbox. `yolo`, not `auto_edit`: headless, `auto_edit` refuses every shell command, and the OS sandbox is what confines them. No `--policy` file: which gemini versions take one is unverified, and an unknown flag would fail every gemini round |

**A blocked host.** The proxy records every host it refused to the round's
`FM_POLICY_BLOCKED` file, on both platforms and for every vendor.
`fm-worker.sh` and `fm-review.sh` report them on stderr and on the board
(`crew_status`, en and zh-TW), and append one JSON line to
`state/policy/blocked-hosts.jsonl`. That record is what firstmate reads to
raise its choice card:

```
{"at":"<UTC>","task":"T-…","role":"worker|reviewer","actor":"…","project":"<name or ''>",
 "hosts":["<refused>",…],"declared":["<registries the round had>",…],
 "add_to":"projects.<name>.policy.network | policy.network","source":"proxy",
 "expected":["<a known refusal, below>",…]}
```

The crew never widens its own policy; only the captain's answer changes it.
The card itself is firstmate's (SK-001, T-107), not T-105's.

**Known refusals (T-147).** Some hosts are refused to every round, for
every vendor, by the captain's decision, and are not a card's to offer.
`KNOWN_REFUSED` in `bin/fm-config.sh` names each with what it is; every
policy carries the list as `known_refused`, a policy whose `network` names
one is refused (65), and the proxy refuses one whatever a hand-edited
`network` or a vendor's own domains say (`deny known: …`). When a round is
refused one, `fm_policy_report` says so once per round on stderr, as a
known, expected refusal (`fm: known refusal, expected: <hosts> - <what>`),
keeps it out of the hosts it reports as undeclared and out of the record's
`hosts`, and lists it in the record's `expected` instead, so no card
offers it. One is on the list:

- `sdmntpr<region>.oaiusercontent.com` (captain, 2026-09-29, after
  firstmate's investigation). OpenAI's user file store: paths under
  `files/`, on OpenAI's own domain, which the Codex SDK and ChatGPT's file
  features use. The first codex worker round was refused
  `sdmntprsouthcentralus.oaiusercontent.com` and
  `sdmntprnortheu.oaiusercontent.com`. A round's model conversation does
  not need it - that round's CLI exited 0 and talked to the model - and
  allowing it would open an upload channel out of the sandbox. Revisit only
  if a codex feature firstmate needs is shown to fail without it. What the
record cannot name: a command that ignores the proxy variables and connects
directly is refused by the OS, which sees an address, or on Linux no route
at all - never a host name - and a refusal made by a vendor's own sandbox
before the proxy (cursor-agent on Linux, above) never reaches it.

**Saving the branch (T-117).** A worker round cannot save its own branch,
and is not asked to. Its write roots are the worktree and its temp
directory; the worktree's git directory lives in the repository's common
`.git`, which the round reads (so `git log`, `diff` and `status` work) and
never writes, and GitHub is out of its reach. So `git commit`, `git push`
and `fm-checkpoint.sh` fail inside a round. That is on purpose: a common
`.git` the round could write would let it move any branch's ref or rewrite
the objects another task's worktree reads, and no profile rule can give it
its own ref and not the others. Saving is `fm-worker.sh`'s alone: it
commits and pushes what the worktree holds when the round ends, and its
EXIT trap does the same when the round is stopped (TERM, INT). The prompt
`fm-worker.sh` builds says so after the worker skill, overriding the
skill's mid-run checkpoint, which a sandboxed round cannot follow. The
cost is that a round's work reaches the pull request only when the round
ends; a machine that dies mid-round loses what the worktree held only if
the worktree goes with it. `tests/sandbox.test.sh` checks that the git
directories are readable and not writable on both platforms, and
`tests/worker.test.sh` that the prompt carries the override.
`skills/worker/SKILL.md` ("Mid-run checkpoint (required)") is outside
T-117's scope and still asks for the checkpoint; the prompt's section
overrides it until the skill is changed.

**Accepted for now.** The worktree's shared git directory - the common
`.git` of the repository the worktree belongs to - is readable, because git
run in the worktree has to read it. So a round can read other tasks'
commits and `.git/config`. It holds no credential fm puts there, and it is
accepted as it stands until a later task closes it. On macOS a loopback
port first opened after the round started is reachable by the round:
another round's dev server, a suite's server, or a board restarted on
another port than `FM_PORT`. The profile denies only the board's port and
the ports that were listening when the round started (and the check above
tries only those), because it is written
before the round runs and cannot tell a port the round opens itself from
one someone else opens later. On Linux the round's loopback is its own
namespace's, so the gap is macOS's alone. On macOS
`/tmp/claude-<uid>` is shared with the operator's own claude sessions, so a
claude round can read what they leave there; it holds scratch output, not
a credential. A vendor's access token is readable by every command in its
own round, which may send it only to the declared registries and the
vendor's own service.

**Evidence.** `tests/adapter-contract.test.sh` and `tests/sandbox.test.sh`
check each vendor's flags and the sandbox profile against the policy, that a
vendor missing a dimension without the OS sandbox is refused, that declared
registries reach both layers, and that loopback and GitHub never do - with a
stand-in for the sandbox binary, since a runner cannot be relied on to have
one - and, since T-117, each vendor's temp and login allowances, that gh's
and git's keychain items stay unreachable, and the escape hatch;
`tests/worker.test.sh` and `tests/review.test.sh` check the hatch end to
end. None of that runs a real vendor, and CI runs only Linux: that is how
T-105 went green and still locked every vendor out. So `bin/fm-canary.sh`,
not part of CI, runs one real round per installed vendor on the operator's
Mac, under the sandbox, and reports each `started`, `authenticated`,
`refused`, or `skipped` (not installed, or not logged in - never a pass).
Its probe tries to write outside, read `~/.ssh`, reach github.com and
127.0.0.1:4173, connect to the Herdr socket, read another round's temp
directory, read gh's token and git's credential for github.com, and on
macOS read a keychain item and the pasteboard fm filled with a nonce; it
checks that the round can use a loopback port it opened itself, and records
the result per vendor and version in `state/canary/results.jsonl`. It exits
0 only when a vendor ran and every vendor that ran started, signed in and
had every probe blocked. Firstmate runs it on the captain's Mac through
`fm doctor --sandbox` (13.3) before the merge card of any change to the
sandbox or an adapter, and puts that output in the pull request; the merge
gate reads it with the required check and the gates.
**It runs each vendor exactly as a worker round would (T-127)**, model
included: it resolves `config.yaml`'s worker model once and hands it in as
`FM_MODEL` for every vendor's probe, the same way a real worker round would -
which is deliberate, since the captain's finding that started T-127 was
exactly this gap surfacing nowhere, on a hand re-dispatch across three
vendors. It reads the model each CLI actually reported back beside its
version, and prints both next to the verdict; a model that vendor refuses is
reported `refused` with the message named, the same as any other
before-the-round refusal.

### 13.2 A round cannot destroy its own work (T-128)

**Why, from first principles.** On 2026-09-27, four crew rounds lost their
whole working tree mid-round: T-121, T-126 and T-127 workers, and T-107 and
T-123 reviewers. In each case, code running inside the round deleted it - a
test that turned an empty variable into the current directory and `rm -rf`ed
it. Fixing our own tests removes one trigger, but it cannot protect an
external project, whose tests, build scripts and package hooks firstmate does
not control, and it cannot protect against the model's own commands either.
The root cause is structural: the only copy of the round's work lived in the
one directory that arbitrary code in the round may write, the worktree,
which is a write root by design. A second, contributing cause: the sandbox
made ordinary defaults fail - bare `mktemp -d` fell back to a per-user temp
dir that was not a write root, which pushed code into untested error paths.
The invariant this section establishes, for the self project and for every
external project alike: **the work a round produces survives whatever runs
in the round, and a round's environment is normal enough that ordinary code
takes its ordinary paths.** The captain approved this on 2026-09-27; it is a
prerequisite of T-055, the first external project.

**The mirror: work kept where the round cannot write.** While a worker round
runs, `fm-worker.sh` - outside the sandbox, like the rest of it - keeps a
mirror of the worktree at `state/mirrors/<project>/<task>/<generation>`.
`<project>` is read from the tree's own path when it sits under a project's
managed clone (`state/projects/<name>/...`), else `FM_PROJECT`, else `self`;
the mechanism is identical for the self project (`repo: .`, worktrees under
`state/worktrees`) and for an external one (worktrees of the managed clone
under `state/projects/<name>/`). A mirror generation excludes `.git` - never
itself the round's work, and protected a different way, below - and the
project's own `.gitignore` when the worktree has one, the same build caches
git itself would not track. It is written by copying the worktree wholesale
for the first generation, trying a copy-on-write clone first where the
filesystem offers one (APFS `clonefile`, or `cp --reflink=auto` on a Linux
filesystem that supports it) before falling back to `rsync`; every later
generation is an `rsync --link-dest` against the previous one, so hard-links
carry an unchanged file forward at no cost and only what changed is written
fresh. A mirror update never writes into the worktree - the one thing that
does, restoring, is described next - and keeps the last three generations,
so a slow corruption (files emptied rather than deleted, not only a file
outright removed) can be rolled back past.

Updates happen twice over: once before the round's adapter starts, so a
generation exists even if the very first thing the round does is destroy
the tree, and then on a short poll (every ten seconds by default,
`FM_MIRROR_INTERVAL`) from a background watcher that runs for as long as the
adapter does - a fixed interval, not fsevents or inotify, portable to both
platforms and simple enough to reason about; the interval keeps the
detection-to-restoration lag well under the roughly thirty seconds the
design allows. A final check runs once more when the round ends, since the
watcher polls and the very end of a round can land in the gap between two
ticks. The watcher itself checks for the round's own shutdown signal once a
second while it waits out the rest of the interval, so a round that ends
well inside it - the common case, most rounds far shorter than ten seconds -
is not held up waiting for the watcher; only the sync/restore check itself
still runs at most once per interval. The same one-second check also covers
a round killed outright: SIGKILL runs no trap, so `fm-worker.sh` never
reaches its own shutdown signal, and the watcher would otherwise run forever
as an orphan, still writing into `state/`. It checks its own parent is still
alive (`kill -0`, the pid `$$` already names inside the backgrounded
subshell) alongside the stop file, so it notices within the same tick and
exits instead (round 4 review).

**Detect and restore.** Each check (`mirror_health` in `bin/fm-worker.sh`)
asks whether the tree looks as it should: present, its `.git` link intact,
and neither its file count nor its total bytes down by more than half from
what the last mirror generation saw - unless `HEAD` has moved since, because
a real commit legitimately removing files is not a wreck. Whether `.git` is
intact is asked of git itself (`tree_git_ok`, `git -C "$tree" rev-parse -q
--verify HEAD`), not guessed from a path or a file type - a worktree's `.git`
is a file, a clone's is a directory, and a test fixture's stub git may lay
down neither, and all three must be judged the same way (round 5 review, a
false "its .git link is gone" against exactly such a fixture lost a live
round's own uncommitted work to a stale restore). `GIT_CEILING_DIRECTORIES`
is set to the tree's own parent for that check, since every real worktree
sits nested inside its own repository's working copy: without it, a
worktree whose `.git` really has gone missing would have git's own
directory search walk up and find the enclosing repository instead, and
answer for that one - a false negative undoing the very detection this
exists for. When the tree does not look as it should, `mirror_restore` keeps
the wreck aside under `state/rescued/`, then merges the latest mirror
generation into the tree with `rsync -au` - never wiping the tree first, as
an earlier round did: a file the round wrote since that generation is newer
than the mirror's copy, and `-u`/`--update` leaves anything already as new
or newer alone, filling in only what is missing or older, with no `--delete`
to ever remove what the round itself put there (round 5 review: a restore
that costs a file the tree already had is worse than no restore). It then
repairs the worktree's `.git` link with `git worktree repair` when
`tree_git_ok` still says no - the object database and the worktree's admin
directory live in the repository's common `.git`, which is never inside the
write roots (design 13.1), so whatever a round deletes, `git` in that tree
still works and every committed change survives. A worker round that finds
its tree restored mid-run is told so in its next prompt, not left to notice
on its own, and the round that destroyed its own tree is reported as exactly
that - `destroyed its own tree rather than changing nothing` - never as one
that changed nothing, which is a different and much less alarming thing to
have happened.

`bin/fm-emit.sh`'s `TYPES` enum is outside this task's own scope (its file
is not in `design/tasks/T-128.json`'s `scope`), so there is no
`worktree_restored` event type of its own yet. What the design calls that
event rides the existing `worker_crashed` type - already the type for "an
earlier round left something behind that this one found and saved" - named
precisely by `.data.event_kind: "worktree_restored"`, with `en` and `zh-TW`
summaries and the round's actor, exactly as any other board-facing event
carries them (section 9). A later task that is in scope for
`bin/fm-emit.sh` can give it a type of its own without changing anything
that reads `.data.event_kind` today. Review checkouts get the same
treatment for the analogous `review_checkout_destroyed`, below.

**The tree's link to git cannot be destroyed from inside - a worker's
worktree only.** The sandbox profile denies deleting or rewriting a
worktree's own `.git`, after the write-roots allow, since SBPL is
last-rule-wins - a read-only bind on Linux, over the round's own read-write
root. On macOS this names exactly that path: a literal deny (`own_git_sbpl`,
`bin/fm-sandbox.sh`), never the unanchored prefix regex `prefix()` uses
elsewhere for a vendor's own rewritten state files, which would also deny
`.gitignore`, `.gitattributes`, `.gitmodules` and everything under
`.github/`, all of them siblings that merely start with the same four
characters (round 1 review). This is narrower than the write roots' own
reach: a round may still delete everything else in its tree, including the
tree's own directory once emptied, but not this one path, which is what
lets `git` still answer inside whatever is left. An external round's
pinned-folder deny covers the whole project home, so on macOS the profile
re-allows read (only read) of the round's own git directories under it after
that deny. Linux needs no additional rule because it never hides that home.
`tests/sandbox.test.sh` asserts the generated profile and bwrap arguments
carry this on every host,
and, only on a host that can actually nest a real sandbox (never inside
another one, which is why the rest of the suite uses a stand-in - design
13.1), runs it for real, in the block guarded by `real_sandbox_ok`: inside
`fm-sandbox.sh run`, `rm -rf "$tree"` leaves `.git` and `git -C $tree status`
still works, and, in the same block, a write to `.gitignore` and to
`.github/workflows/ci.yml` succeeds while `.git` itself stays denied.

A review checkout's `.git` is not protected the same way (round 4 review): a
plain `git clone` makes `.git` a whole directory holding the object database
and the index, not a pointer elsewhere, and ordinary git commands write
inside it - `git checkout`, `git add`, `git commit` all touch `.git/index`.
Denying writes there as a `subpath`, as an earlier round did, stops exactly
those ordinary commands, including the review protocol's own fail-first
step; `own_git` (`bin/fm-sandbox.sh`) only ever returns a worktree's link
*file*, never a clone's directory, so no deny rule is generated for it at
all. A clone is a review checkout, disposable by design (below): the
protection a directory `.git` gets is `fm-review.sh`'s own retry, not write
denial. `tests/sandbox.test.sh`'s `real_sandbox_ok` block proves both halves
in the same run: `git checkout <ref> -- <path>` succeeds in a clone
checkout, next to the worktree's `rm -rf`/`.gitignore` assertions above.

**A normal environment inside every round.** Every round, worker or
reviewer, self or external, gets its own writable `HOME`, `TMPDIR` (already
a write root since T-105/T-117; also the value bare `mktemp -d` resolves to
on macOS), and `XDG_CACHE_HOME`/`XDG_DATA_HOME`, all under the round's own
temp directory - the one place both `fm-sandbox.sh run` and `plain` pass
through, so the guarantee holds whatever called it, the adapter layer or a
direct invocation, and whatever the caller or the operator's own shell had
set them to. The toolchain's own caches (`FM_ROUND_CACHES` in
`bin/adapters/_lib.sh`, T-117) already pointed into the same directory.
`mktemp -d`, `mktemp -t`, `~/.cache`, and `npm`/`bun`/`pip` defaults all
succeed without a special-cased path; the same real-sandbox check in
`tests/sandbox.test.sh` proves it, alongside the `.git` denial, in the one
round it makes.

`XDG_CONFIG_HOME` is the one exception, left exactly as the caller had it
(round 4 review): a vendor's own config directory is already a separate,
existing contract, set per adapter, not by a generic XDG variable here -
`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, gemini's own `HOME`. cursor-agent has no
config-directory variable of its own at all (its login is `CURSOR_API_KEY`);
overriding `XDG_CONFIG_HOME` here too would move it off wherever the
caller's environment already put it, which
`tests/adapter-contract.test.sh`'s "cursor-agent is handed no
`XDG_CONFIG_HOME` of fm's" asserts against directly, one instance of the
broader rule that this task adds a normal environment without changing an
existing per-vendor contract. `HOME` still moves, so `~/.config` (the XDG
default when `XDG_CONFIG_HOME` is unset) already moves with it for anything
that falls back to that default; `tests/sandbox.test.sh` asserts the round is
handed the caller's own `XDG_CONFIG_HOME` unchanged, next to the `HOME`/
`XDG_CACHE_HOME`/`XDG_DATA_HOME` assertions above it.

**The shell a vendor runs commands through (T-147).** The first codex
worker round (T-146, 2026-09-29) stopped at once and changed nothing, and
T-157's first codex round (2026-09-30) stopped the same way; claude rounds
on the same machine met neither. codex runs every command as `$SHELL -lc
<command>`, the operator's own login shell, and two things of that shell
fell outside what T-128 gave a round:

- zsh writes a here-document's temp file under `TMPPREFIX`, `/tmp/zsh` by
  default, not `TMPDIR`, and the sandbox refused it (`can't create temp
  file for here document: operation not permitted`). Every round's
  environment now sets `TMPPREFIX` to `<round tmp>/zsh`. bash, ksh and dash
  already follow `TMPDIR` or use a pipe, so no other shell needs one.
- A login shell runs the system's profile first. On macOS `/etc/zprofile`
  and `/etc/profile` run `path_helper`, which rebuilds `PATH` with
  `/usr/bin` ahead of every directory the operator added (Homebrew's,
  mise's), and Debian's `/etc/profile` resets it. So `git` in the round was
  `/usr/bin/git`, Apple's xcrun shim, where the operator's own shell finds
  their git. The round's `HOME` is its own, so its profile is fm's:
  `fm-sandbox.sh` writes `.zprofile`, `.bash_profile` and `.profile` there,
  each putting back `SANDBOX_ROUND_PATH` - the `PATH` the round was given -
  after the system's profile has run, and sets `ZDOTDIR` to that `HOME`
  so zsh reads it rather than an operator's `ZDOTDIR` the round cannot
  read. This holds for every vendor, whether its shell is a login shell or
  not, so the codex adapter needs no flag of codex's for it.

**Apple's xcrun shims.** `/usr/bin/git`, `/usr/bin/python3` and the other
developer tools on macOS are launchers linked against `libxcselect` that
ask xcrun for the real tool in the active developer directory. Inside a
round a shim cannot work: xcrun writes its cache (`xcrun_db-*`) under the
per-user temp directory `confstr` names, outside every write root, and with
the Xcode licence not accepted it then stops on that. So before a macOS
round, for each of `FM_XCRUN_TOOLS` (git, python3, pip3, make, cc, clang)
whose first match on the round's `PATH` is a shim (`fm_xcrun_shim`: the
file names `libxcselect`), `fm-sandbox.sh` asks xcrun, outside the round,
for the tool it would run (`fm_xcrun_resolve`: `xcode-select -p` first,
which never opens the installer dialog a shim would, then `xcrun --find`).
A stand-in ahead of the shim on the round's `PATH` then runs that tool
directly - the one the shim would have run, under a licence already
accepted - and the round's log says which. Where xcrun has none to give, no
developer directory or the licence not accepted, the stand-in prints what
xcrun said, that nothing inside the round can fix it, and how the operator
does (`fm_xcrun_fix`), and exits 69 at once: the round is told plainly
instead of failing on a cache write and a licence prompt it cannot answer.
`fm doctor` reports a machine whose first `git` or `python3` on PATH is a
shim, from the same `fm_xcrun_shim` and `fm_path_tool`: an `x` line saying
`wrong version`, naming the file as Apple's xcrun shim, with
`fm_xcrun_fix`'s line as the fix, and never `ok`. It checks those two and
no other tool, so the stand-in's message says "fm doctor reports it" only
for them. `tests/doctor.test.sh` covers a shim first on PATH, and a real
tool ahead of one. `tests/adapter-contract.test.sh` runs the codex adapter with a codex
that answers as the real CLI does, through `$SHELL -lc`, and a shell that
plays zsh in exactly those two ways: a here-document and `git status`
succeed in the round, and a machine whose only git is a shim is reported,
not hung.

**Review checkouts are disposable.** Unlike a worker's branch, there is
nothing in a run-mode checkout worth mirroring - only worth noticing and
rebuilding. When `checkout_ok` (`bin/fm-review.sh`) finds the checkout gone
or its `.git` no longer answering after an attempt, the round reports it,
records the analogous event (`worker_crashed`, `.data.event_kind:
"review_checkout_destroyed"`, the same scope reasoning as above), rebuilds
the checkout at the same path the prompt already named - never a fresh
`mktemp`, which would send the reviewer to a directory it was never told
about - and retries the chain once. A checkout destroyed again on the retry
is not retried a second time: the round ends the way any other run that
produced no signed verdict does.

**Proved for both kinds of project.** `bin/fm-canary.sh --sections=destroy`
(the default sections are `vendors,destroy`; `tests/canary.test.sh` asks for
`destroy` alone, so it spends no model call and needs no vendor logged in)
runs a scripted hostile workload - never a real vendor's improvisation,
since destruction has to be exact and repeatable to prove recovery rather
than luck - against two throwaway fixtures of its own, never the operator's
checkout: the self project's shape, and an external project cloned through
`fm-project.sh sync` from a local bare repository standing in for GitHub
(`FM_GITHUB_URL`), exactly the mechanism design 15.1 describes for a target.
Five hostile modes, run through a stand-in adapter
(`tests/fixtures/hostile-adapter/`) rather than `bin/adapters/mock.sh`
itself, which stays exactly what every other test expects it to be: delete
the whole tree; delete only `.git`; `rm -rf "$EMPTY$tree"`, an empty
variable built into a destructive command the same way the four real
incidents were, bounded to this round's own tree by construction rather
than the literal unconfined `rm -rf "$EMPTY/"`, which only a real OS sandbox
can run safely (that shape is what the real-sandbox check above proves,
under genuine kernel confinement); truncate files in place; and fill the
round's own temp directory. For `tree`, `git` and the empty-variable mode,
which unmistakably wreck the tree, it asserts a `worktree_restored` event,
naming the actor, with both languages; committed work survives every mode
(the tree's own `HEAD`, `.git`, and `git status` all still answer); a file
written just before the wreck reaches the round's own commit, proving
uncommitted work is restored from the mirror within the lag; `truncate` and
`fill-tmp` do not touch enough of a small fixture's files to cross the
file-or-byte-loss threshold live, which is exactly why generations are kept
- a slow corruption is rolled back past, not necessarily caught by this
round's own live restore. Firstmate runs `fm doctor --sandbox` at the
merge gate for any change here: it runs the canary's default sections, this
one and the per-vendor probes, and fails when the canary does; workers do not
run the suite themselves.

### 13.3 Setup, doctor and the vendor probe (T-121)

**Why.** On 2026-09-26/27 the captain lost hours to things a doctor would
have said up front: codex out of quota, found only when a canary round
failed; gemini's OAuth expired; cursor unable to `agent login` inside the
sandbox; a stray `bin/__pycache__` making a worktree look dirty. This
absorbs the doctor part of T-078 without its plugin layout; T-079 now
depends on this task instead.

**The toolchain.** `mise.toml` pins every tool `bin/ci.sh` or the
board calls - bun, node, python, jq, gh and shellcheck; jq and gh through
mise's `ubi:` backend, which has no core plugin for either. node because
`bin/ci.sh` runs `bunx playwright test`, and playwright's CLI is
`#!/usr/bin/env node`; shellcheck because `bin/ci.sh` skips its shellcheck
stage on a host without it, so that host would pass a stage it never ran
(T-121 round 6's review). `fm-doctor.sh` holds the same list
(`REQUIRED_PINS`) and reports a `mise.toml` that pins none of one of them,
not only a tool missing from `PATH`. git and perl (`bin/ci.sh` times its
suites with perl) are the system's own: doctor checks them, unpinned. `bin/fm-doctor.sh` reads the pins, compares them against
what is on `PATH` (a dotted, numeric "at least this version" comparison,
never exact-match), and prints the acceptance's own words beside its symbol -
`+ ok`, `x missing`, `x wrong version` (older than the pin), or `!
version unreadable` - with the one command that closes the gap. It installs nothing on its own: `--fix` asks, per tool, before running
`mise install <tool>@<pin>`. Like every script that starts a child, it
closes its standard input (`exec < /dev/null`), so no child reads the
operator's typing; the operator's answers are read from a copy of the
original stdin kept on fd 9, and only `fm setup`, which asks, is handed it.
Folded in from T-078: git, herdr and the OS sandbox tool
(`sandbox-exec`/`bwrap`) are checked the same way, with an OS-specific
install line for each, since mise does not manage them. Which sandbox tool
is checked is decided the way `bin/fm-sandbox.sh`'s `host_os` and
`host_tool` decide it - `FM_SANDBOX_OS`, else `uname`; then
`FM_SANDBOX_TOOL`, else that platform's own tool - so doctor and the sandbox
never disagree about the tool a host uses (T-121 round 15). Doctor's and
setup's suites run on a `PATH` of their own fakes plus links to the host's
`/usr/bin` and `/bin` with every name doctor or setup asks about taken out,
so a tool a test leaves out is missing on every host. A vendor CLI that
is not installed gets the same treatment in the vendor logins section
below: its own published install line, not only that it is missing - each
line is the vendor's own documented installer at the time this was
written, not re-verified live the way the toolchain versions above are.

**Too old.** Where a version matters, doctor has a floor, and a tool older
than it is `x wrong version` with its install line:

- herdr: 0.9.1, the floor firstmate's round-8 brief for this task gave (it
  names design.md's host section as its source, but no section here states
  a herdr version; this is where it is written down now).
- claude 2.1.284, codex 0.155.1, cursor-agent 2026.10.01: the login check
  the probe runs has to exist, and these are the versions its recorded
  transcripts (`tests/fixtures/auth-status`, 2026-09-29 for claude/codex,
  2026-10-05 for cursor-agent) came from. The
  vendors' changelogs and `--help` histories could not be read where these
  were recorded (the worker round had no network), so the first version that
  had each command is not known and each floor may be later than it has to
  be; a transcript recorded from an older version lowers it.
  `tests/doctor.test.sh` keeps each floor equal to its transcript's version.
- gemini: none. The probe runs nothing of gemini's but `--version`, so no
  version of it is too old for anything firstmate asks of it.
- git, perl and the OS sandbox tool: none. firstmate uses nothing of git's
  newer than what every supported OS ships, perl only times suites, and
  `sandbox-exec` and `bwrap` have no version firstmate depends on.

**The vendor probe asks about the round's login, not the operator's.**
`bin/fm-auth-probe.sh <vendor>` answers one question: would the login a
crew round of this vendor gets work right now. So it does not look for a
login of its own. It resolves the credential exactly as the round will get
it, through `fm-sandbox.sh`'s own lookup - `fm-sandbox.sh login-env`, which
runs the same `login` step `run` hands a round its login with: claude's
crew token, or the interactive fallback (T-126); cursor-agent's
`firstmate-cursor-api-key` item or `~/.config/firstmate/cursor-api-key` as
`CURSOR_API_KEY`; codex's `auth.json`, copied less its refresh token into
a `CODEX_HOME` of the probe's own; gemini's `oauth_creds.json` the same
way. With no login a round could use, the answer is `unauthenticated` (or
`expired`, when the lookup says so) with `fm-sandbox.sh`'s own reason, and
the vendor's CLI is never asked: an operator whose own `agent login` works
but who never kept a crew key has no working cursor-agent round, and the
probe says so. Round 4's probe, which asked each CLI about whatever session
the operator's shell had, answered the wrong question both ways - it
refused a keychain-only cursor setup that works and admitted an `agent
login` that no round can use.

With a login, the vendor's own check runs - `claude auth status`,
`codex login status`, `cursor-agent --list-models` (which reads the crew
API key, unlike `status`) - with a fixed argv (never
`FM_ADAPTER_ARGS` or anything else configurable), stdin closed, and an
environment emptied but for `HOME`, `PATH`, `TMPDIR`, `USER` and `LOGNAME`
- `HOME` and `TMPDIR` the probe's own, as a round's are (T-128) - plus
exactly the credentials `login-env` wrote and the vendor's own config
directory where the adapter points it (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`).
Credentials are exported, never put on a command line. A variable the
round sheds (below) is neither counted as a login nor handed to the probe.
The check has a time limit (`FM_AUTH_PROBE_TIMEOUT`, default 20s; no
`timeout(1)` is assumed, since macOS has none). It runs in the foreground
under a small Python runner, never in the background with its pid polled
(T-151). The runner blocks until the kernel reports the first of three
events (`fm_lifeline.py`'s `ProcessExit`: kqueue on macOS, a pidfd on
Linux): the check exits, the limit passes, or the probe dies. When the
limit passes or the probe dies, the runner ends the check's whole process
group, SIGTERM and then SIGKILL a second later. So nothing the check started
outlives the probe, even a probe killed with SIGKILL, where no trap runs. A
probe sent SIGTERM runs its trap once the runner returns, which is at most
the limit later. It prints exactly one of `authenticated`,
`unauthenticated`, `expired`, `quota-exhausted`, `keychain-blocked`, `indeterminate`, `timeout`
or `unavailable` (not installed), the vendor version it probed, and a
one-line reason in English and Traditional Chinese - never the vendor CLI's
own output or a secret. claude's status check, verified live, answers with
one JSON object holding a boolean `loggedIn` (recorded, signed in and
signed out, in `tests/fixtures/auth-status`), parsed rather than
pattern-matched; it says whether a credential is there (a
`CLAUDE_CODE_OAUTH_TOKEN` reads `loggedIn: true` without being checked
against the service), not whether the service takes it, which is left to
the round's own outage signatures. codex's and cursor-agent's plain-text
answers are read with the same kind of phrase list the adapters use
(`_FM_SIG`), narrowed to what a status check itself says.

On macOS, only the cursor-agent model-list check runs through `sandbox-exec`
(or `FM_SANDBOX_TOOL`), using a minimal allow-default profile with the same
`SECRET_SERVICES` mach-lookup denial as crew rounds. `FM_SANDBOX_OS` defaults
to the real platform. Both settings are resolved before the environment is
emptied; HOME remains the probe's empty temporary home. The confined shell
writes `$work/started` before executing `cursor-agent --list-models`. A missing tool
or a wrapper that exits without the marker fails closed as `keychain-blocked`
("could not confine cursor-agent's keychain access" / "無法限制 cursor-agent 的鑰匙圈存取");
cursor-agent never runs unconfined as a fallback. A timeout takes precedence,
even when the wrapper never writes the marker. Linux runs the check unwrapped.

For cursor-agent's own answer (T-195), after timeout and confinement failure,
classification checks quota exhaustion, expiry, exit 0 with a line exactly
`Available models`, `The provided API key is invalid`, a case-insensitive
`keychain` with nonzero exit, the usual unauthenticated signatures, then
`indeterminate`. The model-list success wins over the recorded keychain-save
warning. Neither `Logged in`, exit 0 alone, nor a nonzero model list confirms
the key. A nonzero keychain error remains `keychain-blocked`, with reasons
"cursor-agent tried to store its login in the keychain, which crew rounds deny; this cursor-agent version may no longer honour AGENT_CLI_CREDENTIAL_STORE=memory; run fm doctor" and
"cursor-agent 試圖把登入存進鑰匙圈，而 crew 回合禁止存取鑰匙圈；此版本的 cursor-agent 可能已不支援 AGENT_CLI_CREDENTIAL_STORE=memory；請執行 fm doctor". Other vendors' ordering is unchanged.
Cursor rounds, the probe and the adapter's model-list check run with
`AGENT_CLI_CREDENTIAL_STORE=memory`, so cursor never stores or reads a login
in the keychain, the adapter check is silent without a `CURSOR_API_KEY`, and
fm doctor checks the installed bundle still names the variable.

Cursor's reasons distinguish three failures, in English and Traditional Chinese:

- Only login-env exit 77 with `why` starting with `no ` means every crew source
  is missing: "no crew Cursor API key is stored; cursor-agent's own sign-in
  (agent login) lives in the macOS keychain, which crew rounds cannot read" /
  "尚未保存 crew 的 Cursor API key；cursor-agent 自己的登入（agent login）存在 macOS 鑰匙圈，crew 回合無法讀取",
  followed by the existing policy hint. Darwin names the missing item and
  absolute file path; Linux names the absolute file path alone. Other exit-77
  refusals retain the original actionable reason (unreadable, empty, unsafe
  permissions or unreachable store). The probe never asks whether the
  operator's own keychain login works.
- An invalid key is `unauthenticated`: "cursor rejected the crew Cursor API key
  as invalid; replace it: security add-generic-password -U -s firstmate-cursor-api-key -a "$USER" -w" /
  "cursor 判定 crew 的 Cursor API key 無效；請更換：security add-generic-password -U -s firstmate-cursor-api-key -a "$USER" -w".
  `-U` replaces the existing item.
- Authentication required with a key supplied is `unauthenticated`:
  "cursor-agent did not receive the crew Cursor API key; run fm doctor" /
  "cursor-agent 沒有收到 crew 的 Cursor API key；請執行 fm doctor".

Success says "cursor-agent's model list confirms the crew Cursor API key" /
"cursor-agent 的模型清單確認 crew 的 Cursor API key 有效". These reasons are emitted
only through `print_result`; no vendor output or secret is printed.

No keychain or preference is created or changed. The marker lives inside the
probe's `$work`, removed on EXIT, INT, TERM and HUP. SIGKILL leaves that
scratch directory for the OS's temporary-directory cleanup, as before; there
is no sibling-directory sweep or owner file. Historical `vendor_unavailable`
events stay byte-identical and are never consulted for an auth decision.
Every `fm_auth_probe` call asks afresh, while `fm_auth_filter_chain` truncates
its scratch notes file and fills it with only the current call's refusals.
No stored format or migration is needed (T-188).

gemini is the one vendor whose status is never asked: its docs and every
transcript this repository carries name no non-interactive status command,
only the interactive `/auth` command. Round 2 shipped `gemini auth status`,
guessed by symmetry with codex's `login status`; round 3's review rejected
it - a guessed argv answers a question nobody asked gemini. So gemini's
login is resolved like any other vendor's (none is `unauthenticated`, an
expired one `expired`), and with one present the answer is `indeterminate`
("gemini's login cannot be verified, so rounds on it are refused"); nothing
of gemini's runs but `--version`. A later task that finds gemini's real
status command replaces this, and gemini becomes usable then.

**Only `authenticated` is usable.** `indeterminate` is never read as
authenticated. `bin/fm-worker.sh` and `bin/fm-review.sh` call the probe for
every vendor in their chain that it knows (`fm_vendors`,
`bin/fm-config.sh`: claude, codex, cursor-agent, gemini) before any of them
sees a prompt (`fm_auth_filter_chain`, `bin/adapters/_lib.sh`). Every
answer but `authenticated` (`fm_auth_refuses`) - `unauthenticated`,
`expired`, `quota-exhausted`, `keychain-blocked`, `indeterminate`, `timeout`, `unavailable`, or
no answer at all - refuses the vendor for this round, exactly as
`fm_run_chain` treats an outage: moved past, never started, and put on the
board as `vendor_unavailable` naming the status and the probe's reason
("<vendor>: <status>: <reason>", and "<vendor>：<status>：<reason>"), whose
authored `en`/`zh-TW` summary the board's log renders like any other
event's. The chain then moves on to its next vendor. So gemini is
unavailable until its status can be verified. A vendor the probe does not
know - `mock`, or a name `fm_run_chain` reports as a configuration error -
passes through unprobed. A chain with nothing left reaches `fm_run_chain`
empty, which already returns "every vendor was unavailable" (rc 2).
`fm doctor` applies the same rule: `+` for `authenticated`, `x` for
anything else, with the probe's status and reason in English and in
Traditional Chinese - for gemini, that its login cannot be verified, so
rounds on it are refused.

**Credentials that outrank the subscription are shed.** claude documents
`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_USE_BEDROCK` and
`CLAUDE_CODE_USE_VERTEX` as switching which account or billing it uses
ahead of a stored login; codex `OPENAI_API_KEY` and `CODEX_API_KEY`; gemini
`GEMINI_API_KEY` and `GOOGLE_API_KEY`. Left in the operator's shell for
their own use, any of them would bill a crew round to it without anyone
choosing that. One list (`fm_adapter_outranking`, `bin/adapters/_lib.sh`)
is shed from every round of that vendor unless `config.yaml`'s `billing:`
block names the vendor for api-key billing (`fm_adapter_shed`,
`fm_adapter_billing`). cursor-agent has no such list: `CURSOR_API_KEY` is the
only login this design hands a cursor-agent round.

Every other vendor's credentials are shed too, whatever `billing:` says
(`fm_adapter_credentials`: a vendor's outranking list plus the variable fm
hands its login in, `CLAUDE_CODE_OAUTH_TOKEN` or `CURSOR_API_KEY`). A claude
round has no use for a `CURSOR_API_KEY` or an `OPENAI_API_KEY` left in the
operator's shell, and until round 8 it inherited both: the policy scrub names
cloud and GitHub credentials, not the vendors'. So a round's environment
holds exactly the credential its policy names - claude only
`CLAUDE_CODE_OAUTH_TOKEN`, cursor-agent only `CURSOR_API_KEY`, codex no
variable but the copy of `auth.json` in its `CODEX_HOME`, gemini the copy of
its login file and `GOOGLE_GENAI_USE_GCA=true` - which
`tests/adapter-contract.test.sh` checks per vendor with every vendor's
variables ambient at once.

Shedding is done in two places that agree, so a round is never left with
neither credential. The adapter wraps the vendor's CLI in `env -u` for each
name (`fm_adapter_env_words`), and passes each to `fm-sandbox.sh` as
`--shed=<NAME>` (`fm_adapter_confine`). `fm-sandbox.sh` then does not count
a shed variable as a `given` login - `login_of` skips it - so it reads the
crew token (or the fallback) and hands it in as `CLAUDE_CODE_OAUTH_TOKEN`,
and it scrubs the variable from the round itself. Before this, `given` saw
the ambient `ANTHROPIC_API_KEY`, wrote no token, and the adapter's `env -u`
then started the round with no credential at all (T-121 round 4's review,
finding 3). `login-source` and `login-env` take the same `--shed`, so
`fm-canary.sh`'s login line and the probe read the login exactly as the
round gets it. `fm doctor` still warns when such a variable is set in the
operator's shell, because it changes billing for their own interactive use
too.

For codex and gemini every `given` variable is one of these, so with no
`billing:` entry their round signs in only with the copy of the login file
(`~/.codex/auth.json`, `~/.gemini/oauth_creds.json`); an API key alone in
the shell is no login of the round's, and the round is refused as not
logged in rather than billed per use. `tests/adapter-contract.test.sh`
therefore gives codex and gemini a login file in a home of its own, not an
ambient key: its earlier `CODEX_API_KEY`/`GEMINI_API_KEY` stand-ins were
shed like any other and left every codex round in the suite unavailable
(T-121 round 7, CI shard 3).

**First run.** `bin/fm-setup.sh` asks only what firstmate cannot find out
for itself, each with a recommended default that Enter accepts: which
installed vendor crews as worker and as reviewer (a different installed one
recommended for review when two are usable); whether each bills to its
subscription or per API use; the main repository and base branch (checking
`gh auth status` and, where `gh` can say, push rights); the board port
(default 4173) and language (`en` or `zh-TW`, default `en`). Existing port
and language settings become the defaults on re-run (T-154). Setup refuses
an occupied port unless a nonce verifies this repository's board, including
a listener that does not speak HTTP. No configuration is written on refusal. `--answers FILE` (`key: value`,
one per line, read with `fm_cfg`, the same reader as `config.yaml`) answers
a question without a prompt; a key that file does not name is still asked,
so a file naming nothing is "every default", which is also what a closed
stdin gets with no answers file at all. The installed vendors come from
`fm_vendors`, the one list. It writes `config.yaml` and runs
`fm doctor --sandbox`. It is never asked to
overwrite what it does not own: an existing `config.yaml`'s `policy:`,
`project:`, `projects:`, `notifications:`, `fallback:` blocks and any other
top-level key survive a re-run untouched, and only what was answered - the
worker and reviewer vendor, an api-key billing choice, the project's
repository and base, board port and language - is added or replaced, through `fm_cfg_set` (`bin/fm-config.sh`, the
one writer beside the one reader), which creates every block and key along
a dotted path that is missing and touches nothing else, and changes only a
value, keeping the line's own spacing and comment (a value already set is
not touched at all). No model is written - there is no model question, and
a model name is the vendor's own - and one chosen for another vendor is
said, not changed. The reviewer's mode is never asked and is kept (diff when
unset, `fm-review.sh`'s default), with one thing found out rather than
asked: `fm-review.sh` refuses every round (exit 65) when the mode is `run`
and the reviewer's adapter has no `# fm:review-run` line, so a kept `run`
with such a reviewer (codex, cursor-agent, gemini) becomes `diff`, and the
wizard says so. Round 7's wizard wrote `mode: run` and `model: opus-5`
whatever was chosen, which is what round 7's review found. It never asks for or stores
a secret itself: for a key (cursor-agent's crew API key) it prints the exact
keychain command the operator runs themselves - `fm-config.sh`'s own `hint`
for that vendor.

`fm doctor` itself hands off to `fm setup` when `config.yaml` does not
exist yet, rather than asking anything itself.

**Sandbox reality check.** `fm doctor --sandbox` runs `bin/fm-canary.sh`
(changed to pass the round's `--shed` list to its `login-source` line, and
to tag every record with a `run` id, `FM_CANARY_RUN` when the caller hands
one in) and summarises this run's records in `state/canary/results.jsonl`,
picked by that id, never by "the last N lines". Every line is read from the
field it describes: `started, authenticated, every probe blocked` only when
no entry of `probes` is `reached` and every one is `blocked` (or `n/a`); a
reached probe is `x`, named; an untested one is `x` too, since untested is
not blocked; `own_loopback` gets a line of its own per vendor - works,
blocked, or untested. A run that wrote no record is `x`. A failure gets the
one-time `security add-generic-password` step for cursor, "start gemini
once outside a round" for an expired login, and the quota reset time when
the vendor's own message names one (`fm_auth_quota_reset`).

**Repository hygiene.** `.gitignore` ignores `__pycache__/`. What makes
firstmate's sync skip a worktree is what `git status` shows in it, so `fm
doctor` asks git, per worktree under `state/worktrees` (`git status
--porcelain --untracked-files=all`), and flags each untracked build cache
directory it lists - `__pycache__`, `.pytest_cache`, `.mypy_cache`,
`.ruff_cache`, `.tox`, `.nox`, `.eslintcache`, `.parcel-cache`, `.turbo`,
`node_modules/.cache` - once per directory, naming the worktree. One the
worktree's own `.gitignore` ignores is never shown by git, so it is not
flagged; ordinary untracked work is never named.

**Evidence.** `tests/auth-probe.test.sh` runs the probe against fake vendor
CLIs that replay the recorded transcripts in `tests/fixtures/auth-status`
(`replay.sh` prints a recording's answer and exits with its recorded
code): `claude auth status` signed in and signed out, `codex login status`
signed in and signed out, and `cursor-agent --list-models` with a working key,
no key and a rejected key. Each recording names its CLI version, date, host,
setup, redaction and exit code. The 2026-10-05 host recording used Cursor
2026.10.01-e373342 on macOS Darwin 24.6.0, outside a round, with `env -i`,
an empty temporary HOME and the auth-probe sandbox profile. `status` ignored
`CURSOR_API_KEY`: absent, placeholder and working keys all returned
`Not logged in`, exit 0. The older signed-in status recording reflected the
operator's keychain session. `--list-models` reads the key: no key returned
`Authentication required`, exit 1; the placeholder returned
`The provided API key is invalid`, exit 1; the working key returned
`Available models`, exit 0, after a keychain-save warning. The fourth Cursor
recording, with the working key and `AGENT_CLI_CREDENTIAL_STORE=memory`,
returned `Available models`, exit 0, with no keychain-save warning.
The suite checks the fixed
argv, the closed stdin, the scrubbed environment, the timeout, and that
nothing of the vendor's own output or a secret reaches this script's own
stdout. The operator's home and keychain are stand-ins, and each fake
answers "signed in" only when handed the credential a round gets: a
keychain-only crew Cursor key is `authenticated`; an `agent login` with no
crew key is refused without cursor-agent being asked; claude probes the
crew token (or the interactive fallback) and never an ambient
`ANTHROPIC_API_KEY` it sheds, unless `billing:` chose it; codex probes the
round's copy of `auth.json`, less its refresh token. gemini's fake would
answer if asked, and never is: with a login present gemini is
`indeterminate`. `tests/worker.test.sh` and `tests/review.test.sh` check
that an unauthenticated, an `indeterminate` (gemini) and a `timeout`
vendor are each refused, with `vendor_unavailable` naming the status, and
that the chain's next vendor runs instead.
`tests/sandbox.test.sh` checks the real `given` path: with `--shed`, an
ambient `ANTHROPIC_API_KEY` is not the login, the crew token is handed in,
and the key never reaches the round; `tests/adapter-contract.test.sh`
checks the same through the claude adapter, with no token handed in by the
caller. `tests/doctor.test.sh` and `tests/setup.test.sh` run against a
`PATH` missing a tool and one with a wrong version, an answers file and
"every default", and a re-run against an existing `config.yaml`.
Every suite that starts a real vendor's round through `fm-worker.sh`,
`fm-review.sh` or `fm-herdr.py` meets the probe before that round:
`tests/herdr.test.sh` gives codex and gemini a login file in a home of its
own (a key in the shell is shed, so it is no login), and its fake CLIs
answer `--version` and their status check by replaying the same
recordings - claude and codex signed in, cursor-agent with the recorded
`Authentication required` answer, so its rounds there are refused like gemini's.

#### T-157: diagnosing collected facts

`fm-doctor.sh --collect --repo <dir>` prints tool observations without
judging the host. `--facts <file>` judges supplied observations against that
repository's pins. The file is tab-separated data: tool rows carry name,
path (empty means missing), numeric version, raw version line and optional
xcrun-shim path; host rows carry `os` and `sandbox`; probe rows carry vendor,
status, English explanation and Traditional Chinese explanation; bundle rows
carry `cursor-agent` and `names`, `absent` or `unreadable`, emitted only for
an installed cursor-agent. The collector
does not run login probes in `--collect` mode. Normal doctor runs collect
tools and obtain login probes before judging each usable vendor. Environment,
repository hygiene, approved installs and an explicitly requested canary keep
their existing behavior.

Setup also accepts `--facts` for its detection layer: vendor rows carry name
and login status, repo rows carry `origin` and `ref`, and gh rows carry
`present`, `authed` and `permission`. Its recommendation and config writer
consume those observations. Tests supply facts; the normal commands collect
them from the host.

---

## 14. The task DAG

The task list is `design/tasks/`, one file per task: `design/tasks/<id>.json`
holds that task's entry and nothing else, with `id`, `title`, `milestone`,
`depends_on`, `scope`, `bootstrap` and `acceptance`. `scope` is the glob
allowlist gate 3 enforces. There is no table here: `bin/fm.sh tasks` prints
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
a `rev`, they read a branch rather than the working copy — gate 3, the worker
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

**The migration is retired (T-157).** Firstmate verified on 2026-09-30
that no open pull request and no registered project still carries the
one-array task list. Readers now require `design/tasks/<id>.json`; the
legacy reader, scope alias, migration command and rebuild conversion are
removed. A rebuild preserves the branch's own task file and leaves other
conflicts for the worker, under the usual no-lost-work checks.

---

## 15. Driving other repositories (approved plan; runtime not yet accepted)

The captain approved this consolidation on 2026-10-01. T-166 updates
specifications, documentation and role rules and adds `tests/skills-contract.test.sh`.
The suite checks the role rules' structure and text only, not model compliance;
its assertions provide this change's fail-first evidence for the role-skill
changes, which `config.yaml` classes as behaviour. T-166 changes no runtime or
production scripts. It follows T-130/T-161/T-162/T-163/T-164/T-165/T-167;
existing PR 130/131/132 repairs precede external implementation. It neither
implements external execution nor waives acceptance. T-163 enables independent
Codex reviews; T-167 preserves truthful availability and completion ownership.
See [the adoption ledger](external-roadmap.md) for replacements and deferrals.
Sections 5–13 describe shipped self behavior. The basic external flow is proven;
this section also records planned advanced reviewer and stacking contracts,
and autopilot work beyond T-141/T-231. Report unsupported paths honestly.

### 15.1 Roots and project resolution

The immutable code tree (`FM_CODE_ROOT`) supplies trusted scripts and roles.
The engine root (`--repo` / `FM_ROOT`) supplies engine configuration and self
state. External project data belongs under `FM_HOME` (environment or config
`home:`, default `~/.firstmate`), outside the engine working tree:

```
FM_HOME/projects/<name>/
  repo/             # managed clone
  worktrees/        # task worktrees, direct children only
  CONVENTIONS.md    # approved project contract
  tasks/            # private specs, one JSON object per task
  design.md
  state/            # pins, evidence, runs, reviews, events, decisions,
                    # prompts, mirrors, recovery, unsent, wake records
```

Resolve explicit `--project`, then `FM_PROJECT`, then configured default through
one shared resolver. Never infer project from cwd or remote. Validate project
names (`[a-z0-9-]`, at most 24 characters), duplicate names, unknown fields,
origin identity, canonical paths, traversal and symlink escapes before writes.
Origin identity is the managed clone's configured `remote.origin.url` and
`remote.origin.pushurl`, compared byte for byte with the project's GitHub URL,
never the `insteadOf`-rewritten form. A user's global SSH rewrite is accepted;
a matching rewrite in the clone's local config, a second URL, or a push URL to
another repository is refused (T-217).
Reject FM_HOME inside the engine (exit 65); prevent cleanup crossing roots.
Migration from engine `state/projects/` requires operator approval and verified
recovery; never silently move it. Optional local history excludes repo/worktrees
and never pushes private project records to a remote.

Self (`repo: .`) keeps its paths and no-flag compatibility. External managed
clones do not alter the captain's original checkout. The fresh local pilot's
no-remote bootstrap is explicit, not a pretend clone of a nonexistent remote.

### 15.2 Registry and conventions

The engine registry carries only approved routing metadata, not private project
contracts, designs or specs. Resolve external base, checks and gate contract
from approved private project records. Self retains T-043's full contract:
`setup`, `check`, `check_env`, `tests`, `test`, `docs`, and future fields. T-050
ships shell and Python readers for both the top-level `project:` block and
`projects.firstmate-workflow.project`, refusing duplicate declarations. The
self block now lives in the registry entry (T-170, following captain's card
D-firstmate-workflow-T050-3, 2026-10-03). Old pins
re-derive from the location at their recorded commit without repinning. Never
maintain two conflicting contract copies or let a branch change its own pinned gates.

T-139 inspects merge methods, delete-on-merge, readable protection/checks,
CODEOWNERS, PR template, CONTRIBUTING, commit style and last 30 PRs (reviewers,
bots, cadence, stacking, languages, volume and merge actors). Infer with cited
evidence and ask at most three genuinely missing contract questions. No history
is available in an empty repository: do not invent it. CONVENTIONS.md has three
front-matter keys: `land: card|handoff`, `review: fm|external|both`,
`post: local|summary|check|threads|comments`. Prose carries named reviewers,
required checks/statuses and confirmation, merge/deletion/retention policy,
stacking, task-branch leases, watch cadence/debounce and dated captain intent.
Chat changes report changed lines; scheduled inspection proposes drift updates.

#### T-139 private onboarding contract

The former §15.8 visibility/protection prerequisite is withdrawn. A private
repository is accepted; HTTP 404 protection is unknown, never proof of absent
protection. `fm project add` records a bounded inspection privately, offers at
most three missing-contract question groups, then writes CONVENTIONS.md only
with explicit captain-confirmed checks, policy, product intent and commands.
The same confirmation writes an initial private design.md beside it (T-226): firstmate's own reference for the project, seeded from the confirmed product intent, captain intent, checks and policy, stored only under FM_HOME and refused by the publication guard if a round stages its bytes. Its front matter records based_on, the base commit it was last checked against. Every fm project sync (and so every external round, review and preflight, and the watcher's re-inspection) compares based_on with origin/<base>; when the base moved, it prints the commits and changed files, records them in state/onboarding/design-check.json and pushes one design_stale wake per new base, so firstmate reviews and corrects the file and runs fm-project.sh design-checked <name>. The check never blocks a dispatch and never edits the file; onboarding never overwrites an existing design.md.
The public engine registry carries routing only; command configuration is
`FM_HOME/projects/<name>/state/config.yaml`. Onboarding inserts the routing entry
into the existing `projects:` block, allowing a trailing comment on its header
and refusing a second block. The entry is a working-tree change to the tracked
`config.yaml` that reaches main only through a captain-approved pull request.
Existing explicit-name and self routing remain supported.

The conventions front matter uses data-only fields (strings quoted as JSON;
arrays and objects as JSON; named policy enums may be bare). Mandatory policy
includes repository/base binding, land, review, post, merge_method,
delete_branch, required_checks, stacking, force_with_lease, captain, intent,
product, confirmed_at, confirmed, policy_confirmed and timer values.
T-250 adds optional, captain-confirmed `branch_prefix`, `ci_branch_patterns`
and `ci_pull_request`. The prefix matches `^[a-z0-9][a-z0-9._-]{0,30}/$`,
one segment ending in `/`, JSON-quoted as `"feature/"`. CI patterns are a JSON
list of 1–30 non-empty branch or `refs/heads/` globs; `ci_pull_request` is a
boolean, default false. Missing patterns remain unknown, not an empty list.
The repository prefix wins over `FM_HOME/owners/<owner>.yaml`, then no prefix.
Owner files allow `branch_prefix` beside the three `pr_*` keys; CI rules are
repository-specific and refused in owner files. `branch_format` returns
`{"prefix":"","patterns":null,"pull_request":false}` when nothing is recorded.

Inspection also records `.drone.yml`, `.drone.jsonnet`, up to five direct local
jsonnet imports, and up to twenty YAML files from `.github/workflows` under
`ci_files`. Plain-text parsing proposes branch/ref patterns and PR triggers,
with file paths as evidence. Recent PR heads propose the most common first
segment among heads matching a recorded pattern, or all segmented heads when
no patterns are found, with PR numbers as evidence. The policy question shows
these proposals; approval drops them unless the captain explicitly answers,
and conventions edit accepts the three fields. Older inspection records have
no CI evidence but can still propose a prefix. These confirmed fields are not
drift keys. A non-directory workflows response is unknown, never a file list.

Publication reads the same contract as merge and prompt construction. Missing,
invalid or unconfirmed policy refuses external publication; self defaults stay
unchanged. Merge methods and retention follow the contract; land: handoff
refuses engine merge. No path enables auto-merge or protected-base publication.
T-143 enables policy-authorized stacking and explicit expected-head restacking
through the operator helper documented below. Summary/check/threads projections are retained locally
pending T-140; they never fall back to exposing private acceptance as comments.

Inspection covers the last 30 updated PRs and up to 100 reviews/comments/checks
or statuses per PR. Counts are taken from PR detail; truncated text/review
samples are evidence, not exhaustive history. Git log supplies commit examples
from an existing managed clone or a temporary private history clone. Only
`fm project sync` creates the managed `repo/`; it also repairs earlier shallow,
unpopulated inspection clones without resetting an existing checkout. Missing
merge/deletion/check facts remain unknown until explicitly confirmed. Empty
local folders have no invented remote, commits,
PRs or product brief; bootstrap initial-commit permission and remote identity
are explicit answers, and onboarding creates neither commits nor remotes.

The existing owner-bound watcher schedules daily re-inspection (configurable)
for every registered external project with confirmed conventions, with a private
deadline per project. Inspection failures cannot stop engine wake delivery. It
retains and debounces drift proposals and pushes a bilingual wake to the queue
served by its owning watcher. It never
edits confirmed policy automatically. Chat edits report an exact diff and retain
it privately. Workers and reviewers receive CONVENTIONS.md, and an fm review
for review: external or both is only a pre-check. The captain's merge double
check continues to own authenticated review, current-head checks/statuses and
six-gate evidence.


### 15.3 Private project state and cleanup

All external records in the tree above remain private, including events,
decisions, diagrams, mirrors, context packs and unsent recovery. Engine state
must not receive their specs, worktrees or evidence. The local board on
`127.0.0.1` shows and answers every registered project's records in full on one
main page for the captain alone; `?project=` is an optional filter. External
records stay stored privately under `FM_HOME`, never written into engine state
or public diagrams. The one exception is the forwarded wake item in the
engine queue: only its namespaced id, `reason` (`forwarded`), `origin_project`,
`origin_reason`, projected line and time (`woken`) cross that boundary.
Posting is an explicit projection controlled by project
policy, not a prerequisite to retaining or gating local evidence.

Private `state/config.yaml` may also name `worker:`/`reviewer:` vendors and a
non-empty `fallback:` list using `- item` lines (§5.3). The private list replaces
only the engine fallback list, after the opposite-of-host pair step; bracket
form is reported and ignored. Named private vendors record `rule=project`.
Dispatched tasks use changed values at their next launch without re-gating
because their contract pins stay fixed. Onboarding rewrites this file from the
contract and drops hand-added vendor/fallback keys; add them again afterward.

Cleanup, reconcile, worker, reviewer and gates take the same project context.
Cleanup removes only a validated direct child of that project's worktree root,
retains live-owned review checkouts and respects recovery/retention policy.
Identity is the exact `(project, task)` pair; matching task IDs do not share pins,
judgments, decisions, clearance, reviews, worktrees or cleanup authority.

### 15.4 Events, decisions and the board

Keep explicit identity fields (name, role, project, task, round, attempt), never
parse actor strings. Decision IDs come from `fm-decide.sh --allocate` as
`D-<project>-<task>-<n>` under that task's reservation lock. Preserve legacy IDs
without renumbering. Project content remains in project state; board aggregation
and authorized projections retain project identity. Dynamic summaries carry both
`en` and `zh-TW`; progress uses authored script nodes and real denominators.

The board shows all projects by default and filters by `?project=`. Cards and
crew retain project chips; pending cards sort by request time. Answering one
card never answers, loses or reorders another project's card. No bulk approval.
Project greenlights and readiness judgments authorize only their exact tasks.
Preserve T-034: option selection and custom typing are local, with a separate
explicit confirmation; custom text is literal bounded data for judgment, never
an executable command or merge-equivalent A. T-059's direct-order exception
bypasses only readiness judgment, leaving greenlight, dependencies, park/drop
and capacity checks intact. T-139 conventions choose card versus handoff;
T-141 never auto-merges. A recorded order is not proof of a successful merge.

### 15.5 Immutable pins and authoritative heads

An external task may adopt one human-opened PR with `adopt: {pr, head, base}`:
record its number, the full commit the captain saw, and its base branch. The
captain's readiness A pins those spec bytes; the pinned spec is the sole
adoption authority for workers, autopilot, bindings and merge ownership.
Before a pin exists, readers use the private draft. Gates and review cover the
whole PR from its own base, including the human commits. The external catch-up
rule still applies: rebuilding under `force_with_lease: true` rewrites human
commits on the same PR. Refuse closed PRs, forks, stacked PRs (T-239), protected
head branches, changed bases, branch/title ownership conflicts, duplicate
adoptions and history that lost the approved head before the first adopted
push. A retarget needs a new spec and A card. Unreadable adoption authority
blocks the affected PR while other tasks continue.

T-049 pins append-only snapshots of approved spec, design, conventions and full
gate contract with SHA-256, project/task, approval author/time/decision, source
version, engine code commit and base commit. External local approvals need no
public engine commit. Self committed sources are re-derived; uncommitted self
sources have explicit provenance and hash. One resolver verifies all hashes and
supplies the latest authorized pin; a mutable branch cannot widen its own scope.
Gate 3 refuses missing pins, mismatches, out-of-scope files and `.fm-*` artifacts.
Repin requires an exact project/task captain decision for changed snapshots,
appends a version and emits `spec_repinned`; never rewrite old pins.

A self task's branch file is the committed copy of the latest pin, written
by `fm-worker.sh` at round start and committed with the round (T-207).
A non-rebuilt round restores an edited file to the pin before publishing,
and a rebuilt round that changes it is held (exit `75`); gate 3 is unchanged.

Before each worker or reviewer round, the launcher materializes the verified
snapshots byte for byte under that run's private `pinned/` directory as
`spec.json`, `design.md`, optional `CONVENTIONS.md`, and `contract.yaml` (T-173).
Files are regular (no symlinks) and mode 0444. The directory belongs to the
current user and is not writable by group or others. The launcher creates it
as 0755 so cleanup can remove it normally; reuse and sandbox validation accept
owner writes. The OS sandbox denies round writes and grants only that folder
read access, with no access to its state siblings or signing key. Prompts carry
absolute paths, version and hashes, plus heading and line-range anchors for
spec references and mandatory sections 6–8. No design excerpt or 48 KB cap
remains. Conventions and parsed gate contract also remain complete in the
prompt. Missing conventions are explicit. Legacy no-pin rounds snapshot their
existing sources in the same folder and label them unpinned, without inventing
approval. Missing legacy design, conventions or contract sources are omitted
from the folder and named as absent in the prompt. Invalid hashes refuse before an adapter starts. External snapshots
stay in the project's private run, never the target checkout or engine tree.

The worker launcher writes pin 1 outside the sandbox before calling an adapter.
A resumed task with an existing PR and no pin gets `source: first-pin-on-resume`
from the current accepted base. Self sources record `<commit>:<path>` and
SHA-256; a new spec absent from that base is explicitly `seeded`. Gate contracts
always come from accepted engine base, with readers accepting both the historical
top-level `project:` and the current self registry entry (T-170). External
spec, design, conventions and contract bytes are private local snapshots; resolving them never requires those
files to exist on public engine main. Every reader uses `fm_spec_pins.py`, which
verifies the complete append-only chain, each snapshot hash, identity and
approval provenance, and re-derives committed self sources. Workers and
reviewers receive the pinned spec and context; gate 3 also rejects a self
task entry that differs from the pin and any path component beginning `.fm-`.

Initial authority comes from dispatch records only (T-171): the captain's
`decision_made` A for the readiness card named by `state/ready/<task>.json`
(`fm-ready.sh judged`), including the `ended` card retained after dispatch,
with a matching project/task choice answer, or a captain `greenlit` event for
this exact project and task as a direct order. Existing project-wide captain
greenlights also authorize the first pin unless this task's own readiness
card exists without a matching A receipt. A readiness A receipt without a
`decision_made` event permits that legacy greenlight fallback; it does not
fabricate a decision event. An unrelated choice or scope card never authorizes
the first pin or masks a direct order. Pin resolution accepts the recorded
project-wide authority without depending on the mutable readiness record.
A scope answer recorded after dispatch authority but before pin creation remains
available to `fm-project.sh repin`; ordering compares authorization times, not
pin creation time.

T-184 provides a migration for first pins whose pre-T-171 direct-order
approval names another task. Their recorded engine commit must be an ancestor
of T-171's parent; approval timestamps alone do not establish legacy status.
Missing engine history refuses migration. Pins do not record a separate write
time, so engine provenance is the available historical boundary. An unsuperseded
legacy pin still refuses resolution and gates. An exact project/task captain
choice A can supersede it through `fm-project.sh repin --decision <id>`, even
when snapshot hashes are unchanged: replacing the obsolete authority is itself
a change. The next version records `supersedes_legacy: 1` and
`supersedes_legacy_reason`, retains the history hash, and leaves v1 untouched.
The decision must be unused and newer than the previous approval. Resolution
uses the successor's valid approval while continuing to verify the complete
chain and its snapshots. Existing chains with valid choice-approved v2/v3
above legacy v1 also resolve without rewriting history or requiring a marker
that the old writer did not produce. All other first-pin and repin rules remain
in force; in particular, a scope card never supplies initial dispatch authority,
and ordinary repins still require changed snapshot hashes.

On resume, the launcher passes its actual worktree to the pin collector.
A changed self task file can replace the base snapshot only when an unused
captain choice A for the same project/task names a commit through the existing
`fm-decide.sh --expected-head <sha>` field whose task-file bytes exactly match
the worktree. That choice must postdate dispatch authority. A prose-only card,
a missing commit, or different bytes leaves the base snapshot in force, so gate
3 refuses the changed task entry. The first pin keeps dispatch `approval` and
records the separate `spec_approval`, with `approved-branch` source, commit and
hash. Resolution rechecks the receipt and committed bytes. That decision is
consumed as spec authority and cannot authorize a later repin; later approvals
must postdate it. Design, conventions and contract still come from the accepted
base. Existing pins are never silently replaced by branch files.
No authorization or unavailable first-pin sources means no pin is written;
the worker warns and continues, but gate 3 fails explicitly with `no pin`.
A first-pin source failure is also retained in the round report. An empty pin
directory containing only a lock or temporary file is still unpinned. Legacy unpinned reviewer context is labelled
unapproved. A corrupt existing pin never falls back to mutable task data.

This is **trust on first dispatch**, recorded as
`approval_binding: dispatch-time`. In particular, an external local snapshot is
captured at dispatch, not compared with an immutable proposal captured before
the captain answered. Stronger pre-answer proposal binding is **deferred:
needs board/decide producer changes outside T-049's scope; recorded as a
follow-up for the captain**. The existing dispatch/readiness/decision producers
are unchanged. A repin likewise uses an existing exact project/task captain
choice A, reads all source bytes afresh, requires changed snapshot hashes,
refuses reuse or an approval no later than the superseded pin approval, and appends a new version without replacing one:
`bin/fm-project.sh repin --project <p> --task <t> --decision <id>`.
Self repins identify uncommitted local spec/design/conventions explicitly;
their gate contract still comes from accepted base. Omitted project and explicit
`firstmate-workflow` retain the same self storage and behavior. The pin contains
all contract fields, including `docs`; gate 4 passes the verified contract
to the shared fail-first engine without consulting the target config.

Before accepting evidence, synchronize and verify GitHub's authoritative PR head
against the local task ref and isolated checkout. CI/check statuses, gates,
reviewed head/base/patch, final-answer provenance, reviewer identity and merge
candidate are bound to that verified SHA. Before advance, the autopilot compares
the local task ref to the observed PR head. Equal refs need no fetch; a missing
ref is created only after a private fetch matches that head. An ancestor ref
fast-forwards after that same fetch check, only with no live worker/reviewer
round, no busy autopilot job, and a clean tracked task worktree. Active rounds
and jobs hold silently even when dirty; an idle dirty worktree wakes once after
three held polls. A worktree fast-forwards with `merge --ff-only`; a ref without
a worktree uses an old-SHA compare-and-swap. A moved fetch skips this poll.
Divergent unpublished work remains untouched and authoritative binding still
refuses it. Equal refs clear sync retries and holds, including after manual
repair. Sync errors retry at poll offsets 0, 1 and 3, then wake once with the
last command error. Stale local gates still prove no readiness.
Refresh/refuse on mismatch, remote movement or unreadability. T-051/T-052/T-138
own regressions for that boundary; check again before presenting/using a card.

T-135 owns trusted outside-round append-only local round records and their
worker/reviewer/gate-6/protocol readers. T-138 extends those records with
attempt, verified head/base, stable patch-id, files, spec/contract hashes,
reviewer identity/vendor/model, final-answer provenance and text. Model-written
transport receipts and transcript/quoted approval markers are not authority.
Gate 6 consumes authentic final verdicts and latest rejection precedence. The
standing list remains numbered, complete and closed; a protocol syntax checker
cannot authenticate it or prove a regression/new-ground claim semantically.
T-135 reads the approved local firstmate brief before its bounded context pack,
with coverage in comments/local modes independent of PR publication. T-135
replaces T-073 historical comment transport with authenticated local asks/lists;
every REJECT supplies criteria from round one and later prompts receive them
from round two (SK-007). T-052 extends external prompts and T-140 adds the
other projection modes. No worker reasoning enters reviewer context.

Approval may carry across a verified base-only update only if the authoritative
current stable patch-id remains approved and no later rejection supersedes it.
CI and six gates always run/read for the new head. Changed patch requires review.
Projection failures preserve local evidence and report what was not published.

T-140 collects each conventions `reviewers` login independently through paginated
GitHub reviews, review threads and issue comments. The signed external receipt
retains identities, reviewed commits, cited lines, open threads and complete
payloads separately from fm final-answer provenance and standing lists. Every
named reviewer's latest review must approve the verified current patch; COMMENTED,
a stale approval or an unreturned changes request is not approval. Unresolved
threads block readiness even after another reviewer approves. Confirmed optional
`analysers` names required check/status contexts alongside `required_checks`.
Incomplete or unreadable collections remain unknown, never silently approved.

The worker's bounded context pack supplements its approved local brief with these
linked findings in every posting mode. An approved brief is bound to project,
task, round and head. The pack carries a firstmate brief to a later head in the
same round only when the written head is an ancestor, no non-merge commits
outside the base follow it, and the task's stable patch-id and file list are
unchanged against their respective merge bases. This permits only merges of the
base and states the head the brief was written for. Any other head change needs
a new brief, as gate 6 needs a new review for a changed patch.
External text cannot authorize a brief or
waive coverage; firstmate verifies root causes before writing the approved brief.
The reviewer gets the bounded external evidence without worker reasoning.
`bin/fm-external.sh collect` exposes the same reader outside rounds, after
verifying the remote head/base and local task ref. Gate 6 and merge readiness
refresh it rather than trusting any GitHub projection.

Posting preserves the validated conventions mode. `local` writes no projection;
`summary` edits one receipt-addressed progress comment under a per-task lock;
`check` writes a head-bound progress commit status using the existing personal
credential. Its separate progress context is not review or merge approval. These projections contain
no private brief/verdict/report text and are not approvals. `comments` retains
explicit comment publication. For `threads`, firstmate supplies a private mapping
of thread IDs to verified fixing commits and authored replies in each thread's
language, asking for re-check. The helper replies in the original thread once per
finding/fixing commit, cites that commit and never resolves the thread or counts
a missing returned review as passed. Verifying the actual fix and reply language
is firstmate's responsibility; a structured mapping cannot prove either.
Projection failure preserves authoritative local records. Scheduling beyond
launcher/gate collection points remains T-141.

### 15.6 Gates, protection and landing

Use six gates: **1 branch, 2 rebase, 3 scope, 4 fail-first, 5 ci, 6 approval**. Gates 1/2 use
project or stacked PR base, gate 3 pinned scope, gate 4 pinned contract including
docs and the fail-first engine, gate 5 current required check-runs **and commit
statuses**, gate 6 authenticated review under project policy. Required names
come from readable protection and confirmed conventions. Missing/pending checks
are pending, failed checks are failed, unreadable evidence is unknown. Bounded
CI wait does not turn pending into failure or approval.
An external project's pinned `project.unrunnable` reason lets gate 4 report
not runnable without running tests. Readiness and the candidate retain that
reason in `not_runnable`; it never blocks raising the merge card. The card
warns that fail-first did not run and that required green CI is the only
remaining test evidence. This does not waive gate 5 or approval. Existing
pins keep their previous contract until explicitly repinned.
A behind branch gets one bilingual stderr diagnostic after a passing gate 2,
or before gate 5 in an `--only 5` run, with the commit count and resolved base
SHA. The diagnostic changes no gate result and does not enter the gate report.

Private repositories are accepted. Unreadable protection (including 404) means
unknown, never unprotected, rejected merely for privacy, or implicitly safe.
Confirm project checks and policy before readiness. Sync validates clone origin (rule in §15.1)
and path, configures local guards/excludes without copying engine files to the
target. Every GitHub operation names the repository. Credentials/settings are
not changed as an incidental task side effect.

No protected-base push or force push. A task-branch force-with-lease requires
confirmed project policy and expected old head (an external rebuild, T-223:
conventions `force_with_lease: true`, expected old head = the bound PR head).
This includes clean external branches behind their base; autopilot may rebase
them under that policy or use merge update-branch when conventions allow merge
(T-231).
Merge method and branch deletion
follow conventions, never hardcoded squash/delete; retain branches used as open
PR bases. Never auto-merge. Firstmate verifies actual current-head evidence and
traceable captain approval before board merge (`land: card`) or team handoff.
A helper exit status alone proves neither authorization nor gates.

No engine designs, specs, pins, state, prompts, logs or `.fm-*` artifacts enter
target commits. Changes to target coding instructions, CI or configuration need
explicit pinned scope; settings, secrets, labels, webhooks/releases are not
incidental writes. Bootstrap initial content/remote creation is separately
approved before ordinary task branch rules, not an exception inferred by fm.

### 15.7 Portable roles and stock execution

Trusted launcher prompts carry role, immutable spec, whole conventions, complete
design paths and section anchors, full gate contract, project/task/base
and isolated checkout SHA. The reviewer receives diff and machine evidence,
never worker reasoning. First-round spec is the brief; later packs include
assertions/logs/source, authentic standing-list findings, acceptance mapping and
merge/conflict facts. T-135 warns visibly for missing coverage without inventing
facts; cancelled and pending CI are distinct.

Workers never commit/push/checkpoint or run suites. Frozen outside-round launcher
publishes. T-163 Codex run mode requires genuine isolated checkout, trusted
context, OS confinement and final-assistant-output provenance; no marker-only
admission, silent diff/vendor fallback or unsafe flags. T-167 binds availability
to current CLI/provider outcomes, not quoted errors in model/tool text.

T-051's target execution path synchronizes and verifies the managed external
clone before launch, using frozen engine scripts. A clean checked-out base may
fast-forward to the fetched base; divergent or unpublished local work is retained
and requires synchronization before launch. New task worktrees start at the
fetched confirmed base. With a confirmed prefix, new external branches are
`<prefix><task-slug>-<short>`. The suffix comes only from a `public_title`
whose title, summary and changes pass plain public-text validation: lowercase,
non-ASCII-alphanumeric runs become hyphens, cut to 40 characters and trim edge
hyphens. Missing, invalid or empty results use `work`. Without a prefix the
name remains `<task-slug>-work`. Existing local and remote branches are reused,
including legacy unprefixed branches; adopted PRs retain their own heads.

Before a new external branch creates a worktree or publishes anything, the
worker reads `branch_format`. Read failure emits `worker_crashed` and exits 65.
Absent CI patterns print a migration warning and continue. Otherwise a confirmed
PR trigger permits the branch; without it, at least one pattern must match by
Python `fnmatch.fnmatchcase`, stripping a leading `refs/heads/`. A mismatch
prints the branch and patterns, emits `worker_crashed`, and exits 65 before any
worktree, commit, push or PR. Existing/adopted branches skip the trigger check.
Matching a branch trigger can also run that repository's deployment steps.
No migration renames existing branches or changes self-project naming.
External commit subjects and PR titles use the spec's validated `public_title`,
stripped and without a firstmate task id. Missing or invalid public text keeps
the generic task label and private-evidence fallback; private spec titles stay
private. The public body uses only `public_summary` and optional `public_changes`
(1–10 printable ASCII one-line items, each 1–200 characters, with the summary's
path and STE checks). These public fields live only in external specs under
`FM_HOME/projects/<name>/tasks/`, never in tracked engine files.

T-247 adds three optional CONVENTIONS fields: `pr_title` (`plain` or
`conventional`), `pr_sections` (0–12 unique non-empty one-line headings, each at
most 80 characters and without `#`), and `pr_language` (`en`, `zh-TW`, `zh-CN`,
or `auto`). Per field, the repository value wins over the private owner default
in `FM_HOME/owners/<owner>.yaml`, which wins over `plain`, `[]`, `en`. The owner
and root come from the policy repository and the resolved
`<root>/projects/<name>/CONVENTIONS.md` path; other layouts have no owner default.
Owner files use the same data-only `key: <JSON or bare enum>` line parser, with
blank and comment lines ignored; only these three keys and `branch_prefix` are
allowed. Bare values
use `[a-z][a-z0-9_-]*`; quote `"zh-TW"` and `"zh-CN"` as JSON. Missing owner files
supply no default; symlinked, unreadable or invalid ones make preflight refuse
and the worker refuse branch selection with exit 65. Invalid format fields in
CONVENTIONS refuse the project through the shared policy reader. Owner defaults
are read at round time, not pinned or copied into CONVENTIONS. Onboarding writes
format fields only from the captain's explicit answers. Firstmate git holds no
owner default file or real owner name.

Preflight requires a valid `public_title`. With `pr_title: conventional`, it
also requires a conventional subject such as `fix(api): deduct the fee`, with
an optional author-supplied `[KEY-123] ` ticket prefix. Firstmate never invents
a ticket. Both preflight and rendering apply STE to the text after `: ` for
recognized conventional subjects. Rendering accepts a previously pinned plain
title under a later conventional setting, warns once, and still publishes it.
Existing SPEC-OK receipts and pins need no repin. Public prose stays English
ASCII with no paths; `pr_language` does not translate prose in v1.

The renderer emits the confirmed headings verbatim and in order. Classification
is case-insensitive and first match wins: `AI` plus `参与`, `參與`, `participation`
or `involvement` means AI; `summary`, `摘要` or `概要` means summary; `test`, `测试`
or `測試` means testing; `change`, `改动`, `变更` or `變更` means changes. Unknown
headings and headings without content are omitted. Summary lines and change
items become bullets. With no headings the body is the summary alone, or empty
when absent. Valid public bodies have no private-evidence footer. The renderer
never reads a repository PR template.

Testing uses `<!-- fm:testing -->` and `<!-- /fm:testing -->` around unchecked
required-check lines, initially `pending`. Review mode `run` and a pinned
unrunnable contract can add generic local-test notices, never commands, reasons
or local results. Autopilot refreshes this block on open, non-adopted external
PRs from current-head CI: success/neutral/skipped pass, terminal failures fail,
and other states remain pending. Duplicate names prefer failed over pending
over passed. Unsettled CI resets existing required-check and analyser lines to
pending. `Local tests` lines and all other body text remain unchanged. A saved
head/evidence key suppresses duplicate PATCH requests even with a stale body;
PATCH failures are recorded without blocking gates or merge. This body update
applies under every post mode and never edits unmarked or adopted PRs.
The AI block has exactly `- [x] 🤖 AI-Generated`, `- [ ] 🤝 AI-Assisted`, and
`- [ ] 👤 Human-Written` on separate lines.

Later rounds rename only a PR whose title is still the exact generic label and
whose head branch matches the task branch; adopted PRs retain their title and
body. Self-project commit subjects and PR bodies, draft question PRs, review
comments, status policy, publication guards and gates stay unchanged. PR/Actions requests
name the selected repository. Both initial and rebuilt isolated review checkouts
clone the target repository with their own objects and no remote. External review
requires a PR and compares its authoritative head and fresh base with local refs
before preparation. After the CI wait and before recording the final verdict,
the PR must remain open, its head must match the reviewed head, fetched PR ref
and local task ref, and its base branch name must be unchanged; main moving during
the CI wait does not void the round (T-213). A moved or unreadable head, retargeted
base or closed PR after the CI wait refuses the round before the adapter runs,
with a reason on stderr and a review_failed infrastructure_error event. At the
final check, it retains the final answer as stale evidence instead of publishing
current approval.
The verdict stays bound to the original reviewed head, merge-base and patch-id;
only gate 6's existing patch-id rule decides whether it covers a later head.
Accepted risk: a semantic conflict introduced by main outside the reviewed files
(for example, main renames a function the PR calls) is not seen by the reviewer;
it is caught only by required CI on the current head (gate 5), exactly as for
today's gate 6 carry across a merge of main. Gate and merge candidate authority
remains T-138's shared binding.

Dispatch records its session owner and keeper in the selected project's
`state/dispatch/<task>.json`; this is a launch receipt, not a completion verdict.
Cleanup holds task exclusion and refuses live or uncertain external executions,
even with `--force`. An unreadable PR outcome retains the external worktree unless
force was explicitly requested. Local branch deletion follows confirmed retention
policy and retains branches used as another open PR's base or whose downstream
status cannot be read. Changed `.fm-*` path components are refused before external
commits, including explicitly staged ignored files. The scripted stock-dispatch
fixture checks owner lifetime, duplicate dispatch and private target publication;
it does not establish real vendor, sandbox or Herdr-window acceptance. Firstmate
must capture that live evidence separately before accepting T-051.

Core T-051 stock dispatch must leave a genuinely live owned run and visible
Herdr view after the invoking dispatcher exits, with truthful completion and
cleanup/retention evidence. A manual relaunch after dead dispatch does not pass.
Use lifelines with explicit owner and pushed wakes, no setsid/beacon/PID polling.
Retain cmuxOnly; full detached cmux lifecycle remains deferred under T-162.
This core integration does not wait for advanced T-141 autopilot.

Firstmate runs from engine root, names project on supported operations, and
uses routine fair no-project dispatch only once T-053 implements it; explicit
project dispatch is for captain-requested project work. Native hook loading,
enablement/policy, exact trust, reload and verified delivery are distinct T-164
facts. Never fabricate trust, infer delivery from queue/ack, or claim a held
watcher starts an idle Codex conversation. Complete authorized actionable work
before ending for a real dependency/event/operator action.

#### T-052 portable prompt context

External worker and reviewer prompts carry launcher-supplied project/task/base
and checkout/head identity. Self prompts retain their existing sections apart
from the T-173 complete-input index replacing inline design excerpts; an unpinned self reviewer keeps its
existing diff prompt shape around that index.
Both projects receive the approved immutable pin when present.

T-173 supersedes the bounded design excerpts: complete approved snapshots live
in the round's sandbox-protected `pinned/` folder. The external home stays
hidden except for the pinned folder, the round's roots and the round's own
git directories (read-only, with any `never_read` entry inside them still
denied). Prompts index their absolute paths, hashes and design section anchors
instead of embedding or trimming design text. Whole conventions and the complete parsed gate contract remain in the
prompt. Run-mode contract summaries use the pin rather than mutable target
configuration whenever a pin exists. Existing review total-input bounds still
refuse an unrepresentable prompt.

The frozen engine supplies roles and context; a target need not contain engine
files. For self and external reviews with a PR, shared authoritative head/base
verification refuses a remote update-branch that left the local ref stale before
preparing review. After the CI wait and before publishing, head/ref equality and
the unchanged base name remain required, without base-tip freshness (T-213).
Legacy self review without a PR remains local-only and establishes no remote
readiness. The isolated checkout must match the named head and merge-base. Gate/candidate binding remains
the shared T-138 boundary. These structural guarantees do not prove a model
followed its role or inspected omitted design. Workers leave publication and
suites to the outside launcher and CI; reviewer context excludes worker reports
and reasoning.

### 15.8 Pilot and advanced integration

The basic external flow has run end to end on a private repository: onboarding,
private conventions and design under `FM_HOME`, captain-card dispatch, isolated
worker rounds and reviews, wakes forwarded to firstmate, catch-up rebuild with
a lease, six gates on the authoritative head, and captain-card landing. Advanced
reviewers, stacking and autopilot beyond T-141/T-231 retain their planned
contracts. Keep repository-specific observations and raw evidence privately
under `FM_HOME`; public documentation describes the flow generically.

T-140 external reviewers, T-143 stacking and T-141 autopilot are advanced
integrations, not basic-pilot dependencies. Named
external reviewers must all approve the current change with unresolved requests
cleared; fixed-but-unreturned is not approval. Reply per post convention with
fixing commit/thread language. Stacked work uses per-PR base, retargets after
base merge, verifies new authoritative head/patch and retains shared base branches.

Autopilot is zero-model scripted supervision: local event writers push FIFO
notifications, GitHub alone uses conditional ETag polling. Lifeline owner is
fm session, or an explicitly installed launchd/systemd service. No model timer,
beacon or PID polling. Mechanical updates obey conventions; judgment queues
wake firstmate through supported delivery. It never merges automatically.

The T-141 resident service starts through `fm-session.sh start` and
`fm-autopilot.sh ensure --all`, one instance per registered project. Each runs
from a frozen engine snapshot through T-151, owned by the fm session. Owner
exit ends the service and descendants. An optional launchd/systemd owner needs
an explicit captain choice; nothing installs it implicitly. Kernel locks guard
startup and singleton service ownership. Every operator `fm` command calls
`ensure --resume --all`: a crashed service restarts on that command, while a
project without an `autopilot/owner.json` receipt stays unstarted. Crew commands
with `FM_IN_ROUND` start no service. Test sessions identified by
`FIRSTMATE_CI_SESSION` skip automatic resume and startup unless the feature test
sets `FM_AUTOPILOT_TEST_ENABLE=1`. Reviews still use visible Herdr dispatch.
The service records its `bin/` and `skills/` tree identities. Once firstmate
fast-forwards the engine checkout after a merge, the next `ensure` requests a
reload when those committed trees differ. It drains running or consuming jobs,
batches and unpushed wakes, then its old code hands off to a
fresh snapshot without killing the service. If the new service cannot start,
the old snapshot resumes and queues one bilingual failure wake; that failed
code identity is never retried. Dirty code keeps the running snapshot, and the
next operator `fm` command reports the reload outcome. Session startup uses the
session's frozen copy, taken from the engine checkout moments earlier. HEAD
can move between freezing and recording the identity; the next `ensure` detects
subsequent differences and reloads. If committed autopilot code cannot import,
`fm` reports autopilot unavailable and takes a fresh snapshot on each command,
while the old service keeps serving. A pre-T-203 service needs one manual
restart when no job is running or consuming; thereafter it reloads itself.

Local event writers persist complete lines before ringing the service's own
`state/session/autopilot.d/` FIFOs. These are separate from firstmate's
`session/wake.d/`. Semantic wake and conventions writers also notify autopilot;
ordinary events never ring firstmate's doorbells. When the autopilot channel
directory is absent, emission starts no notification subprocess; this avoids
adding process startup after publishing a lifecycle boundary while the caller
still holds its task lock. The service subscribes before
reading durable offsets and reads local inputs only at startup and on pushed
notifications. Only GitHub is polled, with endpoint ETags, confirmed convention
cadence and bounded network backoff. Per-reviewer quiet periods batch findings;
no idle timer invokes a model.

Self-project mechanical branch updates require an open, non-draft PR observed
as mergeable and behind; unknown mergeability never authorizes a self update.
External updates use ancestry and convention-selected rebase or merge (§5.3.3).
With no live round or busy autopilot job for the task, REST `PUT /repos/{repo}/pulls/{n}/update-branch`
uses `expected_head_sha` as GitHub's compare-and-swap. HTTP 202 stores a
`{head, seq}` pending marker, suppressing another PUT for 20 poll steps on that
head. External rebase updates also store `method: rebase`; that marker survives
a head change until local synchronization or terminal pruning. An expected-head
422 means a race and is re-decided next poll without a wake. Other responses use an uncached PR re-read: a changed head means a race;
an unchanged head or failed re-read retries at poll offsets 0, 1 and 3, then
wakes once with the last HTTP status or transport error. Update failures stay
isolated to their PR. The persistent poll sequence advances even on policy or
network errors; retries, holds and pending markers are pruned when the head
changes or the PR becomes terminal. Restacking follows confirmed policy and
expected-head lease checks. Every new
worker or base-update head runs gates. Gate 6 decides whether an approval
carries, whether changed pinned inputs require review, or whether a new worker
change needs a verdict. A current-head REJECT wakes firstmate for a brief and
never relaunches a worker. Returning
reviewers can receive policy-permitted re-check requests. Readiness holds for
firstmate's recommendation and evidence (§6); landing remains the captain's
card or the team's handoff, never an autopilot merge.

Branch updates are re-decided from GitHub state, without a write-ahead action
record. Gate advancement is also re-decided from its observed fingerprint:
`advanced` stores each PR's head and fingerprint only after the gate job starts.
An unchanged fingerprint holds across restarts; changed CI, bound verdict,
authored details or merge-slot release reconsiders the head. An authoritative
head race is re-read on the next poll, without a wake or retry. Gate-step
failures retry at poll offsets 0, 1 and 3, then wake once with the error;
a changed fingerprint starts a fresh retry series and wake identity.
PR events are decided by the event log alone: an event already in
`events.jsonl` is never written again; a failed write retries at poll offsets
0, 1 and 3, then wakes once. Terminal PRs are marked finished immediately;
`event_pending` retains an unfinished event write until success or the third
failure, including after the PR leaves the recent-closures list. Reviewer
re-check requests are recorded per PR head in `rechecked` and completed when
GitHub returns 201 or lists the reviewer as already requested, or the reviewer
has reviewed that head. A 422 refusal wakes once with GitHub's message without
retry; other failures retry at offsets 0, 1 and 3, then wake once.
Review launch is decided from the review job recorded for that PR head, in any
state: at most one autopilot-launched review per head. Gate 6 can request a
review even with a same-head verdict whose binding is stale. A failed start
marks the job uncertain (or records an uncertain job if launch failed before
recording one) and wakes firstmate once; later gate results do not retry it.
Legacy jobs without kind/PR/head fields match through their packet files.
The autopilot keeps no write-ahead action ledger: per-PR records (`updates`,
`holds`, `advanced`, `rechecked`, `restacks`), shared `retries` and `jobs` remain.
The one-time `migrated_t205` upgrade removes the legacy ledger and obsolete
undelivered action wakes, restores terminal PRs' unfinished `event_pending`,
and preserves reconciliation wakes and uncertain review holds for interrupted
or uncertain launches; delivered wake files and old migration flags stay unchanged.
Restack keeps one per-PR-head record in `restacks`, with `head`, `parent`, `task`
and outcome `started`, `done`, `moved`, `conflict` or `published`. Eligible children
are reconsidered under the expected-head lease and worker exclusion.
Jobs and their recovery remain unchanged. CI
failures, findings, failed/lost rounds, unsent worker notes, B/C answers, readiness and conventions
drift persist reason lines under `state/wake-queue/` and enter the T-137 bridge.
`autopilot_waiting` reports overdue judgment bilingually to the board and desktop;
`conventions_drift` denotes policy requiring judgment. External records and FIFOs
live only under `FM_HOME/projects/<name>/state/`, except for the bounded,
project-named forwarded wake line in the engine queue with its namespaced id,
`reason` (`forwarded`), `origin_project`, `origin_reason` and `woken` time.
Forwarding rings only the engine's firstmate doorbells. Queues, acknowledgements and
notifications establish no model delivery: T-164 native loading, exact trust,
reload and actual receipt remain independently verified requirements.

#### T-143: operating a stack

A confirmed `stacking: allowed` convention permits one unmerged dependency
with a unique open, same-repository PR; other dependencies must have merged.
Ambiguous parents, forks and multiple unmerged parents remain held. Empty self
conventions retain the existing hold policy. Firstmate explicitly dispatches
an authorized stacked task with `fm-dispatch.sh --task <id> --project <name>`;
ordinary readiness-card behavior remains unchanged. The worker resolves the
parent again before creating the child from its head and opens against that
parent branch. Existing PRs retain their own base. Local base refs must match
GitHub before worker resumption, review or gates; unpublished local work is
never overwritten to make a stale base look current.

After the parent merges, firstmate can operate without T-141:

```sh
bash bin/lib/fm-restack.sh --repo <engine> --project <name> \
  --pr <child-number> --parent <merged-parent-number> --expected-head <child-sha>
```

The helper holds the worker's task exclusion and preserves dirty worktrees. It
requires confirmed stacking and force-with-lease policy, refuses protected or
unknown-protection task branches, and rebuilds only the child commits beyond
the parent boundary in a temporary project-local worktree. It pushes with an
explicit expected old head, retargets to the parent's base, verifies GitHub's
new head/base, and updates the local task ref with the same old-head check. A clean managed
task worktree is reattached to that verified head.
Remote push and retarget cannot be atomic: a retarget failure reports the
published SHA and requires synchronization and completion of that retarget
before any review. No result is approval or gate evidence.

The restack helper returns 0 for completion, 65 for a refusal, 66 for a rebase
conflict, 67 when GitHub's child head moved, 68 for a stale local task ref,
69 when published but unfinished, 71 when the push outcome is unknown, and
75 for a live worker. Autopilot records completion and silently holds active
work; 75 tries again next poll without a retry or wake. A 67 result settles
silently only after a fresh GitHub read confirms the head moved; disagreement
or a failed read retries. A 66 or 69 result wakes firstmate immediately once.
Pre-push failures 64, 65, 68 and 70 retry at poll offsets 0, 1 and 3, then wake
once with the last stderr line. Local synchronization can heal a stale ref
between attempts. Exit 71, a timeout, a kill or any unlisted status keeps the
`started` record, wakes once with “outcome unknown”, and holds for reconciliation.
Startup recovery also wakes once for every unfinished `started` restack,
even when the child's base has already been retargeted. A `published` or
`started` hold survives changes to the child head until the PR closes or
firstmate finishes the restack by hand: moving its base off the merged parent
removes it from the restack path. Other records clear on a new head. Cleanup
cannot hide a published or unknown push: its failure is attached to the error,
or returned as `tree_cleanup` after success.

Synchronize the local base without overwriting unpublished work, then obtain
fresh current-head CI, six gates and authoritative review/patch binding before
requesting a merge card. The helper retains the parent while any open PR uses
it, or downstream evidence is unknown. Once the last dependent retargets,
confirmed deletion policy permits expected-head parent deletion; unknown
protection defers cleanup. Merge and cleanup independently retain all open PR
bases, including self-project and forced cleanup paths. T-141 may automate
these mechanical operations later; it does not supply their authorization.


#### Autopilot owns PR advancement (T-175)

Each session owns one supervisor per registered project. Conditional GitHub
polls persist their cache, per-PR records and jobs across restarts. The supervisor
writes `pr_opened`, `merged` and `closed` through `fm-emit.sh` as actor `github`,
using the canonical branch/title task grammar and project-local deduplication.
An event without a project belongs to the default project's log.

A new worker head runs the standing-list protocol from round three, then the
six gates. Gate exit 6 launches the next review round through the frozen
launcher. Updated CI or a bound local APPROVE triggers fresh gates. Exit 0
enters the project's merge lock, verifies the captured base and authoritative
head, reuses the lowest unused merge reservation, and requests a card from
authored details when present. Otherwise, for the self project it builds checked
merge details from the latest answered dispatch A card into
`state/decision-details-built/`, outside the advancement fingerprint's inputs.
Pending or answered cards remain authoritative;
legacy numeric ids are never mistaken for a task's reservation. Another project
has its own lock, PR-number namespace, events, evidence and decision ids.

A failed details build queues one wake naming `D-<project>-<task-key>-<n>`
and its missing-card, structural or STE diagnostic. External projects without
authored details wake with "external project: author the details". A draft PR
with no running task job queues one bilingual wake per head with identity
`draft-<n>-<head>`, asking firstmate to mark it ready; the autopilot never marks
it ready itself. Each open draft gets one wake on the first poll after upgrade.
REJECT queues a brief request. Scope questions, failed gates, protocol violations,
launcher exits 2/3/65, and a review without a verdict queue judgment with the
child's own retained-log line where available. A gate, protocol or review result
for a PR that has merged, or that has a captain merge chosen A at that head
which is running or merged, is dropped without a wake; such a PR is not gated.
A PR closed without merging is not covered, and its results still report.
The supervisor never launches
a worker; dispatch remains the board's intent action or an explicit command.
Gates and reviews run as owned children. Completion receipts ring the service;
an interrupted write is reconciled, never replayed by a restart or idle timer.

#### New task discovery and question freshness (T-180)

The autopilot derives a task candidate using the canonical branch/title grammar,
then validates the matching task spec committed at the observed PR head. A missing
head object is fetched through a private ref without moving the task branch.
If that spec cannot resolve the task, the latest authorized pin supplies the
fallback. The main checkout's task directory is never a prerequisite. Unresolved
PRs retain their head and reason in supervisor state without repeated wakes;
later polls may resolve newly available objects or pins. Gates still verify the
current authoritative head and approved scope independently.

Local ASK and SCOPE-BLOCKED records must match the PR head and be newer than the
persisted T-172 tracking boundary. Draft status does not relax these conditions.
A later authorized firstmate brief supersedes earlier questions for that task.
Each remaining question has its own durable wake identity, allowing a new
question at the same head without replaying the previous one after restart.

#### Recorded chat merge windows (T-182)

Firstmate immediately records each time-boxed chat authorization using
`fm-decide.sh --authorize-merges --until <ISO-8601-with-offset> --quote "<words>"`
with the appropriate repo/project context. `--show` prints the current record,
or `none`. The atomic replacement lives in resolved runtime session state at
`session/merge-authorization.json`, with a unique window id, quote, recorded time
and expiry; external projects retain it outside their target repository.
The window is the captain's stated merge period that the autopilot reports on.
Firstmate answers no merge card, in or out of a window; only the captain's board
click merges. Nothing enforces this mechanically, because a firstmate POST with
the board secret looks like a click. This is an evidence/timer facility, never
a merge bypass or a replacement for gates.

The supervisor subscribes to the writer's existing local doorbell, caches the
window on startup and pushed notifications, and includes its deadlines alongside
GitHub backoff. It queues one bilingual reminder at expiry minus 60 minutes
(or immediately within that hour), listing pending merge cards, observed bound
APPROVE/green-CI PRs without cards, and recorded in-flight worker/reviewer rounds. At expiry it
queues one ended notice. Persisted wake identities include the unique window id,
so T-172 restart recovery repeats neither notice and replacement resets both.
A service starting after expiry sends only the ended notice. Cached PR evidence
is informational; authoritative readiness and board authorization still govern
any merge. Reminder inventory reuses the checks and verdict already read by PR
advancement and folds local lifecycle events for rounds; it performs no extra
GitHub requests or process probes. No wake or queue receipt proves delivery to a model.

### 15.9 Dependency order and shared-file coordination

Captain revision, 2026-10-02: “好 T135安排 解耦外部repo convention”, clarified by “不是這個意思 135做完後 review和brief機制要能不依賴外部repo允許我們張貼每一輪工作日誌”. The brief and review loop must work without permission to post round work logs. “現在是第一輪reviewer就要給過關條件” confirms complete pass criteria on every REJECT from round one.

T-135 runs in the first wave beside T-142 with no dependencies. It owns append-only state/evidence/<project>/<task>/ records for brief, pack, worker-report, ask and verdict, carrying project/task/round/actor/kind/head/time and authenticated final-answer provenance for verdicts. The worker reads local briefs and packs; reviewers receive prior rounds and standing lists from round two; gate 6 and fm-protocol.sh read local verdicts with latest-REJECT precedence. Ask only for a missing or unclear list before edits. The project comments/local switch defaults to comments for self compatibility; local mode posts nothing and completes the entire loop. T-138 depends on T-142 and T-135, extends the same records to private FM_HOME storage, adds signing/spec/patch binding and retains atomic merge-head enforcement. T-140 also gains T-135 and adds summary/check/threads projections. No external conventions or advanced stack are prerequisites for T-135. These are adopted implementation requirements, not claims that the readers already ship.

Task JSON files are authoritative. T-142 depends on T-166 (the approved plan's
original empty dependency is intentionally revised to require consolidation).
Storage T-142 precedes conventions T-139; T-049 needs both. T-138 follows storage and T-135;
T-135 is independent and first-wave beside T-142. Shared work requires
explicit shared-file ownership/immutable run snapshots, never live script edits.
T-050 needs pins/evidence/conventions; T-051 needs pins/storage/T-163/T-167;
T-052 needs execution/conventions/briefs; T-053 needs gates/execution/prompts.
T-055 needs T-052/T-053/T-054/T-137/T-144, without advanced-stack prerequisites.
T-140 needs evidence/conventions/T-135; T-143 execution/conventions; T-141 needs
T-138/T-140/T-143/T-144/T-151. See the adoption ledger for deferred work.

### 15.10 Concurrent projects

A single global capacity counts actual live owned rounds, not open PRs or
historical dispatch events. A short dispatch lock recounts/reserves slots;
identity locks allocate actors; slow verification happens before locking.
Recover reservations through owner completion. Same task ID in two projects
counts twice. No-project dispatch fairly assigns each free slot to an eligible
ready/cleared task in the verified project with fewest live runs, ties by name.
The project store must contain a `greenlit` event or the captain's A on that
task's readiness card as pin `approval(None)` accepts it;
explicit project dispatch shares the same limit. Do not preempt live work.

Each project has one merge turn: take it when card is requested; release on
hold/send-back or recorded merged/failed outcome, not just an answer. Verify
base and authoritative PR head stayed as gated before card/merge. Another
project's merge turn is independent. Outcome recovery uses actual repository
facts; stale cards cannot authorize a changed candidate. Board merging must not
block other projects' cards. T-053/T-054/T-055 prove concurrency, shared task IDs,
simultaneous cards, isolated answers, cleanup and private state separation.
