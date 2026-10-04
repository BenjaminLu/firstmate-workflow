import test from 'node:test';
import assert from 'node:assert/strict';
import { HUD, stringKeys } from '../src/hud.js';

const hud = lang => Object.assign(Object.create(HUD.prototype), {lang});
const crew = {id:'worker',name:'Aya',role:'worker',state:'working',task:null,rank:0,vendor:'codex',llm:'gpt-6-astra'};
const state = mode => ({mode,tasks:[],projects:[],crew:[crew]});

test('live crew fields show vendor and exact model with localized provenance',()=>{
  for (const [lang,vendor,model,requested,mismatch] of [
    ['en','Vendor','Model','(requested)','Model mismatch'],
    ['zh-TW','供應商','模型','（已請求）','模型不符'],
    ['zh-CN','供应商','模型','（已请求）','模型不符'],
  ]) {
    const h=hud(lang), s=state('live');
    assert.equal(h.t.f.vendor,vendor); assert.equal(h.t.f.llm,model);
    const fields=h.crewFields(crew,s);
    assert.deepEqual(fields.map(([k])=>k),['name','role','project','task','round','pr','state','activity','vendor','llm']);
    assert.deepEqual(fields.slice(-2),[['vendor','codex'],['llm','gpt-6-astra']]);
    assert.equal(h.crewFields({...crew,llm_source:'requested'},s).at(-1)[1],`gpt-6-astra ${requested}`);
    assert.equal(h.crewFields({...crew,llm_source:'requested',llm_mismatch:true},s).at(-1)[1],mismatch);
    assert.equal(h.crewFields({...crew,llm:undefined},s).at(-1)[1],h.t.none);
  }
  for (const key of ['f.llm','llmRequested','llmMismatch']) assert.ok(stringKeys().includes(key));
});

test('live and playground rosters have ten headers and ten cells in every crew row',()=>{
  const h=hud('en');
  for (const mode of ['live','playground']) {
    const s=state(mode);
    s.crew=[crew,{...crew,id:'reviewer',role:'reviewer'},{...crew,id:'captain',role:'captain'}];
    const html=h.rosterHtml(s);
    const headers=[...html.matchAll(/<thead>(.*?)<\/thead>/gs)][0][1];
    assert.equal((headers.match(/<th>/g)||[]).length,10);
    const rows=[...html.matchAll(/<tr class="st-[^"]*">(.*?)<\/tr>/gs)];
    assert.equal(rows.length,3);
    for (const row of rows) assert.equal((row[1].match(/<td /g)||[]).length,10);
    const fields=h.crewFields({...crew,vendor:'codex / gpt-6-astra'},s);
    assert.equal(fields.length,10);
    assert.equal(fields.some(([k])=>k==='rank'),mode==='playground');
    assert.equal(headers.includes('<th>Rank</th>'),mode==='playground');
    assert.equal(headers.includes('<th>Model</th>'),mode==='live');
    assert.equal(fields.find(([k])=>k==='vendor')[1],'codex / gpt-6-astra');
  }
});
