// The stage: sea, sky, the frigate, the crew (2.5D puppets riding the deck) and the
// kraken, composed back to front, with the effects on top. Crew live in ship space so
// they rock with her; effects live in world space.
import { Env, SEA_Y } from "./env.js";
import { Ship, CLASSES, classFor } from "./ship.js";
import { Kraken } from "./kraken.js";
import { FX } from "./fx.js";
import { Puppet } from "./puppet.js";
import { Crowd, planRest, fileSegments, restFile, levelIds, linkPoint, linkSteep, Z_SCREEN, DEPTH, GAP } from "../v3src/sim/deckplan.js";

// the cast (the captain's brief): the firstmate is a young officer; the robot is worker-4;
// the workers hired after them take the three sailors' looks in turn
const MODEL = { captain: "captain", firstmate: "firstmate", "reviewer-1": "reviewer-1", "worker-4": "robot" };
const SAILORS = ["sailor-hammer", "sailor-bandana", "sailor-spyglass"];
const lerp = (a, b, k) => a + (b - a) * k;
// each model's drawn box at rest, in baked px about the feet, facing right: the widest over its
// idle loops (captain idle and helm, firstmate helm, hands leaning), from tools/crewfoot.mjs
const FOOT = {
  captain: [-215, 265], firstmate: [-128, 177], "reviewer-1": [-121, 110], robot: [-106, 173],
  "sailor-bandana": [-124, 177], "sailor-spyglass": [-98, 158], "sailor-hammer": [-121, 173], worker: [-124, 177],
};
const FOOT_R = 26; // a crewman's footprint on deck (a circle in x and z), at crew scale 1

export class World {
  constructor({ bake, images, low = false, crewCount = 7 }) {
    this.low = low;
    this.env = new Env({ low });
    this.ship = new Ship({ low, cls: classFor(crewCount) });
    this.kraken = new Kraken({ low });
    this.fx = new FX({ low });
    this.crew = {};
    this.leaving = [];
    this.bake = bake;
    this.images = images;
    // the walking crew on the ship's decks (the shared, deterministic model)
    this.crowd = new Crowd(this.ship.G);
    this.claims = {}; // station id -> worker id, for the hands at work
    this.suspended = false; // the hero ending places the crew itself
  }
  get cls() { return this.ship.cls; }
  get level() { return CLASSES.indexOf(this.ship.cls); }
  get G() { return this.ship.G; }
  // ---------------------------------------------------------------- where everyone rests
  // Every crewman has his own spot, and no two drawn boxes overlap at rest: the captain at the
  // helm, the firstmate forward of him (clearly apart), the reviewer on the forecastle, hands at
  // work at their stations (a gun, the rigging, the lookout), idle hands at their homes (the
  // waist first, then the hold, then the gun decks). Each deck (the three topside decks as one
  // row) keeps its crew GAP apart by their drawn widths; if a row cannot hold them at full size,
  // the crew is drawn smaller (fit), as before.
  home(p) {
    const at = this.plan().at[p.id];
    return at ? { x: at.x, dir: at.dir, off: 0, deck: at.deck, z: at.z } : { x: this.ship.cls.main[0], dir: 1, off: 0, deck: "main", z: 38 };
  }
  foot(p, dir = 1) {
    const f = FOOT[p.bakeKey] || FOOT.worker, k = p.baseScale * this.ship.cls.crewScale * this.plan().fit;
    return dir >= 0 ? [f[0] * k, f[1] * k] : [-f[1] * k, -f[0] * k];
  }
  get fit() { return this.plan().fit; }
  // the stable homes of the idle hands for this ship and this many hands
  homes(n) {
    const G = this.G, key = G.spec.id + "|" + n;
    if (this._homes?.key === key) return this._homes.list;
    const list = [];
    const segs = (deck) => fileSegments(G, restFile(G, deck), FOOT_R * this.ship.cls.crewScale).filter((s) => s[2] === deck);
    const near = (deck, x) => G.stations.some((s) => s.deck === deck && s.kind !== "lookout" && Math.abs(s.x - x) < 150);
    for (const deck of ["main", ...levelIds(G.spec).slice().reverse(), "fore"]) {
      if (!G.decks[deck]) continue;
      const step = deck === "main" ? 200 : 210;
      for (const [a, b] of segs(deck)) for (let x = a + 40; x <= b - 20; x += step) if (deck === "main" || !near(deck, x)) list.push({ deck, x });
    }
    // the waist first, spread along it; then the hold, the gun decks, the forecastle
    return (this._homes = { key, list }).list;
  }
  // the station spots of a kind, for the sim's decks: top -> the lookout, amidships -> the
  // rigging, main -> the guns
  claim(p, station) {
    for (const [k, v] of Object.entries(this.claims)) if (v === p.id) delete this.claims[k];
    const kind = { top: "lookout", amidships: "rig", main: "gun" }[station];
    if (!kind) return null;
    const G = this.G, slot = p.slot ?? 0;
    for (const k of kind === "lookout" ? ["lookout", "rig"] : [kind, "rig", "gun"]) {
      const spots = G.stations.filter((s) => s.kind === k);
      for (let i = 0; i < spots.length; i++) {
        const s = spots[(slot * 3 + i) % spots.length];
        if (!this.claims[s.id]) { this.claims[s.id] = p.id; return s; }
      }
    }
    return null;
  }
  stationOf(id) { for (const [k, v] of Object.entries(this.claims)) if (v === id) return this.G.stations.find((s) => s.id === k); return null; }
  plan() {
    const S = this.ship.cls, G = this.G;
    const all = Object.values(this.crew);
    const key = S.id + "|" + all.map((p) => p.id + ":" + (p.slot ?? "") + ":" + (this.stationOf(p.id)?.id ?? "")).join(",");
    if (this._plan?.key === key && this._plan.G === G) return this._plan;
    const workers = all.filter((p) => p.role === "worker").sort((a, b) => (a.slot ?? 99) - (b.slot ?? 99));
    const homes = this.homes(workers.length);
    const st = (kind) => G.stations.find((s) => s.kind === kind);
    const items = all.map((p) => {
      let want;
      if (p.id === "captain") want = st("helm");
      else if (p.id === "firstmate") want = st("mate");
      else if (p.id === "reviewer-1") want = st("review");
      else {
        const s = this.stationOf(p.id);
        const i = workers.indexOf(p), h = homes[i % Math.max(1, homes.length)];
        want = s || { deck: h?.deck || "main", x: h ? h.x + (i >= homes.length ? 60 : 0) : S.main[0], dir: i % 2 ? -1 : 1 };
      }
      const dir = want.dir ?? 1, f = FOOT[p.bakeKey] || FOOT.worker, k = p.baseScale * S.crewScale;
      return { id: p.id, deck: want.deck, x: want.x, dir, ext: dir >= 0 ? [f[0] * k, f[1] * k] : [-f[1] * k, -f[0] * k], f: FOOT_R * S.crewScale, gapL: p.id === "firstmate" ? 60 : GAP, rank: p.id === "captain" ? 0 : p.id === "firstmate" ? 1 : 2, weight: p.id === "captain" ? 40 : 1, pin: p.id === "captain" ? 30 : null };
    });
    const r = planRest(G, items);
    return (this._plan = { key, G, fit: r.fit, at: r.at });
  }
  workerCount() { return Object.values(this.crew).filter((q) => q.role === "worker").length; }
  // ---------------------------------------------------------------- walking
  agent(id) { return this.crowd.get(id); }
  // bring the crowd onto the ship's current decks (after a class change)
  syncDecks() {
    if (this.crowd.G === this.ship.G) return false;
    this.claims = {};
    this._plan = null;
    for (const a of this.crowd.agents.values()) a.r = FOOT_R * this.ship.cls.crewScale * (a.id === "captain" ? 1.15 : 1);
    this.crowd.setGeometry(this.ship.G);
    return true;
  }
  // send a crewman to his spot (a station of the sim's deck, or his home); then his loop
  sendTo(p, station, action, { loop = true } = {}) {
    if (!p || this.suspended) return false;
    this.syncDecks();
    if (station && station !== "idle") this.claim(p, station);
    else for (const [k, v] of Object.entries(this.claims)) if (v === p.id) delete this.claims[k];
    return this.walkHome(p, () => {
      if (!loop) return;
      p.setLoop(action || (p.role === "worker" ? "lean" : p.id === "firstmate" ? "helm" : "idle"));
    });
  }
  walkHome(p, then) {
    const h = this.home(p), a = this.agent(p.id);
    if (!a) return false;
    a.manual = null;
    this.crowd.goTo(p.id, { deck: h.deck, x: h.x, z: h.z, dir: h.dir }, () => { p.dir = h.dir; then?.(); });
    return true;
  }
  // bring the stage's crew in line with the board's: new hands come aboard, leavers go;
  // returns the new class when the ship has to change to fit them
  syncCrew(simCrew) {
    const ids = new Set(simCrew.map((c) => c.id));
    for (const [id, p] of Object.entries(this.crew)) if (!ids.has(id)) (p.leaving = 1), this.leaving.push(p), delete this.crew[id], this.crowd.remove(id);
    const fresh = [];
    for (const c of simCrew) {
      if (this.crew[c.id]) continue;
      const p = this._puppet(c);
      if (!p) continue;
      this.crew[c.id] = p;
      fresh.push(p);
    }
    // worker slots in hiring order
    Object.values(this.crew).filter((q) => q.role === "worker").sort((a, b) => (parseInt(a.id.split("-")[1], 10) || 0) - (parseInt(b.id.split("-")[1], 10) || 0)).forEach((q, i) => (q.slot = i));
    this.syncDecks();
    for (const p of fresh) {
      const h = this.home(p);
      const pri = p.id === "captain" ? 0 : p.id === "firstmate" ? 1 : p.id === "reviewer-1" ? 2 : 10 + (p.slot ?? 0);
      const a = this.crowd.add(p.id, { deck: h.deck, x: h.x, z: h.z, r: FOOT_R * this.ship.cls.crewScale * (p.id === "captain" ? 1.15 : 1), pri, dir: h.dir });
      p.x = a.x;
      p.dir = h.dir;
      p.y = this.ship.levelY(a.deck) - a.z * Z_SCREEN;
      p.scale = p.baseScale * this.ship.cls.crewScale * this.fit;
      if (p.role === "worker") p.setLoop("lean");
      p.alpha = 0; // new hands come aboard: they fade in once the ship has room for them
      p.arriving = true;
    }
    const want = classFor(simCrew.length);
    return want !== this.ship.cls ? want : null;
  }
  // every crewman walks to his (re-planned) spot, e.g. after the ship changes class: hands at
  // work to their stations, the rest to their homes
  regroup(sim) {
    this.syncDecks();
    if (sim) for (const c of sim.crew) {
      const p = this.crew[c.id];
      if (p?.role === "worker" && c.station && c.station !== "idle" && c.state !== "idle" && !this.stationOf(p.id)) this.claim(p, c.station);
    }
    for (const p of Object.values(this.crew)) {
      const c = sim?.crew.find((x) => x.id === p.id), a = this.agent(p.id);
      if (!a || a.manual || (p.id === "captain" && this.control?.on)) continue;
      const h = this.home(p);
      if (p.arriving && p.alpha < 0.05) {
        const q = this.crowd.free(h.deck, h.x, h.z, a.r, a) ? { deck: h.deck, x: h.x, z: h.z } : null;
        if (q) Object.assign(a, q), (a.goal = null), (a.plan = null), (p.x = h.x), (p.dir = h.dir);
        else this.walkHome(p);
        continue;
      }
      const busy = p.role === "worker" && c && c.state !== "idle" && c.action;
      this.walkHome(p, () => p.setLoop(busy ? c.action : p.role === "worker" ? "lean" : p.id === "firstmate" ? "helm" : "idle"));
    }
  }
  addCrew(simCrew) { this.syncCrew(simCrew); }
  // the hero ending lines the crew up on the waist by itself; walking resumes after it
  suspend() {
    this.suspended = true;
    for (const p of Object.values(this.crew)) {
      const a = this.agent(p.id);
      if (a) (a.manual = null), this.crowd.stop(p.id);
      p.locoExt = false;
      if (p.climbing) (p.climbing = false), p.setLoop(p.preClimb || "idle");
      p.x = Math.max(this.ship.spec.main[0] + 60, Math.min(this.ship.spec.main[1] - 60, p.x));
      p.deckOff = 0;
    }
  }
  resume(sim) {
    if (!this.suspended) return;
    this.suspended = false;
    // everyone steps back into the crowd where he stands on the waist, then walks home
    for (const p of Object.values(this.crew)) {
      const a = this.agent(p.id);
      if (!a) continue;
      a.link = null;
      a.deck = "main";
      a.x = p.x;
      a.z = p.deckOff ? DEPTH - 80 : 60;
      a.placed = false;
    }
    for (const a of this.crowd.order()) {
      const d = this.G.decks.main;
      a.x = Math.max(d.x0 + a.r, Math.min(d.x1 - a.r, a.x));
      if (!this.crowd.free(a.deck, a.x, a.z, a.r, a, true)) { const q = this.crowd.findFree(a.deck, a.x, a.z, a.r, a, true); if (q) Object.assign(a, q); }
      a.placed = true;
    }
    this.regroup(sim);
  }
  deckY(x) { return this.ship.deckY(x); }
  _puppet(c) {
    const key = MODEL[c.id] || (c.role === "worker" ? SAILORS[(parseInt(c.id.split("-")[1], 10) || 1) % 3] : c.model);
    const b = this.bake.crew[key];
    if (!b) return null;
    const base = key === "captain" ? 0.6 : 0.56;
    const p = new Puppet(c.id, b, this.images.crew[key], { props: this.images.props, scale: base * this.ship.cls.crewScale * (this._plan?.fit ?? 1) });
    p.baseScale = base;
    p.role = c.role;
    p.name = c.id === "captain" ? "Captain" : c.id === "firstmate" ? "Firstmate" : c.name;
    p.bakeKey = key;
    if (c.id === "firstmate") p.setLoop("helm");
    if (key === "robot") p.workProp = "laptop";
    return p;
  }
  // the puppets follow their footprints: along the deck, up and down the stairs, ladders and
  // shrouds (the climbing loop on the steep parts); idle hands drift back to their spots
  follow(dt) {
    const C = this.crowd;
    for (const p of Object.values(this.crew)) {
      const a = C.get(p.id);
      if (!a) continue;
      let x = a.x, y, climb = false, dir = a.dir;
      if (a.link) {
        const l = a.link, [lx, ly] = linkPoint(l.L, l.s, l.rev), k = l.s / Math.max(1, l.L.len);
        const z = l.from.z + (l.to.z - l.from.z) * k;
        x = lx;
        y = ly - z * Z_SCREEN;
        climb = linkSteep(l.L, l.s, l.rev);
        const [nx] = linkPoint(l.L, Math.min(l.L.len, l.s + 20), l.rev);
        if (Math.abs(nx - lx) > 1) dir = nx > lx ? 1 : -1;
      } else y = this.ship.levelY(a.deck) - a.z * Z_SCREEN;
      // the ground speed for the walk: the footprint's own motion (x and depth on a deck, the
      // path on a stair), low-passed so the crowd's per-frame nudges (a side step, giving way,
      // pressing into a wall) average out instead of reading as steps; a jump (a slip, a class
      // change) is not a step at all
      const onDeck = !a.link && !p.wasLink && p.lastDeck === a.deck;
      let vx = onDeck ? a.x - (p.ax ?? a.x) : x - p.x, vz = onDeck ? (a.z - (p.az ?? a.z)) * 0.8 : (y - p.y) * 0.6;
      if (Math.hypot(vx, vz) > 40 || !(dt > 0)) (vx = 0), (vz = 0);
      const lp = dt > 0 ? Math.min(1, dt * 16) : 0;
      p.vx = (p.vx || 0) + ((dt > 0 ? vx / dt : 0) - (p.vx || 0)) * lp;
      p.vz = (p.vz || 0) + ((dt > 0 ? vz / dt : 0) - (p.vz || 0)) * lp;
      p.ax = a.x; p.az = a.z; p.lastDeck = a.deck; p.wasLink = !!a.link;
      p.x = x;
      p.y = y;
      p.locoExt = !climb;
      p.locoSpeed = climb ? 0 : Math.hypot(p.vx, p.vz);
      // the facing follows where he means to go (the stick, the next waypoint, the stair), not
      // the crowd's per-frame side steps; a change has to hold a moment before he turns
      let want = p.dir;
      if (a.link) want = dir;
      else if (a.manual?.vx) want = Math.sign(a.manual.vx);
      else if (a.goal && a.plan && !(a.yieldFrom && C.t < a.yieldUntil)) {
        const wp = a.plan[0]?.walk?.[0];
        if (wp && Math.abs(wp[0] - a.x) > 6) want = wp[0] > a.x ? 1 : -1;
      } else if (!a.goal && !a.moving && a.idleT < 0.05 && !p.shots.length) want = a.dir;
      if (want !== p.dir) {
        p.turnHold = (p.turnHold || 0) + dt;
        if (a.manual?.vx || a.link || !a.moving || p.turnHold > 0.12) (p.dir = want), (p.turnHold = 0);
      } else p.turnHold = 0;
      if (climb && !p.climbing) (p.climbing = true), (p.preClimb = p.loop), p.setLoop("climb");
      else if (!climb && p.climbing) (p.climbing = false), p.setLoop(p.preClimb || "idle");
      p.aloft = a.deck === "nest" || (a.link?.L.kind === "shrouds");
      // a slip past a jam reads as a quick fade
      if (a.slipped != null && C.t - a.slipped < 0.35 && !p.arriving) p.alpha = Math.min(1, 0.35 + (C.t - a.slipped) * 2);
      else if (!p.arriving && p.alpha < 1) p.alpha = Math.min(1, p.alpha + dt * 3);
      // an idle hand who has been pushed or left off his spot walks back to it
      if (!a.goal && !a.link && !a.manual && a.idleT > 1.5 && !(p.id === "captain" && this.control?.on)) {
        const h = this.home(p);
        if (h.deck !== a.deck || Math.hypot(h.x - a.x, h.z - a.z) > 8) this.walkHome(p);
      }
    }
  }
  // a crewman's point in world space
  at(p, joint = "head", dx = 0, dy = 0) {
    const [x, y] = p.jointAt(joint, dx, dy);
    return this.ship.toWorld(x, y);
  }
  sectionWorld(i) { const xs = this.ship.sections; return this.ship.toWorld(xs[i % xs.length], -10); }
  update(dt) {
    this.env.update(dt);
    this.ship.update(dt, this.env);
    this.kraken.update(dt);
    const cs = this.ship.cls.crewScale * this.fit;
    if (!this.suspended) {
      this.syncDecks();
      this.crowd.step(dt);
      this.follow(dt);
    }
    for (const p of Object.values(this.crew)) {
      p.update(dt);
      p.scale += (p.baseScale * cs - p.scale) * Math.min(1, dt * 4);
      if (this.suspended && !p.walk) p.y += (this.deckY(p.x) + (p.deckOff || 0) - p.y) * Math.min(1, dt * 12);
    }
    // new hands fade in (after the ship has finished growing to fit them)
    if (!this.ship.transforming) for (const p of Object.values(this.crew)) if (p.arriving) (p.alpha = Math.min(1, p.alpha + dt * 1.6)), p.alpha >= 1 && (p.arriving = false);
    // leavers fade out where they stand
    for (const p of this.leaving) (p.update(dt), (p.alpha = Math.max(0, p.alpha - dt * 1.5)));
    this.leaving = this.leaving.filter((p) => p.alpha > 0);
    // the kraken keeps its distance off the bow, whatever the ship's size
    this.kraken.x += (this.ship.spec.bow + 520 - this.kraken.x) * Math.min(1, dt * 2);
    this.fx.wind = this.env.storm * 2 + this.env.speed;
    this.kraken.viewScale = this.fx.viewScale;
  }
  drawTags(ctx, cam, list) {
    // name tags, readable in the wide shot, gone in close-ups: the name and a small flag in the
    // project's colour, nothing else (the rest is on the detail card). They never overlap: a tag
    // that would collide steps up a row, then shrinks, and is left out if there is still no room.
    const z = cam.zoom, pa = Math.max(0, Math.min(1, (0.62 - z) / 0.18));
    if (pa > 0.02 && !this.hidePennants) {
      const k = 1 / z, small = ctx.canvas.clientWidth < 720;
      ctx.font = `800 ${small ? 11 : 13}px 'Barlow Semi Condensed', system-ui, sans-serif`;
      const tags = list.filter((p) => p.alpha > 0.5 && !p.leaving).map((p) => ({ p, w: (ctx.measureText(p.name).width + 30) * k, x: p.x, y: p.y - p.height - 34 * k })).sort((a, b) => a.x - b.x);
      const placed = [], H = 26 * k;
      const free = (x, y, w) => placed.every((o) => Math.abs(o.x - x) > (o.w + w) / 2 + 3 * k || Math.abs(o.y - y) > H);
      for (const t of tags) {
        search: for (const sc of [1, 0.8]) for (let r = 0; r < 3; r++) {
          const w = t.w * sc, y = t.y - r * H;
          if (free(t.x, y, w)) { placed.push({ x: t.x, y, w }); t.row = r; t.sc = sc; break search; }
        }
        if (t.row !== undefined) pennant(ctx, t.p, k * t.sc, pa, t.row * H / (k * t.sc), this.projectCol?.(t.p.id), small);
      }
      this.tagsShown = tags.filter((t) => t.row !== undefined).map((t) => ({ id: t.p.id, x: t.x, y: t.y - t.row * H, w: t.w * t.sc, h: H }));
    } else this.tagsShown = [];
  }
  draw(ctx, cam) {
    const v = cam.view(), c = { x: cam.x.x, y: cam.y.x };
    const E = this.env, K = this.kraken, S = this.ship, F = this.fx;
    E.drawSky(ctx, v, c);
    E.drawFar(ctx, v, c);
    if (F.fire.length) F.drawFireworks(ctx, true);
    if (this.behindHook) this.behindHook(ctx);
    K.drawArms(ctx, { front: false });
    K.drawBody(ctx);
    E.drawMid(ctx, v);
    S.drawBack(ctx);
    if (E.night > 0.02) {
      // night over the ship's back: the lit crew and the fireworks pop against it
      ctx.fillStyle = `rgba(8,10,40,${0.45 * E.night})`;
      ctx.fillRect(v.x0, v.y0, v.x1 - v.x0, SEA_Y - v.y0);
    }
    F.drawFireworks(ctx);
    // the crew, in ship space, far deck first; relit by the scene (storm, maelstrom, night,
    // the hero light) through one filtered blit of their own layer
    S.enter(ctx);
    const list = [...Object.values(this.crew), ...this.leaving].sort((a, b) => (a.aloft ? -1 : 0) - (b.aloft ? -1 : 0) || a.y - b.y);
    const light = this.low ? "" : crewLight(E, this.heroLight || 0);
    if (light) {
      const L = (this.crewLayer ||= document.createElement("canvas"));
      if (L.width !== ctx.canvas.width || L.height !== ctx.canvas.height) (L.width = ctx.canvas.width), (L.height = ctx.canvas.height);
      const lx = L.getContext("2d");
      lx.setTransform(1, 0, 0, 1, 0, 0);
      lx.clearRect(0, 0, L.width, L.height);
      lx.setTransform(ctx.getTransform());
      for (const p of list) p.draw(lx);
      ctx.save();
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.filter = light;
      ctx.drawImage(L, 0, 0);
      ctx.restore();
    } else for (const p of list) p.draw(ctx);
    ctx.restore();
    S.drawFront(ctx);
    K.drawArms(ctx, { front: true });
    F.drawWaves(ctx);
    // the near sea is cut away where the hull is, like the hull itself: the section runs down
    // through the water, tinted below the waterline
    ctx.save();
    S.clipOutHull(ctx, v);
    E.drawNear(ctx, v);
    ctx.restore();
    S.drawWater(ctx, E);
    // the name tags go over everything on the ship (the cutaway's guns included)
    S.enter(ctx);
    this.drawTags(ctx, cam, list);
    ctx.restore();
    F.draw(ctx);
    F.drawFlyers(ctx);
    F.drawNumbers(ctx);
  }
}
export { SEA_Y };

// the crew's scene light as one canvas filter: colder and flatter in a squall, blood-red in
// the maelstrom, blue at night, and a warm rim glow in the hero light
function crewLight(E, hero) {
  const f = [];
  if (E.storm > 0.05) f.push(`brightness(${(1 - 0.22 * E.storm).toFixed(2)}) saturate(${(1 - 0.35 * E.storm).toFixed(2)})`);
  if (E.ult > 0.05) f.push(`sepia(${(0.45 * E.ult).toFixed(2)}) hue-rotate(${(-28 * E.ult).toFixed(0)}deg) saturate(${(1 + 0.6 * E.ult).toFixed(2)})`);
  if (E.night > 0.05) f.push(`brightness(${(1 - 0.18 * E.night).toFixed(2)}) hue-rotate(${(14 * E.night).toFixed(0)}deg)`);
  if (hero > 0.05) f.push(`drop-shadow(0 0 7px rgba(255,210,120,${(0.95 * hero).toFixed(2)}))`);
  return f.join(" ");
}
function pennant(ctx, p, k, a, lift = 0, col = null, small = false) {
  const x = p.x, y = p.y - p.height - 34 * k;
  ctx.save();
  ctx.globalAlpha = a;
  ctx.translate(x, y);
  ctx.scale(k, k);
  ctx.translate(0, -lift);
  const fs = small ? 11 : 13;
  ctx.font = `800 ${fs}px 'Barlow Semi Condensed', system-ui, sans-serif`;
  const w = ctx.measureText(p.name).width + 30, h = fs + 8;
  if (lift) (ctx.strokeStyle = "rgba(0,0,0,.6)"), (ctx.lineWidth = 2), ctx.beginPath(), ctx.moveTo(0, h / 2), ctx.lineTo(0, h / 2 + lift), ctx.stroke();
  ctx.fillStyle = "#0c0608";
  ctx.fillRect(-w / 2 - 2, -h / 2 - 2, w + 4, h + 4);
  ctx.fillStyle = "#fff";
  ctx.fillRect(-w / 2, -h / 2, w, h);
  // the project flag (grey when the hand has no task)
  ctx.fillStyle = col || "#b8b2a6";
  ctx.beginPath();
  ctx.moveTo(-w / 2 + 5, -h / 2 + 3);
  ctx.lineTo(-w / 2 + 19, -h / 2 + 3);
  ctx.lineTo(-w / 2 + 14, 0);
  ctx.lineTo(-w / 2 + 19, h / 2 - 3);
  ctx.lineTo(-w / 2 + 5, h / 2 - 3);
  ctx.fill();
  ctx.fillStyle = "#0c0608";
  ctx.textAlign = "left";
  ctx.textBaseline = "middle";
  ctx.fillText(p.name, -w / 2 + 23, 0);
  ctx.restore();
}
