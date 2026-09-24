# Prototype v2: the living ship (T-070)

A design prototype of the whole captain's board, for the captain to approve
before T-060 to T-064 and the motion task build it: the ship on a living sea,
and around it every region the live board has today, in the ship's visual
language. It is design only: fixture data, no backend, and nothing changes
unless the captain acts on the page or presses a switch. The production board
is rewritten from it, not promoted from it.

| File | What it is |
|---|---|
| `prototype.html` | the prototype; open it from disk, no network |
| `motion-spec.md` | every moving thing: period, amplitude, curve, trigger, meaning, reduced-motion replacement; the weather table; the CPU budget and how to measure it |
| `fonts/` | the two OFL faces as four woff2 files, and each family's OFL licence text (see [Fonts](#fonts)) |

## The page

Top to bottom, in design.md section 8's order. Everything below works on fake
data, and every interaction the live board has works here too.

| Region | What it holds | What works |
|---|---|---|
| Header | live mark, brand and project, the engine badge (`claude ⇄ codex`), green-lit state, the hour, the language switch | EN, 繁 and 简 switch every label, event summary, decision and diagram on the board |
| Tally | merged, in flight, waiting on you, blocked, ready, backlog | each figure rolls to its new value when it changes |
| Decision deck | the captain's portrait in a brass porthole beside the first call in full; further calls as one-line strips that open in place | pick an option, write your own answer (1 to 1000 characters, checked), confirm; the choice card has A, B, C, D and your own answer, the merge card A, B, C, your own answer and the seven gates; each has its authored diagram in a frame |
| The ship | the approved scene, unchanged in look | reads the board: the lanes and the crew are the same state |
| Caption and roster | what just happened, in words; the crew roster, toggled from the caption bar | rows carry a state mark, name, stage, pull request, the vendor and model the run uses (workers and reviewers), task, and the run's authored activity; a bar only where the run reports a real denominator (the reviewer's files) |
| The fleet | seven ruled columns on one chart sheet: backlog, ready, working, gate, review, captain, merged; the parked group (collapsed) and the drop target below; the completed history (collapsed) | park and drop by the `⋯` menu or by dragging; unpark by the menu or by dragging onto ready or backlog, landing where the dependencies say; drop asks in the page first; Escape closes a menu or the confirmation; `#n` links open the pull request |
| Live log | the ship's log, newest first, with a state mark per event kind | every captain action and board moment writes a line |

Answering a call acts on the whole page: a choice or a sent-back merge is an
order (bell and whistle, the helm spins, all hands answer) and the card leaves
the captain column; merging plays the salvo; holding a merge parks it. Nothing
is dispatched: a task set free goes to ready and waits there.

## Switches

Every state the captain has to judge is one switch away. Keys work anywhere on
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
| Sound | `S` | the synthesised bell, whistle and cannon; no audio files |
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
