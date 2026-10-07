// A viewer preference, independent of the board's data and language rendering.
(() => {
  const html=document.documentElement, button=document.getElementById('themeToggle');
  let theme;
  try { theme=localStorage.getItem('board.theme'); } catch {}
  if(theme!=='light' && theme!=='dark') theme=matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light';
  function paint(){html.dataset.theme=theme;button.setAttribute('aria-pressed',String(theme==='dark'));}
  button.onclick=()=>{
    theme=theme==='dark'?'light':'dark';
    try { localStorage.setItem('board.theme',theme); } catch {}
    paint();
  };
  paint();
})();
