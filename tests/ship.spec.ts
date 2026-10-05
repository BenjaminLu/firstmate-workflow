// Crew roster behavior and shared board helpers, independent of the voyage.
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

test("removing the ship preserves decision controls and page-wide reduced motion", () => {
  const css = CSS.replace(/\s+/g, "");
  for (const rule of [
    '.acts{flex-wrap:wrap}',
    '.acts .tradeoffs,.acts label{width:100%}',
    '.acts textarea{display:block;width:100%;min-height:80px}',
    '.acts [aria-pressed="true"]{outline:2px solid var(--brass)}',
    '.acts [hidden]{display:none}',
    '#orderFeedback{white-space:pre-wrap;overflow-wrap:anywhere}',
    '.change-fallback{display:flex;align-items:center;gap:16px}',
    '.change-fallback section{flex:1}',
    '.change-fallback[hidden]{display:none}',
    '@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}',
  ]) expect(css).toContain(rule.replace(/\s+/g, ""));
});

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

test("every state a crewman can be in is styled and named", () => {
  const en = JSON.parse(readFileSync(join(ROOT, "i18n/ui.en.json"), "utf8"));
  const states = new Set<string>();
  for (const st of ["working", "gate", "review", "captain", "queued", "waiting_ci", "unknown"]) {
    for (const c of SHIP.crewOf({ ...state(3, st), pending: [{ id: "d" }] }, T)) states.add(c.state);
  }
  for (const s of states) {
    expect(CSS).toContain(`.roster li.st-${s}`);
    expect(CSS).toContain(`st-${s}`);
    // the roster names it from the dictionary, so it is switchable
    expect(en["lane" + s[0].toUpperCase() + s.slice(1)]).toBeTruthy();
  }
});

// Unknown roles remain a visible mismatch in roster rows.
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
    expect(CSS).toContain(`.roster li[data-role="${k}"]`);
  }
  // and it reaches the page loudly: a crewman the server sent with a
  // role this page has never heard of
  const s = state(1);
  (s.crew[1] as { role: string }).role = "quartermaster";
  expect(SHIP.crewOf(s, T)[1].role).toBe("unknown");
  const h = host();
  SHIP.roster(h as never, SHIP.crewOf(s, T), T);
  expect(h.innerHTML).toContain('data-role="unknown"');
  expect(h.innerHTML).not.toContain('data-role="w"');
});

test("state and role reach the roster rows", () => {
  const h = host();
  const crew = SHIP.crewOf(state(4, "review"), T);
  SHIP.roster(h, crew, T);
  expect(crew).toHaveLength(5);
  expect([...h.innerHTML.matchAll(/<li class="rrow /g)]).toHaveLength(5);
  expect([...h.innerHTML.matchAll(/class="rrow st-review"/g)]).toHaveLength(4);
  expect(h.innerHTML).toContain('data-role="fm"');
  expect([...h.innerHTML.matchAll(/data-role="r"/g)]).toHaveLength(4);
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


test("the board exposes roster helpers without a second ship or effect queue", () => {
  for (const name of ["render", "enqueue", "captain"]) expect(SHIP).not.toHaveProperty(name);
});

test("roster retains CLI, CI window and project chips with explicit roles", () => {
  for (const projects of [["alpha"], ["alpha", "beta"]]) {
    const s: any = state(1, "waiting_ci");
    s.projects = projects; s.default_project = "alpha";
    s.crew[1].cli_version = "test-cli 2.0";
    const h = host(); SHIP.roster(h, SHIP.crewOf(s, T), T);
    expect(h.innerHTML).toContain('class="rc" data-label="crewCli">test-cli 2.0');
    expect(h.innerHTML).toContain('class="cwindow" data-label="crewWindow">ciNoWindow');
    expect(h.innerHTML).toContain('data-role="w"');
    expect(h.innerHTML.includes('class="pj pchip"')).toBe(projects.length > 1);
  }
});
