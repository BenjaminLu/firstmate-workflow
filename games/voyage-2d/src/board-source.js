// Live-only seam. The host hands us exactly its /api/state and /events snapshots;
// sharing that subscription preserves its selected-project privacy boundary.
import { krakenFromEvents, reviewRounds, taskKey } from './live.js';
const eventId = e => e.identity || JSON.stringify([e.ts,e.actor,e.type,e.project,e.task,e.data]);
const mapped = {commit_pushed:'commit_pushed',ask_pass_criteria:'ask_pass_criteria',criteria_returned:'criteria_returned',worker_crashed:'worker_crashed',vendor_unavailable:'vendor_unavailable',dispatched:'order',pr_opened:'pr_opened',approved:'review_approved',gate_passed:'gate_green',gate_failed:'gate_failed',decision_requested:'decision_requested',decision_made:'decision_answered',merged:'merged'};
const sailor = id => ['sailor-hammer','sailor-bandana','sailor-spyglass'][Array.from(id).reduce((n,c)=>(n+c.charCodeAt(0))%3,0)];
export class BoardSource {
  mode = 'live'; fighting = false; listeners = new Set(); history = new Map(); seen = new Set();
  constructor({token = () => '', fetch: request = globalThis.fetch} = {}) {
    this.token=token;
    // Native browser fetch accepts Window (or no receiver), never this source.
    this.request=(...args)=>request(...args);
    this.accept({});
  }
  subscribe(fn) { this.listeners.add(fn); fn(this.view,[]); return ()=>this.listeners.delete(fn); }
  accept(s) {
    const prior=this.view; this.snapshot=s;
    const fresh=[];
    for(const e of [...(s.recent || [])].reverse()) {
      const id=eventId(e);
      if (!this.history.has(id)) {this.history.set(id,e); fresh.push(e);}
    }
    // Handoff identities on the board contain the original event. External
    // aggregate identities are opaque hashes: never infer private review data.
    // Recover the complete allowed stream before replaying the recent window.
    const complete=new Map();
    for (const h of s.handoffs || []) {
      const match=/^handoff:[0-9]+:(\{.*\})$/.exec(h.identity || '');
      if (!match) continue;
      try {
        const e=JSON.parse(match[1]);
        if(e.task===h.task && (e.project || s.default_project)===(h.project || s.default_project)) complete.set(eventId(e),e);
      } catch { /* Unknown legacy identity: the recent window remains usable. */ }
    }
    for(const [id,e] of this.history) complete.set(id,e);
    const history=[...complete.values()].sort((a,b)=>String(a.ts || '').localeCompare(String(b.ts || '')));
    const rounds=reviewRounds(history,{defaultProject:s.default_project});
    const kraken=krakenFromEvents(history,{defaultProject:s.default_project});
    const key = t => t.key || `${t.project || s.default_project || ''}/${t.id}`;
    const tasks=(s.tasks || []).map(t=>({...t,boardId:t.id,id:key(t),key:key(t),lane:t.stage,
      deps:(t.depends_on || []).map(id=>`${t.project || s.default_project || ''}/${id}`),
      round:Math.max(rounds.get(key(t))?.rounds || 0,rounds.get(key(t))?.lost || 0),
      approved:(rounds.get(key(t))?.approvals || 0)>0,flags:{}}));
    // Reconcile terminal/parked snapshots even when their events fell out of recent.
    const arms=kraken.arms.filter(id=>tasks.some(t=>t.id===id && !['merged','closed','parked'].includes(t.lane)));
    // The board's answerable card takes precedence over the shared monster's
    // fight prompt/target. Keep every grip until a real release event arrives.
    const boardCard=(s.pending || []).some(d=>d.task && d.answerable!==false && arms.includes(taskKey(d,s.default_project)));
    const crew=(s.crew || []).map(c=>({...c,name:c.crew_name || c.id,
      model:c.role==='firstmate'?'firstmate':c.role==='reviewer'?'reviewer-1':sailor(c.id),
      task:c.task?`${c.project || s.default_project || ''}/${c.task}`:null,
      state:({queued:'idle',unknown:'idle',gate:'blocked',captain:'waiting'})[c.state] || c.state,
      action:c.state==='working'?'hammer':c.state==='review'?'lookout':null,
      vendor:c.vendor,llm:c.model,llm_source:c.model_source,
      llm_mismatch:c.model_mismatch,llm_requested:c.model_requested,record:[],honours:[]}));
    crew.unshift({id:'captain',role:'captain',name:'Captain',model:'captain',state:'idle',task:null,record:[],honours:[]});
    const milestones=[...new Set(tasks.map(t=>t.milestone).filter(Boolean))].map(id=>({id,tasks:tasks.filter(t=>t.milestone===id).map(t=>t.id)}));
    const decisions=(s.pending || []).map(d=>({...d,task:d.task?`${d.project || s.default_project || ''}/${d.task}`:null,options:[]}));
    this.view={mode:'live',t:prior?.t || 0,tasks,crew,decisions,milestones,projects:s.projects || [],port:0,
      counts:s.counts || {},kraken:{arms,battle:arms.length && !boardCard?{}:null,fled:false},
      gate:Object.fromEntries(tasks.filter(t=>t.lane==='gate').map(t=>[t.id,'red'])),log:[],stats:{},rituals:{}};
    const events=fresh.filter(e=>mapped[e.type] && e.type!=='merged').map(e=>({...e,type:mapped[e.type],task:e.task?taskKey(e,s.default_project):null,crew:e.actor}));
    for(const e of fresh.filter(e=>e.type==='review_failed')) events.push({type:e.data?.review_outcome==='rejected'?'review_rejected':'gate_failed',task:taskKey(e,s.default_project),crew:e.actor});
    // Merge salvos only follow the board's completed merge outcomes.
    for(const e of s.outcomes || []) if(e.type==='merged' && !this.seen.has(eventId(e))) {
      this.seen.add(eventId(e)); events.push({...e,type:'merged',task:taskKey(e,s.default_project)});
    }
    for(const id of arms) if(!prior?.kraken.arms.includes(id)) events.push({type:'kraken_arm',task:id});
    if(prior?.kraken.arms.length && !arms.length && fresh.some(e=>e.type==='approved' && prior.kraken.arms.includes(taskKey(e,s.default_project)))) events.push({type:'live_victory'});
    // Adapt ritual payloads to the renderer's event vocabulary, with actual
    // crew identities rather than the Playground's fixed worker/reviewer ids.
    for(const e of events) {
      const task=tasks.find(t=>t.id===e.task);
      e.worker=crew.find(c=>c.role==='worker' && c.task===e.task)?.id;
      e.round=task?.round || 0;
      if(e.type==='decision_requested') e.decision=decisions.find(d=>d.id===e.data?.decision || d.task===e.task) || {id:e.data?.decision || '',task:e.task};
    }
    for(const m of milestones) {
      const done=m.tasks.length && m.tasks.every(id=>tasks.find(t=>t.id===id)?.lane==='merged');
      const previous=prior?.milestones.find(p=>p.id===m.id);
      if(done && previous && previous.tasks.some(id=>prior.tasks.find(t=>t.id===id)?.lane!=='merged')) events.push({type:'making_port',port:m.id});
    }
    for(const fn of this.listeners) fn(this.view,events);
    return events;
  }
  async command(c) {
    if(this.fighting) return {error:true,code:'actionFailed'};
    let path,body;
    if(c.type==='answer') {
      const d=(this.snapshot.pending || []).find(d=>d.id===c.decision);
      const opts=d?.details?.en?.options || d?.details?.['zh-TW']?.options;
      if(!d || d.answerable===false || !(opts?Object.hasOwn(opts,c.chosen):['A','B','C'].includes(c.chosen))) return {error:true,code:'invalidChoice'};
      path='/decisions'; body={id:d.id,chosen:c.chosen,...(d.project?{project:d.project}:{})};
    } else {
      const t=this.view.tasks.find(t=>t.key===c.task);
      if(!['park','unpark','drop'].includes(c.type) || !t?.actions?.includes(c.type)) return {error:true,code:'actionFailed'};
      path='/tasks';body={task:t.boardId,action:c.type,...(t.project?{project:t.project}:{}),...(c.confirm?{confirm:true}:{})};
    }
    const token=this.token(); if(!token) return {error:true,code:'noCredential'};
    try {
      const r=await this.request(path,{method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${token}`},body:JSON.stringify(body)});
      return await r.json(); // Preserve the board's translated refusal code.
    } catch {return {error:true,code:'unreachable'};}
  }
  close(){this.listeners.clear();this.history.clear();this.seen.clear();}
}
