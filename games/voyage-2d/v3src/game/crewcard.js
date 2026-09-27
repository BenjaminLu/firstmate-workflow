// p6 (the captain): the tag over a head carries only the name and the project flag; the
// rest is a detail card anchored to the crewman, one at a time, on hover, keyboard focus
// or a tap (a second tap or Esc closes it). Each visible tag has a transparent button
// laid over it, so the tags are reachable by Tab and by touch. Tags never overlap: the
// nearest keeps its place, a crowded one steps up once, the rest hide until there is room.
import * as THREE from "three";
import { tr } from "./i18n.js";

const CSS = `
#crewtags{position:fixed;inset:0;pointer-events:none;overflow:hidden}
#crewtags button{position:absolute;pointer-events:auto;background:transparent;border:0;padding:0;margin:0;min-width:0;min-height:0;cursor:pointer;border-radius:8px}
#crewtags button:focus-visible{outline:3px solid #f1b43c;outline-offset:2px}
#crewcard{position:fixed;z-index:30;min-width:220px;max-width:min(320px,86vw);background:rgba(244,234,210,.97);color:#1c1a24;border:2px solid #2a2016;border-radius:10px;box-shadow:0 10px 28px rgba(0,0,0,.35);padding:8px 10px;font:500 13px/1.35 'Barlow Semi Condensed','Nunito',system-ui,sans-serif;pointer-events:auto}
#crewcard .row{display:grid;grid-template-columns:auto 1fr;gap:0 10px;padding:1px 0;border-bottom:1px dotted rgba(42,32,22,.25)}
#crewcard .row:last-child{border-bottom:0}
#crewcard .k{font-weight:700;color:#5a4a36}
#crewcard .flag{display:inline-block;width:12px;height:9px;margin-right:6px;clip-path:polygon(0 0,100% 50%,0 100%);vertical-align:0}
body.p5 #crewcard{background:#fff;border:3px solid #0b0708;border-radius:0;box-shadow:8px 8px 0 #e3121b;transform:rotate(-1deg)}
body.p5 #crewcard .k{color:#e3121b}
`;
// a project's colour: stable from its name
export function projectColour(name = "") {
  let h = 0;
  for (const ch of name) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return `hsl(${h % 360} 70% 45%)`;
}

export class CrewCards {
  constructor(camera) {
    this.camera = camera;
    this.info = new Map(); // id -> [[label, value], ...]
    this.btn = new Map();
    this.open = null; // { id, pinned }
    const st = document.createElement("style");
    st.textContent = CSS;
    document.head.appendChild(st);
    this.root = document.createElement("div");
    this.root.id = "crewtags";
    const canvas = document.getElementById("c");
    (canvas?.parentNode || document.body).insertBefore(this.root, canvas?.nextSibling || null);
    this.card = document.createElement("div");
    this.card.id = "crewcard";
    this.card.setAttribute("role", "dialog");
    this.card.setAttribute("aria-label", "Crew detail");
    this.card.hidden = true;
    document.body.appendChild(this.card);
    addEventListener("keydown", (e) => e.key === "Escape" && this.open && (this.close(), e.stopPropagation()), true);
    addEventListener("pointerdown", (e) => this.open?.pinned && !this.card.contains(e.target) && ![...this.btn.values()].includes(e.target) && this.close());
  }
  setInfo(id, name, rows) {
    this.info.set(id, { name, rows });
    if (this.open?.id === id) this.fill(id);
    const b = this.btn.get(id);
    if (b) b.setAttribute("aria-label", name);
  }
  button(id) {
    let b = this.btn.get(id);
    if (b) return b;
    b = document.createElement("button");
    b.type = "button";
    b.setAttribute("aria-label", this.info.get(id)?.name || id);
    b.addEventListener("pointerenter", (e) => e.pointerType === "mouse" && !this.open?.pinned && this.show(id, false));
    b.addEventListener("pointerleave", (e) => e.pointerType === "mouse" && !this.open?.pinned && this.close());
    b.addEventListener("focus", () => !this.open?.pinned && this.show(id, false));
    b.addEventListener("blur", () => !this.open?.pinned && this.close());
    b.addEventListener("click", () => (this.open?.id === id && this.open.pinned ? this.close() : this.show(id, true)));
    this.root.appendChild(b);
    this.btn.set(id, b);
    return b;
  }
  fill(id) {
    const I = this.info.get(id);
    if (!I) return;
    this.card.innerHTML = "";
    for (const [k, v, flag] of I.rows) {
      const r = document.createElement("div");
      r.className = "row";
      const a = document.createElement("span");
      a.className = "k";
      a.textContent = tr(k);
      const b = document.createElement("span");
      if (flag) {
        const f = document.createElement("i");
        f.className = "flag";
        f.style.background = flag;
        b.appendChild(f);
      }
      b.appendChild(document.createTextNode(tr(String(v))));
      r.append(a, b);
      this.card.appendChild(r);
    }
  }
  show(id, pinned) {
    this.open = { id, pinned };
    this.fill(id);
    this.card.hidden = false;
    this.place();
  }
  close() {
    this.open = null;
    this.card.hidden = true;
  }
  place() {
    const b = this.open && this.btn.get(this.open.id);
    if (!b || b.hidden) return;
    const r = b.getBoundingClientRect(), cw = this.card.offsetWidth, ch = this.card.offsetHeight;
    let x = r.right + 8, y = r.top - ch * 0.3;
    if (x + cw > innerWidth - 8) x = r.left - cw - 8;
    x = Math.max(8, Math.min(innerWidth - cw - 8, x));
    y = Math.max(8, Math.min(innerHeight - ch - 8, y));
    this.card.style.left = x + "px";
    this.card.style.top = y + "px";
  }
  // every frame: screen rects of the tags, the declutter, the buttons
  update(crew, show) {
    const cam = this.camera, placed = [];
    const H = innerHeight, W = innerWidth;
    const f = H / (2 * Math.tan((cam.fov * Math.PI) / 360));
    const items = [];
    const v = new THREE.Vector3(), s = new THREE.Vector3();
    for (const c of crew) {
      const p = c.pennant;
      if (!p) continue;
      p.updateWorldMatrix(true, false);
      p.getWorldScale(s);
      v.set(0, -(p.userData.lift || 0), 0);
      p.localToWorld(v.set(p.position.x, p.position.y - (p.userData.lift || 0), p.position.z).applyMatrix4(new THREE.Matrix4()).set(0, 0, 0));
      const base = p.getWorldPosition(new THREE.Vector3()).sub(new THREE.Vector3(0, (p.userData.lift || 0) * (s.y / (p.scale.y || 1)), 0));
      const d = base.distanceTo(cam.position);
      const q = base.clone().project(cam);
      const w = (s.x * f) / d, h = (s.y * f) / d;
      items.push({ c, d, x: (q.x * 0.5 + 0.5) * W, y: (-q.y * 0.5 + 0.5) * H, w, h, front: q.z < 1, lh: s.y * 1.08 });
    }
    items.sort((a, b) => a.d - b.d);
    const hit = (r) => placed.some((o) => r.x < o.x + o.w && r.x + r.w > o.x && r.y < o.y + o.h && r.y + r.h > o.y);
    for (const it of items) {
      const p = it.c.pennant;
      let r = { x: it.x - it.w / 2, y: it.y - it.h / 2, w: it.w, h: it.h };
      let lift = 0, ok = show && it.front && p.material.opacity > 0.3;
      if (ok && hit(r)) {
        r = { ...r, y: r.y - it.h * 1.08 };
        lift = 1;
        if (hit(r)) ok = false;
      }
      const want = lift ? it.lh / (p.getWorldScale(new THREE.Vector3()).y / p.scale.y) : 0;
      p.userData.lift = (p.userData.lift || 0) + (want - (p.userData.lift || 0)) * 0.25;
      p.userData.clutter = !ok && show && it.front;
      if (ok) placed.push(r);
      const b = this.button(it.c.id);
      b.hidden = !ok;
      if (ok) (b.style.left = r.x + "px"), (b.style.top = r.y + "px"), (b.style.width = r.w + "px"), (b.style.height = r.h + "px");
      else if (this.open?.id === it.c.id) this.close();
    }
    if (this.open) this.place();
  }
}
