# Movement pass: the walkable ship (2.5D first, 3D after)

Captain's decisions, 2026-09-26:
- Movement works in both Playground and Live. It is cosmetic only and never writes to the board.
- Mini-games are Playground only.
- The default camera stays the director's. A key (and tapping the captain) enters control mode; the same key or Esc leaves it.
- 2.5D first. 3D reuses the same data after that.

## Shared: the walkable ship model (`v3src/sim/` or a new shared module, identical in both games)
- Per ship class (sloop 7, brig 12, frigate 18, ship of the line 24):
  - **Decks:** hold, gun deck, main deck, quarterdeck, forecastle, and the crow's nest where the class has a mast for it.
  - **Walkable spans** per deck, with obstacles (masts, guns, hatches, capstan, wheel, rails).
  - **Links** between decks: stairs and ladders, including the shrouds up to the crow's nest.
- The model is rebuilt on a class transform and scales with the ship.
- **Stations:** every worker and reviewer station gets a deck position. The captain sits at the wheel and the firstmate nearby, both clearly apart; reviewers and workers are spread out with a minimum spacing. It must stay readable at every class and on phone portrait.
- **Pathing:** crew walks are routed on this graph (A* across spans and links). Crew avoid obstacles and each other (separation), deterministically.

## 2.5D
- **Ship art:** redesign the hull in cutaway so the decks and the stairs/ladders read, for every class.
- **Captain control:**
  - Arrows/A–D move left and right; ↑/↓ or W/S take a stair or ladder when standing at one.
  - The camera follows the captain.
  - On phones, a virtual joystick.
- **Interact** (E / tap) near a working crewman opens that station's mini-game, Playground only:
  - gun: a loading rhythm;
  - rigging: hauling sail;
  - crow's nest: spotting a sail;
  - reviewer: stamping.

  A win gives a small morale boost in Playground only.
- **Tests:**
  - no crew inside obstacles or overlapping, over a long run at every class and across transforms;
  - every station is reachable;
  - the captain can reach every deck;
  - control mode enter/leave;
  - Live never writes.

## 3D (after 2.5D)
- Third-person over-the-shoulder captain: WASD plus mouse look; on phones, a joystick plus drag.
- The camera never enters the hull or obstacles.
- The same deck graph gives collision.
- The same mini-games, in 3D form.

## What the 2.5D pass built (2026-09-26)

- **Shared model:** `v3src/sim/deckplan.js`, byte-identical to `voyage-game/src/sim/deckplan.js` (a test compares them). No DOM, no canvas, no randomness.
- **Decks per class:** quarterdeck, main deck (the waist), forecastle, one gun deck (two on the ship of the line: `gun`, `gun2`), the hold, and the crow's nest on the mainmast of the brig, frigate and ship of the line (the sloop has none; its lookout stands in the bow).
- **Hull:** deeper, cut away on the near side from under the main deck to the hold's floor. The ship rides higher (`ride`) so every gun deck is dry. The near sea is cut away where the hull is, and the hold shows below the waterline with a tint. The palette, line weight, rails, galleries, figurehead and name plate are unchanged; the plate moved to the keel band.
- **Guns:** now on the gun decks, muzzles toward the viewer on carriages. The far side's ports and breeches are on the back wall. The brig's short gun deck holds five of its six guns; the ship of the line has two gun rows of ten, not three.
- **Rest:** the old one-file spacing is kept per file: the topside is one row, and each interior deck and the nest is its own row, drawn boxes kept 16 apart, and the firstmate 60 from the captain. The captain is pinned at the wheel: when a row is too full, the crew is drawn smaller (fit) instead of pushing him off it. Idle hands' homes are the waist first, then the hold, then the gun decks, then the forecastle.
- **Stations:** the sim's `top` goes to the lookout (the nest, else the bow), `amidships` to the rigging (the masts and the capstan), and `main` to the guns.
- **Walking:** A* over a column graph per deck plus the links. Walkers keep out of the resting lane. Blocked, they keep right, then give way by rank. A link is held by one walker at a time, first come first served, and its two landings are his while he holds it.
  - **Last resort:** a walker boxed in for 6 s slips past to the next clear spot on his way, shown as a quick fade. It is deterministic and rare (a handful in 8 minutes of the busy test).
  - **Collision rule:** footprints (circles in x and z) never overlap and never touch an obstacle, at any step, walking or not. The drawn boxes are kept apart at rest. Walkers may pass in front of or behind each other in depth, as characters do in a 2.5D view.
- **Captain control:** see `src/control.js`.
  - **Key:** Q, because C is the camera.
  - **Precedence:** Esc closes the innermost thing first: the menu, the crew card, a mini-game, the decision card (folded), then the deck. While a card is up, A–D and Enter belong to the card; the arrows still walk. While the captain has the deck, S walks down; the sound stays in Settings.
- **Mini-games:** see `src/minigame.js`. They are Playground only. A win adds 1 to a local morale count and makes the crew cheer. It is never written anywhere.
- **Known limits:**
  - **Clipping:** the captain is taller than a gun deck's headroom, so his hat overlaps the beam when he goes below.
  - **Class changes:** the deck model switches to the new class as the transform starts. A crewman standing where the new class has an obstacle steps to the nearest clear spot at once (a small pop). A crewman on a deck the new class lacks (the nest, `gun2`) steps down to the nearest deck.
  - **The hero ending:** it still lines the crew up by itself. Walking is suspended for it, crew below decks appear on the waist for the lineup, and everyone walks home after it.

## For the 3D pass

**Import** `src/sim/deckplan.js`. It is the same file as the 2.5D's.

```js
import { SHIP_CLASSES, classFor, deckGeometry, buildNav, findPath, planRest, Crowd,
         linkPoint, linkSteep, levelIds, hullOutline, DEPTH, Z_SCREEN } from "../sim/deckplan.js";
```

**Space.** Ship space is the 2.5D's:

- x runs from the stern toward the bow;
- y runs down, with the main deck's top at 0;
- z runs across the deck, from the near rail (0) to the far rail (`DEPTH` = 420; the nest is 260).

The 3D maps it as `(x, y, z) -> (x * s, -y * s, (z - DEPTH / 2) * s)`, with one scale `s` per class. It must not use `Z_SCREEN`: that is the 2.5D's flattening of depth into a lift.

**What the model gives:**

- **`SHIP_CLASSES`:** per class, the spans, the deck heights (`qd[2]`, `fore[2]`, the interior `levels`), the masts (with the nest height: the lower masthead, over the course yard and a standing lookout under the topsail yard of the 2.5D's drawn rig; brig -1030, frigate -1160, ship of the line -1420), the gun count, `bottom` (the keel), `ride` (how high she floats) and `crewScale`.
- **Stairs (2026-09-27, the captain's "樓梯寬一點"):** every flight and its hatch is `STAIR_W` = 160 across the deck (z), from the far rail in (1.6x the first 100), wide enough for two crewmen abreast; the stairs' landings stand on the flight's middle (`z = DEPTH - STAIR_W/2 - 20`). Placement, guns, stations and every deck's connectivity are checked as before at every class (`tests/run-stairs.test.mjs`). The 2.5D draws the flight's treads across its whole width (a stringer at each side) and a stair's hatch as deep as its flight; the 3D builds its treads, hatch coamings, floor openings, the breast rails' openings and the lens's free space from the same rectangles.
- **Running (2026-09-27, the captain's "船長可以跑步嗎?"):** in control mode only, Shift held (or the phone's stick pushed past `RUN_STICK` = 85 % of its radius) runs the captain at `RUN` = 1.8x his walk. The controls ease `manual.run` 0→1 over 0.25 s and back over 0.3 s; `drive()` multiplies by `runK(manual)`. Links keep their own pace (a stair, ladder or the shrouds climbed with the run held takes exactly as long), and nobody else ever runs. Every rule of the crowd holds at run speed (a step is 9 units a tick against footprints of 26–35: no tunnelling). The run cycle is the walk pushed further (`src/puppet.js` `RUN`): the run comes in with the speed itself (past 1.15x the walk, all of it by 1.6x), a 40 % longer stride (so the cadence rises less than the speed), bigger leg and arm swings with the elbows bent near square, 7° more lean, a bigger bounce and squash; its bounds are `tests/movement-browser.test.mjs` "the run".
- **Climbing:** stairs at 0.75 of a crewman's speed, ladders at 0.5, the shrouds at 0.5 but never slower than `SHROUD_SECS` (3.2 s) from the rail to the nest, so the lookout is up in under 5 s at every class in both games.
- **`hullOutline(S)`:** the side profile as a polygon (clockwise), to loft or to check the camera against.
- **`deckGeometry(S)`:** returns `{ decks, obstacles, links, guns, stations, cut, wheelX, capX }`. It takes ~25–100 ms, so cache it per class.
  - **`decks[id]`:** `{ y, x0, x1, depth, rest, topside }`, a flat walkable rectangle.
  - **`obstacles`:** `{ deck, kind, x0, x1, z0, z1 }` rectangles. The kinds are mast, gun (near and far), hatch, stairs, ladder, capstan, wheel, cask and crate.
  - **`links`:** `{ id, kind: stairs|ladder|shrouds, a:{deck,x,z}, b:{deck,x,z}, path:[[x,y],...], len }`. The path runs top landing, flight, bottom landing. Use `linkPoint(L, s, rev)` and `linkSteep` to place a climber and to choose the climbing animation.
  - **`guns`:** `{ deck, row, i, x, y }`, where `y` is the muzzle height.
  - **`stations`:** `{ id, kind: helm|mate|review|gun|rig|lookout, deck, x, z, dir }`.
- **`buildNav(G)` / `findPath(nav, from, to, r, busy)`:** routes as a list of steps: `{ deck, walk:[[x,z],...] }` and `{ link, from, to }`.
- **`planRest(G, items)`:** where everyone stands at rest, spaced by drawn width. Each item is `{ id, deck, x, dir, ext:[left,right], f, gapL?, weight?, pin? }`; the result is `{ fit, at: { id: { deck, x, z, dir } } }`. The 3D can pass its own widths.
- **`new Crowd(G)`:** the deterministic walkers.
  - **Calls:** `add(id, {deck,x,z,r,pri})`, `remove`, `goTo(id, goal, onArrive)`, `step(dt)` (fixed 1/60 s ticks inside), `setGeometry(G)` on a class change, and `violations()` for tests.
  - **The captain:** set `agent.manual = { vx, run }` to walk him (`run` 0..1 or true: up to `RUN` x as fast). `linkAt(agent, way)` and `takeLink(id, way)` take the stair or ladder he stands at (way -1 up, +1 down).
  - **Agent state to render:** `deck`, `x`, `z`, `link` (`{ L, s, rev, from, to }`), `moving`, `dir` and `slipped` (the time of a slip, for a fade).

**What the 3D must supply:**

1. **Mapping and heights:** the ship-space-to-3D mapping above, and the deck heights from the model. The 3D hull must have the same interior levels, or a 3D model of them.
2. **Cameras:** the over-the-shoulder camera's collision against the hull and the obstacles. Use `hullOutline` for the sides, `decks[].y` and the obstacle boxes (the height of each kind is the 3D's own choice), plus the beam under each deck.
3. **Crew widths:** its own drawn widths for `planRest` (or the 2.5D's FOOT table scaled), and a footprint radius of about 26 × `crewScale`, the same as the 2.5D.
4. **Input to the Crowd:** WASD and mouse look become `manual.vx` along the ship's x. The 3D may later add a z input; `drive()` currently steers z itself.
5. **The mini-games in 3D form:** the rules can be reused from `src/minigame.js` (GAMES). Only the drawing is 2D.
6. **The same gates:** Live shows no prompt and no game, nothing writes, and the fight and endings close the deck.

## The big ship (2026-09-28)

The captain's note: 「2.5D船體的形狀一直有點不協調 船長橫移碰到船員永遠過不去，一艘小船擠滿了人 船需要變得超大
人變得超小 移動空間 房間 船長室 等等 才能設計出來 社群也才有更多素材開發mod改造」.

- **A fork.** The 2.5D's model is now `src/deckplan.js`; the 3D keeps the shared file, frozen.
  Ships are **layouts** (plain data: `src/layouts.js`, or a mod, `docs/modding.md`): decks, rooms of
  a kind (helm, cabin, chart, waist, workshop, forecastle, gundeck, quarters, galley, cargo, open),
  bulkheads with doorways (`aft`/`fore`: door, wall, open), stairs and ladders at given x, masts
  (with a crow's nest each), furniture and stations. A room's kind furnishes it and gives its
  stations. `checkLayout` is the gate: every room and station reachable from the helm, no link
  into a mast, a bulkhead or another link.
- **Scale.** Every deck is 480 below the one above (2.4 crewmen); the sloop is 6,000 long, the ship
  of the line 10,000, with 3 or 4 decks under the main deck. Lengths in crewmen are 3.4–4.1x the
  old ones, depths 2.6–3x (`tests/movement.test.mjs`).
- **The hull** is drawn from the layout: a sheer that rises to the ends and steps up over the
  castles with a crisp break, the stem raked and swept into the keel, the counter overhanging aft,
  a sawn rim round a full-length cutaway (the old one was a rounded window in a deep, short tub).
- **Passing.** The captain is a `ghost` walker: no crewman blocks him and he blocks none; his drive
  steers into a lane the crew ahead leave clear (samples along the next 80 units, so a doorway
  is a lane only where it is), and where they fill every lane he passes them in depth. Why a depth
  pass and not stepping aside: the crew stand at their stations doing their work; moving them would
  break the picture of the workflow, cascade down a crowded gun deck and could still box him in.
  Regression: `tests/movement.test.mjs` "the captain walks the whole length of every deck through a
  line of crew" (every class, three decks, a crewman every 160 in four lanes) and
  `tests/bigship-browser.test.mjs`.
- **Stations** follow the workflow state (`kindFor` in `src/world.js`), the nearest free one of the
  kind; a class change or a state change re-plans; hands placed by hand (the test hooks) are pinned.
- **Camera.** The director's wide shot is the ship in section (every room, the lower sails); on a
  portrait phone a 2,600-wide slice round the action; Z or ⤢ shows the whole ship; the wheel and a
  pinch zoom; the follow camera flies to the captain (k 14). The fight frames the forward half and
  the kraken, which is drawn larger (its head over her main deck).
- **Drawing.** The ship's two layers are cached as a whole-ship picture plus 512-px tiles made as
  the camera comes close (3 a frame, 2 on phones); the crew are drawn only when in view.
- **Known limits.** A class change cross-fades the two ships (no plank-by-plank growth any more).
  Walks were long on the biggest ships (~30 s across the ship of the line at 300 a second).

## The pace, the embed's controls, the kraken (v2d-12, 2026-09-28)

The captain on v2d-11: 「船長不能跑了」 and 「整體移動要快速一點, 現在太拖, 原本遊戲內的操控面板 設定不見了,
情緒價值的部份要保留 海怪沒看到」.

- **Pace.** Everyone walks `WALK_SPEED` = 1100 a second (was 300); the captain's run is 1.8x
  (1980). Stairs climb at 0.85 of the walk, ladders at 0.55. The frigate's cabin to its bow is ~7.6 s
  walking. The walk's stride is about a body height (`WALK.stride` 1.1, the run 1.6x that), so the
  cadence stays a walk's (~2.7 steps a second, ~3.7 running). The puppet's ground-speed cap (600) and
  the world's "a move over 40 in a frame is a jump" rule are now relative to the pace.
- **Stairs at a deck's end.** Held up at the very end of a deck by a stair that goes on the way he
  is going, the captain takes it without ↑ ↓: a run from the wheel carries on down to the waist.
- **Camera.** The follow camera leads him by his speed (k 40); shots and the zoom toggle settle faster.
- **Embed.** `?embed=1` hides only the decision card, its deck and the status counters; the game's
  controls stay in one row: language, sound, style, take the deck, the whole ship, the menu.
- **Rituals.** The squall's "all hands to the rigging" is back as before (the hand whose gate is red
  hauls with two idle hands; with the weather ritual off he goes down to the gun deck); the salvo
  fires from the bow aft and holds its guns shot; the recoil shows again; effects keep their size on
  screen in the wide shots; making port's fireworks burst over the masts; the class change pulls
  back to the whole ship. While the kraken is up the camera does not cut to close-ups far aft.

## Battle stations (v2d-14)

The captain on v2d-13: 「海怪開戰沒有各就各位的感覺」. When the fight is taken up: the bell, the horn and
the whistle, the banner "All hands! Battle stations!" (全員就戰鬥位置！ / 全员就战斗位置！), and every hand
runs (the captain's run pace) to a battle station of the layout (`G.battle`, `docs/modding.md`),
one each, the nearest his role allows: the captain to the bow rail, the firstmate beside him, the
reviewer to a nest, the hands to the bow's guns (at most about half of them), the forward rigging,
the shot in the hold or the lookout. The camera holds the scramble (hull and kraken) for 2.2 s or
until the first tap, and the kraken's first strike waits for it. At their posts gunners swab,
riggers haul, the shot is carried, lookouts watch; name tags are off in the fight. With reduced
motion they are placed at once. The fight over (or stepped out of), everyone goes back to the
workflow's stations. Muster times (headless, 60 fps): 7 hands ~3.5 s, 18 ~4.7 s, 24 ~5.3 s.

## Guns on the kraken, the RPG director (v2d-15)

The captain on v2d-14: 「戰鬥位置砲口沒有對到海怪，導演鏡頭希望能隨著戰鬥切換視角，像RPG game那樣」.

- **Guns trained on the kraken.** Each gun post (`G.battle`, post `gun`) names its gun. In the fight
  the manned guns are drawn side-on, trained forward: the carriage along the deck, the barrel on its
  trunnions at the kraken's eye, clamped to what a carriage allows (20° up, 15° down); the gunner at
  its breech. The shot, the flash and the smoke leave from the muzzle and land on the kraken. Why: a
  broadside gun cannot fire through the bow, but gun crews did train their guns forward with
  handspikes as far as the port allows, and the kraken's bulk off the bow fills that arc; a cutaway
  that showed the guns facing the reader could not read as the ship fighting it. It needs no new
  data, so every layout and mod gets it from its gun decks and its battle posts.
- **The director** (`BattleView.rpg`): between beats the fight's two-shot (the bow half and the
  kraken); the kraken's wind-up (its head and the section it aims at, 1.2 s); the hit on the hull
  (close, with a shake, 0.8 s); the crew's turn (the gunner who fires, then along the shot to the
  kraken's face, 1.45 s, at most every 4 s); reactions to a parry or a dodge (the captain ordering,
  the bow cheering, 0.95 s); the specials keep their own runs. No cut within 0.5 s of another, none
  away from a strike's telegraph, none over a special's run. Reduced motion: no RPG cuts, no punch-ins,
  no shake.
- **The embed's bars** (a panel under 520 high): small, in the top left corner, over the stern.
