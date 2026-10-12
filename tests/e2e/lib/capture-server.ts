// The same populated board used by the end-to-end tests, never live state.
import { makeRoot, startBoard, stopBoard, writeRegistry } from './fixture';
import { rmSync } from 'node:fs';
// A launcher may carry a live project/state environment. The fixture owns
// its own root and registry; retain only the lifeline's ownership variables.
for (const key of Object.keys(process.env)) {
  if (key.startsWith('FM_') && !key.startsWith('FM_LIFELINE_')) delete process.env[key];
}
// Only remove the directory explicitly handed over by the capture hook.
const captureConfig = process.argv[2];
const root = makeRoot(['working', 'gate', 'review', 'working', 'gate']);
writeRegistry(root, 'fixture/capture');
let board: Awaited<ReturnType<typeof startBoard>> | undefined;
try {
  board = await startBoard(root);
  process.stdout.write(JSON.stringify({pages: {
    'board/public/index.html': {url: `${board.url}/?lang=en`, views: [
      {name: 'Decisions', click: '#tabDecisions', ready: '#decisionsPanel #card-D-1'},
      {name: 'Fleet', click: '#tabFleet', ready: '#fleetPanel .card[data-task="SK-007"]'},
      {name: 'Crew', click: '#rosterBtn', ready: '#crewSheet[open] #roster .rrow'},
      {name: 'Log', click: '#logBtn', ready: '#logSheet[open] #log li'},
    ]},
  }}) + '\n');
  await new Promise<void>(resolve => {
    process.stdin.resume();
    process.stdin.once('end', resolve);
  });
} finally {
  try {
    if (board) await stopBoard(board);
    else rmSync(root, {recursive: true, force: true});
  } finally {
    if (captureConfig) rmSync(captureConfig, {recursive: true, force: true});
  }
}
