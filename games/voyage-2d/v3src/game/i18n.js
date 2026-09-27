// Three languages for the board and the menus (p6): English, 繁體中文, 简体中文.
//
// The interface is written in English; a watcher translates every text node and the
// title / aria-label attributes under the HUD as they are written, from a phrase table
// (exact phrases) and a pattern table (the sim's log lines, which carry task ids,
// names and numbers). Names (task ids, crew names, ports kept as proper nouns, vendor
// lines) pass through. The Japanese kanji line of a cut-in and the lettered SFX are
// never touched. The choice is remembered in localStorage (inside try/catch).
export const LANGS = [
  ["en", "EN"],
  ["tw", "繁中"],
  ["cn", "简中"],
];
let LANG = "en";
try {
  const v = localStorage.getItem("fmv-lang");
  if (v === "tw" || v === "cn") LANG = v;
} catch {}
export const lang = () => LANG;

// [English, 繁體, 简体]
const P = [
  // the board
  ["Issues", "議題", "议题"], ["Backlog", "待辦", "待办"], ["Ready", "就緒", "就绪"], ["Working", "進行中", "进行中"], ["Review", "審查", "审查"], ["Merged", "已合併", "已合并"],
  ["merged", "已合併", "已合并"], ["in flight", "航行中", "航行中"], ["waiting on you", "等你決定", "等你决定"], ["blocked", "受阻", "受阻"], ["ready", "就緒", "就绪"], ["backlog", "待辦", "待办"],
  ["New task", "新任務", "新任务"], ["Dispatch", "派工", "派工"], ["Open PR", "開 PR", "开 PR"], ["Merge", "合併", "合并"], ["Approve", "核准", "核准"], ["Reject", "退回", "退回"], ["Red check", "檢查變紅", "检查变红"], ["Green", "轉綠", "转绿"],
  ["Set course", "定航向", "定航向"], ["Survey", "勘測", "勘测"], ["Park", "擱置", "搁置"], ["Drop", "放棄", "放弃"], ["Face the kraken", "迎戰海怪", "迎战海怪"],
  ["issue", "議題", "议题"], ["chat", "對話", "对话"], ["gate red", "閘門紅燈", "闸门红灯"], ["kraken", "海怪", "海怪"], ["approved", "已核准", "已核准"],
  ["Board", "看板", "看板"], ["Roster", "名冊", "名册"], ["Customs", "船規", "船规"], ["Sound", "音效", "音效"], ["Orbit", "環繞", "环绕"], ["Auto-play", "自動航行", "自动航行"],
  ["The fleet", "艦隊", "舰队"], ["Crew roster · one fleet", "船員名冊 · 一支艦隊", "船员名册 · 一支舰队"], ["Ship's customs", "船上規矩", "船上规矩"], ["a frigate of three masts", "三桅巡防艦", "三桅巡防舰"],
  ["Hoisting the sails…", "升帆中…", "升帆中…"], ["Mustering the crew…", "集合船員…", "集合船员…"], ["uncharted issues", "未勘測的議題", "未勘测的议题"],
  ["Record", "履歷", "履历"], ["Top rank", "最高階級", "最高阶级"], ["Later", "稍後", "稍后"], ["Confirm", "確認", "确认"], ["Open", "打開", "打开"],
  ["Collapse the board (B)", "收起看板 (B)", "收起看板 (B)"], ["Expand the board (B)", "展開看板 (B)", "展开看板 (B)"],
  ["Merge", "合併", "合并"], ["Choice", "抉擇", "抉择"], ["Scope", "範圍", "范围"], ["The kraken", "海怪", "海怪"],
  // customs
  ["The order: bell, whistle, the helm spins twice", "下令：鐘響、哨音、舵輪轉兩圈", "下令：钟响、哨音、舵轮转两圈"],
  ["The merge salvo", "合併齊射", "合并齐射"], ["Making port", "入港", "入港"], ["A salute on a first-round approval", "一輪就過時敬禮", "一轮就过时敬礼"],
  ["Clearing and a cheer", "放晴與歡呼", "放晴与欢呼"], ["Weather, not blame", "是天氣，不是責備", "是天气，不是责备"],
  ["Sound effects (synthesised; off by default)", "音效（合成；預設關閉）", "音效（合成；默认关闭）"], ["Cinematic camera (off = free orbit)", "電影鏡頭（關 = 自由環繞）", "电影镜头（关 = 自由环绕）"],
  ["Auto-play a seeded voyage", "自動播放一段航程", "自动播放一段航程"], ["Speed", "速度", "速度"], ["Detail", "畫質", "画质"], ["On", "開", "开"], ["Off", "關", "关"], ["high", "高", "高"], ["low", "低", "低"], ["Language", "語言", "语言"],
  // keys
  ["a new task arrives", "來了新任務", "来了新任务"], ["the captain's order: dispatch", "船長下令：派工", "船长下令：派工"], ["a pull request opens", "開出 PR", "开出 PR"], ["merge (the salvo)", "合併（齊射）", "合并（齐射）"],
  ["the review approves / rejects", "審查核准 / 退回", "审查核准 / 退回"], ["the worker pushes", "船員推送", "船员推送"], ["a red check / turns green", "檢查變紅 / 轉綠", "检查变红 / 转绿"], ["answer the card", "回答決策卡", "回答决策卡"],
  ["battle skills", "戰鬥技能", "战斗技能"], ["full sail (dodge)", "滿帆（閃避）", "满帆（闪避）"], ["counter", "反擊", "反击"], ["choose an arm", "選觸手", "选触手"], ["board / roster / customs", "看板 / 名冊 / 船規", "看板 / 名册 / 船规"],
  ["sound / orbit / auto-play", "音效 / 環繞 / 自動航行", "音效 / 环绕 / 自动航行"], ["special-move style: manga / red-black", "必殺技風格：漫畫 / 紅黑", "必杀技风格：漫画 / 红黑"], ["hide the interface", "隱藏介面", "隐藏界面"], ["language", "語言", "语言"],
  // battle
  ["Broadside", "舷側砲", "舷侧炮"], ["Chain-shot", "鎖鏈彈", "锁链弹"], ["Harpoon", "魚叉", "鱼叉"], ["Full sail", "滿帆", "满帆"], ["Captain's order", "船長命令", "船长命令"], ["Repair", "修補", "修补"],
  ["Play along", "一起玩", "一起玩"], ["Stop playing", "停止", "停止"], ["Slam", "重擊", "重击"], ["Jab", "突刺", "突刺"], ["Two-hit combo", "二連擊", "二连击"], ["Slam?", "重擊？", "重击？"],
  ["A feint: hold, and wait for the real strike", "假動作：按住，等真正的一擊", "假动作：按住，等真正的一击"], ["Perfect! Counter on the weak point", "完美！打弱點", "完美！打弱点"],
  ["Dodged. Counter now: tap the head or Enter", "閃過了。現在反擊：點頭部或 Enter", "闪过了。现在反击：点头部或 Enter"], ["Too early: the sail reloads", "太早了：帆要重新裝填", "太早了：帆要重新装填"],
  ["Full sail in the brass: Space, 4, or tap this bar", "在黃銅區滿帆：空白鍵、4 或點這條", "在黄铜区满帆：空格键、4 或点这条"],
  ["Perfect dodge", "完美閃避", "完美闪避"], ["Dodged. Counter!", "閃過！反擊！", "闪过！反击！"], ["Too early", "太早", "太早"], ["The kraken reels", "海怪踉蹌", "海怪踉跄"], ["Good broadside", "漂亮的舷側砲", "漂亮的舷侧炮"], ["Glancing", "擦過", "擦过"],
  ["No splintered rail to repair", "沒有要修的欄杆", "没有要修的栏杆"], ["READ IT! FINISHER: HIT THE EYE", "看穿了！必殺：打眼睛", "看穿了！必杀：打眼睛"], ["ABYSS SLAM! FULL SAIL ON THE BRASS!", "深淵叩擊！在黃銅區滿帆！", "深渊叩击！在黄铜区满帆！"],
  // cut-in lines (the kanji line above them stays)
  ["CAPTAIN'S ORDER", "船長命令", "船长命令"], ["PERFECT BROADSIDE", "完美舷側齊射", "完美舷侧齐射"], ["FULL-DRAW HARPOON", "滿弓魚叉", "满弓鱼叉"], ["CHAIN-SHOT", "鎖鏈彈", "锁链弹"], ["WEAK POINT!", "弱點！", "弱点！"],
  ["FINISHER: MERGE STRIKE", "必殺：合流斬", "必杀：合流斩"], ["ABYSS SLAM", "深淵叩擊", "深渊叩击"], ["THE CAPTAIN", "船長", "船长"], ["THE KRAKEN", "海怪", "海怪"],
  ["Every gun, fire as she bears!", "所有砲，對準就開火！", "所有炮，对准就开火！"], ["Brass on the mark", "黃銅正中", "黄铜正中"], ["Everything on one line", "全押在一條線上", "全押在一条线上"], ["Bind the arms", "綁住觸手", "绑住触手"],
  ["Counter on the eye", "反擊眼睛", "反击眼睛"], ["Approved. All hands!", "核准了。全員！", "核准了。全员！"], ["The kraken rises. Read it!", "海怪升起。看穿它！", "海怪升起。看穿它！"],
  // banners, captions, the title card
  ["Aye, captain.", "是，船長。", "是，船长。"], ["Aye, captain. Orders away", "是，船長。命令已下", "是，船长。命令已下"], ["A salute: approved on the first round", "敬禮：一輪就核准", "敬礼：一轮就核准"],
  ["Clearing, and a cheer", "放晴，歡呼", "放晴，欢呼"], ["Merged into main", "已合併進 main", "已合并进 main"], ["Ahoy! Merged into main", "啊嘿！已合併進 main", "啊嘿！已合并进 main"],
  ["Welcome aboard, captain. Press O to give the order, or Auto-play to watch a voyage.", "歡迎登船，船長。按 O 下令，或按自動航行看一段航程。", "欢迎登船，船长。按 O 下令，或按自动航行看一段航程。"],
  ["Nothing is ready to dispatch.", "沒有可派工的任務。", "没有可派工的任务。"], ["Every hand is busy; the order waits for a free worker.", "人手都在忙；命令等空出來的船員。", "人手都在忙；命令等空出来的船员。"],
  ["No working task can open a pull request right now.", "目前沒有任務能開 PR。", "目前没有任务能开 PR。"], ["Nothing approved is waiting to merge.", "沒有已核准的等著合併。", "没有已核准的等着合并。"],
  ["No task in flight for that verdict.", "沒有進行中的任務可判。", "没有进行中的任务可判。"], ["No red check to turn green.", "沒有紅燈要轉綠。", "没有红灯要转绿。"],
  ["VICTORY!", "勝利！", "胜利！"], ["LAND HO!", "看到陸地了！", "看到陆地了！"], ["The kraken lets go", "海怪鬆手了", "海怪松手了"], ["CLICK TO SAIL ON", "點一下繼續航行", "点一下继续航行"],
  ["Only an approval wins, and it came", "只有核准能贏，而它來了", "只有核准能赢，而它来了"],
  // pennants
  ["Captain", "船長", "船长"], ["Firstmate", "大副", "大副"], ["on the bow", "在船首", "在船首"], ["at the helm", "掌舵", "掌舵"],
  ["working", "工作中", "工作中"], ["to station", "前往崗位", "前往岗位"], ["in review", "審查中", "审查中"], ["down", "倒下", "倒下"], ["idle", "待命", "待命"], ["standby", "待命", "待命"], ["walking", "走動", "走动"], ["waiting", "等待", "等待"],
  // ranks
  ["deckhand", "水手", "水手"], ["able seaman", "一等水手", "一等水手"], ["bosun's mate", "副水手長", "副水手长"], ["bosun", "水手長", "水手长"], ["quartermaster", "舵手長", "舵手长"],
  ["apprentice inspector", "見習審查員", "见习审查员"], ["inspector", "審查員", "审查员"], ["chief inspector", "首席審查員", "首席审查员"],
  // decision options
  ["As specced", "照規格", "照规格"], ["Rescope smaller", "縮小範圍", "缩小范围"], ["Park it", "先擱置", "先搁置"], ["Keeps the plan", "照計畫走", "照计划走"], ["The larger change", "改動較大", "改动较大"],
  ["One review round fewer", "少一輪審查", "少一轮审查"], ["Leaves a follow-up", "留下後續", "留下后续"], ["Frees the worker", "釋出船員", "释出船员"], ["The task waits", "任務等待", "任务等待"],
  ["Send back", "退回再看", "退回再看"], ["Hold", "暫緩", "暂缓"], ["Makes way on the voyage", "航程前進", "航程前进"], ["Another look", "再看一次", "再看一次"], ["One more round", "多一輪", "多一轮"],
  ["Waits for the next port", "等下一個港", "等下一个港"], ["The task idles", "任務閒置", "任务闲置"], ["Proceed: fight", "繼續：迎戰", "继续：迎战"], ["The battle begins; play along", "戰鬥開始；一起玩", "战斗开始；一起玩"],
  ["Only an approval wins", "只有核准能贏", "只有核准能赢"], ["Rescope", "縮小範圍", "缩小范围"], ["It needs one round less", "少一輪就好", "少一轮就好"], ["The kraken waits far off", "海怪在遠處等", "海怪在远处等"],
  ["The arm lets go", "觸手鬆開", "触手松开"], ["The task waits in parked", "任務在擱置區等", "任务在搁置区等"], ["The kraken goes down whole", "海怪整隻沉下", "海怪整只沉下"], ["The work is dropped", "工作放棄", "工作放弃"],
  ["Approve the spec", "核准規格", "核准规格"], ["The island clears the fog", "島嶼撥開迷霧", "岛屿拨开迷雾"], ["Skip", "略過", "略过"], ["Hides the issue", "藏起議題", "藏起议题"], ["Stays in the fog", "留在霧裡", "留在雾里"],
  // task titles
  ["Board: ranks and service records", "看板：階級與服役紀錄", "看板：阶级与服役记录"], ["Chart band: islands for ready tasks", "海圖帶：就緒任務的島", "海图带：就绪任务的岛"], ["Kraken: one arm per held task", "海怪：每個卡住的任務一條觸手", "海怪：每个卡住的任务一条触手"],
  ["Order ritual: bell and whistle", "下令儀式：鐘與哨", "下令仪式：钟与哨"], ["Merge salvo with the bell", "合併齊射與鐘聲", "合并齐射与钟声"], ["Weather, not blame, on a red gate", "紅燈是天氣，不是責備", "红灯是天气，不是责备"],
  ["Decision cards as strategy cards", "決策卡當策略卡", "决策卡当策略卡"], ["Crew roster with vendor lines", "附供應商的船員名冊", "附供应商的船员名册"], ["Voyage chart: making port", "航海圖：入港", "航海图：入港"],
  ["Reviewer's pass criteria list", "審查員的通過條件", "审查员的通过条件"], ["Firstmate hand-off scroll", "大副交接卷軸", "大副交接卷轴"], ["Deck stations and pooled actions", "甲板崗位與共用動作", "甲板岗位与共用动作"],
  ["Squall band over the scene", "場景上的暴風帶", "场景上的暴风带"], ["Tally roll-over counters", "翻動的計數器", "翻动的计数器"], ["Pennants with rank braid", "帶階級飾帶的旗", "带阶级饰带的旗"],
  ["Harpoon and chain-shot skills", "魚叉與鎖鏈彈技能", "鱼叉与锁链弹技能"], ["Captain's porthole portrait", "船長舷窗肖像", "船长舷窗肖像"], ["Chart: tidewater's own voyage", "海圖：tidewater 自己的航程", "海图：tidewater 自己的航程"],
  ["Sound: ambient sea level", "音效：環境海浪音量", "音效：环境海浪音量"],
];
const DICT = new Map(P.map(([e, t, c]) => [e, { tw: t, cn: c }]));
// patterns: [regex on the whole phrase, { tw, cn } templates with $1..]
const PAT = [
  [/^(\S+) merged into main\. Ahoy!$/, "$1 已合併進 main。啊嘿！", "$1 已合并进 main。啊嘿！"],
  [/^(\S+) is ready \(its last dependency merged\)$/, "$1 就緒（最後一個依賴已合併）", "$1 就绪（最后一个依赖已合并）"],
  [/^Order: (\S+) to (\S+)\. Aye, captain\. Orders away\.$/, "命令：$1 交給 $2。是，船長。命令已下。", "命令：$1 交给 $2。是，船长。命令已下。"],
  [/^(\S+): (\S+) pushed commit (\d+)$/, "$1：$2 推送了第 $3 個 commit", "$1：$2 推送了第 $3 个 commit"],
  [/^(\S+): (\S+) pushed a fix$/, "$1：$2 推送了修正", "$1：$2 推送了修正"],
  [/^(\S+): pull request opened by (\S+)$/, "$1：$2 開了 PR", "$1：$2 开了 PR"],
  [/^(\S+): pull request updated by (\S+)$/, "$1：$2 更新了 PR", "$1：$2 更新了 PR"],
  [/^(\S+): approved on round (\d+) \(a salute\)$/, "$1：第 $2 輪核准（敬禮）", "$1：第 $2 轮核准（敬礼）"],
  [/^(\S+): approved on round (\d+)$/, "$1：第 $2 輪核准", "$1：第 $2 轮核准"],
  [/^(\S+): round (\d+) rejected; back to the station$/, "$1：第 $2 輪退回；回崗位", "$1：第 $2 轮退回；回岗位"],
  [/^(\S+): the gate is red \(weather, not blame\)$/, "$1：閘門紅燈（是天氣，不是責備）", "$1：闸门红灯（是天气，不是责备）"],
  [/^(\S+): the check turned green$/, "$1：檢查轉綠", "$1：检查转绿"],
  [/^(\S+): (\S+) asked for the pass criteria$/, "$1：$2 問了通過條件", "$1：$2 问了通过条件"],
  [/^(\S+): the reviewer returned the pass criteria$/, "$1：審查員回了通過條件", "$1：审查员回了通过条件"],
  [/^(\S+) raised: (.+)$/, "$1 提出：$2", "$1 提出：$2"],
  [/^(\S+): the captain chose (\S) \((.+)\)$/, "$1：船長選了 $2（$3）", "$1：船长选了 $2（$3）"],
  [/^How should (\S+) land\?$/, "$1 要怎麼落地？", "$1 要怎么落地？"],
  [/^Merge (\S+)\?$/, "合併 $1？", "合并 $1？"],
  [/^(\S+) complete: the ship makes port at (.+)$/, "$1 完成：船駛入 $2", "$1 完成：船驶入 $2"],
  [/^Making port: (.+)$/, "入港：$1", "入港：$1"],
  [/^Made port: (.+)$/, "已入港：$1", "已入港：$1"],
  [/^(\S+) rated (.+)$/, "$1 晉升為 $2", "$1 晋升为 $2"],
  [/^The kraken holds (\S+) \(round (\d+)\)$/, "海怪抓住 $1（第 $2 輪）", "海怪抓住 $1（第 $2 轮）"],
  [/^The kraken holds (\S+)$/, "海怪抓住 $1", "海怪抓住 $1"],
  [/^The battle for (\S+) begins$/, "$1 之戰開始", "$1 之战开始"],
  [/^The kraken strikes the deck: (\S+) rejected again$/, "海怪重擊甲板：$1 又被退回", "海怪重击甲板：$1 又被退回"],
  [/^Victory: (\S+) approved, the kraken lets go$/, "勝利：$1 核准，海怪鬆手", "胜利：$1 核准，海怪松手"],
  [/^The kraken lets go of (\S+)$/, "海怪放開 $1", "海怪放开 $1"],
  [/^(\S+) joined the plan: (.+)$/, "$1 加入計畫：$2", "$1 加入计划：$2"],
  [/^(\S+) sent back for another look$/, "$1 退回再看", "$1 退回再看"],
  [/^Aye, captain: (\S+) proceeds$/, "是，船長：$1 繼續", "是，船长：$1 继续"],
  [/^(\S+) held; press M to merge it later\.$/, "$1 暫緩；之後按 M 合併", "$1 暂缓；之后按 M 合并"],
  [/^(\S+) crashed on (\S+)$/, "$1 在 $2 當機了", "$1 在 $2 宕机了"],
  [/^(\S+) re-dispatched on (\S+)$/, "$1 重新派到 $2", "$1 重新派到 $2"],
  [/^(\S+): (.+) is unavailable$/, "$1：$2 無法使用", "$1：$2 无法使用"],
  [/^Course set: (\S+) is (\d+)\w\w$/, "航向已定：$1 排第 $2", "航向已定：$1 排第 $2"],
  [/^(\S+) rescoped: the kraken waits far off$/, "$1 縮小範圍：海怪在遠處等", "$1 缩小范围：海怪在远处等"],
  [/^(\S+) (parked|dropped)$/, "$1 已$2", "$1 已$2"],
  [/^Survey (\S+): (.+)$/, "勘測 $1：$2", "勘测 $1：$2"],
  [/^round (\d+)$/, "第 $1 輪", "第 $1 轮"],
  [/^course (\d+)$/, "航向 $1", "航向 $1"],
  [/^(\d+) approvals$/, "$1 次核准", "$1 次核准"],
  [/^(\d+) merged, (\d+) on the first review \(standing ([\d.]+)\)$/, "$1 次合併，$2 次一輪過（積分 $3）", "$1 次合并，$2 次一轮过（积分 $3）"],
  [/^Next: (.+) at (\d+)$/, "下一階：$1（$2）", "下一阶：$1（$2）"],
  [/^Combo ×(\d+)$/, "連擊 ×$1", "连击 ×$1"],
  [/^Critical hit(.*)!$/, "會心一擊$1！", "会心一击$1！"],
  [/^(.+) is reloading$/, "$1 裝填中", "$1 装填中"],
  [/^Special-move style: (.+)$/, "必殺技風格：$1", "必杀技风格：$1"],
  [/^(\d+) blows on the head · (\d+) perfect reads · (\d+) crits$/, "頭部 $1 擊 · $2 次完美看穿 · $3 次會心", "头部 $1 击 · $2 次完美看穿 · $3 次会心"],
  [/^(\S+) complete · (\d+) merged into main$/, "$1 完成 · $2 個合併進 main", "$1 完成 · $2 个合并进 main"],
  [/^The kraken holds (.+) · round (\d+) · only an approval wins$/, "海怪抓住 $1 · 第 $2 輪 · 只有核准能贏", "海怪抓住 $1 · 第 $2 轮 · 只有核准能赢"],
  [/^(Slam|Jab|Two-hit combo|Slam\?)( \d\/2)? at deck section (\d)$/, "$1$2，甲板第 $3 段", "$1$2，甲板第 $3 段"],
  [/^(.+) needs the captain's call on (.+) before going on\.$/, "$1 需要船長決定「$2」才能繼續。", "$1 需要船长决定「$2」才能继续。"],
  [/^(.+)\. Approved on round (\d+); the seven gates are green\.$/, "$1。第 $2 輪核准；七道閘門全綠。", "$1。第 $2 轮核准；七道闸门全绿。"],
  [/^(\S+) is at review round (\d+) without approval\. Face it, or let it go\.$/, "$1 審到第 $2 輪還沒核准。迎戰，或放手。", "$1 审到第 $2 轮还没核准。迎战，或放手。"],
];
const WORDS = { parked: ["擱置", "搁置"], dropped: ["放棄", "放弃"] };
export function tr(s) {
  if (LANG === "en" || !s) return s;
  const m = /^(\s*)([\s\S]*?)(\s*)$/.exec(s);
  const core = m[2];
  if (!core) return s;
  const d = DICT.get(core);
  if (d) return m[1] + d[LANG] + m[3];
  for (const [re, tw, cn] of PAT) {
    const x = re.exec(core);
    if (!x) continue;
    let out = LANG === "tw" ? tw : cn;
    for (let i = x.length - 1; i >= 1; i--) {
      let v = x[i] ?? "";
      const dv = DICT.get(v);
      if (dv) v = dv[LANG];
      if (WORDS[v]) v = WORDS[v][LANG === "tw" ? 0 : 1];
      out = out.split("$" + i).join(v);
    }
    return m[1] + out + m[3];
  }
  return s;
}
// ---------------------------------------------------------------- the DOM watcher
const SRC = new WeakMap(); // node -> the English it was written in
const SKIP = (el) => el && el.closest && el.closest(".jp, .sp-sfx, script, style, canvas, #c");
let busy = false;
function fixText(n) {
  if (SKIP(n.parentElement)) return;
  const known = SRC.get(n);
  // a node whose text is not what we last wrote was rewritten in English by the UI
  const src = known && known.out === n.nodeValue ? known.src : n.nodeValue;
  const out = tr(src);
  SRC.set(n, { src, out });
  if (out !== n.nodeValue) n.nodeValue = out;
}
function fixAttrs(el) {
  for (const a of ["title", "aria-label"]) {
    if (!el.hasAttribute || !el.hasAttribute(a)) continue;
    const key = "data-en-" + a, cur = el.getAttribute(a);
    const src = el.getAttribute(key) !== null && el.getAttribute(key + "-out") === cur ? el.getAttribute(key) : cur;
    const out = tr(src);
    el.setAttribute(key, src);
    el.setAttribute(key + "-out", out);
    if (out !== cur) el.setAttribute(a, out);
  }
}
function walk(root) {
  if (root.nodeType === 3) return fixText(root);
  if (root.nodeType !== 1 || SKIP(root)) return;
  fixAttrs(root);
  const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
  for (let n = w.nextNode(); n; n = w.nextNode()) n.nodeType === 3 ? fixText(n) : fixAttrs(n);
}
export function translateAll() {
  busy = true;
  walk(document.body);
  busy = false;
}
let observer = null;
export function watch() {
  if (observer) return;
  observer = new MutationObserver((muts) => {
    if (busy || LANG === "en") return;
    busy = true;
    for (const m of muts) {
      if (m.type === "characterData") fixText(m.target);
      else if (m.type === "attributes") fixAttrs(m.target);
      else for (const n of m.addedNodes) walk(n);
    }
    busy = false;
  });
  observer.observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ["title", "aria-label"] });
}
export function setLang(l) {
  const was = LANG;
  LANG = l;
  try {
    localStorage.setItem("fmv-lang", l);
  } catch {}
  if (l === "en" && was !== "en") {
    // back to English: restore every node we translated
    busy = true;
    const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = w.nextNode(); n; n = w.nextNode()) {
      const k = SRC.get(n);
      if (k && k.out === n.nodeValue) n.nodeValue = k.src;
    }
    for (const el of document.querySelectorAll("[data-en-title]")) el.setAttribute("title", el.getAttribute("data-en-title"));
    for (const el of document.querySelectorAll("[data-en-aria-label]")) el.setAttribute("aria-label", el.getAttribute("data-en-aria-label"));
    busy = false;
  } else translateAll();
}
