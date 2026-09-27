// The page around the ship: tally, the board (six lanes, cards that slide),
// the voyage chart, the roster with service records, the ship's customs, the
// decision cards and the battle HUD. It renders from sim state and dispatches
// intents; it never changes the simulation itself.
import { CONFIG } from "../sim/config.js";
import { rankName, nextRank, tally } from "../sim/sim.js";
import { SKILLS } from "../sim/battle.js";

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const LANES = [
  ["issues", "Issues"],
  ["backlog", "Backlog"],
  ["ready", "Ready"],
  ["working", "Working"],
  ["review", "Review"],
  ["merged", "Merged"],
];
const KIND = {
  merge: { frame: "#b88a30", emb: "⚓", name: "Merge" },
  choice: { frame: "#1f2f5c", emb: "✺", name: "Choice" },
  scope: { frame: "#3aa590", emb: "⌖", name: "Scope" },
  kraken: { frame: "#5a2f8f", emb: "☸", name: "The kraken" },
};
const RITUALS = [
  ["order", "The order: bell, whistle, the helm spins twice"],
  ["salvo", "The merge salvo"],
  ["port", "Making port"],
  ["salute", "A salute on a first-round approval"],
  ["clearing", "Clearing and a cheer"],
  ["weather", "Weather, not blame"],
];

export class UI {
  constructor(handlers) {
    this.h = handlers;
    this.cards = new Map();
    this.prevTally = null;
    this.bannerTimer = 0;
    this.open = { board: true, roster: false, customs: false };
    this.records = new Set();
    this.pick = null;
    this.decisionShown = null;
    this.chartShip = null;
    this._build();
  }
  _build() {
    const h = this.h;
    // lanes
    $("lanes").innerHTML = LANES.map(([id, name]) => `<div class="lane" data-lane="${id}"><h3>${name}<span class="num" data-count="${id}">0</span></h3><div class="cards" data-cards="${id}"></div></div>`).join("");
    // actions
    const acts = [
      ["N", "New task", "newTask"],
      ["O", "Dispatch", "dispatch"],
      ["U", "Open PR", "openPR"],
      ["M", "Merge", "merge"],
      ["V", "Approve", "approve"],
      ["J", "Reject", "reject"],
      ["F", "Red check", "redCheck"],
      ["G", "Green", "greenCheck"],
    ];
    $("actions").innerHTML = acts.map(([k, l, a]) => `<button data-act="${a}" title="${l} (${k})">${l}<kbd>${k}</kbd></button>`).join("");
    $("actions").onclick = (e) => {
      const b = e.target.closest("button[data-act]");
      if (b) h.act(b.dataset.act);
    };
    // tools
    $("b-board").onclick = () => this.toggle("board");
    $("b-hideboard").onclick = () => this.toggle("board", false);
    $("b-collapse").onclick = () => {
      $("board").classList.toggle("collapsed");
      $("b-collapse").textContent = $("board").classList.contains("collapsed") ? "▸" : "▾";
    };
    $("b-roster").onclick = () => this.toggle("roster");
    $("b-customs").onclick = () => this.toggle("customs");
    $("b-sound").onclick = () => h.sound();
    $("b-cam").onclick = () => h.camera();
    $("b-demo").onclick = () => h.demo();
    for (const b of document.querySelectorAll("[data-close]")) b.onclick = () => this.toggle(b.dataset.close, false);
    // cards: dispatch a ready task, survey an issue, park / drop, set course
    $("lanes").onclick = (e) => {
      const b = e.target.closest("button[data-card]");
      if (b) h.cardAction(b.dataset.card, b.dataset.id);
    };
    // customs
    const sw = $("switches");
    sw.innerHTML =
      RITUALS.map(([id, label]) => `<div class="switch"><label for="r-${id}">${label}</label><button id="r-${id}" data-ritual="${id}" aria-pressed="true">On</button></div>`).join("") +
      `<div class="switch"><label>Sound effects (synthesised; off by default)</label><button id="c-sound" aria-pressed="false">Off</button></div>
       <div class="switch"><label>Cinematic camera (off = free orbit)</label><button id="c-cine" aria-pressed="true">On</button></div>
       <div class="switch"><label>Auto-play a seeded voyage</label><button id="c-demo" aria-pressed="false">Off</button></div>
       <div class="switch"><label>Speed</label><button id="c-speed">1×</button></div>
       <div class="switch"><label>Detail</label><button id="c-detail">high</button></div>`;
    sw.onclick = (e) => {
      const b = e.target.closest("button");
      if (!b) return;
      if (b.dataset.ritual) {
        const on = b.getAttribute("aria-pressed") !== "true";
        b.setAttribute("aria-pressed", on);
        b.textContent = on ? "On" : "Off";
        h.ritual(b.dataset.ritual, on);
      } else if (b.id === "c-sound") h.sound();
      else if (b.id === "c-cine") h.camera();
      else if (b.id === "c-demo") h.demo();
      else if (b.id === "c-speed") h.speed();
      else if (b.id === "c-detail") h.detail();
    };
    $("keys").innerHTML = [
      ["N", "a new task arrives"],
      ["O", "the captain's order: dispatch"],
      ["U", "a pull request opens"],
      ["M", "merge (the salvo)"],
      ["V / J", "the review approves / rejects"],
      ["H", "the worker pushes"],
      ["F / G", "a red check / turns green"],
      ["A–D, Enter", "answer the card"],
      ["1–6", "battle skills"],
      ["Space", "full sail (dodge)"],
      ["Enter", "counter"],
      ["← →", "choose an arm"],
      ["B / L / K", "board / roster / customs"],
      ["S / C / P", "sound / orbit / auto-play"],
      ["X", "hide the interface"],
    ]
      .map(([k, d]) => `<div><span class="key">${k}</span> ${d}</div>`)
      .join("");
    // decision deck
    $("deck").onclick = (e) => {
      const b = e.target.closest("button");
      if (!b) return;
      if (b.dataset.key) this.choose(b.dataset.key);
      if (b.dataset.confirm) this.confirm();
      if (b.dataset.later) this.minimise();
    };
    // chart islands: set course
    $("chartsvg").addEventListener("click", (e) => {
      const g = e.target.closest("[data-island]");
      if (g) h.cardAction("course", g.dataset.island);
    });
  }
  toggle(name, force) {
    const on = force ?? !this.open[name];
    this.open[name] = on;
    $(name).hidden = !on;
    const btn = { board: "b-board", roster: "b-roster", customs: "b-customs" }[name];
    $(btn)?.setAttribute("aria-pressed", on);
    // one panel on the right at a time on small screens
    if (on && innerWidth < 900) for (const o of ["board", "roster", "customs"]) if (o !== name && this.open[o]) this.toggle(o, false);
  }
  setFlag(id, on, label) {
    const b = $(id);
    if (!b) return;
    b.setAttribute("aria-pressed", !!on);
    if (label !== undefined) b.textContent = label;
  }
  banner(text) {
    const b = $("banner");
    b.textContent = text;
    b.classList.add("show");
    clearTimeout(this.bannerTimer);
    this.bannerTimer = setTimeout(() => b.classList.remove("show"), 2600);
  }
  caption(text) {
    $("caption").textContent = text;
  }
  // ---------------------------------------------------------------- render from state
  render(s) {
    this.renderTally(s);
    this.renderBoard(s);
    if (this.open.roster) this.renderRoster(s);
    this.renderChart(s);
    this.renderDecision(s);
  }
  renderTally(s) {
    const t = tally(s);
    const items = [
      ["merged", "merged"],
      ["inFlight", "in flight"],
      ["waiting", "waiting on you"],
      ["blocked", "blocked"],
      ["ready", "ready"],
      ["backlog", "backlog"],
    ];
    if (!this.prevTally) {
      $("tally").innerHTML = items.map(([k, l]) => `<div class="${k}"><b data-t="${k}">0</b><span>${l}</span></div>`).join("");
      this.prevTally = {};
    }
    for (const [k] of items) {
      if (this.prevTally[k] === t[k]) continue;
      const el = document.querySelector(`[data-t="${k}"]`);
      // the figure rolls to its new value
      const from = this.prevTally[k] ?? t[k];
      const to = t[k];
      const start = performance.now();
      const roll = () => {
        const k2 = Math.min(1, (performance.now() - start) / 500);
        el.textContent = Math.round(from + (to - from) * (1 - Math.pow(1 - k2, 3)));
        if (k2 < 1) requestAnimationFrame(roll);
      };
      roll();
      this.prevTally[k] = to;
    }
  }
  renderBoard(s) {
    const first = new Map();
    for (const [id, el] of this.cards) first.set(id, el.getBoundingClientRect());
    const held = new Set(s.kraken.arms);
    const byLane = Object.fromEntries(LANES.map(([l]) => [l, []]));
    for (const t of s.tasks) if (byLane[t.lane]) byLane[t.lane].push(t);
    byLane.merged = byLane.merged.slice(-6);
    const seen = new Set();
    for (const [lane] of LANES) {
      const box = document.querySelector(`[data-cards="${lane}"]`);
      document.querySelector(`[data-count="${lane}"]`).textContent = s.tasks.filter((t) => t.lane === lane).length;
      for (const t of byLane[lane]) {
        seen.add(t.id);
        let el = this.cards.get(t.id);
        const fresh = !el;
        if (!el) {
          el = document.createElement("div");
          el.className = "card fadein";
          this.cards.set(t.id, el);
        }
        const red = s.gate[t.id] === "red";
        const w = t.worker && s.crew.find((c) => c.id === t.worker);
        const html =
          `<b>${esc(t.id)}</b> ${esc(t.title)}` +
          `<div class="tags"><span class="tag">${t.milestone}</span>` +
          (t.issue ? `<span class="tag glass">issue</span>` : `<span class="tag">chat</span>`) +
          (t.round ? `<span class="tag">round ${t.round}</span>` : "") +
          (red ? `<span class="tag red">gate red</span>` : "") +
          (held.has(t.id) ? `<span class="tag kraken">kraken</span>` : "") +
          (t.approved && t.lane === "review" ? `<span class="tag glass">approved</span>` : "") +
          (t.course ? `<span class="tag">course ${t.course}</span>` : "") +
          (w ? `<span class="tag">${esc(w.name)}</span>` : "") +
          `</div>` +
          (lane === "ready" ? `<button class="cardbtn" data-card="dispatch" data-id="${t.id}">Dispatch</button> <button class="cardbtn" data-card="course" data-id="${t.id}">Set course</button>` : "") +
          (lane === "issues" ? `<button class="cardbtn" data-card="survey" data-id="${t.id}">Survey</button>` : "") +
          (lane === "working" || lane === "review" ? `<button class="cardbtn" data-card="park" data-id="${t.id}">Park</button> <button class="cardbtn" data-card="drop" data-id="${t.id}">Drop</button>` : "") +
          (held.has(t.id) && !s.kraken.battle ? ` <button class="cardbtn" data-card="face" data-id="${t.id}">Face the kraken</button>` : "");
        if (el._html !== html) {
          el.innerHTML = html;
          el._html = html;
        }
        el.className = "card" + (fresh ? " fadein" : "") + (lane === "review" ? " st-review" : "") + (red ? " st-red" : "") + (held.has(t.id) ? " st-held" : "") + (lane === "merged" ? " st-merged" : "");
        if (el.parentElement !== box) box.appendChild(el);
      }
    }
    // cards that left the lanes (parked, dropped, surveyed) fade out
    for (const [id, el] of this.cards)
      if (!seen.has(id)) {
        el.style.transition = "opacity .4s";
        el.style.opacity = "0";
        setTimeout(() => el.remove(), 420);
        this.cards.delete(id);
      }
    // FLIP: slide each moved card from where it was
    for (const [id, el] of this.cards) {
      const a = first.get(id);
      if (!a) continue;
      const b = el.getBoundingClientRect();
      const dx = a.left - b.left,
        dy = a.top - b.top;
      if (Math.abs(dx) + Math.abs(dy) < 2) continue;
      el.animate([{ transform: `translate(${dx}px, ${dy}px)` }, { transform: "none" }], { duration: 520, easing: "cubic-bezier(.2,.8,.3,1)" });
    }
  }
  renderRoster(s) {
    const rows = s.crew
      .map((c) => {
        const t = c.task && s.tasks.find((x) => x.id === c.task);
        const nr = nextRank(c);
        const standing = c.role === "worker" ? `${c.merges} merged, ${c.firstPass} on the first review (standing ${c.standing})` : c.role === "reviewer" ? `${c.approvals} approvals` : "";
        const hem = { working: "#2a2016", standby: "#3aa590", blocked: "#c8402c", waiting: "#c9a44a", down: "#c8402c" }[c.state] || "#b8b0a0";
        const open = this.records.has(c.id);
        return (
          `<div class="row"><span class="pen" style="box-shadow: inset 0 -4px 0 ${hem}"></span><div class="who"><b>${esc(c.name)}</b> · ${esc(rankName(c))}` +
          `<div>${c.vendor && c.role !== "firstmate" ? esc(c.vendor) + " · " : ""}${t ? esc(t.id) + " " : ""}${esc(c.state)}</div></div>` +
          (c.role === "worker" || c.role === "reviewer" ? `<button data-rec="${c.id}" aria-expanded="${open}">Record</button>` : "") +
          `</div>` +
          (open
            ? `<div class="record"><div>${esc(standing)}</div>${nr ? `<div>Next: ${esc(nr.name)} at ${nr.at}</div>` : `<div>Top rank</div>`}${c.honours.length ? `<div>Honours: ${c.honours.map(esc).join("; ")}</div>` : ""}${c.record
                .slice(0, 6)
                .map((r) => `<div>· ${esc(r.text)}</div>`)
                .join("")}</div>`
            : "")
        );
      })
      .join("");
    $("rows").innerHTML = rows;
    $("rows").onclick = (e) => {
      const b = e.target.closest("[data-rec]");
      if (!b) return;
      const id = b.dataset.rec;
      this.records.has(id) ? this.records.delete(id) : this.records.add(id);
      this.renderRoster(s);
    };
  }
  flashRoster(id) {
    void id;
  }
  // ---------------------------------------------------------------- the voyage chart
  // ahead is to the left (the ship points her bow left); home at the right edge;
  // the fog of uncharted issues at the far left
  renderChart(s) {
    const svg = $("chartsvg");
    const W = svg.clientWidth || innerWidth;
    const H = svg.clientHeight || 90;
    const ports = CONFIG.ports.slice(0, s.milestones.length + 1);
    const fogW = Math.min(140, W * 0.16);
    const x0 = W - 40,
      x1 = fogW + 30;
    const px = (i) => x0 - ((x0 - x1) * i) / (ports.length - 1);
    const y = H * 0.5;
    const merged = (m) => m.tasks.filter((id) => s.tasks.find((t) => t.id === id)?.lane === "merged").length;
    const cur = Math.min(s.port, s.milestones.length - 1);
    const m = s.milestones[cur];
    const frac = s.port >= s.milestones.length ? 0 : m.tasks.length ? merged(m) / m.tasks.length : 0;
    const shipX = s.port >= s.milestones.length ? px(ports.length - 1) : px(s.port) + (px(s.port + 1) - px(s.port)) * frac;
    let out = `<defs><pattern id="fogp" width="8" height="8" patternUnits="userSpaceOnUse"><rect width="8" height="8" fill="#cfc6b6"/><circle cx="4" cy="4" r="2" fill="#bdb3a2"/></pattern></defs>`;
    out += `<rect x="0" y="0" width="${fogW}" height="${H}" fill="url(#fogp)" opacity=".9"/>`;
    out += `<text x="10" y="${H - 10}" font-size="13" fill="#4a4450">uncharted issues</text>`;
    out += `<path d="M ${x0} ${y} L ${x1} ${y}" stroke="#8a7a5a" stroke-width="2" stroke-dasharray="6 6"/>`;
    out += `<path d="M ${x0} ${y} L ${shipX} ${y}" stroke="#2a2016" stroke-width="3"/>`;
    ports.forEach((p, i) => {
      const reached = i <= s.port;
      const name = i === 0 ? CONFIG.home : p.name;
      out += `<g class="port"><circle cx="${px(i)}" cy="${y}" r="7" fill="${reached ? "#c9a44a" : "#f4ead2"}" stroke="#2a2016" stroke-width="2"/><text x="${px(i)}" y="${y - 14}" text-anchor="middle">${esc(name)}</text><title>${esc(i ? s.milestones[i - 1]?.id : "home")}: ${esc(name)}${i ? ` (${merged(s.milestones[i - 1])} of ${s.milestones[i - 1].tasks.length} merged)` : ""}</title></g>`;
    });
    // ready tasks are islands on their leg; backlog islands behind a reef
    const legOf = (t) => s.milestones.findIndex((mm) => mm.id === t.milestone);
    let k = 0;
    const course = s.tasks.filter((t) => t.course).sort((a, b) => a.course - b.course);
    for (const t of s.tasks.filter((t) => t.lane === "ready" || t.lane === "backlog")) {
      const leg = Math.max(0, legOf(t));
      const ix = px(leg) + (px(leg + 1) - px(leg)) * (0.25 + ((k++ * 0.23) % 0.6));
      const iy = y + (k % 2 ? 20 : -2) + 8;
      const ready = t.lane === "ready";
      out += `<g class="isl" data-island="${t.id}" opacity="${ready ? 1 : 0.6}"><ellipse cx="${ix}" cy="${iy}" rx="12" ry="6" fill="${ready ? "#6aa84a" : "#9a9280"}" stroke="#2a2016"/>${ready ? "" : `<path d="M ${ix + 14} ${iy - 6} l 4 6 l -4 6" stroke="#c8402c" fill="none" stroke-width="2"/>`}<text x="${ix}" y="${iy + 20}" text-anchor="middle" font-size="12">${t.id}${t.course ? " ⚑" + t.course : ""}</text><title>${esc(t.id)} ${esc(t.title)} (${t.lane}; click to set course)</title></g>`;
    }
    if (course.length) out += `<path d="M ${shipX} ${y} ${course.map(() => "").join("")}" stroke="#c9a44a" stroke-dasharray="3 4" />`;
    for (const t of s.tasks.filter((t) => t.lane === "issues")) out += `<g class="isl"><ellipse cx="${30 + (t.issue % 3) * 30}" cy="${y + ((t.issue % 2) * 16 - 8)}" rx="11" ry="5" fill="#b8b0a0" stroke="#6a6258" stroke-dasharray="2 2"/><text x="${30 + (t.issue % 3) * 30}" y="${y + ((t.issue % 2) * 16 - 8) - 9}" text-anchor="middle" font-size="12">${esc(t.id)}</text></g>`;
    out += `<g class="shipmark" style="transform: translate(${shipX}px, ${y}px)"><path d="M -12 2 L 10 2 L 6 8 L -9 8 Z" fill="#2a2016"/><path d="M -2 2 L -2 -16 L 8 -4 Z" fill="#f4ead2" stroke="#2a2016"/><path d="M -3 -12 L -12 -3 L -3 -3 Z" fill="#1f2f86"/></g>`;
    // keep the ship element (so its glide transitions) and redraw the rest
    const prevX = this.chartShip;
    svg.innerHTML = out;
    const sm = svg.querySelector(".shipmark");
    if (prevX !== null && Math.abs(prevX - shipX) > 1) {
      sm.style.transition = "none";
      sm.style.transform = `translate(${prevX}px, ${y}px)`;
      sm.getBoundingClientRect();
      sm.style.transition = "";
      sm.style.transform = `translate(${shipX}px, ${y}px)`;
    }
    this.chartShip = shipX;
  }
  // ---------------------------------------------------------------- decision cards
  renderDecision(s) {
    const d = s.decisions[0];
    const deck = $("deck");
    if (!d) {
      if (this.decisionShown) {
        deck.innerHTML = "";
        this.decisionShown = null;
      }
      return;
    }
    if (this.decisionShown === d.id && !this.minimised) return;
    if (this.minimised && this.decisionShown === d.id) {
      deck.innerHTML = `<div class="sheet" style="padding:6px 10px;display:flex;gap:8px;align-items:center"><b>${esc(d.id)}</b> ${esc(d.title)} <button data-later="1" style="margin-left:auto">Open</button></div>`;
      return;
    }
    this.decisionShown = d.id;
    this.pick = null;
    const k = KIND[d.kind] || KIND.choice;
    // urgency: how much other work waits on the card's task
    const blocks = s.tasks.filter((t) => t.deps.includes(d.task)).length;
    const pips = blocks >= 3 ? 3 : blocks >= 1 ? 2 : 1;
    deck.innerHTML =
      `<div class="dcard" style="--frame:${k.frame};position:relative" role="dialog" aria-label="${esc(d.title)}">` +
      `<div class="band"><span class="emb">${k.emb}</span>${k.name} · ${esc(d.id)}<span class="pips" title="blocks ${blocks} other task(s)">${"●".repeat(pips)}${"○".repeat(3 - pips)}</span></div>` +
      `<h4>${esc(d.title)}</h4><p>${esc(d.body)}</p>` +
      `<div class="hand">${d.options.map((o) => `<button data-key="${o.key}" aria-pressed="false"><b>${o.key} · ${esc(o.label)}</b><small>+ ${esc(o.pro)}</small><small>− ${esc(o.con)}</small></button>`).join("")}</div>` +
      `<div class="foot"><button data-later="1">Later</button><button class="brass" data-confirm="1" disabled>Confirm</button></div></div>`;
  }
  choose(key) {
    const d = this.decisionShown;
    if (!d) return;
    this.pick = key;
    for (const b of document.querySelectorAll("#deck .hand button")) b.setAttribute("aria-pressed", b.dataset.key === key);
    const c = document.querySelector("#deck [data-confirm]");
    if (c) c.disabled = false;
  }
  confirm() {
    if (!this.decisionShown || !this.pick) return;
    const card = document.querySelector("#deck .dcard");
    if (card) {
      const seal = document.createElement("div");
      seal.className = "seal";
      card.appendChild(seal);
    }
    const id = this.decisionShown,
      key = this.pick;
    setTimeout(() => this.h.answer(id, key), 320);
  }
  minimise() {
    this.minimised = !this.minimised;
    const id = this.decisionShown;
    this.decisionShown = null;
    if (!this.minimised) this.decisionShown = null;
    this.h.rerender();
    void id;
  }
  // ---------------------------------------------------------------- battle HUD
  battleBand(info) {
    const b = $("bband");
    if (!info) {
      b.hidden = true;
      return;
    }
    b.hidden = false;
    const html = `<span>The kraken holds <b>${info.tasks.join(", ")}</b> · round ${info.round} · only an approval wins</span>` + (info.playing ? `<button id="bb-stop">Stop playing <span class="key">Esc</span></button>` : `<button id="bb-play">Play along</button>`);
    if (b._h !== html) {
      b.innerHTML = html;
      b._h = html;
      $("bb-play")?.addEventListener("click", () => this.h.play(true));
      $("bb-stop")?.addEventListener("click", () => this.h.play(false));
    }
  }
  skills(show, cds, now) {
    const el = $("skills");
    el.hidden = !show;
    if (!show) return;
    if (!el._built) {
      const G = { broadside: "✹", chain: "⛓", harpoon: "➶", sail: "⛵", order: "⚔", repair: "⚒" };
      el.innerHTML = Object.entries(SKILLS)
        .map(([id, s]) => `<button data-skill="${id}" aria-label="${s.name}, key ${s.key}, cooldown ${s.cd} seconds"><span class="g">${G[id]}</span><span class="n">${s.name}</span><span class="key">${s.key}</span><span class="cd" hidden></span></button>`)
        .join("");
      el._built = true;
      el.addEventListener("pointerdown", (e) => {
        const b = e.target.closest("[data-skill]");
        if (!b) return;
        e.preventDefault();
        b.setPointerCapture?.(e.pointerId);
        this.h.skillDown(b.dataset.skill);
      });
      const up = (e) => {
        const b = e.target.closest("[data-skill]");
        if (b) this.h.skillUp(b.dataset.skill, e.type === "pointercancel");
      };
      el.addEventListener("pointerup", up);
      el.addEventListener("pointercancel", up);
    }
    for (const b of el.querySelectorAll("[data-skill]")) {
      const left = Math.max(0, (cds[b.dataset.skill] || 0) - now);
      const cd = b.querySelector(".cd");
      cd.hidden = left <= 0;
      if (left > 0) {
        cd.textContent = left.toFixed(0) + "s";
        cd.style.transform = `scaleY(${Math.min(1, left / SKILLS[b.dataset.skill].cd)})`;
      }
    }
  }
  windup(a) {
    const el = $("windup");
    el.hidden = !a;
    if (!a) return;
    const labels = { slam: "Slam", jab: "Jab", combo: "Two-hit combo", feint: "Slam?" };
    el.querySelector(".lbl").textContent = `${labels[a.pattern]}${a.pattern === "combo" ? ` ${a.part}/2` : ""} at deck section ${a.section + 1}`;
    const fill = el.querySelector(".fill");
    fill.style.width = (a.p * 100).toFixed(1) + "%";
    fill.className = "fill" + (a.pattern === "feint" ? " dashed" : "") + (a.dodge === "early" || a.dodge === "early_hold" ? " dashed" : "");
    el.querySelector(".zone").style.width = (a.zone * 100).toFixed(0) + "%";
    el.classList.toggle("inzone", a.p >= 1 - a.zone);
    el.querySelector(".hint").textContent = a.hold ? "A feint: hold, and wait for the real strike" : a.dodge === "perfect" ? "Perfect! Counter on the weak point" : a.dodge === "dodge" ? "Dodged. Counter now: tap the head or Enter" : a.dodge?.startsWith("early") ? "Too early: the sail reloads" : "Full sail in the brass: Space, 4, or tap this bar";
  }
  head(pos, counter, weak) {
    const el = $("headhit");
    el.hidden = !pos;
    if (!pos) return;
    el.style.left = pos.x + "px";
    el.style.top = pos.y + "px";
    const r = Math.max(70, Math.min(220, pos.r));
    el.style.width = el.style.height = r + "px";
    el.style.margin = `${-r / 2}px 0 0 ${-r / 2}px`;
    el.classList.toggle("counter", !!counter);
    el.classList.toggle("weak", !!weak);
  }
  tags(list) {
    const box = $("tags");
    if (!list) {
      box.innerHTML = "";
      box._n = 0;
      return;
    }
    if (box._n !== list.length) {
      box.innerHTML = list.map((t, i) => `<button class="armtag" data-arm="${i}">${esc(t.id)}</button>`).join("");
      box._n = list.length;
      box.onclick = (e) => {
        const b = e.target.closest("[data-arm]");
        if (b) this.h.armTap(+b.dataset.arm);
      };
    }
    list.forEach((t, i) => {
      const el = box.children[i];
      if (!el) return;
      el.style.left = t.x + "px";
      el.style.top = t.y + "px";
      el.hidden = !t.visible;
      el.classList.toggle("bound", !!t.bound);
      el.classList.toggle("sel", !!t.sel);
      el.textContent = `${t.id} · r${t.round}`;
    });
  }
  ring(id, pos, radius, color, width = 3) {
    let el = document.getElementById(id);
    if (!pos) {
      el?.remove();
      return;
    }
    if (!el) {
      el = document.createElement("div");
      el.id = id;
      el.className = "ringfx";
      document.body.appendChild(el);
    }
    el.style.left = pos.x + "px";
    el.style.top = pos.y + "px";
    el.style.width = el.style.height = radius * 2 + "px";
    el.style.border = `${width}px ${id === "ring-brass" ? "dashed" : "solid"} ${color}`;
  }
  combo(text) {
    const el = $("combo");
    el.textContent = text || "";
    el.classList.toggle("show", !!text);
    clearTimeout(this._comboT);
    if (text) this._comboT = setTimeout(() => el.classList.remove("show"), 1200);
  }
  vignette(v) {
    $("vignette").style.opacity = v;
  }
  flash(v) {
    $("flash").style.opacity = v;
  }
  loading(text) {
    $("loading").hidden = !text;
    if (text) $("loading").textContent = text;
  }
  error(text) {
    $("err").hidden = false;
    $("err").textContent = text;
  }
}
