# Modding Firstmate Voyage v2.5 · 模組教學

[English](#english) · [繁體中文](#繁體中文)

---

## English

A mod changes what the game looks like, never what it does. It is **one JSON file**: plain
data that can

- swap or extend the ship: its decks, rooms, doors, stairs and ladders, masts, furniture and
  stations;
- recolour the crew, or swap single sprites (a hand, a head, a prop);
- say the HUD's lines and the stage's captions differently, in English, 繁體中文 and 简体中文.

The game reads a mod, checks every value against a strict schema, and refuses the whole file with
a list of errors if anything is off. A mod cannot run code or reach the network (see
[What a mod cannot do](#what-a-mod-cannot-do-and-why)).

Two examples ship with the game, in `voyage-2d/mods/`:

| File | What it shows |
|---|---|
| `galleon.json` | A different ship: a tall galleon with a three-tier stern castle, four masts, two gun decks, an orlop and a hold. |
| `crimson-crew.json` | A skin: the sailors in crimson, a new placard sprite, new captions. |

### 1. The manifest

```json
{
  "format": "voyage-mod/1",
  "id": "my-mod",
  "name": { "en": "My mod", "zh-TW": "我的模組", "zh-CN": "我的模组" },
  "version": "1.0.0",
  "author": "you",
  "description": { "en": "What it changes." },
  "ships": { "replace": false, "classes": [] },
  "crew": { "palettes": {}, "frames": {}, "props": {} },
  "strings": { "en": {}, "zh-TW": {}, "zh-CN": {} },
  "captions": {}
}
```

| Key | Required | What it is |
|---|---|---|
| `format` | yes | Always `"voyage-mod/1"`. A later format gets a new number. |
| `id` | yes | `a-z`, `0-9` and `-`, at most 32. The name for `?mod=<id>`. |
| `name` | yes | A text, or `{ "en", "zh-TW", "zh-CN" }` (`en` required). |
| `version`, `author`, `description` | no | Texts, shown in Settings. |
| `ships` | no | Ship layouts (§3). `replace: true` makes them the only ships; `false` (the default) puts each one in place of the default class with the same `id`, or adds it. |
| `crew` | no | The crew's looks (§4). |
| `strings` | no | HUD lines by key, per language (§5). |
| `captions` | no | The stage's banners and prompts, by their English words (§5). |

Every object is closed: a key the game does not know is an error, at every level. A text is plain
text: `<` and `>` are refused, and so are control characters.

Limits: the file at most 3,000,000 bytes; at most 8 ship classes; a text at most 20–400
characters depending on the field; an image at most 400,000 characters of `data:` URI.

### 2. Coordinates and units

The ship lives in **ship space**, the same numbers the walking and the drawing use:

- **x** runs from the stern (negative) toward the bow (positive). 0 is the middle of the ship.
- **y** runs **down**. The main deck's floor is `y = 0`; a castle deck above it has a negative
  y; the decks below have positive y.
- **z** runs across a deck, from the near rail (0, toward you) to the far rail (420). You do not
  give z: rooms, doors, stairs and furniture have fixed places across the deck.

One unit is about 1/200 of a crewman's height (a crewman at crew scale 1 is about 200 tall, his
footprint 26 in radius, and he walks 300 a second). The default ships put every deck **480**
below the one above, so a room is about 2.4 crewmen tall. The ship of the line is 10,000 long.

The **hull** is four numbers:

| Key | Meaning | Range |
|---|---|---|
| `stern` | x of the top of the transom | −20000 … −1000 |
| `bow` | x of the stem's head | 1000 … 20000 |
| `keel` | y of the keel's bottom | 600 … 8000 |
| `waterline` | y where the sea stands on her side | 0 … keel |

The side profile is drawn from them and from the decks: the rail follows a sheer that rises to the
ends and steps up over any deck above the main deck that starts in the aft quarter (a quarterdeck,
a poop, a stern castle) or ends in the forward quarter (a forecastle); the stem rakes forward and
sweeps into the keel at 0.19 of the length from the bow; the sternpost and the counter overhang
aft. Keep your lowest gun deck above the waterline (its ports are 78 above its floor).

### 3. Ships: decks, rooms, links, masts, props, stations

A ship class:

```json
{
  "id": "galleon", "cap": 24, "crewScale": 0.84,
  "name": { "en": "Galleon", "zh-TW": "大帆船", "zh-CN": "大帆船" },
  "hull": { "stern": -5500, "bow": 5500, "keel": 2320, "waterline": 1150 },
  "decks": [], "rooms": [], "links": [], "masts": [], "props": [], "stations": []
}
```

`cap` is how many hands she carries (1–24); the game picks the smallest class whose `cap` fits
the crew. `crewScale` (0.6–1.2) draws her crew smaller or larger.

**Decks** — `{ "id", "y", "x0"?, "x1"?, "label"? }`, 2 to 14 of them. One must be
`{ "id": "main", "y": 0 }`. A deck **above** the main deck (y < 0) needs `x0` and `x1`: it makes a
castle, and the hull is drawn round it. A deck below may leave `x0`/`x1` out: it then runs the
hull's inside length at its height, less 70 at each end. Ids are `a-z`, `0-9`, `-`, starting with a
letter; `nest…` is kept for the crow's nests.

**Rooms** — `{ "id", "kind", "deck", "x0"?, "x1"?, "aft"?, "fore"?, "furnish"?, "label"? }`. A room
is a stretch of one deck. Leave out `x0`/`x1` to run to the deck's end. `aft` and `fore` say what
stands at the room's ends: `"door"` (a bulkhead with a doorway, the default), `"wall"` (a solid
bulkhead) or `"open"` (nothing). Where two rooms meet, a door wins over a wall and a wall over
open. A deck's own ends are the hull: no bulkhead is made there. The `label` is the plaque shown
in the room.

A room's **kind** decides its furniture (unless `"furnish": false`) and its stations:

| Kind | Furniture | Stations | Who stands there |
|---|---|---|---|
| `helm` | the wheel, the bell | `helm` | the captain (a layout needs one) |
| `cabin` | the desk, the stern windows, a shelf, a lantern | `cabin`, `visit` | the captain while a decision waits; a hand waiting on his call |
| `chart` | the chart table, charts on the wall | `chart`, `visit` | the firstmate |
| `waist` | workbenches, the capstan | `work`, `rig` | hands at work |
| `workshop` | workbenches, tools | `work` | hands at work |
| `forecastle` | — | `lookout`, `rig` | lookouts (the sim's "top" station) |
| `gundeck` | a gun each side every 300 or so | `gate` | a hand whose check (gate) is red |
| `quarters` | hammocks, sea chests | `rest` | idle, queued and downed hands |
| `galley` | the stove, the mess table | `rest` | idle hands |
| `cargo` | casks and crates (and, live, one crate per ready or backlog task) | `cargo` | overflow rest |
| `open` | nothing | — | — |

A crew member's station follows his workflow state (the Playground's simulation, or the board's
in Live): **at work** → a workbench (or the rigging, or a lookout, by what he is doing); **a red
gate** → a gun; **in review** → a crow's nest; **waiting on the captain** → the captain's cabin;
**idle, queued or down** → the quarters and the galley. The reviewer keeps a crow's nest, the
firstmate the chart room. When every station of a kind is taken, the next kind on its list is used,
so give each kind enough stations for your `cap`.

**Links** — `{ "kind": "stairs" | "ladder", "from", "to", "x", "dir"?, "id"? }` join two decks
(the order of `from` and `to` does not matter). `dir` (1 or −1) is the way the flight runs down
along x. The game places:

- a **stair**: its run is 0.7 × the height between the decks (336 for 480). The hatch in the upper
  deck spans `x … x + dir × 0.82 × run`; the flight on the lower deck spans `x … x + dir × run`,
  on the far side (160 across). Its landings stand at `x − dir × 64` above and
  `x + dir × (run + 64)` below.
- a **ladder**: a hatch 104 wide at `x` in the middle of the upper deck; landings at
  `x + dir × 96` above and `x + dir × 66` below.

A stair from a castle's forward edge down to the waist has no hatch (it starts at the deck's end).
A hatch, flight or ladder may not run into a mast, a bulkhead or another way down; a landing may
not stand in anything.

**Masts** — `{ "x", "height", "span"?, "nest"? }`, up to 5. `height` is from the highest deck under
it to the masthead; `span` is half the widest yard (default 0.19 × height). Yards and sails are
spread down the mast. With `"nest": true` it gets a crow's nest at the lower masthead (a small deck
`nest`, `nest1`, …, with two `review` stations) and shrouds from the deck below up to it. A mast
runs down through every deck to the keel: keep ladders 220 away from it.

**Props** — `{ "kind", "deck", "x", "far"? }`, extra furniture:

| Kind | Width | Across the deck |
|---|---|---|
| `cask`, `crate` | 104 | the far side |
| `workbench` | 150 | the middle (150–250) |
| `table` | 200 | the middle |
| `desk` | 180 | the middle |
| `stove` | 140 | the far side |
| `chest` | 84 | the far side |
| `capstan` | 92 | the middle |
| `hammock`, `lantern`, `shelf`, `bell` | — | drawn only (hung, or on the wall) |

A prop that does not fit (a wall, a link, another prop in the way) is an error.

**Stations** — `{ "kind", "deck", "x", "dir"?, "id"? }`, extra stations (`dir` is the way he
faces). Kinds: `helm`, `mate`, `cabin`, `visit`, `chart`, `work`, `rig`, `lookout`, `review`,
`gate`, `rest`, `cargo`. A station must be clear of everything and at least 150 from any other.

**Battle stations** — `"battle": [{ "post", "deck", "x", "dir"? }]`. When the kraken's fight is
taken up, the call "All hands! Battle stations!" sends every hand running to one of these, one each:

| Post | Who takes it |
|---|---|
| `captain` | the captain (at the bow rail) |
| `mate` | the firstmate, beside him |
| `gun` | hands, at the guns (the bow's first) |
| `rig` | hands, at the rigging |
| `ammo` | hands, carrying shot up from the hold |
| `lookout` | the reviewers (the nests first), then hands |

Leave `battle` out and the game makes them from the rooms: the captain and the mate at the
forecastle's bow end, lookouts along the forecastle and in every nest, the guns of the forward half
of every gun deck (then the rest), the forward rigging stations, and posts in the hold's forward
part. A `gun` post takes the gun nearest it (within 200 on its deck): in the fight that gun is trained on
the kraken, its barrel angled toward the bow, and its shots fly from its muzzle. If you give `battle`, it must hold a `captain` and a `mate` post and at least as many posts as
`cap`; each must be a clear spot at least 170 from the next on its deck.

**The gate.** After the schema, the game builds the ship and walks it: every room, every station
and every battle station must be reachable from the helm, by doors, stairs and ladders, and there
must be a battle station for every hand. A ship that fails is refused with what it could not reach.

### 4. The crew's looks

The crew are baked sprites. Models: `captain`, `firstmate`, `reviewer-1`, `robot`,
`sailor-hammer`, `sailor-bandana`, `sailor-spyglass`.

- **Palettes** — `"palettes": { "<model>": [ { "from": "#001860", "to": "#8a0c1c", "tolerance": 44 } ] }`.
  Every pixel of that model within `tolerance` (0–160, RGB distance) of `from` takes `to`, scaled
  by its own brightness so the shading stays. Up to 16 swaps per model; the first that matches wins.
- **Frames** — `"frames": { "<model>": { "q.parts.torso": "data:image/png;base64,…" } }`. A frame
  path is facing (`q` three-quarter, `f` front), then `parts.<part>`, `heads.<expression>`,
  `hands.l.<pose>` / `hands.r.<pose>`, or `whole`. The image is drawn in the baked sprite's box.
- **Props** — `"props": { "placard": "data:image/png;base64,…" }`: the scroll, the flag, the
  placard, the spyglass and the rest.

Images are `data:image/png`, `webp` or `jpeg` URIs, never a link.

### 5. Strings and captions

- **Strings** — `"strings": { "en": { "welcome": "…" }, "zh-TW": { … }, "zh-CN": { … } }`. Keys
  are the HUD's own (`welcome`, `playground`, `merged`, `rit.salvo`, `st.working`, …: a key with a
  dot is one in a group). An unknown key is an error.
- **Captions** — `"captions": { "Aye, captain.": { "en": "Aye aye, skipper!", "zh-TW": "…", "zh-CN": "…" } }`.
  The key is the English line the stage says (its banners and the fight's prompts); the value is
  what to say instead, per language.

### 6. Testing a mod on your computer

1. Serve the game: `cd voyage-2d && python3 -m http.server 8791`, then open
   `http://127.0.0.1:8791/game2d.html` (or open the built `artifact-2d.html` directly).
2. Open the menu (☰), **Settings**, **Mods**, then **Load a mod file…** and pick your `.json`.
   Or drop the file anywhere on the page. The game checks it; if it passes, it is kept in the
   browser and the page reloads with it. If it fails, the errors are listed under the Mods row.
3. **Reset to default** in the same row forgets it.
4. `?mod=none` opens the page without any mod; `?mod=<id>` opens it with a mod bundled with the
   page. To bundle yours, put it in `voyage-2d/mods/` and run `npm run build` (the build
   validates every bundled mod and stops on an error).
5. Useful while testing: `?crew=24` (a full crew), `?driver=0` (the crew stay put), `Z` (the whole
   ship), `Q` (walk the captain round your rooms), the mouse wheel (zoom).

### 7. Validating a mod

```
node tools/validate-mod.mjs mods/my-mod.json
```

It runs the same checks as the game and prints `✓ … ok` with a summary (decks, rooms, links,
guns, stations per kind), or every error with its path, for example:

```
✗ mods/my-mod.json: refused (3 errors)
   mod: unknown key "colour" (allowed: format, id, name, version, author, description, ships, crew, strings, captions)
   mod.ships.classes[0].cap: expected a number, got the text "24"
   mod.ships.classes[0]: room steerage (main) cannot be reached from the helm
```

### 8. Walkthrough: the galleon

Open `mods/galleon.json` next to this.

1. **The manifest.** `format`, `id: "galleon"`, a three-language `name`. `ships.replace: true`:
   the galleon is the only ship, for every crew size, so its `cap` is 24.
2. **The hull.** `stern −5500`, `bow 5500`: 11,000 long, a little longer than the ship of the line.
   `keel 2320`, `waterline 1150`: the two gun decks (480 and 960) stay dry.
3. **The decks.** Four castle decks with their spans — `castle` (−1440) over the stern, `poop`
   (−960), `qd` (−480) and `fore` (−480) — then `main` (0), `gun` (480), `gun2` (960), `orlop`
   (1440) and `hold` (1920), which take the hull's length. The stern castle's third tier is the
   extra deck: the rail steps up over it.
4. **The rooms.** Aft to fore, deck by deck: the stern castle is `open` (flags fly from it); under
   it the `chart` room, with a door forward onto the open poop; under that the captain's `cabin`,
   with a door onto the `helm`. On the main deck: the officers' berths (`quarters`), the steerage
   (`workshop`), the open `waist` and the `galley` under the forecastle. The upper gun deck is one
   `gundeck`; the lower is a `gundeck` and the bosun's store (`workshop`) behind a bulkhead; the
   orlop holds the crew's `quarters` and the `mess`; the hold is `cargo`.
5. **The links.** Stairs down each castle's forward edge (`x` at the deck's end, `dir` toward the
   waist); the companionway and a ladder from the waist to the gun deck; then a stair and a ladder
   between each lower deck and the next, kept away from the masts and from each other.
6. **The masts.** Four: a small bonaventure (3600) on the poop, the mizzen (4800), the main (6600)
   and the fore (5400), each with a nest.
7. **Check it:** `node tools/validate-mod.mjs mods/galleon.json` → 13 decks (with the four
   nests), 20 rooms, 16 links, 47 guns. Try breaking it: set the steerage's `"fore": "wall"` and the
   validator says the steerage and the officers' berths cannot be reached.
8. **Play it:** `?mod=galleon&crew=24`, then `Z` for the whole ship.

### 9. Walkthrough: the crimson crew

Open `mods/crimson-crew.json`.

1. **No `ships`:** the default ships stay.
2. **Palettes.** The sailors' navy is three close shades (`#001860`, `#181848`, `#181860`); each
   becomes a crimson at its own brightness. The firstmate gets the same three and his blue trim;
   the captain's dark coat (`#181830`) turns oxblood. To find a sprite's colours, count them in the
   bake (`bake/sprites.json`), or pick them from a screenshot.
3. **A sprite swap.** `crew.props.placard` replaces the placard the captain raises while a card
   waits with a crimson banner, drawn in the same box (212 × 496).
4. **Strings.** `welcome` in all three languages.
5. **Captions.** Three of the stage's lines, keyed by their English: "Aye, captain.", "Ahoy!
   Merged into main" and "Clearing, and a cheer".
6. **Check it and play it:** `node tools/validate-mod.mjs mods/crimson-crew.json`, then
   `?mod=crimson-crew&scene=decision`.

### What a mod cannot do, and why

- **Run code.** A mod is only ever read with `JSON.parse` and used as numbers, short texts and
  images. There is no field for a script, an event handler, a formula or a template. Texts with
  `<` or `>` are refused, and every text is escaped where it is shown. The page's Content Security
  Policy lets only the page's own bundle run (the build pins it by its hash) and forbids `eval`.
- **Reach the network.** No field takes a URL: images are `data:` URIs inside the file. The CSP
  forbids connecting anywhere but the page's own origin, and the build refuses a bundle with any
  network code in it (`fetch`, `XMLHttpRequest`, `WebSocket`, `sendBeacon`). A mod is loaded from a
  file the player picks, never downloaded.
- **Act for the captain.** A mod cannot answer a decision, merge, park or drop anything, or change
  the board. It changes only how the ship and the crew look and what the stage says.

Why: mods are passed around by people who do not know each other, and in Live the game sits inside
the captain's board, next to real work — a merge card's first answer really merges. Data that
cannot run, cannot phone home and cannot press a button is safe to share.

---

## 繁體中文

模組只改變遊戲的**樣子**，從不改變它**做的事**。一個模組就是**一個 JSON 檔**，裡面只有資料，可以：

- 換掉或擴充船：甲板、房間、門、樓梯與梯子、桅杆、家具與站位；
- 替船員換色，或換掉單張圖（一隻手、一張臉、一個道具）；
- 用英文、繁體中文、簡體中文改寫 HUD 文字與舞台上的台詞。

遊戲讀進模組後，會用嚴格的格式逐一檢查每個值；只要有一處不對，整個檔案就會被拒絕，並列出所有錯誤。模組不能執行程式，也不能連網（見〈[模組不能做的事](#模組不能做的事與原因)〉）。

遊戲附了兩個範例，放在 `voyage-2d/mods/`：

| 檔案 | 示範什麼 |
|---|---|
| `galleon.json` | 換一艘船：高大的西班牙大帆船，三層艉樓、四根桅杆、兩層砲甲板、最下甲板與貨艙。 |
| `crimson-crew.json` | 換膚：水手換成緋紅、換一張決策旗的圖、換幾句台詞。 |

### 1. 模組檔的格式

```json
{
  "format": "voyage-mod/1",
  "id": "my-mod",
  "name": { "en": "My mod", "zh-TW": "我的模組", "zh-CN": "我的模组" },
  "version": "1.0.0",
  "author": "你",
  "description": { "en": "它改了什麼。" },
  "ships": { "replace": false, "classes": [] },
  "crew": { "palettes": {}, "frames": {}, "props": {} },
  "strings": { "en": {}, "zh-TW": {}, "zh-CN": {} },
  "captions": {}
}
```

| 欄位 | 必填 | 說明 |
|---|---|---|
| `format` | 是 | 固定是 `"voyage-mod/1"`。之後的新格式會換新編號。 |
| `id` | 是 | 只能用 `a-z`、`0-9`、`-`，最多 32 字。也是 `?mod=<id>` 用的名字。 |
| `name` | 是 | 一段文字，或 `{ "en", "zh-TW", "zh-CN" }`（`en` 必填）。 |
| `version`、`author`、`description` | 否 | 文字，會顯示在設定裡。 |
| `ships` | 否 | 船的佈局（§3）。`replace: true` 表示只用這些船；`false`（預設）表示以相同 `id` 取代預設船級，或新增一級。 |
| `crew` | 否 | 船員的外觀（§4）。 |
| `strings` | 否 | 依語言、依鍵名改寫 HUD 文字（§5）。 |
| `captions` | 否 | 舞台上的橫幅與提示，以它們的英文原句為鍵（§5）。 |

每一層的物件都是封閉的：遊戲不認得的鍵就是錯誤。文字只能是純文字：含 `<` 或 `>` 會被拒絕，控制字元也會。

上限：整個檔案最多 3,000,000 位元組；最多 8 個船級；文字依欄位最多 20～400 字；每張圖的 `data:` URI 最多 400,000 字元。

### 2. 座標與單位

船在**船體座標**裡，走路與畫圖用的都是同一組數字：

- **x** 從船尾（負）往船首（正）。0 是船的中間。
- **y** 往**下**為正。主甲板的地板是 `y = 0`；在它上面的艉樓、艏樓甲板是負的 y，下面的甲板是正的 y。
- **z** 是橫越甲板的方向，從靠近你的舷邊（0）到遠側舷邊（420）。z 不用你給：房間、門、樓梯、家具在甲板上的橫向位置都是固定的。

一個單位大約是船員身高的 1/200（船員縮放為 1 時身高約 200、腳下半徑 26、每秒走 300）。預設的船每層甲板相隔 **480**，所以一個房間大約 2.4 個人高。戰列艦長 10,000。

**船殼**只有四個數字：

| 鍵 | 意思 | 範圍 |
|---|---|---|
| `stern` | 船尾艉板頂端的 x | −20000 … −1000 |
| `bow` | 艏柱頂端的 x | 1000 … 20000 |
| `keel` | 龍骨底部的 y | 600 … 8000 |
| `waterline` | 吃水線的 y | 0 … keel |

船的側面輪廓由這四個數字與甲板畫出：舷緣沿著兩端翹起的舷弧走，遇到從船尾四分之一起頭的高甲板（後甲板、艉樓、艉樓頂）或在船首四分之一結束的高甲板（艏樓）就往上抬一層；艏柱往前傾，在離船首 0.19 船長處彎進龍骨；艉柱與艉懸伸在後。最低一層砲甲板要在吃水線之上（砲門在地板上方 78）。

### 3. 船：甲板、房間、通道、桅杆、道具、站位

一個船級長這樣：

```json
{
  "id": "galleon", "cap": 24, "crewScale": 0.84,
  "name": { "en": "Galleon", "zh-TW": "大帆船", "zh-CN": "大帆船" },
  "hull": { "stern": -5500, "bow": 5500, "keel": 2320, "waterline": 1150 },
  "decks": [], "rooms": [], "links": [], "masts": [], "props": [], "stations": []
}
```

`cap` 是這艘船載得下的人數（1～24）；遊戲會挑 `cap` 裝得下全體船員的最小船級。`crewScale`（0.6～1.2）讓船員畫小一點或大一點。

**甲板**——`{ "id", "y", "x0"?, "x1"?, "label"? }`，2 到 14 層。其中一層必須是 `{ "id": "main", "y": 0 }`。主甲板**以上**的甲板（y < 0）要給 `x0` 與 `x1`：它就是一座樓（艉樓、艏樓），船殼會繞著它畫。以下的甲板可以省略 `x0`/`x1`，會自動取該高度的船殼內側長度，兩端各退 70。id 用 `a-z`、`0-9`、`-`，以字母開頭；`nest…` 保留給瞭望台。

**房間**——`{ "id", "kind", "deck", "x0"?, "x1"?, "aft"?, "fore"?, "furnish"?, "label"? }`。房間是某層甲板上的一段。省略 `x0`/`x1` 就延伸到甲板盡頭。`aft`（船尾端）與 `fore`（船首端）說明兩端立著什麼：`"door"`（有門口的隔艙壁，預設）、`"wall"`（實心隔艙壁）或 `"open"`（什麼都沒有）。兩個房間相接時，門優先於牆，牆優先於開放。甲板本身的兩端是船殼，不會再立隔艙壁。`label` 是房間裡掛的名牌。

房間的**種類**決定家具（除非 `"furnish": false`）與站位：

| 種類 | 家具 | 站位 | 誰站在這裡 |
|---|---|---|---|
| `helm` | 舵輪、船鐘 | `helm` | 船長（每艘船都要有一個） |
| `cabin` | 書桌、艉窗、書架、提燈 | `cabin`、`visit` | 有決策等著時的船長；等船長決定的船員 |
| `chart` | 海圖桌、牆上的海圖 | `chart`、`visit` | 大副 |
| `waist` | 工作台、絞盤 | `work`、`rig` | 工作中的船員 |
| `workshop` | 工作台、工具 | `work` | 工作中的船員 |
| `forecastle` | — | `lookout`、`rig` | 瞭望的人（模擬裡的 "top" 站位） |
| `gundeck` | 每隔約 300 兩側各一門砲 | `gate` | 檢查（關卡）亮紅燈的船員 |
| `quarters` | 吊床、水手箱 | `rest` | 閒著、排隊中、倒下的船員 |
| `galley` | 爐灶、餐桌 | `rest` | 閒著的船員 |
| `cargo` | 酒桶與木箱（另外每個就緒或待辦任務即時多一個箱子） | `cargo` | 休息站位不夠時的備用 |
| `open` | 無 | — | — |

船員站在哪裡，跟著他的工作狀態走（遊樂場的模擬，或 Live 模式下看板的狀態）：**工作中** → 工作台（或依他做的事去帆索、瞭望）；**檢查亮紅燈** → 砲位；**審查中** → 瞭望台；**等船長決定** → 船長室；**閒著、排隊、倒下** → 船員艙與廚房。審查員固定在瞭望台，大副在海圖室。某一種站位都被占滿時，會依序改用清單上的下一種，所以每種站位要準備得夠你的 `cap` 用。

**通道**——`{ "kind": "stairs" | "ladder", "from", "to", "x", "dir"?, "id"? }` 連接兩層甲板（`from` 與 `to` 誰上誰下都可以）。`dir`（1 或 −1）是樓梯沿 x 往下走的方向。遊戲會這樣擺：

- **樓梯**：水平長度是兩層高度差的 0.7 倍（480 的話是 336）。上層甲板的艙口範圍是 `x … x + dir × 0.82 × 長度`；下層甲板上的梯段範圍是 `x … x + dir × 長度`，靠遠側舷邊（寬 160）。上方平台在 `x − dir × 64`，下方平台在 `x + dir × (長度 + 64)`。
- **梯子**：上層甲板中央、寬 104 的艙口在 `x`；上方平台在 `x + dir × 96`，下方平台在 `x + dir × 66`。

從樓的前緣往下到中甲板的樓梯沒有艙口（它從甲板盡頭開始）。艙口、梯段、梯子不能撞上桅杆、隔艙壁或別的通道；平台不能站在任何東西裡。

**桅杆**——`{ "x", "height", "span"?, "nest"? }`，最多 5 根。`height` 是從它下方最高的甲板量到桅頂；`span` 是最長帆桁的一半（預設是 0.19 × height）。帆桁與帆會自動沿桅杆往下排。`"nest": true` 會在下桅頂加一座瞭望台（一層小甲板 `nest`、`nest1`…，上面有兩個 `review` 站位），並從下方甲板拉一道桅索上去。桅杆會一路穿過每層甲板到龍骨：梯子要離它 220 以上。

**道具**——`{ "kind", "deck", "x", "far"? }`，額外的家具：

| 種類 | 寬度 | 在甲板的橫向位置 |
|---|---|---|
| `cask`、`crate` | 104 | 遠側 |
| `workbench` | 150 | 中間（150～250） |
| `table` | 200 | 中間 |
| `desk` | 180 | 中間 |
| `stove` | 140 | 遠側 |
| `chest` | 84 | 遠側 |
| `capstan` | 92 | 中間 |
| `hammock`、`lantern`、`shelf`、`bell` | — | 只畫出來（吊著或掛在牆上） |

放不下的道具（被牆、通道或別的道具擋住）就是錯誤。

**站位**——`{ "kind", "deck", "x", "dir"?, "id"? }`，額外的站位（`dir` 是他面向的方向）。種類：`helm`、`mate`、`cabin`、`visit`、`chart`、`work`、`rig`、`lookout`、`review`、`gate`、`rest`、`cargo`。站位不能碰到任何東西，而且要離其他站位至少 150。

**戰鬥位置**——`"battle": [{ "post", "deck", "x", "dir"? }]`。迎戰海怪時一聲「全員就戰鬥位置！」，每個船員都會跑向其中一個位置，一人一個：

| 位置 | 誰去 |
|---|---|
| `captain` | 船長（船首欄杆） |
| `mate` | 大副，在船長旁邊 |
| `gun` | 水手，操砲（先補船首的砲） |
| `rig` | 水手，操帆索 |
| `ammo` | 水手，從貨艙搬彈藥上來 |
| `lookout` | 審查員（先上瞭望台），再來是水手 |

`gun` 位置會接手離它最近的砲（同層、200 以內）：戰鬥時那門砲會瞄準海怪，砲管朝船首斜指，砲彈從砲口飛出。不寫 `battle` 的話，遊戲會依房間自動產生：船長與大副在艏樓的船首端，艏樓與每座瞭望台上有瞭望位，每層砲甲板前半段的砲（不夠再往後），前方的帆索站位，以及貨艙前段的彈藥位。若自己寫 `battle`，一定要有 `captain` 與 `mate`，位置數量至少等於 `cap`；每個位置都要是空的地方，與同層其他位置相距至少 170。

**關卡。**格式檢查通過後，遊戲會把船真的蓋起來走一遍：每個房間、每個站位、每個戰鬥位置都要能從舵輪經由門、樓梯、梯子走到，而且戰鬥位置要夠每個船員各一個。沒通過的船會被拒絕，並列出走不到的地方。

### 4. 船員的外觀

船員是預先烘好的圖。模型有：`captain`、`firstmate`、`reviewer-1`、`robot`、`sailor-hammer`、`sailor-bandana`、`sailor-spyglass`。

- **換色**——`"palettes": { "<模型>": [ { "from": "#001860", "to": "#8a0c1c", "tolerance": 44 } ] }`。該模型每個跟 `from` 的 RGB 距離在 `tolerance`（0～160）以內的像素都換成 `to`，並依它原本的亮度調整，陰影因此保留。每個模型最多 16 組；第一組符合的生效。
- **換圖**——`"frames": { "<模型>": { "q.parts.torso": "data:image/png;base64,…" } }`。路徑是面向（`q` 四分之三側、`f` 正面），接 `parts.<部位>`、`heads.<表情>`、`hands.l.<手勢>`／`hands.r.<手勢>`，或 `whole`。新圖會畫在原本那張圖的框裡。
- **道具圖**——`"props": { "placard": "data:image/png;base64,…" }`：卷軸、旗子、決策旗、望遠鏡等等。

圖只能是 `data:image/png`、`webp` 或 `jpeg` 的 URI，絕不能是連結。

### 5. 文字與台詞

- **文字**——`"strings": { "en": { "welcome": "…" }, "zh-TW": { … }, "zh-CN": { … } }`。鍵是 HUD 自己的鍵（`welcome`、`playground`、`merged`、`rit.salvo`、`st.working`…；有點的鍵是某個群組裡的一項）。不認得的鍵就是錯誤。
- **台詞**——`"captions": { "Aye, captain.": { "en": "Aye aye, skipper!", "zh-TW": "…", "zh-CN": "…" } }`。鍵是舞台說的英文原句（橫幅與戰鬥提示），值是各語言要改說的話。

### 6. 在自己電腦上測試模組

1. 開一個本機伺服器：`cd voyage-2d && python3 -m http.server 8791`，再打開 `http://127.0.0.1:8791/game2d.html`（或直接打開建置好的 `artifact-2d.html`）。
2. 打開選單（☰）→ **設定** → **模組** → **載入模組檔…**，選你的 `.json`。也可以直接把檔案拖放到頁面上。遊戲會先檢查：通過就存在瀏覽器裡並重新載入頁面；沒通過就把錯誤列在模組那一列下面。
3. 同一列的 **恢復預設** 會把它忘掉。
4. `?mod=none` 表示不用任何模組；`?mod=<id>` 表示使用跟頁面一起打包的模組。要打包你的模組，把它放進 `voyage-2d/mods/` 再執行 `npm run build`（建置時會驗證每個打包的模組，有錯就停下來）。
5. 測試時好用的：`?crew=24`（滿員）、`?driver=0`（船員不亂跑）、`Z`（看整艘船）、`Q`（讓船長走遍你的房間）、滑鼠滾輪（縮放）。

### 7. 驗證模組

```
node tools/validate-mod.mjs mods/my-mod.json
```

它跟遊戲做一模一樣的檢查：通過會印出 `✓ … ok` 與摘要（甲板、房間、通道、砲、各種站位數量），沒通過會印出每個錯誤與它的位置，例如：

```
✗ mods/my-mod.json: refused (3 errors)
   mod: unknown key "colour" (allowed: format, id, name, version, author, description, ships, crew, strings, captions)
   mod.ships.classes[0].cap: expected a number, got the text "24"
   mod.ships.classes[0]: room steerage (main) cannot be reached from the helm
```

### 8. 範例一步一步看：大帆船

把 `mods/galleon.json` 開在旁邊。

1. **模組檔。**`format`、`id: "galleon"`、三種語言的 `name`。`ships.replace: true`：不論幾個人都只用大帆船，所以它的 `cap` 是 24。
2. **船殼。**`stern −5500`、`bow 5500`：長 11,000，比戰列艦還長一點。`keel 2320`、`waterline 1150`：兩層砲甲板（480 與 960）都在水面上。
3. **甲板。**四層高甲板給出範圍——船尾上方的 `castle`（−1440）、`poop`（−960）、`qd`（−480）與 `fore`（−480）——接著 `main`（0）、`gun`（480）、`gun2`（960）、`orlop`（1440）、`hold`（1920），這幾層自動取船殼的長度。艉樓的第三層就是多出來的那層甲板：舷緣會在它上面再抬一階。
4. **房間。**由船尾到船首、一層一層看：艉樓頂是 `open`（旗子掛在這裡）；它下面是 `chart` 海圖室，前面有門通往開放的艉樓甲板；再下面是 `cabin` 船長室，門通往 `helm` 舵輪。主甲板上：軍官艙（`quarters`）、舵艙（`workshop`）、開放的 `waist` 中甲板，以及艏樓下的 `galley` 廚房。上層砲甲板整層是 `gundeck`；下層是 `gundeck` 加上隔艙壁後面的水手長倉庫（`workshop`）；最下甲板是船員艙 `quarters` 與餐廳 `mess`；貨艙是 `cargo`。
5. **通道。**每座樓的前緣各有一道樓梯往下（`x` 在甲板盡頭，`dir` 朝中甲板）；中甲板有主樓梯和一道梯子下到砲甲板；之後每兩層之間各有一道樓梯與一道梯子，彼此錯開，也避開桅杆。
6. **桅杆。**四根：艉樓上的小後桅（3600）、後桅（4800）、主桅（6600）、前桅（5400），每根都有瞭望台。
7. **檢查：**`node tools/validate-mod.mjs mods/galleon.json` → 13 層甲板（含 4 座瞭望台）、20 個房間、16 條通道、47 門砲。試著弄壞它：把 steerage 的 `"fore"` 改成 `"wall"`，驗證器就會說舵艙與軍官艙走不到。
8. **玩玩看：**`?mod=galleon&crew=24`，按 `Z` 看整艘船。

### 9. 範例一步一步看：緋紅水手團

打開 `mods/crimson-crew.json`。

1. **沒有 `ships`：**預設的船不變。
2. **換色。**水手的海軍藍其實是三個很接近的顏色（`#001860`、`#181848`、`#181860`），各自換成亮度相當的緋紅。大副換同樣三色再加上他的藍色滾邊；船長的深色外套（`#181830`）換成深酒紅。想知道一張圖用了哪些顏色，可以在烘焙檔（`bake/sprites.json`）裡統計，或從截圖取色。
3. **換一張圖。**`crew.props.placard` 把船長在決策等著時舉起的牌子換成一面緋紅旗，畫在原本的框裡（212 × 496）。
4. **文字。**三種語言的 `welcome`。
5. **台詞。**以英文原句為鍵的三句舞台台詞："Aye, captain."、"Ahoy! Merged into main" 與 "Clearing, and a cheer"。
6. **檢查並玩玩看：**`node tools/validate-mod.mjs mods/crimson-crew.json`，再開 `?mod=crimson-crew&scene=decision`。

### 模組不能做的事，與原因

- **執行程式。**模組只會被 `JSON.parse` 讀進來，當成數字、短文字與圖片使用。沒有任何欄位能放程式、事件處理、公式或樣板。含 `<` 或 `>` 的文字一律拒絕，而且每段文字顯示時都會跳脫。頁面的內容安全政策（CSP）只允許頁面自己的程式包執行（建置時以雜湊值鎖定），並禁止 `eval`。
- **連網。**沒有任何欄位接受網址：圖片是檔案裡的 `data:` URI。CSP 禁止連到頁面本身以外的任何地方，建置也會拒絕含有任何網路程式碼（`fetch`、`XMLHttpRequest`、`WebSocket`、`sendBeacon`）的程式包。模組只能從玩家自己選的檔案載入，從不下載。
- **替船長做事。**模組不能回答決策、不能合併、不能擱置或放棄任何東西，也不能改看板。它只改變船與船員的樣子，以及舞台說的話。

原因：模組會在彼此不認識的人之間流傳；而在 Live 模式下，遊戲就放在船長的看板裡、就在真正的工作旁邊——合併卡的第一個選項是真的會合併。不能執行、不能回報、也不能按按鈕的資料，才能放心分享。
