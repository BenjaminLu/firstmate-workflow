// Mods (src/mod.js), without a browser: the bundled examples validate; the validator is strict
// (an unknown key, a wrong type, an out-of-range number, markup in a text, a remote image, a
// room nobody can reach: each refused with a message naming where it is); the classes a mod makes;
// and nothing in the loader can run a mod or reach the network.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { validateMod, modLayouts, MOD_FORMAT } from "../src/mod.js";
import { stringKeys, captionKeys } from "../src/hud.js";
import { LAYOUTS } from "../src/layouts.js";
import { specOf, deckGeometry } from "../src/deckplan.js";

const ROOT = new URL("..", import.meta.url).pathname;
const bake = JSON.parse(readFileSync(`${ROOT}bake/sprites.json`, "utf8"));
const OPT = { bake, stringKeys: stringKeys(), captionKeys: captionKeys() };
const read = (f) => readFileSync(`${ROOT}mods/${f}`, "utf8");
const galleon = () => JSON.parse(read("galleon.json"));
const errs = (m) => validateMod(typeof m === "string" ? m : JSON.stringify(m), OPT).errors;

test("the bundled examples validate: the galleon (a ship with an extra deck) and the crimson crew (a skin)", () => {
  for (const f of ["galleon.json", "crimson-crew.json"]) {
    const r = validateMod(read(f), OPT);
    assert.deepEqual(r.errors, [], f);
    assert.equal(r.mod.format, MOD_FORMAT);
  }
  const L = galleon().ships.classes[0], G = deckGeometry(specOf(L));
  // an extra deck: a three-tier stern castle, two gun decks and an orlop over the hold
  assert.ok(Object.values(G.decks).filter((d) => d.kind !== "nest").length > Object.values(deckGeometry(specOf(LAYOUTS[3])).decks).filter((d) => d.kind !== "nest").length, "more decks than the ship of the line");
  assert.equal(G.stations.filter((s) => s.kind === "helm").length, 1);
});

test("strict: an unknown key anywhere is refused, with its path and the keys allowed", () => {
  const m = galleon();
  m.colour = "red";
  m.ships.classes[0].rooms[3].colour = "blue";
  const e = errs(m);
  assert.ok(e.some((x) => x.startsWith('mod: unknown key "colour"')), e.join("\n"));
  assert.ok(e.some((x) => x.startsWith('mod.ships.classes[0].rooms[3]: unknown key "colour" (allowed: id, kind, deck')), e.join("\n"));
});

test("strict: wrong types, bad values and out-of-range numbers are refused, each with its place", () => {
  const m = galleon(), L = m.ships.classes[0];
  L.cap = "24";
  L.hull.keel = 99999;
  L.rooms[0].kind = "ballroom";
  L.links[0].dir = 2;
  L.decks[1].y = "low";
  const e = errs(m);
  for (const want of [
    'mod.ships.classes[0].cap: expected a number, got the text "24"',
    "mod.ships.classes[0].hull.keel: 99999 is out of range (600 to 8000)",
    'mod.ships.classes[0].rooms[0].kind: expected one of "helm", "cabin"',
    "mod.ships.classes[0].links[0].dir: expected one of 1, -1, got number 2",
    'mod.ships.classes[0].decks[1].y: expected a number, got the text "low"',
  ]) assert.ok(e.some((x) => x.startsWith(want)), `${want}\n in:\n${e.join("\n")}`);
  assert.deepEqual(errs({ format: "voyage-mod/2", id: "x", name: "X" }), ['mod.format: expected "voyage-mod/1", got "voyage-mod/2"']);
  assert.match(errs("{ not json")[0], /^not JSON: /);
  assert.deepEqual(errs([]), ["mod: expected an object, got a list"]);
});

test("data only: no markup in a text, no image that is not a data: URI, no key that is not the game's", () => {
  const m = JSON.parse(read("crimson-crew.json"));
  m.name = { en: "<img src=x onerror=alert(1)>" };
  m.crew.props.placard = "https://example.com/placard.png";
  m.crew.props.flag = "javascript:alert(1)";
  m.strings.en.welcome = "Welcome <b>aboard</b>";
  m.strings.en.noSuchKey = "hi";
  m.captions["Not a phrase the game says"] = { en: "x" };
  m.crew.palettes.kraken = [{ from: "#000000", to: "#ffffff" }];
  m.crew.frames = { captain: { "q.parts.nose": "data:image/png;base64,AAAA" } };
  const e = errs(m);
  for (const want of [
    "mod.name.en: may not contain < or >",
    "mod.crew.props.placard: expected an image as a data: URI",
    "mod.crew.props.flag: expected an image as a data: URI",
    "mod.strings.en.welcome: may not contain < or >",
    'mod.strings.en: unknown key "noSuchKey"',
    'mod.captions: unknown key "Not a phrase the game says"',
    'mod.crew.palettes: unknown key "kraken"',
    'mod.crew.frames.captain["q.parts.nose"]: no frame "q.parts.nose"',
  ]) assert.ok(e.some((x) => x.startsWith(want)), `${want}\n in:\n${e.join("\n")}`);
  // a key that would reach an object's prototype is only an unknown key
  assert.ok(errs('{"format":"voyage-mod/1","id":"p","name":"P","__proto__":{"x":1}}').some((x) => x.startsWith('mod: unknown key "__proto__"')));
});

test("a ship must be walkable: a room walled off from the helm, a link into a wall, a missing helm are refused", () => {
  const m = galleon(), L = m.ships.classes[0];
  // a solid bulkhead where the steerage opens on the waist: the steerage and the officers' berths
  // aft of it have no other way in (the bosun's store, walled off the same way, still has its ladder)
  L.rooms.find((r) => r.id === "steerage").fore = "wall";
  const e = errs(m);
  assert.ok(e.some((x) => /room steerage \(main\) cannot be reached from the helm/.test(x)), e.join("\n"));
  assert.ok(e.some((x) => /room officers \(main\) cannot be reached from the helm/.test(x)), e.join("\n"));
  const b = galleon();
  b.ships.classes[0].rooms.find((r) => r.id === "bosun").aft = "wall";
  assert.deepEqual(errs(b), [], "the bosun's store is still reached by its ladder from the orlop");
  const n = galleon();
  n.ships.classes[0].rooms = n.ships.classes[0].rooms.filter((r) => r.kind !== "helm");
  assert.ok(errs(n).some((x) => x.includes('needs a room of kind "helm"')));
  const o = galleon();
  o.ships.classes[0].links.push({ kind: "ladder", from: "main", to: "gun", x: 3500 });
  // (a ladder through the foremast)
  assert.ok(errs(o).some((x) => /link ladder-main-gun-\d+: its hatch on the main \(\d+ to \d+\) runs into a mast/.test(x)), errs(o).join("\n"));
  const p = galleon();
  p.ships.classes[0].decks = p.ships.classes[0].decks.filter((d) => d.id !== "main");
  assert.ok(errs(p).some((x) => x.includes('needs the main deck')));
});

test("the classes a mod makes: all of them (replace), or the defaults with the mod's in place of the same id", () => {
  const g = galleon();
  assert.deepEqual(modLayouts(g, LAYOUTS).map((L) => L.id), ["galleon"]);
  const add = { ships: { classes: [{ ...g.ships.classes[0], id: "line", cap: 24 }] } };
  assert.deepEqual(modLayouts(add, LAYOUTS).map((L) => L.id), ["sloop", "brig", "frigate", "line"]);
  assert.equal(modLayouts(add, LAYOUTS)[3], add.ships.classes[0]);
  assert.equal(modLayouts({}, LAYOUTS), null);
  // replacing every class needs one for the fullest crew
  const small = galleon();
  small.ships.classes[0].cap = 12;
  assert.ok(errs(small).some((x) => x.includes("cap 24")));
});

test("nothing in the mod loader can run a mod or reach the network", () => {
  for (const f of ["mod.js", "modui.js"]) {
    const src = readFileSync(`${ROOT}src/${f}`, "utf8").replace(/\/\/.*$/gm, "");
    for (const bad of ["fetch(", "XMLHttpRequest", "WebSocket", "sendBeacon", "eval(", "Function(", "import(", "innerHTML", "setTimeout(\""]) assert.ok(!src.includes(bad), `${f}: ${bad}`);
  }
  // the page's CSP (game2d.html; the build pins the bundle by hash) allows no other host
  const html = readFileSync(`${ROOT}game2d.html`, "utf8"), csp = html.match(/Content-Security-Policy" content="([^"]+)"/)[1];
  assert.match(csp, /default-src 'self'/);
  assert.match(csp, /connect-src 'self'/);
  assert.match(csp, /script-src 'self'(;|$)/);
  assert.doesNotMatch(csp, /unsafe-eval|script-src[^;]*unsafe-inline/);
});
