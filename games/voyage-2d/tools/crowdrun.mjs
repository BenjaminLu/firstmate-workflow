// A long crowd run with no renderer: every class, hands walking to seeded stations and homes,
// the ship changing class; prints any broken rule and any walk that never ends.
import { SHIP_CLASSES, deckGeometry, Crowd, fileSegments, restFile } from "../v3src/sim/deckplan.js";
let seed = 7;
const rnd = () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
const T = +(process.argv[2] || 120);
for (const S of SHIP_CLASSES) {
  const G = deckGeometry(S), C = new Crowd(G);
  const spots = G.stations.filter((s) => s.kind !== "helm");
  // plus resting spots along every deck's rest lane
  for (const file of new Set(Object.keys(G.decks).map((d) => restFile(G, d)))) for (const [a, b, dk] of fileSegments(G, file, 30)) for (let x = a; x <= b; x += 170) spots.push({ id: `${dk}@${x.toFixed(0)}`, deck: dk, x, z: G.decks[dk].rest });
  const n = S.cap;
  for (let i = 0; i < n; i++) {
    const s = i === 0 ? G.stations[0] : spots[i % spots.length];
    const a = C.add("c" + String(i).padStart(2, "0"), { deck: s.deck, x: s.x, z: s.z, r: 26 * S.crewScale, pri: i });
    a.spot = s.id;
  }
  let bad = 0, arrivals = 0, sent = 0, stuck = 0;
  const since = new Map();
  const t0 = performance.now();
  for (let t = 0; t < T; t += 1 / 30) {
    for (const a of C.order()) {
      if (!a.goal && !a.link && rnd() < 0.004) {
        const taken = new Set(C.order().map((b) => b.goal && b.goal.id).filter(Boolean));
        const here = new Set(C.order().filter((b) => !b.goal).map((b) => b.spot));
        const used = spots.filter((s) => taken.has(s.id) || here.has(s.id));
        const free = spots.filter((s) => !used.some((u) => u.deck === s.deck && Math.abs(u.x - s.x) < 70));
        if (!free.length) continue;
        const s = free[Math.floor(rnd() * free.length)];
        a.spot = s.id;
        C.goTo(a.id, { deck: s.deck, x: s.x, z: s.z, id: s.id }, () => arrivals++);
        sent++;
        since.set(a.id, t);
      }
      if (a.moving || !a.goal) since.set(a.id, t);
      if (a.goal && t - (since.get(a.id) ?? t) > +(process.env.STUCK || 15)) {
        const near = C.order().filter((b) => b !== a && b.deck === a.deck && !b.link && Math.hypot(b.x - a.x, b.z - a.z) < a.r + b.r + 20).map((b) => `${b.id}@${b.x.toFixed(0)},${b.z.toFixed(0)}${b.goal ? "→" + b.goal.deck + ":" + b.goal.x.toFixed(0) : " rest"} w${b.wait.toFixed(1)}`);
        const s0 = a.plan?.[0];
        if (process.env.V) console.log("  stuck", S.id, a.id, a.link ? `ON ${a.link.L.id} s=${a.link.s.toFixed(0)}/${a.link.L.len.toFixed(0)}` : "", "hold", (a.holdUntil - C.t).toFixed(1), "yield", a.yieldFrom?.id, a.deck, a.x.toFixed(0), a.z.toFixed(0), "->", a.goal.deck, a.goal.x.toFixed(0), "next", s0 ? (s0.link ? "link " + s0.link + (C.linkBusy[s0.link] ? " busy:" + C.linkBusy[s0.link] : "") : "walk " + s0.walk.map((w) => w.map((v) => v.toFixed(0)).join(",")).join(" ")) : "none", "| near", near.join("; "), "| busy", JSON.stringify(C.linkBusy), (() => { const need = a.plan?.find((st) => st.link)?.link; const hb = C.get(C.linkBusy[need] || ""); return hb ? `holder of ${need}: ${hb.id} goal ${hb.goal?.deck}:${hb.goal?.x?.toFixed(0)} plan ${JSON.stringify(hb.plan?.slice(0,2))} ${hb.deck} ${hb.x.toFixed(0)},${hb.z.toFixed(0)} link:${hb.link?.L.id} s=${hb.link?.s?.toFixed(0)} w${hb.wait.toFixed(1)}` : ""; })());
        stuck++;
        if (process.env.SNAP && S.id === process.env.SNAP) {
          const need = a.plan?.find((st) => st.link)?.link, hb = C.get(C.linkBusy[need] || "");
          if (hb) {
            console.log("   SNAP holder", hb.id, hb.deck, hb.x.toFixed(1), hb.z.toFixed(1), "wait", hb.wait.toFixed(2), "yieldT", (hb.yieldUntil - C.t).toFixed(2), "moving", hb.moving, "plan", JSON.stringify(hb.plan));
            for (const b of C.order()) if (b.deck === hb.deck && !b.link && Math.hypot(b.x - hb.x, b.z - hb.z) < 200) console.log("     agent", b.id, b.x.toFixed(0), b.z.toFixed(0), b.goal ? "goal " + b.goal.deck + ":" + b.goal.x.toFixed(0) : "rest", "w", b.wait.toFixed(1), "r", b.r.toFixed(1));
            for (const o of G.obstacles) if (o.deck === hb.deck && o.x1 > hb.x - 200 && o.x0 < hb.x + 200) console.log("     obst", o.kind, o.x0.toFixed(0), o.x1.toFixed(0), o.z0, o.z1);
            process.exit(0);
          }
        }
        since.set(a.id, t);
      }
    }
    C.step(1 / 30);
    const v = C.violations();
    if (v.length && bad++ < 5) console.log("  ", S.id, t.toFixed(2), v.slice(0, 3));
  }
  console.log(S.id, `${T}s: ${sent} walks, ${arrivals} arrived, ${stuck} stuck, ${bad} bad frames, ${C.slips || 0} slips, ${(performance.now() - t0).toFixed(0)} ms`);
}
