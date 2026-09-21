// The ship, the crew and the ahoy. Driven entirely by /api/state: the board
// never invents a crewman, so what you see aboard is what the event log says.
//
// One source for every shared number. The geometry below is written onto the
// scene as CSS custom properties, and ship.css reads them; nothing here is
// also declared there. The same GUNS list draws the ports, the muzzle flashes
// and the number of shots in the broadside, so they cannot drift apart.

const SHIP = (() => {
  const DECK_Y0 = 82;      // scene-bottom to the lowest deck
  const FIG_H = 88;        // a crewman's head clears this much of his deck
  const BUBBLE_CLEAR = 74; // his bubble sits above that
  const SAIL_H = 98, MAST_TOP = 26, HULL_BOTTOM = 12, BULWARK = 26, GUN_DROP = 20, FLAG_H = 18;
  const CAPTAIN_SCALE = 1.05;   // he stands nearer than the crew; one source

  // six rates. More crew means more decks and a broader hull, never a longer
  // one: a crowd stacks upward.
  const RATES = [
    { max: 2,  rows: 1, w: 34, step: 92, sc: 0.92, guns: 3, key: "rate1" },
    { max: 5,  rows: 2, w: 44, step: 92, sc: 0.86, guns: 4, key: "rate2" },
    { max: 9,  rows: 3, w: 55, step: 86, sc: 0.80, guns: 6, key: "rate3" },
    { max: 14, rows: 3, w: 66, step: 86, sc: 0.76, guns: 7, key: "rate4" },
    { max: 19, rows: 4, w: 76, step: 78, sc: 0.70, guns: 9, key: "rate5" },
    { max: 24, rows: 4, w: 86, step: 78, sc: 0.66, guns: 11, key: "rate6" },
  ];
  const rateFor = (n) => RATES.find((r) => n <= r.max) || RATES[RATES.length - 1];

  // twelve actions, each holding something
  const ACTIONS = ["hammer", "saw", "swab", "paint", "haul", "coil", "lookout",
                   "chart", "helm", "lantern", "sound", "lean"];
  const BY_STATE = {
    working: ["hammer", "saw", "paint", "haul", "coil", "sound"],
    gate:    ["swab", "lean", "lantern"],
    review:  ["lookout", "chart", "lantern"],
    queued:  ["lean", "coil"],
    captain: ["helm", "chart"],
  };
  const hash = (s) => { let h = 7; for (const c of String(s)) h = (h * 31 + c.charCodeAt(0)) >>> 0; return h; };
  const actionFor = (id, state) => {
    const pool = BY_STATE[state] || ACTIONS;
    return pool[hash(id) % pool.length];
  };

  // rows fill from the top deck down, because the top deck is the widest
  const layout = (n, rows) => {
    const per = Array(rows).fill(0);
    for (let i = 0; i < n; i++) per[rows - 1 - (i % rows)]++;
    return per;
  };
  const taper = (r, rows) => (rows === 1 ? 1 : 0.62 + 0.38 * (r / (rows - 1)));

  const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

  // one lens curve. The decks are that same curve clipped, so the planks the
  // crew stand on and the hull they stand in share a projection.
  function hullSVG(w, h, rows, step) {
    const deckY = (r) => h - (DECK_Y0 + r * step - HULL_BOTTOM);
    const path = `M0 0 H${w} C${w - 14} ${h * 0.5},${w - 46} ${h * 0.88},${w * 0.9} ${h}` +
                 ` L${w * 0.2} ${h} C${w * 0.05} ${h * 0.84},0 ${h * 0.46},0 0 Z`;
    let decks = "";
    for (let r = 0; r < rows; r++) {
      const y = deckY(r);
      decks += `<rect x="0" y="${y - 5}" width="${w}" height="5" fill="#160f09"/>` +
               `<rect x="0" y="${y - 7}" width="${w}" height="2" fill="#6b4f2c" opacity=".55"/>`;
    }
    return `<svg class="hullsvg" viewBox="0 0 ${w} ${h}" width="100%" height="${h}" ` +
      `preserveAspectRatio="none" aria-hidden="true">` +
      `<defs><clipPath id="hullclip"><path d="${path}"/></clipPath>` +
      `<linearGradient id="hullg" x1="0" y1="0" x2="0" y2="1">` +
      `<stop offset="0" stop-color="#4a2f1b"/><stop offset=".55" stop-color="#2f1e12"/>` +
      `<stop offset="1" stop-color="#140c07"/></linearGradient></defs>` +
      `<g clip-path="url(#hullclip)"><rect width="${w}" height="${h}" fill="url(#hullg)"/>` +
      decks +
      `<rect x="0" y="${deckY(rows - 1) - BULWARK}" width="${w}" height="4" fill="#d9a441" opacity=".85"/>` +
      `<rect x="0" y="${h - 22}" width="${w}" height="22" fill="#0b0705" opacity=".8"/></g>` +
      `<path d="${path}" fill="none" stroke="#0a0705" stroke-width="3"/></svg>`;
  }

  function prow(h) {
    // bow to the left, so the figurehead is mirrored by CSS onto that end
    return `<div class="prow" style="left:0;bottom:${Math.round(h * 0.52)}px">` +
      `<svg width="150" height="95" viewBox="0 0 120 76" aria-hidden="true">` +
      `<path d="M4 70 C30 60,46 40,52 6 C70 16,86 34,92 58 C70 70,36 76,4 70 Z" fill="#3b2617" stroke="#0a0705" stroke-width="2.5"/>` +
      `<path d="M18 62 C38 54,50 38,54 18" fill="none" stroke="#d9a441" stroke-width="3"/>` +
      `<circle cx="62" cy="42" r="7" fill="#d9a441"/></svg><i class="spar"></i></div>`;
  }

  function figure(c, scale) {
    const parts = ["shoeL", "shoeR", "legL", "legR", "torso",
                   c.role === "cap" ? "coat" : "", "neck", "head", "brim", "crown"]
      .filter(Boolean)
      .map((k) => `<div class="bx ${k}"><i class="bk"></i><i class="lf"></i><i class="sd"></i>` +
                  `<i class="tp"></i><i class="fr"></i></div>`).join("");
    const arm = (s) => `<div class="bx arm${s}"><i class="bk"></i><i class="lf"></i><i class="sd"></i>` +
      `<i class="tp"></i><i class="fr"></i><div class="bx hand${s}"><i class="bk"></i><i class="lf"></i>` +
      `<i class="sd"></i><i class="tp"></i><i class="fr"></i></div>${s === "R" ? '<i class="tool"></i>' : ""}</div>`;
    return `<div class="pivot" data-crew="${esc(c.id)}" style="--px:${c.x}%;--r:${c.row};--sc:${scale}">` +
      `<div class="fig r-${c.role} s-${c.state} a-${c.action}" ` +
      `style="--step:${(1.05 + (hash(c.id) % 7) / 10).toFixed(2)}s;--hopDelay:${hash(c.id) % 9}s">` +
      `<div class="sh"></div>${parts}${arm("L")}${arm("R")}<i class="eye"></i></div></div>`;
  }

  function bubble(c, T, topRow) {
    if (c.row !== topRow) {
      // the chip carries the TASK. The criterion has no crowding
      // qualifier, and a chip with only the agent's name meant no bubble
      // anywhere on a crowded ship said what anyone was working on. The
      // agent's own name is in the roster beside it.
      return `<div class="bub mini st-${c.state}" style="--px:${c.x}%;--r:${c.row}">` +
        `<div class="who">${esc(c.task || c.name)}</div></div>`;
    }
    return `<div class="bub st-${c.state}" style="--px:${c.x}%;--r:${c.row}">` +
      `<div class="who">${esc(c.name)}</div>` +
      `<div class="job">${esc(c.job)}</div>` +
      (c.pct == null ? "" : `<div class="pb"><i style="width:${c.pct}%"></i></div>`) + `</div>`;
  }

  // The crew are AGENTS. The server derives them from the actors in the
  // event log - who is running, and what each one is on - because a
  // crewman standing on the deck is something doing work, not a task
  // waiting for someone. Drawing one per in-flight task put pull requests
  // on the deck: three tasks handled by one worker looked like three of
  // the crew, and the ship grew with the backlog instead of the crew.
  // the server sends one of these three; an unknown one is a mismatch
  // between the two halves and should be visible, not painted as a worker
  const ROLE = { firstmate: "fm", worker: "w", reviewer: "r" };   // no captain: see captain()
  function crewOf(s, T) {
    // only firstmate is named by its role; a worker or a reviewer is
    // named by its own id, and the captain is not in this list at all
    const label = { firstmate: T("roleFirstmate") };
    // the limit comes from the server with the list. No fallback: a
    // number here as well is the same number in two languages, and the
    // test for it would pass through the copy.
    return (s.crew || []).slice(0, s.deckLimit).map((a) => ({
      id: a.id,
      role: ROLE[a.role] || "unknown",
      state: a.state || "working",
      // the agent's own name, and what it is on underneath
      name: a.role === "firstmate" ? label.firstmate : a.id,
      // only firstmate can be aboard without a task: the server skips a
      // taskless worker or reviewer, so there is no third case to write
      job: a.task
        ? `${a.task}${a.title ? " \u00b7 " + a.title : ""}`
        : T(s.greenlit ? "fmDispatching" : "fmWaiting"),
      task: a.task || null,
      pct: a.task ? ({ working: 45, gate: 70, review: 85, captain: 95 }[a.state] ?? null) : null,
    }));
  }

  function render(host, s, T) {
    const crew = crewOf(s, T);
    // from the server with the list: the shipbar used to print a
    // hardcoded 24 under a comment claiming the number had one source
    const limit = s.deckLimit;
    const rate = rateFor(crew.length);
    const rows = rate.rows, step = rate.step;
    const topDeck = DECK_Y0 + (rows - 1) * step;
    const sceneH = Math.round(topDeck + FIG_H + BUBBLE_CLEAR + SAIL_H + MAST_TOP + FLAG_H);
    const hullH = Math.round(topDeck + BULWARK - HULL_BOTTOM);
    const hullW = 1000;

    const per = layout(crew.length, rows);
    let k = 0;
    for (let r = rows - 1; r >= 0; r--) {
      const n = per[r], span = rate.w * taper(r, rows) * 0.9;
      for (let i = 0; i < n; i++, k++) {
        crew[k].row = r;
        crew[k].x = +(50 - span / 2 + (span * (i + 0.5)) / n).toFixed(2);
        crew[k].action = actionFor(crew[k].id, crew[k].state);
      }
    }

    // one gun list: ports, flashes and the count of shots all read it
    const guns = [];
    for (let i = 0; i < rate.guns; i++) {
      guns.push({ x: +(14 + (70 * (i + 0.5)) / rate.guns).toFixed(2),
                  y: DECK_Y0 - HULL_BOTTOM - GUN_DROP });
    }
    host._guns = guns;

    const masts = rows <= 1 ? [50] : rows === 2 ? [34, 62] : [26, 50, 76];
    const mastH = FIG_H + BUBBLE_CLEAR + SAIL_H + MAST_TOP;

    host.style.setProperty("--sceneH", sceneH + "px");
    host.style.setProperty("--deckY0", DECK_Y0 + "px");
    host.style.setProperty("--rowStep", step + "px");
    host.style.setProperty("--deckW", rate.w + "%");
    host.style.setProperty("--hullBottom", HULL_BOTTOM + "px");
    host.style.setProperty("--figH", Math.round(FIG_H * rate.sc) + "px");
    host.style.setProperty("--bubW", Math.max(9, Math.min(15, 96 / crew.length)) + "%");
    host.dataset.rate = rate.key;
    host.dataset.crew = String(crew.length);

    host.innerHTML =
      `<div class="horizon"></div><div class="sea" style="height:${HULL_BOTTOM + 14}px"></div>` +
      `<div class="shipbar"><span class="tier">${esc(T(rate.key))}</span>` +
      `<span>${esc(T("aboard"))} ${crew.length}/${limit}</span>` +
      `<button id="ahoyBtn">${esc(T("ahoyBtn"))}</button>` +
      `<button class="mute" id="muteBtn" aria-pressed="${SHIP.muted}">${esc(T(SHIP.muted ? "unmute" : "mute"))}</button></div>` +
      `<div class="vessel" id="vessel">` +
        `<div class="ship">` +
          masts.map((mx, i) => {
            const h = Math.round(mastH * (i === 1 || masts.length === 1 ? 1 : 0.86));
            const yw = i === 1 || masts.length === 1 ? 118 : 92;
            return `<div class="mast" style="--mx:${mx}%;--topR:${rows - 1};height:${h}px">` +
              `<i class="yard" style="top:${Math.round(h * 0.1)}px;--yw:${yw}px"></i>` +
              `<i class="sail${i === 1 || masts.length === 1 ? " main" : ""}" ` +
              `style="top:${Math.round(h * 0.1) + 5}px;height:${SAIL_H}px;--sw:${yw - 12}px"></i>` +
              (i === masts.length - 1
                ? `<div class="jolly"><svg viewBox="0 0 24 24" fill="#e8e8ee" aria-hidden="true">` +
                  `<circle cx="12" cy="9" r="6"/><rect x="7" y="16" width="10" height="3" rx="1.5"/>` +
                  `<circle cx="9.5" cy="8.5" r="1.8" fill="#0b0b0d"/><circle cx="14.5" cy="8.5" r="1.8" fill="#0b0b0d"/></svg></div>`
                : "") + `</div>`;
          }).join("") +
          `<div class="hullwrap">${hullSVG(hullW, hullH, rows, step)}${prow(hullH)}` +
            `<div class="ports">` + guns.map((g) =>
              `<div class="port" style="left:${g.x}%;bottom:${g.y - HULL_BOTTOM}px"><b></b></div>`).join("") +
            `</div><div class="salvo" id="salvo">` + guns.map((g) =>
              `<i style="left:${g.x}%;bottom:${g.y - HULL_BOTTOM}px"></i>`).join("") + `</div>` +
          `</div>` +
          `<div class="helm" style="--hx:${50 + rate.w / 2 - 4}%;--topR:${rows - 1}">` +
            `<div class="ring"></div><i></i><i></i><i></i><i></i></div>` +
          crew.map((c) => figure(c, rate.sc)).join("") +
        `</div>` +
      `</div>` +
      crew.map((c) => bubble(c, T, rows - 1)).join("") +
      `<div class="ahoy" id="ahoy">AHOY!<small>${esc(T("ahoySub"))}</small></div>`;

    host.querySelector("#ahoyBtn").onclick = () => SHIP.ahoy(host);
    host.querySelector("#muteBtn").onclick = (e) => {
      SHIP.muted = !SHIP.muted;
      try { localStorage.setItem("board.muted", SHIP.muted ? "1" : ""); } catch (_) {}
      e.target.textContent = T(SHIP.muted ? "unmute" : "mute");
      e.target.setAttribute("aria-pressed", String(SHIP.muted));
    };
    drag(host);
    return crew;
  }

  // The captain's own figure, beside the cards rather than on the deck.
  // He is not crew: the crew are agents doing work and he is the person
  // they are waiting on, so he stands in the place where the waiting is.
  function captain(host, n, T) {
    if (!host) return;
    if (!n) { host.innerHTML = ""; host.hidden = true; return; }
    host.hidden = false;
    // he stands on no deck, so the deck offsets are zero - written from
    // here, because the geometry has one source and it is this file
    host.style.setProperty("--deckY0", "0px");
    host.style.setProperty("--rowStep", "0px");
    // every number the captain's block uses, from the deck's constants
    host.style.setProperty("--figH", Math.round(FIG_H * CAPTAIN_SCALE) + "px");
    host.style.setProperty("--capStand", Math.round(FIG_H * CAPTAIN_SCALE * 1.5) + "px");
    host.style.setProperty("--capBox", Math.round(FIG_H * CAPTAIN_SCALE * 2.05) + "px");
    host.style.setProperty("--capFoot", Math.round(FIG_H * CAPTAIN_SCALE * 1.04) + "px");
    const c = { id: "captain", role: "cap", state: "captain", action: "helm", x: 50, row: 0 };
    // the scale is an argument, not also a custom property: figure() puts
    // it on the pivot, which is the only place it is read
    host.innerHTML =
      `<div class="capstand">${figure(c, CAPTAIN_SCALE)}</div>` +
      `<div class="capsays"><b>${esc(T("roleCaptain"))}</b>` +
      `<span>${esc(T("capDeciding"))}</span>` +
      `<i>${n}</i></div>`;
    drag(host);
  }

  function roster(host, crew, T) {
    host.innerHTML = `<h3><span>${esc(T("roster"))}</span><span>${crew.length}</span></h3><ul>` +
      crew.map((c) => `<li class="st-${c.state}"><span class="av"></span>` +
        `<span class="nm">${esc(c.name)}</span>` +
        `<span class="st">${esc(T("lane" + c.state[0].toUpperCase() + c.state.slice(1)))}</span>` +
        `<span class="jb" title="${esc(c.job)}">${esc(c.job)}</span></li>`).join("") + `</ul>`;
  }

  // Drag to turn a crewman; the pointer owns him until it lets go.
  //
  // The listeners go on the .pivot elements, never on the host, and every
  // caller has just replaced host.innerHTML - so the elements these are
  // attached to are new and the previous ones were discarded with their
  // listeners. Nothing accumulates across renders. Put one on `host` and
  // that stops being true.
  function drag(host) {
    host.querySelectorAll(".pivot").forEach((p) => {
      let x0 = 0, y0 = 0, ry = -26, rx = 8, on = false;
      p.addEventListener("pointerdown", (e) => {
        on = true; x0 = e.clientX; y0 = e.clientY;
        ry = parseFloat(p.style.getPropertyValue("--ry")) || -26;
        rx = parseFloat(p.style.getPropertyValue("--rx")) || 8;
        p.classList.add("dragging"); p.setPointerCapture(e.pointerId); e.preventDefault();
      });
      p.addEventListener("pointermove", (e) => {
        if (!on) return;
        p.style.setProperty("--ry", (ry + (e.clientX - x0) * 0.6) + "deg");
        p.style.setProperty("--rx", Math.max(-32, Math.min(42, rx - (e.clientY - y0) * 0.4)) + "deg");
      });
      const up = () => { on = false; p.classList.remove("dragging"); };
      p.addEventListener("pointerup", up);
      p.addEventListener("pointercancel", up);
    });
  }

  // synthesised, so the board carries no audio files
  let ac = null;
  function boom(at, gain) {
    if (SHIP.muted) return;
    try {
      ac = ac || new (window.AudioContext || window.webkitAudioContext)();
      if (ac.state === "suspended") ac.resume();
    } catch (_) { return; }
    const t0 = ac.currentTime + at, len = 0.5;
    const buf = ac.createBuffer(1, Math.floor(ac.sampleRate * len), ac.sampleRate);
    const d = buf.getChannelData(0);
    for (let i = 0; i < d.length; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / d.length, 2.6);
    const src = ac.createBufferSource(); src.buffer = buf;
    const lp = ac.createBiquadFilter(); lp.type = "lowpass";
    lp.frequency.setValueAtTime(900, t0); lp.frequency.exponentialRampToValueAtTime(110, t0 + len);
    const g = ac.createGain(); g.gain.setValueAtTime(gain, t0); g.gain.exponentialRampToValueAtTime(0.001, t0 + len);
    src.connect(lp).connect(g).connect(ac.destination); src.start(t0); src.stop(t0 + len);
  }

  function ahoy(host) {
    const vessel = host.querySelector("#vessel"), salvo = host.querySelector("#salvo"),
          banner = host.querySelector("#ahoy");
    if (!vessel) return;
    vessel.classList.remove("heel"); void vessel.offsetWidth; vessel.classList.add("heel");
    banner.classList.remove("on"); void banner.offsetWidth; banner.classList.add("on");
    host.querySelectorAll(".fig").forEach((f, i) =>
      setTimeout(() => { f.classList.add("cheer"); setTimeout(() => f.classList.remove("cheer"), 1400); }, i * 55));
    // the flash and the report are the same event: one gun, one sound, same delay
    const guns = host._guns || [];
    salvo.classList.remove("fire"); void salvo.offsetWidth;
    salvo.querySelectorAll("i").forEach((el, i) => {
      el.style.animationDelay = (i * 0.07).toFixed(2) + "s";
      boom(i * 0.07, i === 0 ? 0.5 : 0.34);
    });
    salvo.classList.add("fire");
    return guns.length;
  }

  return { render, roster, captain, ahoy, rateFor, actionFor, crewOf, layout, RATES, ACTIONS,
           muted: (() => { try { return !!localStorage.getItem("board.muted"); } catch (_) { return false; } })() };
})();
if (typeof module !== "undefined") module.exports = SHIP;
