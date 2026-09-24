# Prototype v2: the living ship (T-070), with its emotional layer (T-086)

A design prototype of the whole captain's board, for the captain to approve
before T-060 to T-064 and the motion task build it: the ship on a living sea,
and around it every region the live board has today, in the ship's visual
language. It is design only: fixture data, no backend, and nothing changes
unless the captain acts on the page or presses a switch. The production board
is rewritten from it, not promoted from it.

| File | What it is |
|---|---|
| `prototype.html` | the prototype; open it from disk, no network. T-086 adds the emotional layer (see [The emotional layer](#the-emotional-layer-t-086)) |
| `motion-spec.md` | every moving thing: period, amplitude, curve, trigger, meaning, reduced-motion replacement; the weather table; the CPU budget and how to measure it; T-086's section for the chart, ranks, rituals, the kraken and the battle game |
| `sound-spec.md` | every sound (T-086): what makes it, how long, how loud, what triggers it; the ambient sea; all of it off until the captain turns it on |
| `fonts/` | the two OFL faces as four woff2 files, and each family's OFL licence text (see [Fonts](#fonts)) |

## The page

Top to bottom, in design.md section 8's order. Everything below works on fake
data, and every interaction the live board has works here too.

| Region | What it holds | What works |
|---|---|---|
| Header | live mark, brand and project, the engine badge (`claude ⇄ codex`), green-lit state, the hour, the language switch | EN, 繁 and 简 switch every label, event summary, decision and diagram on the board |
| Tally | merged, in flight, waiting on you, blocked, ready, backlog | each figure rolls to its new value when it changes |
| Decision deck | the captain's portrait in a brass porthole beside the first call in full; further calls as one-line strips that open in place | pick an option, write your own answer (1 to 1000 characters, checked), confirm; the choice card has A, B, C, D and your own answer, the merge card A, B, C, your own answer and the seven gates; each has its authored diagram in a frame, and under it (T-086) the picked option's diagram, before and after |
| The ship | the approved scene, unchanged in look | reads the board: the lanes and the crew are the same state |
| Caption and roster | what just happened, in words; the crew roster, toggled from the caption bar | rows carry a state mark, name, stage, pull request, the vendor and model the run uses (workers and reviewers), task, and the run's authored activity; a bar only where the run reports a real denominator (the reviewer's files) |
| The fleet | seven ruled columns on one chart sheet: backlog, ready, working, gate, review, captain, merged (eight since T-086: issues comes first); the parked group (collapsed) and the drop target below; the completed history (collapsed) | park and drop by the `⋯` menu or by dragging; unpark by the menu or by dragging onto ready or backlog, landing where the dependencies say; drop asks in the page first; Escape closes a menu or the confirmation; `#n` links open the pull request |
| Live log | the ship's log, newest first, with a state mark per event kind | every captain action and board moment writes a line |

Answering a call acts on the whole page: a choice or a sent-back merge is an
order (bell and whistle, the helm spins, all hands answer) and the card leaves
the captain column; merging plays the salvo; holding a merge parks it. Nothing
is dispatched: a task set free goes to ready and waits there.

## Switches

Every state the captain has to judge is one switch away. Since T-086 the
switches live in the floating controls at the lower right, which one control
(or `K`) hides and shows, so the ship stays in view. Keys work anywhere on
the page except inside a text field, a card's action menu or the drop
confirmation, so a letter typed there never fires a switch.

| Switch | Key | What it shows |
|---|---|---|
| Time of day | `T` cycles | local time (the default), dawn, day, dusk, night |
| Weather | `W` cycles calm, breeze, squall | the scenario the board's state comes from; the sea shows what that state supports. The page opens in a squall so the deck is on screen at first sight |
| Clearing | `M` | a merge: the card slides into merged and the tally rolls, then light breaks, the salvo, the bell, then back to the weather the state supports |
| Live runs | `L` cycles | 1 to 3 runs in flight; wind and way scale with them |
| Rate | `1` to `6` | cutter, schooner, frigate, ship of the line, flagship, man-o'-war (D-1009); sets the crew to the rate's largest count (3, 5, 8, 12, 18, 24). Masts follow D-1024: one for 1 to 3 crew, two for 4 to 8, three from 9 up, so the rates carry 1, 2, 2, 3, 3, 3 masts. Decks (1, 1, 2, 2, 3, 4) and length grow with the rate, and guns with the crew, one more for every two hands (`4 + ⌈crew / 2⌉`: 6, 7, 8, 10, 13, 16 at the rates' largest counts) |
| Crew | `[` and `]` (also `-` and `=`) | 1 to 24 aboard; the rate follows the crew, as on the board |
| Crew action | `A` cycles, or the menu | every crewman on one action, or as assigned by deck and state |
| Captain | `C` cycles | idle (sheathed), ready (cutlass half drawn), order (raised) |
| Handoff | `Q` order, `P` pull request, `Y` approval, `X` rejection | one handoff of that kind between the right figures |
| Merge salvo with bell | `M` | the same as clearing. It merges the pending merge card's task, or else the oldest task in review; with no merge card waiting and nothing in review, nothing can merge and the caption says so |
| Order with bell and whistle | `O` | D-1010: bell, bosun's whistle, the captain raises the cutlass, the helm spins twice, the crew salute, the order passes to the firstmate |
| Motion | `R` | on, or off (the reduced-motion scene); starts from the system setting |
| Sound | `S` | the synthesised bell, whistle, cannon and T-086's effects; no audio files. Off until you turn it on (T-086; T-070 opened with it on). Its switch is in the controls' "On the board" group, beside the ambient sea |
| A pull request opens | `U` | a working run opens its pull request: the card slides from working to review, the pull request handoff flies to the reviewer, the run stands by |
| A new task arrives | `N` | a task joins the plan and its card fades in on ready or backlog (three in the fixture) |
| Reset the board | | back to the opening fixture |

The board's own interactions (the menus, dragging, the deck, the language) are
on the page itself and are not repeated as switches. What demonstrates each
live moment of the page (Q4):

| Moment | Shown by |
|---|---|
| a card slides to its new lane | `W` between breeze and squall (a ready task goes to the gate, two go to the captain, and back), `U`, `M`, park and unpark, answering a merge card; merging T-064 also slides T-069 from backlog to ready |
| a new card fades in | `N`, or unparking while the parked group is closed |
| counts roll to their new value | any of the above |
| a merge plays the salvo across the ship | `M`, or confirming A on the merge card |

On the scene itself: click a figure or its pennant to read it (the pennants
are buttons, so the keyboard reaches them too); drag a figure to turn it, drag
a deck to turn all hands, double-click to reset.

The line under the scene narrates what just happened, in words, in every mode.
The meter at the bottom of the switches reports the engine's frame rate, script
time a frame, how often the vessel was re-set, and how many crew faces are
live.

## What it is built from

- **Sky, sea and hull are layered SVG**, built once per hour or size and then
  only translated. Sky, sun or moon, stars and the light that breaks on a merge
  are one SVG; clouds, a squall band, far islands, far wavelets, mid swell,
  near swell, crests and a foam band are tiled parallax bands.
- **The ship is one SVG**: every deck is the same lens curve scaled, the hull
  is the main deck's curve extruded to a keel, and the rig stands on the top
  deck in a second SVG on top of it.
- **The crew stay DOM**, the prototype's box figures, so they can be dragged
  and clicked, and so browser tests can assert classes (`.fig.s-<state>`,
  `.a-<action>`, `.c-<pose>`) rather than diff screenshots. Those state
  classes belong to the scene; the page around it uses its own names (the
  header's `.livemark`, the state marks' `.m-<lane>`, the caption's
  `.selinfo`), so no page rule can land on a crewman.
- **A small engine** (easing curves, damped springs, tweens, one frame loop)
  drives the swell, the parallax, spray, wake, weather changes, heel and
  handoffs. CSS keyframes drive crew loops and one-shot reactions.

## Parity with prototype v1

| v1 element | In v2 |
|---|---|
| Perspective elliptical decks with planks | every deck is one lens curve: far edge arched, near edge bowed; eight fore-and-aft seams that meet at the ends, and staggered butt joints; a light pool on the key-light side |
| Riser walls | each upper deck hangs a riser down to the deck below, with a brass moulding |
| Capped bulwarks | a far bulwark rises above each deck with its inner face lit and a brass cap; the near edge carries a brass cap rail over a shadow line |
| One hull volume | the main deck's curve extruded to a keel: sheer rising to the stem and the stern, raked stem, a transom counter; three wales, brass mouldings, a boot-top at the waterline, and the key light across the hull |
| Figurehead and trailboard | the gilded figure leading the bow, with a scrolled gilt trailboard under it |
| Masts from the top deck | spaced over 84% of the top deck; shrouds and ratlines to its edges; stays fore and aft; bowsprit, jib boom and jib |
| Exactly one main mast with the red course, skull and Jolly Roger | mast number `floor(masts / 2)` counting from the bow at 0: the only mast of a cutter, the aft mast of two, the middle mast of three: ensign-red course with a skull and crossbones in sailcloth, a royal above the others, the Jolly Roger at its head; every other mast carries sailcloth and a brass truck |
| The captain's full outfit and two-arm poses | ensign-red coat with tails, brass sash, buckle and epaulettes, tricorn with brass trim and a plume, eye patch, beard, scabbard at the hip and a cutlass that is in his hand only when drawn; idle, ready and order move both arms |
| Deck-pooled crew actions with left-hand tools and deck props | top deck lookout, signal, point, log; amidships haul, capstan, carry, climb; main deck hammer, saw, swab, carry; idle pool lean, coil, mend. Every action holds or stands at something: spyglass, flags and flag locker, rolled chart and chart table, quill and logbook, line and belaying rail, capstan and bar, crates, ratline, hammer and sea chest, saw and sawhorse, swab and bucket, barrel and belaying pin, rope coil, sailcloth and needle |
| Per-kind handoff arcs | order, pull request, approval and rejection each have their own object, arc height, easing and spin (motion spec) |
| Smoke with the salvo | one flash and one puff per gun port, on the same clock as that gun's report |
| Helm and stern lantern | the helm beside the firstmate on the top deck; the lantern at the stern end of the top deck, lit after dark |

Nothing v1 or design.md excludes comes back: no percentages, no progress bars
without a real denominator, no random progress, no simulated dispatch; one
captain, on the top deck; secondary text at least 13 px and primary text at
least 16 px.

## Design decisions

The plan's direction is kept: a tilt-shift ship-model diorama that evolves the
prototype's figures, with materials rather than accents, a sky that follows
the captain's local time, and weather that reads the board's state.

**The palette is the plan's materials.** Stockholm tar for the hull, sailcloth
for sails and pennants, brass for fittings (rails, trucks, bell, helm, lantern,
figurehead, the name plate), ensign red for the main course and for anything
blocked or rejected, sea-glass for approval, review and calm-water highlights,
Prussian ink for night water and the captain's pennant. Deck timber is a
weathered oak between tar and sailcloth, so the deck reads as wood without
adding a new colour.

**The hour lights everything.** Four keyed palettes with the plan's anchor
colours. The key light sits where the sun or moon is; figures take it on their
side faces with a rim on the lit edge; contact shadows fall away from it; the
timber and canvas dim at dusk and night; stern windows and the lantern are lit
after dark.

**Weather is read from state.** The weather switch picks a scenario; the
scenario sets crew states; the sea shows what those states support. Calm is no
run in flight, a breeze scales with live runs, a squall is a red gate plus a
card waiting on the captain, clearing is a merge.

**Nothing moves for decoration.** Only the swell moves on its own. Crew loops
run only on live runs; idle crew stand at their prop and blocked crew sag and
hold still; the ship is still on her mark in a calm, with slack sails and a
hanging flag.

**Pennants, not cards.** Name tags are sailcloth pennants on a brass staff with
a swallowtail fly. State is in the hem and the fly: tar for working, sea-glass
for review, an ensign-red fly for blocked, brass for waiting on the captain;
idle pennants are dimmed. The captain's pennant is ink with an ensign hem. On a
crowded deck names shorten (worker-12 reads w12) instead of being cut off; the
full name is in the accessible label and the caption.

**Every worker's and reviewer's pennant names its engine.** Under the name, in
the same weight as the job, each flies the vendor and model its run uses:
`claude · opus-5`, `cursor-agent · composer`, `codex · gpt-5.5`. The line is
never cut: where the deck has room it is one line, and where the one line would
be wider than the space to the next crewman it stacks, vendor over model. The
roster row carries the same words on a line of its own, and the pennant's
accessible label reads "worker-1 on claude · opus-5, working on …".

**Type in two roles.** IM Fell English SC appears in one place, the brass name
plate on the stern quarter: the ship's name and her rate ("Firstmate, a
frigate of two masts, two decks"), so the rate is legible without a label. Everything
else is Barlow Semi Condensed, sentence case, no monospace.

### The page around the ship: a ship's log and a chart table

The frontend-design first pass for the page, reviewed against the plan and the
generated-design defaults before it was built:

- **Colour.** No new colours. The page is the hour's page tone (mist by day,
  pearl at dawn, violet at dusk, ink at night) with one lighter chart sheet per
  hour for the lanes, the calls and the log. State is carried by the plan's
  materials: ensign red for blocked and for dropping, sea-glass for review and
  approval, brass for what waits on the captain, the page's ink for work under
  way.
- **Type.** Barlow Semi Condensed everywhere on the board: titles 16 px, call
  titles 22 px, the tally 30 px, secondary text 13 px, all tabular where they are
  numbers. IM Fell English SC stays in its one place, the name plate. CJK falls
  back to PingFang or Noto Sans CJK.
- **Structure is rules, not boxes.** The seven lanes are ruled columns of one
  chart sheet with a double neat line, each headed by a ledger's double rule;
  cards are log entries separated by a hairline, square, with no fill of their
  own and no shadow. The tally is the head line of the log, a heavy rule over
  six figures. Nothing on the page is a rounded card.
- **The state mark is the crew's pennant.** Every card, roster row and log line
  carries the same swallowtail the crew fly on deck, in its state's material,
  so the lanes, the roster and the ship read as one system. Badges (gate
  failed, a call with its options, asked for the pass criteria) are small
  swallowtail pennants too.
- **Brass is a fitting.** It appears as the porthole ring, the rivet on the
  engine badge, the strip over "waiting on you", the rule under the captain's
  column and the one button that sends an order, which is a brass plate with
  its words cut in like the name plate. It is never the colour of text.
- **Quiet everywhere but the ship.** The page has no hover lifts, no entrance
  animations and no decoration; it moves only on a change of state, as listed
  in the motion spec.

### Changes from firstmate's plan, and why

1. **The name plate is a brass plate with the letters cut in.** The plan lists
   brass for "lettering" and also says brass is not a highlight colour for
   text. Engraving reconciles both: brass stays a material, the letters are
   tar.
2. **The page around the ship follows the hour too.** A mist-grey page by day,
   pearl at dawn, violet at dusk, ink at night, each with ink or sailcloth
   text. A fixed dark page would be the "dark background plus one bright
   accent" default the plan rules out, and a fixed light one would glare at
   night.
3. **Loops only on live runs.** v1's random hops every 7 to 15 s, the slowly
   spinning helm, the flickering lantern and the idle crew's weight shift are
   gone: they moved for decoration. Idle crew hold their prop, blocked crew
   sag without v1's slump loop, and the helm moves only while the firstmate
   coordinates live runs.
4. **The cry is in sentence case.** "Ahoy! Merged into main" and "Aye,
   captain. Orders away" replace v1's `AHOY! / MERGED INTO MAIN` in capitals
   and monospace: the plan wants sentence case and no monospace labels. It is
   still English in every locale.
5. **Clearing is a moment, not a weather you stay in.** For 6 s after a
   merge the sea runs as a breeze of the live runs (at least one) with the
   cloud band gone and light whitecaps, even if a gate or a call would
   otherwise hold a squall; then it returns to what the state supports, since
   a merge does not change how much work is in flight.
6. **The captain stands at the stern of the top deck**, facing forward, with
   the firstmate and the helm at the bow as design.md anchors them. The order
   moment passes an order from the captain to the firstmate; the separate
   order handoff is the firstmate dispatching to a worker, as design.md lists
   it.
7. **Bell and whistle on an order follow D-1010**, which the task cites.
   design.md section 8 still says the later captain override disabled bell
   and whistle audio; the task that builds the order moment updates that
   paragraph.
8. **Budget measures the plan did not name.** The frame caps, the
   quarter-pixel rule for the vessel and three faces per crew box came out of
   measuring: at 24 crew the box faces are what the scene spends its time on
   (motion spec, CPU budget).
9. **The bowsprit shortens at the widest rates** so the head of a man-o'-war
   stays in frame.
10. **The page opens in a squall.** A card waiting on the captain is a squall
    by the plan's own rule, so a page that shows the decision deck at first
    sight has to open in one. The approved scene's other weathers are one `W`
    away.
11. **The weather reads pending calls directly.** The first version set the squall
    from the switch; now any red gate or pending call raises it and nothing else
    does, which is the plan's definition and what the live board will compute.
12. **The live board's capitals are set in sentence case.** Its dictionaries
    have `CREW ROSTER`, `CONFIRM` and a `CUSTOM` option, and its badge prints
    the literal `ASK-PASS-CRITERIA`. Here they read "Crew roster", "Confirm",
    "Your own answer" and "asked for the pass criteria", as the plan's
    sentence-case rule asks. The dictionary change belongs to the task that
    builds the page.
13. **The captain's column is marked, not coloured.** It gets a faint ink wash
    and a brass rule only while something is in it, rather than the live
    board's purple border, which is an accent colour outside the materials.
14. **zh-CN needs 60 more characters in `i18n/tw2cn.tsv`.** The page derives
    zh-CN from zh-TW through the board's own table, copied in; its fixture
    text uses characters the table does not carry yet (連, 風, 雲, 燈, 鐘 and
    others), listed in `TW2CN_EXTRA` in the script. The live board will need
    them as soon as its summaries use those words.
15. **At most three masts (D-1024).** The rate switch still runs cutter to
    man-o'-war (D-1009), but the masts are read from the crew: one for 1 to 3,
    two for 4 to 8, three from 9 up. This supersedes the "1 to 6 masts" in the
    task's switch list, which predates D-1024. The rate names stay as D-1009
    has them, so the frigate (6 to 8 crew) carries two masts and says so on its
    name plate. As D-1024 says, decks, length and guns still grow with the
    crew: decks and length through the rate the crew sets, and guns with the
    crew itself, `4 + ⌈crew / 2⌉`, from 5 for one or two hands to 16 for 24.
    On a hull too short for that many ports at full size (a phone width) the
    ports are cut smaller, down to about a third, rather than fewer.
16. **The vendor and model are fixture data until T-085.** Workers cycle
    through `claude · opus-5`, `cursor-agent · composer` and
    `claude · sonnet-5`; the reviewer runs `codex · gpt-5.5`. The header's
    engine badge (`claude ⇄ codex`) stays the configured default; a run may
    differ from it, which is why the pennant names the run's own. The firstmate
    and the captain carry no engine line: the captain's feedback names workers
    and reviewers, and the top deck is the most crowded.
17. **The rig is hung above the tallest pennant actually flown.** The engine
    line makes a pennant one line taller, or two where it stacks; the sail
    clearance is now 16 px a line of the tallest pennant on deck, so no pennant
    reaches a course at any crew count.
18. **The captain's pennant flies aft from its staff.** He is always the
    aftmost figure on the top deck, so his wider pennant now spreads toward the
    stern instead of over the crewman forward of him. With this and the
    stacking in 16, no two pennants overlap at 1 to 24 crew at 1280, 1366 or
    1440 px, which also clears the overlaps the earlier layout had at 5, 12 and 18 crew.

## The emotional layer (T-086)

Settled with the captain on 2026-09-24: **companionship first, then
accomplishment**. Every beat answers a real event on the board. Nothing is
timed, nothing is random, no progress is invented, and the information density
and the 13 px and 16 px floors are T-070's. It is design only, for the captain
to approve before implementation tasks are opened. Everything below works on the
same fixture as the rest of the page.

### What the page gains

| Region | What it holds | What works |
|---|---|---|
| Header | *Ship's customs* beside the language switch | the customs open a panel of switches |
| Ship's customs | six rituals, each with its own switch | each ritual can be switched off |
| The controls | a drawer floating at the lower right, over the page: "On the board" (the playground switch, sound effects, the ambient sea), then the playground's triggers while it is on, then the prototype's switches | its tab or `K` hides and shows it, so the ship and a battle stay in view without scrolling; it remembers whether it was shut. Both sounds are off until turned on |
| The greeting | one sentence of true numbers on the day's first visit, above the tally | "Good morning, captain. Three made port overnight, two cards wait on you, and a squall is up." (早安，船長。昨夜入港三艘，兩張卡等你定奪，海上起了風暴。) The numbers are counted from the fixture: merges since the last visit, cards pending now, the weather the state supports. A battle of three or more rounds the day before adds a second line |
| The scene | the kraken, its tags, the battle band, the combat card, the skill bar, the attacks' wind-up bar, fireworks | see below |
| The voyage chart | a slim band of chart paper under the ship, always visible | ports, the ship's place, ready islands, backlog islands behind reefs, the fog of issues, the course set |
| The fleet | an eighth column, *Issues*, left of backlog; tags on every card; two more card actions | survey or skip an issue; raise a chat task as an issue; face the kraken |
| The roster | each worker's and reviewer's rank, where he is now, and a service record | open a record to read standing, the next rank, honours and entries |
| The deck | every decision card is a strategy-game card (below); three new kinds: a spec card for a surveyed issue, an issue card for a chat task, and a readiness card for a task that became ready; on every card, the option's diagram | answer them as any card; each has its authored diagram. Under it, the picked option's diagram (restored from prototype v1): *Pick an option first* until one is picked, then BEFORE → AFTER for that option, switching the instant another is picked; your own answer's AFTER is your words as you type them |
| Playground | a banner, a hatched frame and a panel of triggers in the controls | anything can be triggered; nothing is written; turning it off restores the board as it was |

### The voyage chart

- **Ports are milestones**, with the nautical names the captain sets in
  `config.yaml` (below). Hover or focus a port for the real milestone: its id,
  title, merged of total, and whether the ship has arrived, is bound there next,
  or it lies ahead.
- **The ship's place comes from merged tasks only**: between the last port
  reached and the next, at merged ÷ total of the current milestone. A milestone
  with no tasks yet is ahead, not reached.
- **Ready tasks are islands on the route ahead**, on their milestone's leg.
  Clicking one opens its readiness card; *Set course* is the proceed answer on
  that card, logged as such. Setting course on several islands draws a dotted
  brass route through them in the order chosen, with a numbered flag on each
  and a "course 1st" badge on the fleet card. Nothing sails from the prototype;
  on the live board the firstmate dispatches in that order.
- **Backlog tasks are islands behind reefs**, and the reef carries the id of the
  task it waits on (a parked or dropped blocker says so on the island's card).
- **Open GitHub issues are uncharted islands in the fog** at the chart's far end.
  *Survey* has the firstmate draft a spec and raise a spec card; approving it
  clears the fog (the island fades up on its leg as the new task). *Skip* hides
  the issue from the Issues lane and leaves the island in the fog, dimmed.
- **The chart sails the way the ship does**: ahead is to the left, as the ship
  above points her bow left; home is at the right edge and the fog of
  uncharted issues at the left. Legs already sailed are drawn short.
- **One chart a project.** With two projects in the fleet the chart has a
  project switch; tidewater's voyage is its own.

### Ranks and service records

- **Workers** rise deckhand, able seaman (3), bosun's mate (10), bosun (25),
  quartermaster (50). Their standing is merges plus a bonus for each merge
  whose first review approved it (`first_pass_bonus: 0.5`, so a first-pass
  merge counts one and a half). **Reviewers** rise apprentice inspector,
  inspector (10), chief inspector (40), by approvals never later overturned.
  All thresholds are config.
- **Only merges and approvals move a rank.** A promotion writes one log line
  ("worker-1 rated able seaman (3 merged, 2 on the first review)"), an entry in
  the service record, the new outfit and braid, and one turn on the spot.
- **The outfit** (on deck): able seaman an ensign kerchief; bosun's mate a
  striped shirt too; bosun a brass bosun's call on its chain; quartermaster a
  dark coat with brass buttons and a brass cap band. Inspector brass
  spectacles; chief inspector a sea-glass sash and a brass band on the hat.
  **The pennant** carries a rank braid along its head, which takes no room
  from the words: tar dashes counting the rank, brass for the top rank,
  sea-glass for reviewers.
- **One fleet across projects**: the roster says "one fleet across 2 projects",
  and each row carries a project badge for where that crewman is now (worker-2
  is on tidewater's T-078 in the opening squall).
- **The service record** in each row: rank, standing in true numbers, the next
  rank and its threshold, honours (from real kraken battles) and entries (merges,
  approvals, promotions), newest first.

### Rituals

Each answers one real event, lasts under two seconds, and has its own switch.

| Ritual | Event | What happens |
|---|---|---|
| Making port | a merge completes a milestone | the chart's ship glides to the port, which rings; three bursts of fireworks over the ship; two bells |
| A salute | the review approves a task on its first round | the reviewer and the worker salute in turn; their pennants swell; the whistle |
| The greeting | the day's first visit | one sentence of true numbers (see above) |
| Clearing and a cheer | a red check turns green | the light breaks for 1.6 s and the crew cheer once |
| Weather, not blame | a red gate | the man on the gate is no longer drawn sagging and dimmed alone: he and up to two idle hands haul one line together in the squall. The pennant still names the blocked task |
| The kraken | a task at review round three without approval | below |

### The kraken

- **One kraken**, with one arm per held task, at most eight (more are named in
  one tag by its head). Each arm carries a sailcloth tag with its task id and
  round, tied on below the rail so it never covers a pennant; clicking the arm
  or the tag opens its combat card.
- **Nothing held**: only a blurred shadow on the horizon.
- **Menacing but a little comic**: one large brass eye under a heavy, lowered
  lid and a scowling brow; it blinks when hit; its pupil goes round with
  surprise when it loses; the last arm down raises a scrap of sailcloth like a
  white flag.
- **Outcomes follow the captain, and the kraken flees whole.** *Drop* (from
  the combat card, or the board's own menu or drag) drags that arm down and
  sends the whole kraken down with it, **whatever else it holds**: the other
  arms dive and the head goes under. *Rescope* shrinks the whole kraken to the
  distance, where it waits small on the horizon while the rescoped work is
  unmerged, again whatever else it holds. A task it still holds keeps its
  kraken badge on its card, and a tag by the kraken below or far off ("still
  held; the kraken waits below"). The kraken comes back only on a real event:
  a rejected round on a task it still holds, a task newly held, or the captain
  facing it (that tag, or *Face the kraken* on the card). Nothing brings it
  back on a timer. *Park* makes the arm let go. *Proceed* and *re-dispatch*
  resolve it: the battle begins.
- **The battle follows real progress**: a rejected round is the kraken striking
  the deck (the ship heels, a rail section splinters), a new push is a hit, a
  red check thickens the storm. When the review approves, the battle is won:
  the victory animation and a synthesised fanfare of about four seconds,
  played once per approval. The honours go into the worker's and the reviewer's
  service records, and tomorrow's greeting carries the line.

**Combat mode.** A tentacle opens its task's real actions: re-dispatch,
proceed, rescope, park, and drop (the board's existing action, which the
outcomes above need). Each asks for a confirmation in place. Only a confirmed
action lands a blow; the action is written to the board first and the blow
follows it; the whole sequence is under three seconds (motion spec).

### The battle mini-game

In a real battle the band over the scene offers *Play along*. Skills touch the
battle only: a bruise, a reel and splinters are drawn and nothing is written.
Only an approval wins; ten points of bruise and the kraken reels for three
seconds (it cannot attack) and comes back.

**Every blow lands on the kraken's head, the only hit target** (captain,
2026-09-24). The tentacles carry the cards (a task id that opens its card), so
they are never hit, and no effect covers or hides one: every effect is drawn in
one layer masked by the arms' outlines, and the tags sit above it. An arm is
only ever *picked*: the chain-shot binds two, and the arrow keys choose which.

**The battle is fierce.** Every blow ends in an explosion scaled to its weight:
a flash held through a hit-stop, a fireball in sailcloth, brass and ensign, a
shockwave ring (two from weight 3), iron debris on falling arcs, rising embers,
spreading smoke, and a screen shake. Each skill layers its own on top (motion
spec, "The explosion").

| Skill | Pointer and touch | Keyboard | Weight and effect | Cooldown |
|---|---|---|---|---|
| Broadside | click (tap) the head to aim, click again as the closing ring meets the brass ring: within 5 px is a perfect 3, within 14 a good 2, else a glancing 1 | `1` or Enter, twice | three guns fire in turn, three explosions spread over the head; a perfect broadside ends in a fourth, heavier burst | 8 s |
| Chain-shot | arm it, then drag a line across two arms (it binds as the second is crossed), or tap two arms in turn | `2` binds the selected arm and the next; arrows choose | two balls on a spinning chain hit the head (weight 2); the two arms freeze and their tags wear a shackle; their attacks pause for 6 s | 15 s |
| Harpoon | arm it, then hold on the head to charge and release | hold `3`, release to throw | a harpoon trailing its line, weight 1 to 4; a full throw bursts twice | 12 s |
| Full sail | the button, or the wind-up bar itself (the biggest target on a touch screen) | space (or `4`) | the ship turns away; a dodged strike lands in the sea as a column of water beside her. A dodge read off the bar costs nothing; a dodge too early, or with nothing coming, reloads (see *The kraken's attacks*) | 10 s |
| Captain's order | click the captain on deck, or the button | `5` | every gun fires bow to stern (muzzle flash and smoke at each port), a volley hits the head, and the crew's guns fire twice as often for 5 s | 30 s |
| Repair | click a splintered rail section (arm it first if you like) | `6` repairs the first splintered section | a brass glow, sawdust and hammer sparks | 6 s |

Touch works like the pointer: the head, the arms and their tags, the skill bar,
the wind-up bar and a splintered section take no page pan, and an armed
chain-shot or harpoon stops the scene panning, so a drag or a hold is never
taken for a scroll. A drag or a hold keeps its pointer (pointer capture) when the
finger slides off the head or an arm. If the browser still takes the gesture (a
`pointercancel`), or the capture is lost, the drag, the charge and a half-picked
chain are dropped and nothing is thrown; the skill stays armed, and no ring or
line is left on screen.

Escape stops playing. The skill bar is six brass fittings on a strip of
sailcloth, each with an engraved glyph, its key, its name, and an ink sweep with
the seconds left while it reloads; each fitting's accessible name ("Harpoon, key
3, cooldown 12 seconds") is written in en and zh-TW. While the captain plays,
the battle's keys (1 to 6, space, arrows, Enter, Escape) come before the
prototype's switch keys.

#### The kraken's attacks (captain, 2026-09-24)

Every attack is telegraphed before it lands, and the fight rewards reading, not
mashing. Each shows:

- **the wind-up**: the head rears back and the attacking arm draws up as it
  winds; the target deck section glows hotter in ensign under a dashed ring; a
  short warning cue (sound effects on);
- **the wind-up bar**, in the sky at the upper left, clear of every arm and tag:
  what is coming and where ("Slam at deck section 2"), a tar track filling in
  ensign to the strike, and a narrow **perfect zone** in brass at its end. The
  bar is also the dodge's button.

| Pattern | Its telegraph | Bar | Perfect zone | Weight when it lands |
|---|---|---|---|---|
| Slam | the head rears fully; a low horn | 1.6 s | the last 14% | 3 |
| Jab | a short rear; two quick ticks; a thinner bar | 0.85 s | the last 16% | 2 |
| Two-hit combo | a rising pair of notes for each hit; the bar says 1/2, then 2/2 | 1.15 s, then 0.7 s after a 0.26 s beat | 15%, 17% | 2.5 each |
| Feint | looks like a slam and runs at a slam's speed, but its fill is dashed and the head trembles; the bar **stops at 55% and holds for 0.7 s** ("A feint: hold, and wait for the real strike"), then runs out in 0.38 s | 1.96 s in all | the last 14% | 3, and 4 if the captain dodged into the hold |

**The mix follows the real review rounds** of the tasks in the battle (the fake
kraken's are set in the playground), walked in a fixed order, never at random:
round 3 is slams and jabs (slam, jab, slam, slam, jab, 5.2 s apart); round 4
mixes in the combo (slam, jab, combo, slam, combo, jab, 4.4 s apart); round 5 and
on, the feint too (slam, feint, combo, jab, feint, combo, slam, jab, 3.6 s
apart).

**Reading the dodge** (full sail: space, `4`, the button, or the bar):

| When | Result |
|---|---|
| before half the bar, or into a feint's hold | **too early**: the kraken follows the ship, the sail reloads (10 s), the strike lands; into a feint it lands harder |
| from half the bar to the zone | **a dodge**: the strike goes into the sea; no reload; the head is open for 1.5 s: **counter** by tapping or clicking the head, or Enter, for a blow of weight 3.2 |
| in the perfect zone | **a perfect dodge**: a half-second slow beat (the world at 0.3 speed, the scene's edges darkening), a bell-like chime, the **weak point** shows on the head (a brass mark with a pulsing ring) for 2 s, and the counter is a **critical hit** on it: the largest explosion there is (weight 4.5) |
| perfect after perfect | **the combo**: each perfect dodge in a row adds one; the critical hit grows by half a weight for each (to 6) and its bruise by half again; "Combo ×n" |
| nothing coming | the ship turns; the sail reloads |

A landed strike, a too-early dodge or a plain dodge ends the combo. An attack
never touches real work: a landed one splinters the rail (repair it), and only
an approval wins.

### Issues and tags

- **Every open issue of each target repository** is synced into the *Issues*
  lane, left of backlog, with its project tag, author and age. An issue is not
  a task: its menu has *Survey* and *Skip*, and nothing else.
- **Survey** raises a spec card (`D-1100` and on): the drafted spec, where the
  task will land (ready, or backlog behind its dependencies), its tags, and
  what its pull request body will say. With the project's registry entry at
  `issues.auto_close: true` (the default) that is "Closes #n", so merging closes
  the issue; with `false` it is "Refs #n" and the issue stays open. Approve it
  and the task enters the plan carrying its `#n issue` tag; send it back and
  the issue returns to the lane; skip it from the card and it is skipped.
- **Skip** hides the issue from the lane (a "2 skipped, show them" line brings
  them back) without touching GitHub.
- **Tags on every card, in a fixed order**: project (outlined), origin (*chat*
  in ink, *issue* in sea-glass, *skill update* in brass), `#n issue`, `#n PR`.
  The two numbers link to that project's repository: T-078's go to tidewater.
- **Raise as an issue** on a chat task's menu has the firstmate draft the issue
  from the spec and raise an issue card. Only its approval creates the issue
  (the next number on that repository) and adds the `#n issue` tag. Nothing is
  created on GitHub without that card.

### Decision cards as strategy-game cards (captain, 2026-09-24)

The captain's decision cards look and move like cards in a strategy card game,
and keep every piece of information they carried: the title, the explanation,
the pros and cons, the outcome, the authored diagram and the option's before →
after, the pull request and the tags, and on a merge card the seven gates. The
face is the same flat chart sheet at the 13 px and 16 px floors; the game is in
the frame and the motion, and no effect is drawn over a word.

- **A framed face by kind**: an 8 px frame in the kind's metal and a band with
  its emblem. *Merge* is brass with an anchor; *scope* (a spec card for a
  surveyed issue, an issue card for a chat task) is sea-glass with a pair of
  dividers; *choice* is ink with a compass rose; *readiness* is ensign with a
  pennant.
- **Urgency** is how much other work waits on the card's task, counted from the
  plan: three pips, one lit for "blocks no other task", two for one or two,
  three (and an ensign line outside the frame) for three or more. The count is
  written beside the pips.
- **Dealt onto the table** when a card arrives while the page is open (a
  survey, an issue to raise, a task become ready): it slides in from the pile at
  the upper right, edge-on, and turns face up. The cards on the table when the
  page opens were already there and are not dealt.
- **Tilts toward the pointer** (at most 2.5° either way, so the words stay square
  to the eye) with a **foil glare** of brass and sea-glass that runs round the
  frame only. Typing in the card, a touch screen or reduced motion holds it flat.
- **The hand**: each option (A to D, or merge / send back / hold, and your own
  answer) is its own card, fanned a little under the face, each reading its
  description, advantages and costs in full. Hovering or focusing one lifts it.
- **Playing a card**: picking an option plays it onto the table above the hand
  (the card flies from the hand to the table), and the option's diagram flips to
  that option's before → after.
- **Sealing**: *Confirm* writes the answer first, as before; then a wax seal in
  the kind's metal, with its emblem, is pressed onto the frame's corner, a ring
  goes out, the card jolts, and it is taken off the table while the deck closes
  up.
- The cards below the top one are strips in the same frame, with the emblem,
  still reading their id and title.
- **The readiness card** (new): raised when a task's last dependency merges.
  *Proceed* is the same answer as *Set course* on its island (it joins the
  course in the order answered, logged as proceed); *Park* parks it; *Not yet*
  leaves it ready.

Every effect is under a second, follows a real action (a card raised, a pick, a
confirmed answer), has a still replacement, and its sound is off until the
captain turns sound on (motion spec, sound spec).

### Playground

The *Playground* switch in the controls snapshots the board and this layer and
shows an ink banner, a hatched brass-and-tar frame round the page, and a panel
of triggers in the controls: the hour, the weather, the rate, each handoff,
each ritual (port, salute, greeting, clearing, a merge salvo), each rank for
worker-1 and reviewer-1, a fake kraken of one to eight arms and its battle (the
cannon game, a strike, a hit, the storm, victory with the fanfare, which plays
every time: a fake victory is not an approval), the fake kraken's review rounds
(3, 4, or 5 and on, which set its mix of attacks), each attack pattern on
demand (a slam, a jab, a two-hit combo, a feint), and your dodge shown for you
(too early into a feint; a dodge and a counter; a perfect dodge and a critical
hit; three perfect in a row for the combo). Everything the live page does also
works there. Nothing is written: the last-visit date is not stored, and turning
the playground off restores the board, its log, the crew, the records, the
customs, the sound, the ambient sea, the cards on the table and the registry's
`issues.auto_close` exactly as they were, at once.

What makes that true, for the implementation:

- **The snapshot is every mutable, whole.** The board's `BOARD` (the log is in
  it, so a line written in the playground goes with it), the parts of `S` and
  `UI` that are state, `ROT`; this layer's `E` (which carries `auto_close` per
  project, the kraken's flight, the ambient switch and the fake kraken's rounds),
  the event switches' target, the open service records, the cards already dealt,
  the explosions' seed count and the greeting on screen. What is rebuilt from
  those (`CREW`, the chart's layout, the kraken's drawing, the combat card, the
  game, whose attack order starts again from the first) is closed and redrawn on
  the way out. Kept on purpose: the captain's view (language, motion, the roster
  toggle, the controls drawer). The config and the registry are frozen, so a
  write to them throws instead of leaking.
- **One clock for deferred work.** From the moment the layer loads, every
  timeout and engine tween the page starts is tracked. A cut (the playground on,
  the playground off, the board's reset) cancels all of them and every scripted
  animation, clears the effect layers, the light, the shake, a slow beat, a
  merge's clearing and the salvo, and moves on a generation, so nothing scheduled
  under one mode or fixture lands in the next. No deferred callback writes state
  anywhere: a milestone's log line is written with the merge, and only the port
  ritual waits for the salvo. The ambient sea's own stop timer runs on the native
  timer, so a cut never leaves it playing.
- **Checked as one string.** `Emo.fingerprint()` serialises everything above
  plus the rendered log; it is equal before entering and after leaving. Round 4
  checked it after flipping `auto_close`, turning the ambient sea on, merging
  T-064 (M2's port), a rejected round, a readiness card, the greeting and a
  perfect dodge, leaving 0.7 s later and again 3 s later.

### Switches (T-086)

In the prototype's switches, under "The emotional layer". Each stands in for a
real event arriving and writes the log line the live board would.

| Switch | Key | What it shows |
|---|---|---|
| Events land on | | which task in flight the review, push and check switches act on; by default the task in battle, else the oldest in flight |
| The review approves | `V` | round 1: the salute. A held task in battle: victory. A held task outside a battle: the kraken lets go. Every approval counts for the reviewer's rank (reviewer-1 is one short of chief inspector) |
| The review rejects the round | `J` | the round goes up; the third unapproved round raises the kraken with a new arm; a kraken that fled comes back for a task it still holds; in battle, the kraken strikes the deck |
| The worker pushes | `H` | in battle, a hit |
| The check goes red | `F` | in battle, the storm thickens |
| The red check turns green | `G` | the red gate's task goes on to review; clearing and a cheer |
| An issue is opened on GitHub | `I` | #99 fades into the Issues lane and appears in the fog |
| `issues.auto_close` for firstmate-workflow | | flips the registry setting a spec card reads |
| Greet me as the day's first visit | `E` | the greeting |
| Tomorrow's greeting | | what tomorrow's greeting would say, with today's battles |
| Merges | `M` | merging T-064 from the opening squall completes M2: the ship makes port at Nassau, and worker-1 is rated able seaman |
| A task becomes ready: its readiness card is dealt | | the next ready task without a course or a card gets a readiness card, dealt onto the table |
| Deal the table again | | every card on the table is dealt again, to show the deal (on the live board a card is dealt only when it arrives) |
| The controls | `K` | hides and shows the floating controls |

The kinds of card, and where to see each: merge (D-1012, brass), choice
(D-1011, ink), scope (*Survey* on #91, or *Raise as an issue* on T-074 after
`N`; sea-glass), readiness (the switch above; ensign). D-1012 blocks T-069, so it
shows two pips; the others one.

Walk-throughs from the opening squall (T-060 is held at review round 4 and
T-061 at round 3; each was run on the rendered page this round, from a reset):

- **Port and rank**: `M`.
- **First-pass salute**: `G` (T-078 goes to review at round 1), pick T-078 in
  *Events land on*, `V`.
- **The kraken rises**: after `G`, pick T-078, `J` twice.
- **A battle**: click the T-060 arm, choose *Proceed*, confirm; then `J`
  (strike), `H` (hit), `F` (storm), *Play along*; `V` wins it.
- **Flee**: click the T-061 arm, *Drop*, confirm: the whole kraken goes down,
  though it still holds T-060, and T-060's tag waits by the bow. Click that tag
  (face it), or pick T-060 in *Events land on* and press `J`: it comes back.
  Reset and choose *Rescope* on T-061 instead: the whole kraken shrinks to the
  distance, with T-060's tag beside it.
- **The option's diagram**: pick A, B, C or D on D-1011; pick *Your own
  answer* and type.
- **A card played and sealed**: hover D-1011 (it tilts, the glare runs round
  its frame), pick B from the hand (it flies onto the table, the diagram flips
  to B), *Confirm*: the seal, and the card leaves; D-1012 is next.
- **A card dealt**: *A task becomes ready*: T-062's readiness card is dealt;
  open it, pick *Proceed*, confirm: T-062 carries "course 1st" and a flag on
  its island.
- **Issues**: *Survey* on #91 (lane menu or its fog island), answer A on the
  spec card; *Raise as an issue* on T-074 after `N`.
- **The attacks** (in the playground): *Its attacks*, *A slam*: read the bar,
  and press space in the brass; then *A feint* and wait out its hold. *Your
  dodge, shown* plays each outcome for you: *Too early* (into a feint), *A dodge
  and a counter*, *A perfect dodge and a critical hit*, *Three perfect in a row*
  (the combo reaches ×3). *Its review rounds* 4 and 5 change the mix.

### Config

What the live board would read from `config.yaml` and the project registry.
The prototype carries the same values in `CONFIG` and `REGISTRY` at the head of
section 14.

```yaml
voyage:
  firstmate-workflow:
    home: Portsmouth
    ports: { M0: Port Royal, M1: Tortuga, M2: Nassau, M3: Havana, M4: Cartagena }
  tidewater:
    home: Whitby
    ports: { M1: Scarborough, M2: Bridlington }
ranks:
  worker: { deckhand: 0, able seaman: 3, "bosun's mate": 10, bosun: 25, quartermaster: 50 }
  first_pass_bonus: 0.5
  reviewer: { apprentice inspector: 0, inspector: 10, chief inspector: 40 }
kraken:
  from_round: 3
  max_arms: 8
# per project, in the registry
issues:
  auto_close: true
```

The port names are the captain's; a zh-TW name sits beside each in the
prototype, because dynamic board text carries both languages.

### Design decisions, and why

1. **No new colours.** The kraken is ensign red sunk in Prussian ink
   (`color-mix`), its underside ensign in sailcloth, its eye brass; chart paper
   is the hour's chart sheet; the fog is the page's own grey; the origin tags
   are ink, sea-glass and brass. The playground is marked by an ink banner and
   a hatch of brass and tar, the plan's materials.
2. **The one bold thing is still the ship.** The chart is quiet chart paper
   with 13 px labels; the kraken lives in the scene; the page around it gains
   only a line of greeting, tags, an eighth column and a roster line.
3. **The chart reads the way the ship sails** (ahead to the left) rather than as
   a left-to-right timeline, so the chart and the scene above it agree on
   direction at a glance.
4. **Weather, not blame, changes T-070's look for a red gate.** v2 drew the man
   on a red gate sagging and dimmed; the captain's rule is that a failure is
   weather the crew work through together. It is a custom, on by default; off,
   v2's look returns.
5. **Sound is off by default**, which reverses T-070's default (sound on).
6. **Drop is in the combat card** beside the four actions the task names,
   because the outcomes ("dropping sends it down whole") need it, and it is
   the board's existing action with its own confirmation.
7. **Skills can wear the kraken down but never sink it.** A reel is the most a
   skill can do; the text under the skill bar says only an approval wins.
8. **The readiness card is the island's card, and a card on the deck.**
   design.md has no readiness card yet; the prototype shows it both as the
   island's popover (proceed as *Set course*, park, show its card) and, since
   the strategy-card round, as a readiness card dealt onto the deck (proceed,
   park, not yet). Either proceed is the same answer and joins the same course.
9. **A surveyed issue joins the project's furthest milestone** in the fixture;
   on the live board the firstmate's spec says which.
10. **One fixture task for a second project**, T-078 on tidewater (with its
    #11 issue), so the fleet, the project badge, per-project links and the
    chart's project switch have something to show. In the opening squall it is
    the task at the red gate. **This changes T-070's approved opening scene**:
    T-078 sits ahead of T-062 in the fixture, so worker-2's pennant at the red
    gate reads "T-078 blocked" (on tidewater) where T-070's read "T-062
    blocked", and the narration names T-078.
11. **A fixture milestone M4, "the living ship"**, holds the design tasks
    T-060 to T-072 the fixture already had, and T-064 sits in M2 so that its
    merge card completes a milestone. Milestones M0 to M3 carry design.md's
    names.
12. **zh-CN needs 90 more characters in `i18n/tw2cn.tsv`** for this layer's
    words; they are in `TW2CN_T086` in the script. Every dynamic string in
    section 14 is written in en and zh-TW and reaches zh-CN only through
    `cn()` (`t()`, `loc()`, `L2()`); no branch zh-TW takes calls `cn()`.
13. **Eight lanes at 1280 px** are 154 px each; titles wrap one line more often
    than with seven. The 13 px and 16 px floors hold.
14. **The kraken flees whole on a drop or a rescope, even while it holds other
    work**, as the acceptance says, and it comes back only on a real event (a
    rejected round, a newly held task, or the captain facing it). Coming back
    on its own, or on a timer, would be a beat with no event behind it; staying
    near would narrow "flee" to the case where nothing else is held.
15. **The head is the battle's only target** (captain, 2026-09-24), which
    changes the acceptance's "click a tentacle" (broadside) and "one tentacle"
    (harpoon): both now aim at the head. The tentacles are the cards, so a
    mask, not a convention, keeps every effect off them.
16. **The controls float** (captain, 2026-09-24): the playground switch and
    both sounds leave the header and the customs for a drawer at the lower
    right, with the prototype's switches and the playground's triggers below
    them. The live board would carry only the "On the board" group.
17. **The option's diagram is HTML, not SVG**, in the authored diagram's boxes
    and ink: its words are the option's own, of any length, and HTML wraps
    them at the 16 px floor where SVG text would need measuring.
18. **A read dodge costs nothing; a guessed one reloads.** The acceptance gives
    full sail a 10 s cooldown, and the captain's attacks come every 3.6 to
    5.2 s, some in pairs. So the 10 s is the price of a dodge that did not read
    the bar (too early, into a feint's hold, or with nothing coming), and a
    dodge in the window or the perfect zone refunds it. Mashing space is then
    the one way to lose the sail.
19. **The feint has a tell.** It runs at a slam's speed and sounds like one, but
    its fill is dashed and the head trembles as it winds; the bar stopping short
    is the loud tell. A feint with no tell would reward guessing, not reading.
20. **Deterministic, not random.** Each round's mix is a fixed list walked in
    turn, and each attack comes from the next unbound arm in turn; the same
    battle plays the same way. The playground can force a pattern.
21. **The wind-up bar is in the sky, not on the skill bar.** On the skill bar it
    grew the strip over the middle arm's tag; at the upper left it covers only
    sky and a sail, never an arm or a tag, and it is the dodge's biggest touch
    target.
22. **Every effect that could darken a tentacle is in the masked layer.** The
    critical hit's scene flash and the slow beat's darkened edges are drawn in
    the effect layer, under the arms' mask, so they pass round every arm, and
    the tags stay above them.
23. **Urgency is the work a card blocks**, counted from the plan (the tasks
    whose dependencies include the card's task), not how long it has waited:
    waiting time would make the frame change on a timer.
24. **A sealed card leaves in place.** The answer is written and the deck
    re-rendered at once; the sealed card is a copy laid back where it was, so
    it never slides over the next card's words, and the deck closes up only when
    it has gone (0.94 s).
25. **Spec cards and issue cards share the scope frame**: both decide what work
    enters the plan and how it is tracked. The four kinds in the acceptance
    (merge, scope, choice, readiness) are the four frames.

### Limits (T-086)

- Round 4 rendered the prototype in headless Chrome at 1280 × 900 and drove
  it from the console, in en, zh-TW and with motion off: no console errors;
  every walk-through above, from a reset; the playground's fingerprint before
  entering and after leaving (above); a merge followed by a reset 0.3 s later
  (no port ritual after it; without the reset, 54 firework sparks at 1.2 s);
  every attack pattern and every shown dodge (a combo of three perfect dodges
  reaches ×3); touch as synthetic `pointerType: touch` events (a harpoon hold
  then `pointercancel`, a hold then a lost capture, a hold and release that
  throws, a chain-shot drag across two tags that binds them); `touch-action:
  none` computed on the skill bar, the wind-up bar, the tags and the arms; the
  ranks and braids at first paint; a card picked, played, confirmed and sealed;
  a readiness card dealt and answered. Not done: a real touchscreen, a real
  speaker check of the sounds, and the CPU measurement.
- The playground panel's trigger labels and the prototype's switches are
  English in every locale, as T-070's switches are; everything the live board
  localises is localised.
- The kraken's CPU cost and the ambient sea's level were not measured (motion
  spec, CPU, T-086; sound spec).

## Fonts

The page loads four files from `fonts/`, each tried after the locally
installed face of the same name:

| File | Face | Source (OFL 1.1) |
|---|---|---|
| `fonts/im-fell-english-sc-400.woff2` | IM Fell English SC | https://cdn.jsdelivr.net/fontsource/fonts/im-fell-english-sc@latest/latin-400-normal.woff2 |
| `fonts/barlow-semi-condensed-400.woff2` | Barlow Semi Condensed Regular | https://cdn.jsdelivr.net/fontsource/fonts/barlow-semi-condensed@latest/latin-400-normal.woff2 |
| `fonts/barlow-semi-condensed-500.woff2` | Barlow Semi Condensed Medium | https://cdn.jsdelivr.net/fontsource/fonts/barlow-semi-condensed@latest/latin-500-normal.woff2 |
| `fonts/barlow-semi-condensed-600.woff2` | Barlow Semi Condensed SemiBold | https://cdn.jsdelivr.net/fontsource/fonts/barlow-semi-condensed@latest/latin-600-normal.woff2 |

**The four files are vendored**, from the fontsource URLs above, in commit
2968aca under the captain's one-time authorisation, with each family's OFL 1.1
licence text beside them: `fonts/OFL-im-fell-english-sc.txt` and
`fonts/OFL-barlow-semi-condensed.txt`. The page needs no network for its type.
If a file were missing the page would fall back to the system's condensed sans
(Avenir Next Condensed on macOS) and an old-style serif (Iowan Old Style or
Palatino).

## Limits of this prototype

- Fixture data only: the tasks, pull request numbers, activities, calls and
  log lines are invented. Titles are borrowed from design/tasks.json where the
  task exists. The `#n` links follow the live board's format, so they point at
  whatever that number is on GitHub.
- "Open locally" and "design.md" in a call only say in the caption what the
  live board would open; the prototype has no server to hand the file to an
  editor.
- The ship's caption and the prototype switches stay English in every locale;
  everything the live board localises is localised.
- Tab CPU in percent was not measured by the worker; see the motion spec for
  what was measured and how firstmate measures the rest.
