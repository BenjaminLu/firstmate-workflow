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
