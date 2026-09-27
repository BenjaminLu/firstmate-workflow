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
  - **The captain:** set `agent.manual = { vx }` to walk him. `linkAt(agent, way)` and `takeLink(id, way)` take the stair or ladder he stands at (way -1 up, +1 down).
  - **Agent state to render:** `deck`, `x`, `z`, `link` (`{ L, s, rev, from, to }`), `moving`, `dir` and `slipped` (the time of a slip, for a fade).

**What the 3D must supply:**

1. **Mapping and heights:** the ship-space-to-3D mapping above, and the deck heights from the model. The 3D hull must have the same interior levels, or a 3D model of them.
2. **Cameras:** the over-the-shoulder camera's collision against the hull and the obstacles. Use `hullOutline` for the sides, `decks[].y` and the obstacle boxes (the height of each kind is the 3D's own choice), plus the beam under each deck.
3. **Crew widths:** its own drawn widths for `planRest` (or the 2.5D's FOOT table scaled), and a footprint radius of about 26 × `crewScale`, the same as the 2.5D.
4. **Input to the Crowd:** WASD and mouse look become `manual.vx` along the ship's x. The 3D may later add a z input; `drive()` currently steers z itself.
5. **The mini-games in 3D form:** the rules can be reused from `src/minigame.js` (GAMES). Only the drawing is 2D.
6. **The same gates:** Live shows no prompt and no game, nothing writes, and the fight and endings close the deck.
