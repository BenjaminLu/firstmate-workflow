import { expect } from '@playwright/test';
import { test, makeRoot, startBoard, stopBoard, writeTasks, writeProjects } from './lib/fixture';
import { emitFixture } from './lib/board';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';

const actor = 'reviewer-nikhil-sp-t191-r1b';
const payload = {role:'reviewer', phase:'review', mode:'spec-preflight', crew_name:actor,
  identity:{name:'nikhil',role:'reviewer',task:'T-191',round:1,attempt:2,
    vendor:'claude',model_requested:'fixture-model'}};

test('preflight crew remains labelled through warnings, never creates tasks or changes lanes', async ({page}) => {
  test.setTimeout(90_000);
  const root=makeRoot([],false);
  writeTasks(root, [{id:'T-191',title:'Defined task',depends_on:[]}]);
  emitFixture(root,'worker-live','T-191','dispatched','Working','工作中',{role:'worker',identity:{name:'worker',round:null,attempt:1}});
  emitFixture(root,actor,'T-191','crew_status','Checking spec','檢查規格',payload);
  emitFixture(root,'opaque-preflight','T-999','crew_status','Checking spec','檢查規格',payload);
  const run=join(root,'state/runs',actor);
  mkdirSync(run,{recursive:true});
  writeFileSync(join(run,'identity.json'),JSON.stringify({...payload.identity,actor,mode:'spec-preflight'}));
  const warning=spawnSync('python3',[join(root,'bin/fm-herdr.py'),'emit-status','--root',root,
    '--actor',actor,'--task','T-191','--role','reviewer','--en','Sandbox warning','--tw','沙箱警告'],
    {env:{...process.env,FM_ROOT:root,HERDR_ENV:'0'}});
  expect(warning.status,warning.stderr.toString()).toBe(0);
  expect(JSON.parse(readFileSync(join(root,'state/events.jsonl'),'utf8').trim().split('\n').at(-1)!).data.mode).toBe('spec-preflight');
  // Classification belongs to the actor even if its latest event lacks mode.
  emitFixture(root,actor,'T-191','crew_status','Sandbox warning','沙箱警告',{role:'reviewer'});
  const b=await startBoard(root);
  const state=async()=> (await page.request.get(b.url+'/api/state')).json();
  try {
    const s=await state();
    expect(s.crew.find(c=>c.id===actor)).toMatchObject({name:'nikhil',mode:'spec-preflight',state:'review',vendor:'claude',model:'fixture-model'});
    expect(s.tasks.some(t=>t.id==='T-999')).toBe(false);
    expect(s.tasks.find(t=>t.id==='T-191').stage).toBe('working');
    for(const [lang,label] of [['en','spec preflight'],['zh-TW','預檢'],['zh-CN','预检']]) {
      await page.goto(`${b.url}/?lang=${lang}`);
      await expect(page.locator(`[data-crew-chip="${actor}"] .cd`)).toHaveText(label);
      await expect(page.locator(`#crewcard-${actor} .cround`)).toHaveText(label);
      await expect(page.locator(`[data-roster="${actor}"] .rd`)).toHaveText(label);
    }
    await page.locator('[data-sort="round"]').click();
    const sorted=await page.locator('#roster [data-roster]').evaluateAll(els=>els.map(el=>el.getAttribute('data-roster')));
    expect(sorted.indexOf(actor)).toBeLessThan(sorted.indexOf('worker-live'));
    emitFixture(root,'worker-live','T-191','pr_opened','PR opened','已開啟 PR');
    expect((await state()).handoffs.filter(h=>h.kind==='work').at(-1).to).toBe(null);
    emitFixture(root,'real-reviewer','T-191','review_opened','Review','審查',{role:'reviewer'});
    emitFixture(root,'worker-live','T-191','pr_opened','PR opened','已開啟 PR');
    expect((await state()).handoffs.filter(h=>h.kind==='work').at(-1).to).toBe('real-reviewer');
    for(const outcome of ['refused','failed','interrupted']) {
      const id='preflight-'+outcome;
      emitFixture(root,id,'T-191','crew_status','Preflight','預檢',payload);
      if(outcome==='interrupted') emitFixture(root,id,'T-191','agent_lost','Lost','失聯');
      emitFixture(root,id,'T-191','agent_finished','Finished','完成',{result:'failed',preflight_outcome:outcome});
      const s=await state();
      expect(s.crew.some(c=>c.id===id)).toBe(false);
      expect(s.tasks.find(t=>t.id==='T-191')).toMatchObject({stage:'review',badges:[]});
    }
    for(const [id,task] of [[actor,'T-191'],['opaque-preflight','T-999']]) emitFixture(root,id,task,'agent_finished','Finished','完成',{mode:'spec-preflight',result:'ok'});
    expect((await state()).crew.some(c=>[actor,'opaque-preflight'].includes(c.id))).toBe(false);
    expect((await state()).tasks.some(t=>t.id==='T-999')).toBe(false);
    const ordinary='reviewer-zain-sp-t191-r1';
    emitFixture(root,ordinary,'T-191','review_opened','Review','審查',{role:'reviewer'});
    emitFixture(root,ordinary,'T-191','agent_lost','Lost','失聯',{role:'reviewer'});
    emitFixture(root,ordinary,'T-191','agent_finished','Finished','完成',{role:'reviewer',status:'process_gone'});
    expect((await state()).tasks.find(t=>t.id==='T-191')).toMatchObject({stage:'gate',badges:[{kind:'lost',actor:ordinary}]});
  } finally { await stopBoard(b); }
});

test('external preflight mode survives the aggregate metadata projection', async ({page})=> {
  test.setTimeout(90_000);
  const root=makeRoot([],false);
  writeTasks(root,[]);
  writeProjects(root,[{name:'alpha',github:'org/alpha'},{name:'beta',github:'org/beta',tasks:[]}]);
  const r=spawnSync('bash',[join(root,'bin/fm-emit.sh'),'--project','beta','--actor',actor,'--task','T-191',
    '--type','crew_status','--data',JSON.stringify({...payload,identity:{...payload.identity,project:'beta'}}),
    '--en','Preflight','--tw','預檢'],{env:{...process.env,FM_ROOT:root,HERDR_ENV:'0'}});
  expect(r.status,r.stderr.toString()).toBe(0);
  const b=await startBoard(root);
  try {
    for(const query of ['', '?project=beta']) {
      const s=await (await page.request.get(b.url+'/api/state'+query)).json();
      expect(s.crew.find(c=>c.id===actor).mode).toBe('spec-preflight');
      expect(s.tasks.some(t=>t.id==='T-191')).toBe(false);
    }
  } finally { await stopBoard(b); }
});
