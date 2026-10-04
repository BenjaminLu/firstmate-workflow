// Voyage configuration: the values the live board would read from config.yaml
// and the project registry (T-086 README, "Config"), plus the game's timings.
export const CONFIG = Object.freeze({
  project: "firstmate-workflow",
  home: "Portsmouth",
  ports: Object.freeze([
    { id: "M0", name: "Port Royal" },
    { id: "M1", name: "Tortuga" },
    { id: "M2", name: "Nassau" },
    { id: "M3", name: "Havana" },
    { id: "M4", name: "Cartagena" },
  ]),
  ranks: Object.freeze({
    worker: [
      ["deckhand", 0],
      ["able seaman", 3],
      ["bosun's mate", 10],
      ["bosun", 25],
      ["quartermaster", 50],
    ],
    first_pass_bonus: 0.5,
    reviewer: [
      ["apprentice inspector", 0],
      ["inspector", 10],
      ["chief inspector", 40],
    ],
  }),
  kraken: Object.freeze({ from_round: 3, max_arms: 8 }),
  // game pacing (seconds of simulated time)
  timing: Object.freeze({
    walk: 2.2, // a worker walks to their station
    firstPush: [5, 8], // dispatch -> first commit
    pushGap: [4, 7], // between commits
    commits: [1, 3],
    prAfter: [3, 5], // last commit -> pull request
    review: [6, 9], // pull request -> verdict
    criteriaReply: 3.2, // ask_pass_criteria -> criteria_returned
    fixPush: [4, 6], // rejection -> fix pushed -> review again
    redToGreen: [6, 9], // a red check until it turns green
    crashRecover: 7, // a crashed worker is re-dispatched
  }),
  // chances drawn from the seeded generator, once per task, when it is created
  chance: Object.freeze({ askCriteria: 0.3, decision: 0.3, gateRed: 0.25, crash: 0.08, vendorDown: 0.05 }),
  // review rounds a task needs before approval: 1 (first pass) .. 5
  roundsWeights: Object.freeze([0.5, 0.24, 0.12, 0.09, 0.05]),
});

// Deterministic task titles (the fixture's own words; nothing here is real work)
export const TITLES = Object.freeze([
  "Board: ranks and service records",
  "Chart band: islands for ready tasks",
  "Kraken: one arm per held task",
  "Order ritual: bell and whistle",
  "Merge salvo with the bell",
  "Weather, not blame, on a red gate",
  "Decision cards as strategy cards",
  "Clearing and a cheer",
  "Crew roster with vendor lines",
  "Voyage chart: making port",
  "Reviewer's pass criteria list",
  "Firstmate hand-off scroll",
  "Deck stations and pooled actions",
  "Squall band over the scene",
  "Tally roll-over counters",
  "Pennants with rank braid",
  "Harpoon and chain-shot skills",
  "Captain's porthole portrait",
]);

export const CREW_FIXTURE = Object.freeze([
  { id: "captain", role: "captain", name: "Captain" },
  { id: "firstmate", role: "firstmate", name: "Firstmate", vendor: "robot" },
  { id: "worker-1", role: "worker", name: "worker-1", model: "sailor-hammer", vendor: "claude · opus-5", standing: 2, merges: 2, firstPass: 0 },
  { id: "worker-2", role: "worker", name: "worker-2", model: "sailor-bandana", vendor: "cursor-agent · composer", standing: 9, merges: 7, firstPass: 4 },
  { id: "worker-3", role: "worker", name: "worker-3", model: "sailor-spyglass", vendor: "claude · sonnet-5", standing: 0, merges: 0, firstPass: 0 },
  { id: "worker-4", role: "worker", name: "worker-4", model: "sailor-laptop", vendor: "claude · opus-5", standing: 1.5, merges: 1, firstPass: 1 },
  { id: "reviewer-1", role: "reviewer", name: "reviewer-1", model: "reviewer", vendor: "codex · gpt-5.5", approvals: 9 },
]);
