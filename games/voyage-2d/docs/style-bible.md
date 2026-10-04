# v2.5 style bible: one look (P5 × shōnen manga)

This is the concept pass, for the captain to review before any rebuild. It adapts the game skills' art-direction rules to 2D:
- one identity in every surface;
- readable silhouettes at game scale;
- the HUD serves the play, not the other way round.

## Palette

| Role | Colours |
| --- | --- |
| Frame colours (UI, cut-ins, accents) | P5 red `#e60012`, ink `#0c0608`, paper white `#ffffff` |
| Crew accents | navy `#1f2a5c`, gold `#f2c040`, sailor blue `#2a5ad8`, reviewer green `#1f9a58`, robot orange `#e8742a` |
| Skin | light `#f6c49a`, shadow `#d88a68` |

- Shadows are a darker flat tone of the same hue. A shadow never becomes a gradient.
- Red is spent on meaning: the recommended choice, the waiting-on-you counter, the danger telegraph, the captain's coat lining and cockade, the firstmate's vest piping.

## Line

- Every character part, effect, panel and HUD element has a black ink outline.

| Element | Ink line at 1× |
| --- | --- |
| Silhouette | 6–7 px |
| Inner detail | 4–5 px |
| Panels | 10–16 px |

- Faces draw their brows as solid ink blades.

## Shading

- Two to three flat tones per part: base, one hard shadow shape (light from the upper left), and a highlight only on metal and gold.
- Screentone (halftone dots) is used on backgrounds and the dim layer, never on faces.

## Silhouette and proportion (浮誇)

- Heroes are 5–6 heads tall, no longer 2.5–3.
- **Captain:** the widest shoulders, the tallest hat and a coat that flares.
- **Firstmate:** the longest legs.
- **Workers:** squarer.
- **Robot:** a box.
- Each character is readable in black silhouette alone: tricorn, sailor cap with flying ribbons, boxy green cap, red box cap, spyglass, antenna.

## Faces

- Eyes are a white shape with a black block and no glint. This is the approved rule, kept.
- Brows are heavy and slanted.
- Grins show a band of teeth.
- **Captain:** the 八-shaped moustache hangs past the jaw over a full beard, with the cheek band and the ears.

## Motion

- **Poses:** they read as key art. Weight is on one leg, the arms break the silhouette, and the head tilts.
- **Timing:** fast in, hold on the strongest frame, ease out.
- **Secondary motion:** ribbons, coat tails, epaulette fringe and the neckerchief carry it.

## Effects and UI share the language

- **Effects:** inked, cel-shaded fire, smoke and water; SFX lettering; red/black impact frames; torn-panel cut-ins with ransom lettering.
- **HUD:**
  - It is stage-first, with one corner status cluster (merged, in flight, waiting on you), one prompt, sliding toasts and one menu button.
  - The board, the roster, the chart and the settings open behind the menu as a paused, red-dimmed overlay.
  - Decision cards appear only while a decision waits.
  - Touch targets are at least 44 px.
  - Every label exists in English, 繁體中文 and 简体中文, with a switch that is remembered. The default is EN.

## Production technique (recommended: hand-authored vector cutouts, variant C)

The cast is drawn in Canvas2D code on one shared skeleton, with a part per bone, driven by v3's motion keys.

| Option | Result | Cost |
| --- | --- | --- |
| A: re-bake v3 + ink and cel post | Same chibi proportions; still reads as 3D. | About half a day |
| B: re-bake with manga proportions + A | Longer legs and smaller heads, but the soft 3D faces and hands remain. | About 1 day |
| **C: vector cutouts** | The true manga look, bold proportions, resolution independent, no sprite payload (−2 MB). Poses come from the same skeleton. | About 4–5 days for 7 characters × 2 facings × 5 expressions + props + secondary motion, plus about 1 day to wire it to the motion tables |

**The trade-off with C:** the 2D cast becomes a second look to keep aligned with v3's 3D models. The shared-language rules above are what keep them related.
