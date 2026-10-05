// Crew roster, captain portrait and shared helpers; this module no longer draws a ship.
const SHIP = (() => {
  const hash = (s) => { let h = 7; for (const c of String(s)) h = (h * 31 + c.charCodeAt(0)) >>> 0; return h; };
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

  const projectColor = (p) => `hsl(${hash(p) % 360} 62% 60%)`;
  // the server sends one of these three; an unknown one is a mismatch
  // between the two halves, and .roster li[data-role="unknown"] marks it. Exported
  // because the sheet has to carry a rule for every value in here and
  // nothing can check that against a constant it cannot see.
  const ROLE = { firstmate: "fm", worker: "w", reviewer: "r" };   // the human captain is not a crew row
  // The server names the active agents; task backlog never creates crew rows.
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
        mode: a.mode,
        round: Number.isInteger(a.round) ? a.round : null,
        attempt: Number.isInteger(a.attempt) ? a.attempt : null,
        // T-127: what the round actually ran on, read from the run itself;
        // null/false for a run recorded before this, never guessed
        host_recorded: !!a.host_recorded,
        host_confirmed: a.host_confirmed,
        vendor: a.vendor || null,
        model: a.model || null,
        model_requested: a.model_requested || null,
        cli_version: a.cli_version || null,
        model_mismatch: !!a.model_mismatch,
        // only firstmate can be aboard without a task: the server skips a
        // taskless worker or reviewer, so there is no third case to write
        job: a.task ? `${a.task} · ${activity}` : activity,
        activity,
        task: a.task || null,
        title: a.title || null,
        // the project of the task it is on: shown in every roster row
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

  // Patch matching nodes in place, preserving shared board interaction state.
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

  // The voyage captain, beside the first decision and gone when nothing waits.
  function portrait(host, show, T) {
    if (!host) return;
    host.hidden = !show;
    if (!show) { if (host.firstChild) host.innerHTML = ""; return; }
    if (!host.querySelector(".lbl")) {
      host.innerHTML = (typeof window !== "undefined" && window.VOYAGE
        ? '<img class="capimg" src="/voyage2d/captain.webp" alt="" width="401" height="598">' : '') +
        '<div class="lbl"><b></b><span></span></div>';
      const img = host.querySelector('.capimg');
      if (img) {
        img.onerror = () => { img.hidden = true; };
        if (img.complete && !img.naturalWidth) img.hidden = true;
      }
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
    task: (c) => c.task || "", round: (c) => c.mode === "spec-preflight" ? -1 : c.round ?? -1, state: (c) => c.state,
    vendor: (c) => c.vendor || "", model: (c) => c.model || "",
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
    const row = (c) => `<li class="rrow st-${c.state}" data-roster="${esc(c.id)}" data-role="${esc(c.role)}"${c.project ? ` data-project="${esc(c.project)}"` : ""}>` +
      `<div class="l1"><span class="av" aria-hidden="true"></span>` +
      `<span class="nm" data-label="${esc(T("crewName"))}">${esc(c.name)}</span>` +
      cell("rl", T("crewRole"), esc(c.roleLabel)) +
      `<span class="pj${c.showProject ? " pchip" : ""}" data-label="${esc(T("projectChip"))}"${c.showProject ? ` title="${esc(T("projectChip"))}: ${esc(c.project || T("crewUnknown"))}"` : ""}>` + (c.project
        ? `<i class="pdot" style="--pc:${projectColor(c.project)}" aria-hidden="true"></i>${esc(c.project)}` : unknown) + `</span>` +
      (c.role === "fm" && !c.host_recorded ? "" :
      cell("rv" + (c.host_confirmed === false ? " warn" : ""), T("crewVendor"),
        c.host_confirmed === false ? esc(T("hostUnconfirmed").replace("{vendor}", c.vendor || T("crewUnknown")))
          : c.vendor ? esc(c.vendor) : unknown) +
      cell("rm" + (c.model_mismatch ? " warn" : ""), T("crewModel"), c.model_mismatch
        ? esc(T("modelMismatch").replace("{requested}", c.model_requested || unknown).replace("{model}", c.model || unknown))
        : c.model ? esc(c.model) : unknown) +
      cell("rc", T("crewCli"), c.cli_version ? esc(c.cli_version) : unknown)) +
      cell("rd", T("crewRound"), c.mode === "spec-preflight" ? esc(T("specPreflight")) : c.round == null ? unknown
        : esc(c.round) + (c.attempt > 1 ? ` <span class="att">${esc(T("crewAttempt"))} ${esc(c.attempt)}</span>` : "")) +
      `<span class="st" data-label="${esc(T("crewState"))}">${esc(T("lane" + c.state[0].toUpperCase() + c.state.slice(1)))}</span>` +
      `<span class="rpr" data-label="${esc(T("crewPr"))}">${c.pr ? prRef(c.pr, c.pr_url) : ""}</span></div>` +
      `<div class="jb" data-label="${esc(T("crewTask"))}">` +
      (c.task ? `<b class="tk">${esc(c.task)}</b> <span class="tt">${linkPrs(esc(c.title || T("titleMissing")), c.pr_urls)}</span> ` : "") +
      `<span class="act">${linkPrs(esc(c.activity), c.pr_urls)}</span>` +
      (c.state === "waiting_ci" ? cell("cwindow", T("crewWindow"), esc(T("ciNoWindow"))) : "") +
      (c.progress
        ? `<span class="pb" role="progressbar" aria-valuemin="0" aria-valuenow="${c.progress.done}" ` +
          `aria-valuemax="${c.progress.total}" title="${c.progress.done}/${c.progress.total}">` +
          `<i style="width:${c.pct}%"></i></span>`
        : "") +
      `</div></li>`;
    const head = `<div class="rhead" role="group" aria-label="${esc(T("rosterSort"))}">` +
      [["name", T("crewName")], ["role", T("crewRole")], ["project", T("projectChip")],
      ["vendor", T("crewVendor")], ["model", T("crewModel")], [null, T("crewCli")],
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

  return { roster, portrait, patch, crewOf, ROLE, prRef, linkPrs, projectColor, esc,
           rosterSort: (() => { try { return localStorage.getItem("board.rosterSort") || null; } catch (_) { return null; } })(),
           rosterGroup: (() => { try { return !!localStorage.getItem("board.rosterGroup"); } catch (_) { return false; } })(),
           // shown unless the captain hid it; the choice survives a reload
           rosterOn: (() => { try { return localStorage.getItem("board.roster") !== "hidden"; } catch (_) { return true; } })() };
})();
if (typeof module !== "undefined") module.exports = SHIP;
