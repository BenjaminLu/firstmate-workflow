// T-235: count real filesystem work inside one /api/state request. Unlike the
// race facade, this helper never changes an I/O result or injects an error.
export * from "node:fs";
import * as fs from "node:fs";
import { basename, join } from "node:path";
import { AsyncLocalStorage } from "node:async_hooks";

type Counts = { configStats: number; eventBytes: number };
const requests = new AsyncLocalStorage<Counts>();
// Match the board's canonical root, including macOS /var -> /private/var.
const root = fs.realpathSync(process.env.FM_ROOT!);
const config = join(root, "config.yaml");
const report = join(root, "state-cost.json");
const opened = new Map<number, fs.PathLike>();
const eventPath = (path: unknown) => typeof path === "string" && basename(path) === "events.jsonl";

export const statSync = (...args: Parameters<typeof fs.statSync>) => {
  const counts = requests.getStore();
  if (counts && String(args[0]) === config) counts.configStats++;
  return fs.statSync(...args);
};
export const readFileSync = (...args: Parameters<typeof fs.readFileSync>) => {
  const result = fs.readFileSync(...args);
  const counts = requests.getStore();
  const path = typeof args[0] === "number" ? opened.get(args[0]) : args[0];
  if (counts && eventPath(path)) counts.eventBytes += Buffer.byteLength(result);
  return result;
};
export const openSync = (...args: Parameters<typeof fs.openSync>) => {
  const fd = fs.openSync(...args);
  opened.set(fd, args[0]);
  return fd;
};
export const closeSync = (...args: Parameters<typeof fs.closeSync>) => {
  try { return fs.closeSync(...args); } finally { opened.delete(args[0]); }
};
export const readSync = (...args: Parameters<typeof fs.readSync>) => {
  const bytes = fs.readSync(...args);
  const counts = requests.getStore();
  if (counts && eventPath(opened.get(args[0]))) counts.eventBytes += bytes;
  return bytes;
};

// Keep the board's real handler and response intact. Request scope excludes
// startup, recovery timers and other clients; no per-stat disk logging distorts
// the base's hundreds of thousands of calls. /api/state is synchronous on both
// base and head, so the report is complete before the response reaches curl.
// Bun.serve has several websocket/TLS overloads; forward its options unchanged.
export function costServe(options: any) {
  const fetch = options.fetch;
  return Bun.serve({ ...options, fetch(req: Request, server: any) {
    const url = new URL(req.url);
    if (url.pathname !== "/api/state" || url.searchParams.get("cost_measure") !== "1")
      return fetch.call(this, req, server);
    const counts: Counts = { configStats: 0, eventBytes: 0 };
    return requests.run(counts, () => {
      try { return fetch.call(this, req, server); }
      finally { fs.writeFileSync(report, JSON.stringify(counts) + "\n"); }
    });
  } });
}
