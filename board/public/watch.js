// Whether firstmate is watched (T-137): the line under the counts, made from
// the server's `watch` and the page's own t(). One function that the page and
// tests/watch-line.spec.ts both run, so the words the captain reads, in either
// language, are the words the tests read.
//
//   watchLine(watch, t) -> { state: "on" | "off", parts: [text...], gap: text | null }
const WATCH = (() => {
  const fill = (text, values) =>
    Object.entries(values).reduce((out, [k, v]) => out.split(`{${k}}`).join(String(v ?? "")), String(text));
  function watchLine(w, t) {
    w = w || {};
    const parts = [
      w.alive ? fill(t("watchOn"), { n: w.beaconAge ?? 0 }) : t("watchOff"),
      w.lastWake ? fill(t("watchLast"), { reason: w.lastWake.reason, ts: w.lastWake.ts }) : t("watchNever"),
    ];
    if (w.waiting > 0) parts.push(fill(t("watchWaiting"), { n: w.waiting }));
    let gap = null;
    if (w.gap) gap = w.gap.since
      ? fill(t("watchGap"), { n: w.gap.inflight, since: w.gap.since })
      : fill(t("watchGapOpen"), { n: w.gap.inflight });
    return { state: w.alive ? "on" : "off", parts, gap };
  }
  return { watchLine };
})();
if (typeof module !== "undefined") module.exports = WATCH;
