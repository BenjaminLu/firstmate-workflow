// The ship is asserted through classes and numbers, never through a
// screenshot: a pose is a class, and every shared number has one source.
import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const SHIP = createRequire(import.meta.url)(join(ROOT, "board/public/ship.js"));
const CSS = readFileSync(join(ROOT, "board/public/ship.css"), "utf8");
const T = (k: string) => k;

const stub = () => ({
  onclick: null as unknown, textContent: "", style: {} as Record<string, string>,
  classList: { add() {}, remove() {} }, setAttribute() {},
  querySelectorAll: () => [] as unknown[],
});
function host() {
  const props: Record<string, string> = {};
  return {
    props, dataset: {} as Record<string, string>, innerHTML: "",
    style: { setProperty: (k: string, v: string) => { props[k] = v; } },
    querySelector: () => stub(), querySelectorAll: () => [] as unknown[],
  };
}
// The crew are AGENTS now: the server derives who is running from the
// actors in the log and the page draws that list. A fixture that wants
// five crewmen needs five agents, not five tasks - one worker that has
// moved through three tasks is one crewman.
const state = (n: number, stage = "working") => ({
  greenlit: true, counts: { merged: 0, inflight: n, blocked: 0, queued: 0 }, pending: [],
  tasks: Array.from({ length: n }, (_, i) => ({ id: `T-${i}`, title: `task ${i}`, stage })),
  crew: [
    { id: "firstmate", role: "firstmate", state: "working", task: null },
    ...Array.from({ length: n }, (_, i) => ({
      id: stage === "review" ? `reviewer-${i}` : `worker-${i}`,
      role: stage === "review" ? "reviewer" : "worker",
      state: stage, task: `T-${i}`, title: `task ${i}`,
    })),
  ],
});

test("a crowd stacks onto more decks, it does not stretch the hull", () => {
  const two = SHIP.rateFor(2), full = SHIP.rateFor(24);
  expect(full.rows).toBeGreaterThan(two.rows);
  expect(SHIP.RATES.length).toBe(6);
  expect(SHIP.RATES[SHIP.RATES.length - 1].max).toBe(24);
  // every rate is reachable and the ladder only ever grows
  for (let i = 1; i < SHIP.RATES.length; i++) {
    expect(SHIP.RATES[i].max).toBeGreaterThan(SHIP.RATES[i - 1].max);
    expect(SHIP.RATES[i].w).toBeGreaterThan(SHIP.RATES[i - 1].w);
    expect(SHIP.RATES[i].rows).toBeGreaterThanOrEqual(SHIP.RATES[i - 1].rows);
  }
  expect(full.rows).toBe(4);
  // a deck must hold its share without the crew overlapping
  for (const r of SHIP.RATES) expect(Math.ceil(r.max / r.rows)).toBeLessThanOrEqual(7);
});

test("every deck carries crew, including the topmost", () => {
  for (const n of [1, 4, 9, 14, 19, 24]) {
    const r = SHIP.rateFor(n), per = SHIP.layout(n, r.rows);
    expect(per.reduce((a: number, b: number) => a + b, 0)).toBe(n);
    if (n >= r.rows) expect(Math.min(...per)).toBeGreaterThan(0);
  }
});

test("the crew are the agents the server named, and 24 is the deck limit", () => {
  const c = SHIP.crewOf(state(3), T);
  expect(c.map((x: any) => x.id)).toEqual(["firstmate", "worker-0", "worker-1", "worker-2"]);
  // and each one says the task it is on, not its own name twice
  expect(c[1].job).toBe("T-0 \u00b7 task 0");
  expect(SHIP.crewOf(state(40), T).length).toBe(24);
  // the captain is not in this list at all: he is the person they are
  // waiting on, drawn beside the cards from the pending deck, and the
  // server does not put him here either - one source, not two
  expect(SHIP.crewOf(state(1), T).some((x: any) => x.role === "cap")).toBe(false);
});

test("a pose is a class, and every action holds a prop", () => {
  for (const a of SHIP.ACTIONS) {
    expect(CSS).toContain(`.fig.a-${a} `);
    expect(CSS.split(`.fig.a-${a} .tool`).length).toBeGreaterThan(1);
  }
  expect(SHIP.ACTIONS.length).toBe(12);
  // the same crewman always gets the same action
  expect(SHIP.actionFor("T-7", "working")).toBe(SHIP.actionFor("T-7", "working"));
  for (const s of ["working", "gate", "review", "queued", "captain"]) {
    expect(SHIP.ACTIONS).toContain(SHIP.actionFor("T-7", s));
  }
});

test("every state a crewman can be in is styled and named", () => {
  const en = JSON.parse(readFileSync(join(ROOT, "i18n/ui.en.json"), "utf8"));
  // the rate name is a computed key, so the file scan cannot see it
  for (const r of SHIP.RATES) expect(en[r.key]).toBeTruthy();
  const states = new Set<string>();
  for (const st of ["working", "gate", "review", "captain"]) {
    for (const c of SHIP.crewOf({ ...state(3, st), pending: [{ id: "d" }] }, T)) states.add(c.state);
  }
  for (const s of states) {
    expect(CSS).toContain(`.fig.s-${s}`);
    expect(CSS).toContain(`st-${s}`);
    // the roster names it from the dictionary, so it is switchable
    expect(en["lane" + s[0].toUpperCase() + s.slice(1)]).toBeTruthy();
  }
});

test("state and role reach the page as classes", () => {
  const h = host();
  const crew = SHIP.render(h as any, state(4, "review"), T);
  expect(crew.length).toBe(5);
  expect(h.innerHTML.split("class=\"pivot\"").length - 1).toBe(5);
  expect(h.innerHTML).toContain("s-review");
  expect(h.innerHTML).toContain("r-fm");
  expect(h.innerHTML).toContain("r-r");
  expect(h.dataset.crew).toBe("5");
  expect(h.dataset.rate).toBe(SHIP.rateFor(5).key);

  // the crew reach the page on the decks the layout put them on
  const rate = SHIP.rateFor(5);
  const rowsSeen = [...h.innerHTML.matchAll(/--r:(\d+)/g)].map((m) => +m[1]);
  const perRow = SHIP.layout(5, rate.rows);
  for (let r = 0; r < rate.rows; r++) {
    expect(rowsSeen.filter((x) => x === r).length).toBe(perRow[r] * 2); // figure + bubble
  }
  expect(new Set(rowsSeen).size).toBe(rate.rows);

  // and each one wears the action his own state chose, not one shared pose
  const mixed = { ...state(6), tasks: [
    { id: "T-a", title: "a", stage: "working" }, { id: "T-b", title: "b", stage: "gate" },
    { id: "T-c", title: "c", stage: "review" }, { id: "T-d", title: "d", stage: "working" }] };
  const h2 = host();
  const c2 = SHIP.render(h2 as any, mixed, T);
  const worn = [...h2.innerHTML.matchAll(/class="fig r-\w+ s-\w+ a-(\w+)"/g)].map((m) => m[1]);
  expect(worn).toEqual(c2.map((c: any) => SHIP.actionFor(c.id, c.state)));
  expect(new Set(worn).size).toBeGreaterThan(1);
});

test("shared numbers have one source: ship.css declares no geometry", () => {
  const h = host();
  SHIP.render(h as any, state(6), T);
  for (const k of ["--sceneH", "--deckY0", "--rowStep", "--deckW", "--figH", "--hullBottom"]) {
    expect(h.props[k]).toBeTruthy();
    // a fallback in var() is a read; a declaration would be a second source
    expect(CSS).not.toMatch(new RegExp("[;{]\\s*" + k + "\\s*:"));
  }
});

test("the whole sail clears the tallest crewman's head", () => {
  for (const n of [1, 7, 24]) {
    const h = host();
    SHIP.render(h as any, state(n), T);
    const px = (k: string) => parseFloat(h.props[k]);
    const rate = SHIP.rateFor(SHIP.crewOf(state(n), T).length);
    const topDeck = px("--deckY0") + (rate.rows - 1) * px("--rowStep");
    const sail = /class="sail[^"]*" style="top:(\d+)px;height:(\d+)px/.exec(h.innerHTML)!;
    const mastH = parseInt(/class="mast"[^>]*height:(\d+)px/.exec(h.innerHTML)![1], 10);
    const sailBottom = topDeck + mastH - (parseInt(sail[1], 10) + parseInt(sail[2], 10));
    expect(sailBottom).toBeGreaterThan(topDeck + px("--figH"));
  }
});

test("one gun list drives the ports, the flashes and the broadside", () => {
  const h = host();
  SHIP.render(h as any, state(20), T);
  const rate = SHIP.rateFor(SHIP.crewOf(state(20), T).length);
  expect(h.innerHTML.split('class="port"').length - 1).toBe(rate.guns);
  expect(h.innerHTML.split('<i style="left:').length - 1).toBe(rate.guns);
  expect((h as any)._guns.length).toBe(rate.guns);
  // all of them point the same way, and the bow is to the left
  expect(CSS).toContain("scaleX(-1)");
  // one band, so every port is clear of the crew standing on a deck
  expect(new Set((h as any)._guns.map((g: any) => g.y)).size).toBe(1);
  expect(CSS.split("translateX(-7px)").length).toBe(2);
});

test("brass is the only accent", () => {
  const accents = new Set((CSS.match(/#[0-9a-f]{6}/gi) || [])
    .filter((c) => /^#(d9a441|e8ae3e|c9972f|f0c46a|ffe6a8|ffe9ae|fffbe8|f6b447)$/i.test(c)));
  expect(accents.size).toBeGreaterThan(0);
  // no competing accent hue: nothing saturated green or cyan in the chrome
  expect(CSS).not.toMatch(/#(0[0-9a-f]f[0-9a-f]{3}|00[0-9a-f]{2}ff)/i);
});

test("the board says nothing the reader cannot switch language on", () => {
  const src = readFileSync(join(ROOT, "board/public/ship.js"), "utf8");
  const han = src.split("\n").filter((l) => /\p{Script=Han}/u.test(l));
  expect(han).toEqual([]);
});
