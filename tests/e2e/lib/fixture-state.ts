// T-289: writes the capture fixture's /api/state JSON to the path it is given,
// so the approved prototype can be served the same data snapshot as the board
// (in place of its own snap/api_state.json, opened with ?pending=0) and both
// are screenshotted from one source. Usage:
//   bun run tests/e2e/lib/fixture-state.ts <out.json>
import { startBoard, stopBoard } from './fixture';
import { captureRoot } from './capture-fixture';
import { writeFileSync, rmSync } from 'node:fs';

// A launcher may carry a live project/state environment. The fixture owns
// its own root and registry; retain only the lifeline's ownership variables.
for (const key of Object.keys(process.env)) {
  if (key.startsWith('FM_') && !key.startsWith('FM_LIFELINE_')) delete process.env[key];
}
const out = process.argv[2];
if (!out) { console.error('usage: fixture-state.ts <out.json>'); process.exit(2); }
const root = captureRoot();
let board: Awaited<ReturnType<typeof startBoard>> | undefined;
try {
  board = await startBoard(root);
  const state = await (await fetch(`${board.url}/api/state`)).json();
  writeFileSync(out, JSON.stringify(state, null, 2) + '\n');
} finally {
  if (board) await stopBoard(board);
  else rmSync(root, {recursive: true, force: true});
}
