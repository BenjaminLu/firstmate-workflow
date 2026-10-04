// Prototype v2's easing curves (motion-spec "The engine"): named curves plus
// cubic-bezier(x1,y1,x2,y2) solved by Newton's method, 8 iterations. Pure.
export function cubicBezier(x1, y1, x2, y2) {
  const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
  const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  const X = (t) => ((ax * t + bx) * t + cx) * t;
  const dX = (t) => (3 * ax * t + 2 * bx) * t + cx;
  const Y = (t) => ((ay * t + by) * t + cy) * t;
  return (x) => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 8; i++) {
      const d = dX(t);
      if (Math.abs(d) < 1e-7) break;
      t -= (X(t) - x) / d;
      t = Math.min(1, Math.max(0, t));
    }
    return Y(t);
  };
}
export const Ease = {
  linear: (k) => k,
  inOutSine: (k) => 0.5 - 0.5 * Math.cos(Math.PI * k),
  outCubic: (k) => 1 - (1 - k) ** 3,
  inOutCubic: (k) => (k < 0.5 ? 4 * k * k * k : 1 - (-2 * k + 2) ** 3 / 2),
  // the spec's named beziers, by what they are used for
  pose: cubicBezier(0.2, 0.9, 0.3, 1.3), // captain's pose, a snap with overshoot
  arrive: cubicBezier(0.2, 0.8, 0.3, 1), // arrival jolt, rank-up, rise
  flight: cubicBezier(0.3, 0, 0.2, 1), // order handoff, count roll, chart glide
  approval: cubicBezier(0.2, 0.7, 0.2, 1),
  rejection: cubicBezier(0.6, 0, 0.4, 1),
  helm: cubicBezier(0.45, 0, 0.25, 1), // the helm's two turns
  bell: cubicBezier(0.3, 0.6, 0.4, 1),
  card: cubicBezier(0.2, 0.8, 0.2, 1),
  sink: cubicBezier(0.6, 0, 0.9, 0.5), // dragged down, arms dive
  strike: cubicBezier(0.5, 0, 0.3, 1),
  deck: cubicBezier(0.4, 0, 0.2, 1),
  smoke: cubicBezier(0.15, 0.6, 0.3, 1),
  boom: cubicBezier(0.15, 0.7, 0.3, 1),
};
// a keyframed value: keys [[t, value, easeIntoThisKey?], ...], t ascending
export function keyed(keys, t) {
  if (t <= keys[0][0]) return keys[0][1];
  for (let i = 1; i < keys.length; i++) {
    const [t1, b, e = Ease.inOutSine] = keys[i];
    if (t <= t1) {
      const [t0, a] = keys[i - 1];
      const k = e((t - t0) / Math.max(1e-6, t1 - t0));
      return Array.isArray(a) ? a.map((v, j) => v + (b[j] - v) * k) : a + (b - a) * k;
    }
  }
  return keys[keys.length - 1][1];
}
