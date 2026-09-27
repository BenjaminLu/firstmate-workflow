// The game-first HUD: a status cluster in one corner, the menu button and the language switch
// in the other, one prompt at the bottom, toasts that come and go. The board, the roster, the
// voyage chart and the settings live behind the menu (the game pauses and dims); the decision
// card shows only while a decision waits. Every label in English, 繁體中文 and 简体中文.
// It renders from sim state and dispatches intents; it never changes the simulation itself.
import { CONFIG } from "../v3src/sim/config.js";
import { rankName, tally } from "../v3src/sim/sim.js";

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
export const LANGS = ["en", "zh-TW", "zh-CN"];
const LANE_IDS = ["issues", "backlog", "ready", "working", "review", "merged"];
// what the board lets the captain do to a card, by lane (board/server.ts ACTIONS; the sim has
// no parked lane). Nothing else on a card is the captain's: dispatching is the firstmate's.
export const BOARD_ACTIONS = { ready: ["park", "drop"], backlog: ["park", "drop"] };

// ---------------------------------------------------------------- the dictionary
const T = {
  en: {
    merged: "merged", inflight: "in flight", waiting: "waiting on you", crew: "crew",
    tap: "TAP", menu: "Menu", board: "BOARD", roster: "ROSTER", chart: "CHART", settings: "SETTINGS", resume: "RESUME",
    boardSub: "the fleet's lanes · paused", rosterSub: "by role and state · paused", chartSub: "the voyage · paused", settingsSub: "the ship's customs · paused",
    lanes: ["Issues", "Backlog", "Ready", "Working", "Review", "Merged"], paused: "Paused · Esc or tap outside to return",
    park: "Park", drop: "Drop", chat: "chat", issue: "issue", round: "round", gateRed: "gate red", kraken: "kraken", approved: "approved",
    command: "Command", review: "Review", workers: "Workers",
    st: { idle: "idle", working: "working", walking: "walking", waiting: "waiting", standby: "standby", blocked: "blocked", down: "down", review: "reviewing" },
    rituals: "Rituals", sound: "Sound", speed: "Speed", detail: "Detail", style: "Style", freecam: "Free camera", language: "Language", hands: "Hands aboard", on: "On", off: "Off",
    rit: { order: "The order", salvo: "The merge salvo", port: "Making port", salute: "The salute", clearing: "Clearing and a cheer", weather: "Weather" },
    decision: "DECISION", later: "Later", open: "Open", recommended: "recommended", keys: "A–D to choose · Enter to confirm",
    home: "home", fog: "uncharted", ship: "ship", ofMerged: "merged",
    loading: "Hoisting the sails…", welcome: "Welcome aboard, captain. The crew are at work; a card comes up when they need your call.", playground: "PLAYGROUND · simulated",
    tFight: "fight the kraken", tStop: "stop playing",
    grows: "The ship grows", trims: "The ship trims down",
    f: { name: "Name", role: "Role", project: "Project", task: "Task", round: "Round", pr: "PR", state: "State", activity: "Activity", rank: "Rank", vendor: "Vendor" },
    roles: { captain: "Captain", firstmate: "Firstmate", reviewer: "Reviewer", worker: "Worker" },
    act: { lookout: "on lookout", signal: "signalling", point: "pointing the way", log: "writing the log", haul: "hauling lines", capstan: "at the capstan", carry: "carrying", climb: "climbing", hammer: "hammering", saw: "sawing", swab: "swabbing", lean: "at ease", coil: "coiling rope", mend: "mending" },
    styles: { p5: "Crimson", manga: "Manga" },
    now: "NOW", ifPick: "IF", parkedL: "Parked", droppedL: "Dropped", fightL: "Kraken fight", portL: "Waits for port", deck: "Cards waiting",
    prOpen: "open", prApproved: "approved", prMerged: "merged", none: "—", close: "Close",
  },
  "zh-TW": {
    merged: "已合併", inflight: "進行中", waiting: "等你決定", crew: "船員",
    tap: "點擊", menu: "選單", board: "看板", roster: "船員名冊", chart: "航海圖", settings: "設定", resume: "繼續",
    boardSub: "艦隊的泳道 · 已暫停", rosterSub: "依職務與狀態 · 已暫停", chartSub: "這趟航程 · 已暫停", settingsSub: "船上的規矩 · 已暫停",
    lanes: ["議題", "待辦", "就緒", "進行中", "審查", "已合併"], paused: "已暫停 · 按 Esc 或點擊外面返回",
    park: "擱置", drop: "放棄", chat: "對話", issue: "議題", round: "第幾輪", gateRed: "檢查紅燈", kraken: "海怪", approved: "已通過",
    command: "指揮", review: "審查", workers: "水手",
    st: { idle: "待命", working: "工作中", walking: "走動中", waiting: "等待中", standby: "備便", blocked: "受阻", down: "倒下", review: "審查中" },
    rituals: "儀式", sound: "音效", speed: "速度", detail: "畫質", style: "風格", freecam: "自由鏡頭", language: "語言", hands: "在船人數", on: "開", off: "關",
    rit: { order: "下令", salvo: "合併禮炮", port: "進港", salute: "敬禮", clearing: "放晴與歡呼", weather: "天氣" },
    decision: "決策", later: "稍後", open: "打開", recommended: "推薦", keys: "A–D 選擇 · Enter 確認",
    home: "母港", fog: "未知海域", ship: "船", ofMerged: "已合併",
    loading: "升帆中…", welcome: "歡迎登船，船長。船員已開工；需要你決定時，決策卡會出現。", playground: "遊樂場 · 模擬",
    tFight: "迎戰海怪", tStop: "停止操作",
    grows: "船艦升級", trims: "船艦縮編",
    f: { name: "名字", role: "職務", project: "專案", task: "任務", round: "審查輪次", pr: "PR", state: "狀態", activity: "動作", rank: "階級", vendor: "模型" },
    roles: { captain: "船長", firstmate: "大副", reviewer: "審查員", worker: "水手" },
    act: { lookout: "瞭望", signal: "打旗號", point: "指路", log: "寫航海日誌", haul: "拉纜繩", capstan: "推絞盤", carry: "搬運", climb: "攀爬", hammer: "敲打", saw: "鋸木", swab: "拖甲板", lean: "休息", coil: "盤繩", mend: "補帆" },
    styles: { p5: "緋紅", manga: "漫畫" },
    now: "現在", ifPick: "若選", parkedL: "已擱置", droppedL: "已放棄", fightL: "海怪之戰", portL: "等下一個港口", deck: "待決的卡",
    prOpen: "開啟中", prApproved: "已通過", prMerged: "已合併", none: "—", close: "關閉",
  },
  "zh-CN": {
    merged: "已合并", inflight: "进行中", waiting: "等你决定", crew: "船员",
    tap: "点击", menu: "菜单", board: "看板", roster: "船员名册", chart: "航海图", settings: "设置", resume: "继续",
    boardSub: "舰队的泳道 · 已暂停", rosterSub: "按职务与状态 · 已暂停", chartSub: "这趟航程 · 已暂停", settingsSub: "船上的规矩 · 已暂停",
    lanes: ["议题", "待办", "就绪", "进行中", "审查", "已合并"], paused: "已暂停 · 按 Esc 或点击外面返回",
    park: "搁置", drop: "放弃", chat: "对话", issue: "议题", round: "第几轮", gateRed: "检查红灯", kraken: "海怪", approved: "已通过",
    command: "指挥", review: "审查", workers: "水手",
    st: { idle: "待命", working: "工作中", walking: "走动中", waiting: "等待中", standby: "备便", blocked: "受阻", down: "倒下", review: "审查中" },
    rituals: "仪式", sound: "音效", speed: "速度", detail: "画质", style: "风格", freecam: "自由镜头", language: "语言", hands: "在船人数", on: "开", off: "关",
    rit: { order: "下令", salvo: "合并礼炮", port: "进港", salute: "敬礼", clearing: "放晴与欢呼", weather: "天气" },
    decision: "决策", later: "稍后", open: "打开", recommended: "推荐", keys: "A–D 选择 · Enter 确认",
    home: "母港", fog: "未知海域", ship: "船", ofMerged: "已合并",
    loading: "升帆中…", welcome: "欢迎登船，船长。船员已开工；需要你决定时，决策卡会出现。", playground: "游乐场 · 模拟",
    tFight: "迎战海怪", tStop: "停止操作",
    grows: "船舰升级", trims: "船舰缩编",
    f: { name: "名字", role: "职务", project: "项目", task: "任务", round: "审查轮次", pr: "PR", state: "状态", activity: "动作", rank: "阶级", vendor: "模型" },
    roles: { captain: "船长", firstmate: "大副", reviewer: "审查员", worker: "水手" },
    act: { lookout: "瞭望", signal: "打旗号", point: "指路", log: "写航海日志", haul: "拉缆绳", capstan: "推绞盘", carry: "搬运", climb: "攀爬", hammer: "敲打", saw: "锯木", swab: "拖甲板", lean: "休息", coil: "盘绳", mend: "补帆" },
    styles: { p5: "绯红", manga: "漫画" },
    now: "现在", ifPick: "若选", parkedL: "已搁置", droppedL: "已放弃", fightL: "海怪之战", portL: "等下一个港口", deck: "待决的卡",
    prOpen: "开启中", prApproved: "已通过", prMerged: "已合并", none: "—", close: "关闭",
  },
};
// fixed phrases said by the stage (banners, the battle's prompts): English -> [繁, 简]
const PHRASES = {
  "Aye, captain.": ["是，船長。", "是，船长。"],
  "Aye, captain. Orders away": ["是，船長。命令已下達", "是，船长。命令已下达"],
  "A salute: approved on the first round": ["敬禮：首輪就通過", "敬礼：首轮就通过"],
  "Clearing, and a cheer": ["放晴，一陣歡呼", "放晴，一阵欢呼"],
  "Merged into main": ["已合併進 main", "已合并进 main"],
  "Ahoy! Merged into main": ["啊喂！已合併進 main", "啊喂！已合并进 main"],
  "All hands! Read the arm, parry at the gold": ["全員就位！看準觸手，金光時格擋", "全员就位！看准触手，金光时格挡"],
  "TAP TO FIRE": ["點擊開火", "点击开火"], "TAP! PARRY": ["點擊！格擋", "点击！格挡"], "TAP! BRACE": ["點擊！穩住", "点击！稳住"], "BRACED!": ["穩住了！", "稳住了！"],
  "TAP! COUNTER": ["點擊！反擊", "点击！反击"], "WAIT…": ["等等…", "等等…"], "get ready": ["準備", "准备"], "PARRY!": ["格擋！", "格挡！"],
  "TAP! DODGE": ["點擊！閃避", "点击！闪避"], "TAP! DUCK": ["點擊！蹲下", "点击！蹲下"], "TAP! JUMP": ["點擊！跳起", "点击！跳起"],
  "Victory!": ["勝利！", "胜利！"],
  "TAP! 承認": ["點擊！承認", "点击！承认"], "TAP! 反撃": ["點擊！反擊", "点击！反击"], "ゴゴゴ… MAELSTROM": ["ゴゴゴ… 大漩渦", "ゴゴゴ… 大漩涡"], "TAP! SHOOT": ["點擊！射擊", "点击！射击"],
  "only an approval wins": ["只有通過才算贏", "只有通过才算赢"], "the swell is coming": ["大浪要來了", "大浪要来了"], "the crushing tide": ["壓頂的巨浪", "压顶的巨浪"], "fire at will": ["自由開火", "自由开火"],
  slam: ["重擊", "重击"], jab: ["突刺", "突刺"], "sweep · unblockable": ["橫掃 · 無法格擋", "横扫 · 无法格挡"], ink: ["墨汁", "墨汁"],
  "the kraken lets go · approved on the board": ["海怪放手了 · 看板上已通過", "海怪放手了 · 看板上已通过"],
};
// the board's events as toasts, per language (the few that matter; the rest stay in the log)
const EVENTS = {
  order: (e, n) => !e.resume && !e.sendback && [`Order: ${e.task} to ${n(e.worker)}`, `命令：${e.task} 交給 ${n(e.worker)}`, `命令：${e.task} 交给 ${n(e.worker)}`],
  pr_opened: (e, n) => [`${e.task}: pull request by ${n(e.worker)}`, `${e.task}：${n(e.worker)} 開了 PR`, `${e.task}：${n(e.worker)} 开了 PR`],
  review_approved: (e) => [`${e.task} approved${e.firstRound ? " on the first round" : ""}`, `${e.task} 審查通過${e.firstRound ? "（首輪）" : ""}`, `${e.task} 审查通过${e.firstRound ? "（首轮）" : ""}`],
  review_rejected: (e) => [`${e.task}: round ${e.round} sent back`, `${e.task}：第 ${e.round} 輪被退回`, `${e.task}：第 ${e.round} 轮被退回`],
  gate_failed: (e) => [`${e.task}: the gate is red (weather, not blame)`, `${e.task}：檢查亮紅燈（是天氣，不是誰的錯）`, `${e.task}：检查亮红灯（是天气，不是谁的错）`],
  merged: (e) => [`${e.task} merged into main`, `${e.task} 已合併進 main`, `${e.task} 已合并进 main`],
  kraken_arm: (e) => [`The kraken holds ${e.task}`, `海怪纏住了 ${e.task}`, `海怪缠住了 ${e.task}`],
  battle_begin: (e) => [`The battle for ${e.task} begins`, `${e.task} 之戰開始`, `${e.task} 之战开始`],
  victory: (e) => [`Victory: ${e.task} approved`, `勝利：${e.task} 通過`, `胜利：${e.task} 通过`],
  making_port: (e) => [`Making port: ${e.port}`, `進港：${e.port}`, `进港：${e.port}`],
  promoted: (e, n) => [`${n(e.crew)} rated ${e.rank}`, `${n(e.crew)} 晉升為 ${RANKS[e.rank]?.[0] || e.rank}`, `${n(e.crew)} 晋升为 ${RANKS[e.rank]?.[1] || e.rank}`],
  decision_requested: (e) => [`${e.decision.id} waits on you`, `${e.decision.id} 等你決定`, `${e.decision.id} 等你决定`],
  task_new: (e) => [`${e.task} joined the plan`, `${e.task} 加入計畫`, `${e.task} 加入计划`],
  hired: (e) => [`${e.crew} came aboard`, `${e.crew} 登船了`, `${e.crew} 登船了`],
  dismissed: (e) => [`${e.crew} went ashore`, `${e.crew} 上岸了`, `${e.crew} 上岸了`],
};
const EV_ICON = { merged: "⚓", victory: "★", making_port: "⚑", promoted: "★", kraken_arm: "☸", battle_begin: "☸", decision_requested: "!", gate_failed: "☁", hired: "+", dismissed: "−" };
const EV_GOLD = new Set(["merged", "victory", "making_port", "promoted", "hired"]);
// the decision cards, by kind and by each option's effect: [title, body] and [label, pro, con]
const DECK = {
  choice: (d) => [[`How should ${d.task} land?`, `${d.task} 要怎麼落地？`, `${d.task} 要怎么落地？`], [d.body, `船員需要船長決定 ${d.task} 才能繼續。`, `船员需要船长决定 ${d.task} 才能继续。`]],
  merge: (d) => [[`Merge ${d.task}?`, `要合併 ${d.task} 嗎？`, `要合并 ${d.task} 吗？`], [d.body, "審查已通過，所有檢查都是綠燈。", "审查已通过，所有检查都是绿灯。"]],
  kraken: (d) => [[`The kraken holds ${d.task}`, `海怪纏住了 ${d.task}`, `海怪缠住了 ${d.task}`], [d.body, `${d.task} 審查多輪仍未通過。迎戰，或放手。`, `${d.task} 审查多轮仍未通过。迎战，或放手。`]],
  scope: (d) => [[d.title, `勘查 ${d.task}`, `勘查 ${d.task}`], [d.body, "大副起草了規格。", "大副起草了规格。"]],
};
const OPTS = {
  proceed: [["照規格做", "維持計畫", "改動較大"], ["照规格做", "维持计划", "改动较大"]],
  rescope: [["縮小範圍", "少一輪審查", "留下後續任務"], ["缩小范围", "少一轮审查", "留下后续任务"]],
  park: [["先擱置", "釋放船員", "任務等待"], ["先搁置", "释放船员", "任务等待"]],
  merge: [["合併", "航程前進", "—"], ["合并", "航程前进", "—"]],
  sendback: [["退回", "再看一次", "多一輪"], ["退回", "再看一次", "多一轮"]],
  hold: [["暫緩", "等下一個港口", "任務閒置"], ["暂缓", "等下一个港口", "任务闲置"]],
  battle: [["迎戰", "開戰，一起玩", "只有通過才算贏"], ["迎战", "开战，一起玩", "只有通过才算赢"]],
  drop: [["放棄", "海怪整隻沉下去", "工作被放棄"], ["放弃", "海怪整只沉下去", "工作被放弃"]],
  spec: [["批准規格", "迷霧散去", "—"], ["批准规格", "迷雾散去", "—"]],
  skip: [["略過", "隱藏議題", "留在迷霧裡"], ["略过", "隐藏议题", "留在迷雾里"]],
};

// a crewman's project: the milestone of the task in hand, with its colour (the flag on his name tag)
export const PROJECT_COLS = ["#e60012", "#2a5ad8", "#1f9a52", "#e0a400", "#8a2cc0", "#e0569a"];
export function projectOf(c, s) {
  const task = c?.task && s.tasks.find((t) => t.id === c.task);
  if (!task) return null;
  const mi = Math.max(0, s.milestones.findIndex((m) => m.id === task.milestone));
  return { id: task.milestone, name: CONFIG.ports[mi + 1]?.name || task.milestone, col: PROJECT_COLS[mi % PROJECT_COLS.length], task };
}

// rank names: English -> [繁, 简]
const RANKS = {
  deckhand: ["水手", "水手"], "able seaman": ["一等水手", "一等水手"], "bosun's mate": ["副水手長", "副水手长"], bosun: ["水手長", "水手长"], quartermaster: ["舵手長", "舵手长"],
  "apprentice inspector": ["見習審查員", "见习审查员"], inspector: ["審查員", "审查员"], "chief inspector": ["首席審查員", "首席审查员"],
};

function storedLang() {
  const q = new URLSearchParams(location.search).get("lang");
  if (LANGS.includes(q)) return q;
  try {
    const l = localStorage.getItem("v2d-lang");
    if (LANGS.includes(l)) return l;
  } catch {}
  return "en";
}

export class HUD {
  constructor(h) {
    this.h = h; // intents: answer, cardAction (park/drop), ritual, sound, camera, speed, detail, style, pause, play, prompt
    this.lang = storedLang();
    this.tab = null; // the open menu tab, or null
    this.decisionShown = null;
    this.minimised = false;
    this.pick = null;
    this.flags = {};
    this.toastsOn = [];
    this.s = null;
    this.promptKey = "";
    for (const b of document.querySelectorAll("#lang button")) b.addEventListener("click", () => this.setLang(b.dataset.lang));
    $("menuBtn").addEventListener("click", () => this.toggle(this.tab ? null : "board"));
    $("menu").addEventListener("click", (e) => {
      const nav = e.target.closest("[data-tab]");
      if (nav) return nav.dataset.tab === "resume" ? this.toggle(null) : this.toggle(nav.dataset.tab);
      if (e.target === $("menu")) return this.toggle(null);
      const c = e.target.closest("[data-card]");
      if (c) return this.h.cardAction(c.dataset.card, c.dataset.id);
      const set = e.target.closest("[data-set]");
      if (set) return this.setting(set.dataset.set, set.dataset.v);
    });
    $("decision").addEventListener("click", (e) => {
      const o = e.target.closest("[data-key]");
      if (o) return (this.choose(o.dataset.key), this.confirm());
      if (e.target.closest("[data-later]")) return this.minimise();
    });
    $("waitChip").addEventListener("click", () => this.minimised && this.minimise());
    $("deckIcon")?.addEventListener("click", () => this.minimised && this.minimise());
    const lit = (e) => { const o = e.target.closest?.(".opt"); if (o) this.highlight(o.dataset.key); };
    const unlit = (e) => { if (e.target.closest?.(".opt")) this.highlight(this.pick || ""); };
    $("decision").addEventListener("pointerover", lit);
    $("decision").addEventListener("focusin", lit);
    $("decision").addEventListener("pointerout", unlit);
    $("prompt").addEventListener("click", () => this.h.prompt?.());
    $("crewCard").addEventListener("click", (e) => e.target.closest("[data-crewclose]") && this.hideCrew());
    // keyboard: every crewman is a focusable (visually hidden) button; focus opens his card
    $("crewFocus").addEventListener("focusin", (e) => { const b = e.target.closest("[data-crew]"); if (b) this.showCrew(b.dataset.crew, this.h.crewAt?.(b.dataset.crew)); });
    $("crewFocus").addEventListener("focusout", () => this.hideCrew());
    this.applyLang();
  }
  get t() { return T[this.lang]; }
  // a fixed English phrase in the current language
  tr(text) {
    if (!text || this.lang === "en") return text;
    const p = PHRASES[text];
    return p ? p[this.lang === "zh-TW" ? 0 : 1] : text;
  }
  pick3(a) { return a[LANGS.indexOf(this.lang)] ?? a[0]; }
  rankWords(r) { return [r, RANKS[r]?.[0] || r, RANKS[r]?.[1] || r]; }
  rank(c) {
    const r = c.role === "captain" || c.role === "firstmate" ? this.t.roles[c.role] : rankName(c);
    return this.lang === "en" || !RANKS[r] ? r : RANKS[r][this.lang === "zh-TW" ? 0 : 1];
  }
  setLang(l) {
    if (!LANGS.includes(l)) return;
    this.lang = l;
    try { localStorage.setItem("v2d-lang", l); } catch {}
    this.applyLang();
  }
  applyLang() {
    document.documentElement.lang = this.lang;
    for (const e of document.querySelectorAll("[data-t]")) e.textContent = this.t[e.dataset.t] ?? "";
    for (const b of document.querySelectorAll("#lang button")) b.setAttribute("aria-pressed", b.dataset.lang === this.lang);
    $("menuBtn").setAttribute("aria-label", this.t.menu);
    this.decisionShown = null; // re-render the card in the new language
    this.promptKey = "";
    if (this.s) this.render(this.s);
  }
  // ---------------------------------------------------------------- the menu (pauses the game)
  toggle(name, force) {
    const tab = force === false ? null : name === "customs" ? "settings" : name;
    const next = tab === this.tab && force === undefined && name !== null ? null : tab;
    this.tab = next;
    document.body.classList.toggle("menu", !!next);
    for (const b of document.querySelectorAll("#menu nav [data-tab]")) b.toggleAttribute("aria-current", b.dataset.tab === next);
    $("menuBtn").setAttribute("aria-expanded", !!next);
    this.h.pause?.(!!next);
    if (next && this.s) this.renderSheet(this.s);
    return !!next;
  }
  expandBoard() { return this.toggle("board"); }
  get menuOpen() { return !!this.tab; }
  setFlag(id, on, label) { this.flags[id] = { on: !!on, label }; if (this.tab === "settings" && this.s) this.renderSheet(this.s); }
  setting(k, v) {
    const h = this.h;
    if (k === "lang") this.setLang(v);
    else if (k === "ritual") h.ritual(v, !(this.flags["r-" + v]?.on ?? true));
    else h[k]?.(v);
    if (this.s) this.renderSheet(this.s);
  }
  // ---------------------------------------------------------------- toasts and banners
  toast(text, { icon = "•", gold = false, sub = "", ms = 4200 } = {}) {
    const box = $("toasts");
    const el = document.createElement("div");
    el.className = "toast" + (gold ? " gold" : "");
    el.innerHTML = `<span class="ic">${esc(icon)}</span><span>${esc(text)}${sub ? `<small>${esc(sub)}</small>` : ""}</span>`;
    box.prepend(el);
    while (box.children.length > 3) box.lastChild.remove();
    setTimeout(() => (el.classList.add("out"), setTimeout(() => el.remove(), 400)), ms);
  }
  // a board event as a toast, in the current language
  event(e, s) {
    const f = EVENTS[e.type];
    if (!f) return;
    const n = (id) => s?.crew.find((c) => c.id === id)?.name || id || "";
    const r = f(e, n);
    if (r) this.toast(this.pick3(r), { icon: EV_ICON[e.type] || "•", gold: EV_GOLD.has(e.type) });
  }
  caption(text, ms = 6000) { if (text) this.toast(this.tr(text), { icon: "⚓", ms }); }
  dismissCaption() { for (const el of document.querySelectorAll("#toasts .toast")) el.remove(); }
  placeCaption() {}
  // the big tilted banner across the top: a phrase, or a {en, tw, cn} triple
  banner(text, kind = "") {
    const b = $("banner");
    const s = typeof text === "object" ? this.pick3([text.en, text.tw, text.cn]) : this.tr(text);
    b.innerHTML = `<span>${esc(s)}</span>`;
    b.className = "show " + kind;
    b.dataset.kind = kind;
    clearTimeout(this.bannerTimer);
    this.bannerTimer = setTimeout(() => (b.className = ""), kind === "transform" ? 3400 : 2400);
  }
  battleBand(info) { this.band = info; }
  combo() {}
  loading(text) { $("loading").hidden = !text; $("loading").textContent = text ? this.t.loading : ""; }
  error(text) { const e = $("error"); e.hidden = !text; e.textContent = text; }
  // ---------------------------------------------------------------- the one prompt
  // {key, id} from the stage (the first thing to tap), or null; hidden in the fight (the canvas
  // draws the fight's prompt) and while a card or the menu is up
  setPrompt(p, battle) {
    const key = p ? p.key : battle?.inBattle && !battle.playing ? "tFight" : "";
    const hide = !key || this.tab || (this.decisionShown && !this.minimised) || document.body.classList.contains("ending");
    const k = hide ? "" : key + this.lang;
    if (k === this.promptKey) return;
    this.promptKey = k;
    $("prompt").hidden = !k;
    if (k) $("prompt").innerHTML = `<b>${esc(this.t.tap)}</b><span>${esc(this.t[key])}</span>`;
  }
  // ---------------------------------------------------------------- render from state
  render(s) {
    this.s = s;
    const t = tally(s);
    const set = (id, v) => { const e = $(id); if (e && e.textContent !== String(v)) e.textContent = v; };
    set("n-merged", t.merged);
    set("n-flight", t.inFlight);
    set("n-wait", s.decisions.length);
    $("waitChip").classList.toggle("zero", !s.decisions.length);
    const info = this.h.shipInfo?.();
    if (info) (set("n-crew", s.crew.length), set("shipName", this.pick3([info.en, info.tw, info.cn])));
    const fk = s.crew.map((c) => c.id + ":" + c.name).join() + this.lang;
    if ($("crewFocus")._k !== fk) ($("crewFocus")._k = fk), ($("crewFocus").innerHTML = s.crew.map((c) => `<button data-crew="${c.id}">${esc(c.name)} · ${esc(this.t.roles[c.role] || c.role)}</button>`).join(""));
    if (this.crewId) this.showCrew(this.crewId);
    this.renderDecision(s);
    if (this.tab) this.renderSheet(s);
  }
  renderSheet(s) {
    const t = this.t, tab = this.tab;
    $("sheetTitle").textContent = t[tab];
    $("sheetSub").textContent = t[tab + "Sub"];
    const body = $("sheetBody");
    body.className = "sb-" + tab;
    let html = "";
    if (tab === "board") html = this.boardHtml(s);
    if (tab === "roster") html = this.rosterHtml(s);
    if (tab === "chart") html = this.chartHtml(s);
    if (tab === "settings") html = this.settingsHtml(s);
    if (body._h !== html) (body.innerHTML = html), (body._h = html);
  }
  boardHtml(s) {
    const t = this.t, held = new Set(s.kraken.arms);
    return `<div id="lanes">` + LANE_IDS.map((lane, li) => {
      let cards = s.tasks.filter((x) => x.lane === lane);
      const n = cards.length;
      if (lane === "merged") cards = cards.slice(-6).reverse();
      return `<div class="lane" data-lane="${lane}"><h3>${esc(t.lanes[li])}<b>${n}</b></h3>` + cards.map((x, j) => {
        const red = s.gate[x.id] === "red", w = x.worker && s.crew.find((c) => c.id === x.worker);
        const tags = [x.milestone, x.issue ? t.issue : t.chat, x.round ? `R${x.round}` : "", red ? t.gateRed : "", held.has(x.id) ? t.kraken : "", x.approved && lane === "review" ? t.approved : "", x.course ? "⚑" + x.course : "", w ? w.name : ""].filter(Boolean);
        const acts = (BOARD_ACTIONS[lane] || []).map((k) => [k, t[k]]);
        return `<div class="card${red ? " red" : ""}${held.has(x.id) ? " held" : ""}${lane === "merged" ? " done" : ""}" style="--r:${j % 2 ? 0.8 : -1}deg"><b>${esc(x.id)}</b>${esc(x.title)}<div class="tags">${tags.map((g) => `<i>${esc(g)}</i>`).join("")}</div>${acts.length ? `<div class="acts">${acts.map(([k, l]) => `<button data-card="${k}" data-id="${x.id}">${esc(l)}</button>`).join("")}</div>` : ""}</div>`;
      }).join("") + `</div>`;
    }).join("") + `</div>`;
  }
  // every field of a crewman, labelled, in the current language
  crewFields(c, s) {
    const t = this.t, pj = projectOf(c, s), task = pj?.task;
    const pr = !task ? t.none : task.lane === "merged" ? t.prMerged : task.lane === "review" ? (task.approved ? t.prApproved : t.prOpen) : t.none;
    return [
      ["name", c.name], ["role", t.roles[c.role] || c.role], ["project", pj ? `${pj.id} · ${pj.name}` : t.none, pj?.col], ["task", task ? `${task.id} · ${task.title}` : t.none],
      ["round", task?.round ? String(task.round) : t.none], ["pr", pr], ["state", t.st[c.state] || c.state], ["activity", (c.action && (t.act[c.action] || c.action)) || t.none],
      ["rank", this.rank(c)], ["vendor", c.vendor || t.none],
    ];
  }
  // the detail card, anchored to the crewman (one at a time; Esc or a second tap closes it)
  showCrew(id, at) {
    const s = this.s, c = s?.crew.find((x) => x.id === id), el = $("crewCard");
    if (!c) return this.hideCrew();
    this.crewId = id;
    const html = `<div class="cc-h"><span class="flag" style="--pc:${projectOf(c, s)?.col || "#bbb"}"></span><b>${esc(c.name)}</b><button data-crewclose aria-label="${esc(this.t.close)}">✕</button></div><dl>` +
      this.crewFields(c, s).slice(1).map(([k, v, col]) => `<dt>${esc(this.t.f[k])}</dt><dd>${col ? `<i style="--pc:${col}"></i>` : ""}${esc(v)}</dd>`).join("") + `</dl>`;
    if (el._h !== html + this.lang) (el.innerHTML = html), (el._h = html + this.lang);
    el.hidden = false;
    el.dataset.crew = id;
    if (at) this.placeCrew(at);
  }
  placeCrew([x, y]) {
    const el = $("crewCard"), w = el.offsetWidth, h = el.offsetHeight;
    const left = Math.max(8, Math.min(innerWidth - w - 8, x - w / 2)), top = y - h - 18 < 60 ? Math.min(innerHeight - h - 8, y + 40) : y - h - 18;
    el.style.transform = `translate(${Math.round(left)}px, ${Math.round(top)}px)`;
  }
  hideCrew() { this.crewId = null; $("crewCard").hidden = true; }
  // the roster keeps every field as its own column, grouped by role and state (readable at 24)
  rosterHtml(s) {
    const t = this.t, keys = ["name", "role", "project", "task", "round", "pr", "state", "activity", "rank", "vendor"];
    const row = (c) => `<tr class="st-${c.state}">` + this.crewFields(c, s).map(([k, v, col], i) => `<td class="c-${k}">${i === 0 ? '<span class="dot"></span>' : ""}${col ? `<i style="--pc:${col}"></i>` : ""}${esc(v)}</td>`).join("") + `</tr>`;
    const order = ["working", "walking", "waiting", "blocked", "down", "standby", "idle"];
    const groups = [[t.command, s.crew.filter((c) => c.role === "captain" || c.role === "firstmate")], [t.review, s.crew.filter((c) => c.role === "reviewer")]];
    const wk = s.crew.filter((c) => c.role === "worker");
    for (const st of [...new Set(wk.map((c) => c.state))].sort((a, b) => order.indexOf(a) - order.indexOf(b))) groups.push([`${t.workers} · ${t.st[st] || st}`, wk.filter((c) => c.state === st)]);
    return `<div class="roster"><table><thead><tr>${keys.map((k) => `<th>${esc(t.f[k])}</th>`).join("")}</tr></thead>` +
      groups.filter(([, l]) => l.length).map(([g, l]) => `<tbody><tr class="grp"><th colspan="${keys.length}">${esc(g)} <b>${l.length}</b></th></tr>${l.map(row).join("")}</tbody>`).join("") + `</table></div>`;
  }
  chartHtml(s) {
    const t = this.t, ports = CONFIG.ports.slice(0, s.milestones.length + 1);
    const merged = (m) => m.tasks.filter((id) => s.tasks.find((x) => x.id === id)?.lane === "merged").length;
    const W = 900, y = 70, x0 = W - 60, x1 = 120, px = (i) => x0 - ((x0 - x1) * i) / Math.max(1, ports.length - 1);
    const cur = Math.min(s.port, s.milestones.length - 1), m = s.milestones[cur];
    const frac = s.port >= s.milestones.length ? 0 : m.tasks.length ? merged(m) / m.tasks.length : 0;
    const shipX = s.port >= s.milestones.length ? px(ports.length - 1) : px(s.port) + (px(s.port + 1) - px(s.port)) * frac;
    let o = `<svg viewBox="0 0 ${W} 150" class="chartsvg" role="img" aria-label="${esc(t.chart)}"><rect width="100" height="150" fill="#d8d2c4"/><text x="10" y="140" font-size="16">${esc(t.fog)}</text>`;
    o += `<path d="M ${x0} ${y} L ${x1} ${y}" stroke="#0c0608" stroke-width="3" stroke-dasharray="10 8"/><path d="M ${x0} ${y} L ${shipX} ${y}" stroke="#e60012" stroke-width="8"/>`;
    ports.forEach((p, i) => {
      const name = i === 0 ? CONFIG.home : p.name, mm = s.milestones[i - 1];
      o += `<g><rect x="${px(i) - 10}" y="${y - 10}" width="20" height="20" transform="rotate(45 ${px(i)} ${y})" fill="${i <= s.port ? "#e60012" : "#fff"}" stroke="#0c0608" stroke-width="4"/><text x="${px(i)}" y="${y - 22}" text-anchor="middle" font-size="18" font-weight="900">${esc(name)}</text>${mm ? `<text x="${px(i)}" y="${y + 38}" text-anchor="middle" font-size="14">${merged(mm)}/${mm.tasks.length} ${esc(t.ofMerged)}</text>` : ""}</g>`;
    });
    o += `<g transform="translate(${shipX} ${y - 4})"><path d="M -18 4 L 16 4 L 10 14 L -13 14 Z" fill="#0c0608"/><path d="M -2 4 L -2 -24 L 14 -4 Z" fill="#fff" stroke="#0c0608" stroke-width="2"/></g></svg>`;
    return o;
  }
  settingsHtml(s) {
    const t = this.t, f = (id) => this.flags[id] || {};
    const row = (label, inner) => `<div class="set"><span>${esc(label)}</span><div>${inner}</div></div>`;
    const tog = (k, on, v = "") => `<button data-set="${k}" data-v="${v}" aria-pressed="${!!on}">${on ? t.on : t.off}</button>`;
    const info = this.h.shipInfo?.() || {};
    const rit = Object.keys(t.rit).map((r) => `<button data-set="ritual" data-v="${r}" aria-pressed="${f("r-" + r).on ?? true}">${esc(t.rit[r])}</button>`).join("");
    return `<div class="settings">` +
      row(t.language, LANGS.map((l, i) => `<button data-set="lang" data-v="${l}" aria-pressed="${this.lang === l}">${["EN", "繁體", "简体"][i]}</button>`).join("")) +
      row(t.hands, this.handsHtml(s.crew.length) + `<small>${esc(this.pick3([info.en, info.tw, info.cn]))}</small>`) +
      row(t.sound, tog("sound", f("c-sound").on)) +
      row(t.freecam, tog("camera", f("b-cam").on)) +
      row(t.speed, `<button data-set="speed">${esc(f("c-speed").label || "1×")}</button>`) +
      row(t.detail, `<button data-set="detail">${esc(f("c-detail").label || "")}</button>`) +
      row(t.style, `<button data-set="style">${esc(t.styles[f("style").label] || t.styles.p5)}</button>`) +
      row(t.rituals, `<span class="rits">${rit}</span>`) + (this.h.settingsExtra?.(row, esc) || "") + `</div>`;
  }
  // hands aboard: in Playground the captain sets the crew size (the ship's class follows it);
  // in Live the board's crew list sets it, so there the count is only shown
  handsHtml(n) {
    const r = this.h.mode?.() === "playground" && this.h.hands && this.h.handsRange?.();
    if (!r) return `<b class="big" data-hands>${n}</b>`;
    const [lo, hi] = r, t = this.t;
    return `<span class="hands"><button data-set="hands" data-v="-1" aria-label="${esc(t.hands)} −"${n <= lo ? " disabled" : ""}>−</button>` +
      `<b class="big" data-hands>${n}</b>` +
      `<button data-set="hands" data-v="1" aria-label="${esc(t.hands)} +"${n >= hi ? " disabled" : ""}>+</button></span>`;
  }
  // ---------------------------------------------------------------- the decision card
  // ---------------------------------------------------------------- the decision card
  // Dealt from the deck with a flip, the options fanned like a hand; hover lifts and lights an
  // option, the pick pulls it forward, confirming stamps a wax seal and the card flies off,
  // Later tucks it back into the deck. Each move is under 500 ms; reduced motion skips them.
  // The card carries its infographic: in Live the board's own diagram for the decision
  // (this.diagrams, see docs/interface.md), in Playground a before/after drawn from its options.
  // Either follows the option under the pointer, the focus or the pick.
  get still() { try { return matchMedia("(prefers-reduced-motion: reduce)").matches; } catch { return false; } }
  renderDecision(s) {
    const d = s.decisions[0];
    document.body.classList.toggle("decision", !!d && !this.minimised);
    const deck = $("deckIcon");
    if (deck) (deck.hidden = !(d && this.minimised)), (deck.querySelector("b").textContent = s.decisions.length), deck.setAttribute("aria-label", this.t.deck);
    if (!d) {
      this.decisionShown = null;
      this.minimised = false;
      return;
    }
    if (this.minimised || this.decisionShown === d.id) return;
    this.decisionShown = d.id;
    this.pick = null;
    const L = LANGS.indexOf(this.lang), t = this.t;
    const [tt, bb] = (DECK[d.kind] || DECK.choice)(d);
    const title = L ? tt[L] : d.title, body = L ? bb[L] : d.body;
    const n = d.options.length;
    const opt = (o, i) => {
      const tr = L && OPTS[o.effect]?.[L - 1];
      const [label, pro, con] = tr || [o.label, o.pro, o.con];
      return `<button class="opt${i === 0 ? " rec" : ""}" data-key="${o.key}" aria-pressed="false" style="--i:${i};--fan:${((i - (n - 1) / 2) * 1.4).toFixed(2)}deg"><span class="k">${o.key}</span><span class="ot">${esc(label)}${i === 0 ? `<em>${esc(t.recommended)}</em>` : ""}<small>+ ${esc(pro)}${con && con !== "—" ? `  · − ${esc(con)}` : ""}</small></span></button>`;
    };
    const figure = this.diagrams ? `<figure class="dgm live" data-hl=""><iframe class="dg" title="${esc(d.id)}" hidden></iframe></figure>` : `<figure class="dgm sim" data-hl="${d.options[0].key}">${this.infographic(d, s)}</figure>`;
    $("decision").innerHTML = `<div class="dcard k-${d.kind}${this.still ? " still" : ""}" role="dialog" aria-label="${esc(title)}"><span class="kicker">${esc(t.decision)} · ${esc(d.id)}</span><h2>${esc(title)}</h2><p>${esc(body)}</p>${figure}<div class="opts">${d.options.map(opt).join("")}</div><div class="dfoot"><button data-later="1">${esc(t.later)}</button><small>${esc(t.keys)}</small></div></div>`;
    if (this.diagrams) this.mountDiagram(d.id);
  }
  // Live: the board's diagram file for this decision, shown only once a HEAD says it is there;
  // zh-CN reads zh-CN when the board has it, else zh-TW
  async mountDiagram(id) {
    const fig = document.querySelector("#decision .dgm.live"), frame = fig?.querySelector("iframe");
    if (!frame) return;
    const P = this.diagrams, tries = this.lang === "zh-CN" ? ["zh-CN", "zh-TW"] : [this.lang];
    for (const lang of tries) {
      const url = P.src(id, lang);
      let there = false;
      try { there = !!url && (await P.exists(url)); } catch { there = false; }
      if (this.decisionShown !== id || !frame.isConnected) return;
      if (!there) continue;
      frame.addEventListener("load", () => this.highlight(fig.dataset.hl), { once: true });
      frame.src = url;
      frame.hidden = false;
      fig.classList.add("shown");
      return;
    }
    fig.remove(); // no diagram for this decision: no image, never the server's 404 page
  }
  // light the option's before/after: our own drawing, or the board's diagram (its
  // [data-option] parts, else its answers list in A, B, C order)
  highlight(key) {
    const fig = document.querySelector("#decision .dgm");
    if (!fig) return;
    fig.dataset.hl = key || "";
    const doc = fig.querySelector("iframe")?.contentDocument;
    if (!doc?.body) return;
    if (!doc.getElementById("v2d-hl")) doc.head?.insertAdjacentHTML("beforeend", `<style id="v2d-hl">.v2d-pick{outline:3px solid #e60012;outline-offset:2px;background:rgba(230,0,18,.18)!important}</style>`);
    const parts = [...doc.querySelectorAll("[data-option]")];
    const list = parts.length ? parts : [...doc.querySelectorAll(".answers li")];
    list.forEach((el, i) => el.classList.toggle("v2d-pick", !!key && (el.dataset.option ? el.dataset.option === key : i === "ABCD".indexOf(key))));
  }
  // Playground: before and after, drawn from the sim decision's options
  infographic(d, s) {
    const t = this.t, L = LANGS.indexOf(this.lang);
    const task = s.tasks.find((x) => x.id === d.task);
    const laneName = (lane) => ({ issues: t.lanes[0], backlog: t.lanes[1], ready: t.lanes[2], working: t.lanes[3], review: t.lanes[4], merged: t.lanes[5], parked: t.parkedL, dropped: t.droppedL, fight: t.fightL, port: t.portL })[lane] || lane;
    const AFTER = { proceed: ["working", 0], rescope: ["working", -1], park: ["parked", 0], merge: ["merged", 0], sendback: ["review", 1], hold: ["port", 0], battle: ["fight", 0], drop: ["dropped", 0], spec: ["ready", 0], skip: ["issues", 0] };
    const now = task ? task.lane : "ready", round = task?.round || 0;
    const chip = (x, y, w, text, cls) => `<g class="${cls}"><rect x="${x}" y="${y}" width="${w}" height="26" rx="2"/><text x="${x + w / 2}" y="${y + 18}" text-anchor="middle">${esc(text)}</text></g>`;
    const dots = (x, y, n, extra) => Array.from({ length: Math.max(0, n) + Math.max(0, extra) }, (_, i) => `<circle class="${i < n ? "rd" : "rd new"}" cx="${x + i * 12}" cy="${y}" r="4"/>`).join("");
    const afters = d.options.map((o) => {
      const [lane, dr] = AFTER[o.effect] || ["ready", 0];
      const label = (L && OPTS[o.effect]?.[L - 1]?.[0]) || o.label;
      return `<g class="after" data-opt="${o.key}">${chip(186, 22, 106, laneName(lane), "lane to " + lane)}${dots(192, 62, Math.max(0, round + Math.min(0, dr)), Math.max(0, dr))}<text class="lab" x="239" y="88" text-anchor="middle">${esc(o.key)} · ${esc(label.length > 18 ? label.slice(0, 17) + "…" : label)}</text></g>`;
    }).join("");
    const keys = d.options.map((o, i) => `<g class="key" data-opt="${o.key}"><rect x="${120 + i * 22 - (d.options.length - 1) * 11}" y="80" width="18" height="18"/><text x="${129 + i * 22 - (d.options.length - 1) * 11}" y="93" text-anchor="middle">${o.key}</text></g>`).join("");
    return `<svg viewBox="0 0 300 104" role="img" aria-label="${esc(t.now)} → ${esc(t.ifPick)}"><text class="hd" x="8" y="14">${esc(t.now)}</text><text class="hd" x="186" y="14">${esc(t.ifPick)} …</text>` +
      chip(8, 22, 106, laneName(now), "lane now") + dots(14, 62, round, 0) + `<text class="lab" x="61" y="88" text-anchor="middle">${esc(d.task || "")}</text>` +
      `<path class="arrow" d="M122 35 L172 35 M162 27 L174 35 L162 43"/>${keys}${afters}</svg>`;
  }
  choose(key) {
    if (!this.decisionShown) return;
    this.pick = key;
    for (const b of document.querySelectorAll("#decision .opt")) b.setAttribute("aria-pressed", b.dataset.key === key);
    this.highlight(key);
  }
  // the wax seal, then the card flies off; the answer lands when it has gone
  confirm() {
    if (!this.decisionShown || !this.pick) return;
    const card = document.querySelector("#decision .dcard");
    const id = this.decisionShown, key = this.pick;
    this.pick = null;
    if (card && !this.still) {
      card.insertAdjacentHTML("beforeend", `<span class="seal" aria-hidden="true">${esc(key)}</span>`);
      card.classList.add("sealed");
    }
    setTimeout(() => this.h.answer(id, key), this.still ? 0 : 420);
  }
  // Later: the card tucks back into the deck (the deck icon, bottom right, deals it again)
  minimise() {
    if (this.tab) return this.toggle(null);
    const card = document.querySelector("#decision .dcard");
    const fold = () => {
      this.minimised = !this.minimised;
      this.decisionShown = null;
      if (this.s) this.render(this.s);
    };
    if (!this.minimised && card && !this.still) return void (card.classList.add("tucked"), setTimeout(fold, 300));
    fold();
  }
}
