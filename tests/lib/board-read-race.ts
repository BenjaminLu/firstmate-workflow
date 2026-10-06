// Deterministic filesystem fault injection for board-live-stream.test.sh.
// Delegates to the real fs, moving a file/directory only during one call.
export * from "node:fs";
import * as fs from "node:fs";
import { join } from "node:path";
const marker = join(process.env.FM_ROOT!, "race.json");
function racing<T>(operation: string, path: unknown, read: () => T): T {
  let race;
  try { race = JSON.parse(fs.readFileSync(marker, "utf8")); } catch { return read(); }
  if (race.operation !== operation || race.path !== String(path)) return read();
  if (Number.isInteger(race.skip) && race.skip > 0) {
    fs.writeFileSync(marker, JSON.stringify({ ...race, skip: race.skip - 1 }));
    return read();
  }
  fs.unlinkSync(marker);
  if (race.error) throw Object.assign(new Error(`injected ${race.error}`), { code: race.error });
  const saved = String(path) + ".race-saved";
  fs.renameSync(String(path), saved);
  try { return read(); }
  finally { fs.renameSync(saved, String(path)); }
}
export const statSync = (...args: Parameters<typeof fs.statSync>) => racing("statSync", args[0], () => fs.statSync(...args));
export const readFileSync = (...args: Parameters<typeof fs.readFileSync>) => racing("readFileSync", args[0], () => fs.readFileSync(...args));
export const readdirSync = (...args: Parameters<typeof fs.readdirSync>) => racing("readdirSync", args[0], () => fs.readdirSync(...args));

// Descriptor reads still refer to the opened inode while its path is renamed.
// Remember the path so these calls exercise the same replacement contract.
const opened = new Map<number, fs.PathLike>();
export const openSync = (...args: Parameters<typeof fs.openSync>) => {
  const fd = racing("openSync", args[0], () => fs.openSync(...args));
  opened.set(fd, args[0]);
  return fd;
};
export const closeSync = (...args: Parameters<typeof fs.closeSync>) => {
  try { return fs.closeSync(...args); } finally { opened.delete(args[0]); }
};
export const fstatSync = (...args: Parameters<typeof fs.fstatSync>) => racing("fstatSync", opened.get(args[0]), () => fs.fstatSync(...args));
export const readSync = (...args: Parameters<typeof fs.readSync>) => racing("readSync", opened.get(args[0]), () => fs.readSync(...args));
export const lstatSync = (...args: Parameters<typeof fs.lstatSync>) => racing("lstatSync", args[0], () => fs.lstatSync(...args));
