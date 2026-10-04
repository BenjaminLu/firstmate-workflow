// Mods in the game: which one is loaded (a mod bundled with the page, picked with ?mod=<id> or in
// Settings; or the player's own file, picked with the file button or dropped on the page), the
// Settings row that shows it, and "reset to default". A mod file is read with the File API from
// the player's own disk: the page never fetches one, and the build refuses network code.
//
// Loading is at start-up: a chosen mod is kept (localStorage "v2d-mod") and the page reloads, so a
// mod's ship is built the way the game builds its own. A mod that fails validation is refused
// with its errors, and a kept one that no longer validates is dropped.
import { validateMod, modLayouts, MOD_FORMAT } from "./mod.js";
import { LAYOUTS, setLayouts } from "./layouts.js";
import { stringKeys, captionKeys, overrideStrings, overrideCaptions } from "./hud.js";
import BUNDLED from "./mods-data.js";

const KEY = "v2d-mod";
const T = {
  en: { mods: "Mods", none: "Default ship", load: "Load a mod file…", reset: "Reset to default", hint: "a voyage-mod/1 JSON file, or drop one on the page · data only: no scripts, no network", bad: "The mod was refused", ok: "Mod loaded", by: "by" },
  "zh-TW": { mods: "模組", none: "預設船艦", load: "載入模組檔…", reset: "恢復預設", hint: "voyage-mod/1 的 JSON 檔，或直接拖放到頁面上 · 只有資料：不能執行程式、不能連網", bad: "模組被拒絕", ok: "模組已載入", by: "作者" },
  "zh-CN": { mods: "模组", none: "默认船舰", load: "载入模组文件…", reset: "恢复默认", hint: "voyage-mod/1 的 JSON 文件，或直接拖放到页面上 · 只有数据：不能执行程序、不能联网", bad: "模组被拒绝", ok: "模组已载入", by: "作者" },
};
const opts = (bake) => ({ bake, stringKeys: stringKeys(), captionKeys: captionKeys() });
const store = {
  get() { try { return JSON.parse(localStorage.getItem(KEY) || "null"); } catch { return null; } },
  set(v) { try { v ? localStorage.setItem(KEY, JSON.stringify(v)) : localStorage.removeItem(KEY); return true; } catch { return false; } },
};
export const bundledMods = () => Object.values(BUNDLED);

// at start-up, before the HUD and the ship are made: the mod in play (or none), applied
export function startMod(Q, bake) {
  const out = { mod: null, source: null, errors: [] };
  const q = Q.get("mod");
  let pick = null;
  if (q === "none") return out;
  if (q) {
    if (BUNDLED[q]) pick = { kind: "bundled", id: q, mod: BUNDLED[q] };
    else out.errors.push(`?mod=${q}: no mod by that name is bundled with the page (${Object.keys(BUNDLED).join(", ") || "none"})`);
  } else {
    const s = store.get();
    if (s?.kind === "bundled" && BUNDLED[s.id]) pick = { kind: "bundled", id: s.id, mod: BUNDLED[s.id] };
    else if (s?.kind === "file" && typeof s.text === "string") pick = { kind: "file", id: null, mod: s.text };
  }
  if (!pick) return out;
  const r = validateMod(pick.mod, opts(bake));
  if (!r.ok) {
    out.errors.push(...r.errors);
    if (!q) store.set(null); // a kept mod that no longer validates is dropped
    return out;
  }
  applyMod(r.mod);
  return { mod: r.mod, source: pick.kind, errors: [] };
}
export function applyMod(mod) {
  const layouts = modLayouts(mod, LAYOUTS);
  if (layouts) setLayouts(layouts);
  overrideStrings(mod.strings);
  overrideCaptions(mod.captions);
}

// the Settings row, and what its buttons do
export class ModUI {
  constructor({ ui, bake, current }) {
    Object.assign(this, { ui, bake, current });
    this.errors = current.errors || [];
    this.input = document.getElementById("modFile");
    this.input?.addEventListener("change", () => { const f = this.input.files?.[0]; this.input.value = ""; if (f) this.readFile(f); });
    // a mod file dropped anywhere on the page
    addEventListener("dragover", (e) => { if ([...(e.dataTransfer?.items || [])].some((i) => i.kind === "file")) e.preventDefault(); });
    addEventListener("drop", (e) => { const f = e.dataTransfer?.files?.[0]; if (!f) return; e.preventDefault(); this.readFile(f); });
    if (this.errors.length) setTimeout(() => this.ui.toast(this.t.bad, { icon: "!", sub: this.errors[0], ms: 9000 }), 400);
  }
  get t() { return T[this.ui.lang] || T.en; }
  name(m) { const n = m?.name; return typeof n === "string" ? n : n?.[this.ui.lang] || n?.en || m?.id || ""; }
  async readFile(f) {
    let text = "";
    try { text = await f.text(); } catch (e) { return this.refuse([`could not read the file: ${e?.message || e}`]); }
    const r = validateMod(text, opts(this.bake));
    if (!r.ok) return this.refuse(r.errors);
    if (!store.set({ kind: "file", text })) return this.refuse(["this browser keeps nothing for the page (storage is off): open the page with ?mod=<id> for a mod bundled with it"]);
    this.reload(null);
  }
  refuse(errors) {
    this.errors = errors;
    this.ui.toast(this.t.bad, { icon: "!", sub: errors[0], ms: 9000 });
    this.ui.renderSheet?.(this.ui.s);
    return false;
  }
  // (a page opened with ?mod= keeps it in its address; picking another drops it)
  reload(mod) {
    const u = new URL(location.href);
    if (mod) u.searchParams.set("mod", mod);
    else u.searchParams.delete("mod");
    location.replace(u.toString());
  }
  act(v) {
    if (v === "file") return this.input?.click();
    if (v === "reset") { store.set(null); this.errors = []; return this.reload(null); }
    if (BUNDLED[v]) { store.set({ kind: "bundled", id: v }); return this.reload(null); }
  }
  row(row, esc) {
    const t = this.t, cur = this.current.mod;
    const list = bundledMods().map((m) => `<button data-set="mod" data-v="${esc(m.id)}" aria-pressed="${cur?.id === m.id}">${esc(this.name(m))}</button>`).join("");
    const errs = this.errors.length ? `<ul class="moderr">${this.errors.slice(0, 8).map((e) => `<li>${esc(e)}</li>`).join("")}${this.errors.length > 8 ? `<li>… +${this.errors.length - 8}</li>` : ""}</ul>` : "";
    const who = cur ? `<b data-mod="${esc(cur.id)}">${esc(this.name(cur))}${cur.author ? ` <small>${esc(t.by)} ${esc(cur.author)}</small>` : ""}</b>` : `<b data-mod="">${esc(t.none)}</b>`;
    return row(t.mods, `${who}${list}<button data-set="mod" data-v="file">${esc(t.load)}</button><button data-set="mod" data-v="reset"${cur || store.get() ? "" : " disabled"}>${esc(t.reset)}</button><small class="modhint">${esc(t.hint)}</small>${errs}`);
  }
}
export { MOD_FORMAT };
