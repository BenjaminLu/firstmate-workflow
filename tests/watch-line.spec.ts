// T-137: the board's line saying whether firstmate is watched, rendered by
// board/public/watch.js - the function the page itself runs - through each
// dictionary, so what is asserted is the text the captain reads.
import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const WATCH = createRequire(import.meta.url)(join(ROOT, "board/public/watch.js"));
const dict = (lang: string) => JSON.parse(readFileSync(join(ROOT, `i18n/ui.${lang}.json`), "utf8"));
const EN = dict("en"), TW = dict("zh-TW");
// the page's t(): a key a dictionary lacks comes back as the key itself
const tOf = (d: Record<string, string>) => (k: string) => d[k] ?? k;

const watched = { alive: true, beaconAge: 42, gen: 3, since: "2026-09-29T10:00:00Z",
  lastWake: { ts: "2026-09-29T10:05:00Z", reason: "review: T-134 APPROVE 4ea1ec2" }, waiting: 0, gap: null };
const blind = { alive: false, beaconAge: null, gen: 3, since: null, lastWake: null, waiting: 2,
  gap: { since: "2026-09-29T09:00:00Z", inflight: 3 } };

test("a watched firstmate reads as watched, with the last wake and its reason, in English", () => {
  const line = WATCH.watchLine(watched, tOf(EN));
  expect(line.state).toBe("on");
  expect(line.parts).toEqual([
    "Firstmate is watched (watcher up 42s)",
    "last wake: review: T-134 APPROVE 4ea1ec2 (2026-09-29T10:05:00Z)",
  ]);
  expect(line.gap).toBeNull();
});

test("and in Traditional Chinese", () => {
  const line = WATCH.watchLine(watched, tOf(TW));
  expect(line.parts).toEqual([
    "大副正被看守（看守者已運作 42 秒）",
    "上次喚醒：review: T-134 APPROVE 4ea1ec2（2026-09-29T10:05:00Z）",
  ]);
});

test("a blind firstmate reads as not watched, with what waits and the open gap, in both languages", () => {
  const en = WATCH.watchLine(blind, tOf(EN));
  expect(en.state).toBe("off");
  expect(en.parts).toEqual(["Firstmate is NOT watched", "no wake yet", "2 wake(s) waiting for the next turn"]);
  expect(en.gap).toBe("gap: 3 in flight and no watcher since 2026-09-29T09:00:00Z");
  const tw = WATCH.watchLine(blind, tOf(TW));
  expect(tw.parts).toEqual(["大副目前沒有人看守", "尚未喚醒過", "2 則喚醒等候下一回合"]);
  expect(tw.gap).toBe("缺口：3 項進行中卻沒有看守者，自 2026-09-29T09:00:00Z 起");
});

test("a gap with no known start still says so", () => {
  const gap = { ...blind, waiting: 0, gap: { since: null, inflight: 1 } };
  expect(WATCH.watchLine(gap, tOf(EN)).gap).toBe("gap: 1 in flight and no watcher");
  expect(WATCH.watchLine(gap, tOf(TW)).gap).toBe("缺口：1 項進行中卻沒有看守者");
  expect(WATCH.watchLine(gap, tOf(EN)).parts).toHaveLength(2);
});
