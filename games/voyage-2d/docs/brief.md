# Firstmate Voyage v2.5: brief

**Promise.** Prototype v2's board and crew rituals, played on a 2D pirate stage by v3's crew, with a kraken fight that looks like a fighting-game super, on a budget a phone can carry.

**Target feeling.** Warm storybook sailing between events; loud, fast, readable anime spectacle in the fight; a key-art freeze frame at the end.

## Core loop contract

The captain gives orders (O), reads the board and answers the cards. The crew act each event out on deck: the order ritual, the PR hand-off, review approve or reject, the criteria ask, the squall and the clearing, the merge salvo, making port and promotions.

When a task stalls three rounds, the kraken takes it: one arm per held task. The fight loop runs every 1.5–2.5 s:

- The kraken **telegraphs** a strike (the arm coils and glows; the wind-up bar shows a blue dodge zone and a gold parry zone).
- The crew **dodge** (Space) late, or **parry** (J) in the last sliver. A parry opens a **riposte** window (J again) that crits the weak point.
- Parries, dodges and hits fill the **gauge**, which buys the specials:
  - **Broadside** (K, hold and release in the gold);
  - **Harpoon & Chain** (L, binds two arms);
  - **All Hands** (I, four volleys).

Failure costs hull. A broken hull stuns the crew for 2.4 s, then the carpenters patch her: the fight never ends in a game over, because the review can always go another round.

At 60 % and at 25 % grip the kraken casts **MAELSTROM**. It gathers for 3 s, then the swell comes (hold Space to brace). Then the Crushing Tide lands, with a gold parry window. A braced perfect parry turns it into the crew's **Counter Broadside**.

At zero grip only an approval wins. Enter plays the finisher: the reviewer's **APPROVED** stamp, then the captain's **golden gun**. The held tasks are approved on the board, and the ending is the crew's hero pose, with fireworks, light rays, the victory fanfare and a freeze-frame title.

## Encounter plan

- **Camera and framing.** A side-on stage with the ship on the left and the kraken off the bow. The camera can frame:
  - the whole fight;
  - the gun deck;
  - the eye;
  - the bow chaser;
  - the tidal wall.
- **Escalation.** It follows v3's review rounds (3–5):
  - the attack mix tightens;
  - the gaps shrink from 2.2 s to 1.45 s;
  - sweeps (unblockable, red telegraph) and ink (shoot it down with a broadside) join the slams and jabs.
- **Landmarks.** The ship's three masts and the main-course emblem, the kraken's eyes (the weak point is the left one), and the lighthouse island on the horizon.

## Pass 2 (2026-09-26): wide, tap-first, inked

- **Camera.** The default and battle frames show the whole ship (sails to keel), the sea, the sky and the kraken, after the banner's composition. Close-ups are brief cuts (at most 1.8 s for rituals, 2.4 s for specials) that return to the wide shot. Portrait keeps the middle three quarters of the frame.
- **One input.** A tap anywhere does what the single prompt says: parry, dodge, shoot the ink down, riposte, brace, parry the tide, or start the finisher. Between strikes, a tap fires at will.
  - The windows are generous (0.45–0.7 s).
  - A tap too soon only waits; there is no penalty.
  - One special button lights at a full gauge and fires the next special in rotation.
- **On the stage.** Tap the captain to give the order, the card he holds up to answer it, and the kraken to fight it. Keys stay as shortcuts.
- **Cast.** The firstmate is v3's young officer (navy vest, sailor cap), and stands beside the captain on the quarterdeck. The robot is worker-4, carrying the laptop.
- **Styles.**
  - "漫画": inked, cel-shaded effects, SFX lettering, black and white impact frames, manga panel cut-ins.
  - "P5": red, black and white, torn panels, ransom lettering and an all-out silhouette finisher.

  Toggle with the Style button or `?style=p5`.
