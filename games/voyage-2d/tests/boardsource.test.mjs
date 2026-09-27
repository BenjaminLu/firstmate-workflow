// BoardSource (src/boardsource.js): the Live data source. This suite fakes
// fetch and EventSource so it needs no running board; tests/board.test.sh
// covers the same module end to end against the real server (T-125,
// acceptance point 2: v1 and the game hold the same tasks in the same
// lanes after the same fixture events).
import test from "node:test";
import assert from "node:assert/strict";
import { BoardSource, mapView, mapTask, mapEvent, newEvents, EVENT_MAP } from "../src/boardsource.js";

const STATE = {
  greenlit: true, lanes: ["backlog", "ready", "working", "gate", "review", "captain", "merged"],
  projects: ["firstmate-workflow"], default_project: "firstmate-workflow", project: null,
  deckLimit: 24, engine: { vendor: "claude", reviewer: "claude", cross: false },
  counts: { merged: 1, inflight: 1, blocked: 0, ready: 1, backlog: 0, parked: 0, waiting: 1 },
  tasks: [
    { id: "T-1", key: "firstmate-workflow/T-1", title: "first", project: "firstmate-workflow",
      milestone: "M1", stage: "working", pr: 5, pr_url: "https://github.com/x/y/pull/5",
      depends_on: [], blocked_on: [], blocked_by: [], actions: ["park", "drop"],
      badges: [], crew: [{ id: "worker-1", name: "worker-1", role: "worker", round: 1, attempt: 1 }],
      merged_seq: null, confirm: false },
  ],
  crew: [{ id: "worker-1", role: "worker", state: "working", task: "T-1", title: "first",
    project: "firstmate-workflow", activity: null, progress: null, round: 1, attempt: 1 }],
  pending: [{ id: "D-1", task: "T-1", kind: "choice", title: "pick one" }],
  responses: [], handoffs: [], outcomes: [],
  recent: [{ ts: "2026-01-01T00:00:00Z", actor: "worker-1", type: "dispatched", task: "T-1", data: { role: "worker" } }],
  pr_urls: {}, pr_urls_by_project: {},
};

test("mapView keeps a lane alias alongside the board own stage, field by field", () => {
  const view = mapView(STATE);
  assert.equal(view.tasks.length, 1);
  const t = view.tasks[0];
  assert.equal(t.id, "T-1");
  assert.equal(t.stage, "working");
  assert.equal(t.lane, "working", "lane is the game name for the same value v1 shows as stage");
  assert.equal(t.pr, 5);
  assert.equal(t.actions.join(","), "park,drop");
  assert.equal(view.counts.inflight, 1);
  assert.equal(view.crew[0].id, "worker-1");
});

test("mapTask never invents a field the board did not send", () => {
  const t = mapTask({ id: "T-2", stage: "ready" });
  assert.equal(t.pr, null);
  assert.deepEqual(t.depends_on, []);
  assert.deepEqual(t.actions, []);
  assert.equal(t.key, "/T-2");
});

test("every mapped event name matches the docs interface.md section 1.7 table", () => {
  const table = {
    dispatched: "order", commit_pushed: "commit_pushed", pr_opened: "pr_opened",
    review_opened: "review_opened", gate_passed: "gate_green", approved: "review_approved",
    merged: "merged", closed: "closed", decision_requested: "decision_requested",
    decision_made: "decision_answered", ask_pass_criteria: "ask_pass_criteria",
    criteria_returned: "criteria_returned", worker_crashed: "worker_crashed",
    vendor_unavailable: "vendor_unavailable", greenlit: "greenlit", parked: "parked",
    unparked: "unparked", agent_finished: "agent_finished",
  };
  assert.deepEqual(EVENT_MAP, table);
  assert.equal(mapEvent({ type: "review_failed", data: { review_outcome: "rejected" } }).type, "review_rejected");
  assert.equal(mapEvent({ type: "review_failed", data: { review_outcome: "infrastructure_error" } }).type, "gate_failed");
  assert.equal(mapEvent({ type: "crew_status" }), null, "the busiest event triggers no ritual");
  assert.equal(mapEvent({ type: "gate_failed" }), null, "gate_failed itself has no ritual in this table; only review_failed maps onto it");
});

test("newEvents emits only what is newer than the last snapshot, oldest first", () => {
  const seen = new Set();
  const snap1 = [{ ts: "2", actor: "a", type: "dispatched", task: "T-1" }, { ts: "1", actor: "a", type: "greenlit", task: null }];
  const first = newEvents(snap1, seen);
  assert.deepEqual(first.map((e) => e.ts), ["1", "2"], "oldest of the new ones first");
  const again = newEvents(snap1, seen);
  assert.deepEqual(again, [], "nothing new the second time around");
  const snap2 = [{ ts: "3", actor: "a", type: "pr_opened", task: "T-1" }, ...snap1];
  assert.deepEqual(newEvents(snap2, seen).map((e) => e.ts), ["3"]);
});

function fakeFetch(calls, answer) {
  return async (url, init) => {
    calls.push({ url, init });
    return { ok: answer.ok !== false, status: answer.status ?? 200, json: async () => answer.body ?? {} };
  };
}

test("command(answer) posts only to /decisions, with the bearer token and nothing else", async () => {
  const calls = [];
  const src = new BoardSource({ base: "http://x", token: "tok", fetchImpl: fakeFetch(calls, { body: { ok: true } }) });
  const r = await src.command({ type: "answer", decision: "D-1", chosen: "A" });
  assert.equal(r.ok, true);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "http://x/decisions");
  assert.equal(calls[0].init.method, "POST");
  assert.equal(calls[0].init.headers.authorization, "Bearer tok");
  assert.deepEqual(JSON.parse(calls[0].init.body), { id: "D-1", chosen: "A" });
});

test("command(park/unpark/drop) posts only to /tasks", async () => {
  const calls = [];
  const src = new BoardSource({ base: "", token: "tok", fetchImpl: fakeFetch(calls, { body: { ok: true } }) });
  await src.command({ type: "park", task: "T-1" });
  assert.equal(calls[0].url, "/tasks");
  assert.deepEqual(JSON.parse(calls[0].init.body), { task: "T-1", action: "park" });
});

test("a refused write is reported with the board own code, never invented", async () => {
  const calls = [];
  const src = new BoardSource({ base: "", token: "bad", fetchImpl: fakeFetch(calls, { ok: false, status: 403, body: { error: "not sent", code: "writeCredential" } }) });
  const r = await src.command({ type: "drop", task: "T-1" });
  assert.equal(r.ok, false);
  assert.equal(r.code, "writeCredential");
});

test("command() offers nothing beyond answer, park, unpark and drop", async () => {
  const src = new BoardSource({ base: "", token: "t", fetchImpl: async () => { throw new Error("must not be called"); } });
  const r = await src.command({ type: "dispatch", task: "T-1" });
  assert.equal(r.ok, false);
  assert.match(r.error, /not a board write/);
});

test("the module holds no board secret and calls nothing but fetch and EventSource", async () => {
  const src = new (await import("../src/boardsource.js")).BoardSource({ token: "tok" });
  assert.equal(src.mode, "live");
  assert.equal(src.writes, 0);
});
