// The board. Binds loopback only, serves one page, and streams the event log.
//
//   bun run board/server.ts            0.0.0.0 is never an option here
//   FM_PORT=4173 FM_ROOT=.             the log it tails is the one the crew writes
//
// No build step and no framework: the page is a file, the stream is SSE, and
// the state endpoint is derived from events.jsonl and design/tasks.json so the
// board has no opinion the log does not already hold.
import { existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, statSync, unlinkSync, watch, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

// canonical from the start: on macOS /var is a symlink to /private/var, and a
// path check that compares a resolved path against an unresolved root refuses
// every legitimate file in the repository
const ROOT = realpathSync(resolve(process.env.FM_ROOT ?? "."));
const PORT = Number(process.env.FM_PORT ?? 4173);
const LOG = join(ROOT, "state/events.jsonl");
const PUBLIC = join(ROOT, "board/public");

type Event = Record<string, unknown> & { type?: string; task?: string; pr?: number };

const readEvents = (): Event[] => {
  if (!existsSync(LOG)) return [];
  return readFileSync(LOG, "utf8")
    .split("\n")
    .filter((l) => l.trim() !== "")
    .flatMap((l) => { try { return [JSON.parse(l) as Event]; } catch { return []; } });
};

// A task's state is whatever the log last said about it. The board never
// decides; it reports.
// What a crewman is, declared: every field on every entry, so a missing
// one is a type error rather than an `undefined` the client happens to
// tolerate. The state is a closed set because the client turns it into a
// class name, a dictionary key and a progress number - an open one meant
// an actor on a blocked task reached the page as `st-blocked`, which no
// stylesheet rule and no dictionary key covers.
const DECK_LIMIT = 24;   // what the ship holds; the page reads it back
type CrewState = "queued" | "working" | "gate" | "review" | "captain";
type Crew = {
  id: string;
  role: "firstmate" | "worker" | "reviewer";
  state: CrewState;
  task: string | null;
  title: string | null;
};
const CREW_STATE = (s: string | undefined): CrewState =>
  s === "queued" || s === "working" || s === "gate" || s === "review" || s === "captain"
    ? s : "working";

const STAGE: Record<string, string> = {
  dispatched: "working", commit_pushed: "working", pr_opened: "review",
  gate_failed: "gate", gate_passed: "review", review_opened: "review",
  approved: "captain", decision_requested: "captain",
  merged: "merged", closed: "closed",
  // a task whose review never happened, or whose worker died, is blocked -
  // it must not sit in a lane that says work is under way
  review_failed: "gate", worker_crashed: "gate",
};

const state = () => {
  const events = readEvents();
  const tasksFile = join(ROOT, "design/tasks.json");
  const defs = existsSync(tasksFile)
    ? (JSON.parse(readFileSync(tasksFile, "utf8")).tasks as Array<Record<string, unknown>>)
    : [];
  const stage = new Map<string, string>();
  const pr = new Map<string, number>();
  // merged and closed are where a task stops. Anything said about it
  // afterwards - a review round run against the branch, a late sync - is
  // about work that is already in, and letting it move the task back reads
  // as work in progress that nobody is doing.
  const FINAL = new Set(["merged", "closed"]);
  for (const e of events) {
    if (!e.task) continue;
    if (FINAL.has(stage.get(e.task) ?? "")) continue;
    const s = STAGE[e.type ?? ""];
    if (s) stage.set(e.task, s);
    if (typeof e.pr === "number") pr.set(e.task, e.pr);
  }
  // A pending decision is a fact on disk, not a point in a history: while
  // the card is up, the task is the captain's whatever else has been said
  // since. T-016 read as "working" because a dispatch that should never
  // have happened landed after the card went up.
  const awaiting = new Set(pending().map((p: Record<string, unknown>) => String(p.task ?? "")));
  const tasks = defs.map((d) => ({
    id: d.id, title: d.title, milestone: d.milestone,
    depends_on: d.depends_on ?? [],
    stage: awaiting.has(d.id as string) ? "captain" : (stage.get(d.id as string) ?? "queued"),
    pr: pr.get(d.id as string) ?? null,
  }));
  // The crew are AGENTS, not tasks. A crewman on the deck is something
  // that is running: firstmate, each worker or reviewer currently engaged,
  // and the captain while a decision is waiting. Drawing one figure per
  // in-flight task put pull requests on the deck instead - three tasks
  // handled by one worker looked like three of the crew, and the ship's
  // rate followed the backlog rather than the concurrency.
  //
  // An agent is engaged when the last thing it did concerns a task that is
  // not finished. github is the sync, not an agent, and is never aboard.
  // firstmate included: it is an agent like the others and it does work
  // of its own. Pinning it to "dispatching" was the board saying what the
  // role is for rather than what the agent is doing, and it is the one
  // crewman a reader most wants to be told the truth about.
  // Aboard means RUNNING. An actor whose last word was agent_finished has
  // gone home, whatever became of the task: without that, "aboard" meant
  // "ever touched a task that is not finished yet", a worker that died at
  // a gate was drawn working for ever, and the rate followed the history
  // rather than what is happening now.
  const lastByActor = new Map<string, Event>();
  for (const e of events) {
    if (!e.actor || e.actor === "github" || e.actor === "captain") continue;
    lastByActor.set(e.actor, e);
  }
  for (const [actor, e] of [...lastByActor]) {
    if (e.type === "agent_finished") lastByActor.delete(actor);
  }
  const done = new Set(tasks.filter((t) => ["merged", "closed"].includes(t.stage))
                            .map((t) => t.id as string));
  // firstmate carries its task like anyone else. Pinning it to
  // "dispatching" was the board saying what the role is FOR rather than
  // what the agent is DOING - and firstmate is the crewman a reader most
  // wants the truth about, because it is the one that works off the board.
  // firstmate is always ABOARD - it is the one that dispatches, so the
  // ship is never empty - but everything else about it is read the same
  // way as any other agent: its task if it has one, nothing if its run
  // ended. Two comments used to argue it was "an agent like the others"
  // while the code exempted it; this is the exemption, named and narrow.
  const fm = lastByActor.get("firstmate");
  const fmTask = fm?.task && !done.has(fm.task) ? fm.task : null;
  const fmT = fmTask ? tasks.find((x) => x.id === fmTask) : undefined;
  const crew: Crew[] = [{
    id: "firstmate", role: "firstmate",
    state: !events.some((e) => e.type === "greenlit") ? "queued"
         : CREW_STATE(fmT?.stage),
    task: fmTask, title: fmT?.title ?? null,
  }];
  for (const [actor, e] of lastByActor) {
    if (actor === "firstmate") continue;   // already aboard, above
    const task = e.task ?? null;
    if (!task || done.has(task)) continue;
    const t = tasks.find((x) => x.id === task);
    crew.push({
      id: actor,
      role: actor.startsWith("reviewer") ? "reviewer" : "worker",
      state: CREW_STATE(t?.stage),
      task, title: t?.title ?? null,
    });
  }
  // no captain here on purpose. He is not crew - the crew are agents
  // doing work and he is the person they are waiting on - and he is drawn
  // beside the cards from the same pending deck the cards come from. The
  // first version emitted him here AND re-derived him on the page, which
  // is the two sources this file argues against three comments above.

  return {
    // The deck holds this many. One number: the server truncates and
    // tells the page what the limit was, rather than both of them
    // knowing 24 - truncating only on the client also left the server
    // building an unbounded array into every payload.
    deckLimit: DECK_LIMIT,
    crew: crew.slice(0, DECK_LIMIT),
    greenlit: events.some((e) => e.type === "greenlit"),
    counts: {
      merged: tasks.filter((t) => t.stage === "merged").length,
      inflight: tasks.filter((t) => ["working", "review"].includes(t.stage)).length,
      blocked: tasks.filter((t) => t.stage === "gate").length,
      queued: tasks.filter((t) => t.stage === "queued").length,
    },
    tasks,
    recent: events.slice(-40).reverse(),
    pending: pending(),
  };
};

// Decisions the captain has been asked for but has not answered.
// A card for a pull request that is already merged is the board lying. It
// happens whenever a merge goes through some other way - a decision file
// outlives the thing it was asking about - and the captain is then offered
// a choice that cannot be made.
const pending = () => {
  const dir = join(ROOT, "state/pending");
  if (!existsSync(dir)) return [];
  const settled = new Set(
    readEvents()
      .filter((e) => e.type === "merged" || e.type === "closed")
      .map((e) => String((e as Record<string, unknown>).pr ?? "")),
  );
  return readdirSync(dir).filter((f) => f.endsWith(".json")).flatMap((f) => {
    try {
      const d = JSON.parse(readFileSync(join(dir, f), "utf8"));
      if (d.pr != null && settled.has(String(d.pr))) return [];
      return [d];
    } catch { return []; }
  });
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

const serveFile = (name: string) => {
  const p = join(PUBLIC, name);
  if (!p.startsWith(PUBLIC) || !existsSync(p)) return new Response("not found", { status: 404 });
  const type = name.endsWith(".css") ? "text/css"
    : name.endsWith(".js") ? "text/javascript" : "text/html; charset=utf-8";
  return new Response(readFileSync(p), { headers: { "content-type": type } });
};

const server = Bun.serve({
  hostname: "127.0.0.1",          // never 0.0.0.0: this board is for one machine
  port: PORT,
  fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/api/state") return json(state());

    // the dictionaries, plus the table that derives zh-CN from zh-TW
    if (url.pathname === "/api/i18n") {
      const dir = join(ROOT, "i18n");
      const read = (f: string) =>
        existsSync(join(dir, f)) ? JSON.parse(readFileSync(join(dir, f), "utf8")) : {};
      const table = existsSync(join(dir, "tw2cn.tsv"))
        ? readFileSync(join(dir, "tw2cn.tsv"), "utf8").split("\n")
            .filter((l) => l.trim() !== "" && !l.startsWith("#"))
            .map((l) => l.split("\t")).filter((p) => p.length === 2)
        : [];
      return json({ en: read("ui.en.json"), "zh-TW": read("ui.zh-TW.json"), tw2cn: table });
    }

    if (url.pathname === "/events") {
      let stop = () => {};
      const stream = new ReadableStream({
        start(c) {
          const enc = new TextEncoder();
          const send = (event: string, data: unknown) =>
            c.enqueue(enc.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`));
          send("state", state());
          let size = existsSync(LOG) ? statSync(LOG).size : 0;
          const poll = setInterval(() => {
            const now = existsSync(LOG) ? statSync(LOG).size : 0;
            if (now !== size) { size = now; send("state", state()); }
          }, 500);
          const beat = setInterval(() => c.enqueue(enc.encode(": beat\n\n")), 15000);
          // a change to the page itself reloads every open board
          const w = existsSync(PUBLIC) ? watch(PUBLIC, () => send("reload", {})) : null;
          stop = () => { clearInterval(poll); clearInterval(beat); w?.close(); };
        },
        cancel() { stop(); },
      });
      return new Response(stream, {
        headers: { "content-type": "text/event-stream", "cache-control": "no-cache" },
      });
    }

    // The captain answers. The board writes the answer down and, for a merge,
    // calls the one script allowed to merge - it never shells out ad hoc.
    if (url.pathname === "/decisions" && req.method === "POST") {
      return req.json().then(async (body: any) => {
        const id = String(body?.id ?? "");
        const chosen = String(body?.chosen ?? "");
        if (!/^D-[0-9]{1,6}$/.test(id)) return json({ error: "bad decision id" }, 400);
        if (!/^[A-Z]$/.test(chosen)) return json({ error: "bad choice" }, 400);

        const p = pending().find((d: any) => d.id === id);
        const dir = join(ROOT, "state/decisions");
        mkdirSync(dir, { recursive: true });
        const file = join(dir, `${id}.json`);
        if (existsSync(file)) return json({ ok: true, already: true });
        writeFileSync(file, JSON.stringify({
          id, chosen, task: p?.task ?? null, kind: p?.kind ?? "choice",
          note: typeof body?.note === "string" ? body.note.slice(0, 500) : "",
          ts: new Date().toISOString(),
        }) + "\n");

        let merged = null;
        if (p?.kind === "merge" && chosen === "A" && typeof p.pr === "number") {
          const r = Bun.spawnSync([join(ROOT, "bin/fm-merge.sh"),
            "--pr", String(p.pr), ...(p.task ? ["--task", p.task] : []), "--repo", ROOT],
            { env: { ...process.env, FM_ROOT: ROOT } });
          merged = { ok: r.exitCode === 0, out: new TextDecoder().decode(r.stdout).trim() };
        }
        const pf = join(ROOT, "state/pending", `${id}.json`);
        if (existsSync(pf)) unlinkSync(pf);
        return json({ ok: true, merged });
      }).catch(() => json({ error: "bad request" }, 400));
    }

    // Hand a file to the editor, or show it. Both refuse anything that does
    // not resolve inside the repository, and both refuse a caller that is not
    // on this machine - the board binds loopback, but a browser on it can be
    // pointed anywhere by a page the captain did not write.
    const localOnly = (r: Request) => {
      const h = new URL(r.url).hostname;
      return h === "127.0.0.1" || h === "localhost" || h === "::1";
    };
    // one check for every endpoint that takes a path: resolve it fully, then
    // insist the real thing sits inside the real root. Three copies of this
    // is three chances to write it differently.
    const inside = (p: string) => {
      if (p === "") return null;
      const abs = resolve(ROOT, p);
      if (!existsSync(abs)) return null;
      const real = realpathSync(abs);
      return real === ROOT || real.startsWith(ROOT + "/") ? real : null;
    };

    if (url.pathname === "/open") {
      if (!localOnly(req)) return json({ error: "localhost only" }, 403);
      const abs = inside(url.searchParams.get("path") ?? "");
      if (!abs) return json({ error: "outside the repository" }, 403);
      const editor = (readFileSync(join(ROOT, "config.yaml"), "utf8")
        .match(/^editor:\s*([^\s#]+)/m)?.[1] ?? "code");
      Bun.spawn([editor, abs], { stdout: "ignore", stderr: "ignore" });
      return json({ ok: true, opened: abs, editor });
    }

    if (url.pathname === "/file") {
      if (!localOnly(req)) return json({ error: "localhost only" }, 403);
      const abs = inside(url.searchParams.get("path") ?? "");
      if (!abs) return json({ error: "outside the repository" }, 403);
      if (statSync(abs).size > 512 * 1024) return json({ error: "too large to show" }, 413);
      return new Response(readFileSync(abs), { headers: { "content-type": "text/plain; charset=utf-8" } });
    }

    if (url.pathname === "/diff") {
      if (!localOnly(req)) return json({ error: "localhost only" }, 403);
      const branch = url.searchParams.get("branch") ?? "";
      if (!/^[A-Za-z0-9._\/-]{1,120}$/.test(branch)) return json({ error: "bad branch" }, 400);
      const r = Bun.spawnSync(["git", "-C", ROOT, "diff", `main...${branch}`], {});
      if (r.exitCode !== 0) return json({ error: "no such branch" }, 404);
      return new Response(r.stdout, { headers: { "content-type": "text/plain; charset=utf-8" } });
    }

    if (url.pathname === "/" || url.pathname === "") return serveFile("index.html");
    return serveFile(url.pathname.replace(/^\//, ""));
  },
});
console.log(`board on http://127.0.0.1:${server.port}  root=${ROOT}`);
