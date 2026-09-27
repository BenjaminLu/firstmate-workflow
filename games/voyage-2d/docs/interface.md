# Voyage 2.5D ↔ the captain's board: the interface

The 2.5D game joins the board (v1, `board/server.ts` in `firstmate-workflow`) as a
switchable mode. It shares one interface with the 3D game. This document gives
the following:

1. Every input the game reads (§1).
2. Every action it sends back (§2).
3. Where each one comes from on the real board: `GET /api/state`, SSE `/events`,
   `POST /decisions`, `POST /tasks` and `GET /api/i18n`.
4. What is simulation-only today and has to be replaced by live data or dropped (§3).
5. The full inventory of the game's features and modes, which the 3D game is
   measured against (§4).

Everything below was read from `board/server.ts` and one real
`state/events.jsonl`. Nothing is taken from memory of how the board used to work.

## 0. Two modes, one seam

The game runs in one of two modes. The mode is set when the page loads and does
not change while it runs.

| | **Live** (inside the board, after integration) | **Playground** (this standalone build, until then) |
|---|---|---|
| Data | the board: `GET /api/state` and the SSE `/events` snapshots, read by a `BoardSource` | the simulated voyage (`v3src/sim/sim.js`), a `SimSource` |
| What moves the voyage | the real crew. The game only watches. | the sim, on its own: its firstmate dispatches, its reviewers do their rounds, new work joins, hands come aboard and go ashore, and the kraken rises |
| What the captain does | answers cards and parks or drops work, as on the board, plus the fight | the same, against the sim |
| Writes | `POST /decisions` (a card clicked on the card) and `POST /tasks` (park, unpark, drop). Nothing else. | **none, ever.** A card answer or a park changes only the sim. |
| Badge | none | a persistent **PLAYGROUND · simulated** / **遊樂場 · 模擬** / **游乐场 · 模拟** (bottom left, shown in the fight and the ending too) |

**The Playground's guarantee.** The Playground build contains no network code at
all. `tools/build.py` refuses a bundle that contains `fetch(`, `XMLHttpRequest`,
`WebSocket`, `sendBeacon` or `importScripts`. The browser test "the Playground badge shows
… and the page never talks to the board" watches every request while cards are
answered and the fight is played, and fails on any request that is not a GET of
the page's own files or its fonts. The Live data source (fetch plus EventSource)
is a separate module that only a Live build includes, so a Playground page cannot
reach the board even by mistake.

Today all state flows through one call:

```
step(state, action) -> { state, events[] }
```

`main.js` then does three things:

1. It keeps `sim = state`.
2. It feeds each event to `director.handle(e, sim)` (the rituals and the camera)
   and to `battle.sync(sim)`.
3. It renders the HUD with `ui.render(sim)`.

The captain's two board actions already go through a data source,
`source.command(...)` in `main.js`, which is today's Playground implementation:

```js
source.mode          // "playground" | "live"
source.command({ type: "answer", decision, chosen })   // a card, clicked on the card
source.command({ type: "park" | "drop", task })        // only where BOARD_ACTIONS allows it
```

Suggested full shape, shared by the 2D and 3D games:

```js
source.subscribe((view, events) => ...)   // view: the §1 view model; events: the §1.7 list
source.command({ type: "answer", decision, chosen, text? })  // Live: POST /decisions
source.command({ type: "park" | "unpark" | "drop", task, project })  // Live: POST /tasks
```

The game renders from `view` and never reads raw board JSON. `SimSource` is the
Playground; `BoardSource` is Live.

## 1. Inputs: what the game needs from the board

### 1.1 Tasks and lanes

| Game needs (view model) | Board source (`/api/state`) | Notes |
|---|---|---|
| `task.id`, `title` | `tasks[].id`, `tasks[].title` | The title can be `null`; the game shows the id alone. |
| `task.key` (unique) | `tasks[].key` = `project/id` | Two projects can both have a T-004. The game must key cards, arms and tags by `key`, not by `id`. |
| `task.project` | `tasks[].project` | This is the flag colour (§1.5). |
| `task.lane` | `tasks[].stage` | See the lane mapping below. |
| `task.deps`, `blocked_on` | `depends_on[]`, `blocked_on[]`, `blocked_by[]{id,stage}` | These are the backlog lines on the chart. |
| `task.milestone` | `tasks[].milestone` (may be `null`) | Drives the chart's ports (§1.6). |
| `task.pr`, `pr_url` | `tasks[].pr`, `tasks[].pr_url` | Used by the detail card's PR line. |
| `task.round` | **not in the payload**; derive it (§1.4) | Needed for the kraken. |
| `task.actions` | `tasks[].actions` | These are the only park, unpark and drop buttons to show. |
| `task.badges` | `tasks[].badges[]`: `gate{gate}`, `ask`, `decision{id,options}` | Gate red, pass criteria asked, a card waiting. |
| who is on it | `tasks[].crew[]` (names aboard) | |
| merge order | `tasks[].merged_seq` | Latest first in the merged lane. |
| counts in the status cluster | `counts.{merged, inflight, waiting, blocked, ready, backlog, parked}` | These replace the simulator's `tally(s)`. |

Lane mapping. The board's order comes from `lanes`: `backlog, ready, working, gate, review, captain, merged`.

| Board `stage` | Game lane today | Change needed |
|---|---|---|
| `backlog` | backlog | – |
| `ready` | ready | – |
| `working` | working | – |
| `gate` (gate failed, review failed or worker crashed) | *(none: the simulator keeps these in working with `gate[id]="red"`)* | **Add a lane**, or render it as working with the red badge. The weather ritual keys off it. |
| `review` | review | – |
| `captain` (approved, or a card up) | *(none: the simulator uses review plus `approved`)* | **Add a lane**. This is where merge cards live. |
| `merged` | merged | – |
| `parked` (a task's stage, not a lane in `lanes`) | *(none)* | Show it in the board menu under the backlog lane, with Unpark. |
| `closed` | *(none)* | Hidden, like merged history. |
| `untouched` | – | This never reaches the page; the server resolves it to backlog or ready. |
| *(simulator only)* `issues` | issues lane, the fog on the chart | **No board equivalent.** Drop the lane, or feed it later from GitHub issues. |

### 1.2 Crew

`GET /api/state` → `crew[]` holds at most `deckLimit` entries (24, which is the
ship of the line's capacity). The ship's tiers map one to one onto this limit:
7, 12, 18, 24.

| Game needs | Board source | Notes |
|---|---|---|
| `id` | `crew[].id` (actor, e.g. `worker-imani-t107-r490`) | The game's fixed ids (`worker-1` to `worker-4`) are simulator-only. Live ids are transient, one per run. |
| display name | `crew[].crew_name` ?? `id` | Used on the name tag. |
| `role` | `crew[].role`: `firstmate`, `worker` or `reviewer` | **The captain is not in `crew`.** He is the human and is always aboard; the game adds him itself. |
| `state` | `crew[].state`: `queued`, `working`, `gate`, `review`, `captain` or `unknown` | The simulator's states (`idle`, `walking`, `waiting`, `standby`, `blocked`, `down`) need a mapping table: `gate` → blocked, `captain` → waiting, `queued` → idle, `unknown` → idle with a "?" on the card. |
| `task`, `title` | `crew[].task`, `crew[].title` | |
| `project` | `crew[].project` | Name-tag flag colour. |
| activity (detail card) | `crew[].activity` `{en, zh-TW}` | Authored text. zh-CN comes from `tw2cn` (§1.8). The simulator's `action` keys (hammer, haul, and so on) only choose the *animation*; derive them from `state` and `role`. |
| progress | `crew[].progress` `{done,total}` or `null` | Not shown today; it could fill the detail card. |
| rank, standing, merges, first-pass | **none** | Simulator-only (§3). |
| vendor | **per crewman: none.** Board-wide: `engine.{vendor, reviewer, cross}` | The detail card's vendor line shows the engine badge, or it is removed. |
| model (which puppet) | **none** | The game chooses a puppet: robot for `worker-4` today, and live a stable hash of the id picks one of the sailors. The firstmate and reviewer puppets go by `role`. |
| hand-offs between crewmen | `handoffs[]` `{kind: order, work, approve or reject, from, to, task, project}` | This is exactly what the rituals need: the order bell, the scroll carried to the reviewer, the salute, the rejection. |

Boarding and leaving. A crewman who appears in `crew[]` boards the ship; one who
disappears goes ashore. In Playground the sim's own crew driver does this; there
is no manual control. In Live **the crew list drives it**. The ship's transform
(§4.6) follows the crew count, and should be damped so that a run finishing and
another starting in the same second does not make the ship shrink and grow back.

### 1.3 Decisions (the cards)

`GET /api/state` → `pending[]`, oldest first:

```
{ id, task, kind: "choice"|"merge", pr?, project?, title,
  details: { en: {title, explanation, before, after, outcome,
                  options: {A:{description,pros,cons}, B:…, C:…, D?:…}},
             "zh-TW": {…same…} },
  owner: {project, task, n} | null, answerable: bool }
```

Some cards are raised with `--title` only (a skill update, `D-SK-*`). These have
`title` and no `details`, and the game must show a plain A/B/C card for them.
**`answerable: false`** cards are listed, but answering one is refused; show the
refusal.

`responses[]` holds the answered records: `{id, chosen, task, pr, kind, merge}`,
where `merge` is `running`, `merged`, `failed` or `null`, plus `merge_reason`,
`merge_unknown` and `superseded`. The game needs these to play the merge salvo
only when `merge` becomes `merged`, and a clear, non-blaming "the merge did not
go through" when it becomes `failed`.

Mapping to the game's card:

| Card part | Source |
|---|---|
| kicker | `DECISION · {id}` |
| title | `details[lang].title`, else `title` |
| body | `details[lang].explanation` (optionally with `before`→`after`) |
| options | `details[lang].options.{A,B,C,D}` → label `description`, `+ pros`, `− cons` |
| recommended option | **not in the payload.** The game marks A today. Live, mark nothing, or add a field to the board. |
| language | `en` and `zh-TW` are authored; zh-CN comes from `tw2cn`. |

**The card's infographic.** Every card carries one, in both modes:

- **Live.** The diagram the board already has for the decision. `bin/fm-diagram.sh`
  writes `design/diagrams/<decision-id>.<lang>.html`, and the board serves it as
  `diagrams/<id>.<lang>.html`, which is how `board/public/diagram.js` finds it.
  The game asks a `diagrams` provider, `{ src(id, lang), exists(url) }`, which is
  the Live source's HEAD check. It shows the iframe only once the HEAD succeeds.
  If there is no file, the figure is removed: no image, never the server's 404
  page. The language is `en` or `zh-TW`. zh-CN uses the board's zh-CN file when
  there is one, and falls back to zh-TW.
- **Playground.** A before/after drawn in the game's style from the sim
  decision's options. NOW shows the task's lane and lost rounds. IF shows, for
  each option, the lane it would land in and its rounds.
- **Either way it follows the option.** Hovering, focusing or picking an option
  lights that option's part. In the Playground drawing it is the matching
  after-panel. In a board diagram it is the elements marked `[data-option="A"]`,
  and if there are none, the diagram's `.answers li` list in A, B, C order.

**The card FX**, each under 500 ms, and switched off by `prefers-reduced-motion`:

1. The card is dealt in from the deck with a flip, and the options arrive as a
   slight fan.
2. Hover lifts and lights an option; the pick pulls it forward.
3. Confirming stamps a wax seal and the card flies off. The answer is sent when
   the card has gone, about 420 ms later; with reduced motion it is sent at once.
4. Later tucks the card into a deck icon at the bottom right, which deals it
   again.

Crimson and Manga each have their own card: red and black torn paper for
Crimson, inked paper with screentone for Manga.

**How a card may be answered.** Only by clicking it on the card itself. There
are no auto-answers, the stage placard does not answer, and A–D and Enter only
work while the card is on screen. In Playground the answer changes the sim; in
Live it is `POST /decisions`.

The simulator's card kinds (`choice`, `merge`, `scope`, `kraken`) and its option
`effect`s (proceed, rescope, park, merge, sendback, hold, battle, drop, spec,
skip) are **simulator-only**. On the board, what an answer does is decided by
whoever raised the card, not by the game. Live, the game must not interpret
`chosen`. It only waits for the log to move.

### 1.4 Review rounds and the kraken (both modes)

The board publishes no round number, so Live derives it from the task's own
events. `src/live.js` implements this, and `tests/live.test.mjs` checks it
against a recorded slice of the board's real `state/events.jsonl` (T-035, T-048,
T-054 and T-067), plus small made-up logs.

- **Rounds.** Each `review_opened` for a task opens a round. A `review_failed`
  with `data.review_outcome == "rejected"` is a lost round (the matching
  `handoffs[]` entry has `kind: "reject"`). Other failures, such as
  `infrastructure_error` or `missing_review`, are not lost rounds. A task is its
  project and id. An event naming no project belongs to `default_project`, so
  the project-less and project-named events of one task count together.
- **Grab.** When a task has lost **three** rounds since it was last approved
  (its review has gone past three rounds), it grabs the ship. That is one arm per
  task, up to the arm cap of 8, the same as the Playground's
  `CONFIG.kraken.max_arms`. A task past the cap waits, and takes the next arm
  that comes free, oldest first.
- **Let go.** An arm lets go when its task is `approved`, `merged`, `parked` or
  dropped (the board's `closed`).
  - Only `approved` is a victory: the finisher unlocks on it.
  - An approval resets the count, so a later rejection streak must lose three
    fresh rounds to grab again. The record shows this happening to T-067.
  - `merged` and `closed` are final, so a settled task never grabs again.
- **The fight in Live.** It is the game layer. The captain may fight for fun,
  but the kraken is defeated only by the real `approved` event. Nothing in the
  fight writes to the board.
- **No kraken card in Live.** The Playground's four-option kraken card (fight,
  rescope, park, drop) is not shown in Live, because the board has no matching
  action. The grab appears as an event banner ("The kraken holds T-117") and a
  prompt to fight, unless the board itself has a real pending decision for that
  task. In that case the board's card is the card.
- **Playground.** Its kraken is unchanged: the sim's rule (round ≥ 3, 8 arms),
  and its kraken card, where Proceed: fight starts the fight at once.

### 1.5 Projects

| Game needs | Source |
|---|---|
| list of projects | `projects[]` (default first), `default_project` |
| one project only | `?project=<name>` on both `/api/state` and `/events` |
| project flag colour | **none.** The game assigns colours from `projects[]` order, using the same palette as the name-tag flags (`PROJECT_COLS` in `src/hud.js`). The board's own chip colours should be shared if it has any. |
| PR links | `tasks[].pr_url`, `pr_urls`, `pr_urls_by_project` |

Today the simulator's "project" is a task's milestone (M1 to M4). Live, the
project and the milestone are separate fields; the flag uses `project`.

### 1.6 The voyage chart

The simulator has milestones M0 to M4 with Caribbean ports, and makes port when
every task of a milestone has merged. Live, this is built from `tasks[].milestone`
and `merged`. The port names are presentation (a fixed list, by milestone
order). "Making port" becomes a derived event: the last task of a milestone
reaching `merged`.

### 1.7 Events (what drives the rituals)

SSE `/events` sends **`event: state`**, the full `/api/state` snapshot, on every
change to `events.jsonl`, `state/decisions` or `state/pending`. It is polled
every 500 ms, with a heartbeat every 15 s. It also sends **`event: reload`** when
the board page's own files change. It does **not** send individual events. The
adapter derives them:

1. From `recent[]`, the last 40 events, newest first, each
   `{ts, actor, type, task, project?, pr?, data, summary{en,zh-TW}}`. Keep the
   last seen `(ts, actor, type, task)`, and emit the newer ones oldest first.
   40 is a window. If more than 40 events land between two snapshots, the rest
   are lost. The game must tolerate gaps: re-sync from the snapshot, and never
   assume it has seen every event.
2. From `handoffs[]` (with a stable `identity`) and `outcomes[]` (merges and
   decisions, with an `identity`), which are complete lists. Dedupe by
   `identity`.

Mapping from board event types (the real log's counts are in brackets) to the
game's director:

| Board event | Game event and ritual | Notes |
|---|---|---|
| `dispatched` (379) | `order` → bell, whistle, the helm spins, the worker walks to his station | A reviewer's dispatch is a reviewer, not a worker. Use `data.role`. |
| `commit_pushed` (348) | `commit_pushed` → hammer or saw loop | |
| `pr_opened` (47) | `pr_opened` → the scroll is carried to the reviewer | |
| `review_opened` (335) | *(new)* the reviewer takes up the scroll; round + 1 | The simulator has no separate event for this. |
| `review_failed` with rejected (160) | `review_rejected` → back to the station; the kraken at round 3 | |
| `review_failed` otherwise, `gate_failed` (20) | `gate_failed` → squall ("weather, not blame") | |
| `gate_passed` (5) | `gate_green` → clearing | |
| `approved` (87) | `review_approved` → salute; **victory** if the kraken holds the task | |
| `decision_requested` (102) | `decision_requested` → the captain raises the placard; the card comes up | |
| `decision_made` (92) | `decision_answered` → the seal on the card | |
| `merged` (97) | `merged` → salvo; **only after the merge's outcome is `merged`** | |
| `closed` (35) | *(new)* the card leaves the board | |
| `ask_pass_criteria` (223), `criteria_returned` (1) | same names → the worker asks the reviewer | |
| `worker_crashed` (33), `vendor_unavailable` (71) | same names → the hand is down, not blamed | |
| `crew_status` (1314) | *(no ritual)* updates the activity and progress on the detail card | The most frequent event. It must never trigger a ritual. |
| `agent_finished` (678) | the crewman goes ashore | Drives the ship's size (§1.2). |
| `parked`, `unparked` | the card moves | |
| `greenlit` (3) | the firstmate leaves the queued state | |
| *(simulator only)* `task_new`, `island`, `making_port`, `promoted`, `kraken_*`, `battle_begin`, `victory`, `worker_walk`, `work_start`, `recovered`, `course_set`, `caption` | derived by the adapter (`making_port`, `kraken_*`, `victory`) or dropped (`promoted`, `course_set`, `task_new`) | |

### 1.8 Languages

`GET /api/i18n` returns `{en, "zh-TW", tw2cn}`: the board's own dictionaries and
a Traditional-to-Simplified table. The game's dictionaries (`src/hud.js` `T`,
`PHRASES`, `EVENTS`, `DECK`, `OPTS`, `RANKS`) keep their three languages.

Board-authored text (summaries, activities, card details) is authored only in
`en` and `zh-TW`. The game must build zh-CN from it with `tw2cn`, the same way
the board page does. The game's language choice (`v2d-lang` in localStorage)
should become the board's language setting when running inside the board, so
that switching language in one switches the other.

## 2. Actions: what the game sends back

The captain does two things on the board, and the game offers exactly those
two. Dispatching is the firstmate's job, not the board's and not the game's, so
**no dispatch endpoint is needed**.

| Game action | Where it lives | Live: board API | Playground |
|---|---|---|---|
| **Answer a decision card** | a deliberate click on the card's A–D. The keys A–D and Enter work only while the card is on screen. | **`POST /decisions`** `{id, chosen: "A"|"B"|"C"|"D"|"custom", text?, note?}` → `{ok, decision, merge, eventRecorded}`. Errors: 400 (`bad decision id`, `bad choice`, `customInvalid`), 404 (no pending decision), 409 (already recorded differently, or `mergeBusy`). Offering D needs `details.en.options.D`. **A merge card's A really merges** (the board starts `fm-merge.sh`), which is why nothing but a click on the card answers. | changes the sim |
| **Park / unpark / drop a task** | the board menu's card buttons, shown only where the board's `tasks[].actions` allows them (ready and backlog: park and drop; parked: unpark and drop) | **`POST /tasks`** with `content-type: application/json`, body `{task, action: "park"|"unpark"|"drop", project?}` → `{ok, event}`; 409 when the lane does not allow it | changes the sim, with the same lane rule (`BOARD_ACTIONS` in `src/hud.js`) |
| The fight: tap, special, stop | in battle only | none (game-local) | game-local |
| Menu views, language, style, sound, speed, detail, free camera, the rituals | the menu and settings | none (local preferences) | same |

**Removed from the game in both modes** (the captain's decision): dispatch
("give the order", tapping the captain, the Dispatch button, O), Set course,
Survey, Open PR (U), Approve (V), Reject (J outside the fight), red and green
checks (F/G), push (H), New task (N), merge (M), the Auto-play toggle (P),
answering from the stage placard, and Face the kraken on the board. In Playground
the sim does all of this on its own, out of sight.

**Playground only: Hands aboard.** In Playground the captain sets the crew size
freely: Settings, "Hands aboard" (在船人數 / 在船人数), with − and + (and the keys
`+`, `=` and `-` out of the fight), from the fixture's 7 to 24; the ship changes
class with its transform as a cap is crossed. Once he has set it, the crew driver
stops hiring and dismissing on its own. Live has no such control (the board's crew
list sets the count; the sheet only shows it). A hand at work is not sent ashore.

**Playground's kraken.** The first ready task of every simulated voyage is stubborn
(`createSim`: two rounds past the kraken's third, no card on the way), so every
Playground voyage meets the kraken in its first minute or so, and the kraken's card
goes to the top of the deck. Live is unchanged (§1.4). The hooks tests use (`__voyage2d.apply`, `hire`, `dismiss`,
`stage`, `?scene=`, `?crew=`) are sim API, not UI.

## 3. Simulation-only: what must be replaced by live data

| Simulator part (`v3src/sim/sim.js`, `src/battle2d.js`) | Live replacement |
|---|---|
| The seeded world: task titles (`TITLES`), `rounds` per task, `flags` (ask, decision, red, crash, vendor), timings, the schedule | The log. Nothing is predicted; the game only reacts. |
| `CREW_FIXTURE` (the fixed seven: captain, firstmate, reviewer-1, workers 1 to 4) and `newHand()` | `crew[]`, plus the captain added by the game. |
| Ranks, standing, merges, first-pass counts, honours, the service record, promotion events | **None.** Drop them, or compute them later from the log (merges per crew name). |
| Per-crewman vendor | `engine` (board-wide) only. |
| Lanes `issues`; card actions survey and set course; the `course` field | none (§2). |
| Decision generation (choice, merge, scope and kraken cards with `effect`s) | `pending[]` / `responses[]`. |
| `tally()` | `counts`. |
| The review round counter `t.round` | derived (§1.4). |
| The kraken's arms, `kraken.battle`, `battle_begin` | derived from rounds; the fight is local. |
| `step({type:"tick"})` time | wall clock; snapshots arrive whenever the log changes. |
| Milestones and ports, making port | from `tasks[].milestone` (§1.6). |
| Captions from `sim.log` | `recent[].summary` `{en, zh-TW}` (+ tw2cn). |
| The battle reducer (`battle2d.js`: grip, hull, gauge, attacks, specials, the ultimate, the finisher) | **Stays game-local in both modes.** Live, only the finisher's unlock is tied to a real `approved`. |
| The Playground's crew driver (`playgroundTick` in `main.js`: dispatch, new work, hands aboard and ashore) | the real crew; nothing to replace, it simply does not run in Live |
| Staged scenes (`?scene=`), `?crew=N`, `?grip=`, `?demo=1` (the bot fighter), `__voyage2d.*` hooks | Test and proof-shot tools; kept on `SimSource` only. |

## 4. Feature and mode inventory (what the 3D game is compared against)

### 4.1 HUD: game first

- **Status cluster** at the top left: merged, in flight, "waiting on you" (a
  button; it reopens a card put off with Later), and the ship class with the
  crew count.
- **Top right:** the language switch (EN, 繁, 简) and the **menu button**.
- **One prompt** at the bottom centre. It shows only when there is something to
  do on stage: "fight the kraken" once the captain has chosen to fight and
  stepped out of it. It is clickable.
- **Mode badge** at the bottom left, persistent: PLAYGROUND · simulated,
  遊樂場 · 模擬, 游乐场 · 模拟.
- **Deck icon** at the bottom right, while a card is folded away with Later.
- **Toasts** at the top left, at most 3, fading after about 4 s. They show board
  events in the current language, with an icon, and gold for good news.
- **Banner**: the stage's big lines, tilted, including the three-language "The
  ship grows: …" and "The ship trims down: …".
- **Stage hint**: a pulsing ring on the kraken when a chosen fight waits.
- Everything is hidden in the fight and in the ending; X hides the HUD.

### 4.2 Menu (the game pauses behind a dimmed red overlay)

Tabs are Board (B), Roster (L), Chart (T), Settings (K) and Resume (Esc). Esc or
tapping outside also resumes.

- **Board**: six lanes with card counts. Each card shows its id, title and tags
  (milestone, issue or chat, round, gate red, kraken, approved, course, worker)
  and, only where the board allows it, Park and Drop (ready and backlog).
- **Roster**: a table with one column per field (name, role, project, task,
  round, PR, state, activity, rank, vendor), grouped into Command, Review, and
  Workers by state. It is readable at 24.
- **Chart**: the voyage as ports on a line, the merged share of each leg, the
  ship's position, and the fog of uncharted issues.
- **Settings**:
  - language;
  - hands aboard (count and class, read only);
  - sound and free camera;
  - speed (1× to 3×);
  - detail (high or low; reloads);
  - style (Crimson or Manga);
  - the six rituals, each on or off: order, merge salvo, making port, salute,
    clearing, weather.

### 4.3 Decision cards

- Shown only while a decision waits. The card has a kicker, title and body, the
  **infographic** (§1.3: the board's diagram in Live, a drawn before/after in
  Playground), and big A to D options (label, pros, cons). A is marked
  recommended.
- The infographic follows the option under the pointer, the focus or the pick.
- It is answered only by a click on the card itself. The keyboard uses A–D, then
  Enter, and only while the card is on screen.
- **Card-game FX** (under 500 ms each, off with reduced motion):
  - the card is dealt from the deck with a flip, and the options fan in;
  - hover lifts and glows; the pick pulls forward;
  - confirming stamps a wax seal and the card flies off;
  - **Later** tucks it into the deck icon, and the deck or the waiting chip deals
    it again.
- Crimson and Manga have their own card looks.
- The captain still raises the placard on stage while a card waits. It is only a
  picture: it cannot be tapped to answer.

### 4.4 Name tags and the detail card

- The tag above each character is only the name and a small flag in the
  project's colour (grey with no task). At 24, tags never overlap: they stack
  up to 3 rows, then shrink to 80%, then hide. They appear in the wide shot
  only.
- The detail card opens on hover, tap or keyboard focus (each crewman is a
  focusable button) and is anchored to the character. It lists name, role,
  project, task and title, round, PR, state, activity, rank and vendor, one
  labelled line each. One is open at a time; Esc or a second tap closes it. It
  is in three languages.

### 4.5 Rituals (the director)

Each ritual is driven by a board event, and each has an off switch:

- the order (bell, whistle, helm spin, walk to station);
- work loops by station (hammer, saw, haul and so on);
- the hand-off scroll to the reviewer;
- rejection back to the station;
- the salute on a first-round approval;
- squall and clearing ("weather, not blame");
- the placard on a decision;
- the merge salvo, where every gun row fires in waves;
- making port;
- promotion;
- hand down;
- new island / task;
- the cheer.

The camera cuts between wide, deck, bow, helm, guns, sky, kraken, battle and
crew close-ups and two-shots, with free-camera mode as an alternative.

### 4.6 Ship tiers (by crew count)

| Class (EN · 繁 · 简) | Hands | Build | Crew scale |
|---|---|---|---|
| Sloop · 單桅帆船 · 单桅帆船 | ≤ 7 | 1 mast, 4 guns, 1 gun row | 1.00 |
| Brig · 雙桅橫帆船 · 双桅横帆船 | ≤ 12 | 2 masts, 6 guns | 0.95 |
| Frigate · 巡防艦 · 巡防舰 | ≤ 18 | 3 masts, 7 guns | 0.90 |
| Ship of the line · 戰列艦 · 战列舰 | ≤ 24 | 3 masts, 10 guns × 2 gun decks | 0.84 |

- Every hand has a spot on the walkable decks (§5): the captain at the wheel, the
  firstmate on the quarterdeck (clearly apart), the reviewer on the forecastle,
  hands at work at their stations (guns, rigging, lookout), idle hands in the
  waist, then the hold, then the gun decks. The hull is a cutaway, so the decks
  below the waist show.
- The **transform** takes 3.2 s:
  - the hull stretches, and masts and yards grow in (planks, steam, トンカン!);
  - the masts snap in with sparkles (ジャキーン!);
  - the camera pulls back past both hulls, then settles;
  - a three-language banner appears;
  - a bell rings and the crew cheer;
  - new hands fade in once there is room.
- It shrinks back the same way ("trims down"); hands step inboard first.

### 4.7 Battle (the kraken)

- **Entry (Playground):** round 3 → the kraken rises → its card (fight,
  rescope, park, drop) → **Proceed: fight starts the fight at once.** After the
  captain steps out with Esc, the prompt or tapping the kraken takes it up again.
- **Entry (Live):** a task past three lost rounds grabs the ship (§1.4). A banner
  and a prompt to fight replace the card. Only the real approval finishes the
  kraken.
- **Input:** tap only. One prompt says what a tap does now (fire at will, parry
  at the gold, dodge a sweep, shoot the ink, brace, counter). It gives generous
  windows, and too-early taps are free.
- **Bars:** grip (the arms' hold on the tasks), hull, and the special gauge.
- **Specials** fire when the gauge is full, from the special button or K, in
  rotation:
  - Broadside (舷側斉射);
  - Harpoon & Chain (魚叉鎖鏈);
  - All Hands (総員砲撃);
  - plus Riposte on a perfect parry.
- **Ultimate** (the maelstrom) at 60% and 25% grip: brace, then parry. The
  answer is the Counter Broadside.
- **Finisher** at 0 grip: tap to strike. Then the all-out frame and the hero
  ending: the whole crew in one or two ranks, the captain in the middle and the
  firstmate at his right, fireworks, and the VICTORY card. The held tasks are
  approved.
- **Specials escalate with the ship class:**
  - Sloop: one gun, a small cut-in band.
  - Brig: twin guns, a full band, a bigger shockwave.
  - Frigate: a three-gun volley, a three-panel cut-in, the sea split by water
    columns.
  - Ship of the line: every gun deck firing in waves, the whole-crew cut-in
    montage (7 panels) with a title slab, letterbox, slow-mo, lightning, a
    camera push, and a longer hold.
  - The ultimate and the finisher use the same cut-in scaling.
- **Feel:** hit-stop, trauma shake, impact frames (white, black, invert, mono,
  red), ransom lettering, SFX lettering (ドン! and so on), the zoom blur (desktop),
  motion trails, the relit crew.

### 4.8 Languages

- EN (default), 繁體中文 and 简体中文 for every HUD, menu, card, toast, banner and
  battle-prompt string, including ranks, states, activities and ship classes.
- The choice is remembered in `localStorage` (`v2d-lang`, in a try/catch) and
  can be overridden with `?lang=`.
- Move names in cut-ins stay stylised as English plus Japanese in all languages.

### 4.9 Styles

- **Crimson** (緋紅, 绯红; the default): red, black and white, torn bands,
  ransom lettering, the all-out silhouettes.
- **Manga** (漫畫, 漫画): ink panels, speed lines, kanji move names.
- The choice is stored as `v2d-style` and can be set with `?style=`. Internally
  the styles are still named `p5` and `manga`.

### 4.10 Other modes

- **Playground** (the standalone build): the sim runs the voyage on its own.
  Its firstmate dispatches, its reviewers do their rounds, new work joins, hands
  board and leave (so the ship grows and trims), and the kraken rises. The
  captain answers cards and fights. There is no Auto-play toggle; the bot
  fighter survives only as the test hook `?demo=1`.
- **Live** (after integration): the board's data, the same controls, and the
  writes of §2 only.
- **Speed** 1× to 3×; **detail** high or low (low on phones: DPR 1, no zoom blur,
  fewer particles); **free camera**; **sound** (synthesised, off by default).
- **Phones**: stage-first layout, 44 px touch targets, the menu as a bottom
  strip, the board lanes scrolling sideways, the whole ship in portrait.
- **Keyboard**:
  - A–D and Enter for cards; B, L, T, K for the menu tabs; Esc;
  - S sound, C camera, X hide HUD;
  - Q (or a tap on the captain) takes the deck: ← → / A D walk, ↑ ↓ / W S take
    stairs and ladders, E lends a hand (Playground), Q / Esc back (§5);
  - in the fight: Space, J or Enter to tap, K for the special, Esc to stop;
  - the old simulator keys (N, O, U, M, V, J, H, F, G, P, `+`, `-`) are gone.
- **Test and proof hooks**: `?scene=` (order, work, review, squall, merge,
  decision, port, kraken, battle, ultimate, finisher, victory), `?crew=N`,
  `?grip=`, `?seed=`, `?demo=1`, `?detail=` and `window.__voyage2d`.

## 5. The walkable ship and the captain on deck (both modes; cosmetic)

The decks, their obstacles, the stairs, ladders and shrouds between them, the
stations and the crew's walking live in one renderer-free module shared with the
3D game: `v3src/sim/deckplan.js` (3D: `src/sim/deckplan.js`, byte-identical). Its
API and what the 3D must supply are in `docs/movement-spec.md`, "For the 3D pass".

| | Playground | Live |
|---|---|---|
| Crew walk the decks (A* over decks and links, deterministic, no overlaps) | yes | yes (driven by the same events) |
| The captain takes the deck (Q, a tap on him; phones: joystick, ▲ ▼, ✕) | yes | yes |
| Mini-games at a working hand's station (E / tap): gun, rigging, crow's nest, reviewer | yes; a win is a local morale count | **never shown** |
| Writes | none | **none**: nothing in the walk or the games reaches `source.command` |

Key precedence (`src/main.js`): Esc closes the innermost thing first (menu, crew
card, mini-game, the decision card, then the deck); the fight's keys; a mini-game's
keys; the card's A–D and Enter while it is on screen; then the walk (← → A D, ↑ ↓ W
S, E, Q). In the fight and the endings the deck closes and the captain returns to
the wheel. The HUD file gained one hook, `h.settingsExtra`, for the Settings row
that lists these keys (copied into the 3D's shared `hud.js`).
