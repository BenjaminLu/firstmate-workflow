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
  // a pull request number is a link to it, at the URL the server derived
  // from the project registry (T-069); without one it stays plain text. The
  // page never decides what a valid number is or builds a URL: a URL string
  // from the server is the whole test. The page uses these two as well.
  const prRef = (n, url, cls = "", label = "#" + esc(n)) =>
    typeof url === "string" && url.startsWith("https://github.com/")
      ? `<a${cls ? ` class="${cls}"` : ""} href="${esc(url)}" target="_blank" rel="noreferrer" draggable="false" data-pr="${esc(n)}">${label}</a>`
      : cls ? `<span class="${cls}">${label}</span>` : label;
  // every #n in already-escaped text, linked through the server's pr_urls
  // map. The server collects the numbers with the same pattern; the lead
  // excludes a word character and the '&' of an escaped entity like &#39;
  const linkPrs = (html, urls) => urls ? String(html).replace(/(^|[^\w&])#([1-9][0-9]{0,8})(?![0-9])/g,
    (m, lead, n) => Object.hasOwn(urls, n) ? lead + prRef(n, urls[n]) : m) : html;

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

  // the body alone, so the ship and the captain's portrait draw one figure
  function body(c) {
    const parts = ["shoeL", "shoeR", "legL", "legR", "torso",
                   c.role === "cap" ? "coat" : "", "neck", "head", "brim", "crown"]
      .filter(Boolean)
      .map((k) => `<div class="bx ${k}"><i class="bk"></i><i class="lf"></i><i class="sd"></i>` +
                  `<i class="tp"></i><i class="fr"></i></div>`).join("");
    const arm = (s) => `<div class="bx arm${s}"><i class="bk"></i><i class="lf"></i><i class="sd"></i>` +
      `<i class="tp"></i><i class="fr"></i><div class="bx hand${s}"><i class="bk"></i><i class="lf"></i>` +
      `<i class="sd"></i><i class="tp"></i><i class="fr"></i></div>${s === "R" ? '<i class="tool"></i>' : ""}</div>`;
    return `<div class="fig r-${c.role} s-${c.state} a-${c.action}" ` +
      `style="--step:${(1.05 + (hash(c.id) % 7) / 10).toFixed(2)}s;--hopDelay:${hash(c.id) % 9}s">` +
      `<div class="sh"></div>${parts}${arm("L")}${arm("R")}<i class="eye"></i></div>`;
  }
  function figure(c, scale) {
    return `<div class="pivot" data-crew="${esc(c.id)}" style="--px:${c.x}%;--r:${c.row};--sc:${scale}">` +
      body(c) + `</div>`;
  }

  // T-116: a project's one colour, wherever it appears on the board - the
  // pennant on a name tag, the roster's project column, a card's chip. Read
  // off the name, so it needs no registry and never changes between pages.
  const projectColor = (p) => `hsl(${hash(p) % 360} 62% 60%)`;
  // On a tag the pennant names its project to a screen reader, since a
  // colour alone says nothing to one. With several projects live it is the
  // tag's project chip (T-054) and holds the name as hidden text; a board of
  // one project has no chip anywhere, so there the name is its label.
  const pennant = (c, T) => !c.project ? ""
    : `<i class="pennant${c.showProject ? " pchip" : ""}" style="--pc:${projectColor(c.project)}" data-project="${esc(c.project)}"` +
      ` title="${esc(T("projectChip"))}: ${esc(c.project)}"` + (c.showProject
        ? `><span class="sr">${esc(c.project)}</span></i>`
        : ` role="img" aria-label="${esc(T("projectChip"))}: ${esc(c.project)}"></i>`);
  // the card writes the project out beside it, so there it is only colour
  const swatch = (c) => `<i class="pennant" style="--pc:${projectColor(c.project)}" aria-hidden="true"></i>`;
  // A quiet name tag over each head (T-116): the crew member's name and the
  // pennant of the project, and nothing else - no task, round, pull request
  // or activity, which crowded 24 tags into one another. Those are in the
  // detail card, which the same tag holds closed until the figure is
  // hovered, focused or tapped. No progress and no percentage anywhere here.
  function bubble(c, T, topRow) {
    const open = SHIP.openCard === c.id;
    return `<div class="bub${c.row !== topRow ? " mini" : ""} st-${c.state}${c.alt ? " alt" : ""}${c.far ? " far" : ""}${open ? " open" : ""}"` +
      ` data-bubble="${esc(c.id)}" style="--px:${c.x}%;--r:${c.row};--tagW:${c.tagW}%">` +
      `<div class="who">${esc(c.name)}${pennant(c, T)}</div>${detail(c, T, open)}</div>`;
  }
  // One labelled line per field, each on its own: never a joined string.
  function detail(c, T, open) {
    const unknown = esc(T("crewUnknown"));
    const line = (key, label, value) => `<dt>${esc(label)}</dt><dd class="${key}">${value}</dd>`;
    const round = c.round == null ? unknown
      : esc(c.round) + (c.attempt > 1 ? ` <span class="att">${esc(T("crewAttempt"))} ${esc(c.attempt)}</span>` : "");
    return `<div class="crewcard" id="crewcard-${esc(c.id)}" role="dialog" aria-label="${esc(T("crewCard"))}: ${esc(c.name)}"` +
      `${open ? "" : " hidden"}><dl>` +
      line("cname", T("crewName"), esc(c.name)) +
      line("crole", T("crewRole"), esc(c.roleLabel)) +
      line("cproject", T("projectChip"), c.project ? `${swatch(c)} ${esc(c.project)}` : unknown) +
      line("ctask", T("crewTask"), c.task
        ? `<b>${esc(c.task)}</b> ${linkPrs(esc(c.title || T("titleMissing")), c.pr_urls)}` : unknown) +
      line("cround", T("crewRound"), round) +
      line("cpr", T("crewPr"), c.pr ? prRef(c.pr, c.pr_url) : unknown) +
      line("cstate", T("crewState"), esc(T("lane" + c.state[0].toUpperCase() + c.state.slice(1)))) +
      // .job: the current activity, the one line the tag used to carry
      line("job", T("crewActivity"), linkPrs(esc(c.activity), c.pr_urls)) +
      `</dl></div>`;
  }

  // the server sends one of these three; an unknown one is a mismatch
  // between the two halves, and .fig.r-unknown draws it as one. Exported
  // because the sheet has to carry a rule for every value in here and
  // nothing can check that against a constant it cannot see.
  const ROLE = { firstmate: "fm", worker: "w", reviewer: "r" };   // no captain: see captain()
  // The crew are AGENTS. The server derives them from the actors in the
  // event log - who is running, and what each one is on - because a
  // crewman standing on the deck is something doing work, not a task
  // waiting for someone. Drawing one per in-flight task put pull requests
  // on the deck: three tasks handled by one worker looked like three of
  // the crew, and the ship grew with the backlog instead of the crew.
  function crewOf(s, T, L = value => value?.en || '') {
    // only firstmate is named by its role; a worker or a reviewer is
    // named by its own id, and the captain is not in this list at all
    const label = { firstmate: T("roleFirstmate") };
    // T-054: a crewman's task is its project's; two projects' T-004 are two
    // tasks, each with its own pull request and its own links
    const several = (s.projects || []).length > 1;
    const projectOf = (o) => (o && o.project) || s.default_project || null;
    const taskOf = (a) => (s.tasks || []).find((t) => t.id === a.task && projectOf(t) === projectOf(a)) || {};
    const urlsOf = (a) => (s.pr_urls_by_project ? s.pr_urls_by_project[projectOf(a) || ""] || {} : s.pr_urls || null);
    // the limit comes from the server with the list. No fallback: a
    // number here as well is the same number in two languages, and the
    // test for it would pass through the copy.
    return (s.crew || []).slice(0, s.deckLimit).map((a) => {
      const activity = a.task
        ? L(a.activity) || T("descriptionUnavailable")
        : L(a.activity) || T(s.greenlit ? "descriptionUnavailable" : "fmWaiting");
      // Only explicit bounded progress ({done,total}) becomes a bar. Coarse
      // lifecycle state never invents a percentage.
      const p = a.progress && typeof a.progress === "object" ? a.progress : null;
      const done = p ? Number(p.done) : NaN, total = p ? Number(p.total) : NaN;
      const bounded = Number.isFinite(done) && Number.isFinite(total) && total > 0 && done >= 0 && done <= total;
      return {
        id: a.id,
        role: ROLE[a.role] || "unknown",
        // the role as a reader names it, from the dictionary
        roleLabel: a.role === "worker" ? T("roleWorker") : a.role === "reviewer" ? T("roleReviewer")
          : a.role === "firstmate" ? T("roleFirstmate") : T("crewUnknown"),
        state: a.state || "unknown",
        // T-116: the crew member's own name, a field the server sends; a
        // run that recorded none is known by its crew_name, then its id
        name: a.role === "firstmate" ? label.firstmate : a.name || a.crew_name || a.id,
        // the task's review round and the retry within it; null is unknown
        round: Number.isInteger(a.round) ? a.round : null,
        attempt: Number.isInteger(a.attempt) ? a.attempt : null,
        // only firstmate can be aboard without a task: the server skips a
        // taskless worker or reviewer, so there is no third case to write
        job: a.task ? `${a.task} · ${activity}` : activity,
        activity,
        task: a.task || null,
        title: a.title || null,
        // the project of the task it is on: shown on every tag and roster
        // row, one project or several (T-116)
        project: a.task ? projectOf(a) : null,
        showProject: several,
        color: a.task && projectOf(a) ? projectColor(projectOf(a)) : null,
        pr: taskOf(a).pr ?? null,
        // the URL the server put beside the task's number (T-069), or none
        pr_url: taskOf(a).pr_url ?? null,
        // and every other #n the title or the activity names, on its project
        pr_urls: urlsOf(a),
        progress: bounded ? { done, total } : null,
        pct: bounded ? Math.round((100 * done) / total) : null,
      };
    });
  }

  // Patch matching nodes in place: a captured pointer, rotation and running
  // effect belong to the same figure across state and language updates.
  function patch(parent, markup) {
    if (!parent.ownerDocument) { parent.innerHTML = markup; return; }
    const template = document.createElement('template'); template.innerHTML = markup;
    const key = el => el.nodeType === 1 ? el.id || el.dataset.crew || el.dataset.bubble || '' : '';
    function sync(dst, src) {
      const old = [...dst.childNodes];
      const retained = new Set();
      [...src.childNodes].forEach((fresh,index) => {
        let node = key(fresh) ? old.find(el=>key(el)===key(fresh)) : old[index];
        if (!node || node.nodeName !== fresh.nodeName || (key(node) && key(node)!==key(fresh))) node = fresh.cloneNode(true);
        else if (node.nodeType === 3) node.textContent = fresh.textContent;
        else {
          const rotation = ['--rx','--ry'].map(p=>node.style.getPropertyValue(p));
          const transient = ['dragging','cheer','react','ping','heel','orders','fire','active'].filter(c=>node.classList.contains(c));
          const effectDelay = transient.length ? node.style.animationDelay : '';
          for (const a of [...node.attributes]) if (!fresh.hasAttribute(a.name) && !(node.tagName==='IFRAME' && ['src','style'].includes(a.name))) node.removeAttribute(a.name);
          for (const a of fresh.attributes) if (node.getAttribute(a.name)!==a.value && !(node.tagName==='IFRAME' && a.name==='hidden' && node.hasAttribute('src'))) node.setAttribute(a.name,a.value);
          rotation.forEach((v,i)=>{if(v)node.style.setProperty(['--rx','--ry'][i],v);});
          transient.forEach(c=>node.classList.add(c));
          if(effectDelay)node.style.animationDelay=effectDelay;
          sync(node,fresh);
        }
        if(dst.childNodes[index]!==node)dst.insertBefore(node,dst.childNodes[index] || null);
        retained.add(node);
      });
      old.filter(el=>!retained.has(el)).forEach(el=>el.remove());
    }
    sync(parent,template.content);
  }

  function render(host, s, T, L) {
    const crew = crewOf(s, T, L);
    // from the server with the list: the shipbar used to print a
    // hardcoded 24 under a comment claiming the number had one source
    const limit = s.deckLimit;
    const rate = rateFor(crew.length);
    const rows = rate.rows, step = rate.step;
    const topDeck = DECK_Y0 + (rows - 1) * step;
    // Reserve a band above the rigging for outcome feedback and audio controls.
    const sceneH = Math.round(topDeck + FIG_H + BUBBLE_CLEAR + SAIL_H + MAST_TOP + FLAG_H + 80);
    const hullH = Math.round(topDeck + BULWARK - HULL_BOTTOM);
    const hullW = 1000;

    const per = layout(crew.length, rows);
    let k = 0;
    for (let r = rows - 1; r >= 0; r--) {
      const n = per[r], span = rate.w * taper(r, rows) * 0.9;
      // T-116: a name tag shrinks to the gap to its neighbour, so 24 tags
      // cannot overlap, and a far deck of a crowded ship keeps only its
      // pennant on a narrow screen (ship.css).
      const gap = span / (n + (r === rows - 1 ? 1 : 0));
      for (let i = 0; i < n; i++, k++) {
        crew[k].row = r;
        crew[k].x = +(50 - span / 2 + (span * (i + 0.5)) / (n + (r === rows-1 ? 1 : 0))).toFixed(2);
        crew[k].action = crew[k].role === 'fm' ? 'helm' : actionFor(crew[k].id, crew[k].state);
        crew[k].tagW = +Math.min(15, gap * 0.95).toFixed(2);
        crew[k].far = crew.length > 14 && rows - 1 - r >= 2;
      }
    }
    const firstmate = crew.find(c=>c.role==='fm');
    // firstmate stands at the helm, off the deck's spacing, so its tag is
    // stacked one line above the others rather than into its neighbour's
    if (firstmate) { firstmate.x = 50 - rate.w * .3; firstmate.alt = true; }

    // one gun list: ports, flashes and the count of shots all read it
    const guns = [];
    for (let i = 0; i < rate.guns; i++) {
      guns.push({ x: +(14 + (70 * (i + 0.5)) / rate.guns).toFixed(2),
                  y: DECK_Y0 - HULL_BOTTOM - GUN_DROP });
    }
    host._guns = guns;

    // two masts, as the prototype draws them; a tall ship adds a third. Each
    // carries a topsail over a course, and the two share SAIL_H between them
    // so the whole rig still hangs above the tallest head.
    const masts = rows <= 2 ? [30, 64] : [24, 50, 76];
    const mastH = FIG_H + BUBBLE_CLEAR + SAIL_H + MAST_TOP;
    const TOPSAIL = Math.round(SAIL_H * 0.38), REEF = 8, COURSE = SAIL_H - TOPSAIL - REEF;

    host.style.setProperty("--sceneH", sceneH + "px");
    host.style.setProperty("--deckY0", DECK_Y0 + "px");
    host.style.setProperty("--rowStep", step + "px");
    host.style.setProperty("--deckW", rate.w + "%");
    host.style.setProperty("--hullBottom", HULL_BOTTOM + "px");
    host.style.setProperty("--figH", Math.round(FIG_H * rate.sc) + "px");
    host.dataset.rate = rate.key;
    host.dataset.crew = String(crew.length);

    const captainX = 50 + rate.w * .29;
    const helmX = crew.find(c=>c.role==='fm')?.x ?? 50 - rate.w * .3;
    const markup =
      `<div class="horizon"></div><div class="sea" style="height:${HULL_BOTTOM + 14}px"></div>` +
      `<div class="shipbar"><span class="tier">${esc(T(rate.key))}</span>` +
      `<span>${esc(T("aboard"))} ${crew.length}/${limit}</span>` +
      `<button class="toggle" id="rosterBtn" aria-controls="roster" aria-pressed="${SHIP.rosterOn}">${esc(T("rosterBtn"))}</button>` +
      // a demonstration, and says so: it plays the salute locally and
      // records nothing - no event, no request, no decision
      `<button class="ahoybtn" id="ahoyDemo" title="${esc(T("ahoyDemo"))}" aria-label="${esc(T("ahoyDemo"))}">&#9875; AHOY!</button>` +
      `<button class="ahoybtn q" id="orderDemo" title="${esc(T("orderDemo"))}" aria-label="${esc(T("orderDemo"))}">&#9784;</button>` +
      `<button class="mute" id="muteBtn" aria-pressed="${SHIP.muted}">${esc(T(SHIP.muted ? "unmute" : "mute"))}</button>` +
      `<span class="hint">${esc(T("dragHint"))}</span></div>` +
      `<div class="vessel" id="vessel">` +
        `<div class="ship">` +
          masts.map((mx, i) => {
            const main = i === masts.length - 1 || (masts.length === 3 && i === 1);
            const h = Math.round(mastH * (main ? 1 : 0.86));
            const yw = main ? 118 : 92;
            const top = Math.round(h * 0.1);
            return `<div class="mast" style="--mx:${mx}%;--topR:${rows - 1};height:${h}px">` +
              `<i class="shroud l"></i><i class="shroud r"></i>` +
              `<i class="yard" style="top:${top}px;--yw:${Math.round(yw * 0.72)}px"></i>` +
              `<i class="sail top" style="top:${top + 5}px;height:${TOPSAIL}px;--sw:${Math.round((yw - 12) * 0.72)}px"></i>` +
              `<i class="yard" style="top:${top + 5 + TOPSAIL + REEF - 3}px;--yw:${yw}px"></i>` +
              `<i class="sail${main ? " main" : ""}" ` +
              `style="top:${top + 5 + TOPSAIL + REEF}px;height:${COURSE}px;--sw:${yw - 12}px"></i>` +
              (i === masts.length - 1
                ? `<div class="jolly"><svg viewBox="0 0 24 24" fill="#e8e8ee" aria-hidden="true">` +
                  `<circle cx="12" cy="9" r="6"/><rect x="7" y="16" width="10" height="3" rx="1.5"/>` +
                  `<circle cx="9.5" cy="8.5" r="1.8" fill="#0b0b0d"/><circle cx="14.5" cy="8.5" r="1.8" fill="#0b0b0d"/></svg></div>`
                : "") + `</div>`;
          }).join("") +
          `<div class="hullwrap">${hullSVG(hullW, hullH, rows, step)}${prow(hullH)}<i class="stern" aria-hidden="true"></i>` +
            `<div class="ports">` + guns.map((g) =>
              `<div class="port" style="left:${g.x}%;bottom:${g.y - HULL_BOTTOM}px"><b></b></div>`).join("") +
            `</div><div class="salvo" id="salvo">` + guns.map((g) =>
              `<i style="left:${g.x}%;bottom:${g.y - HULL_BOTTOM}px"></i>`).join("") + `</div>` +
          `</div>` +
          `<div class="helm" style="--hx:${helmX}%;--topR:${rows - 1}">` +
            `<div class="ring"></div><i></i><i></i><i></i><i></i></div>` +
          crew.map((c) => figure(c, rate.sc)).join("") +
          `<div id="captain" class="captain" style="--capX:${captainX}%;--capRow:${rows-1}">${figure({id:'captain',role:'cap',state:'captain',action:'helm',x:captainX,row:rows-1},Math.min(rate.sc,CAPTAIN_SCALE))}</div>` +
        `</div>` +
      `</div>` +
      crew.map((c) => bubble(c, T, rows - 1)).join("") +
      `<div class="ahoy" id="ahoy" role="status"></div>`;
    const layer = host.querySelector('.handoffs');
    if (layer?.remove) layer.remove();
    patch(host, markup);
    if (layer?.remove) host.append(layer);
    for (const c of crew) {
      const p = [...host.querySelectorAll('[data-crew]')].find(el=>el.dataset.crew===c.id);
      if (p) {
        // the figure names its crew member and what it is doing, to a
        // screen reader only; the card, which it describes and controls,
        // carries every other field (T-116)
        p.setAttribute('aria-label',`${c.name} · ${T('lane'+c.state[0].toUpperCase()+c.state.slice(1))} · ${c.activity}`); p.tabIndex=0;
        p.setAttribute('aria-describedby',`crewcard-${c.id}`); p.setAttribute('aria-controls',`crewcard-${c.id}`);
        p.setAttribute('aria-haspopup','dialog'); p.setAttribute('aria-expanded',String(SHIP.openCard===c.id));
      }
    }

    host.querySelector("#muteBtn").onclick = (e) => {
      SHIP.muted = !SHIP.muted;
      if (SHIP.muted) silence(); else unlock();
      try { localStorage.setItem("board.muted", SHIP.muted ? "1" : ""); } catch (_) {}
      e.target.textContent = T(SHIP.muted ? "unmute" : "mute");
      e.target.setAttribute("aria-pressed", String(SHIP.muted));
    };
    host.querySelector("#rosterBtn").onclick = (e) => {
      SHIP.rosterOn = !SHIP.rosterOn;
      try { localStorage.setItem("board.roster", SHIP.rosterOn ? "" : "hidden"); } catch (_) {}
      e.target.setAttribute("aria-pressed", String(SHIP.rosterOn));
      const list = host.ownerDocument && host.ownerDocument.getElementById("roster");
      if (list) list.hidden = !SHIP.rosterOn;
    };
    // demonstration identities never collide with a real outcome's and are
    // never sent anywhere; the queue plays them like any other effect
    host.querySelector("#ahoyDemo").onclick = () => enqueue(host, "merge", `demo:merge:${++demos}`);
    host.querySelector("#orderDemo").onclick = () => enqueue(host, "order", `demo:order:${++demos}`);
    drag(host);
    cards(host);
    applyEffect(host);
    if (host.ownerDocument) handoffs(host,s.handoffs || [],T,crew);
    return crew;
  }

  // Human captain is permanently part of ship geometry, never agent counts.
  function captain(host, n, T) {
    if (!host) return;
    host.hidden = false;
    host.setAttribute('aria-label', T('roleCaptain'));
  }

  // Portrait of the one captain, beside the first decision card. It is a
  // picture of the captain on the ship, not a second one aboard: no pivot, no
  // crew id, hidden from assistive technology, and gone when nothing waits.
  function portrait(host, show, T) {
    if (!host) return;
    host.hidden = !show;
    if (!show) { if (host.firstChild) host.innerHTML = ""; return; }
    if (!host.querySelector(".fig")) {
      host.innerHTML = `<div class="floor"></div><div class="glow"></div>` +
        `<div class="capfig" aria-hidden="true">${body({ id: "portrait", role: "cap", state: "captain", action: "helm" })}</div>` +
        `<div class="lbl"><b></b><span></span></div>`;
    }
    host.querySelector(".lbl b").textContent = T("roleCaptain");
  }

  // Two-column rows, as the prototype lays them out: status dot, name, stage
  // pill and pull request over the task and the authored activity. A bar only
  // for bounded progress, and never a percentage.
  //
  // T-116: the fields are separate columns - name, role, project, task (id
  // and title), round, pull request, state - under one header, and the
  // project column is there with one project as with several. On a phone
  // each row folds into two lines of the same cells, each labelled by its
  // data-label (ship.css). The roster sorts by any column and can group its
  // rows by project; both choices survive a reload.
  const SORTS = {
    name: (c) => c.name, role: (c) => c.roleLabel, project: (c) => c.project || "",
    task: (c) => c.task || "", round: (c) => c.round ?? -1, state: (c) => c.state,
  };
  function roster(host, crew, T) {
    if (host.ownerDocument) host.hidden = !SHIP.rosterOn;
    host._roster = { crew, T };
    const unknown = esc(T("crewUnknown"));
    const key = SORTS[SHIP.rosterSort] ? SHIP.rosterSort : null;
    // firstmate heads the list whatever the order, as it heads the deck
    const cmp = (a, b) => {
      if ((a.role === "fm") !== (b.role === "fm")) return a.role === "fm" ? -1 : 1;
      const x = SORTS[key](a), y = SORTS[key](b);
      return typeof x === "number" ? x - y : String(x).localeCompare(String(y));
    };
    const order = key ? [...crew].sort(cmp) : crew;
    const cell = (cls, label, value) => `<span class="${cls}" data-label="${esc(label)}">${value}</span>`;
    const row = (c) => `<li class="rrow st-${c.state}" data-roster="${esc(c.id)}"${c.project ? ` data-project="${esc(c.project)}"` : ""}>` +
      `<div class="l1"><span class="av" aria-hidden="true"></span>` +
      `<span class="nm" data-label="${esc(T("crewName"))}">${esc(c.name)}</span>` +
      cell("rl", T("crewRole"), esc(c.roleLabel)) +
      cell("pj", T("projectChip"), c.project
        ? `<i class="pdot" style="--pc:${projectColor(c.project)}" aria-hidden="true"></i>${esc(c.project)}` : unknown) +
      cell("rd", T("crewRound"), c.round == null ? unknown
        : esc(c.round) + (c.attempt > 1 ? ` <span class="att">${esc(T("crewAttempt"))} ${esc(c.attempt)}</span>` : "")) +
      `<span class="st" data-label="${esc(T("crewState"))}">${esc(T("lane" + c.state[0].toUpperCase() + c.state.slice(1)))}</span>` +
      `<span class="rpr" data-label="${esc(T("crewPr"))}">${c.pr ? prRef(c.pr, c.pr_url) : ""}</span></div>` +
      `<div class="jb" data-label="${esc(T("crewTask"))}">` +
      (c.task ? `<b class="tk">${esc(c.task)}</b> <span class="tt">${linkPrs(esc(c.title || T("titleMissing")), c.pr_urls)}</span> ` : "") +
      `<span class="act">${linkPrs(esc(c.activity), c.pr_urls)}</span>` +
      (c.progress
        ? `<span class="pb" role="progressbar" aria-valuemin="0" aria-valuenow="${c.progress.done}" ` +
          `aria-valuemax="${c.progress.total}" title="${c.progress.done}/${c.progress.total}">` +
          `<i style="width:${c.pct}%"></i></span>`
        : "") +
      `</div></li>`;
    const head = `<div class="rhead" role="group" aria-label="${esc(T("rosterSort"))}">` +
      [["name", T("crewName")], ["role", T("crewRole")], ["project", T("projectChip")],
      ["round", T("crewRound")], ["state", T("crewState")], [null, T("crewPr")], ["task", T("crewTask")]]
      .map(([k, label]) => k
        ? `<button class="rsort" data-sort="${k}" aria-pressed="${key === k}">${esc(label)}</button>`
        : `<span class="rcol">${esc(label)}</span>`).join("") + `</div>`;
    let lists;
    if (SHIP.rosterGroup) {
      const groups = new Map();
      for (const c of order) {
        const g = c.project || "";
        if (!groups.has(g)) groups.set(g, []);
        groups.get(g).push(c);
      }
      lists = [...groups].map(([g, rows]) => `<h4 class="rgroup"${g ? ` data-project="${esc(g)}"` : ""}>` +
        (g ? `<i class="pdot" style="--pc:${projectColor(g)}" aria-hidden="true"></i>${esc(g)}` : unknown) +
        ` <span>${rows.length}</span></h4><ul class="rows">${rows.map(row).join("")}</ul>`).join("");
    } else lists = `<ul class="rows">${order.map(row).join("")}</ul>`;
    patch(host, `<h3><span>${esc(T("roster"))}</span>` +
      `<button class="rgroupbtn" data-group aria-pressed="${!!SHIP.rosterGroup}">${esc(T("rosterGroup"))}</button>` +
      `<span>${crew.length}</span></h3>` + head + lists);
    if (!host.ownerDocument || host._rosterBound) return;
    host._rosterBound = true;
    host.addEventListener("click", (e) => {
      const sort = e.target.closest("[data-sort]"), group = e.target.closest("[data-group]");
      if (!sort && !group) return;
      if (sort) SHIP.rosterSort = SHIP.rosterSort === sort.dataset.sort ? null : sort.dataset.sort;
      if (group) SHIP.rosterGroup = !SHIP.rosterGroup;
      try {
        localStorage.setItem("board.rosterSort", SHIP.rosterSort || "");
        localStorage.setItem("board.rosterGroup", SHIP.rosterGroup ? "1" : "");
      } catch (_) {}
      roster(host, host._roster.crew, host._roster.T);
    });
  }

  // The detail card (T-116): one open at a time, anchored in the figure's own
  // name tag. Hover or focus opens it and leaving closes it; a tap - a touch
  // or a pen that did not drag - toggles it; Esc closes it and hands focus
  // back to the figure. Which card is open lives here, so a re-render from
  // /api/state keeps it open.
  function showCard(host, id) {
    SHIP.openCard = id;
    for (const b of host.querySelectorAll('[data-bubble]')) {
      const on = b.dataset.bubble === id;
      b.classList.toggle('open', on);
      const card = b.querySelector('.crewcard');
      if (card) card.hidden = !on;
    }
    for (const p of host.querySelectorAll('.pivot[data-crew]'))
      if (p.hasAttribute('aria-expanded')) p.setAttribute('aria-expanded', String(p.dataset.crew === id));
  }
  function cards(host) {
    if (!host.ownerDocument) return;
    let timer = null;
    const later = () => { clearTimeout(timer); timer = setTimeout(() => showCard(host, null), 250); };
    const keep = () => clearTimeout(timer);
    const idOf = (el) => el.closest('[data-crew],[data-bubble]');
    host.querySelectorAll('.pivot[data-crew],[data-bubble]').forEach((el) => {
      if (el._cardBound || el.closest('#captain')) return;
      el._cardBound = true;
      const id = () => el.dataset.crew || el.dataset.bubble;
      el.addEventListener('pointerenter', (e) => { if (e.pointerType === 'mouse') { keep(); showCard(host, id()); } });
      el.addEventListener('pointerleave', (e) => { if (e.pointerType === 'mouse') later(); });
      if (!el.dataset.crew) return;
      el.addEventListener('focus', () => { if (host._cardQuiet) return; keep(); showCard(host, id()); });
      el.addEventListener('blur', later);
      el.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); showCard(host, SHIP.openCard === id() ? null : id()); }
      });
      el.addEventListener('fm-tap', () => showCard(host, SHIP.openCard === id() ? null : id()));
    });
    if (host._cardKeys) return;
    host._cardKeys = true;
    host.ownerDocument.addEventListener('keydown', (e) => {
      if (e.key !== 'Escape' || !SHIP.openCard) return;
      const was = SHIP.openCard;
      showCard(host, null);
      // back to the figure, without the focus reopening what Esc closed
      host._cardQuiet = true;
      [...host.querySelectorAll('.pivot[data-crew]')].find((p) => p.dataset.crew === was)?.focus({ preventScroll: true });
      host._cardQuiet = false;
    });
    // a tap anywhere else on the page closes the card a tap opened
    host.ownerDocument.addEventListener('pointerdown', (e) => {
      if (SHIP.openCard && e.pointerType !== 'mouse' && !idOf(e.target)) showCard(host, null);
    });
  }

  // Drag to turn a crewman; the pointer owns him until it lets go.
  //
  // Bind once to preserved figures; the scene owns only background drags.
  function drag(host) {
    if (!host.ownerDocument) return;
    host.querySelectorAll(".pivot").forEach((p) => {
      if (p._dragBound) return;
      p._dragBound = true;
      let x0 = 0, y0 = 0, ry = -26, rx = 8, on = false, moved = false;
      p.addEventListener("pointerdown", (e) => {
        e.stopPropagation(); on = true; moved = false; x0 = e.clientX; y0 = e.clientY;
        ry = parseFloat(p.style.getPropertyValue("--ry")) || -26;
        rx = parseFloat(p.style.getPropertyValue("--rx")) || 8;
        p.classList.add("dragging"); p.setPointerCapture(e.pointerId); e.preventDefault();
      });
      p.addEventListener("pointermove", (e) => {
        if (!on) return;
        if (Math.abs(e.clientX - x0) + Math.abs(e.clientY - y0) > 6) moved = true;
        p.style.setProperty("--ry", (ry + (e.clientX - x0) * 0.6) + "deg");
        p.style.setProperty("--rx", Math.max(-32, Math.min(42, rx - (e.clientY - y0) * 0.4)) + "deg");
      });
      const up = () => { on = false; p.classList.remove("dragging"); };
      // a touch that did not turn him is a tap: it toggles his card (T-116)
      p.addEventListener("pointerup", (e) => {
        const tap = on && !moved && e.pointerType !== "mouse";
        up();
        if (tap) p.dispatchEvent(new Event("fm-tap"));
      });
      p.addEventListener("pointercancel", up);
      p.addEventListener('dblclick',e=>{e.stopPropagation();p.style.removeProperty('--rx');p.style.removeProperty('--ry');});
    });
    if (host._deckDrag) return;
    host._deckDrag = true;
    let start = null;
    host.addEventListener('pointerdown', e=>{
      if (e.target.closest('button,a,.pivot,.crewcard')) return;
      start = {x:e.clientX,y:e.clientY,crew:[...host.querySelectorAll('.pivot')].map(p=>[p,parseFloat(p.style.getPropertyValue('--ry')) || -26,parseFloat(p.style.getPropertyValue('--rx')) || 8])};
      host.setPointerCapture(e.pointerId);e.preventDefault();
    });
    host.addEventListener('pointermove',e=>{if(start)for(const [p,y,x] of start.crew){p.style.setProperty('--ry',y+(e.clientX-start.x)*.6+'deg');p.style.setProperty('--rx',Math.max(-32,Math.min(42,x-(e.clientY-start.y)*.4))+'deg');}});
    for(const event of ['pointerup','pointercancel'])host.addEventListener(event,()=>{start=null;});
    host.addEventListener('dblclick',e=>{if(e.target.closest('button,a'))return;host.querySelectorAll('.pivot').forEach(p=>{p.style.removeProperty('--rx');p.style.removeProperty('--ry');});});
  }

  const handoffSeen = new Set();
  let handoffStarted = false;
  function handoffs(host, events, T, crew) {
    let layer = host.querySelector('.handoffs');
    if (!layer) {layer=document.createElement('div');layer.className='handoffs';host.append(layer);}
    host._handoffT = T;
    const person = id => crew.find(c=>c.id===id)?.name || id || T('handoffUnavailable');
    for(const e of events) {
      if(handoffSeen.has(e.identity))continue;
      handoffSeen.add(e.identity);
      if(!handoffStarted)continue;
      const cue=document.createElement('div');cue.className='handoff';cue.dataset.identity=e.identity;cue.dataset.from=e.from || '';cue.dataset.to=e.to || '';cue.dataset.kind=e.kind;
      cue.setAttribute('role','status');layer.append(cue);
      const start=performance.now(), duration=1400;
      const find=id=>[...host.querySelectorAll('.pivot')].find(p=>p.dataset.crew===id);
      let arrived=false;
      function frame(now) {
        const from=find(e.from), to=find(e.to), elapsed=now-start;
        const label=host._handoffT('handoff'+e.kind[0].toUpperCase()+e.kind.slice(1));
        cue.setAttribute('aria-label',`${label}: ${person(e.from)} → ${person(e.to)} · ${e.task || ''}`);
        if(!from || !to || matchMedia('(prefers-reduced-motion: reduce)').matches) {
          cue.style.removeProperty('left');cue.style.removeProperty('top');
          cue.classList.add('static');cue.textContent=cue.getAttribute('aria-label')+(!from||!to?' · '+host._handoffT('handoffUnavailable'):'');
        } else {
          cue.textContent={order:'ORD',work:'PR',reject:'✕',approve:'✓'}[e.kind];
          const a=from.getBoundingClientRect(),b=to.getBoundingClientRect(),h=host.getBoundingClientRect(),p=Math.min(1,elapsed/duration);
          cue.style.left=(a.x+a.width/2+(b.x+b.width/2-a.x-a.width/2)*p-h.x)+'px';
          cue.style.top=(a.y+a.height/2+(b.y+b.height/2-a.y-a.height/2)*p-h.y)+'px';
          if(p===1&&!arrived){arrived=true;to.classList.add('react');const bubble=[...host.querySelectorAll('[data-bubble]')].find(b=>b.dataset.bubble===e.to);bubble?.classList.add('ping');setTimeout(()=>{to.classList.remove('react');bubble?.classList.remove('ping');},700);}
        }
        if(elapsed<2300)requestAnimationFrame(frame);else cue.remove();
      }
      requestAnimationFrame(frame);
    }
    handoffStarted=true;
  }

  // synthesised, so the board carries no audio files
  let ac = null, master = null;
  const sources = new Set();
  let unlocked = false, current = null;
  const effects = [], handled = new Set();
  function unlock() {
    unlocked = true;
    if (SHIP.muted) return;
    try {
      ac = ac || new (window.AudioContext || window.webkitAudioContext)();
      master = master || ac.createGain(); master.connect(ac.destination);
      master.gain.setValueAtTime(1, ac.currentTime);
      if (ac.state === 'suspended') Promise.resolve(ac.resume()).catch(() => {});
    } catch (_) {}
  }
  function silence() {
    effects.forEach(effect => { effect.audio = false; });
    try { master?.gain.setValueAtTime(0, ac.currentTime); } catch (_) {}
    for (const source of sources) { try { source.stop(); } catch (_) {} }
    sources.clear();
  }
  function sound(kind, host) {
    if (kind !== 'merge' || SHIP.muted || !unlocked) return;
    try {
      unlock();
      (host._guns || []).forEach((_, i) => boom(i * .07, .34));
    } catch (_) { /* optional audio never changes a recorded decision */ }
  }
  function boom(at, gain) {
    if (SHIP.muted || !ac || !master) return;
    try {
      ac = ac || new (window.AudioContext || window.webkitAudioContext)();
      if (ac.state === "suspended") Promise.resolve(ac.resume()).catch(() => {});
    } catch (_) { return; }
    const t0 = ac.currentTime + at, len = 0.5;
    const buf = ac.createBuffer(1, Math.floor(ac.sampleRate * len), ac.sampleRate);
    const d = buf.getChannelData(0);
    for (let i = 0; i < d.length; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / d.length, 2.6);
    const src = ac.createBufferSource(); src.buffer = buf;
    const lp = ac.createBiquadFilter(); lp.type = "lowpass";
    lp.frequency.setValueAtTime(900, t0); lp.frequency.exponentialRampToValueAtTime(110, t0 + len);
    const g = ac.createGain(); g.gain.setValueAtTime(gain, t0); g.gain.exponentialRampToValueAtTime(0.001, t0 + len);
    src.connect(lp).connect(g).connect(master); sources.add(src); src.onended = () => sources.delete(src);
    src.start(t0); src.stop(t0 + len);
  }

  function applyEffect(host) {
    if (!current) return;
    const elapsed = (Date.now() - current.start) / 1000;
    const banner = host.querySelector('#ahoy');
    banner.textContent = current.kind === 'order' ? 'AYE, CAPTAIN! / ORDERS AWAY' : 'AHOY! / MERGED INTO MAIN';
    banner.classList.add('active');
    host.dataset.effect = current.id;
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduced) return;
    host.querySelectorAll('.fig').forEach((f, i) => {
      if (!f.classList.contains('cheer')) {
        f.classList.add('cheer'); f.style.animationDelay = `${i * .055 - elapsed}s`;
      }
    });
    const target = host.querySelector(current.kind === 'order' ? '.helm' : '#vessel');
    const targetClass = current.kind === 'order' ? 'orders' : 'heel';
    if (!target.classList.contains(targetClass)) {
      target.classList.add(targetClass); target.style.animationDelay = `${-elapsed}s`;
    }
    if (current.kind === 'merge') {
      const salvo = host.querySelector('#salvo');
      if (!salvo.classList.contains('fire')) {
        salvo.classList.add('fire');
        salvo.querySelectorAll('i').forEach((el, i) => { el.style.animationDelay = `${i * .07 - elapsed}s`; });
      }
    }
  }
  function nextEffect(host) {
    if (current || !effects.length) return;
    current = {...effects.shift(), start:Date.now()};
    applyEffect(host); if (current.audio) sound(current.kind, host);
    document.dispatchEvent(new Event('ship-effect'));
    setTimeout(() => {
      current = null;
      host.querySelectorAll('.cheer,.heel,.orders,.fire,.active').forEach(el => {
        el.classList.remove('cheer','heel','orders','fire','active'); el.style.animationDelay = '';
      });
      delete host.dataset.effect;
      document.dispatchEvent(new Event('ship-effect')); nextEffect(host);
    }, 3200);
  }
  let demos = 0;
  function enqueue(host, kind, id) {
    if (handled.has(id)) return;
    handled.add(id); effects.push({kind,id,audio:!SHIP.muted && unlocked}); nextEffect(host);
  }

  return { render, roster, captain, portrait, patch, enqueue, unlock, active:() => current,
           rateFor, actionFor, crewOf, layout, RATES, ACTIONS, ROLE, prRef, linkPrs, projectColor,
           // T-116: the one open detail card, and the roster's order and grouping
           openCard: null,
           rosterSort: (() => { try { return localStorage.getItem("board.rosterSort") || null; } catch (_) { return null; } })(),
           rosterGroup: (() => { try { return !!localStorage.getItem("board.rosterGroup"); } catch (_) { return false; } })(),
           muted: (() => { try { return !!localStorage.getItem("board.muted"); } catch (_) { return false; } })(),
           // shown unless the captain hid it; the choice survives a reload
           rosterOn: (() => { try { return localStorage.getItem("board.roster") !== "hidden"; } catch (_) { return true; } })() };
})();
if (typeof module !== "undefined") module.exports = SHIP;
