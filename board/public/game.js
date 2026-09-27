// T-125: mounts and unmounts the Live 2.5D voyage inside the board. The
// game itself never gets the boards secret: only the tabs own session
// token (T-122), and only inside an iframe, so a full teardown - canvas,
// audio, every timer the game owns - is one DOM removal away, guaranteed by
// the browser rather than by anything this game chose to clean up after
// itself. The boss key (Esc Esc) and the visible Board button both call
// unmount(); nothing here ever talks to the board directly - the game does,
// through games/voyage-2d/src/boardsource.js, once it is mounted.
(function () {
  "use strict";
  let frame = null;
  let onBossKey = null;
  function onMessage(e) {
    if (!frame || e.source !== frame.contentWindow) return;
    if (e.origin !== location.origin) return;
    if (e.data && e.data.type === "voyage2d:boss-key" && onBossKey) onBossKey();
  }
  // opts: { base, token, project, onBossKey }. base is always same-origin
  // (the board itself); it is named only so boardsource.js never has to
  // guess it. The config travels in the iframe URL hash - the same place
  // the boards own one-time /login code travels - so it never reaches a
  // server log or the top windows own history.
  function mount(container, opts) {
    unmount();
    onBossKey = typeof opts.onBossKey === "function" ? opts.onBossKey : null;
    const cfg = { base: opts.base || "", token: opts.token || "", project: opts.project || null };
    const hash = encodeURIComponent(JSON.stringify(cfg));
    frame = document.createElement("iframe");
    frame.className = "voyage2dFrame";
    frame.setAttribute("title", "Voyage 2.5D");
    frame.setAttribute("allow", "autoplay");
    frame.src = "voyage2d/live.html#" + hash;
    addEventListener("message", onMessage);
    container.textContent = "";
    container.appendChild(frame);
    container.hidden = false;
  }
  // Removing the iframe destroys its whole browsing context at once: every
  // requestAnimationFrame loop, AudioContext and interval the game owned
  // stops immediately, with nothing left running - the same guarantee a
  // closed tab gives, without waiting on the games own cleanup code.
  function unmount() {
    removeEventListener("message", onMessage);
    if (frame) { frame.remove(); frame = null; }
    onBossKey = null;
  }
  window.VoyageGame = { mount, unmount };
})();
