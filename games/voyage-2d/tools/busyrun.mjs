// The unit test's busy crowd run, with a snapshot of the first long stall.   node tools/busyrun.mjs [secs] [seed] [order]
import { SHIP_CLASSES, deckGeometry, Crowd, fileSegments, restFile } from "../v3src/sim/deckplan.js";
function busyRun(order, secs, seed) {
  let s = seed;
  const rnd = () => ((s = (s * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
  const spotsOf = (G) => {
    const out = G.stations.filter((q) => q.kind !== "helm").map((q) => ({ id: q.id, deck: q.deck, x: q.x, z: q.z }));
    for (const file of new Set(Object.keys(G.decks).map((d) => restFile(G, d)))) for (const [a, b, dk] of fileSegments(G, file, 30)) for (let x = a; x <= b; x += 170) out.push({ id: `${dk}@${x.toFixed(0)}`, deck: dk, x, z: G.decks[dk].rest });
    return out;
  };
  let S = SHIP_CLASSES[order[0]], G = deckGeometry(S), C = new Crowd(G), spots = spotsOf(G);
  // each class carries its own full crew: hands come aboard and go ashore as it changes
  const crew = () => {
    const n = S.cap;
    for (const a of C.order()) if (+a.id.slice(1) >= n) C.remove(a.id);
    for (let i = 0; i < n; i++) if (!C.get("c" + String(i).padStart(2, "0"))) { const q = spots[(i * 5) % spots.length]; C.add("c" + String(i).padStart(2, "0"), { deck: q.deck, x: q.x, z: q.z, r: 26 * S.crewScale, pri: i }); }
  };
  crew();
  const out = { bad: [], walks: 0, arrived: 0, stalls: [], classes: [S.id] };
  const still = new Map();
  const per = secs / order.length;
  for (let t = 0, h = 1 / 60, phase = 0; t < secs; t += h) {
    if (t >= (phase + 1) * per) {
      phase++;
      S = SHIP_CLASSES[order[phase]];
      G = deckGeometry(S);
      for (const a of C.agents.values()) a.r = 26 * S.crewScale;
      C.setGeometry(G);
      spots = spotsOf(G);
      crew();
      out.classes.push(S.id);
    }
    for (const a of C.order()) {
      if (!a.goal && !a.link && rnd() < 0.002) {
        const used = C.order().map((b) => b.goal || (!b.link && { deck: b.deck, x: b.x })).filter(Boolean);
        const free = spots.filter((q) => !used.some((u) => u.deck === q.deck && Math.abs(u.x - q.x) < 70));
        if (free.length) { const q = free[Math.floor(rnd() * free.length)]; C.goTo(a.id, { deck: q.deck, x: q.x, z: q.z }, () => out.arrived++); out.walks++; }
      }
      if (a.moving || !a.goal) still.set(a.id, t);
      else if (t - (still.get(a.id) ?? t) > +(process.env.STALL || 30)) {
        out.stalls.push(`${S.id} ${a.id} at ${t.toFixed(1)}`); still.set(a.id, t);
        if (!out.snap) {
          out.snap = true;
          const need = a.plan?.find((st) => st.link)?.link;
          console.log("STALL", S.id, a.id, a.deck, a.x.toFixed(0), a.z.toFixed(0), "wait", a.wait.toFixed(1), "yield", a.yieldFrom?.id, "plan", JSON.stringify(a.plan?.slice(0, 2)), "goal", JSON.stringify(a.goal), "need", need, "holder", C.linkBusy[need], "grant", C.grant?.[need]);
          const hb = C.get(C.linkBusy[need] || "");
          if (hb?.link) { const e = hb.link.to; for (const b of C.order()) { if (b === hb) continue; const f = C.footOn(b, e.deck); if (f && Math.hypot(f[0] - e.x, f[1] - e.z) < 80) console.log("  ON LANDING", b.id, b.deck, b.link?.L.id, f.map((v) => v.toFixed(0)).join(","), b.goal ? "goal" : "rest", "yield", b.yieldFrom?.id, "wait", b.wait.toFixed(1), "free-for-holder", C.free(e.deck, e.x, e.z, hb.r, hb)); } console.log("  landing free?", C.free(e.deck, e.x, e.z, hb.r, hb), "stall", hb.link.stall?.toFixed(1)); }
          if (hb) console.log("  holder", hb.id, hb.deck, hb.x.toFixed(0), hb.z.toFixed(0), "link", hb.link?.L.id, hb.link?.s?.toFixed(0), "wait", hb.wait.toFixed(1), "plan", JSON.stringify(hb.plan?.slice(0, 2)));
          for (const b of C.order()) if (b !== a && b.deck === a.deck && !b.link && Math.hypot(b.x - a.x, b.z - a.z) < 160) console.log("  near", b.id, b.x.toFixed(0), b.z.toFixed(0), b.goal ? "goal " + b.goal.deck + ":" + b.goal.x.toFixed(0) : "rest", "wait", b.wait.toFixed(1), "yield", b.yieldFrom?.id, "plan", JSON.stringify(b.plan?.[0])?.slice(0, 90));
          for (const o of G.obstacles) if (o.deck === a.deck && o.x1 > a.x - 160 && o.x0 < a.x + 160) console.log("  obst", o.kind, o.x0.toFixed(0), o.x1.toFixed(0), o.z0, o.z1);
          for (const l of G.links) for (const e of [l.a, l.b]) if (e.deck === a.deck && Math.abs(e.x - a.x) < 200) console.log("  linkend", l.id, e.x.toFixed(0), e.z, "busy", C.linkBusy[l.id]);
        }
      }
    }
    C.tick(h);
    const v = C.violations();
    if (v.length && out.bad.length < 5) out.bad.push(`${S.id} ${t.toFixed(2)}s: ${v[0]}`);
  }
  out.slips = C.slips || 0;
  out.final = C.order().map((a) => `${a.id}:${a.deck}:${a.x.toFixed(3)}:${a.z.toFixed(3)}`).join("|");
  return out;
}


const [secs = 480, seed = 7, order = "0,1,2,3,2,0,3,1"] = process.argv.slice(2);
const r = busyRun(order.split(",").map(Number), +secs, +seed);
console.log(JSON.stringify({ walks: r.walks, arrived: r.arrived, stalls: r.stalls, bad: r.bad, slips: r.slips }));
