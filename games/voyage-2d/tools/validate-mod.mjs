// Validate a mod file the way the game does before it loads one (docs/modding.md, "Validate"):
//   node tools/validate-mod.mjs mods/galleon.json [more.json ...]
// Prints "ok" and a summary, or every error with where it is. Exit code 1 on any refused file.
import { readFileSync } from "node:fs";
import { validateMod } from "../src/mod.js";
import { stringKeys, captionKeys } from "../src/hud.js";
import { specOf, deckGeometry } from "../src/deckplan.js";

const bake = JSON.parse(readFileSync(new URL("../bake/sprites.json", import.meta.url), "utf8"));
let bad = 0;
for (const f of process.argv.slice(2)) {
  const r = validateMod(readFileSync(f, "utf8"), { bake, stringKeys: stringKeys(), captionKeys: captionKeys() });
  if (!r.ok) {
    bad++;
    console.log(`✗ ${f}: refused (${r.errors.length} error${r.errors.length > 1 ? "s" : ""})`);
    for (const e of r.errors) console.log("   " + e);
    continue;
  }
  const m = r.mod, parts = [];
  for (const L of m.ships?.classes || []) {
    const G = deckGeometry(specOf(L)), n = (k) => G.stations.filter((s) => s.kind === k).length;
    parts.push(`ship "${L.id}" (up to ${L.cap} hands): ${Object.keys(G.decks).length} decks, ${G.rooms.length} rooms, ${G.links.length} links, ${G.guns.length} guns, stations: ${n("work")} work, ${n("rest")} rest, ${n("gate")} gate, ${n("review")} review`);
  }
  if (m.crew) parts.push(`crew: ${Object.keys(m.crew.palettes || {}).length} palettes, ${Object.values(m.crew.frames || {}).reduce((a, x) => a + Object.keys(x).length, 0)} frames, ${Object.keys(m.crew.props || {}).length} props`);
  if (m.strings) parts.push(`strings: ${Object.entries(m.strings).map(([l, x]) => `${l} ${Object.keys(x).length}`).join(", ")}`);
  if (m.captions) parts.push(`captions: ${Object.keys(m.captions).length}`);
  console.log(`✓ ${f}: ok — ${m.id}${parts.length ? "\n   " + parts.join("\n   ") : ""}`);
}
process.exit(bad ? 1 : 0);
