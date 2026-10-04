// Prints each class's walkable ship: decks, links, stations, and whether every station, link
// end and deck is reachable from the helm.   node tools/deckcheck.mjs
import { deckGeometry, buildNav, findPath, staticFree } from "../src/deckplan.js";
import { CLASSES as SHIP_CLASSES } from "../src/layouts.js";
for (const S of SHIP_CLASSES) {
  const t0 = performance.now();
  const G = deckGeometry(S), t1 = performance.now(), nav = buildNav(G), t2 = performance.now();
  console.log("==", S.id, "decks", Object.values(G.decks).map((d) => `${d.id}[${d.x0.toFixed(0)},${d.x1.toFixed(0)}]@${d.y}`).join(" "), `geom ${(t1 - t0).toFixed(0)}ms nav ${(t2 - t1).toFixed(0)}ms`);
  console.log("   links", G.links.map((l) => `${l.id}:${l.kind}`).join(" "), "guns", G.guns.length, "/", S.guns * (S.levels.length - 1), "nodes", nav.nodes.length, "stations", G.stations.map((s) => s.kind[0]).join(""));
  const helm = G.stations.find((s) => s.kind === "helm");
  let tp = performance.now(), n = 0;
  for (const s of G.stations) {
    const ok = staticFree(G, s.deck, s.x, s.z, 36);
    const p = findPath(nav, helm, s); n++;
    if (!ok || !p) console.log("   BAD station", s.id, ok, !!p);
  }
  for (const l of G.links) for (const e of [l.a, l.b]) { n++; if (!staticFree(G, e.deck, e.x, e.z, 36) || !findPath(nav, helm, e)) console.log("   BAD link end", l.id, e); }
  console.log(`   ${n} paths, ${((performance.now() - tp) / n).toFixed(1)} ms each`);
}
