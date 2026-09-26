# Sound spec: the emotional layer (T-086)

Every sound the board can make, what makes it, and what it means. Two rules
the captain settled on 2026-09-24:

1. **Every sound is off until the captain turns it on**, the attacks' warnings
   and the decision cards' sounds with the rest. Two switches, both
   off on a first visit, both in the floating controls at the lower right,
   under "On the board" (captain, 2026-09-24: the option controls, sound among
   them, float in one panel that hides and shows with one control): *Sound
   effects* (every one-shot below, and v2's bell, whistle and guns) and *The
   ambient sea*. The prototype's `S` key is the same *Sound effects* switch.
   T-070's prototype started with sound on; T-086 turns that default off.
2. **Every sound answers a real event**, like the motion it goes with. The
   ambient sea is the one layer that plays for its own sake, and it follows the
   weather and the hour the board already shows.

Everything is synthesised with the Web Audio API in the page: no audio files,
no network. `Snd` (section 14.8 of the script) holds the new one-shots; `Audio`
(section 10, T-070) holds the bell, the whistle and the cannon; `Amb` holds the
ambient sea in its own audio context, so turning it off never cuts an effect.

## One-shots

Frequencies in Hz, times in seconds from the event.

| Sound | Made of | Length | Level (peak gain) | Trigger | Encodes |
|---|---|---|---|---|---|
| Bell (T-070) | five sine partials of 523 (×1, ×2, ×2.76, ×5.4, ×0.5), exponential decay | 2.6 | 0.16 | a merge; an order; making port rings it twice, 0.42 apart | a bell rung for something done |
| Bosun's whistle (T-070) | a sine rising 1500 to 2300, a 14 Hz trill, falling to 1400 | 1.1 | 0.08 | an order; a first-pass salute; the captain's order in a battle | all hands, attention |
| Cannon (T-070) | low-passed noise (520) with a 55 Hz thump | 0.34 a report | 0.16 to 0.6 | a merge's salvo | a gun fired |
| Explosion | noise through a low-pass closing from `1600 + 300w` to 160 Hz, over a drum falling to `70 − 6w` Hz (*w* the blow's weight, 1 to 4, as in the motion spec) | `0.35 + 0.18w` | noise `min(0.5, 0.12 + 0.08w)`, drum `min(0.5, 0.16 + 0.07w)` | every blow on the kraken's head (a confirmed combat action, a push in battle, a skill, the crew's guns), a slam on the deck, a gun's muzzle in the captain's order | a hit, as heavy as it sounds |
| Splash | noise band-passed from 2400 falling to 500 Hz, over a 58 Hz drum | `0.7 + 0.15w` | `0.08 + 0.04w`; drum `0.12 + 0.04w` | a dodged slam lands in the sea; the arm going under at a victory | a miss, or the kraken going down |
| Hammer | three triangle strokes, 900 falling to 420 Hz, 0.16 apart | 0.42 | 0.12 | the repair skill | the deck mended |
| Victory fanfare | a small brass section: two sawtooths detuned ±6 cents through a low-pass opening 700 to 2600 and closing to 1300. A rising call G4 C5 E5, G5 held (0 to 1.15), an answer E5 G5 (1.2 to 2.3), a held C major chord C5 E5 G5 C6 (2.35 to 4.05); a drum stroke (98 falling from 157) at 0 and a deeper one (82) at 2.35 | about 4 | 0.07 a voice in the call, 0.05 a voice in the chord; drum 0.3 and 0.4 | the review approves a task in battle, **once per approval** (the key is task and round; the same approval never plays it twice). The playground's *Victory* is not an approval, so it plays every time it is triggered | the battle is won |
| Clearing triad | the fanfare's brass, C5 E5 G5, 0.14 apart, 0.5 each | 0.8 | 0.05 | a red check turns green | the weather broke |
| Fireworks crackle | high-passed noise (2500), fast decay | 0.5 a burst | 0.12 | each of the three bursts when making port | a port reached |
| The kraken strikes | a 60 Hz drum and a band-passed noise crack (1800) 20 ms after | 0.9 | 0.45 drum, 0.18 crack | a rejected round in battle; an unevaded slam in the game | we were hit |
| Thunder | low-passed noise (180), fast rise, long tail | 2.1 | 0.5 falling to 0.12 at 0.5 s | a red check in battle | the storm thickened |
| An attack's warning | a slam (and a feint, which pretends to be one): a sawtooth horn 98 falling to 82 Hz through a 900 Hz low-pass, 0.55 s. A jab: two square ticks, 620 falling to 540 Hz, 0.06 s each, 0.09 apart. A combo: a triangle pair rising 247 to 294 Hz for the first hit, 330 to 392 for the second, 0.16 s each | 0.06 to 0.55 | 0.12 horn, 0.07 ticks, 0.08 pair | each attack's wind-up starts, in the game | what is coming: each pattern sounds its own |
| Full sail | noise band-passed (Q 1.1) sweeping 500 to 2200 Hz | 0.42 | 0.09 (0.054 for a too-early dodge) | a dodge | the ship turned away |
| A perfect dodge | a sine chime at 1046 Hz with a 2.76× partial, a whole tone higher for each perfect dodge in a row (to four steps), over the full-sail rush | 0.9 | 0.08, partial 0.03 | a dodge in the perfect zone | perfect; the combo climbing |
| A critical hit's clang | three triangle partials, 1780, 2310 and 3120 Hz, each falling an octave | 0.7 | 0.06, 0.04, 0.03 | the counter on the weak point, over its explosion | the weak point struck |
| A card dealt | high-passed noise (3200), a 4 ms attack | 0.12 | 0.07 | a decision card arrives while the page is open | a new call on the table |
| A card played | high-passed noise (2400) | 0.09 | 0.05 | an option picked from the hand | the option is on the table |
| The seal | a 72 Hz drum under high-passed noise (1400) | 0.9 | 0.28 drum, 0.08 noise | a decision confirmed | it is decided |

No one-shot plays on a timer. The battle game's own guns use the explosion at
weight 1, at the game's clock, and only while the captain plays along; the
attacks' warnings sound only while the captain plays along, at the game's own
turn of attacks.

## The ambient sea

Off until the captain turns it on. It fades in over 1.5 s and out over about
0.75 s (a 0.25 s time constant). It reads the same springs the scene is drawn
from every 120 ms, so the sound and the picture never disagree.

| Layer | Made of | Follows | Level |
|---|---|---|---|
| Sea | brown noise (a 3 s loop of noise through a one-pole filter), low-passed at `380 + 36 × swell` Hz | the swell: the level breathes with the ship's own heave, `0.035 + 0.01 × swell × (0.55 + 0.45 × the heave's phase)` | 0.035 to 0.16 |
| Wind | white noise band-passed (Q 1.4) at `700 + 500 × speed + 500 × squall` Hz | way and weather: calm is almost silent, a breeze rises with the live runs, a squall howls | `0.004 + 0.02 × speed + 0.05 × squall` |
| Rigging | a sawtooth creak, 150 falling to 118 Hz through a narrow band-pass at 420 | one creak at each crest of the swell, so a calm sea creaks slowly and a squall often | 0.03 |
| Gulls | three short triangle-wave cries falling from about 1900 to 1250 Hz, 0.24 apart | at every third crest, **only at dawn and by day, and never in a squall**; none at dusk or night | 0.018 |

Nothing in it is random: the noise loops are seeded, and creaks and gulls fall
on the swell's crests. With motion off the swell's phase is taken from the
clock at the same period, so the sea still breathes.

## What the live board needs

- the two switches stored with the captain's other board preferences, both
  false by default; a board that has never been told otherwise is silent;
- the victory fanfare keyed by the approval event's id, so a reconnect or a
  replayed event does not play it again;
- an audio context created only on the captain's own click (the switch), which
  is also what browsers require.
