import test from 'node:test';
import assert from 'node:assert/strict';
import { BoardSource } from '../src/board-source.js';
const snapshot = () => ({default_project:'self', projects:['self','other'],
  tasks:[{id:'T-1',key:'self/T-1',project:'self',stage:'gate',actions:['park','drop']},
    {id:'T-1',key:'other/T-1',project:'other',stage:'ready',actions:[]}],
  crew:[{id:'worker-aya-t1-r4',crew_name:'aya',role:'worker',state:'gate',task:'T-1',project:'self',activity:{en:'Fixing', 'zh-TW':'修正中'}}],
  pending:[{id:'D-self-T-1-1',task:'T-1',project:'self',answerable:true,details:{en:{options:{B:{description:'Hold'}}},effect:{B:'hold'}}}],
  recent:[],handoffs:[],outcomes:[],counts:{merged:0}});
function make() {
  const requests=[];
  const source=new BoardSource({token:()=> 'tab-secret', fetch:async (path, init)=> {
    requests.push({path,init}); return {ok:true,json:async()=>({ok:true,decision:{id:'D-self-T-1-1'},effect:'hold',outcome:'done'})};
  }});
  return {source,requests};
}
test('BoardSource uses project keys and only the visible board crew',()=>{
  const {source}=make(); let view;
  source.subscribe(v=>view=v); source.accept(snapshot());
  assert.deepEqual(view.tasks.map(t=>t.id),['self/T-1','other/T-1']);
  assert.deepEqual(view.crew.map(c=>c.id),['captain','worker-aya-t1-r4']);
  assert.equal(view.crew[1].task,'self/T-1');
  assert.equal(view.crew[1].state,'blocked');
  assert.deepEqual(view.crew[1].activity, snapshot().crew[0].activity);
  source.accept({...snapshot(),tasks:[],crew:[],pending:[]});
  assert.equal(view.crew.length,1); assert.equal(view.tasks.length,0);
});
test('only offered actions write, using the tab token and the card project',async()=>{
  const {source,requests}=make(); source.accept(snapshot());
  await source.command({type:'answer',decision:'D-self-T-1-1',chosen:'B'});
  await source.command({type:'park',task:'self/T-1',confirm:true});
  assert.deepEqual(requests.map(r=>r.path),['/decisions','/tasks']);
  assert.equal(requests[0].init.headers.Authorization,'Bearer tab-secret');
  assert.deepEqual(JSON.parse(requests[0].init.body),{id:'D-self-T-1-1',chosen:'B',project:'self'});
  assert.deepEqual(JSON.parse(requests[1].init.body),{task:'T-1',action:'park',project:'self',confirm:true});
  for (const c of [{type:'answer',decision:'D-self-T-1-1',chosen:'A'},{type:'park',task:'other/T-1'},{type:'approve',task:'self/T-1'}]) await source.command(c);
  source.fighting=true; await source.command({type:'drop',task:'self/T-1'});
  assert.equal(requests.length,2,'unoffered actions and fights never write');
});
test('refusal returns the board translation key and never mutates the view',async()=>{
  const source=new BoardSource({token:()=> 'token',fetch:async()=>({ok:false,json:async()=>({error:'confirm first',code:'confirmRequired'})})});
  source.accept(snapshot()); const before=source.view;
  assert.equal((await source.command({type:'park',task:'self/T-1'})).code,'confirmRequired');
  assert.equal(source.view,before);
});
test('snapshot replay deduplicates lost rounds and only approval releases victory',()=>{
  const {source,requests}=make(); const s=snapshot();
  s.recent=[3,2,1].map(n=>({ts:String(n),actor:'reviewer',project:'self',task:'T-1',type:'review_failed',data:{review_outcome:'rejected'}}));
  source.accept(s); source.accept(s);
  assert.deepEqual(source.view.kraken.arms,['self/T-1']);
  assert.equal(source.view.tasks[0].round,3);
  s.recent.unshift({ts:'4',actor:'reviewer',project:'self',task:'T-1',type:'approved'});
  const events=source.accept(s);
  assert.equal(source.view.kraken.arms.length,0);
  assert.ok(events.some(e=>e.type==='live_victory'));
  assert.equal(requests.length,0);
});

test('complete handoffs recover lost reviews when recent is empty',()=>{
  const {source}=make(); const s=snapshot();
  s.handoffs=[1,2,3].map(n=>{
    const e={ts:`2026-10-01T00:00:0${n}Z`,actor:'reviewer',type:'review_failed',task:'T-1',project:'self',data:{review_outcome:'rejected'}};
    return {identity:`handoff:${n}:${JSON.stringify(e)}`,kind:'reject',project:'self',task:'T-1'};
  });
  source.accept(s); assert.deepEqual(source.view.kraken.arms,['self/T-1']);
});

test('opaque aggregate handoffs never create private review history',()=>{
  const {source}=make(); const s=snapshot();
  s.handoffs=[1,2,3].map(n=>({identity:`external:${n}`,kind:'reject',project:'other',task:'T-1'}));
  source.accept(s); assert.deepEqual(source.view.kraken.arms,[]);
});


test('the request callback is invoked without the BoardSource as its receiver',async()=>{
  let called=false;
  const source=new BoardSource({token:()=> 'token',fetch:async function() {
    assert.equal(this,undefined,'browser fetch must not receive a BoardSource receiver');
    called=true;
    return {json:async()=>({ok:true})};
  }});
  source.accept(snapshot());
  assert.deepEqual(await source.command({type:'park',task:'self/T-1'}),{ok:true});
  assert.equal(called,true);
});


test('answerable board cards suppress the Live fight without releasing its grip',()=>{
  const {source,requests}=make(); const s=snapshot();
  s.recent=[3,2,1].map(n=>({ts:String(n),actor:'reviewer',project:'self',task:'T-1',type:'review_failed',data:{review_outcome:'rejected'}}));
  source.accept(s);
  assert.deepEqual(source.view.kraken.arms,['self/T-1'],'the real rejection streak still grips the ship');
  assert.equal(source.view.kraken.battle,null,'the board card replaces the fight prompt and stage target');
  for (const pending of [[], [{...s.pending[0],answerable:false}], [{...s.pending[0],project:'other'}]]) {
    source.accept({...s,pending});
    assert.ok(source.view.kraken.battle,'absent, unanswerable and other-project cards do not suppress the fight');
  }
  source.accept({...s,pending:[{...s.pending[0],project:undefined,answerable:undefined}]});
  assert.equal(source.view.kraken.battle,null,'legacy cards use the default project and are answerable unless explicitly refused');
  source.accept({...s,recent:[{ts:'4',type:'approved',task:'T-1',project:'self'},...s.recent]});
  assert.deepEqual(source.view.kraken.arms,[]);
  assert.equal(source.view.kraken.battle,null);
  assert.equal(requests.length,0,'snapshot reconciliation never writes');
});
