import test from 'node:test';
import assert from 'node:assert/strict';
import { BoardSource } from '../src/board-source.js';
import { Director } from '../src/director.js';

test('preflight is a lookout without a task card and never receives a review ritual',()=> {
  const source=new BoardSource();
  source.accept({default_project:'self',tasks:[],crew:[{id:'preflight',role:'reviewer',state:'review',task:'T-191',mode:'spec-preflight'}]});
  assert.equal(source.view.tasks.length,0);
  assert.equal(source.view.crew.find(c=>c.id==='preflight').action,'lookout');
  assert.equal(source.view.crew.find(c=>c.id==='preflight').preflight,true);
  source.accept({default_project:'self',tasks:[{id:'T-191',stage:'review'}],crew:[
    {id:'worker',role:'worker',state:'working',task:'T-191'},
    {id:'preflight',role:'reviewer',state:'review',task:'T-191',mode:'spec-preflight'}],
    recent:[{type:'pr_opened',actor:'worker',task:'T-191'},
      {type:'agent_finished',actor:'old-preflight',task:'T-191',data:{mode:'spec-preflight',result:'failed'}},
      {type:'crew_status',actor:'old-preflight',task:'T-191',data:{mode:'spec-preflight',role:'reviewer'}}]});
  const director=new Director({world:{crew:{worker:{},preflight:{},real:{}}},rituals:{}});
  const recipients=[];
  director.handoff=(kind,from,to)=>recipients.push(to);
  director.twoShot=()=>{};
  director.handle({type:'pr_opened',worker:'worker',task:'self/T-191'},source.view);
  assert.deepEqual(recipients,[null]);
  source.view.crew.push({id:'real',role:'reviewer',task:'self/T-191'});
  director.handle({type:'pr_opened',worker:'worker',task:'self/T-191'},source.view);
  assert.equal(recipients[1],director.world.crew.real);
  assert.equal(source.view.tasks[0].round,0);
});
