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
const STAGE: Record<string, string> = {
  dispatched: "working", commit_pushed: "working", pr_opened: "review",
  gate_failed: "gate", gate_passed: "review", review_opened: "review",
  approved: "captain", merged: "merged", closed: "closed",
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
  const tasks = defs.map((d) => ({
    id: d.id, title: d.title, milestone: d.milestone,
    depends_on: d.depends_on ?? [],
    stage: stage.get(d.id as string) ?? "queued",
    pr: pr.get(d.id as string) ?? null,
  }));
  return {
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
