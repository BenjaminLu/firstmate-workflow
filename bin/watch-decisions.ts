// Blocks until a decision file appears, then prints its path and exits.
// fs.watch is what makes the board feel instant; the shell falls back to a
// one-second poll when bun is not installed, which is the only reason this
// file is allowed to be the fast path rather than the only path.
const dir = process.argv[2];
const want = process.argv[3] ?? "";
const timeoutMs = Number(process.argv[4] ?? "0");

import { existsSync, mkdirSync, readdirSync, watch } from "node:fs";
mkdirSync(dir, { recursive: true });

const hit = (name: string) =>
  name.endsWith(".json") && (want === "" || name === `${want}.json`);

const already = readdirSync(dir).find(hit);
if (already) { console.log(`${dir}/${already}`); process.exit(0); }

let done = false;
const finish = (p: string | null) => {
  if (done) return;
  done = true;
  if (p) { console.log(p); process.exit(0); }
  process.exit(1);
};

const w = watch(dir, (_e, name) => {
  if (name && hit(name) && existsSync(`${dir}/${name}`)) { w.close(); finish(`${dir}/${name}`); }
});
if (timeoutMs > 0) setTimeout(() => { w.close(); finish(null); }, timeoutMs);
