// Mods: plain data that swaps or extends the ship, the crew's looks and the captions. A mod is one
// JSON file (format "voyage-mod/1", docs/modding.md). It is only ever parsed with JSON.parse and
// read as numbers, short plain texts and data: images, against a strict schema: an unknown key,
// a wrong type or an out-of-range number is refused with a message naming where it is. Nothing in
// a mod is run, and nothing in it can reach the network: no field is a URL (images are data:
// URIs only), no text may carry markup (< and > are refused), and the page's CSP forbids any
// other host. A ship layout must also pass the walking model's own gate (checkLayout): every room
// and station reachable from the helm.
import { specOf, checkLayout, ROOM_KINDS, PROP_KINDS, STATION_KINDS, BATTLE_POSTS } from "./deckplan.js";

export const MOD_FORMAT = "voyage-mod/1";
export const MAX_BYTES = 3_000_000;
const LANG_KEYS = ["en", "zh-TW", "zh-CN"];
const ID = /^[a-z0-9][a-z0-9-]{0,31}$/, DECK_ID = /^[a-z][a-z0-9-]{0,15}$/, HEX = /^#[0-9a-fA-F]{6}$/;
const DATA_IMG = /^data:image\/(png|webp|jpeg);base64,[A-Za-z0-9+/]+={0,2}$/;
const MAX_IMG = 400_000;

// the checker: every rule appends a message with the path it is about
function checker(errors) {
  const say = (path, msg) => errors.push(`${path}: ${msg}`);
  const type = (v) => (v === null ? "null" : Array.isArray(v) ? "a list" : typeof v === "object" ? "an object" : typeof v === "string" ? `the text "${v.length > 24 ? v.slice(0, 24) + "…" : v}"` : `${typeof v} ${v}`);
  const C = {
    say,
    obj(v, path, keys, required = []) {
      if (!v || typeof v !== "object" || Array.isArray(v)) return say(path, `expected an object, got ${type(v)}`), false;
      for (const k of Object.keys(v)) if (!keys.includes(k)) say(path, `unknown key "${k}" (allowed: ${keys.join(", ")})`);
      for (const k of required) if (!(k in v)) say(path, `missing "${k}"`);
      return true;
    },
    num(v, path, lo, hi, int = false) {
      if (typeof v !== "number" || !Number.isFinite(v)) return say(path, `expected a number, got ${type(v)}`), false;
      if (int && !Number.isInteger(v)) return say(path, `expected a whole number, got ${v}`), false;
      if (v < lo || v > hi) return say(path, `${v} is out of range (${lo} to ${hi})`), false;
      return true;
    },
    bool(v, path) { if (typeof v !== "boolean") return say(path, `expected true or false, got ${type(v)}`), false; return true; },
    oneOf(v, path, list) { if (!list.includes(v)) return say(path, `expected one of ${list.map((x) => JSON.stringify(x)).join(", ")}, got ${type(v)}`), false; return true; },
    re(v, path, re, what) {
      if (typeof v !== "string") return say(path, `expected ${what}, got ${type(v)}`), false;
      if (!re.test(v)) return say(path, `"${v.slice(0, 40)}" is not ${what}`), false;
      return true;
    },
    // plain text: no markup, no control characters, not too long
    text(v, path, max = 120) {
      if (typeof v !== "string") return say(path, `expected text, got ${type(v)}`), false;
      if (!v.trim()) return say(path, "is empty"), false;
      if (v.length > max) return say(path, `is ${v.length} characters long (at most ${max})`), false;
      if (/[<>]/.test(v)) return say(path, "may not contain < or > (plain text only: a mod carries no markup)"), false;
      if (/[\u0000-\u001f\u007f]/.test(v)) return say(path, "contains a control character"), false;
      return true;
    },
    // a text in three languages (or one text for all of them)
    text3(v, path, max = 80) {
      if (typeof v === "string") return C.text(v, path, max);
      if (!C.obj(v, path, LANG_KEYS, ["en"])) return false;
      for (const k of Object.keys(v)) if (LANG_KEYS.includes(k)) C.text(v[k], `${path}.${k}`, max);
      return true;
    },
    list(v, path, lo, hi) {
      if (!Array.isArray(v)) return say(path, `expected a list, got ${type(v)}`), false;
      if (v.length < lo || v.length > hi) return say(path, `has ${v.length} entries (${lo} to ${hi})`), false;
      return true;
    },
    image(v, path) {
      if (typeof v !== "string" || !DATA_IMG.test(v)) return say(path, "expected an image as a data: URI (data:image/png;base64,…); a mod never links to a file or a host"), false;
      if (v.length > MAX_IMG) return say(path, `the image is ${v.length} bytes of text (at most ${MAX_IMG})`), false;
      return true;
    },
  };
  return C;
}

// ---------------------------------------------------------------- a ship layout
const X = 20000; // no coordinate is further than this from the ship's middle
export function checkShip(L, path, C, { deep = true } = {}) {
  if (!C.obj(L, path, ["id", "cap", "crewScale", "name", "hull", "decks", "rooms", "links", "masts", "props", "stations", "battle"], ["id", "cap", "name", "hull", "decks", "rooms"])) return;
  C.re(L.id, `${path}.id`, ID, "an id (a-z, 0-9 and -, at most 32)");
  C.num(L.cap, `${path}.cap`, 1, 24, true);
  if ("crewScale" in L) C.num(L.crewScale, `${path}.crewScale`, 0.6, 1.2);
  C.text3(L.name, `${path}.name`, 40);
  const h = L.hull;
  if (C.obj(h, `${path}.hull`, ["stern", "bow", "keel", "waterline"], ["stern", "bow", "keel", "waterline"])) {
    const ok = C.num(h.stern, `${path}.hull.stern`, -X, -1000) & C.num(h.bow, `${path}.hull.bow`, 1000, X) & C.num(h.keel, `${path}.hull.keel`, 600, 8000) & C.num(h.waterline, `${path}.hull.waterline`, 0, 8000);
    if (ok && h.waterline >= h.keel) C.say(`${path}.hull.waterline`, `${h.waterline} is at or below the keel (${h.keel})`);
  }
  const decks = new Set();
  if (C.list(L.decks, `${path}.decks`, 2, 14)) L.decks.forEach((d, i) => {
    const p = `${path}.decks[${i}]`;
    if (!C.obj(d, p, ["id", "y", "x0", "x1", "label"], ["id", "y"])) return;
    if (C.re(d.id, `${p}.id`, DECK_ID, "a deck id (a-z first, then a-z, 0-9 and -)")) {
      if (decks.has(d.id)) C.say(`${p}.id`, `"${d.id}" is used twice`);
      if (/^nest\d*$/.test(d.id)) C.say(`${p}.id`, `"${d.id}" is kept for the crow's nests (a mast with "nest": true makes one)`);
      decks.add(d.id);
    }
    C.num(d.y, `${p}.y`, -4000, 8000);
    if ("x0" in d) C.num(d.x0, `${p}.x0`, -X, X);
    if ("x1" in d) C.num(d.x1, `${p}.x1`, -X, X);
    if (typeof d.x0 === "number" && typeof d.x1 === "number" && d.x1 - d.x0 < 400) C.say(p, `is ${d.x1 - d.x0} long (at least 400)`);
    if (d.y < 0 && (!("x0" in d) || !("x1" in d))) C.say(p, "a deck above the main deck (y < 0) needs x0 and x1: it makes a castle, and the hull is drawn round it");
    if ("label" in d) C.text3(d.label, `${p}.label`, 40);
  });
  if (Array.isArray(L.decks) && !L.decks.some((d) => d && d.id === "main" && d.y === 0)) C.say(`${path}.decks`, 'needs the main deck: { "id": "main", "y": 0 }');
  const deckRef = (v, p) => C.re(v, p, DECK_ID, "a deck id") && (decks.has(v) || (C.say(p, `no deck "${v}" (decks: ${[...decks].join(", ")})`), false));
  const rooms = new Set();
  if (C.list(L.rooms, `${path}.rooms`, 1, 48)) L.rooms.forEach((r, i) => {
    const p = `${path}.rooms[${i}]`;
    if (!C.obj(r, p, ["id", "kind", "deck", "x0", "x1", "aft", "fore", "furnish", "label"], ["id", "kind", "deck"])) return;
    if (C.re(r.id, `${p}.id`, ID, "a room id") && rooms.has(r.id)) C.say(`${p}.id`, `"${r.id}" is used twice`);
    rooms.add(r.id);
    C.oneOf(r.kind, `${p}.kind`, ROOM_KINDS.filter((k) => k !== "nest"));
    deckRef(r.deck, `${p}.deck`);
    if ("x0" in r) C.num(r.x0, `${p}.x0`, -X, X);
    if ("x1" in r) C.num(r.x1, `${p}.x1`, -X, X);
    if (typeof r.x0 === "number" && typeof r.x1 === "number" && r.x1 - r.x0 < 300) C.say(p, `is ${r.x1 - r.x0} long (at least 300)`);
    for (const k of ["aft", "fore"]) if (k in r) C.oneOf(r[k], `${p}.${k}`, ["door", "wall", "open"]);
    if ("furnish" in r) C.bool(r.furnish, `${p}.furnish`);
    if ("label" in r) C.text3(r.label, `${p}.label`, 40);
  });
  if (Array.isArray(L.rooms) && !L.rooms.some((r) => r?.kind === "helm")) C.say(`${path}.rooms`, 'needs a room of kind "helm" (the captain\'s wheel)');
  if ("links" in L && C.list(L.links, `${path}.links`, 0, 48)) L.links.forEach((l, i) => {
    const p = `${path}.links[${i}]`;
    if (!C.obj(l, p, ["id", "kind", "from", "to", "x", "dir"], ["kind", "from", "to", "x"])) return;
    if ("id" in l) C.re(l.id, `${p}.id`, ID, "a link id");
    C.oneOf(l.kind, `${p}.kind`, ["stairs", "ladder"]);
    deckRef(l.from, `${p}.from`);
    deckRef(l.to, `${p}.to`);
    C.num(l.x, `${p}.x`, -X, X);
    if ("dir" in l) C.oneOf(l.dir, `${p}.dir`, [1, -1]);
  });
  if ("masts" in L && C.list(L.masts, `${path}.masts`, 0, 5)) L.masts.forEach((m, i) => {
    const p = `${path}.masts[${i}]`;
    if (!C.obj(m, p, ["x", "height", "span", "nest"], ["x", "height"])) return;
    C.num(m.x, `${p}.x`, -X, X);
    C.num(m.height, `${p}.height`, 800, 12000);
    if ("span" in m) C.num(m.span, `${p}.span`, 100, 5000);
    if ("nest" in m) C.bool(m.nest, `${p}.nest`);
  });
  if ("props" in L && C.list(L.props, `${path}.props`, 0, 240)) L.props.forEach((q, i) => {
    const p = `${path}.props[${i}]`;
    if (!C.obj(q, p, ["kind", "deck", "x", "far"], ["kind", "deck", "x"])) return;
    C.oneOf(q.kind, `${p}.kind`, PROP_KINDS.filter((k) => k !== "gun" && k !== "wheel"));
    deckRef(q.deck, `${p}.deck`);
    C.num(q.x, `${p}.x`, -X, X);
    if ("far" in q) C.bool(q.far, `${p}.far`);
  });
  if ("stations" in L && C.list(L.stations, `${path}.stations`, 0, 240)) L.stations.forEach((s, i) => {
    const p = `${path}.stations[${i}]`;
    if (!C.obj(s, p, ["id", "kind", "deck", "x", "dir"], ["kind", "deck", "x"])) return;
    if ("id" in s) C.re(s.id, `${p}.id`, ID, "a station id");
    C.oneOf(s.kind, `${p}.kind`, STATION_KINDS);
    deckRef(s.deck, `${p}.deck`);
    C.num(s.x, `${p}.x`, -X, X);
    if ("dir" in s) C.oneOf(s.dir, `${p}.dir`, [1, -1]);
  });
  if ("battle" in L && C.list(L.battle, `${path}.battle`, 2, 120)) {
    L.battle.forEach((b, i) => {
      const p = `${path}.battle[${i}]`;
      if (!C.obj(b, p, ["post", "deck", "x", "dir"], ["post", "deck", "x"])) return;
      C.oneOf(b.post, `${p}.post`, BATTLE_POSTS);
      deckRef(b.deck, `${p}.deck`);
      C.num(b.x, `${p}.x`, -X, X);
      if ("dir" in b) C.oneOf(b.dir, `${p}.dir`, [1, -1]);
    });
    for (const post of ["captain", "mate"]) if (!L.battle.some((b) => b?.post === post)) C.say(`${path}.battle`, `needs a "${post}" post`);
    if (L.battle.length < (L.cap || 0)) C.say(`${path}.battle`, `has ${L.battle.length} posts for up to ${L.cap} hands (one each)`);
  }
  // the walking model's gate: build the ship and walk it
  if (deep && C.errors.length === C.start) {
    try {
      for (const e of checkLayout(specOf(L))) C.say(path, e);
    } catch (e) {
      C.say(path, "the ship could not be built: " + (e?.message || e));
    }
  }
}

// ---------------------------------------------------------------- the manifest
// opts.bake: the sprite bake (for the frame paths and model names); opts.stringKeys and
// opts.captionKeys: what the HUD lets a mod say differently (src/hud.js)
export function validateMod(input, { bake = null, stringKeys = null, captionKeys = null } = {}) {
  const errors = [];
  let m = input;
  if (typeof input === "string") {
    if (input.length > MAX_BYTES) return { ok: false, errors: [`the file is ${input.length} bytes (at most ${MAX_BYTES})`] };
    try { m = JSON.parse(input); } catch (e) { return { ok: false, errors: ["not JSON: " + e.message] }; }
  }
  const C = checker(errors);
  C.errors = errors;
  if (!C.obj(m, "mod", ["format", "id", "name", "version", "author", "description", "ships", "crew", "strings", "captions"], ["format", "id", "name"])) return { ok: false, errors };
  if (m.format !== MOD_FORMAT) C.say("mod.format", `expected "${MOD_FORMAT}", got ${JSON.stringify(m.format)?.slice(0, 40)}`);
  C.re(m.id, "mod.id", ID, "an id (a-z, 0-9 and -, at most 32)");
  C.text3(m.name, "mod.name", 60);
  if ("version" in m) C.text(m.version, "mod.version", 20);
  if ("author" in m) C.text(m.author, "mod.author", 80);
  if ("description" in m) C.text3(m.description, "mod.description", 400);
  if ("ships" in m && C.obj(m.ships, "mod.ships", ["replace", "classes"], ["classes"])) {
    if ("replace" in m.ships) C.bool(m.ships.replace, "mod.ships.replace");
    if (C.list(m.ships.classes, "mod.ships.classes", 1, 8)) {
      const ids = new Set();
      m.ships.classes.forEach((L, i) => {
        C.start = errors.length;
        checkShip(L, `mod.ships.classes[${i}]`, C);
        if (L?.id) (ids.has(L.id) && C.say(`mod.ships.classes[${i}].id`, `"${L.id}" is used twice`), ids.add(L.id));
      });
      if (m.ships.replace && !m.ships.classes.some((L) => L?.cap === 24)) C.say("mod.ships", "replaces every class, so one class must carry the most hands the game allows (cap 24)");
    }
  }
  if ("crew" in m && C.obj(m.crew, "mod.crew", ["palettes", "frames", "props"])) {
    const models = bake ? Object.keys(bake.crew) : null;
    const model = (k, p) => (models && !models.includes(k) ? (C.say(p, `no crewman "${k}" (the models: ${models.join(", ")})`), false) : C.re(k, p, /^[a-z0-9-]{1,32}$/, "a model name"));
    if ("palettes" in m.crew && C.obj(m.crew.palettes, "mod.crew.palettes", models || Object.keys(m.crew.palettes))) for (const [k, list] of Object.entries(m.crew.palettes)) {
      const p = `mod.crew.palettes.${k}`;
      if (!model(k, p) || !C.list(list, p, 1, 16)) continue;
      list.forEach((sw, i) => {
        if (!C.obj(sw, `${p}[${i}]`, ["from", "to", "tolerance"], ["from", "to"])) return;
        C.re(sw.from, `${p}[${i}].from`, HEX, "a colour like #1f2a5c");
        C.re(sw.to, `${p}[${i}].to`, HEX, "a colour like #1f2a5c");
        if ("tolerance" in sw) C.num(sw.tolerance, `${p}[${i}].tolerance`, 0, 160);
      });
    }
    if ("frames" in m.crew && C.obj(m.crew.frames, "mod.crew.frames", models || Object.keys(m.crew.frames))) for (const [k, map] of Object.entries(m.crew.frames)) {
      const p = `mod.crew.frames.${k}`;
      if (!model(k, p) || !C.obj(map, p, Object.keys(map))) continue;
      for (const [path, img] of Object.entries(map)) {
        if (bake && !framePath(bake.crew[k], path)) C.say(`${p}["${path}"]`, `no frame "${path}" (for example "q.parts.torso", "q.heads.grin", "f.hands.r.fist", "q.whole")`);
        else if (!bake && !/^[qf]\.(parts|heads|hands\.[lr])\.[a-z0-9_]+$|^[qf]\.whole$/.test(path)) C.say(`${p}["${path}"]`, "is not a frame path");
        C.image(img, `${p}["${path}"]`);
      }
    }
    if ("props" in m.crew && C.obj(m.crew.props, "mod.crew.props", bake ? Object.keys(bake.props) : Object.keys(m.crew.props))) for (const [k, img] of Object.entries(m.crew.props)) C.image(img, `mod.crew.props.${k}`);
  }
  if ("strings" in m && C.obj(m.strings, "mod.strings", LANG_KEYS)) for (const [lang, map] of Object.entries(m.strings)) {
    if (!LANG_KEYS.includes(lang) || !C.obj(map, `mod.strings.${lang}`, stringKeys || Object.keys(map))) continue;
    for (const [k, v] of Object.entries(map)) C.text(v, `mod.strings.${lang}.${k}`, 200);
  }
  if ("captions" in m && C.obj(m.captions, "mod.captions", captionKeys || Object.keys(m.captions))) for (const [k, v] of Object.entries(m.captions)) C.text3(v, `mod.captions["${k}"]`, 120);
  return errors.length ? { ok: false, errors } : { ok: true, errors: [], mod: m };
}
// a frame path ("q.parts.torso", "f.hands.r.fist", "q.whole") in a baked crewman
export function framePath(c, path) {
  if (!c) return null;
  const [f, g, a, b] = path.split(".");
  const F = c.facings?.[f];
  if (!F) return null;
  if (g === "whole" && a === undefined) return F.whole || null;
  if (g === "parts" || g === "heads") return (b === undefined && F[g]?.[a]) || null;
  if (g === "hands" && (a === "l" || a === "r")) return F.hands?.[a]?.[b] || null;
  return null;
}
// the classes a mod's ships make: all of them (replace), or the defaults with the mod's in place
// of the same ids and the new ones added; smallest first
export function modLayouts(mod, defaults) {
  const list = mod?.ships?.classes;
  if (!list) return null;
  if (mod.ships.replace) return list.slice();
  const out = defaults.filter((L) => !list.some((M) => M.id === L.id));
  return [...out, ...list].sort((a, b) => a.cap - b.cap);
}
