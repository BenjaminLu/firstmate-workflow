// The board. Binds loopback only, serves one page, and streams the event log.
//
//   bun run board/server.ts            0.0.0.0 is never an option here
//   FM_PORT=4173 FM_ROOT=.             the log it tails is the one the crew writes
//
// No build step and no framework: the page is a file, the stream is SSE, and
// the state endpoint is derived from events.jsonl and design/tasks.json so the
// board has no opinion the log does not already hold.
import { existsSync, readFileSync, statSync, watch } from "node:fs";
import { join, resolve } from "node:path";

const ROOT = resolve(process.env.FM_ROOT ?? ".");
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
};

const state = () => {
  const events = readEvents();
  const tasksFile = join(ROOT, "design/tasks.json");
  const defs = existsSync(tasksFile)
    ? (JSON.parse(readFileSync(tasksFile, "utf8")).tasks as Array<Record<string, unknown>>)
    : [];
  const stage = new Map<string, string>();
  const pr = new Map<string, number>();
  for (const e of events) {
    if (!e.task) continue;
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
  };
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

    if (url.pathname === "/" || url.pathname === "") return serveFile("index.html");
    return serveFile(url.pathname.replace(/^\//, ""));
  },
});
console.log(`board on http://127.0.0.1:${server.port}  root=${ROOT}`);
