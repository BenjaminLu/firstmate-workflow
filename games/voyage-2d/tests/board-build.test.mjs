import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

const prepare=fileURLToPath(new URL('../tools/prepare-board.sh',import.meta.url));
test('board build replaces stale output and removes partial output on failure',()=>{
  const root=mkdtempSync(join(tmpdir(),'voyage-build-'));
  try {
    const tools=join(root,'games/voyage-2d/tools');
    const target=join(root,'board/public/voyage2d/index.html');
    mkdirSync(tools,{recursive:true});mkdirSync(join(root,'board/public/voyage2d'),{recursive:true});
    const build=join(tools,'build.py');
    writeFileSync(build,`import sys\nfrom pathlib import Path\nassert sys.argv[1:] == ['--live']\np = Path(${JSON.stringify(target)})\np.write_text('fresh')\n`);
    writeFileSync(target,'stale');
    const ok=spawnSync('bash',[prepare,root],{encoding:'utf8'});
    assert.equal(ok.status,0,ok.stderr);
    assert.equal(readFileSync(target,'utf8'),'fresh');
    writeFileSync(build,readFileSync(build,'utf8')+'sys.exit(1)\n');
    const fail=spawnSync('bash',[prepare,root],{encoding:'utf8'});
    assert.notEqual(fail.status,0);
    assert.equal(existsSync(target),false,'failed builds must never leave a stale or partial stage');
    assert.match(fail.stderr,/board will start without the voyage panel/);
  } finally {rmSync(root,{recursive:true,force:true});}
});

test('session start builds before board startup and continues after a failed build',()=>{
  const root=mkdtempSync(join(tmpdir(),'voyage-session-'));
  try {
    const bin=join(root,'bin'), tools=join(root,'games/voyage-2d/tools');
    mkdirSync(join(bin,'lib'),{recursive:true});mkdirSync(tools,{recursive:true});
    const session=fileURLToPath(new URL('../../../bin/fm-session.sh',import.meta.url));
    writeFileSync(join(bin,'fm-session.sh'),readFileSync(session));
    writeFileSync(join(tools,'prepare-board.sh'),readFileSync(prepare));
    // Replace unrelated session services, leaving the session entrypoint and
    // build helper real. No service or background process starts in this test.
    writeFileSync(join(bin,'fm-config.sh'),`
fm_storage_init() { FM_STATE_DIR="$1/state"; }
fm_freeze() { :; }
fm_cfg_in() { echo codex; }
fm_model() { echo fixture; }
fm_model_known() { return 0; }
fm_role_vendor() { echo codex; }
fm_model_for() { echo fixture; }
`);
    for(const f of ['fm_host.py','fm_hooks.py']) writeFileSync(join(bin,'lib',f),'');
    writeFileSync(join(bin,'fm-herdr.py'),`import sys\nfrom pathlib import Path\nr=Path(sys.argv[3])\np=r/'order'\np.write_text(p.read_text()+'board\\n')\n`);
    const target=join(root,'board/public/voyage2d/index.html');
    mkdirSync(join(root,'board/public/voyage2d'),{recursive:true});
    const build=join(tools,'build.py');
    const program=`import sys\nfrom pathlib import Path\nr=Path(${JSON.stringify(root)})\np=r/'order'\np.write_text('build\\n')\n(r/'board/public/voyage2d/index.html').write_text('fresh')\n`;
    for(const failure of [false,true]) {
      writeFileSync(build,program+(failure?'sys.exit(1)\n':''));
      const result=spawnSync('bash',[join(bin,'fm-session.sh'),'start','--repo',root],{
        encoding:'utf8',env:{...process.env,FM_ROOT:root,FM_CODE_ROOT:root,FM_IN_ROUND:'1'},
      });
      assert.equal(result.status,0,result.stderr);
      assert.equal(readFileSync(join(root,'order'),'utf8'),'build\nboard\n');
      assert.equal(existsSync(target),!failure);
      if(failure) assert.match(result.stderr,/board will start without the voyage panel/);
    }
  } finally {rmSync(root,{recursive:true,force:true});}
});
