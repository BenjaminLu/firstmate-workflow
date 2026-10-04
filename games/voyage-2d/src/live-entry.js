import { BoardSource } from './board-source.js';
// The Live build imports this before main; Playground never imports it.
const host = window.parent !== window && window.parent.location.origin === location.origin
  ? window.parent.VOYAGE : null;
window.__voyageLive = new BoardSource({token:()=>host?.token() || ''});
if(host) {
  const unsubscribe=host.subscribe(snapshot=>window.__voyageLive.accept(snapshot));
  addEventListener('pagehide',()=>{unsubscribe();window.__voyageLive.close();},{once:true});
  addEventListener('keydown',e=>{
    if(e.key==='Escape' || (e.key.toLowerCase()==='f' && !e.target.closest?.('input,textarea,select,[contenteditable]'))) {
      if(!e.repeat && !e.ctrlKey && !e.metaKey && !e.altKey) {e.preventDefault();e.stopImmediatePropagation();if(e.key==='Escape')dispatchEvent(new Event('voyage-escape'));host.key(e.key);}
    }
  },true);
}
