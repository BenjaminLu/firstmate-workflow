// Read-only scene and retained diff walk. Loaded only by opted-in cards.
// T-289: the scene is drawn as the prototype's "How it works"; the walk fills
// the card's "Walk the diff" tab, beside its "Intent check" tab.
(() => {
  const states = new Map();
  const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
  function mount(root, {t, esc, words, lang}) {
    root.querySelectorAll('[data-walk-host]').forEach(host => {
      const raw = host.dataset.walkHost;
      if (host.dataset.walkMounted === raw + lang && host.firstElementChild) return;
      host.dataset.walkMounted = raw + lang;
      let data; try { data = JSON.parse(raw); } catch { return; }
      const card = host.closest('.cap') || host.closest('.intent-alignment') || host.parentElement;
      const locale = value => words(value?.[lang === 'en' ? 'en' : 'zh-TW'] || value?.en || '');
      let scene = data.scene;
      const walk = data.walk;
      const valid = walk?.status === 'valid';
      const fresh = !states.has(data.id);
      const state = states.get(data.id) || {phase: reduced() ? 1 : 0, playing: false, intent:1, block:0, opened:data.open === true, other:false, highlight:[]};
      state.dispose?.();
      states.set(data.id, state);
      const link = (url, label) => typeof url === 'string' && url.startsWith('https://github.com/') ? `<a href="${esc(url)}" target="_blank" rel="noreferrer">${label}</a>` : label;
      const keyFor = n => valid ? walk.intents.find(i => i.intent === n)?.key || [] : [];
      const label = {
        play:t("walkPlay"), pause:t("walkPause"), scrub:t("walkScrubber"), before:t("walkBefore"), change:t("walkChange"), after:t("walkAfter"),
        all:t("walkShowAll"), its:t("walkItsCode"), code:t("walkCode"), check:t("walkIntentCheck"), other:t("walkOther"),
        stale:t("walkStale"), absent:t("walkAbsent"), empty:t("walkNoKey"), head:t("walkReviewedHead"), omitted:t("walkOmitted"),
        previous:t("walkPrevious"), next:t("walkNext"), diff:t("walkDiff")
      };
      let animation = '', positions = new Map(), paths = new Map();
      try {
        if (scene) {
          if (!Array.isArray(scene.lanes) || !scene.lanes.length || !Array.isArray(scene.nodes) || !scene.nodes.length || !Array.isArray(scene.edges) || !Array.isArray(scene.changes)) throw Error('layout');
          const safeId = id => typeof id === 'string' && /^[a-z][a-z0-9-]{0,23}$/.test(id);
          if (![...scene.nodes,...scene.edges].every(item=>safeId(item.id))) throw Error('layout');
          for (const phase of ['before','after']) {
            const tokens=scene.tokens?.[phase];
            if (!Array.isArray(tokens) || !tokens.length || !tokens.every(id=>scene.edges.some(edge=>edge.id===id))) throw Error('layout');
          }
          if (!scene.changes.every(change=>Array.isArray(change.intents))) throw Error('layout');
          const slots = scene.lanes.map(() => 0), width = scene.lanes.length * 240;
          for (const node of scene.nodes) {
            if (!Number.isInteger(node.lane) || !slots.hasOwnProperty(node.lane)) throw Error('layout');
            positions.set(node.id, {x:node.lane * 240 + 25, y:60 + slots[node.lane]++ * 100});
          }
          const height = 95 + Math.max(...slots) * 100;
          const lanes = scene.lanes.map((lane,i) => `<g class="scene-lane"><rect x="${i*240+8}" y="4" width="224" height="${height-8}" rx="6"/><text x="${i*240+18}" y="25">${esc(words(lane.label))}</text></g>`).join('');
          const edges = scene.edges.map(edge => {
            const a=positions.get(edge.from), b=positions.get(edge.to);
            if (!a || !b) throw Error('layout');
            // Every segment runs in a lane gap, a row gap or along a node side,
            // never through a node rectangle (nodes 190x50, lanes 240, rows 100).
            let d, mx, my;
            if (a.x !== b.x) {
              const right = b.x > a.x, x1 = a.x + (right ? 190 : 0), y1 = a.y + 25, x2 = b.x + (right ? 0 : 190), y2 = b.y + 25;
              if (Math.abs(b.x - a.x) === 240) { d = `M${x1},${y1} H${(x1+x2)/2} V${y2} H${x2}`; mx = (x1+x2)/2; my = (y1+y2)/2; }
              else {
                const out = x1 + (right ? 25 : -25), into = x2 + (right ? -25 : 25), row = a.y + 75;
                d = `M${x1},${y1} H${out} V${row} H${into} V${y2} H${x2}`; mx = (out+into)/2; my = row;
              }
            } else if (a === b) {
              d = `M${a.x+190},${a.y+15} h20 v20 h-20`; mx = a.x + 210; my = a.y + 25;
            } else if (b.y === a.y + 100) {
              const x1 = a.x + 95, y1 = a.y + 50, y2 = b.y;
              d = `M${x1},${y1} V${(y1+y2)/2} H${x1} V${y2}`; mx = x1; my = (y1+y2)/2;
            } else {
              // Upward, or downward past another node: around the lane's right side.
              d = `M${a.x+190},${a.y+25} H${a.x+210} V${b.y+25} H${b.x+190}`; mx = a.x + 210; my = (a.y+b.y)/2 + 25;
            }
            paths.set(edge.id, d);
            return `<g data-scene-id="${esc(edge.id)}" data-state="${esc(edge.state)}" data-change="${esc(edge.change || '')}" class="scene-edge"><path d="${d}"/>${edge.label ? `<text x="${mx+5}" y="${my-5}">${esc(words(edge.label))}</text>` : ''}${edge.state === 'gone' ? `<path class="scene-strike" d="M${mx-7},${my-7} l14,14"/>` : ''}</g>`;
          }).join('');
          const nodes = scene.nodes.map(node => {
            const p=positions.get(node.id);
            return `<g data-scene-id="${esc(node.id)}" data-state="${esc(node.state)}" data-change="${esc(node.change || '')}" class="scene-node kind-${esc(node.kind)}" transform="translate(${p.x},${p.y})"><rect width="190" height="50" rx="${node.kind==='decision' ? 22 : node.kind==='store' ? 0 : 8}"/><text x="95" y="29" text-anchor="middle">${esc(words(node.label))}</text>${node.change ? `<g class="cbadge scene-number"><circle cx="176" cy="14" r="10"/><text x="176" y="18" text-anchor="middle">${esc(node.change.replace(/^c/, ''))}</text></g>` : ''}</g>`;
          }).join('');
          animation = `<section class="scene-view hero2"><div class="scene-banner hfocus" hidden></div><div class="scene-controls hctl" role="toolbar" aria-label="${esc(t("howHeading"))}"><span class="seg2">${[label.before,label.change,label.after].map((text,i)=>`<button type="button" data-phase="${i}">${esc(text)}</button>`).join('')}</span><button type="button" class="hplay" data-play></button><input class="hscrub" data-scrub type="range" min="0" max="2" step="0.01" value="${state.phase}" aria-label="${esc(label.scrub)}">${scene.counter ? `<span class="hcount scene-counter"><b data-counter></b> ${esc(words(scene.counter.label))}</span>` : ''}</div><svg class="herosvg" viewBox="0 0 ${width} ${height}" style="max-width:${Math.round(width*1.4)}px" role="img" aria-label="${esc(t("howHeading"))}">${lanes}${edges}${nodes}<circle class="scene-token token" r="6"/></svg><ol class="scene-badges hchanges">${scene.changes.map(c=>`<li><button type="button" data-badge="${esc(c.id)}"><span class="cn2">${esc(c.id.replace(/^c/, ''))}</span><span>${esc(words(c.text))}</span><span class="go2">${esc(label.its)}</span></button></li>`).join('')}</ol></section>`;
        }
      } catch { animation=''; scene=null; positions.clear(); paths.clear(); }
      const reasons = {
        "walk helper missing":t("walkReasonWalkHelperMissing"),
        "no local review":t("walkReasonNoLocalReview"),
        "no local approval":t("walkReasonNoLocalApproval"),
        "verdict has no source binding":t("walkReasonVerdictHasNoSourceBinding"),
        "no walk":t("walkReasonNoWalk"),
        "duplicate walk":t("walkReasonDuplicateWalk"),
        "invalid JSON":t("walkReasonInvalidJson"),
        "invalid walk fields":t("walkReasonInvalidWalkFields"),
        "diff unavailable":t("walkReasonDiffUnavailable"),
        "invalid intent fields":t("walkReasonInvalidIntentFields"),
        "intent out of range":t("walkReasonIntentOutOfRange"),
        "duplicate intent":t("walkReasonDuplicateIntent"),
        "too many key blocks per intent":t("walkReasonTooManyKeyBlocksPerIntent"),
        "too many key blocks":t("walkReasonTooManyKeyBlocks"),
        "invalid block fields":t("walkReasonInvalidBlockFields"),
        "unknown hunk id":t("walkReasonUnknownHunkId"),
        "duplicate key hunk":t("walkReasonDuplicateKeyHunk"),
        "nontext key hunk":t("walkReasonNontextKeyHunk"),
        "invalid block kind":t("walkReasonInvalidBlockKind"),
        "invalid note fields":t("walkReasonInvalidNoteFields"),
        "note fails STE":t("walkReasonNoteFailsSte"),
        "invalid line note fields":t("walkReasonInvalidLineNoteFields"),
        "line note fails STE":t("walkReasonLineNoteFailsSte"),
        "line note outside block":t("walkReasonLineNoteOutsideBlock"),
        "missing or invalid step":t("walkReasonMissingOrInvalidStep"),
        "unknown step id":t("walkReasonUnknownStepId"),
        "empty step":t("walkReasonEmptyStep"),
        "step without scene":t("walkReasonStepWithoutScene"),
        "invalid block changes":t("walkReasonInvalidBlockChanges"),
        "proves on code block":t("walkReasonProvesOnCodeBlock"),
        "invalid proves target":t("walkReasonInvalidProvesTarget"),
        "walk check failed":t("walkReasonWalkCheckFailed"),
      };
      const message = walk?.status === 'stale' ? `${esc(label.stale)} · ${esc(label.head)} <code>${esc((walk.reviewed_head || '').slice(0,7))}</code>` : `${esc(label.absent)}${walk?.reason ? ' · '+esc(reasons[walk.reason] || reasons['walk check failed']) : ''}`;
      host.innerHTML = animation;
      const codePanel = data.detailOnly ? null : card.querySelector('[data-code-panel]');
      // the walk opens on the intent tabs, plus "Other changes"
      if (codePanel) codePanel.innerHTML = `<div class="diff-walk dwalk2">${valid ? `<p class="walk-head kcount">${esc(label.head)} <code>${esc(walk.head.slice(0,7))}</code></p><div class="walk-tabs wtabs" role="tablist">${(data.intents || []).map((intent,i)=>`<button type="button" data-intent-tab="${i+1}" role="tab"><b>${esc(t("intentHeading"))} ${i+1}</b><span>${esc(words(intent?.text || ''))}</span></button>`).join('')}<button type="button" data-other-tab role="tab"><b>${esc(label.other)}</b><span>${esc(String(walk.other.length))}</span></button></div><div class="dwalk" data-blocks tabindex="0"></div>` : `<p role="status">${message}</p>`}</div>`;
      const fallback = host.parentElement.querySelector('.change-fallback');
      if (fallback) fallback.hidden = Boolean(animation);
      const checkPanel = data.detailOnly ? null : card.querySelector('[data-check-panel]');
      const codeTab = data.detailOnly ? null : card.querySelector('[data-code-tab]'), checkTab = data.detailOnly ? null : card.querySelector('[data-check-tab]');
      let frame, last;
      state.dispose = () => { if (frame) cancelAnimationFrame(frame); frame = null; };
      function stop() { state.playing=false; if(frame) cancelAnimationFrame(frame); frame=null; paint(); }
      function paint() {
        if (!animation) return;
        const playButton=host.querySelector('[data-play]');
        // the icon is drawn in CSS: the scene's drawing is the section's one svg
        playButton.innerHTML=`<span class="pi${state.playing ? ' pause' : ''}" aria-hidden="true"></span><span class="vh">${esc(state.playing ? label.pause : label.play)}</span>`;
        host.querySelector('[data-scrub]').value=state.phase;
        host.querySelector('.scene-view').dataset.phase=state.phase < .67 ? 'before' : state.phase < 1.34 ? 'change' : 'after';
        host.querySelectorAll('[data-scene-id]').forEach(el => {
          const mode=el.dataset.state;
          el.style.opacity=mode==='new' ? String(Math.min(1, Math.max(0, (state.phase-.6)/.7))) : mode==='gone' ? String(Math.max(.15, .65-state.phase*.25)) : '1';
          if (mode === 'new' && el.classList.contains('scene-edge')) {
            const path=el.querySelector('path'), length=path.getTotalLength();
            path.style.strokeDasharray=String(length);path.style.strokeDashoffset=String(length*(1-Math.min(1,Math.max(0,(state.phase-.6)/.7))));
          }
          el.classList.toggle('scene-dim',state.highlight.length>0 && el.dataset.change && !state.highlight.includes(el.dataset.change));
        });
        host.querySelectorAll('.scene-controls [data-phase]').forEach(el=>el.setAttribute('aria-pressed',String(Number(el.dataset.phase)===Math.round(state.phase))));
        const token=host.querySelector('.scene-token');
        const ids=state.phase < 1 ? scene.tokens.before : scene.tokens.after;
        const progress=state.phase < 1 ? state.phase : state.phase-1;
        const index=Math.min(ids.length-1,Math.floor(progress*ids.length));
        const edge=host.querySelector(`[data-scene-id="${ids[index]}"] path`);
        if(edge && !reduced()) {const p=edge.getPointAtLength(edge.getTotalLength()*(progress===1 ? 1 : progress*ids.length-index));token.setAttribute('cx',p.x);token.setAttribute('cy',p.y);token.style.display='';} else token.style.display='none';
        const counter=host.querySelector('[data-counter]');if(counter) counter.textContent=state.phase<1 ? scene.counter.before : scene.counter.after;
      }
      function tick(now) {
        if(!host.isConnected){stop();return;}
        state.phase=Math.min(2,state.phase+(now-last)/4000);last=now;paint();
        if(state.phase===2)stop();else frame=requestAnimationFrame(tick);
      }
      function play() { if(!animation || reduced())return; if(state.playing){stop();return;}if(state.phase>=2)state.phase=0;state.playing=true;last=performance.now();frame=requestAnimationFrame(tick);paint(); }
      function showBlocks() {
        const panel=codePanel?.querySelector('[data-blocks]'); if(!panel)return;
        codePanel.querySelectorAll('[data-intent-tab]').forEach(el=>el.setAttribute('aria-selected',String(!state.other && Number(el.dataset.intentTab)===state.intent)));
        codePanel.querySelector('[data-other-tab]').setAttribute('aria-selected',String(state.other));
        panel.classList.toggle('dwalk',!state.other);
        if(state.other) {
          panel.innerHTML=`<ul class="walk-other otherpane">${walk.other.map(file=>`<li>${link(file.url || (walk.intents.flatMap(i=>i.key)[0]?.url || (data.diffUrl ? data.diffUrl + '/files' : '')).split('#')[0],esc(file.file))} · ${esc(file.hunks)}${file.kinds ? ' · '+esc(file.kinds.join(', ')) : ''}</li>`).join('')}</ul>`;
          panel.querySelectorAll('.walk-other a').forEach(async (a, i) => {
            const bytes = new TextEncoder().encode(walk.other[i].file);
            const digest = await crypto.subtle.digest('SHA-256', bytes);
            if (a.isConnected) a.href = a.href.split('#')[0] + '#diff-' + Array.from(new Uint8Array(digest), b=>b.toString(16).padStart(2,'0')).join('');
          });
          return;
        }
        const keys=keyFor(state.intent); state.block=Math.min(state.block,Math.max(0,keys.length-1));
        // the key blocks on the left, the current block's code in the middle, and
        // its explanation with the step controls on the right
        const block=keys[state.block], noted=row=>block.line_note?.line === (block.side==='L' ? row.old : row.new);
        panel.innerHTML=keys.length ? `<nav class="dtoc"><ol class="ksteps">${keys.map((key,i)=>`<li><button type="button" class="walk-block${i===state.block ? ' active' : ''}" data-block="${i}" aria-current="${i===state.block}"><span class="wi">${i+1}</span><span><code>${esc(key.file.split('/').pop())}:${esc(key.start)}</code><small>${esc(locale(key.note))}</small></span></button></li>`).join('')}</ol></nav>` +
          `<section class="dcode"><header><code>${link(block.url,esc(block.file)+':'+esc(block.start))}</code></header><div class="crows">${block.rows.map(row=>`<div class="walk-row crow ${esc(row.type)}${noted(row) ? ' noted crit' : ''}"><span class="walk-line cn">${esc(row.old ?? '')}\t${esc(row.new ?? '')}</span><span class="cm" aria-hidden="true">${row.type==='add' ? '+' : row.type==='del' ? '-' : ''}</span><code>${esc(row.text)}</code>${noted(row) ? `<em class="cnote">${esc(locale(block.line_note))}</em>` : ''}</div>`).join('')}</div></section>` +
          `<aside class="dexplain"><div class="dnav walk-navigation"><button type="button" data-previous aria-label="${esc(label.previous)}">↑</button><span class="dpos">${state.block+1} / ${keys.length}</span><button type="button" data-next aria-label="${esc(label.next)}">↓</button><span class="dprog"><i style="width:${Math.round(100*(state.block+1)/keys.length)}%"></i></span></div>` +
          `<p class="walk-note dnote">${esc(locale(block.note))}</p>${block.truncated ? `<p class="whelp">${esc(label.omitted).replace('{before}',esc(block.truncated.before)).replace('{after}',esc(block.truncated.after))}</p>` : ''}</aside>` : `<p>${esc(label.empty)}</p>`;
        const move = delta => { state.block=Math.max(0,Math.min(keys.length-1,state.block+delta));showBlocks(); };
        panel.querySelector('[data-previous]')?.addEventListener('click',()=>move(-1));
        panel.querySelector('[data-next]')?.addEventListener('click',()=>move(1));
        panel.querySelectorAll('[data-block]').forEach(el=>el.onclick=()=>{state.block=Number(el.dataset.block);lightStep();showBlocks();});
        lightStep();
      }
      function lightStep() {
        const block=keyFor(state.intent)[state.block], ids=[...(block?.step?.nodes || []),...(block?.step?.edges || [])];
        host.querySelectorAll('[data-scene-id]').forEach(el=>el.classList.toggle('scene-lit',ids.includes(el.dataset.sceneId)));
      }
      function openIntent(n) {state.intent=n;state.block=0;state.other=false;state.opened=true;tabs();showBlocks();codePanel?.scrollIntoView({block:'nearest'});}
      function tabs() {
        if (!codePanel) return;
        codePanel.toggleAttribute('hidden',!state.opened);
        checkPanel?.toggleAttribute('hidden',state.opened);
        codeTab?.setAttribute('aria-selected',String(state.opened));
        checkTab?.setAttribute('aria-selected',String(!state.opened));
      }
      // The banner's inputs live in the card state, so a remount (an update or
      // a locale switch) rebuilds it in the current locale with the same target.
      function showBanner() {
        const banner=host.querySelector('.scene-banner');
        if (!banner || !state.banner) return false;
        const {intent:n, badgeJump}=state.banner;
        banner.hidden=false;
        banner.innerHTML=`<button data-show-all>${esc(label.all)}</button>`+(badgeJump === false ? `<button disabled>${esc(label.its)}</button>` : keyFor(n).length ? `<button data-its-code>${esc(label.its)}</button>` : !valid ? `<button disabled>${esc(label.its)}</button><span>${esc(label.absent)}</span>` : '');
        banner.querySelector('[data-show-all]').onclick=()=>{state.highlight=[];state.banner=null;banner.hidden=true;paint();};
        const jump=banner.querySelector('[data-its-code]');if(jump)jump.onclick=()=>openIntent(n);
        return true;
      }
      function highlight(n, changes, badgeJump = null) {
        state.highlight=changes;state.banner={intent:n,badgeJump};paint();
        if(!showBanner() && keyFor(n).length)openIntent(n);
        if(!state.playing)play();
      }
      card.querySelectorAll('.intent-row').forEach((row,i) => {
        row.querySelectorAll('.walk-intent-link').forEach(el=>el.remove());
        const slot=row.querySelector('.kg') || row;
        const number=i+1, changes=scene?.changes.filter(c=>c.intents.includes(number)) || [];
        if(!scene && !valid)return;
        const button=document.createElement('button');button.type='button';button.className='walk-intent-link';
        button.textContent=changes.length ? changes.map(c=>c.id).join(' · ') : label.its;
        if(!scene && !keyFor(number).length)button.disabled=true;
        button.onclick=()=>highlight(number,changes.map(c=>c.id));slot.append(button);
      });
      host.querySelector('[data-play]')?.addEventListener('click',play);
      host.querySelector('[data-scrub]')?.addEventListener('input',e=>{const value=Number(e.target.value);stop();state.phase=value;paint();});
      host.querySelectorAll('.scene-controls [data-phase]').forEach(el=>el.onclick=()=>{stop();state.phase=Number(el.dataset.phase);paint();});
      host.querySelectorAll('[data-badge]').forEach(el=>el.onclick=()=>{
        const id=el.dataset.badge, change=scene.changes.find(c=>c.id===id);
        const target=valid && walk.intents.find(i=>i.key.some(b=>b.changes?.includes(id)));
        highlight(change.intents[0],[id],Boolean(target));
        if(target){openIntent(target.intent);state.block=target.key.findIndex(b=>b.changes?.includes(id));showBlocks();}
      });
      // the card's two tabs outlive a remount, so they take one handler each
      if (codeTab) codeTab.onclick=()=>{state.opened=true;tabs();showBlocks();};
      if (checkTab && codePanel) checkTab.onclick=()=>{state.opened=false;tabs();};
      codePanel?.querySelectorAll('[data-intent-tab]').forEach(el=>el.onclick=()=>openIntent(Number(el.dataset.intentTab)));
      codePanel?.querySelector('[data-other-tab]')?.addEventListener('click',()=>{state.other=true;showBlocks();});
      codePanel?.querySelector('[data-blocks]')?.addEventListener('keydown',e=>{
        if(e.key==='ArrowUp' || e.key==='ArrowDown'){e.preventDefault();state.block=Math.max(0,Math.min(keyFor(state.intent).length-1,state.block+(e.key==='ArrowDown'?1:-1)));showBlocks();}
        if(e.code==='Space'){e.preventDefault();play();}
      });
      showBlocks();tabs();paint();
      if(state.banner)showBanner();
      if(reduced()){state.phase=1;state.playing=false;paint();}
      // No timer remains once its DOM owner is replaced.
      if(animation && !reduced() && (fresh || state.playing)){state.playing=false;play();}
    });
  }
  window.WALK={mount};
})();
