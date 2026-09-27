// Turn a baked (soft, smoothly lit) sprite into the game's one look: flat cel shading in
// three hard tones, shadows pushed toward the P5 red-black, saturated mid tones, black ink
// lines on the inner edges (where the tone or the colour breaks) and a heavy outline round
// the silhouette. Runs once per sprite at load; the result is a canvas drawImage takes.
//
//   mangaize(image, { outline: px, ink: 0..1, red: 0..1, tones: [dark, mid, light] })
const clamp = (v) => (v < 0 ? 0 : v > 255 ? 255 : v);

export function mangaize(src, { outline = 5, ink = 1, red = 0.35, tones = [0.38, 0.72, 1.0], sat = 1.3, edge = 60 } = {}) {
  const pad = outline + 2;
  const w = (src.naturalWidth || src.width) + pad * 2, h = (src.naturalHeight || src.height) + pad * 2;
  const c = document.createElement("canvas");
  c.width = w;
  c.height = h;
  const x = c.getContext("2d", { willReadFrequently: true });
  x.drawImage(src, pad, pad);
  const img = x.getImageData(0, 0, w, h), d = img.data;
  const V = new Float32Array(w * h), A = new Uint8Array(w * h), H = new Float32Array(w * h);
  // 1. cel tones: quantise the value into three hard steps, keep and push the hue
  for (let i = 0, p = 0; p < w * h; p++, i += 4) {
    const a = d[i + 3];
    A[p] = a > 40 ? 1 : 0;
    if (!A[p]) continue;
    let r = d[i], g = d[i + 1], b = d[i + 2];
    const mx = Math.max(r, g, b), mn = Math.min(r, g, b), v = mx / 255;
    V[p] = v;
    H[p] = (r * 3 + g * 5 + b * 7) / 255; // a cheap colour signature for the colour edges
    if (v < 0.16) { // ink stays ink
      d[i] = d[i + 1] = d[i + 2] = 12;
      continue;
    }
    const step = v < 0.42 ? tones[0] : v < 0.74 ? tones[1] : tones[2];
    // saturate about the grey
    const grey = (r + g + b) / 3;
    r = grey + (r - grey) * sat;
    g = grey + (g - grey) * sat;
    b = grey + (b - grey) * sat;
    const k = (step * 255) / Math.max(1, Math.max(r, g, b));
    r *= k; g *= k; b *= k;
    if (step === tones[0] && red > 0) {
      // the shadow tone leans into the P5 red-black
      r = r * (1 - red) + 70 * red;
      g = g * (1 - red) + 8 * red;
      b = b * (1 - red) + 24 * red;
    }
    d[i] = clamp(r); d[i + 1] = clamp(g); d[i + 2] = clamp(b); d[i + 3] = 255;
  }
  // 2. inner ink: where the tone or the colour jumps between neighbours
  if (ink > 0) {
    const Vq = new Float32Array(w * h);
    for (let p = 0; p < w * h; p++) Vq[p] = A[p] ? (V[p] < 0.42 ? 0 : V[p] < 0.74 ? 1 : 2) : -1;
    for (let y = 1; y < h - 1; y++) for (let xx = 1; xx < w - 1; xx++) {
      const p = y * w + xx;
      if (!A[p]) continue;
      const r = p + 1, dn = p + w;
      const toneJump = (A[r] && Math.abs(Vq[p] - Vq[r]) >= 2) || (A[dn] && Math.abs(Vq[p] - Vq[dn]) >= 2);
      const colJump = (A[r] && Math.abs(H[p] - H[r]) * 17 > edge) || (A[dn] && Math.abs(H[p] - H[dn]) * 17 > edge);
      if (toneJump || colJump) {
        const i = p * 4;
        d[i] = d[i + 1] = d[i + 2] = 14;
      }
    }
  }
  x.putImageData(img, 0, 0);
  // 3. the silhouette outline: the shape in black, stamped round, under the colour
  if (outline > 0) {
    const s = document.createElement("canvas");
    s.width = w;
    s.height = h;
    const sx = s.getContext("2d");
    sx.drawImage(c, 0, 0);
    sx.globalCompositeOperation = "source-in";
    sx.fillStyle = "#0c0608";
    sx.fillRect(0, 0, w, h);
    const o = document.createElement("canvas");
    o.width = w;
    o.height = h;
    const ox = o.getContext("2d");
    const n = 12;
    for (let k = 0; k < n; k++) {
      const a = (k / n) * Math.PI * 2;
      ox.drawImage(s, Math.cos(a) * outline, Math.sin(a) * outline);
    }
    ox.drawImage(c, 0, 0);
    return { canvas: o, pad };
  }
  return { canvas: c, pad };
}
