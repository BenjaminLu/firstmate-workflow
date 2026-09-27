// The game's two looks (p6): "manga" (the default: the painted scene with inked FX and
// manga cut-ins) and "p5" (a Persona-style whole-scene look: the 3D frame graded to
// black, red and white with bold black edges and a halftone screen; the board, HUD,
// cut-ins, impact frames, damage numbers and the title card in red/black/white with
// tilted panels). ?style=p5 at load; the Y key toggles. The grade is an SVG filter on
// the canvas (gradient map + an edge kernel), so it costs no extra 3D pass.
const SVG = `<svg id="p5-defs" width="0" height="0" style="position:absolute" aria-hidden="true"><defs>
<filter id="p5grade" x="0" y="0" width="100%" height="100%" color-interpolation-filters="sRGB">
  <feColorMatrix in="SourceGraphic" type="matrix" values="0.3 0.59 0.11 0 0  0.3 0.59 0.11 0 0  0.3 0.59 0.11 0 0  0 0 0 1 0" result="lum"/>
  <feComponentTransfer in="lum" result="map">
    <feFuncR type="discrete" tableValues="0.04 0.86 0.86 0.98 1"/>
    <feFuncG type="discrete" tableValues="0.02 0.06 0.06 0.93 1"/>
    <feFuncB type="discrete" tableValues="0.04 0.1 0.1 0.9 1"/>
  </feComponentTransfer>
  <feConvolveMatrix in="lum" order="3" kernelMatrix="-1 -1 -1  -1 8 -1  -1 -1 -1" edgeMode="duplicate" result="edge"/>
  <feColorMatrix in="edge" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  5 5 5 0 -0.35" result="edgeA"/>
  <feFlood flood-color="#050205" result="ink"/>
  <feComposite in="ink" in2="edgeA" operator="in" result="lines"/>
  <feMerge><feMergeNode in="map"/><feMergeNode in="lines"/></feMerge>
</filter></defs></svg>`;
const CSS = `
body.p5 canvas#c{filter:url(#p5grade)}
body.p5::after{content:"";position:fixed;inset:0;pointer-events:none;z-index:2;background:radial-gradient(circle,rgba(0,0,0,.28) 24%,transparent 27%) 0 0/7px 7px;mix-blend-mode:multiply}
body.p5{--ink:#0b0708;--sail:#fff;--tar:#0b0708;--brass:#e3121b;--brass-hi:#ff2a33;--ensign:#e3121b;--glass:#fff;--prussian:#0b0708;--panel:rgba(12,8,9,.94);--panel-edge:#e3121b}
body.p5 .sheet{border:3px solid #fff;border-radius:0;box-shadow:8px 8px 0 #e3121b;color:#fff;transform:rotate(-1.2deg)}
body.p5 .sheet *{color:inherit}
body.p5 button{background:#fff;color:#0b0708;border:2px solid #0b0708;border-radius:0;font-weight:800;transform:skewX(-8deg)}
body.p5 button[aria-pressed="true"]{background:#e3121b;color:#fff;border-color:#fff}
body.p5 .lane h3{background:#e3121b;color:#fff;transform:skewX(-10deg);padding:2px 8px;letter-spacing:.06em;text-transform:uppercase}
body.p5 .card{background:#fff;color:#0b0708;border:2px solid #0b0708;border-radius:0;box-shadow:4px 4px 0 #e3121b}
body.p5 .card *{color:#0b0708}
body.p5 .tag{background:#0b0708!important;color:#fff!important;border-radius:0}
body.p5 #tally b{color:#fff;font-style:italic}
body.p5 #banner{background:#0b0708;color:#fff;border:3px solid #e3121b;transform:translateX(-50%) rotate(-3deg);font-style:italic;text-transform:uppercase}
body.p5 #caption{background:#fff;color:#0b0708;border:3px solid #0b0708;box-shadow:6px 6px 0 #e3121b;border-radius:0}
body.p5 .dcard{background:#fff!important;color:#0b0708;border:4px solid #0b0708!important;box-shadow:10px 10px 0 #e3121b;transform:rotate(-2deg)}
body.p5 .dcard .band{background:#0b0708!important;color:#fff}
body.p5 #chart{filter:grayscale(1) contrast(1.4)}
body.p5 .sp-dmg{color:#fff!important;-webkit-text-stroke:4px #0b0708;text-shadow:7px 7px 0 #e3121b}
body.p5 #titlecard .t1{color:#fff;-webkit-text-stroke:5px #0b0708;text-shadow:10px 10px 0 #e3121b;font-style:italic}
body.p5 #titlecard .rule{background:#e3121b;height:9px;transform:skewX(-20deg)}
body.p5 #titlecard .t2{background:#0b0708;color:#fff;display:inline-block;padding:.1em .6em;transform:rotate(-2deg)}
body.p5 #titlecard .t3{background:#fff;color:#0b0708;display:inline-block;padding:.1em .5em;text-shadow:none;transform:rotate(1.5deg)}
body.p5 #titlecard.show{background:repeating-conic-gradient(from 0deg at 50% 60%,rgba(227,18,27,.55) 0 8deg,rgba(0,0,0,.45) 8deg 16deg)}
body.p5 #tools, body.p5 #board{transform:none}
`;
let STYLE = "manga";
export const style = () => STYLE;
export function initLook() {
  if (!document.getElementById("p5-defs")) {
    document.body.insertAdjacentHTML("afterbegin", SVG);
    const st = document.createElement("style");
    st.textContent = CSS;
    document.head.appendChild(st);
  }
  const q = new URLSearchParams(location.search);
  setLook(q.get("style") === "p5" || q.get("fx") === "p5" ? "p5" : "manga");
}
export function setLook(s, specials = null) {
  STYLE = s;
  document.body.classList.toggle("p5", s === "p5");
  specials?.setStyle(s);
}
