# Motion spec: prototype v2 of the living ship

Every moving thing in `prototype.html`, what makes it move, and what it means.
The rule behind the whole table: **only the sea's idle swell moves for its own
sake.** Everything else moves because the state changed, or because a run is
live right now. When the state is quiet, the ship is quiet.

Numbers are the prototype's values. T-060 to T-064 and the motion task build
against them; where one of those tasks has a reason to change a number, it
changes it here first.

## The engine

One `requestAnimationFrame` loop drives the sea and the ship, with springs and
tweens (section 1 of the script: `Ease`, `Spring`, `Engine`). CSS keyframes drive the crew's
action loops and the one-shot reactions, because those are transforms on small
elements and the compositor runs them without script.

| Part | Behaviour |
|---|---|
| Easing | named curves `linear`, `inOutSine`, `outCubic`, `inOutCubic`, and `cubicBezier(x1,y1,x2,y2)` solved by Newton's method (8 iterations) |
| Spring | `a = -k(x - target) - c·v`, fixed 1/120 s substeps so it is stable at any frame rate |
| Weather spring | k 12, c 6.9 (critically damped): a change of weather settles in about 1.3 s with no overshoot |
| Heel spring | k 30, c 3.2 (underdamped): period about 1.15 s, decays within 3 s |
| Tween | duration, easing, per-frame callback, completion callback |
| Frame cap | 20 frames a second on a calm sea, 30 under way, the display's own rate while a tween runs or a spring is still moving |
| Stops | the loop does not run when motion is off, the tab is hidden, or the scene is scrolled off screen; CSS animations pause with it (`.paused`) |
| Flush | switching motion off mid-moment lands every tween at its end state at once, so nothing is left mid-air |

## The sea and the ship

The swell phase advances by `dt · 2π / period`. The ship is centred and never
leaves its anchor point: it only heaves and pitches about the waterline
under its middle.

| Thing | Period | Amplitude | Curve | Trigger | Encodes | Reduced motion |
|---|---|---|---|---|---|---|
| Ship heave | weather's swell period | weather's swell amplitude | `sin φ + 0.35·sin(1.63φ + 1.1)` | idle | the sea is alive (the one motion allowed for its own sake) | ship held level at rest |
| Ship pitch | same | weather's pitch | `cos(φ + 0.6)` degrees | idle | how rough the weather is | level |
| Heel | about 1.15 s, rocks out within 3 s | about 2.4° at peak | heel spring, kicked −20°/s | a merge | the broadside's recoil | none |
| Near swell, crests | same | 0.45 × swell amplitude | `sin(φ + 1.8)` | idle | the water the ship sits in | frozen |
| Foam band | same | 0.59 × swell amplitude | same | idle | same | frozen |
| Mid swell | same | 0.23 × swell amplitude | same | idle | same | frozen |

The vessel element is re-set only once it has moved a quarter of a pixel at the
hull's end. On a calm sea that is about ten updates a second; the crew faces
riding on it are recomposited that often instead of at every frame.

### Parallax: forward travel

Each band slides at `share × speed + drift` pixels a second, where `speed` is
the weather's speed factor and `drift` is the swell's own run toward the bow.
Travel is linear (constant velocity); only the speed factor eases, through the
weather spring.

Every band is a tile that repeats, so its period is the tile width divided by
its velocity; it has no amplitude of its own beyond that velocity.

| Band | Period | Amplitude (velocity) | Curve | Trigger | Encodes | Reduced motion | Depth of field |
|---|---|---|---|---|---|---|---|
| Clouds | continuous | `8 × speed` px/s | linear | weather: any speed above 0 | forward travel, farthest plane | stops where it is | 0.6 px blur |
| Squall band | continuous | `12 × speed` px/s | linear | same; visible only with the cloud band (squall) | forward travel under the squall | stops where it is | none |
| Far islands | continuous | `4 × speed` px/s | linear | same | forward travel against the horizon | stops where it is | 1.1 px blur |
| Far wavelets | continuous | `22 × speed` px/s | linear | same | forward travel on far water | stops where it is | none |
| Mid swell | continuous | `44 × speed − 5` px/s | linear | idle (the drift) and weather (the speed) | the swell's own run, plus way on the ship | stops where it is | none |
| Near swell and crests | continuous | `80 × speed − 9` px/s | linear | same | same, nearest water under the hull | stops where it is | 0.5 px blur |
| Foam band | continuous | `110 × speed − 12` px/s | linear | same | same, the nearest plane | stops where it is | 2.2 px blur |

On a calm sea the speed is 0, so only the drift remains: the swell runs slowly
toward the bow and the ship stays where she is. That is the difference between
riding at a mark and making way.

### Spray, wake and sails

| Thing | Period / life | Amplitude | Curve | Trigger | Encodes | Reduced motion |
|---|---|---|---|---|---|---|
| Bow spray | droplets live 0.7 to 1.2 s | 1.2 to 3.4 px droplets, launched 50 to 140 px/s forward and 70 to 180 px/s up, gravity 420 px/s² | ballistic | weather: none when calm, `3 + 3n` a second in a breeze of n runs, 24 a second in a squall (plus 150% while the bow is dipping) | way on the ship, and how hard she is working | a standing bow wave, sized by speed |
| Wake | one foam patch every 0.22 s, each lives 3.2 s | grows from 10 to 56 px wide, fades from 0.55 to 0 | linear | any speed above 0.05 | the ship has made way | a standing wake `40 + 300 × speed` px long |
| Sail belly | weather spring | 0.12 calm, `0.45 + 0.15n` in a breeze, 1 in a squall | redrawn when it moves by more than 0.03 | weather change | the wind | drawn at the target belly |
| Jolly Roger | calm: none; breeze `1.9 − 0.25n` s; squall 0.9 s | skew `7–8° × flagA`, flagA 0 / `0.35 + 0.15n` / 1 | ease-in-out | weather change | the wind | held still; in a calm it hangs at 64° |
| Jolly Roger drops to hang | 0.8 s, once | from flying to hanging at 64°, 86% of its length | ease | the weather becomes calm (the last live run ends) | the wind has died | hangs at once |

The pools are bounded: 36 droplets and 18 wake patches at most.

## The weather

Weather is read from the board's state, never set on its own. The switch picks
the scenario; the scenario becomes crew states on the board's own tasks and, in
a squall, two pending calls; the sea shows what that state supports. A breeze
with nobody aboard who can run work shows a calm. A squall lasts while a gate is
red or a call is pending, so answering both calls leaves the squall standing
until the red gate goes.

In the clearing column, n is the live runs left after the merge, at least 1:
for its 6 s a clearing is a breeze of those runs with the cloud band gone and
light whitecaps, even when a red gate or a call would otherwise hold a squall.
Every value in the table is a spring target, so a clearing out of a squall
eases down to these values over about 1.3 s, and back to the state's weather
when it ends.

| Parameter | Calm (no run in flight) | Breeze (n live runs, 1 to 3) | Squall (a red gate or a card waiting on the captain) | Clearing (a merge) |
|---|---|---|---|---|
| Speed factor | 0 | `0.45 + 0.22n` | 1.3 | `0.45 + 0.22n` |
| Swell amplitude | 3 px | 5 px | 10 px | 5 px |
| Swell period | 7.5 s | 6.2 s | 4.6 s | 6.2 s |
| Pitch | 0.5° | 1.1° | 2.4° | 1.1° |
| Cloud band (`--dark`) | 0 | 0 | 0.9 | 0 |
| Whitecaps (`--foam`) | 0.2 | 0.45 | 0.95 | 0.35 |
| Sail belly | 0.12 | `0.45 + 0.15n` | 1 | `0.45 + 0.15n` |
| Flag | hangs (flagA 0) | flutters, `1.9 − 0.25n` s, flagA `0.35 + 0.15n` | flutters, 0.9 s, flagA 1 | flutters, `1.9 − 0.25n` s, flagA `0.35 + 0.15n` |
| Spray | none | `3 + 3n` a second | 24 a second, plus 150% while the bow dips | `3 + 3n` a second |
| Light | the hour's key light | the same | the sky darkened under a cloud band | light breaks: rays rise to 0.55 over 0.9 s, hold, fade from 3.6 s to 0 at 6 s (`inOutSine`) |
| Reduced motion | every value drawn at its target at once | same | same | rays held at 0.35 for 2.3 s, then the state's weather at once |

A live run is a worker or a reviewer on a task. The firstmate coordinates them
and is not counted.

| Thing | Period | Amplitude | Curve | Trigger | Encodes | Reduced motion |
|---|---|---|---|---|---|---|
| A change of weather | settles in about 1.3 s, no overshoot | from the old column's values to the new one's | weather spring (k 12, c 6.9, critically damped) | the state's weather changes: a run starts or ends, a gate goes red or green, a call arrives or is answered, a merge starts or ends a clearing | the crew's state, read as weather | the new column is drawn at once |

## The hour

| Thing | Period | Amplitude | Curve | Trigger | Encodes | Reduced motion |
|---|---|---|---|---|---|---|
| Sky, sea, islands, clouds, ambient on crew, page chrome | 1.2 s cross-fade of registered colour properties, once | from one hour's keyed palette to the next's | ease | a change of hour (checked every 30 s in local mode) or the switch | the captain's local time | instant |
| Timber and canvas brightness | 1.2 s, once | brightness and saturation to the hour's: dawn 0.94 / 0.92, day 1 / 1, dusk 0.8 / 0.95, night 0.56 / 0.72 | ease | same | the key light falls on the ship too | instant |
| Stars, stern windows, lantern glow | 1.2 s, once | opacity 0 to 1 (stars at night only; windows and lantern at dusk and night) | ease | the hour becomes or stops being dusk or night | lamps are lit after dark | instant |

The key light sits where the sun or moon is: low right at dawn, high right by
day, low left at dusk, the moon upper left at night. Figures take it on their
side faces and a rim on the lit edge; contact shadows fall away from it.

## The crew

Action loops run **only on a live run** (`.live`). An idle crewman holds his
idle pose and prop; a blocked one sags and holds still. The ship's swell is the
only thing that moves them.

Every loop repeats for as long as its trigger holds and stops, back to the key
pose, when it ends. The crew action switch is a look at the poses only: it puts
every crewman who is not blocked on one action and runs its loop, without
changing the board.

| Loop | Period | Amplitude | Curve | Trigger | Encodes | Reduced motion |
|---|---|---|---|---|---|---|
| Helm (firstmate) | 2.4 s | arms −52° to −64°; wheel −14° to +16° | ease-in-out | at least one live run aboard and no call waiting on the captain | the firstmate is coordinating live runs | arms held at −58°, wheel still |
| Lookout (reviewer) | 4.2 s | turns −17° to +19° | ease-in-out | the reviewer's run is live on a pull request | a review in progress | faces forward, spyglass arm at −106° |
| Signal | 0.8 s | arm −132° to −158° | ease-in-out | a top-deck crewman's run is live on this action | work on the top deck | flag arm held at −140° |
| Point | 3 s | 3 px bob | ease-in-out | same | same | chart arm at −92°, no bob |
| Log | 0.9 s | arm −70° to −58° | ease-in-out | same | same | quill arm at −70° |
| Haul | 1.25 s | arms −70° to −40°, body 3 px | ease-in-out | an amidships crewman's run is live on this action | work amidships | arms held at −64° on the line |
| Capstan | 1.1 s | arm −20° to −96° and back | linear | same | same | arm held at −58° on the bar |
| Carry | 1.6 s | 4 px trudge | ease-in-out | same | same | arms at −78° under the crate, standing |
| Climb | 1.4 s | arms alternate −124° and −70° | ease-in-out | same | same | left arm at −124°, right at −70°, still |
| Hammer | 0.62 s | arm −14° to −86° | ease-in-out | a main-deck crewman's run is live on this action | work on the main deck | hammer arm at −40° |
| Saw | 0.7 s | arm −30° to −62° | ease-in-out | same | same | saw arm at −44° |
| Swab | 1.5 s | arm −34° to −72° | ease-in-out | same | same | swab arm at −50° |
| Weight shift (legs and shoes together) | 1.05 to 1.54 s, fixed per crewman by a hash of his id | 5 px lift, 2° to −12° | ease-in-out | the crewman's run is live | the man is working, not posed | both feet planted |

Reduced motion, for every loop: the loop is removed and the figure holds the
key pose its action draws statically (the angles above are that pose).

One more thing moves on a figure, and it is the captain's hand, not state:

| Thing | Duration | Amplitude | Curve | Trigger | Encodes | Reduced motion |
|---|---|---|---|---|---|---|
| A figure turns back | 0.16 s | from the turn the captain dragged it to, back to its default (8° tilt, −26° turn; the captain 6°, 24°) | ease-out | a double-click on the figure, or on the deck for all hands | direct manipulation: the view returns to where it was; nothing on the board changed | turns back at once |

While a figure is being dragged it follows the pointer with no easing.

## Moments

Each moment is triggered by one state change and cleans up after itself.

| Moment | Period | Amplitude | Curve | Trigger | Encodes | Reduced motion |
|---|---|---|---|---|---|---|
| Captain's pose | arms move in 0.32 s, once | right arm −14° (idle), −62° (ready), −142° (order); left arm −30° to −34° | `cubic-bezier(.2,.9,.3,1.3)` | a choice is picked on the deck (ready), the pick is cleared (idle), the order moment (order, then back to the previous pose at 1.8 s) | whether the captain has a call in hand or is giving an order | the pose changes without travel |
| Cutlass drawn or sheathed | 0.2 s, once, with the arm above | blade opacity 0 to 1 in his hand as the hilt at his hip goes 1 to 0, and back | ease | the pose goes to or from idle | whether the captain has a call in hand | the blade is there or not, at once |
| Crew salute | the right arm rises in 0.18 s, holds, and drops when the salute ends at 0.65 s | right arm to −150° | ease-out | an order (see Order below); crewman i starts at `250 + i × 45 ms` | all hands acknowledge the order | arm up in place for 0.65 s, no travel |
| Handoff: order | 1.4 s travel, once | arc 110 px high, one full turn | `cubic-bezier(.3,0,.2,1)` | the firstmate dispatches to a worker (`Q`); the captain's order passes to the firstmate (the order moment) | an order passing between figures | the arc is drawn whole with "Order from …" beside the recipient for 2.3 s |
| Handoff: pull request | 1.4 s, once | arc 70 px, 40° tumble | `inOutSine` | a worker's pull request opens (`U`, or `P`) | a pull request going to the reviewer | same, "Pull request from …" |
| Handoff: approval | 1.4 s, once | arc 50 px, no spin | `cubic-bezier(.2,.7,.2,1)` | the reviewer approves (`Y`) | an approval going to the firstmate | same, "Approval from …" |
| Handoff: rejection | 1.4 s, once | arc 36 px, a 6 px wobble in three lobes that dies out | `cubic-bezier(.6,0,.4,1)` | the reviewer rejects (`X`) | work sent back to the worker | same, "Rejection from …" |
| Handoff trail | draws on with the flyer, fades from 80% of travel, removed 0.9 s after arrival | the flyer's arc, stroke drawn 0 to full, opacity 0.75 to 0 | same as the flyer | any handoff | the path the handoff took | drawn whole, dashed |
| Arrival | recipient jolts 0.55 s; pennant swells over 0.8 s | jolt from 10 px up at 108% to rest; pennant 100% to 110% and back | `cubic-bezier(.2,.8,.3,1)` | a handoff lands | who received it | no jolt; the words carry it |
| Salvo flash | 0.34 s per gun, gun i fires at `i × 75 ms` | scale 0.25 to 1.35 to 2, 18 px back from the port, opacity 0 to 1 to 0 | ease-out | a merge, one gun per port | the broadside for the merge | none |
| Salvo smoke | 1.7 s per gun, same clock | grows from 0.3× to 3.4×, drifts 12 px forward and 14 px up, opacity to 0.95 and out | `cubic-bezier(.15,.6,.3,1)` | a merge | same | smoke held at 60% and 1.4× for 2.3 s |
| Cannon reports | one per gun, same 75 ms clock, 0.34 s each | lowpassed noise, gain 0.6 falling 0.03 a gun | not motion | a merge | same | unchanged: sound is not motion |
| Cheer | arms up 1.7 s, two 0.8 s hops, crewman i starts at `i × 45 ms` | arms to −150°; hops 12 px then 5 px | ease-out | a merge | all hands see the merge | arms up, no hop |
| Bell | swings 1.8 s, once | 22°, −16°, 10°, −5°, 2°, rest | `cubic-bezier(.3,.6,.4,1)` | rung at `guns × 75 ms + 300 ms` after a merge, and at once on an order | the bell was rung | the bell does not swing; it still sounds |
| Order | bell at 0, bosun's whistle at 180 ms (1.1 s), helm spins in 1.2 s, crew salute 0.65 s from 250 ms staggered 45 ms, order handoff captain to firstmate at 300 ms, captain returns to his previous pose at 1.8 s | helm two full turns (720°); the rest as in their own rows | helm `cubic-bezier(.45,0,.25,1)`; the rest as in their own rows | the captain confirms a choice or sends a merge back (`O` shows it) | the captain gave an order (D-1010) | no spin, no stagger; salute and pose change in place |
| Banner | 3 s, once: unfurls over the first 0.48 s, holds, fades from 2.55 s | unrolls left to right to its swallowtail, opacity 1 to 0 at the end | `cubic-bezier(.2,.8,.3,1)` | a merge ("Ahoy! Merged into main") or an order ("Aye, captain. Orders away") | what just happened, in words; it sits in the sky clear of the ship | shown still for 3 s |

The salvo, cheer, smoke and banner all finish inside the board's 3.2 s effect
deadline. The clearing light is the weather that follows the merge, not part
of the effect, and runs its own 6 s.

## The page around the ship

The rest of the board is still until its state changes (the captain's Q4). Four
things move on it, each once, each for one change. They use the Web Animations
API on transform and opacity only, so the compositor runs them and the page
adds nothing to the ship's frame loop.

| Moving thing | Duration | Amplitude | Curve | Trigger | Encodes | Reduced motion |
|---|---|---|---|---|---|---|
| A card changes lane | 0.56 s | from its old place to its new one (FLIP), with a lifted shadow `0 8px 18px` that settles to none | `cubic-bezier(.2,.8,.2,1)` | a task's lane changes: a gate goes red, a pull request opens, a merge, park, unpark, a sent-back or held merge card, a dependency merging (backlog to ready) | where the work went | the card is in its new lane at once |
| A card closes a gap in its lane | 0.32 s | the vertical distance only, no shadow | same | a card above it left or arrived, or a card's menu opened | the lane re-settled; nothing about this card changed | at once |
| A new card | 0.42 s | fades in from 8 px below | `cubic-bezier(.2,.7,.2,1)` | a task joins the plan, or a parked card returns while the parked group is closed | a card that was not on the board before | appears at once |
| A count rolls | 0.6 s | one figure height: up when the number grows, down when it shrinks | `cubic-bezier(.3,0,.2,1)` | any of the six tallies changes | merged, in flight, waiting on you, blocked, ready, backlog moved | the new figure replaces the old |
| A log entry | 0.42 s | fades in from 6 px above | `cubic-bezier(.2,.7,.2,1)` | the event is written | the newest line in the ship's log | appears at once |
| The captain's portrait | 0.32 s, the same curve as on deck | the pose's arm angles | `cubic-bezier(.2,.9,.3,1.3)` | a choice is picked (ready) or the pick is cleared (idle); a confirmed call leaves the deck at once, so the order pose comes from the order moment | the captain on deck and in the porthole are one man | the pose changes without travel |

Nothing else on the page moves: menus, the drop confirmation, the deck's strips
(their marker turns at once when a strip opens), the language switch and the
hour's colour change (1.2 s cross-fade, listed under the hour) have no travel.
Pressing the brass confirm button presses it in with an inset shadow; it does
not move. A card being dragged is the browser's own drag image; its place in the
lane dims to 40% until it is dropped.

## Inventory

Every `transition` and `animation` in the prototype's stylesheet, and every
Web Animation and engine tween in its script, with the row that specifies it.
Anything that moves and is not on this list is a defect.

| In `prototype.html` | Specified in |
|---|---|
| `body` page colours, `.scene` sky and sea colours, `.stars`, `.hull, .rig, .plate` filter, `.lampglow` (1.2 s) | The hour |
| `.jolly` `flutter` | Spray, wake and sails: Jolly Roger |
| `.jolly` transform transition (0.8 s) | Spray, wake and sails: Jolly Roger drops to hang |
| `.pivot, .ppivot` transform transition (0.16 s) | The crew: a figure turns back |
| `steer`, `scan`, `wave`, `bob`, `scribble`, `haul`, `heave`, `crank`, `trudge`, `climbL`, `climbR`, `hammer`, `saw`, `swab`, `stepA`, `stepB` | The crew |
| `.helm.live .wheel` `correct` | The crew: helm |
| `.fig.r-cap` arm transition (0.32 s) | Moments: captain's pose; the page: the captain's portrait |
| `.cutlass` opacity transition (0.2 s) | Moments: cutlass drawn or sheathed |
| `.fig.salute .armR` transition (0.18 s) | Moments: crew salute |
| `jolt`, `ping` | Moments: arrival |
| `cheerhop` | Moments: cheer |
| `spin2` | Moments: order |
| `ring` | Moments: bell |
| `flash`, `puff` | Moments: salvo flash, salvo smoke |
| `unfurl` | Moments: banner |
| engine: heave, pitch, heel, parallax, spray, wake, sail belly | The sea and the ship |
| engine: handoff flyer and trail tweens | Moments: handoffs, handoff trail |
| engine: clearing light tween (`--rays`) | The weather: light |
| Web Animations: `rollTo` | The page: a count rolls |
| Web Animations: `flip` | The page: a card changes lane, closes a gap, a new card |
| Web Animations: `renderLog` | The page: a log entry |

Removed from the prototype because they moved without encoding anything: the deck
strip marker's 0.15 s turn, the confirm button's 1 px press, and a 0.3 s opacity
transition on pennants that never played (pennants are redrawn, not restyled,
when a crewman's state changes).

A merge plays its card move and its tally roll first, in the same frame the
salvo starts, so the eye can go from the card to the ship.

## Reduced motion

`prefers-reduced-motion: reduce` starts the prototype still; the motion switch
(`R`) overrides it either way, and a system change is followed only while the
switch has not been used.

The still scene is not an empty one. State that motion carried is drawn
instead: speed as a standing wake and bow wave, wind as sail belly and a hanging
or flying flag, weather as the cloud band and whitecaps, handoffs as a drawn
arc with directed words, a merge as held smoke and the banner. The narration
line under the scene says what happened in every mode.

## CPU budget

**Budget:** below 10% of one core while nothing is happening (a calm sea, or a
breeze with no moment in progress), with a man-o'-war and 24 crew aboard, the
worst case the board can show. Nothing at all while the tab is hidden or the
scene is off screen.

**What keeps it there:**

- the loop runs at 20 frames a second on a calm sea and 30 under way, and only
  goes faster for the length of a moment;
- the loop does not run at all when motion is off, the tab is hidden or the
  scene is off screen, and CSS animations pause with it;
- per-frame work is transforms on eight parallax bands and one vessel, plus at
  most 54 particle attributes; no layout is read in the loop;
- the vessel, which carries every crew face, is re-set only after a quarter
  pixel of movement;
- each crew box is drawn with the three faces visible at the default turn
  (front, near side, top); the other two are added only to a figure someone
  drags. At 24 crew that is 1,065 faces instead of about 1,800;
- crew loops run only on live runs, at most three workers, a reviewer and the
  helm at the board's concurrency;
- sails are redrawn only when the belly moves by 0.03, which happens during a
  weather change and not otherwise;
- blur is on static layers that only translate, so it is rasterised once;
- the board around the ship has no loop and no timer: it re-renders on a state
  change and its few animations are one-shot compositor transforms (see the
  page around the ship).

**How it is measured:**

1. On the captain's machine, in Chrome, open `prototype.html` at a window width
   of about 1440 px. Press `6` (man-o'-war, 24 crew), then `W` until the sea is
   calm (the page opens in a squall). Scroll so the ship fills the window. Wait
   10 s for the springs to settle.
2. Open Chrome's Task Manager (Window, Task Manager) and read the CPU column for
   the tab over 60 s. Record the steady value. Repeat in a breeze with three
   runs (`L` until 3, `W` to breeze). The GPU process's line is recorded next
   to it, since compositing is where this scene spends its time.
3. Cross-check with DevTools, Performance: record 10 s idle and read the main
   thread's and the compositor's busy time; divided by 10 s it is the share of
   a core.
4. The in-page meter under the switches reports frames a second, script time a
   frame, how often the vessel was re-set, and how many crew faces are live.
5. Hide the tab for 30 s: Task Manager shows the tab at 0% and the meter reports
   the engine stopped when you return.

**What the worker measured, and what it did not.** In headless Chrome with
software compositing (no GPU) at 1440 × 1000:

- script time: 0.10 ms a frame on a calm sea, 0.18 ms in a breeze of three
  runs, with 24 crew (about 0.2% and 0.5% of a core at the capped rates);
- before face culling, compositing the man-o'-war's crew in software held the
  frame rate to 12 to 15 frames a second; hiding the crew brought it to the
  30 cap, which is how the crew faces were found to be the cost;
- after culling and the quarter-pixel rule, the same headless run holds its
  caps: 20 on a calm sea (24 while the springs settle), 29 in a breeze of
  three runs, the vessel re-set 10 and 29 times a second.

Tab CPU in percent was **not** measured: the tools that read it (Task Manager,
`ps`, a GPU-backed browser) were not available to the worker. Firstmate
measures steps 1 to 5 on the captain's machine and records the numbers on the
pull request. If the man-o'-war is over budget there, the next lever is to
flatten figures on decks nobody is dragging into cached layers, which costs the
free rotation of an undragged figure and nothing else.

## The emotional layer (T-086)

Everything T-086 adds that moves. The rule above still holds, with one
addition the captain settled: **every emotional beat answers a real event.**
Nothing here plays on a timer, nothing is random, and nothing shows progress
the board does not have. Section 14 of the script (`window.Emo`) holds all of
it; the board reaches it only through hooks marked `T-086`. Sounds are in
[sound-spec.md](sound-spec.md); every one is off until the captain turns it on.

The captain's order of feelings is companionship first, then accomplishment:
the greeting, the salute and weather-not-blame are companionship; the port, the
ranks and the kraken's defeat are accomplishment. The rituals (the first five
rows under Rituals) each last under two seconds and each has its own switch in
the ship's customs.

### The voyage chart

A 156 px band of chart paper under the scene. It is drawn from state and does
not move on its own: no idle motion at all.

| Moving thing | Duration | Amplitude | Curve | Trigger | Encodes | Reduced motion |
|---|---|---|---|---|---|---|
| The ship on the chart | none; drawn at its place | `x` = the previous port plus the leg's length × merged ÷ total of the current milestone | — | any change of merged tasks | how far the current milestone has come, from merged tasks only | the same |
| Making port: the glide | 1.9 s, once: to the port by 55%, holds to 75%, on to the new place | from the ship's place before the merge to the port, then to where the next milestone's merged tasks put her | `cubic-bezier(.3,0,.2,1)` | a merge completes a milestone | the milestone is done; the next leg may already be part-sailed | the ship is at her new place at once |
| Making port: the port's ring | 1.6 s, once | a brass ring spreading 0 to 26 px and fading | ease-out | the same | which port was reached | none; the port is drawn reached |
| An island clears the fog | 0.9 s, once | the new island fades up from blur 6 px | `cubic-bezier(.2,.7,.2,1)` | the captain approves a surveyed issue's spec card | the issue became specced work on its leg | appears at once |
| A course is set | none | a dotted brass line from the ship through the chosen islands, and a numbered flag on each | — | "Set course" on a ready island (the proceed answer on its readiness card) | the order the captain chose | the same |
| Tooltip on a port | none | the real milestone: id, title, merged of total, arrived / next / ahead | — | hover or keyboard focus | which milestone the nautical name stands for | the same |

### Ranks

| Moving thing | Duration | Amplitude | Curve | Trigger | Encodes | Reduced motion |
|---|---|---|---|---|---|---|
| A promotion: one turn on the spot | 1.4 s, once | up 10 px, a full turn about the vertical, down | `cubic-bezier(.2,.8,.3,1)` | a merge or an approval that crosses a threshold in `config.yaml` (after the merge's own 2.2 s moment, so the cheer is not cut short) | this crewman earned a rank | the new outfit and braid appear at once |
| The roster row | 1.6 s, once | a 2 px ink outline that fades | ease-out | the same | whose record changed | none |

The outfit and the pennant's braid are not motion: a rank is drawn, from
deckhand (nothing) through able seaman (ensign kerchief), bosun's mate (and a
striped shirt), bosun (and a brass bosun's call) to quartermaster (a dark coat
with brass buttons and a brass cap band); for reviewers, inspector (brass
spectacles) and chief inspector (and a sea-glass sash and a brass band on the
hat). The braid along the pennant's head counts the rank in tar dashes, in
brass when it is the top rank; a reviewer's is sea-glass.

### Rituals

| Moving thing | Duration | Amplitude | Curve | Trigger | Encodes | Reduced motion |
|---|---|---|---|---|---|---|
| Making port: fireworks | 1.8 s: three bursts at 0, 0.32 and 0.64 s, each 1.1 s | 18 sparks a burst, 46 to 70 px out, falling 16 px, opacity 1 to 0; brass, sailcloth, sea-glass, ensign | `cubic-bezier(.1,.7,.3,1)` | a merge completes a milestone (after the salvo has begun, 0.9 s in) | a port reached | the three bursts are drawn at full size for 1.4 s, then removed |
| A salute | 0.8 s from the approval's arrival: reviewer, then worker 0.22 s later | right arm to −150°, pennant swells to 110% | ease-out | the review approves a task on its first round (the approval handoff lands first, 1.4 s) | clean work, recognised by the crew | arms up in place, no swell |
| The greeting | 0.7 s, once | fades in from 6 px above | `cubic-bezier(.2,.7,.2,1)` | the day's first visit (the last visit's date in `localStorage`; never written in the playground) | one sentence of true numbers: merged since the last visit, cards waiting, the sea; a battle of three or more rounds adds yesterday's line | appears at once |
| Clearing and a cheer | 1.6 s: the light breaks to 0.42 over the first quarter and eases out; the crew hop once in 0.8 s, twice | `--rays` 0 to 0.42 to 0; hops 12 px then 5 px, crewman i at `min(i × 30, 300) ms` | light `inOutSine`; hop ease-out | a red check turns green (`G`) | the weather broke; the crew cheer together | the light is held at 0.3 for 1.5 s; arms up, no hop |
| Weather, not blame | the crew's `haul` loop (1.25 s), as long as the gate is red | the crewman on the red gate and up to two idle hands haul one line together; nobody sags or dims alone | as `haul` in the crew table | a red gate | a failure is weather the crew work through together | the three hold the haul pose |

With "weather, not blame" off, the man on a red gate sags and dims as in v2.
The pennant still says what is blocked ("T-078 blocked"); the words name the
task, never the crewman.

### The kraken

| Moving thing | Duration | Amplitude | Curve | Trigger | Encodes | Reduced motion |
|---|---|---|---|---|---|---|
| An arm rises | 0.9 s, once; each further arm 60 ms later | from 70 px under the rail's line to rest | `cubic-bezier(.2,.8,.3,1)` | a task reaches review round three without approval (`J` on a task at round two); arms already holding when the page opens are drawn in place | one arm per held task, at most eight; more are named in one tag | drawn in place |
| The head rises | 1.0 s, once | from 150 px below | same | the first arm | the kraken is here | drawn in place |
| The hold | 5.2 to 6.55 s a cycle (by arm), for as long as the task is held | ±1.6° to ±2.3° about the arm's root at the waterline | `ease-in-out` | a task held at round three or later | still holding: the work is stuck | still |
| Its eye | one blink, 0.5 s | the heavy lid from 42% closed to shut and back | `ease-in-out` | a blow lands | it felt that | none |
| A blow (combat and battle) | a shot 0.45 s from the nearest gun to the **head**, then the head rocks back for 0.42 + 0.07 × weight s after the hit-stop, and the explosion (below) | arc 50 px above the higher end; the head 3 px back, 2.5 px down and 1.8° per unit of weight | shot `inOutSine`; rock `cubic-bezier(.2,.8,.3,1)` | a confirmed combat action (weight 2; 3 for a drop), a push in a battle (`H`, weight 2), a skill | the real action or the real push landed. The head is the only target: an arm is never hit | no shot; one still frame of the explosion |
| It strikes the deck | 0.9 s: rears 36 px, slams 12 px down at 58%; at 0.52 s the ship heels and the rail bursts: a deck explosion of weight 3 (splinters, dust, shake, hit-stop) and a splintered section | heel spring kick 18 | `cubic-bezier(.4,0,.2,1)` | a rejected round on a task in battle (`J`); in the game, an unevaded slam | the review sent it back: the kraken hit us | no rear, shake or heel; the splintered rail appears |
| The storm thickens | lightning 0.5 s; the sea eases to the new weather over the weather spring's 1.3 s | per red check: cloud band +0.08 (+0.45 on a sea that was not in a squall), swell +2 px, spray +6 a second, foam +0.1, pitch +0.3° | lightning in two flashes; sea on the critically damped spring | a red check on a task in battle (`F`) | the battle is going worse | no flash; the sea is drawn at the new weather |
| Let go | 1.1 s | the arm sinks 200 px, fading to 60% | `cubic-bezier(.4,0,.6,1)` | park, or an approval outside a battle | the hold on that task ended without a fight | removed at once |
| Dragged down | 0.8 s, after the blow | sinks 200 px, with six bubbles rising 10 to 25 px over 0.7 to 1.0 s | `cubic-bezier(.6,0,.9,.5)` | drop, from the combat card or from the board's own menu or drag | the task was dropped | removed at once |
| The other arms dive | 1.0 s, 0.12 s after the dropped arm | each sinks 200 px | `cubic-bezier(.6,0,.9,.5)` | a drop while other tasks are still held | the kraken flees whole, whatever else it holds | removed at once |
| Down whole | 1.3 s, from 0.5 s after the last arm starts down | the head sinks 160 px and fades | `cubic-bezier(.5,0,.8,.4)` | a drop of a held task (always), or the last held task parked or approved | the kraken fled, or nothing is stuck now | removed; the far shadow, or the kraken below, is drawn |
| Below the surface | none | a blurred ink mass at the bow's waterline with one brass eye, and a tag for each task still held ("still held; the kraken waits below") | — | a drop while other tasks are still held | it fled but still holds work; the tag opens that task's combat card | the same |
| Shrinks to the distance | 1.3 s, after the blow | the whole kraken to 30% at the horizon, 10% of the way across, opacity 80% | `cubic-bezier(.4,0,.2,1)` | rescope, **whatever else is held**: the other arms let go with it | rescoped work remains; the kraken waits far off until it merges, with a tag for each task it still holds | drawn far off |
| Returns | 1.1 s from the distance (the reverse), or the head and arms rise as above from below | as above | same | a real event only: a rejected round on a task it still holds (`J`), a task newly held, or the captain facing it (the tag, or *Face the kraken* on the card) | it is back | drawn near |
| The shadow far off | none | a blurred ink shape at 34% on the horizon | — | nothing held and nothing rescoped at sea | it is out there; nothing is stuck | the same |
| Victory | the pupil widens in 0.5 s; from 0.7 s the arm lifts 10 px, raises a scrap of sailcloth and sinks 200 px over 2.2 s; at 1.3 s a column of water (weight 3.5) where it leaves the sea; the head goes under from 1.2 s; the light breaks over 3.4 s; the crew cheer from 0.6 s; the banner "Victory" for 3 s. The fanfare is 4 s | pupil to 2.6 × 0.9; `--rays` to 0.5 | arm `cubic-bezier(.5,0,.7,.4)`; light `inOutSine` | the review approves a task in battle (`V`), once per approval; in the playground, every time it is triggered | the worker and the reviewer won | the arm and head are removed; the banner shows still |

**Combat mode stays under three seconds** from the confirm: the action is
written and the board re-rendered in the same frame, the blow lands on the head
by 0.45 s, the hit-stop holds to 0.54 s (0.51 s at weight 2), the explosion's
smoke is gone by 2.2 s, an arm that leaves is gone by 2.1 s (let go) or 1.8 s
(dragged down), and a kraken that goes down whole is gone by 2.8 s. The
animation never runs before the action is on the board, and nothing on the
kraken moves without a confirmed action or an event behind it.

### The battle mini-game

Only while the captain plays along in a real battle, or with the playground's
fake kraken. Skills touch the battle only: a bruise, a reel and deck splinters
are drawn, nothing is written, and only an approval wins. Its loop is one
`requestAnimationFrame` that runs only while the game is on and the tab is
visible, and stops the moment the captain stops playing or the battle ends.

**The head is the only hit target** (captain, 2026-09-24). The tentacles carry
the cards (a task id that opens its card), so no blow lands on one, and no
effect may cover or hide one: every effect draws in one SVG layer masked by
each arm's outline, grown 11 px all round and drawn again where the arm rears
(36 px up) and slams (12 px down, 6 px across), so the arm and its sway stay
clear. The tags are HTML above that layer. An arm is picked (the chain-shot's
two, the arrow keys) but never struck.

| Moving thing | Duration | Amplitude | Curve | Trigger | Encodes | Reduced motion |
|---|---|---|---|---|---|---|
| Broadside aim ring | closes over 1.1 s | from 96 px to 0 round the head, over a dashed brass ring of 26 px | linear | the first click or tap on the head (or `1`, or Enter) | when to fire: within 5 px of the brass ring is perfect (3), within 14 good (2), else glancing (1) | kept: the ring is the control |
| Broadside | three shots from three guns, 90 ms apart, each a blow of weight 1 to 3 on the head, spread 16 px; a perfect one ends in a fourth burst of weight 3.5 | as a blow | as a blow | the second click, tap or key | the shot and its timing | one still frame each |
| Chain-shot | the drag line follows the pointer; the bound arms hold 6 s | two balls on a chain, spinning 38° a frame, to the head: weight 2. The bound arms' sway pauses and their tags show a shackle | none | drag a line across two arms (it binds as the second is crossed), tap two arms in turn, or `2` (the selected arm and the next) | two arms bound: their attacks pause | the shackles are drawn |
| Harpoon charge | grows over 1.5 s while held | ensign ring 14 to 58 px round the head | linear | hold on the head (or hold `3`) | the charge: 1 to 4 on release | kept |
| Harpoon | a 0.3 s throw trailing its line from the gun; the line fades over 0.5 s | weight 1 to 4; at 4 a second burst 150 ms later | `outCubic` | release | the heavy blow | one still frame |
| Full sail | the heel spring's rock, about 1.2 s; a dodged strike lands in the sea as a column of water (weight 2.5) beside the ship | kick −16 | the heel spring | space (or `4`), the button, or the wind-up bar | the ship turns away | no rock; one still frame |
| The kraken's attacks | below, "The kraken's attacks" | | | | | |
| The crew's guns | a blow every 2.4 s, every 1.2 s under the captain's order | weight 1 | as a blow | the game's clock | the crew fight with you | one still frame |
| Captain's order | 5 s | every gun fires bow to stern, 45 ms apart: a muzzle flash and smoke at each port; then two shots of weight 1.5 on the head. The captain's order pose, the crew salute in a 30 ms stagger | as the captain's pose and the salute | click the captain, or `5` | the crew's guns double | pose in place; still frames |
| Repair | about 0.9 s | a repair burst on the section: a brass glow ring, sawdust, hammer sparks | as the explosion | click a splintered section (or `6`) | the deck is whole again | one still frame |
| Bruise and reel | bruise over 0.3 s; a reel for 3 s | the head darkens 0.055 a point to 0.6; at 10 points the head sinks 34 px and every arm 28 px, and back, and it cannot attack | `ease-in-out` | points from blows on the head | it is hurt but comes back: skills never sink it | no sink |
| Cooldown | as the skill's cooldown | an ink sweep over the skill's fitting and the seconds left | linear | a skill used | when it can be used again | the seconds and a still sweep |

### The kraken's attacks

In the game only (captain, 2026-09-24): every attack is telegraphed long enough
to react, read off a wind-up bar with a perfect zone at its end, and dodged or
not. Four patterns, each with its own telegraph and bar speed; the mix follows
the real review rounds (README, "The kraken's attacks"), in a fixed order.
Times are from the attack's start; *p* is the bar's fill, 0 to 1 at the strike.
All of it is drawn by the game's own loop, so it stops with the game.

| Moving thing | Duration | Amplitude | Curve | Trigger | Encodes | Reduced motion |
|---|---|---|---|---|---|---|
| The wind-up bar | a slam 1.6 s; a jab 0.85 s; a combo 1.15 s, a 0.26 s beat, then 0.7 s; a feint 0.88 s to 55%, a 0.7 s hold, 0.38 s to the end | a tar track 14 px high (a jab's 10) at the upper left of the scene, filling in ensign (a feint's fill dashed); the perfect zone the last 14 to 17% in hatched brass, lit with a sailcloth ring and a brass glow once *p* is inside it; a feint's track shivers ±1.5 px every 0.12 s while it holds | linear fill | an attack starts: 4 s after play begins, then 5.2, 4.4 or 3.6 s after the last one ends (review round 3, 4, 5 and on), from the next unbound arm, never while it reels or in a slow beat | what is coming, where, and when to dodge | kept: the bar is the control; the feint's shiver is dropped |
| The head rears | as the bar | up to 12 px up and −6° about its base, × 1 (slam, feint), 0.75 (combo), 0.45 (jab); a feint holding trembles ±1.2° | with the bar | the attack's wind-up | which way it is coming, and how hard | no pose |
| The attacking arm draws up | as the bar | up to 30 px up (× the same weights) | with the bar | the same | which arm | no pose |
| The target spot | as the bar | an ensign glow 20 to 36 × 7 to 11 px, opacity 0.2 to 0.95 with *p*, blurred 3 px, under the dashed ring (±6 px pulse) on the deck section | linear, the ring on a sine | the same | where it will land | the glow and ring are drawn, the ring still |
| The strike | 0.46 s: from reared to a slam 12 px down and 6 px across by 30%, back; the deck's explosion 0.12 s in (weight 2 to 4), the ship heeling by `12 + 2w` | as the explosion | `cubic-bezier(.5,0,.3,1)` | the bar full and no read dodge | we were hit: a rail section splinters | no slam; one still frame |
| Into the sea | 0.52 s: the arm slams 22 px down beside the ship; a column of water (weight 2.5) 26 px off the section | as the explosion | `cubic-bezier(.5,0,.3,1)` | the bar full after a dodge or a perfect dodge | it missed | one still frame |
| A too-early dodge | the ship's heel only; the bar's fill turns to ensign and tar dashes | — | — | a dodge before half the bar, or into a feint's hold | the kraken followed the ship | the same, still |
| The counter window | 1.5 s after a dodge; 2 s after a perfect one, from the end of the slow beat | a sea-glass dashed ring round the head, 8 px out, breathing ±3 px; a sea-glass prompt under the wind-up bar | sine, 0.7 s | a dodge in the window | counter now: the head is open | the ring still |
| The slow beat | 0.48 s | the world at 0.3 speed (the engine's springs and tweens, every running animation); the scene's edges darken in ink (a radial fade from 55% of the way out, to 75% ink at the corners), up by 20% and down from 70% | ease-out | a perfect dodge | that was perfect | none |
| The weak point | the counter window | a brass disc on the crown of the head (9 px × the kraken's scale) with a brass ring breathing ±4 px | sine | a perfect dodge | where the critical hit lands | drawn still |
| The counter | a shot 0.45 s to the head, then an explosion of weight 3.2 | as a blow | as a blow | the head tapped or clicked, or Enter, in the window | the counter landed | one still frame |
| The critical hit | a shot to the weak point, then the largest explosion (below) of weight 4.5, plus 0.5 for each perfect dodge in a row after the first, to 6 | as the explosion, "crit" | as the explosion | the counter after a perfect dodge | the combo: the chain of perfect dodges | one still frame of the flash and two rings |

The dodge's reading and its timings are in the README. Every strike and every
dodge touches only the battle.

### The explosion

Every blow ends in one, layered and scaled by its weight *w* (1 light, 4 the
heaviest harpoon, 4.5 to 6 a critical hit). The scatter is seeded by a count, so the same blow draws the
same; nothing is random. Colours are the plan's: sailcloth at the heart, brass,
ensign red burning out; iron and oak debris; tar-and-sailcloth smoke.

| Layer | Duration | Amplitude | Curve | Reduced motion |
|---|---|---|---|---|
| Hit-stop | 24 + 22*w* ms (46 to 112 ms) | the kraken's sway freezes and every layer holds its first frame | — | none |
| Flash | 150 + 30*w* ms after the hit-stop | radius 12 + 10*w*, scale 0.55 to 1.5, opacity 1 to 0 | `cubic-bezier(.15,.7,.3,1)` | drawn still for 0.26 s |
| Fireball | 360 + 70*w* ms | radius 10 + 9*w*, scale 0.35 to 1.1 to 1.3, rising 6 px | same | none |
| Shockwave | 380 + 60*w* ms; from *w* = 3 a second ring 90 ms later, 160 ms longer | a sailcloth ring to 36 + 26*w* px, stroke 2 + *w* to 0.5 | same | the ring drawn still for 0.26 s |
| Debris | 620 + 90*w* ms | 3 + 3*w* chips (iron on the head, oak on the deck, drops in the sea, sawdust in a repair) flung up and outward 34 + 22*w* px, falling 22 + 10*w*, spinning | `cubic-bezier(.2,.6,.5,1)` | none |
| Embers | 700 + 160*w* ms, staggered up to 160 ms | 3 + 3*w* brass sparks rising 24 + 22*w* px | `cubic-bezier(.1,.5,.4,1)` | none |
| Smoke | 1100 + 180*w* ms | 1 + *w* puffs of radius 10 + 6*w*, to 1.9×, drifting up 18 + 8*w* | `cubic-bezier(.2,.6,.4,1)` | none |
| Screen shake | 240 + 80*w* ms | ±(1.2 + 1.7*w*) px (15% more on the deck), four swings | `cubic-bezier(.3,.7,.4,1)` | none |

Variants: a slam into the sea or a victory's sinking is a column of water with
drops and mist, no fire; a slam on the deck is a fireball over oak splinters; a
repair is a glow ring, sawdust and sparks, with no hit-stop or shake; a gun
firing is a small flash and a puff of smoke. **A critical hit** is the largest:
its hit-stop is that of *w* + 2 (up to 0.2 s), the scene flashes (sailcloth at
70%, fading over 0.26 s, drawn in the masked effect layer so it passes round
every arm), a white-hot core pulses inside the fireball (0.3 + 0.04*w* s), three
shockwave rings, half as much debris, embers and smoke again, the shake 30%
larger, and an iron clang over the boom.

### Around the board

| Moving thing | Duration | Amplitude | Curve | Trigger | Encodes | Reduced motion |
|---|---|---|---|---|---|---|
| An issue card fades into the Issues lane | 0.42 s | as a new card | as a new card | an issue synced (`I`) | a new open issue | at once |
| A card slides out of the Issues lane | not a slide: the issue card leaves, and the new task's card fades into ready or backlog | as a new card | as a new card | the spec card approved | the issue became a task | at once |
| A card found from the chart | 1.2 s | a 2 px ink outline that fades | ease-out | "Show its card" on an island | which card the island is | none |
| The playground | none | a hatched brass-and-tar frame round the page and an ink banner | — | the playground switch | nothing here is real | the same |
| Leaving the playground | at once | every timeout, engine tween and scripted animation started in the playground is cancelled, and the effect layers (the kraken's, the fireworks, the deal layer and the handoffs' flyer, trail and note) are cleared, with every leftover a cancelled clean-up would have removed (leaving arms, a sealed card, an option card in flight, a count mid-roll, timed pose classes), before the live state is restored | — | the switch off | nothing it scheduled lands on the live board | the same |
| A decision's option diagram | none for its content: it switches the instant an option is picked (the flip below only frames the new content and never delays it; where the two rows seem to differ, this one wins), and the custom answer's "after" follows the text as it is typed | before, an arrow, after, under the authored diagram; "Pick an option first" until one is | — | picking A to D or your own answer | what that option changes | the same |
| The floating controls | none | a drawer at the lower right, up to 58% of the window high; hidden, only its tab | — | its tab, or `K` | — | the same |
| A reset | at once | as leaving the playground: every timeout, tween and scripted animation is cancelled, and the effect layers and every leftover are cleared as there, before the fixture returns | — | the board's reset | nothing the old state scheduled lands on the new | the same |

### The decision cards

Strategy-game cards (captain, 2026-09-24). Every effect is under one second,
follows a real action, and frames the face: nothing is drawn over its words,
which stay flat at the 13 px and 16 px floors. The frame and emblem by kind, and
the urgency's pips, are drawn, not moved.

| Moving thing | Duration | Amplitude | Curve | Trigger | Encodes | Reduced motion |
|---|---|---|---|---|---|---|
| Dealt | 0.64 s; a second card 0.09 s later | from 180 px right and 60 px up, turned 7° and edge-on (−88° about the vertical), transparent; opaque by 25%, face up and at −1° by 80%, square at the end | `cubic-bezier(.2,.75,.25,1)` | a card raised while the page is open (a survey, an issue to raise, a task become ready) | a new call arrived | appears in place |
| Tilt toward the pointer | follows the pointer; 0.2 s to settle, and back flat on leaving | up to ±2.5° about the vertical, ±1.75° about the horizontal, in 1800 px perspective | ease-out | a mouse over the card; never while typing in it, never on touch | the card is in your hand | flat |
| Foil glare | follows the pointer; fades in and out over 0.2 s | a sailcloth highlight 180 × 140 px under the pointer and a brass and sea-glass band sliding with it, overlaid on the 8 px frame only | — | the same | — | none |
| A hand card lifts | 0.16 s | up 8 px from its place in the fan (±0.8° per card from the middle, 3 px lower per card out), its shadow deepening | ease-out | hover or keyboard focus | this is the one you are about to play | none |
| Played onto the table | 0.38 s | a copy of the table's chip flies from the picked card to the table, scaling to the chip's size | `cubic-bezier(.3,.7,.3,1)` | the pick (the pick is on the board first) | this option is on the table | the chip appears at once |
| The option's diagram flips | 0.32 s, from 0.3 s | from edge-on (88°) and 40% opacity to square | `cubic-bezier(.3,.7,.3,1)` | the same | its before and after | swaps at once |
| Sealed | 0.94 s: the wax seal drops from 2.4× and −20° to 1× in 0.2 s; a ring 0.4 to 3.2× from 0.17 s over 0.36 s; the card jolts 3 px down over 0.13 s; slides 60 px right and 24 px up, turning 3°, fading, from 0.44 s over 0.3 s; the deck closes up over 0.22 s from 0.72 s | a 54 px wax disc on the frame's corner, clear of the words | seal `cubic-bezier(.6,0,.9,.4)`, ring `cubic-bezier(.15,.7,.3,1)`, leave `cubic-bezier(.5,0,.8,.4)`, close ease-in | *Confirm* (the answer is written first; the sealed card is a copy laid where it was) | the decision is made | the seal shows still on the card for 0.3 s, then it goes |

### Inventory, T-086

| In `prototype.html` | Specified in |
|---|---|
| `ksway` | The kraken: the hold |
| `blink` | The kraken: its eye |
| `kshake` (amplitude and duration from `--shk`, `--shkT`), `bolt` | The explosion: screen shake; the storm thickens |
| `.hitstop` on `#kraken` | The explosion: hit-stop |
| `rankup`, `.rrow.promoted` (`cardflash`) | Ranks |
| `portring` | The voyage chart: making port |
| `cardflash` on `.card.flash` | Around the board: a card found from the chart |
| Web Animations: the chart ship's glide, `clearFog`, `showGreeting`, `fireworks`, `rise`, `leave`, `bubbles`, `hitHead`'s rock, `boom`'s layers (and the critical hit's flash), `strike`, `slamSea`, `hitGame`'s reel, the harpoon line's fade, the kraken's far and near transitions, the victory pupil, `slowBeat`'s edges | the rows above |
| Web Animations on the deck: `deal`, `played` (the flight and the diagram's flip), `seal` (the wax, its ring, the jolt, the leave, the close) | The decision cards |
| `wheld` (a feint's bar holding); the tilt and the hand's lift are CSS transitions on `--rx`, `--ry` and the hover | The kraken's attacks; the decision cards |
| engine tweens: `blow`'s shot, `clearingCheer`'s and `victory`'s light; `Engine.scale` for the slow beat | the rows above |
| the game's `requestAnimationFrame` loop: the wind-up bar, the pose, the target spot, the counter's rings, the weak point | The battle mini-game; the kraken's attacks |

### Reduced motion, T-086

Every row gives its still replacement. The still scene keeps what the motion
said: the kraken's arms are drawn with their tags, a splintered rail stays
splintered, a thicker storm is drawn thicker, the chart's ship is at her place,
and the narration line under the scene says what happened. The game's aim and
charge rings keep animating, because they are the controls the captain acts on,
and so does the attacks' wind-up bar; the head and the arm hold still through a
wind-up, there is no slow beat, and the weak point and the counter's ring are
drawn still. An explosion is one still frame of its flash and shockwave ring for
0.26 s, with no hit-stop, shake or particles (a critical hit adds a second
ring). The decision cards lie flat: no tilt, no glare, no lift; a card arriving
appears in place, a played option's chip and diagram change at once, and a
sealed card shows its seal still for 0.3 s, then goes.

### CPU, T-086

Nothing here adds to the idle frame. The chart is static DOM and SVG, redrawn
only on a state change. The kraken's hold is a CSS rotation on at most eight
SVG groups, composited, and only while a task is held; with nothing held there
is a static shadow. The game's loop runs only while the captain plays. The
ambient sea (sound spec) ticks a 120 ms timer only while it is on and costs no
frames. An explosion adds at most about 40 short-lived SVG nodes, each on one
Web Animation, removed when its longest layer ends (under 2 s); a critical
hit about 60. The attacks add nothing outside the game: the wind-up bar is one
element whose fill is a CSS variable set by the game's loop. The decision cards
cost nothing idle: the tilt and glare run only under a moving mouse, and each
deal, play or seal is a handful of Web Animations under a second. To measure: repeat steps 1 to 3 of the CPU budget in the opening squall
(two arms holding) and compare with the kraken switched off in the ship's
customs; the difference is the kraken's cost.
