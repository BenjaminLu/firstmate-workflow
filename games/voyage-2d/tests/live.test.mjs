// Live mode's kraken, against recorded board events (tests/fixtures/board-events.jsonl is a
// slice of firstmate-workflow's own state/events.jsonl: every lifecycle event of T-035, T-048,
// T-054 and T-067), plus small made-up logs for the rules the record never exercised.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { KRAKEN, reviewRounds, krakenFromEvents } from "../src/live.js";

const DEF = "firstmate-workflow";
const LOG = readFileSync(new URL("./fixtures/board-events.jsonl", import.meta.url), "utf8").trim().split("\n").map((l) => JSON.parse(l));
const lostBefore = (key, at) => LOG.slice(0, at + 1).filter((e) => `${e.project || DEF}/${e.task}` === key && e.type === "review_failed" && e.data?.review_outcome === "rejected").length;

test("rounds are counted from the board's own review events, per task", () => {
  const r = reviewRounds(LOG, { defaultProject: DEF });
  const t35 = r.get(`${DEF}/T-035`), t54 = r.get(`${DEF}/T-054`);
  assert.equal(t35.rounds, LOG.filter((e) => e.task === "T-035" && e.type === "review_opened").length);
  assert.equal(t35.lost, 5);
  assert.equal(t35.final, "merged");
  assert.equal(t54.lost, 16);
  assert.equal(t54.approvals, 2);
  assert.equal(t54.lostSince, 0, "an approval starts the count again");
  // an event naming the default project and one naming none are the same task
  assert.ok(![...r.keys()].some((k) => k.startsWith("/")));
});

test("recorded log: an arm grabs at the third lost round and lets go on approval, merge or drop", () => {
  const k = krakenFromEvents(LOG, { defaultProject: DEF });
  const arms = k.happened.filter((h) => h.type === "kraken_arm");
  for (const a of arms) {
    assert.equal(LOG[a.at].type, "review_failed");
    assert.equal(LOG[a.at].data.review_outcome, "rejected");
  }
  // T-035's arm comes with its third rejection overall (it was never approved before)
  const a35 = arms.find((a) => a.task === `${DEF}/T-035`);
  assert.equal(lostBefore(`${DEF}/T-035`, a35.at), 3);
  const go35 = k.happened.find((h) => h.type === "kraken_let_go" && h.task === `${DEF}/T-035`);
  assert.deepEqual([go35.why, go35.victory, LOG[go35.at].type], ["merged", false, "merged"]);
  // T-067: beaten by a real approval (the finisher's unlock), then grabbed again only after
  // three fresh lost rounds, and let go for good when it merged
  const t67 = k.happened.filter((h) => h.task === `${DEF}/T-067`).map((h) => [h.type, h.why || h.round]);
  assert.deepEqual(t67, [["kraken_arm", 3], ["kraken_let_go", "approved"], ["kraken_arm", 3], ["kraken_let_go", "merged"]]);
  assert.equal(k.happened.find((h) => h.why === "approved" && h.task === `${DEF}/T-067`).victory, true);
  // at the end of the record nothing is held: every task was settled
  assert.deepEqual(k.arms, []);
});

const ev = (type, task, extra = {}) => ({ type, task, ...extra });
const reject = (task) => ev("review_failed", task, { data: { review_outcome: "rejected" } });

test("parked and dropped let go; infrastructure failures are not lost rounds; a settled task never grabs again", () => {
  const log = [
    reject("T-1"), reject("T-1"), ev("review_failed", "T-1", { data: { review_outcome: "infrastructure_error" } }), reject("T-1"),
    reject("T-2"), reject("T-2"), reject("T-2"),
    ev("parked", "T-1"), ev("closed", "T-2"),
    reject("T-2"), reject("T-2"), reject("T-2"),
  ];
  const k = krakenFromEvents(log);
  assert.deepEqual(k.happened.map((h) => [h.type, h.task, h.why || h.round]), [
    ["kraken_arm", "/T-1", 3], ["kraken_arm", "/T-2", 3], ["kraken_let_go", "/T-1", "parked"], ["kraken_let_go", "/T-2", "dropped"],
  ]);
  assert.deepEqual(k.arms, []);
  // a parked task that comes back and loses three more rounds is grabbed again
  const again = krakenFromEvents([...log, ev("unparked", "T-1"), reject("T-1"), reject("T-1")]);
  assert.deepEqual(again.arms, []);
  assert.deepEqual(krakenFromEvents([...log, ev("unparked", "T-1"), reject("T-1"), reject("T-1"), reject("T-1")]).arms, ["/T-1"]);
});

test("one arm per task up to the cap; the next task waits for a free arm", () => {
  const log = [];
  for (let i = 1; i <= KRAKEN.maxArms + 1; i++) for (let r = 0; r < 3; r++) log.push(reject(`T-${i}`));
  let k = krakenFromEvents(log);
  assert.equal(k.arms.length, KRAKEN.maxArms);
  assert.deepEqual(k.waiting, [`/T-${KRAKEN.maxArms + 1}`]);
  k = krakenFromEvents([...log, reject("T-1"), ev("approved", "T-3")]);
  assert.equal(k.arms.length, KRAKEN.maxArms);
  assert.ok(k.arms.includes(`/T-${KRAKEN.maxArms + 1}`) && !k.arms.includes("/T-3"), "the freed arm takes the waiting task");
  assert.equal(k.arms.filter((a) => a === "/T-1").length, 1, "one arm per task");
  // two projects' T-1 are two tasks
  assert.equal(krakenFromEvents([...[0, 1, 2].map(() => reject("T-1")), ...[0, 1, 2].map(() => ({ ...reject("T-1"), project: "other" }))]).arms.length, 2);
});

test("the Live kraken reads the log and writes nothing", () => {
  const src = readFileSync(new URL("../src/live.js", import.meta.url), "utf8");
  for (const bad of ["fetch(", "XMLHttpRequest", "WebSocket", "sendBeacon", "EventSource"]) assert.ok(!src.includes(bad), bad);
  const log = [reject("T-9"), reject("T-9"), reject("T-9")];
  const copy = JSON.stringify(log);
  krakenFromEvents(log);
  assert.equal(JSON.stringify(log), copy, "the events are not changed");
});
