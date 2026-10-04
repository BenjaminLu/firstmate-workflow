// The rig's proportions on the big ships (src/layouts.js; the old test checked the scale factor
// the movement pass drew the rig at, which the big ships no longer need: their masts are sized in
// the layout). Per class: the sails carry a ship's share of her side (sail area / hull side area
// between 0.6 and 1.2), the masthead stands well over the hull (1.6 to 2.4 times her depth), and
// every crow's nest sits at the lower masthead: over the course yard (its bowl clear of the yard),
// with a standing lookout's room (200) under the topsail yard.
import test from "node:test";
import assert from "node:assert/strict";
import { CLASSES } from "../src/layouts.js";
import { sailBoxes, rigTop } from "../src/ship.js";

const polyArea = (P) => { let a = 0; for (let i = 0; i < P.length; i++) { const [x0, y0] = P[i], [x1, y1] = P[(i + 1) % P.length]; a += x0 * y1 - x1 * y0; } return Math.abs(a) / 2; };

test("every class carries a ship's share of sail, and her masts stand well over her hull", () => {
  for (const S of CLASSES) {
    const sail = sailBoxes(S).reduce((a, [, , half, h]) => a + 2 * half * h, 0), share = sail / polyArea(S.hull);
    assert.ok(share > 0.6 && share < 1.2, `${S.id}: sail / hull ${share.toFixed(2)}`);
    const top = Math.min(...S.hull.map((p) => p[1])), k = -rigTop(S) / (S.bottom - top);
    assert.ok(k > 1.6 && k < 2.4, `${S.id}: masthead ${rigTop(S)} over a hull ${S.bottom - top} deep (${k.toFixed(2)}x)`);
  }
});

test("every crow's nest sits at the lower masthead: over the course yard, a standing lookout's height under the topsail yard", () => {
  for (const S of CLASSES) {
    assert.ok(S.masts.some((m) => m.nest != null), `${S.id}: a nest`);
    for (const m of S.masts) {
      if (m.nest == null) continue;
      const ys = m.yards.map(([y]) => y), course = ys[ys.length - 1], topsail = ys[ys.length - 2];
      assert.ok(m.nest + 110 < course, `${S.id} mast ${m.i}: the nest's bowl (${m.nest}..${m.nest + 110}) over the course yard at ${course}`);
      assert.ok(m.nest - 200 > topsail, `${S.id} mast ${m.i}: a standing lookout at ${m.nest} under the topsail yard at ${topsail}`);
    }
  }
});
