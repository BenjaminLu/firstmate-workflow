# firstmate-workflow

一個由 firstmate 調度其他 agent 完成軟體工作的工作流。三件事構成它：

- **`skills/`** — 內容。所有角色的行為用純 Markdown 定義。
- **`bin/fm-*.sh`** — 法律。驗收只看檔案系統與 exit code，不看模型講了什麼。
- **`board/`** — 船長的唯一操作面。即時狀態、待決事項、拍板送出。

agent CLI 是可替換的引擎，不是系統本體。

規格看 [`design/design.md`](design/design.md)，任務 DAG 看 [`design/tasks.json`](design/tasks.json)。

## 狀態

規格已定案，尚未實作。`design/proposals/` 下是船長已核可的看板提案視覺化
（丟棄式 prototype，不會直接晉升為實作）。

```
open design/proposals/2026-09-20-captain-board/prototype.html
```

方向鍵切四級呈現，右上角切 EN / 繁 / 简。
