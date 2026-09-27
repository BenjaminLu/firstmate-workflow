# Chibi proportions — measured from the paintings

Measured in pixels on crops of `banner.png`, `kf2.png`, `kf3.png` and `kf5.png` (crops
in `shots/ref/`). "Head" means crown of the skull to chin, without the hat.

| measure | kf2 hammer sailor | kf2 robot | kf3 crew (avg) | banner busts | **target** |
|---|---|---|---|---|---|
| total height / head (no hat) | 3.1 | 3.2 | ~3.0 | — | **3.0** |
| hat height / head | 0.45 (sailor cap) | 0.25 (antenna) | 0.45 | tricorn 0.55 | cap **0.45**, tricorn **0.5** |
| hat width / head width | 1.35 | — | 1.3 | tricorn 1.6 | cap **1.3**, tricorn **1.6** |
| shoulder span (outer arms) / head width | 1.35 | 1.2 | 1.3 | 1.3 | **1.3** |
| torso, neck base to crotch / head | 0.95 | 1.3 | 1.0 | — | **0.96** |
| leg, crotch to sole / head | 1.2 | 0.85 | ~1.0 | — | **0.96** |
| arm, shoulder to fingertip / head | 1.25 | 1.1 | 1.2 | 1.2 | **1.2** (fingertips reach mid-thigh) |
| neck / head | 0.08 | 0.1 | visible | visible | **0.09** |
| eye height / head | 0.20 | (screen eyes 0.22) | 0.2 | 0.21 | **0.21** |
| eye width / head width | 0.14 | — | 0.13 | 0.14 | **0.16** |
| eye centre above chin / head | 0.47 | — | 0.48 | 0.46 | **0.47** |
| gap between eyes / head width | 0.18 | — | 0.2 | 0.18 | **0.16** |
| mouth centre above chin / head | 0.18 | — | 0.2 | 0.2 | **0.16** |
| hair beyond skull (sides/back) / head | 0.10–0.15 | — | 0.12 | 0.12 | **0.1** (1–2 head voxels + tufts) |
| fist width / head width | 0.3 | 0.3 | 0.3 | 0.3 | **0.27** |

## Silhouette notes

- Heads are rounded, voxel-stepped ovals: flat-ish face, rounded cheeks, narrower jaw
  and chin, dome on top. They are not cubes.
- Visible neck, and square shoulders wider than the head.
- Arms reach mid-thigh. Fists have a separate thumb, and pointing hands have a real
  index finger.
- Legs end in chunky boots with a toe cap. Sailors wear bell-bottom navy trousers.
- Eyes are big and dark, with one large and one small white highlight and a thick
  upper lid line. Brows are thick and dark. The nose is a single pixel. Mouths are
  large open D shapes with teeth and tongue.
- Hair has volume: jagged bangs in clumps, sideburns, tufts sticking out under the
  hats. The captain's hair is long and curly to the shoulders.
- Sailor cap: a white box widening toward the top, navy band, navy anchor badge on the
  front, navy ribbon tails.
- Tricorn: black, gold braid on the upturned rim, front point over the face.
- Reviewer's bandana: a green boxy wrap knotted at the side, with two trailing tails
  sticking out. Round black glasses frame white eyes with dark pupils.

## Implementation (chibi.js)

- Body voxels are `CS = 0.05`. Head, face, hair, hat and hands are `HS = 0.03`, which
  gives the face 1.7× the resolution.
- Head: 19 × 19 × 17 HS (0.57 wide × 0.57 tall). Legs: 11 CS (0.55). Torso: 11 CS
  (0.55) plus neck. Total: 1.72 = **3.0 heads**.
- Shoulder span: 15 CS (0.75) = **1.32 head widths**. Upper arm 5 CS, forearm 5 CS,
  hand 5 HS, so the arm is 0.65 = **1.14 heads**, reaching mid-thigh.
