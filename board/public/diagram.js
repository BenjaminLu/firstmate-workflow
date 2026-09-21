// The decision diagram, embedded. The board never draws one: a diagram is a
// file bin/fm-diagram.sh wrote, in each of the three languages, and all the
// page has to know is where it lives and when to move.
//
// One function builds the src. The card that first shows a diagram and the
// language switch that swaps it both call it, so they cannot end up pointing
// at different files - the bug where a reader switches to English and gets
// the Chinese drawing because the swap spelled the path itself.
//
// A decision may have no diagram: a routine event never produced one, and an
// old decision predates the generator. The src is therefore set only after a
// HEAD says the file is there; otherwise the iframe is removed, because an
// iframe showing the server's 404 page is worse than no iframe.

const DIAGRAM = (() => {
  const LANGS = ["en", "zh-TW", "zh-CN"];
  const DIR = "diagrams/";
  const isDecision = (id) => /^D-[0-9]{1,6}$/.test(String(id ?? ""));

  const src = (id, lang) =>
    isDecision(id) ? DIR + id + "." + (LANGS.includes(lang) ? lang : "zh-TW") + ".html" : "";

  // hidden and without a src: mount decides whether it is shown at all
  const embed = (id) => isDecision(id)
    ? `<iframe class="dg" data-decision="${id}" title="${id}" loading="lazy" hidden></iframe>`
    : "";

  const decisionOf = (el) =>
    (el.dataset && el.dataset.decision) || el.getAttribute("data-decision");

  // Point every embedded diagram at the file for this language. Called after
  // a render and again when the reader switches, so it is also the swap.
  // Returns how many it moved, which is what the suite can see.
  async function mount(root, lang, fetcher) {
    const get = fetcher || (typeof fetch === "function" ? fetch : null);
    const frames = root ? Array.from(root.querySelectorAll("iframe.dg")) : [];
    let moved = 0;
    for (const el of frames) {
      const want = src(decisionOf(el), lang);
      if (!want || el.getAttribute("src") === want) continue;
      let there = false;
      try { there = !!get && (await get(want, { method: "HEAD" })).ok; } catch (_) { there = false; }
      if (!there) { el.remove(); continue; }
      el.setAttribute("src", want);
      el.removeAttribute("hidden");
      moved++;
    }
    return moved;
  }

  return { LANGS, src, embed, mount, isDecision };
})();
if (typeof module !== "undefined") module.exports = DIAGRAM;
