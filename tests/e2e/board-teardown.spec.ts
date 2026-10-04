import { expect } from '@playwright/test';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test, makeRoot, startBoard, stopBoard, ROOT } from './lib/fixture';

for (const startupFails of [false, true]) {
  test(`teardown drains a writing child${startupFails ? ' after failed startup' : ''}`, async () => {
    const root = makeRoot([], false);
    const audit = mkdtempSync(join(tmpdir(), 'fm-e2e-teardown-'));
    // Readiness is sent only after the writer has opened the fixture tree.
    writeFileSync(join(root, 'writer.py'), `import os, signal, sys\nfrom pathlib import Path\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\np = Path(sys.argv[1])\nPath(sys.argv[2]).write_text(str(os.getpid()))\n(p / 'bin' / 'writing').write_text('ready')\nprint('ready', flush=True)\ni = 0\nwhile True:\n    try:\n        (p / 'bin').mkdir(parents=True, exist_ok=True)\n        (p / 'bin' / 'writing').write_text(str(i))\n        i += 1\n    except FileNotFoundError:\n        pass\n`);
    writeFileSync(join(root, 'board/server.ts'), `
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
const root = process.env.FM_ROOT!;
const child = Bun.spawn(['python3', ${JSON.stringify(join(ROOT, 'bin/lib/fm_lifeline.py'))},
  'keep', '--pid', String(process.pid), '--', 'python3', join(root, 'writer.py'), root,
  ${JSON.stringify(join(audit, 'writer'))}],
  {stdout:'pipe', stderr:'inherit', env:process.env});
await child.stdout.getReader().read();
writeFileSync(${JSON.stringify(join(audit, 'keeper'))}, String(child.pid));
// Freeze the keeper, not the writer. Owner death alone cannot clean it up;
// fixture drainage must find this detached keeper and resume its shutdown.
process.kill(child.pid, 'SIGSTOP');
const dir = join(process.env.XDG_CONFIG_HOME!, 'firstmate');
mkdirSync(dir, {recursive:true});
writeFileSync(join(dir, 'board-' + process.env.FM_PORT + '.secret'), 'secret');
Bun.serve({hostname:'127.0.0.1', port:Number(process.env.FM_PORT),
  fetch:() => new Response('ready', {status:${startupFails ? 503 : 200}})});
`);
    try {
      if (startupFails) {
        await expect(startBoard(root, { FM_LIFELINE_GRACE: '0' })).rejects.toThrow('the board did not come up');
      } else {
        const board = await startBoard(root, { FM_LIFELINE_GRACE: '0' });
        await stopBoard(board);
        expect(board.proc.exitCode !== null || board.proc.signalCode !== null,
          'stopBoard waits for process completion before returning').toBe(true);
      }
      const writer = Number(readFileSync(join(audit, 'writer'), 'utf8'));
      const status = spawnSync('python3', ['-c',
        'import sys; sys.dont_write_bytecode=True; sys.path.insert(0, sys.argv[1]); import fm_lifeline as L\ntry:\n p=L.ProcessExit(int(sys.argv[2])); gone=p.gone(); p.close()\nexcept L.OwnerGone: gone=True\nsys.exit(0 if gone else 1)',
        join(ROOT, 'bin/lib'), String(writer)]);
      expect(status.status, 'the detached writer exited before tree removal').toBe(0);
      expect(existsSync(root)).toBe(false);
    } finally {
      // Cleanup also runs against the reverted fixture: resume the keeper,
      // kill the writer, and wait on both kernel exit descriptors before rm.
      const cleanup = spawnSync('python3', ['-c', `
import os, signal, sys
from pathlib import Path
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import fm_lifeline as L
import select
watches = []
for name in ('writer', 'keeper'):
    path = Path(sys.argv[2]) / name
    if not path.exists(): continue
    pid = int(path.read_text())
    try:
        watches.append(L.ProcessExit(pid))
        os.kill(pid, signal.SIGKILL if name == 'writer' else signal.SIGCONT)
    except (ProcessLookupError, L.OwnerGone): pass
for watch in watches:
    if not watch.gone():
        ready, _, _ = select.select([watch.fileno()], [], [], 15)
        if not ready or not watch.gone(): raise RuntimeError('test cleanup did not finish')
    watch.close()
`, join(ROOT, 'bin/lib'), audit], {timeout: 35_000});
      rmSync(audit, {recursive:true, force:true});
      rmSync(root, {recursive:true, force:true, maxRetries:5, retryDelay:100});
      expect(cleanup.status, cleanup.stderr?.toString()).toBe(0);
    }
  });
}
