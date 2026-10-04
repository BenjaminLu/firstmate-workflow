// Every sound is synthesised with WebAudio (no files), and all of it is off
// until the captain turns sound on (T-086: sound off by default).
export class Sound {
  constructor() {
    this.on = false;
    this.ctx = null;
    this.ambient = null;
  }
  enable(on) {
    this.on = on;
    if (on && !this.ctx) {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return;
      this.ctx = new AC();
      this.master = this.ctx.createGain();
      this.master.gain.value = 0.5;
      this.master.connect(this.ctx.destination);
    }
    if (this.ctx) on ? this.ctx.resume() : this.ctx.suspend();
    this.sea(on);
  }
  _noise(dur) {
    const n = Math.max(1, Math.floor(this.ctx.sampleRate * dur));
    const b = this.ctx.createBuffer(1, n, this.ctx.sampleRate);
    const d = b.getChannelData(0);
    let s = 7;
    for (let i = 0; i < n; i++) {
      s = (s * 16807) % 2147483647;
      d[i] = (s / 2147483647) * 2 - 1;
    }
    const src = this.ctx.createBufferSource();
    src.buffer = b;
    return src;
  }
  _env(g, t, a, peak, dcy) {
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(peak, t + a);
    g.gain.exponentialRampToValueAtTime(0.0001, t + a + dcy);
  }
  _osc(type, f, t, dur, peak = 0.3, dest = this.master) {
    const o = this.ctx.createOscillator();
    const g = this.ctx.createGain();
    o.type = type;
    o.frequency.setValueAtTime(f, t);
    this._env(g, t, 0.005, peak, dur);
    o.connect(g).connect(dest);
    o.start(t);
    o.stop(t + dur + 0.05);
    return o;
  }
  play(name, delay = 0) {
    if (!this.on || !this.ctx) return;
    const t = this.ctx.currentTime + delay;
    const f = this[name];
    if (typeof f === "function") f.call(this, t);
  }
  // ---------------------------------------------------------------- the sounds
  bell(t) {
    // an inharmonic ship's bell: partials 1, 2.4, 3, 4.5, 5.9 of 420 Hz
    for (const [r, a, d] of [[1, 0.35, 2.4], [2.4, 0.18, 1.6], [3, 0.12, 1.2], [4.5, 0.08, 0.8], [5.9, 0.05, 0.6]]) this._osc("sine", 420 * r, t, d, a);
  }
  whistle(t) {
    // bosun's call: a rising sweep, a trill, a fall (1.1 s)
    const o = this.ctx.createOscillator();
    const g = this.ctx.createGain();
    const lfo = this.ctx.createOscillator();
    const lg = this.ctx.createGain();
    o.type = "sine";
    o.frequency.setValueAtTime(1400, t);
    o.frequency.linearRampToValueAtTime(2300, t + 0.35);
    o.frequency.setValueAtTime(2300, t + 0.8);
    o.frequency.linearRampToValueAtTime(1600, t + 1.1);
    lfo.frequency.value = 22;
    lg.gain.setValueAtTime(0, t);
    lg.gain.setValueAtTime(60, t + 0.4);
    lfo.connect(lg).connect(o.frequency);
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(0.16, t + 0.05);
    g.gain.setValueAtTime(0.16, t + 1.0);
    g.gain.exponentialRampToValueAtTime(0.0001, t + 1.15);
    o.connect(g).connect(this.master);
    o.start(t);
    lfo.start(t);
    o.stop(t + 1.2);
    lfo.stop(t + 1.2);
  }
  cannon(t, gain = 0.6) {
    const n = this._noise(0.5);
    const lp = this.ctx.createBiquadFilter();
    lp.type = "lowpass";
    lp.frequency.setValueAtTime(900, t);
    lp.frequency.exponentialRampToValueAtTime(120, t + 0.34);
    const g = this.ctx.createGain();
    this._env(g, t, 0.004, gain, 0.34);
    n.connect(lp).connect(g).connect(this.master);
    n.start(t);
    const o = this._osc("sine", 70, t, 0.4, gain * 0.8);
    o.frequency.exponentialRampToValueAtTime(38, t + 0.35);
  }
  salvo(t) {
    for (let i = 0; i < 7; i++) this.cannon(t + i * 0.075, 0.6 - i * 0.03);
  }
  boom(t) {
    this.cannon(t, 0.8);
    this.cannon(t + 0.05, 0.5);
  }
  clang(t) {
    for (const f of [880, 1320, 2150]) this._osc("square", f, t, 0.25, 0.05);
    this.boom(t);
  }
  horn(t) {
    const o = this._osc("sawtooth", 82, t, 1.2, 0.14);
    o.frequency.linearRampToValueAtTime(70, t + 1.2);
  }
  tick(t) {
    this._osc("square", 1600, t, 0.05, 0.05);
    this._osc("square", 1600, t + 0.12, 0.05, 0.05);
  }
  rising(t) {
    this._osc("triangle", 520, t, 0.12, 0.08);
    this._osc("triangle", 780, t + 0.12, 0.12, 0.08);
  }
  chime(t) {
    for (const [f, d] of [[1568, 0], [2093, 0.06], [2637, 0.12]]) this._osc("sine", f, t + d, 0.9, 0.09);
  }
  splash(t) {
    const n = this._noise(0.8);
    const bp = this.ctx.createBiquadFilter();
    bp.type = "bandpass";
    bp.frequency.value = 900;
    const g = this.ctx.createGain();
    this._env(g, t, 0.02, 0.3, 0.7);
    n.connect(bp).connect(g).connect(this.master);
    n.start(t);
  }
  cheer(t) {
    for (let i = 0; i < 5; i++) {
      const o = this._osc("sawtooth", 300 + i * 70, t + i * 0.04, 0.6, 0.025);
      o.frequency.linearRampToValueAtTime(420 + i * 90, t + 0.5);
    }
  }
  fanfare(t) {
    // about four seconds: a brass arpeggio and a held chord
    const notes = [392, 523, 659, 784, 659, 784, 1046];
    notes.forEach((f, i) => this._osc("square", f, t + i * 0.22, 0.28, 0.06));
    for (const f of [523, 659, 784]) this._osc("sawtooth", f, t + 1.6, 2.2, 0.05);
  }
  fireworks(t) {
    for (let i = 0; i < 3; i++) {
      const n = this._noise(0.4);
      const hp = this.ctx.createBiquadFilter();
      hp.type = "highpass";
      hp.frequency.value = 2400;
      const g = this.ctx.createGain();
      this._env(g, t + i * 0.32, 0.005, 0.2, 0.35);
      n.connect(hp).connect(g).connect(this.master);
      n.start(t + i * 0.32);
      this.cannon(t + i * 0.32, 0.2);
    }
  }
  spark(t) {
    const n = this._noise(0.25);
    const hp = this.ctx.createBiquadFilter();
    hp.type = "highpass";
    hp.frequency.value = 3000;
    const g = this.ctx.createGain();
    this._env(g, t, 0.003, 0.15, 0.22);
    n.connect(hp).connect(g).connect(this.master);
    n.start(t);
  }
  thud(t) {
    this._osc("sine", 120, t, 0.18, 0.2);
  }
  paper(t) {
    const n = this._noise(0.3);
    const bp = this.ctx.createBiquadFilter();
    bp.type = "bandpass";
    bp.frequency.value = 4000;
    const g = this.ctx.createGain();
    this._env(g, t, 0.01, 0.08, 0.25);
    n.connect(bp).connect(g).connect(this.master);
    n.start(t);
  }
  sea(on) {
    if (!this.ctx) return;
    if (on && !this.ambient) {
      const n = this._noise(4);
      n.loop = true;
      const lp = this.ctx.createBiquadFilter();
      lp.type = "lowpass";
      lp.frequency.value = 500;
      const g = this.ctx.createGain();
      g.gain.value = 0.05;
      const lfo = this.ctx.createOscillator();
      const lg = this.ctx.createGain();
      lfo.frequency.value = 0.12;
      lg.gain.value = 0.03;
      lfo.connect(lg).connect(g.gain);
      n.connect(lp).connect(g).connect(this.master);
      n.start();
      lfo.start();
      this.ambient = { n, lfo };
    } else if (!on && this.ambient) {
      this.ambient.n.stop();
      this.ambient.lfo.stop();
      this.ambient = null;
    }
  }
}
