// The ocean: stylised Gerstner waves on the GPU, the same waves on the CPU for
// buoyancy. Near the ship the sea is voxel-terraced (cells take their centre's
// height, quantised to steps, foam is a hard threshold: the keyframes' stepped
// water with cube foam); it fades to smooth with distance so the far sea does
// not alias. Two meshes: a dense near grid centred on the camera side of the
// ship, and a radially warped far grid out to the horizon (its centre dips under
// the near grid). Weather drives amplitude, foam, speed (wake) and darkening.
import * as THREE from "three";

const G = 9.8;
// [dirX, dirZ, wavelength m, steepness]; steepness sums < 1 so crests never loop
const ALL_WAVES = [
  [1, 0.25, 34, 0.24],
  [0.7, -0.7, 21, 0.2],
  [0.25, 1, 13, 0.16],
  [-0.6, 0.8, 7.5, 0.12],
  [0.95, -0.3, 4.2, 0.08],
].map(([x, z, L, s]) => {
  const d = Math.hypot(x, z);
  return [x / d, z / d, L, s];
});
export const OCEAN_NORM = ALL_WAVES.reduce((a, [, , L, s]) => a + (s * L) / (2 * Math.PI), 0); // max crest per unit amp

export function createOcean({ tier = "high", look = "voxel", sunDir, center = new THREE.Vector3(), fog = true } = {}) {
  const nWaves = tier === "low" ? 3 : tier === "medium" ? 4 : 5;
  const WAVES = ALL_WAVES.slice(0, nWaves);
  const low = tier === "low";
  const uniforms = THREE.UniformsUtils.merge([
    THREE.UniformsLib.fog,
    {
      uTime: { value: 0 },
      uAmp: { value: 0.45 },
      uFoam: { value: 0.45 },
      uSpeed: { value: 0.5 },
      uDark: { value: 0 },
      uVoxel: { value: look === "voxel" ? 1 : 0 },
      uCell: { value: 0.6 },
      uStepH: { value: 0.3 },
      uSun: { value: (sunDir || new THREE.Vector3(0, 0.3, -1)).clone().normalize() },
      uShip: { value: new THREE.Vector4(0, 0, 1, 0) },
      uShipSize: { value: new THREE.Vector3(13.4, 3.7, 0) },
      uIslands: { value: [0, 1, 2, 3].map(() => new THREE.Vector4(0, 0, 0, 0)) },
      uCenter: { value: new THREE.Vector2(center.x, center.z) },
      uNear: { value: new THREE.Vector2(22, 40) }, // terracing fades out between these radii
      uSink: { value: 0 }, // far grid: sink under the near grid
      uNearBox: { value: new THREE.Vector4(1e9, 1e9, -1e9, -1e9) },
    },
  ]);
  const W = WAVES.map(([x, z, L, s]) => `vec4(${x.toFixed(4)}, ${z.toFixed(4)}, ${L.toFixed(2)}, ${s.toFixed(3)})`).join(",");
  const common = /* glsl */ `
    uniform float uTime, uAmp, uFoam, uSpeed, uDark, uVoxel, uCell, uStepH, uSink;
    uniform vec3 uSun; uniform vec4 uShip; uniform vec3 uShipSize; uniform vec4 uIslands[4];
    uniform vec2 uCenter, uNear; uniform vec4 uNearBox;
    const vec4 W[${nWaves}] = vec4[${nWaves}](${W});
    float h21(vec2 p){ return fract(sin(dot(p, vec2(12.9898,78.233)))*43758.5453); }
    float n2(vec2 p){ vec2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f); return mix(mix(h21(i),h21(i+vec2(1,0)),f.x), mix(h21(i+vec2(0,1)),h21(i+vec2(1,1)),f.x), f.y); }
    vec2 shipLocal(vec2 p){ vec2 d = p - uShip.xy; return vec2(d.x*uShip.z + d.y*uShip.w, -d.x*uShip.w + d.y*uShip.z); }
    // amplitude envelope: calmer inside the hull and the islands, fading far away
    float env(vec2 p){
      vec2 sl = shipLocal(p);
      float hull = length(vec2(sl.x / (uShipSize.x * 1.05), sl.y / (uShipSize.y * 1.1)));
      float e = mix(0.35, 1.0, smoothstep(0.8, 1.3, hull));
      for (int i = 0; i < 4; i++) if (uIslands[i].w > 0.5) e *= smoothstep(uIslands[i].z * 0.8, uIslands[i].z * 1.4, length(p - uIslands[i].xy));
      return e * (1.0 - smoothstep(160.0, 420.0, length(p - uCenter)));
    }
    vec3 gerst(vec2 p, out vec3 T, out vec3 B){
      vec3 P = vec3(p.x, 0.0, p.y); T = vec3(1,0,0); B = vec3(0,0,1);
      float a0 = uAmp * env(p);
      for (int i = 0; i < ${nWaves}; i++){
        vec2 d = W[i].xy; float k = 6.28318/W[i].z; float c = sqrt(9.8/k); float wa = W[i].w * a0; float a = wa / k;
        float f = k*(dot(d,p) - c*uTime); float cf = cos(f), sf = sin(f);
        P.x += d.x*a*cf; P.z += d.y*a*cf; P.y += a*sf;
        T += vec3(-d.x*d.x*wa*sf, d.x*wa*cf, -d.x*d.y*wa*sf);
        B += vec3(-d.x*d.y*wa*sf, d.y*wa*cf, -d.y*d.y*wa*sf);
      }
      return P;
    }
    // foam 0..1 at world p with normalised height h (0 trough .. 1 crest)
    float foamAt(vec2 p, vec2 base, float h){
      float br = n2(base * 1.3 + uTime * 0.25) * 0.6 + n2(base * 3.7 - uTime * 0.4) * 0.4;
      float f = smoothstep(0.86 - uFoam * 0.14, 1.0, h + br * 0.2) * (0.4 + uFoam);
      vec2 sl = shipLocal(p);
      float hull = length(vec2(sl.x / uShipSize.x, sl.y / uShipSize.y));
      f += smoothstep(1.3, 1.02, hull) * step(0.98, hull) * (0.5 + 0.5 * br) * (0.35 + uSpeed);
      // bow wave
      f += smoothstep(3.5, 0.0, length(vec2(sl.x - uShipSize.x, sl.y) * vec2(0.8, 1.0))) * uSpeed * (0.5 + br);
      // V wake and the trail behind the stern
      float behind = -sl.x - uShipSize.x * 0.85;
      if (behind > 0.0) {
        float v = smoothstep(0.7, 0.0, abs(abs(sl.y) - uShipSize.y * 0.7 - behind * 0.34) - 0.3) * exp(-behind * 0.025);
        float tr = smoothstep(uShipSize.y * 0.9, 0.3, abs(sl.y)) * exp(-behind * 0.04);
        f += (v * 0.9 + tr * 0.55) * (0.4 + 0.6 * br) * clamp(uSpeed * 1.4, 0.0, 1.0);
      }
      for (int i = 0; i < 4; i++) if (uIslands[i].w > 0.5) {
        float r = length(p - uIslands[i].xy) - uIslands[i].z;
        f += smoothstep(2.4, 0.2, abs(r - 0.6)) * (0.4 + 0.6 * br);
      }
      return clamp(f, 0.0, 1.0);
    }
    // painterly colour (linear) from height, view and foam
    vec3 seaColour(vec3 N, vec3 V, float h, float foam, float terr){
      vec3 deep = pow(vec3(0.10, 0.16, 0.52), vec3(2.2)), body = pow(vec3(0.13, 0.40, 0.90), vec3(2.2)), crest = pow(vec3(0.36, 0.80, 0.95), vec3(2.2));
      vec3 col = mix(deep, body, smoothstep(0.1, 0.6, h));
      float sss = pow(max(dot(V, -uSun), 0.0), 3.0) * smoothstep(0.45, 0.95, h);
      col = mix(col, crest, clamp(smoothstep(0.6, 1.0, h) * 0.55 + sss * 0.8, 0.0, 1.0));
      float dif = dot(N, normalize(vec3(-uSun.x, 0.9, -uSun.z)));
      col *= mix(0.72, 1.08, smoothstep(0.1, 0.7, dif));
      float fr = pow(1.0 - max(dot(N, V), 0.0), 4.0);
      col = mix(col, pow(vec3(0.95, 0.66, 0.78), vec3(2.2)), fr * 0.35);
      vec3 R = reflect(-V, N);
      col += pow(vec3(1.0, 0.72, 0.42), vec3(2.2)) * pow(max(dot(R, uSun), 0.0), 160.0) * 3.0 * (1.0 - uDark);
      float fo = mix(smoothstep(0.35, 0.6, foam), step(0.5, foam), terr);
      col = mix(col, vec3(0.86, 0.9, 1.0), fo);
      // the squall: colder, darker water
      col = mix(col, col * vec3(0.45, 0.52, 0.66), uDark * 0.8);
      return col;
    }
  `;
  const vertexShader = /* glsl */ `
    #include <fog_pars_vertex>
    ${common}
    varying vec3 vWorld; varying vec3 vN; varying float vH; varying vec2 vBase; varying float vTerr;
    ${low ? "varying vec3 vCol;" : ""}
    void main(){
      vec4 wp = modelMatrix * vec4(position, 1.0);
      vec2 base = wp.xz;
      // terracing near the ship; smooth far out
      float terr = uVoxel * (1.0 - smoothstep(uNear.x, uNear.y, length(wp.xz - uCenter)));
      vec2 cellC = (floor(wp.xz / uCell) + 0.5) * uCell;
      if (terr > 0.5) base = cellC;
      vec3 T, B; vec3 P = gerst(base, T, B);
      if (terr > 0.5) { P.xz = wp.xz; P.y = floor(P.y / uStepH + 0.5) * uStepH; }
      // the far grid dips under the near one
      if (uSink > 0.5 && wp.x > uNearBox.x && wp.x < uNearBox.z && wp.z > uNearBox.y && wp.z < uNearBox.w) P.y -= 4.0;
      vN = normalize(cross(B, T));
      vH = clamp(P.y / max(uAmp * ${OCEAN_NORM.toFixed(3)}, 0.01) * 0.5 + 0.5, 0.0, 1.0);
      vBase = base; vWorld = P; vTerr = terr;
      vec4 mvPosition = viewMatrix * vec4(P, 1.0);
      gl_Position = projectionMatrix * mvPosition;
      ${low ? "vCol = seaColour(vN, normalize(cameraPosition - P), vH, foamAt(P.xz, base, vH), terr);" : ""}
      #include <fog_vertex>
    }`;
  const fragmentShader = /* glsl */ `
    #include <fog_pars_fragment>
    ${common}
    varying vec3 vWorld; varying vec3 vN; varying float vH; varying vec2 vBase; varying float vTerr;
    ${low ? "varying vec3 vCol;" : ""}
    void main(){
      ${
        low
          ? "vec3 col = vCol;"
          : `vec3 N = normalize(vN);
      if (vTerr > 0.5) { vec3 dx = dFdx(vWorld), dy = dFdy(vWorld); vec3 fn = normalize(cross(dx, dy)); if (fn.y < 0.0) fn = -fn; N = normalize(mix(N, fn, 0.7)); }
      vec3 V = normalize(cameraPosition - vWorld);
      vec3 col = seaColour(N, V, vH, foamAt(vWorld.xz, vBase, vH), vTerr);`
      }
      gl_FragColor = vec4(col, 1.0);
      #include <tonemapping_fragment>
      #include <colorspace_fragment>
      #include <fog_fragment>
    }`;
  const make = (sink) => {
    const u = { ...uniforms, uSink: { value: sink ? 1 : 0 } };
    return new THREE.ShaderMaterial({ uniforms: u, vertexShader, fragmentShader, fog, lights: false, extensions: {} });
  };
  // near grid: uniform, centred on the camera side of the ship
  const nearSize = low ? 64 : 76;
  const nearSeg = low ? 96 : tier === "medium" ? 128 : 168;
  const nearGeo = new THREE.PlaneGeometry(nearSize, nearSize, nearSeg, nearSeg).rotateX(-Math.PI / 2);
  const near = new THREE.Mesh(nearGeo, make(false));
  near.frustumCulled = false;
  near.receiveShadow = false;
  // far grid: radially warped (dense near the middle), out to 900 m
  const farSeg = low ? 64 : 112;
  const farGeo = new THREE.PlaneGeometry(2, 2, farSeg, farSeg).rotateX(-Math.PI / 2);
  const pos = farGeo.attributes.position;
  for (let i = 0; i < pos.count; i++) {
    const x = pos.getX(i),
      z = pos.getZ(i);
    const r = Math.max(Math.abs(x), Math.abs(z));
    const R = 900 * Math.pow(r, 2.2);
    const s = r > 1e-6 ? R / r : 0;
    pos.setXYZ(i, x * s, 0, z * s);
  }
  farGeo.computeBoundingSphere();
  const far = new THREE.Mesh(farGeo, make(true));
  far.frustumCulled = false;
  far.renderOrder = -1;
  const group = new THREE.Group();
  group.add(far, near);
  const mats = [near.material, far.material];
  const U = near.material.uniforms; // shared uniform objects (see make: same value refs)
  for (const k of Object.keys(uniforms)) if (k !== "uSink") far.material.uniforms[k] = near.material.uniforms[k];

  // place the grids around a world point (the ship's camera side)
  function recenter(p) {
    near.position.set(Math.round(p.x / 0.6) * 0.6, 0, Math.round(p.z / 0.6) * 0.6);
    far.position.set(p.x, 0, p.z);
    U.uCenter.value.set(p.x, p.z);
    const h = nearSize / 2 - 1.5;
    U.uNearBox.value.set(near.position.x - h, near.position.z - h, near.position.x + h, near.position.z + h);
    U.uNear.value.set(nearSize * 0.3, nearSize * 0.48);
  }
  recenter(center);

  // CPU mirror of the waves (envelope ignored: probes sit outside the hull ring)
  const amp = () => U.uAmp.value;
  function gerstnerCPU(x, z, t, a) {
    let px = x,
      py = 0,
      pz = z;
    for (const [dx, dz, L, s] of WAVES) {
      const k = (2 * Math.PI) / L,
        c = Math.sqrt(G / k),
        A = (s * a) / k;
      const f = k * (dx * x + dz * z - c * t);
      px += dx * A * Math.cos(f);
      pz += dz * A * Math.cos(f);
      py += A * Math.sin(f);
    }
    return [px, py, pz];
  }
  function heightAt(x, z, t = U.uTime.value, a = amp()) {
    let sx = x,
      sz = z;
    for (let i = 0; i < 3; i++) {
      const p = gerstnerCPU(sx, sz, t, a);
      sx += x - p[0];
      sz += z - p[2];
    }
    return gerstnerCPU(sx, sz, t, a)[1];
  }
  return {
    group,
    uniforms: U,
    materials: mats,
    heightAt,
    recenter,
    setLook(l) {
      U.uVoxel.value = l === "voxel" ? 1 : 0;
    },
    // weather: v2 column values (see src/motion/weather.js)
    applyWeather(w, t) {
      U.uTime.value = t;
      U.uAmp.value = 0.28 + w.swell * 0.62;
      U.uFoam.value = w.foam;
      U.uSpeed.value = Math.min(1.2, w.speed);
      U.uDark.value = Math.max(w.dark * 0.9, 0);
    },
  };
}

// Buoyancy: four hull probes on the CPU waves, a damped follow for heave, pitch
// and roll (heavy, not twitchy), plus the heel spring from the caller.
export class Buoyancy {
  constructor(ocean, { halfLength = 11, halfBeam = 3.2, follow = 2.6 } = {}) {
    Object.assign(this, { ocean, halfLength, halfBeam, follow });
    this.heave = 0;
    this.pitch = 0;
    this.roll = 0;
  }
  update(dt, x, z, yaw, t) {
    const c = Math.cos(yaw),
      s = Math.sin(yaw);
    // ship-local x forward, z to port -> world
    const at = (lx, lz) => this.ocean.heightAt(x + lx * c + lz * s, z - lx * s + lz * c, t);
    const hb = at(this.halfLength, 0),
      hs = at(-this.halfLength, 0),
      hp = at(0, this.halfBeam),
      hq = at(0, -this.halfBeam);
    const k = 1 - Math.exp(-dt * this.follow);
    this.heave += ((hb + hs + hp + hq) / 4 - this.heave) * k;
    this.pitch += (Math.atan2(hb - hs, this.halfLength * 2) - this.pitch) * k;
    this.roll += (Math.atan2(hp - hq, this.halfBeam * 2) - this.roll) * k;
    this.bowDip = hb < this.heave;
    return this;
  }
}
