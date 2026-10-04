// v3's synthesised sound (audio.js), plus v2.5's battle sounds and the victory cue.
// Everything is Web Audio oscillators and noise: no files, no network. Off by default.
import { Sound } from "../v3src/game/audio.js";

const NOTE = (n) => 440 * Math.pow(2, (n - 69) / 12); // MIDI note -> Hz

export class Sound2D extends Sound {
  whoosh(t) {
    const n = this._noise(0.45), f = this.ctx.createBiquadFilter(), g = this.ctx.createGain();
    f.type = "bandpass";
    f.frequency.setValueAtTime(400, t);
    f.frequency.exponentialRampToValueAtTime(3200, t + 0.3);
    this._env(g, t, 0.05, 0.25, 0.35);
    n.connect(f).connect(g).connect(this.master);
    n.start(t);
  }
  cutin(t) {
    this.whoosh(t);
    this._osc("sawtooth", 180, t, 0.3, 0.05).frequency.exponentialRampToValueAtTime(900, t + 0.25);
    this._osc("square", NOTE(88), t + 0.08, 0.16, 0.04);
  }
  parry(t) {
    for (const f of [1760, 2640, 3960]) this._osc("triangle", f, t, 0.45, 0.07);
    this._osc("square", 220, t, 0.08, 0.1);
  }
  impact(t) {
    this.cannon(t, 0.9);
    const n = this._noise(1.2), f = this.ctx.createBiquadFilter(), g = this.ctx.createGain();
    f.type = "lowpass";
    f.frequency.setValueAtTime(1800, t);
    f.frequency.exponentialRampToValueAtTime(60, t + 1.1);
    this._env(g, t, 0.003, 0.8, 1.1);
    n.connect(f).connect(g).connect(this.master);
    n.start(t);
    this._osc("sine", 55, t, 1.0, 0.6).frequency.exponentialRampToValueAtTime(28, t + 0.9);
  }
  rumble(t) {
    const n = this._noise(3.2), f = this.ctx.createBiquadFilter(), g = this.ctx.createGain();
    f.type = "lowpass";
    f.frequency.value = 140;
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(0.9, t + 2.6);
    g.gain.exponentialRampToValueAtTime(0.0001, t + 3.2);
    n.connect(f).connect(g).connect(this.master);
    n.start(t);
    const o = this._osc("sawtooth", 46, t, 3.0, 0.08);
    o.frequency.linearRampToValueAtTime(92, t + 3);
  }
  charge(t) {
    const o = this._osc("sawtooth", 220, t, 1.0, 0.05);
    o.frequency.exponentialRampToValueAtTime(1320, t + 1);
  }
  stampHit(t) {
    this.thud(t);
    this._osc("square", 110, t, 0.2, 0.2);
    this.chime(t + 0.05);
  }
  // the victory cue: ~9 s of heroic fanfare in C major, melody over a brass pad, a
  // marching bass, snare rolls and a timpani hit; distinct from the merge salvo
  victoryMusic(t0) {
    const bus = this.ctx.createGain();
    bus.gain.value = 0.9;
    bus.connect(this.master);
    const Q = 0.23; // a quaver
    const lead = (n, at, len, v = 0.1) => {
      for (const [type, det, vol] of [["square", 0, v], ["sawtooth", 7, v * 0.5]]) {
        const o = this.ctx.createOscillator(), g = this.ctx.createGain();
        o.type = type;
        o.frequency.value = NOTE(n);
        o.detune.value = det;
        g.gain.setValueAtTime(0.0001, at);
        g.gain.exponentialRampToValueAtTime(vol, at + 0.02);
        g.gain.setValueAtTime(vol, at + len * 0.7);
        g.gain.exponentialRampToValueAtTime(0.0001, at + len);
        o.connect(g).connect(bus);
        o.start(at);
        o.stop(at + len + 0.05);
      }
    };
    const pad = (notes, at, len) => { for (const n of notes) this._osc("sawtooth", NOTE(n), at, len, 0.028, bus); };
    const bass = (n, at, len) => this._osc("triangle", NOTE(n), at, len, 0.22, bus);
    const snare = (at, v = 0.25) => {
      const s = this._noise(0.18), f = this.ctx.createBiquadFilter(), g = this.ctx.createGain();
      f.type = "highpass";
      f.frequency.value = 1500;
      this._env(g, at, 0.002, v, 0.14);
      s.connect(f).connect(g).connect(bus);
      s.start(at);
    };
    const kick = (at) => this._osc("sine", 90, at, 0.25, 0.5, bus).frequency.exponentialRampToValueAtTime(40, at + 0.2);
    const timp = (at) => { this._osc("sine", 65, at, 1.6, 0.6, bus).frequency.exponentialRampToValueAtTime(55, at + 1.5); snare(at, 0.15); };
    // pickup: a snare roll into the downbeat
    for (let i = 0; i < 8; i++) snare(t0 + i * Q * 0.5, 0.08 + i * 0.03);
    const t = t0 + 4 * Q;
    timp(t);
    // melody (MIDI, quavers): G G G | C . . E D C | E . G . | C'' . . .
    const mel = [[67, 0, 1], [67, 1, 1], [67, 2, 1], [72, 3, 3], [76, 6, 1.5], [74, 7.5, 0.5], [72, 8, 1], [76, 9, 2], [79, 11, 3],
      [77, 14, 1], [76, 15, 1], [74, 16, 1], [72, 17, 1], [74, 18, 2], [67, 20, 2],
      [72, 22, 1], [72, 23, 1], [72, 24, 1], [76, 25, 2], [79, 27, 2], [84, 29, 6]];
    for (const [n, at, len] of mel) lead(n, t + at * Q, len * Q * 0.95);
    // harmony a third below on the big notes
    for (const [n, at, len] of mel) if (len >= 2) lead(n - 4, t + at * Q, len * Q * 0.95, 0.05);
    // pads: C | F | G | C
    const bars = [[[48, 55, 60, 64], 0], [[53, 57, 60, 65], 8], [[55, 59, 62, 67], 16], [[48, 55, 60, 64, 67], 24]];
    for (const [ch, at] of bars) pad(ch, t + at * Q, 8 * Q);
    // marching bass on the beats
    const roots = [36, 41, 43, 36];
    for (let b = 0; b < 4; b++) for (let i = 0; i < 8; i += 2) bass(roots[b] + (i === 6 ? 7 : 0), t + (b * 8 + i) * Q, Q * 1.8);
    // drums: kick on 1 and 3, snare on 2 and 4, a fill into the last bar
    for (let i = 0; i < 32; i += 2) (i % 4 === 0 ? kick : snare)(t + i * Q);
    for (let i = 0; i < 6; i++) snare(t + (29 + i * 0.5) * Q, 0.2);
    timp(t + 29 * Q);
    // the last chord rings with a cymbal wash
    const c = this._noise(2.5), cf = this.ctx.createBiquadFilter(), cg = this.ctx.createGain();
    cf.type = "highpass";
    cf.frequency.value = 5000;
    this._env(cg, t + 29 * Q, 0.01, 0.2, 2.4);
    c.connect(cf).connect(cg).connect(bus);
    c.start(t + 29 * Q);
  }
}
