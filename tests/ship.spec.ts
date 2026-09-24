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
  // the server sends the limit with the list; the page holds no copy of
  // the number, so a fixture that omitted it made this test pass through
  // a client-side fallback that no longer exists
  deckLimit: 24,
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
  expect(c[1].job).toBe("T-0 · descriptionUnavailable");
  expect(SHIP.crewOf(state(40), T).length).toBe(24);
  // and it is the server's number that decides, not one kept here
  expect(SHIP.crewOf({ ...state(40), deckLimit: 6 }, T).length).toBe(6);
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

// The page maps the server's three role names onto short class
// suffixes and falls back to "unknown" for anything else. The comment
// beside that line says a mismatch "should be visible, not painted as a
// worker" - which was reasoning, not code: r-unknown had no rule, so it
// inherited .fig and looked like an ordinary crewman.
// The captain's geometry has one source, and the test for that is not a
// comment saying so. It wrote three properties nothing in his block read
// - two of them for a sum that a more specific rule overrode - which is
// the same defect as a literal, pointed the other way.
// The chip below the top deck carries the task, and falls back to the
// agent's name when there is none. The fallback is the page's contract
// with a crew list, not with today's server: firstmate is crew[0] and
// crew[0] is always on the top row, so nothing the server sends reaches
// it - and an empty chip is a crewman the board cannot name at all.
test("a crewman below the top deck with no task is still named on his chip", () => {
  const s = state(7);
  const nameless = s.crew[4] as { task?: string | null; title?: string | null; id: string };
  nameless.task = null; nameless.title = null;
  const h = host();
  SHIP.render(h as never, s, T);
  const minis = [...h.innerHTML.matchAll(/class="bub mini [^"]*"[^>]*><div class="who">([^<]*)</g)]
    .map((m) => m[1]);
  expect(minis.length).toBeGreaterThan(0);
  // no chip is blank, and the taskless one carries the agent's own id
  for (const m of minis) expect(m.trim()).not.toBe("");
  expect(minis.map(x=>x.trim())).toContain(nameless.id);
});

test("every custom property the captain writes is one his own block reads", () => {
  const js = readFileSync(join(ROOT, "board/public/ship.js"), "utf8");
  const body = js.slice(js.indexOf("function captain("), js.indexOf("function roster("));
  const props = [...body.matchAll(/setProperty\("(--[\w-]+)"/g)].map((m) => m[1]);
  expect(props.length).toBe(0); // the captain now shares the ship's deck geometry
  // his rules only: a property read somewhere else on the page is not
  // read HERE, which is the whole of the claim
  const his = CSS.replace(/\/\*[\s\S]*?\*\//g, "")
    .split("}")
    .filter((chunk) => /(^|[\s{,])\.(captain|capwrap|capstand|capsays)\b/.test(chunk.split("{")[0] ?? ""))
    .join("}");
  expect(his).toContain(".captain");
  for (const p of props) expect(his).toContain(`var(${p})`);
  // and the other way: the column the captain stands in takes its size
  // from him, rather than a literal that has to be kept in step
  expect(CSS).toContain('var(--capRow) * var(--rowStep)');
});

test("a role the page does not know is drawn as a mismatch, not as a worker", () => {
  // every suffix the map can produce has a rule of its own, and the
  // server's own role union is what decides the set - a fourth role
  // added there without one here has to fail
  const roles = readFileSync(join(ROOT, "board/server.ts"), "utf8")
    .match(/role:\s*("(?:firstmate|worker|reviewer)"(?:\s*\|\s*"\w+")*)/)?.[1]
    ?.split("|").map((x) => x.trim().replace(/"/g, "")) ?? [];
  expect(roles.length).toBeGreaterThan(2);
  for (const r of roles) expect(SHIP.ROLE[r]).toBeTruthy();
  for (const k of [...Object.values(SHIP.ROLE) as string[], "unknown"]) {
    expect(CSS).toContain(`.fig.r-${k}`);
  }
  // and it reaches the page loudly: a crewman the server sent with a
  // role this page has never heard of
  const s = state(1);
  (s.crew[1] as { role: string }).role = "quartermaster";
  expect(SHIP.crewOf(s, T)[1].role).toBe("unknown");
  const h = host();
  SHIP.render(h as never, s, T);
  expect(h.innerHTML).toContain("r-unknown");
  expect(h.innerHTML).not.toContain("r-w ");
});

test("state and role reach the page as classes", () => {
  const h = host();
  const crew = SHIP.render(h as any, state(4, "review"), T);
  expect(crew.length).toBe(5);
  expect(h.innerHTML.split("class=\"pivot\"").length - 1).toBe(6);
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
    expect(rowsSeen.filter((x) => x === r).length).toBe(perRow[r] * 2 + (r===rate.rows-1?1:0)); // human captain shares top deck
  }
  expect(new Set(rowsSeen).size).toBe(rate.rows);

  // and each one wears the action his own state chose, not one shared pose
  const mixed = { ...state(6), tasks: [
    { id: "T-a", title: "a", stage: "working" }, { id: "T-b", title: "b", stage: "gate" },
    { id: "T-c", title: "c", stage: "review" }, { id: "T-d", title: "d", stage: "working" }] };
  const h2 = host();
  const c2 = SHIP.render(h2 as any, mixed, T);
  const worn = [...h2.innerHTML.matchAll(/class="fig r-\w+ s-\w+ a-(\w+)"/g)].map((m) => m[1]);
  expect(worn).toEqual([...c2.map((c: any) => c.role==='fm'?'helm':SHIP.actionFor(c.id, c.state)), 'helm']);
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
    // every sail on every mast: a topsail clearing the heads says nothing
    // about the course hung below it
    const masts = [...h.innerHTML.matchAll(/<div class="mast"[^>]*height:(\d+)px">([\s\S]*?)<\/div>/g)];
    expect(masts.length).toBeGreaterThanOrEqual(2);
    for (const [, height, rig] of masts) {
      const sails = [...rig.matchAll(/class="sail[^"]*" style="top:(\d+)px;height:(\d+)px/g)];
      expect(sails.length).toBe(2);
      for (const s of sails) {
        const sailBottom = topDeck + parseInt(height, 10) - (parseInt(s[1], 10) + parseInt(s[2], 10));
        expect(sailBottom).toBeGreaterThan(topDeck + px("--figH"));
      }
    }
  }
});

test("a two-mast ship, name tags without percentages, and demonstrations that record nothing", () => {
  const h = host();
  const s = state(3);
  (s.crew[1] as any).progress = { done: 3, total: 7 };
  SHIP.render(h as any, s, T);
  expect(h.innerHTML.split('class="mast"').length - 1).toBe(2);
  // the smallest ship is a two-master too, not a single stick
  const small = host();
  SHIP.render(small as any, state(1), T);
  expect(small.innerHTML.split('class="mast"').length - 1).toBe(2);
  // the tag over a head carries no bar and no number, bounded or not
  const tags = [...h.innerHTML.matchAll(/<div class="bub[^"]*"[\s\S]*?<\/div><\/div>/g)].map((m) => m[0]);
  expect(tags.length).toBeGreaterThan(0);
  for (const tag of tags) {
    expect(tag).not.toContain('class="pb"');
    // the text a reader sees; the position style is a percentage too
    expect(tag.replace(/<[^>]*>/g, "")).not.toMatch(/\d+\s*%/);
  }
  // the roster toggle and both demonstrations are on the ship's bar
  for (const id of ["rosterBtn", "ahoyDemo", "orderDemo", "muteBtn"]) expect(h.innerHTML).toContain(`id="${id}"`);
  // and the demonstrations go through the effect queue, not the network
  const src = readFileSync(join(ROOT, "board/public/ship.js"), "utf8");
  const demo = src.slice(src.indexOf('querySelector("#ahoyDemo")'), src.indexOf('querySelector("#orderDemo")') + 120);
  expect(demo).toContain("enqueue(");
  expect(demo).not.toMatch(/fetch\(|XMLHttpRequest|sendBeacon/);
});

test("the roster is two-line rows and a bar only for bounded progress", () => {
  const s = state(2);
  (s.crew[1] as any).progress = { done: 1, total: 4 };
  (s.crew[2] as any).progress = 67;   // a bare number is not progress
  s.tasks[0] = { ...s.tasks[0], pr: 12 } as any;
  const crew = SHIP.crewOf(s, T);
  const h = { innerHTML: "", ownerDocument: null } as any;
  SHIP.roster(h, crew, T);
  const rows = [...h.innerHTML.matchAll(/<li class="rrow [^"]*"[\s\S]*?<\/li>/g)].map((m) => m[0]);
  expect(rows.length).toBe(3);
  for (const r of rows) {
    expect(r).toContain('class="l1"');
    expect(r).toContain('class="nm"');
    expect(r).toContain('class="st"');
    expect(r).toContain('class="jb"');
    // the text a reader sees; the bounded bar's fill width is a percentage too
    expect(r.replace(/<[^>]*>/g, "")).not.toMatch(/\d+\s*%/);
  }
  expect(rows[1]).toContain("#12");
  expect(rows[1]).toContain("T-0");
  expect(rows[1]).toContain('class="pb"');
  expect(rows[1]).toContain('aria-valuemax="4"');
  expect(rows[2]).not.toContain('class="pb"');
});

// T-069: the roster's #n links to the URL the server put beside the task's
// number, and to nothing the page made up when there is none
test("a roster row's pull request number links to the server's URL, or stays text", () => {
  const s = state(2);
  const url = "https://github.com/example-org/roster-app/pull/12";
  s.tasks[0] = { ...s.tasks[0], pr: 12, pr_url: url } as any;
  s.tasks[1] = { ...s.tasks[1], pr: 13, pr_url: null } as any;
  const crew = SHIP.crewOf(s, T);
  const h = { innerHTML: "", ownerDocument: null } as any;
  SHIP.roster(h, crew, T);
  const rows = [...h.innerHTML.matchAll(/<li class="rrow [^"]*"[\s\S]*?<\/li>/g)].map((m) => m[0]);
  const link = /<a [^>]*>#12<\/a>/.exec(rows[1])?.[0] ?? "";
  expect(link).toContain(`href="${url}"`);
  expect(link).toContain('target="_blank"');
  expect(link).toContain('rel="noreferrer"');
  expect(rows[2]).toContain("#13");
  expect(rows[2]).not.toContain("<a ");
  expect(rows[2]).not.toContain("github.com");
});

// a #n inside a title or an activity links through the server's pr_urls
// map, the one list of numbers the server accepted; one it left out is text
test("a roster row's title and activity link the #n the server mapped, and only those", () => {
  const s = state(2) as any;
  const url = "https://github.com/example-org/roster-app/pull/5";
  s.crew[1] = { ...s.crew[1], title: "follows #5 and #6", activity: { en: "reviewing #5, it's #7 next" } };
  s.pr_urls = { "5": url };
  const crew = SHIP.crewOf(s, T);
  const h = { innerHTML: "", ownerDocument: null } as any;
  SHIP.roster(h, crew, T);
  const row = [...h.innerHTML.matchAll(/<li class="rrow [^"]*"[\s\S]*?<\/li>/g)].map((m) => m[0])
    .find((r) => r.includes("reviewing")) ?? "";
  // #5 in the title and in the activity; #6 and #7 are not in the map
  expect(row.match(/<a [^>]*href="([^"]+)"[^>]*>#5<\/a>/g)?.length).toBe(2);
  expect(row).toContain(`href="${url}"`);
  expect(row).toContain("#6</span>");
  expect(row).toContain("#7 next");
  expect(row).not.toMatch(/>#7<\/a>/);
  expect(SHIP.linkPrs("see #5 or #05 or a#5", { "5": url }))
    .toBe(`see <a href="${url}" target="_blank" rel="noreferrer" draggable="false" data-pr="5">#5</a> or #05 or a#5`);
  expect(SHIP.linkPrs("it&#39;s #5", {})).toBe("it&#39;s #5");
  expect(SHIP.linkPrs("it&#39;s #5", null)).toBe("it&#39;s #5");
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
