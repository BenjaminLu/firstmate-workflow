# firstmate-workflow — 設計文件

> 本文是全系統唯一規格來源。`bin/fm-dispatch.sh` 從 `design/tasks.json` 讀任務 DAG，
> 本文的第 14 節與該檔一一對應；兩者不一致時 CI 會紅。
>
> 語言：本文與所有 PR 討論固定 zh-TW 單語。只有船長看板三語（見第 9 節）。

---

## 1. 這是什麼

一個由單一 agent（firstmate）調度其他 agent 完成軟體工作的工作流。三件事構成它：

1. **`skills/`** —— 內容。所有角色的行為用純 Markdown 定義，改 skill 就改行為。
2. **`bin/fm-*.sh`** —— 法律。驗收一律看檔案系統與 exit code，不看模型講了什麼。
3. **`board/`** —— 船長的唯一操作面。即時狀態、待決事項、拍板送出。

agent CLI 是**可替換的引擎**，不是系統本體。

### 不是什麼

- 不是自動合併機器人。合併永遠由人按下。
- 不是 agent 自主改進系統。skills 的變更走跟一般程式碼一模一樣的 PR 與七道閘。
- 不做 snapshot 式狀態。事件日誌就是真相（第 5.1 節）。

---

## 2. 已定案決策

| 編號 | 決策 | 結果 |
|---|---|---|
| Q0 | 落點 | 全新 repo，不重用任何既有專案 |
| Q1 | 執行基座 | shell 起獨立 agent 程序，一 task 一 git worktree |
| Q2 | firstmate 形態 | 長駐 session ＋ 看板為第二輸入通道 |
| Q3 | 真相來源 | 本地 append-only `state/events.jsonl`；GitHub 為外顯 |
| Q4 | 看板→firstmate | 決策落檔 + 阻塞等待（bun `fs.watch`，退回輪詢） |
| Q5 | 看板技術棧 | Bun + SSE + vanilla HTML，零 build step |
| Q6 | 確定性邊界 | script 管「跑過了嗎」，模型只管「做對了嗎」 |
| Q7 | 第三輪協定 | `ASK-PASS-CRITERIA` + 編號封閉清單 |
| Q8 | 圖解範圍 | 只有要船長拍板的方案畫圖，優先重用既有圖 |
| Q9 | PR 落點 | private `BenjaminLu/firstmate-workflow` |
| R1 | 自更新 | skills 定義行為；寫回走完整 PR；外部 skills 單向唯讀匯入 |
| R2 | reviewer 視野 | 只有 diff + task spec + 驗收準則，看不到 worker reasoning |
| R3 | 粒度 | 一 task = 一 PR = 一 worktree；DAG `depends_on`；並行上限 3 |
| R4 | 分支 | 每 task 從 `main` 開、打回 `main`；衝突由 worker 自行 rebase |
| R5 | 日誌寫入 | 只能經 `bin/fm-emit.sh`（`flock` 序列化） |
| R6 | 開本地檔 | `/open` 呼叫編輯器（localhost only、路徑須在 repo 內）＋唯讀檢視器 |
| R7 | CI | 本機與 GHA 跑同一支 `bin/ci.sh` |
| R8 | 復原 | event log replay ＋ 啟動時對帳 |
| R9 | hot-reload | 前端 SSE 推 `reload`；後端 `bun --watch` |
| I1 | 看板動態內容 | agent 產出時就寫入三語 payload |
| I2 | 三語來源 | agent 產 en + zh-TW；zh-CN 由詞表機械轉換 |
| I3 | 語言偏好 | `localStorage` ＋ `?lang=` 覆寫，預設 `zh-TW` |
| I4 | 圖解語言 | 產 `.en.html` 與 `.zh-TW.html`；zh-CN 後處理 |
| I5 | e2e 語言 | chrome 快照三語；互動流程只跑 zh-TW |
| I6 | 工作語言 | PR / design.md / skills 固定 zh-TW 單語 |
| I7 | 原文呈現 | 看板只顯示三語結構化摘要 ＋ PR 連結 |
| V1 | vendor 抽象 | shell adapter 契約 |
| V2 | 角色 vendor | 全體同一家；reviewer 可選擇性覆寫 |
| V3 | 能力差異 | adapter 只產生檔案變更，git/gh 全由腳本做 |
| V4 | prompt 可攜 | skills 純 Markdown，adapter 負責翻譯；lint 擋 vendor 專屬語法 |
| V5 | 可攜性保證 | `mock` adapter 跑全部 e2e ＋ adapter 契約測試 |
| V6 | 失敗語意 | exit 0 完成 / 1 沒過 / 2 供應商不可用（只有 2 切 fallback） |
| V7 | 看板顯示 | 標頭顯示引擎，reviewer 覆寫時標示 |
| V8 | 對抗性 | 資訊不對稱 ＋ 對立 skill ＋ 可選跨 vendor |

---

## 3. 角色與程序

| 角色 | 形態 | 生命週期 | 能碰 git 嗎 |
|---|---|---|---|
| **captain**（你） | 人 | — | 只按合併 |
| **firstmate** | 長駐互動 session | 一直在 | 不 |
| **worker** | `bin/adapters/<vendor>.sh` 起的獨立程序 | 一 task 一條命 | **不** |
| **reviewer** | 同上，獨立程序 | 一輪審核一條命 | **不** |
| **board** | `bun --watch board/server.ts` | 一直在 | 不 |

worker 與 reviewer 都是無狀態的一次性程序：讀 prompt、在自己的 worktree 裡改檔案、退出。
git / commit / push / `gh pr create` / 貼 comment **全部由 `bin/fm-*.sh` 執行**。

firstmate 自己不寫程式碼，只做四件事：派工、整理、把待決事項送上看板、等你拍板。

---

## 4. Repo 佈局

```
bin/
  fm.sh                 唯一入口，分派子命令
  fm-emit.sh            事件唯一寫入口（flock 序列化、schema 驗證）
  fm-dispatch.sh        讀 DAG，派 ready 的 task；無「成案」事件不動作
  fm-worker.sh          建 worktree → 跑 adapter → commit → 開 PR
  fm-gate.sh            七道閘，exit code 說了算
  fm-review.sh          起 reviewer（只餵 diff）→ 貼 PR comment
  fm-protocol.sh        第 3 輪 ASK-PASS-CRITERIA 強制與違規偵測
  fm-decide.sh          阻塞等待船長決策
  fm-reconcile.sh       崩潰後對帳
  fm-diagram.sh         為決策產生 en / zh-TW 圖解
  ci.sh                 本機與 GHA 跑的同一支
  adapters/
    _contract.md        adapter 契約
    mock.sh             CI 用，純 shell，產生固定 diff
    claude.sh  cursor-agent.sh  gemini.sh
skills/
  firstmate/SKILL.md    調度、整理、何時上呈船長
  worker/SKILL.md       如何做事、如何在第 3 輪反問
  reviewer/SKILL.md     如何找出拒絕的理由
  vendor/               從外部 skills 單向唯讀匯入，不回寫
board/
  server.ts             SSE + /open + 唯讀檢視器 + 決策 API
  public/index.html     vanilla，零 build
  public/board.css  public/board.js
i18n/
  ui.en.json  ui.zh-TW.json
  tw2cn.tsv             繁簡＋陸台術語對照
state/                  .gitignore，執行期產物
  events.jsonl          append-only，唯一真相
  decisions/D-*.json    船長的回覆落地處
  workers/T-*.pid
  worktrees/T-*/
design/
  design.md             本文
  tasks.json            機器可讀的任務 DAG
  diagrams/D-*.{en,zh-TW}.html
  proposals/            每次盤問後的提案視覺化，丟棄式，保留供回溯
tests/
  *.test.sh             閘門與腳本自己的測試
  adapter-contract.test.sh
  e2e/*.spec.ts         Playwright，看板
config.yaml             vendor / model / 並行上限 / 編輯器
```

---

## 5. 契約

### 5.1 事件日誌 `state/events.jsonl`

append-only。**任何程序只能透過 `bin/fm-emit.sh` 寫入**，該腳本用 `flock` 序列化並做單行原子 append。
CI 以 `grep -rn '>>.*events\.jsonl' bin/ board/` 擋掉繞道寫入。

```jsonc
{"ts":"2026-09-20T14:10:02Z","actor":"worker-2","task":"T-004","type":"gate_failed",
 "pr":9,"data":{"gate":5},
 "summary":{"en":"...","zh-TW":"..."}}      // 要上看板的事件才需要 summary
```

`type` 列舉：`greenlit` `dispatched` `commit_pushed` `pr_opened` `gate_passed` `gate_failed`
`review_opened` `ask_pass_criteria` `criteria_returned` `protocol_violation` `approved`
`merged` `decision_requested` `decision_made` `worker_crashed` `vendor_unavailable`

`summary` 只帶 en 與 zh-TW；zh-CN 由看板用 `i18n/tw2cn.tsv` 即時轉換（純查表，無模型呼叫）。

### 5.2 船長決策 `state/decisions/D-*.json`

看板 `POST /decisions` 落檔；`bin/fm-decide.sh` 阻塞等待該目錄出現新檔。

```jsonc
{"id":"D-007","task":"T-004","chosen":"B","note":"先不要動 schema","ts":"..."}
```

等待實作：有 `bun` 時用 `bun run bin/watch-decisions.ts`（`fs.watch`，毫秒級）；
沒有時退回 `while :; do ...; sleep 1; done`。**不引入 `fswatch` 依賴。**

### 5.3 Adapter 契約 `bin/adapters/<vendor>.sh`

```
用法：  <vendor>.sh run <prompt-file> <worktree-dir> <log-file>
職責：  把 prompt 交給該供應商的 CLI，讓它在 <worktree-dir> 內修改檔案。
禁止：  執行任何 git / gh 指令；寫入 <worktree-dir> 以外的路徑。
退出：  0 = 完成
        1 = 執行了但沒達成（模型放棄、產出不合格）
        2 = 供應商層級不可用（未登入、額度耗盡、網路失敗）
```

只有 `2` 會觸發 `config.yaml` 的 fallback 清單；`1` 照常進七道閘與 reviewer。
每個 adapter 都必須通過 `tests/adapter-contract.test.sh`。

### 5.4 PR 協定

PR 上的字串是 `fm-gate.sh` 的輸入，格式錯誤等於沒發生：

| 字串 | 由誰貼 | 意義 |
|---|---|---|
| `APPROVE:<task-id>` | reviewer | 唯一有效的通過信號 |
| `ASK-PASS-CRITERIA:<task-id>` | worker | 第 3 輪起的反問 |
| `CRITERIA-COMPLETE:<task-id>` | reviewer | 宣告後續編號清單即為完整集合 |
| `REGRESSION:<task-id>` | reviewer | 清單外但屬新引入的退步，允許 |

---

## 6. 生命週期與七道閘

```
盤問 /grilling  →  提案視覺化 /prototype  →  【船長成案】  →  design.md + tasks.json
                                                  ↓
                                   fm-dispatch.sh（只派 ready 的，上限 3）
                                                  ↓
                     fm-worker.sh：worktree → adapter → commit → 開 PR
                                                  ↓
                                   ★ fm-gate.sh 七道閘 ★
                                                  ↓
                     fm-review.sh：reviewer 只拿 diff + spec + 驗收準則
                                                  ↓
                 未過 → worker 復活修（第 3 輪起先發 ASK-PASS-CRITERIA）→ 回閘門
                                                  ↓
                 APPROVE → firstmate 整理狀況 → 【船長在看板按合併】
```

**`fm-dispatch.sh` 在 `events.jsonl` 出現對應的 `greenlit` 事件之前，一律不派工。**
這是第八道閘，擋的是「沒給船長看過就開工」。

### fm-gate.sh 七道閘

| # | 檢查 | 怎麼驗 |
|---|---|---|
| 1 | 分支存在且有 commit | `git rev-list --count main..<branch>` > 0 |
| 2 | rebase 到 main 乾淨 | 在暫存 worktree 試 rebase，非零即失敗 |
| 3 | `bin/ci.sh` exit 0 | 與 GHA 同一支腳本 |
| 4 | diff 未超出宣告範圍 | `git diff --name-only` ⊆ tasks.json 的 `scope` glob |
| 5 | **新測試不是空的** | revert 實作 hunk → 新測試必須變紅；仍綠即失敗 |
| 6 | GHA 必檢項目為綠 | `gh pr checks <pr> --required` |
| 7 | reviewer 已貼 `APPROVE:<task-id>` | 且發文者必須是設定的 reviewer 帳號 |

七道全綠才會 emit `approved` 並進入「請船長合併」清單。
任何一道紅，reviewer 在 PR 上的任何讚美都不算數。

---

## 7. 第三輪反問協定

第 1、2 輪：reviewer 正常挑毛病。

**第 3 輪起**：

1. worker 必須先貼 `ASK-PASS-CRITERIA:<task-id>`，再動任何一行程式碼。
2. reviewer 必須回一份**編號清單**並貼 `CRITERIA-COMPLETE:<task-id>`。
3. 此後 reviewer 只能針對：清單內編號項目、或標記 `REGRESSION:` 的新引入退步。
4. 出現清單外的舊問題 → `fm-protocol.sh` emit `protocol_violation`，該意見不計入閘門，
   並把事件推上看板讓船長知道 reviewer 在擠牙膏。

目的：終結「改一輪、冒一個新問題」的無限迴圈。

---

## 8. 船長看板

Bun + 原生 SSE + vanilla HTML，**零 build step**。

| 區塊 | 內容 |
|---|---|
| 海面標頭 | 已合併 / 進行中 / 等你 / 受阻 計數、引擎 chip（reviewer 覆寫時標示） |
| 船身 | **海盜船，單一量體**：每層甲板與船殼由同一條透鏡曲線生成到同一張 SVG —— 甲板是前縮平面，船殼是它往下擠出的量體，與方塊船員同一套投影。每層有舷牆立面與黃銅壓條，層與層之間有立面牆（riser），這是「一層」讀得出來的關鍵。船殼為暖黑剪影（`--tar`），**黃銅是全畫面唯一亮點**，船員因此成為最亮的一層。大小隨在編船員數變化，1 桅小艇 → 5 桅旗艦 |
| 甲板 | 所有船員站同一塊甲板；姿勢由狀態驅動；交接物在人之間飛行 |
| 決策台 | 左側是**船長本人**（紅袍金綬帶、三角帽、彎刀），姿勢隨決策狀態改變；右側大決策卡：選項、before/after 圖解、PR 連結、design.md 連結、下令按鈕 |
| 泳道 | 排隊 / 施工 / 閘門 / 審核 / 船長 / 已合併 |
| 即時日誌 | `events.jsonl` 的三語摘要 |

**船的分級**（依甲板上總人數，含 firstmate 與 reviewer）：

| 人數 | 船型 | 桅 | 甲板層 | 甲板寬 |
|---|---|---|---|---|
| ≤3 | 單桅小艇 | 1 | 1 | 42% |
| 4–5 | 雙桅縱帆船 | 2 | 1 | 54% |
| 6–8 | 三桅巡防艦 | 3 | 2 | 66% |
| 9–12 | 四桅戰列艦 | 4 | 2 | 74% |
| 13–18 | 旗艦 | 5 | 3 | 82% |
| 19–24 | 巨型戰艦 | 6 | 4 | 90% |

**上限 24 人**（含 firstmate 與 reviewer）。實測 24 人時人物縮放觸及 0.52 下限、
氣泡間距剩 10px，再往上只是越來越小。真正的瓶頸不是船而是 `concurrency`（預設 3）。

**人多時往上分層，不往橫向拉長。** 上層甲板較短，firstmate 永遠在最高層掌舵，
reviewer 在次高層。船體、各層甲板、船員、名牌全部對齊 `--deckY + row × --rowH`；
各層甲板板面高度必須一致，否則各層船員「踩進甲板」的深度會不同。

**舵輪是最上層甲板的固定物**，不是掛在 firstmate 身上的道具 —— 由結構保證它永遠在頂層艉側，
而不是靠「剛好 firstmate 站在那裡」。firstmate 雙手前伸扶舵。

桅高與場景高度由 `headroom()` 推導，保證**整片帆都在最高層船員的頭頂之上** —— 否則人會站在帆布裡。
名牌寬度逐層計算（各層甲板寬度不同），依密度降級（≤4 全欄位 / 5–7 去掉任務標題 / ≥8 只留短代號與進度條），
3 至 14 人的每個人數都不得重疊。

**每個船員頭上有一個氣泡**承載他的狀態（代號、任務、進度條、百分比），氣泡尾巴指向本人。
邊框顏色即狀態（施工藍／審核紫／閘門紅／已合併綠／排隊灰）。交接物落地時對應氣泡會擴散一圈。
層距必須大於「人高 + 氣泡高」，否則氣泡會蓋到上一層的船員。

**各層船員做各層的事**，共 12 種動作，用 id 雜湊挑選以保持穩定：

| 甲板 | 工作 |
|---|---|
| 頂層 | 掌舵、瞭望、打旗號、指揮、記航海日誌 |
| 中層 | 拉纜、絞盤、搬運、爬索具 |
| 主甲板 | 打鐵、鋸木、刷洗、搬運 |

**閒置的人也要有自己的動作池**（刷甲板、爬索具、搬貨、記帳、絞盤）—— 並行上限只有 3，
大船上多數人沒有任務，全部給同一個閒置姿勢會變成一排壞掉的雕像。
工具跟著**工作**走不是跟著角色走。狀態仍然優先：閘門擋下就駝背、審核中就舉望遠鏡。

**桅杆從最上層甲板長出，桅距依 `deckW` 按比例分佈** —— 用固定百分比的話，小船時桅杆會插在船殼外面。

**船長本人**站在決策台左側的聚光台上，可拖曳旋轉，三種姿勢：
未選 `c-idle` 手按刀柄 → 選了選項 `c-ready` 刀半出鞘 → 按下令 `c-order` 舉刀。

**互動**：拖人物轉單人、拖甲板轉全員、雙擊復位。狀態文字綁在各自人物腳下。
所有姿勢以 `.fig.s-<state>` class 表達，**e2e 直接斷言 class，不比對截圖**。

**hot-reload**：`board/public/**` 變動 → SSE 推 `reload`；`board/server.ts` 變動 → `bun --watch` 重啟，
SSE client 自動重連。決策已落檔，重啟不掉。

**`/open`**：`GET /open?path=` → `code <path>`。僅接受 localhost 來源，且 `realpath` 必須在 repo 內，
否則 403。另備唯讀 diff 檢視器作為不切窗的替代。

3D 船員的正式實作從 `design/proposals/` 的 prototype **重寫**，不直接晉升
（prototype 在無測試、無錯誤處理的前提下寫成）。

---

## 9. 三語

只有看板三語。PR、design.md、skills、事件原文一律 zh-TW 單語。

- agent 在 `fm-emit.sh` 的 `summary` 欄位寫入 **en + zh-TW** 兩份。
- zh-CN 由 `i18n/tw2cn.tsv` 機械轉換（繁簡＋陸台術語：`程式`→`程序`、`函式`→`函数`、`相依`→`依赖`）。
  詞表進版控、有測試。反向不做（`程序` 在 zh-CN 同時是 program 與 procedure，轉不回去）。
- UI chrome 走 `i18n/ui.*.json`。CI lint：UI 出現未進字典的硬編碼字串即紅。
- 圖解產 `.en.html` 與 `.zh-TW.html` 兩版，zh-CN 後處理 HTML 文字節點。
- 語言偏好存 `localStorage`，`?lang=` 可覆寫，預設 `zh-TW`。

---

## 10. CI

本機與 GitHub Actions 跑**同一支** `bin/ci.sh`：

```
shellcheck bin/**.sh          →  bash tests/*.test.sh
→  bun test                   →  playwright（chrome 快照三語；互動流程只跑 zh-TW）
→  lint：硬編碼 UI 字串 / 繞道寫 events.jsonl / skills 內的 vendor 專屬語法
```

**所有 e2e 使用 `mock` adapter** —— 不呼叫任何模型，因此快、免費、確定性。
真 vendor 只在 nightly smoke job 跑。

---

## 11. 自更新

`skills/` 是行為定義，改 skill 即改行為，不必改程式碼。

firstmate 跑完一輪後可以開 `skill-update` task，**但它走一模一樣的 PR + reviewer + 七道閘**。
系統不能偷改自己。

`fm.sh sync-skills` 從外部 skills 目錄單向匯入到 `skills/vendor/`，唯讀，不回寫，
不污染使用者的全域 skills。

---

## 12. 失效與復原

- 真相是 `events.jsonl`，啟動時 replay 重建狀態。不做 snapshot。
- `fm-reconcile.sh`：掃 `state/worktrees/` ＋ `gh pr list` 對帳；
  worker 以 pid file 判活，已死的標 `worker_crashed` 並重派。
- adapter 回 `2` → 依 `config.yaml` 的 fallback 清單換下一家，emit `vendor_unavailable`。
- 日誌成長到影響 replay 速度再談壓縮，現在不做。

---

## 13. 安全

- `/open` 僅接受 localhost，`realpath` 須落在 repo 內，否則 403。
- adapter 禁止執行 git / gh；worker 拿不到 GitHub token。
- repo 為 private：內含本機路徑、agent prompt 與決策紀錄。
- 看板不對外開埠，僅綁 `127.0.0.1`。

---

## 14. 任務 DAG

機器可讀版本在 `design/tasks.json`，欄位：`id` `title` `milestone` `depends_on` `scope`
`bootstrap` `acceptance`。`scope` 是第 4 道閘的 glob 白名單。

`bootstrap: true` 的任務由人手工建立 —— 派工器本身還不存在，無法自己派自己。

### M0 — 骨架（bootstrap）

| id | 標題 | 依賴 |
|---|---|---|
| T-001 | repo 骨架、`ci.sh`、bash 測試框架 | — |
| T-002 | `fm-emit.sh`：事件唯一寫入口 | T-001 |
| T-003 | adapter 契約、`mock.sh`、契約測試 | T-001 |
| T-004 | `fm-gate.sh`：七道閘 | T-002, T-003 |
| T-005 | `fm-worker.sh`：worktree → adapter → commit → PR | T-003, T-004 |
| T-006 | `fm-review.sh`：reviewer 只餵 diff | T-005 |
| T-007 | `fm-dispatch.sh`：DAG、上限 3、成案閘 | T-005, T-006 |
| T-008 | `fm-decide.sh`：決策落檔 + 阻塞等待 | T-002 |

### M1 — 看板

| id | 標題 | 依賴 |
|---|---|---|
| T-009 | board server：SSE、靜態、hot-reload | T-002 |
| T-010 | board UI：甲板、船員、決策台、泳道、日誌 | T-009 |
| T-011 | i18n：字典、`tw2cn.tsv`、硬編碼 lint | T-009 |
| T-012 | `/open` 端點與唯讀 diff 檢視器 | T-009 |
| T-013 | 決策 API：`POST /decisions` → 落檔 | T-008, T-009 |
| T-014 | Playwright e2e ＋ GHA workflow | T-010, T-011, T-013 |

### M2 — 協定與自更新

| id | 標題 | 依賴 |
|---|---|---|
| T-015 | `fm-protocol.sh`：第 3 輪強制與違規偵測 | T-006 |
| T-016 | `fm-diagram.sh`：決策圖解 en / zh-TW ＋ 看板嵌入 | T-010 |
| T-017 | `fm-reconcile.sh`：崩潰對帳 | T-007 |
| T-018 | `skills/` 自更新流程與 `sync-skills` | T-007, T-015 |
