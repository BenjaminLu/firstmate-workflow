// The four ships of the 2.5D game as layouts: plain data, the same shape a mod's "ships" section
// supplies (docs/modding.md). They are made by one recipe, so the classes grow alike, but what
// comes out is only numbers and names: nothing here runs in the game but this file's recipe.
//
// Scale (the captain's "船需要變得超大 人變得超小"): a crewman is about 200 units tall at crew
// scale 1. Every deck is LEVEL (480) below the one above, and the ships are long: the sloop is
// about 30 crewmen long and 11.5 tall, stern to stem and rail to keel (it was 7.3 and 4.5), the
// ship of the line about 60 long and 20 tall (it was 17.7 and 6.7). Every class has the same rooms, so every hand has somewhere to be:
//   the quarterdeck with the helm; the captain's great cabin under it (where decisions wait);
//   the chart room (the firstmate); the open waist with workbenches (hands at work); the
//   forecastle and the bow (lookouts); the crow's nests (review); the gun decks (the gates);
//   the galley and the crew's quarters (hands at rest); the hold (the stowed work).
import { LEVEL, specOf } from "./deckplan.js";

const R = (v) => Math.round(v);

// one ship by the recipe: len (stern to stem), the masts as fractions of the length from the
// stern, gunDecks (1 or 2), poop (a deck over the quarterdeck, the chart room under it)
function recipe({ id, cap, crewScale, name, len, masts, mastH, span = 0.19, gunDecks = 1, poop = false }) {
  const stern = -len / 2, bow = len / 2, at = (f) => R(stern + len * f);
  const qdX1 = at(0.3), foreX0 = at(0.8), poopX1 = at(0.16);
  const ys = { poop: -2 * LEVEL, qd: -LEVEL, fore: -LEVEL, main: 0 };
  const lower = [];
  for (let i = 0; i < gunDecks; i++) lower.push(i ? "gun" + (i + 1) : "gun");
  lower.push("berth", "hold");
  lower.forEach((d, i) => (ys[d] = (i + 1) * LEVEL));
  const keel = ys.hold + 340, waterline = ys[lower[gunDecks - 1]] + 190;
  const decks = [
    ...(poop ? [{ id: "poop", y: ys.poop, x0: at(0.012), x1: poopX1, label: { en: "Poop deck", "zh-TW": "艉樓甲板", "zh-CN": "艉楼甲板" } }] : []),
    { id: "qd", y: ys.qd, x0: at(0.01), x1: qdX1, label: { en: "Quarterdeck", "zh-TW": "後甲板", "zh-CN": "后甲板" } },
    { id: "fore", y: ys.fore, x0: foreX0, x1: at(0.955), label: { en: "Forecastle", "zh-TW": "艏樓", "zh-CN": "艏楼" } },
    { id: "main", y: 0, label: { en: "Main deck", "zh-TW": "主甲板", "zh-CN": "主甲板" } },
    ...lower.map((d) => ({ id: d, y: ys[d], label: LOWER[d.replace(/\d+$/, "")] })),
  ];
  const cabinX1 = poop ? at(0.2) : at(0.19);
  const rooms = [
    ...(poop ? [
      { id: "poop", kind: "open", deck: "poop", label: L.poop },
      { id: "chart", kind: "chart", deck: "qd", x1: poopX1, fore: "door", label: L.chart },
      { id: "helm", kind: "helm", deck: "qd", x0: poopX1, label: L.helm },
    ] : [
      { id: "helm", kind: "helm", deck: "qd", label: L.helm },
    ]),
    { id: "cabin", kind: "cabin", deck: "main", x1: cabinX1, fore: "door", label: L.cabin },
    poop
      ? { id: "workshop", kind: "workshop", deck: "main", x0: cabinX1, x1: qdX1, fore: "door", label: L.workshop }
      : { id: "chart", kind: "chart", deck: "main", x0: cabinX1, x1: qdX1, fore: "door", label: L.chart },
    { id: "waist", kind: "waist", deck: "main", x0: qdX1, x1: foreX0, aft: "open", fore: "open", label: L.waist },
    { id: "galley", kind: "galley", deck: "main", x0: foreX0, aft: "door", label: L.galley },
    { id: "forecastle", kind: "forecastle", deck: "fore", label: L.forecastle },
    ...lower.slice(0, gunDecks).map((d, i) => ({ id: d, kind: "gundeck", deck: d, label: i ? { en: "Lower gun deck", "zh-TW": "下層砲甲板", "zh-CN": "下层炮甲板" } : L.gundeck })),
    { id: "quarters", kind: "quarters", deck: "berth", x1: at(0.62), fore: "door", label: L.quarters },
    { id: "mess", kind: "galley", deck: "berth", x0: at(0.62), label: L.mess },
    { id: "hold", kind: "cargo", deck: "hold", label: L.hold },
  ];
  // the ways between decks: stairs down from the castles to the waist, the companionway and a
  // fore ladder from the waist, and two ways between each lower deck and the next
  // The ways down, placed by the recipe (a mod gives its x values directly): each keeps clear of
  // the others, of the masts (they run down to the keel) and of the bulkheads, on both its decks.
  // A stair's run is 0.7 of the deck's height, its hatch 0.82 of that; landings stand 64 beyond.
  const mx = masts.map((f) => at(f)), busy = {};
  for (const r of rooms) for (const x of [r.x0, r.x1]) if (x != null) (busy[r.deck] ||= []).push([x - 40, x + 40]);
  const reach = (kind, x, s, run) => kind === "stairs"
    ? { up: [Math.min(x - s * 104, x + s * run * 0.82), Math.max(x - s * 104, x + s * run * 0.82)], dn: [Math.min(x, x + s * (run + 104)), Math.max(x, x + s * (run + 104))] }
    : { up: [Math.min(x - 52, x + s * 136), Math.max(x + 52, x + s * 136)], dn: [Math.min(x - 20, x + s * 106), Math.max(x + 20, x + s * 106)] };
  const free = (deck, [a, b]) => !(busy[deck] || []).some(([p, q]) => a < q + 30 && p < b + 30);
  const way = (kind, from, to, want, s = 1, fixed = false) => {
    const run = Math.max(200, (ys[to] - ys[from]) * 0.7);
    for (let d = 0; d < len; d += 20) for (const x of d ? [want + d, want - d] : [want]) {
      const sp = reach(kind, x, s, run);
      if (!fixed && (sp.up[0] < stern + len * 0.08 || sp.up[1] > bow - len * 0.14)) continue;
      if (!fixed && kind === "ladder" && mx.some((m) => Math.abs(m - x) < 220)) continue; // (a flight is on the far side, clear of a mast)
      if (!fixed && (!free(from, sp.up) || !free(to, sp.dn))) continue;
      (busy[from] ||= []).push(sp.up);
      (busy[to] ||= []).push(sp.dn);
      return { kind, from, to, x: R(x), dir: s };
    }
    return { kind, from, to, x: R(want), dir: s };
  };
  const links = [
    ...(poop ? [way("stairs", "poop", "qd", poopX1, 1, true)] : []),
    way("stairs", "qd", "main", qdX1, 1, true),
    way("stairs", "fore", "main", foreX0, -1, true),
    way("stairs", "main", lower[0], Math.max(at(0.38), qdX1 + 760)),
    way("ladder", "main", lower[0], foreX0 - 260, -1),
  ];
  for (let i = 1; i < lower.length; i++) {
    const up = lower[i - 1], dn = lower[i];
    links.push(way(dn === "hold" ? "ladder" : "stairs", up, dn, at(i % 2 ? 0.55 : 0.42), i % 2 ? 1 : -1));
    links.push(way("ladder", up, dn, at(i % 2 ? 0.25 : 0.76)));
  }
  return {
    id, cap, crewScale, name,
    hull: { stern, bow, keel, waterline },
    decks, rooms, links,
    masts: masts.map((f, i) => { const height = R(mastH * (i === (masts.length > 1 ? 1 : 0) ? 1 : 0.84)); return { x: at(f), height, span: R(height * span), nest: true }; }),
  };
}
const L = {
  helm: { en: "Helm", "zh-TW": "舵輪", "zh-CN": "舵轮" },
  cabin: { en: "Captain's cabin", "zh-TW": "船長室", "zh-CN": "船长室" },
  chart: { en: "Chart room", "zh-TW": "海圖室", "zh-CN": "海图室" },
  workshop: { en: "Carpenter's shop", "zh-TW": "木工房", "zh-CN": "木工房" },
  waist: { en: "Waist · workbenches", "zh-TW": "中甲板 · 工作台", "zh-CN": "中甲板 · 工作台" },
  galley: { en: "Galley", "zh-TW": "廚房", "zh-CN": "厨房" },
  mess: { en: "Mess", "zh-TW": "餐廳", "zh-CN": "餐厅" },
  forecastle: { en: "Bow lookout", "zh-TW": "船首瞭望", "zh-CN": "船首瞭望" },
  gundeck: { en: "Gun deck · the gates", "zh-TW": "砲甲板 · 關卡", "zh-CN": "炮甲板 · 关卡" },
  quarters: { en: "Crew quarters", "zh-TW": "船員艙", "zh-CN": "船员舱" },
  hold: { en: "Hold · the backlog", "zh-TW": "貨艙 · 待辦", "zh-CN": "货舱 · 待办" },
  poop: { en: "Poop deck · merged flags", "zh-TW": "艉樓 · 合併旗", "zh-CN": "艉楼 · 合并旗" },
};
const LOWER = {
  gun: { en: "Gun deck", "zh-TW": "砲甲板", "zh-CN": "炮甲板" },
  berth: { en: "Berth deck", "zh-TW": "住艙甲板", "zh-CN": "住舱甲板" },
  hold: { en: "Hold", "zh-TW": "貨艙", "zh-CN": "货舱" },
};

export const LAYOUTS = [
  recipe({ id: "sloop", cap: 7, crewScale: 1, name: { en: "Sloop", "zh-TW": "單桅帆船", "zh-CN": "单桅帆船" }, len: 6000, masts: [0.5], mastH: 4400, span: 0.34 }),
  recipe({ id: "brig", cap: 12, crewScale: 0.95, name: { en: "Brig", "zh-TW": "雙桅橫帆船", "zh-CN": "双桅横帆船" }, len: 7000, masts: [0.38, 0.64], mastH: 4700, span: 0.25 }),
  recipe({ id: "frigate", cap: 18, crewScale: 0.9, name: { en: "Frigate", "zh-TW": "巡防艦", "zh-CN": "巡防舰" }, len: 8400, masts: [0.22, 0.5, 0.72], mastH: 5200, poop: true }),
  recipe({ id: "line", cap: 24, crewScale: 0.84, name: { en: "Ship of the line", "zh-TW": "戰列艦", "zh-CN": "战列舰" }, len: 10000, masts: [0.22, 0.5, 0.73], mastH: 6100, gunDecks: 2, poop: true }),
];

// the classes in play, smallest first: built from LAYOUTS, or from a mod's ships (setLayouts).
// The array is kept (and changed in place), so every module that holds it sees the mod's ships.
export const CLASSES = LAYOUTS.map(specOf);
export const classFor = (n) => CLASSES.find((c) => n <= c.cap) || CLASSES[CLASSES.length - 1];
export function setLayouts(list) {
  const specs = list.map(specOf).sort((a, b) => a.cap - b.cap);
  CLASSES.splice(0, CLASSES.length, ...specs);
  return CLASSES;
}
