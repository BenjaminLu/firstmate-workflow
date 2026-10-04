# v2.5 scorecard (threejs-aaa-graphics-builder rubric, adapted to 2D)

- **Scale:** 0 placeholder, 1 basic styled, 2 premium stylized, 3 showcase.
- **Before:** not captured. v2.5 is a new build; prototype v2 was never scored on this rubric.
- **Scored on:** the active-play captures in `shots/` (desktop 1440×900, iPhone 13 emulation) and the canvas inspector (`artifacts/inspect/`).

## Genre equivalents

| Rubric category | What it means here |
| --- | --- |
| Hero | the crew puppets |
| Enemies | the kraken |
| Interactables | the board, the cards and the battle pad |
| World | the sea, the sky and the ship |

## Scores

| Category | Score | Evidence |
| --- | --- | --- |
| Art direction | 2.5 | One identity across the storybook ship, v3's crew, anime cut-ins and v2's parchment UI. The painted ship and the baked 3D-look crew are two techniques, but the palette and the rim lights tie them together. |
| Hero (crew) | 2.5 | v3's approved models, baked per part and per expression and rebuilt as puppets. They are driven by v3's own motion keys through spring joints, with squash and stretch and danglers. Limits: legs are one piece (no knee bend), hand shapes swap, and limbs foreshorten rather than turn. |
| Enemies (kraken) | 2 | A menacing mantle with rim and wet highlights, slit eyes, a beak and silhouette arms. Telegraphs are colour-coded: gold means parryable, red means unblockable. Arm motion is a coil-and-lash only; there are no grabs or sweeps along the deck. |
| Interactables | 2 | v2's board, lanes, decision cards, tally and chart are kept as they were. The battle pad has cost labels and hold hints. |
| World | 2 | Layers with parallax: sky, clouds, gulls, islands, far sea, mid swell, hull, near swell and foam. There are also the whirlpool and the tidal wall. Only one ship, and no other traffic. |
| Materials | 2 | Painted gradients, planking, trim and wear on the ship; baked lighting on the crew; wet highlights on the kraken. |
| Lighting | 2 | Weather grades (squall, maelstrom, night), crepuscular rays, eye glow, hero light rays and the vignette. The crew sprites keep their baked light (no relight). |
| VFX / motion | 3 | Every special has a cut-in, impact frames (inverted, white or black), hit-stop, shake, a punch-in, a radial zoom blur, motion trails, debris, water columns, rings and damage numbers. There are also fireworks with sea reflections and the curling tidal wall. |
| UI / HUD | 2 | Fighting-game telegraph bars, grip thresholds marked on the bar, a gauge with cost ticks, a combo counter and prompts. The phone layout works in portrait but is dense. |
| Performance | 3 | Measured over 9 s of auto-played battle: desktop p50 1.2 ms and p95 1.9 ms; phone (4× CPU throttle) p50 4.1 ms and p95 4.9–6.3 ms, against a 16.7 ms budget. Ready in 46–81 ms (desktop) and 340 ms (phone). |
| **Average** | **2.3** | Every category is at 2 or above. |
| **Cool** (added row) | 2.5 | Judged against fighting-game supers, anime cut-ins and pirate key art. The cut-ins, impact frames and hero ending read as key art in stills. The routine tentacle strikes read small in the wide fight shot. |

## Automatic failures

None stand. The inspector's `battle` capture measured:

- colour entropy 6.68 bits;
- edge density 0.306;
- contrast 203;
- dominant colour share 0.08.

The mobile capture is similar.

## Performance caveat

Frame cost is JS plus canvas command time from `performance.now()` in the loop. GPU raster time is not in it. The fps counter held at 60 in every run, including the throttled phone.

## Pass 2 re-score (2026-09-26)

| Category | Pass 1 | Pass 2 | Evidence |
| --- | --- | --- | --- |
| Art direction | 2.5 | 2.5 | Inked world effects, a yōkai kraken, manga or P5 overlays. |
| Hero (crew) | 2.5 | 2.5 | Knees bend (two-segment legs), hands crossfade, scene relight. The crew read small in the wide shot, so name pennants were added. |
| Enemies | 2 | 2.5 | Cel-shaded kraken with ink outlines, sharp glowing eyes, sumi-e arms, smear frames, a demonic aura and ukiyo-e crests. |
| Interactables | 2 | 2.5 | Tap the captain, the card and the kraken, one prompt, one special button. |
| World | 2 | 2 | Unchanged, wider framing. |
| Materials | 2 | 2 | Unchanged. |
| Lighting | 2 | 2 | The crew are now relit by squall, maelstrom and night, with a hero rim. |
| VFX / motion | 3 | 3 | SFX lettering, brush slash, mono impact frames. |
| UI / HUD | 2 | 2.5 | The approach-ring prompt, a phone layout without the action bar. |
| Performance | 3 | 3 | Desktop p95 1.7–8.2 ms; phone (4× throttle) p95 5.8–6.8 ms. The first cut-in has a one-off 89 ms frame (font raster). |
| **Average** | **2.3** | **2.45** | |
| **Cool** | 2.5 | 2.5 | The finisher and cut-ins read as key art in both styles. Routine strikes are bigger but still read small in the wide shot on phones. |
