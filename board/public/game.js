// One live iframe, in two sizes. The workflow nodes themselves move into the
// drawer, preserving the board's controls, confirmations and translated errors.
(() => {
  const get=(store,key,fallback)=>{try{return store.getItem(key) ?? fallback;}catch{return fallback;}};
  const put=(store,key,value)=>{try{store.setItem(key,value);}catch{}};
  let hidden=get(localStorage,'board.voyage.hidden','0')==='1';
  let full=get(sessionStorage,'board.voyage.mode','panel')==='full';
  const narrow=matchMedia('(max-width:650px)');
  let size=get(localStorage,'board.voyage.size',null);
  if(size!=='strip' && size!=='full-size')size=null;
  const isStrip=()=>size===null?narrow.matches:size==='strip';
  let lastEscape=null, snapshot=null, fighting=false, lang='en', label=k=>k;
  const listeners=new Set();
  let pending=[], cancelDelivery=null;
  function clearDelivery(){cancelDelivery?.();cancelDelivery=null;pending=[];}
  function deliverLater(s){
    // Replay and ship reconciliation belong to the stage, not the board's
    // render stack. Retain every snapshot in order (including short-lived
    // outcomes), and only notify subscribers present when it arrived.
    if(hidden)return;
    pending.push({snapshot:s,recipients:[...listeners]});
    if(cancelDelivery)return;
    const deliver=()=>{
      cancelDelivery=null;
      const batch=pending;pending=[];
      for(const {snapshot,recipients} of batch)
        for(const fn of recipients)if(listeners.has(fn))fn(snapshot);
    };
    if(window.requestIdleCallback){
      const id=requestIdleCallback(deliver,{timeout:100});
      cancelDelivery=()=>cancelIdleCallback(id);
    } else {
      const id=setTimeout(deliver,0);cancelDelivery=()=>clearTimeout(id);
    }
  }
  const panel=document.createElement('section'); panel.id='voyage';
  const bar=document.createElement('div');bar.id='voyage-bar';
  const toggle=document.createElement('button');toggle.type='button';toggle.id='voyage-toggle';
  const drawerButton=document.createElement('button');drawerButton.type='button';drawerButton.id='voyage-workflow';
  const sizeButton=document.createElement('button');sizeButton.type='button';sizeButton.id='voyage-size';
  sizeButton.innerHTML='<span aria-hidden="true">↕</span>';
  const stage=document.createElement('div');stage.id='voyage-mount';
  const drawer=document.createElement('aside');drawer.id='voyage-drawer';
  bar.append(toggle,sizeButton,drawerButton);panel.append(bar,stage,drawer);
  document.querySelector('#counts').before(panel);
  const homes=['#readOnly','#counts','#deckwrap','.lanes-wrap'].map(selector=>{
    const node=document.querySelector(selector), marker=document.createComment('voyage workflow home');
    node.before(marker);return {node,marker};
  });
  let iframe=null, workflowInDrawer=false, cancelMount=null;
  function clearMount(){cancelMount?.();cancelMount=null;}
  function mountLater(){
    // The board owns startup. Never load the stage before its first completed
    // render or extend the page's load event with the iframe's own work.
    if(hidden || !snapshot || iframe || cancelMount || document.readyState!=='complete')return;
    const mount=()=>{
      cancelMount=null;
      if(hidden || iframe)return;
      stage.hidden=false;iframe=document.createElement('iframe');iframe.id='voyage-stage';iframe.name='voyage-stage';
      const query=new URLSearchParams({embed:'1',lang});
      const project=new URLSearchParams(location.search).get('project'); if(project) query.set('project',project);
      iframe.src='/voyage2d/index.html?'+query;
      iframe.setAttribute('sandbox','allow-scripts allow-same-origin');
      iframe.title=label('voyageTitle');stage.append(iframe);
    };
    if(window.requestIdleCallback){
      const id=requestIdleCallback(mount);cancelMount=()=>cancelIdleCallback(id);
    } else {
      const id=setTimeout(mount,0);cancelMount=()=>clearTimeout(id);
    }
  }
  function labels(){
    toggle.textContent=label(hidden?'voyageShow':full?'voyagePanel':'voyageFull');
    drawerButton.textContent=label('voyageWorkflow');
    sizeButton.title=label(isStrip()?'voyageGrow':'voyageShrink');
    sizeButton.setAttribute('aria-label',sizeButton.title);
    sizeButton.setAttribute('aria-expanded',String(!isStrip()));
    drawer.setAttribute('aria-label',label('voyageWorkflow'));
    if(iframe) iframe.title=label('voyageTitle');
  }
  function render(){
    document.body.classList.toggle('voyage-full',full && !hidden);
    document.body.classList.toggle('voyage-hidden',hidden);
    panel.classList.toggle('voyage-strip',isStrip());
    sizeButton.hidden=hidden || full;
    drawerButton.hidden=hidden || !full;
    drawer.hidden=hidden || !full;
    const inDrawer=full && !hidden;
    if(inDrawer!==workflowInDrawer){
      for(const {node,marker} of homes) inDrawer?drawer.append(node):marker.after(node);
      workflowInDrawer=inDrawer;
    }
    if(hidden){clearMount();clearDelivery();iframe?.remove();iframe=null;fighting=false;stage.hidden=true;}
    else mountLater();
    labels();
  }
  function boardControlOpen(){
    return [...document.querySelectorAll('[role="menu"],[role="dialog"],[role="alertdialog"],dialog[open]')]
      .some(node=>!node.hidden && node.getClientRects().length>0);
  }
  function key(key){
    if(boardControlOpen()){lastEscape=null;return;}

    if(key==='Escape'){
      const now=performance.now();
      if(lastEscape!==null && now-lastEscape<=400){
        hidden=!hidden;full=false;lastEscape=null;
        put(localStorage,'board.voyage.hidden',hidden?'1':'0');
      } else {lastEscape=now;full=false;}
    } else if(key.toLowerCase()==='f' && !hidden) full=!full;
    put(sessionStorage,'board.voyage.mode',full?'full':'panel');render();
  }
  window.VOYAGE={
    token:()=>get(sessionStorage,'board.token',''),
    subscribe(fn){listeners.add(fn);if(snapshot)fn(snapshot);return ()=>listeners.delete(fn);},
    update(s,t,l){snapshot=s;label=t;lang=l;labels();deliverLater(s);mountLater();},
    key, fight(on){fighting=on;}, get fighting(){return fighting;},get hidden(){return hidden;}
  };
  toggle.onclick=()=>{if(hidden){hidden=false;put(localStorage,'board.voyage.hidden','0');render();}else key('f');};
  sizeButton.onclick=()=>{size=isStrip()?'full-size':'strip';put(localStorage,'board.voyage.size',size);panel.classList.add('voyage-resizing');render();setTimeout(()=>panel.classList.remove('voyage-resizing'),250);};
  narrow.addEventListener('change',()=>{if(size===null)render();});
  drawerButton.onclick=()=>{drawer.hidden=!drawer.hidden;drawerButton.setAttribute('aria-expanded',String(!drawer.hidden));};
  // Capture the open control before the board's bubbling handler closes it.
  addEventListener('keydown',e=>{
    if(boardControlOpen()){lastEscape=null;return;}
    if(e.repeat || e.ctrlKey || e.metaKey || e.altKey || e.target.closest?.('input,textarea,select,[contenteditable]'))return;
    if(e.key==='Escape') key(e.key);
    else if(e.key.toLowerCase()==='f'){e.preventDefault();key(e.key);}
  },true);
  addEventListener('storage',e=>{if(e.key==='board.voyage.hidden'){hidden=e.newValue==='1';render();}});
  addEventListener('load',mountLater,{once:true});
  addEventListener('pagehide',()=>{clearMount();clearDelivery();});
  render();
})();
