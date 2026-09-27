// The rig's proportions (the captain's note: the hull grew in the movement pass, the sails did
// not). Per class, the drawn sails carry the same share of the ship's side as before the
// movement pass (sail area / hull side area within 10 % of the pre-movement ship's, whose keel
// sat at RIG_OLD_BOTTOM), the rig grows with the hull rather than shrinking, and the shared
// model's numbers (masts, the crow's nest) are untouched.
import test from "node:test";
import assert from "node:assert/strict";
import { SHIP_CLASSES } from "../v3src/sim/deckplan.js";
import { RIG, RIG_OLD_BOTTOM, rigOf, sailArea, hullArea, rigTop } from "../src/ship.js";

test("every class's rig keeps its pre-movement share of the ship's side (sail area / hull area within 10 %)", () => {
  for (const S of SHIP_CLASSES) {
    const before = sailArea(S, S.masts, 1) / hullArea({ ...S, bottom: RIG_OLD_BOTTOM });
    const unscaled = sailArea(S, S.masts, 1) / hullArea(S);
    const { f, masts } = rigOf(S);
    const now = sailArea(S, masts, f) / hullArea(S);
    assert.ok(Math.abs(now / before - 1) <= 0.1, `${S.id}: ${now.toFixed(3)} vs ${before.toFixed(3)} before`);
    // without the fix the share had halved: the test would catch it
    assert.ok(unscaled / before < 0.6, `${S.id}: the deeper hull halved the share (${(unscaled / before).toFixed(2)})`);
    assert.ok(f > 1.2 && f < 1.8, `${S.id}: rig scale ${f}`);
    assert.equal(f, RIG[S.id]);
    // the rig stands taller than the hull is deep, as it did
    assert.ok(-rigTop(S) / S.bottom > 1.8, `${S.id}: masthead ${rigTop(S).toFixed(0)} over a keel at ${S.bottom}`);
    // the crow's nest and the mast positions stay the shared model's
    for (const [i, m] of masts.entries()) (assert.equal(m.nest, S.masts[i].nest), assert.equal(m.x, S.masts[i].x));
  }
});

// The crow's nest at the lower masthead (the captain's call: the nest read as sitting low on the
// scaled mast). In the drawn rig of every class with a nest: over the course yard (its bowl clear
// of the yard), under the topsail yard with room for a standing lookout (200 ship units, the
// crew's drawn height at the biggest crewScale) between his floor and that yard. The sloop has
// no nest; its lookout stands in the bow.
test("the crow's nest sits at the lower masthead at every class: over the course yard, a standing lookout's height under the topsail yard", () => {
  for (const S of SHIP_CLASSES) {
    const mi = Math.min(S.masts.length - 1, S.masts.length === 1 ? 0 : 1), m = rigOf(S).masts[mi];
    if (!S.masts[mi].nest) { assert.equal(S.id, "sloop", `${S.id}: only the sloop has no nest`); continue; }
    const ys = m.yards.map(([y]) => y), course = ys[ys.length - 1], topsail = ys[ys.length - 2];
    assert.ok(m.nest + 90 < course, `${S.id}: the nest's bowl (${m.nest}..${m.nest + 90}) over the course yard at ${course.toFixed(0)}`);
    assert.ok(m.nest - 200 > topsail, `${S.id}: a standing lookout at ${m.nest} under the topsail yard at ${topsail.toFixed(0)}`);
    // higher up the drawn mast than the fighting top it was (over half the course-to-topsail gap's lower third)
    assert.ok((course - m.nest) / (course - topsail) > 0.3, `${S.id}: the nest ${(((course - m.nest) / (course - topsail)) * 100).toFixed(0)} % of the way from the course yard to the topsail yard`);
  }
});
