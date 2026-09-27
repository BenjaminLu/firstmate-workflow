// Voxel sea: a blocky heightfield of instanced columns, animated entirely in the
// vertex shader, with foam as separate white voxels riding the crests, around
// the hull (bow wave), in the wake and on shorelines. A sun-glint path sparkles
// on the column tops. CPU cost per frame: one uniform write.
import * as THREE from "three";

const GLSL_WAVES = /* glsl */ `
  uniform float uTime;
  uniform float uAmp;
  uniform float uStep;
  uniform vec4 uShip;      // x, z, cos(heading), sin(heading)
  uniform vec3 uShipSize;  // half length, half beam, enabled
  uniform vec4 uIslands[4];// x, z, radius, enabled
  uniform vec4 uHole;      // xmin, zmin, xmax, zmax: cells inside are dropped (for a nested finer grid)
  float h21(vec2 p){ return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
  float waveH(vec2 p, float t){
    float h = 0.95 * sin(0.34 * p.x + 0.12 * p.y + 1.1 * t)
            + 0.65 * sin(0.24 * (p.x * 0.6 - p.y * 0.8) + 1.4 * t)
            + 0.50 * sin(0.55 * (p.x * 0.35 + p.y) - 1.8 * t)
            + 0.32 * sin(0.95 * (p.x - p.y * 0.45) + 2.6 * t)
            + 0.18 * sin(1.60 * (p.x * 0.7 + p.y * 0.7) - 3.1 * t);
    return h * uAmp;
  }
  // ship-local coordinates: x forward (bow), y across
  vec2 shipLocal(vec2 p){
    vec2 d = p - uShip.xy;
    return vec2(d.x * uShip.z + d.y * uShip.w, -d.x * uShip.w + d.y * uShip.z);
  }
  // returns (height offset, foam amount); height offset < -50 means "inside the hull"
  vec2 shipField(vec2 p){
    if (uShipSize.z < 0.5) return vec2(0.0);
    vec2 q = shipLocal(p);
    float L = uShipSize.x, B = uShipSize.y;
    // hull footprint: pointed ellipse
    float bx = q.x / L;
    float halfW = B * sqrt(max(0.0, 1.0 - pow(max(bx, 0.0), 2.0))) * (bx < -0.85 ? 0.9 : 1.0);
    float inside = (abs(q.x) < L && abs(q.y) < halfW - 0.2) ? 1.0 : 0.0;
    if (inside > 0.5) return vec2(-99.0, 0.0);
    float d = max(abs(q.y) - halfW, 0.0) + max(abs(q.x) - L, 0.0);
    float near = 1.0 - smoothstep(0.0, 3.2, d);
    float bow = smoothstep(0.1, 0.9, bx);
    float lift = near * (0.4 + 1.3 * bow);
    float foam = near * (0.55 + 0.6 * bow);
    // wake: widening V behind the stern plus churned centre
    if (q.x < -L * 0.8) {
      float back = -L * 0.8 - q.x;
      float spread = B * 0.9 + back * 0.32;
      float edge = 1.0 - smoothstep(0.0, 1.6, abs(abs(q.y) - spread));
      float centre = (1.0 - smoothstep(0.0, B * 0.8 + back * 0.08, abs(q.y))) * 0.8;
      float fade = 1.0 - smoothstep(10.0, 45.0, back);
      foam = max(foam, max(edge * 0.8, centre) * fade);
    }
    return vec2(lift, foam);
  }
  float islandFoam(vec2 p){
    float f = 0.0;
    for (int i = 0; i < 4; i++){
      if (uIslands[i].w < 0.5) continue;
      float d = length(p - uIslands[i].xy) - uIslands[i].z;
      f = max(f, (1.0 - smoothstep(0.0, 2.8, d)) * step(-1.5, d));
    }
    return f;
  }
`;

function makeSeaMaterial(uniforms, { foamLayer = false } = {}) {
  const mat = new THREE.MeshStandardMaterial({ roughness: foamLayer ? 0.8 : 0.28, metalness: 0.0, vertexColors: false });
  mat.onBeforeCompile = (sh) => {
    Object.assign(sh.uniforms, uniforms);
    sh.vertexShader = sh.vertexShader
      .replace(
        "#include <common>",
        `#include <common>
        ${GLSL_WAVES}
        uniform float uDepth;
        uniform vec3 uSunDir;
        varying float vH; varying float vFoam; varying float vTop; varying float vRnd; varying vec3 vW;`,
      )
      .replace(
        "#include <begin_vertex>",
        `#include <begin_vertex>
        vec4 cw = modelMatrix * instanceMatrix * vec4(0.0, 0.0, 0.0, 1.0);
        vec2 cp = cw.xz;
        float rnd = h21(floor(cp * 7.0 + 0.5));
        vRnd = rnd;
        float h = waveH(cp, uTime);
        vec2 sf = shipField(cp);
        float foam = sf.y;
        bool hidden = sf.x < -50.0 || (cp.x > uHole.x && cp.x < uHole.z && cp.y > uHole.y && cp.y < uHole.w);
        h += sf.x;
        foam = max(foam, islandFoam(cp));
        float crest = smoothstep(1.05 * uAmp, 1.9 * uAmp, h);
        foam = max(foam, crest);
        // blocky: quantise the height
        float hq = floor(h / uStep + 0.5) * uStep;
        vH = h / (2.4 * uAmp);
        vFoam = foam;
        vTop = normal.y;
        ${
          foamLayer
            ? `// foam voxel: visible when this cell rolls under the foam threshold
          float show = step(rnd, foam * 1.1 - 0.12) * (hidden ? 0.0 : 1.0);
          float bob = h21(floor(cp * 7.0 + 0.5) + floor(uTime * 3.0 + rnd * 7.0)) ;
          transformed *= show;
          transformed.y += (hq + 0.35 * uStep + bob * uStep * 1.2 * foam) * show;
          transformed.x += (rnd - 0.5) * 0.5 * show * 0.5;`
            : `transformed.y = hidden ? -uDepth - 5.0 : transformed.y * (uDepth + hq) - uDepth;`
        }
        vW = (modelMatrix * instanceMatrix * vec4(transformed, 1.0)).xyz;`,
      );
    sh.fragmentShader = sh.fragmentShader
      .replace(
        "#include <common>",
        `#include <common>
        uniform vec3 uSunDir; uniform float uTime;
        uniform vec3 uDeep; uniform vec3 uMid; uniform vec3 uHi; uniform vec3 uFoamCol;
        varying float vH; varying float vFoam; varying float vTop; varying float vRnd; varying vec3 vW;
        float h21f(vec2 p){ return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }`,
      )
      .replace(
        "#include <color_fragment>",
        `#include <color_fragment>
        ${
          foamLayer
            ? `diffuseColor.rgb = uFoamCol * (0.92 + 0.08 * vRnd);`
            : `float k = clamp(vH * 0.5 + 0.5, 0.0, 1.0);
          vec3 wc = k < 0.5 ? mix(uDeep, uMid, k / 0.5) : mix(uMid, uHi, (k - 0.5) / 0.5);
          wc *= 0.9 + 0.2 * vRnd;
          // sides of the columns darker and bluer, like the paintings
          wc = mix(wc * vec3(0.55, 0.62, 0.85), wc, step(0.5, vTop));
          // foam tint on the tops that are almost foam
          wc = mix(wc, uFoamCol * 0.95, smoothstep(0.55, 1.0, vFoam) * 0.6 * step(0.5, vTop));
          diffuseColor.rgb = wc;`
        }`,
      )
      .replace(
        "#include <emissivemap_fragment>",
        `#include <emissivemap_fragment>
        ${
          foamLayer
            ? ""
            : `{
          // sun-glint path: sparkles on column tops that mirror the sun
          vec3 V = normalize(cameraPosition - vW);
          vec3 R = reflect(-V, vec3(0.0, 1.0, 0.0));
          float g = pow(max(dot(R, normalize(uSunDir)), 0.0), 60.0);
          float cellT = floor(uTime * 4.0 + vRnd * 13.0);
          float sp = step(0.72, h21f(floor(vW.xz * 2.0) + cellT)) * step(0.5, vTop);
          totalEmissiveRadiance += vec3(1.0, 0.72, 0.42) * (g * 0.9 + g * sp * 5.0) * step(0.5, vTop);
          float broad = pow(max(dot(R, normalize(uSunDir)), 0.0), 8.0);
          totalEmissiveRadiance += vec3(0.9, 0.5, 0.3) * broad * 0.18 * step(0.5, vTop);
        }`
        }`,
      );
  };
  mat.customProgramCacheKey = () => (foamLayer ? "sea-foam" : "sea-col");
  return mat;
}

export function buildSea({ cell = 0.5, width = 80, depth = 70, center = [0, 0], amp = 0.55, sunDir = new THREE.Vector3(0.8, 0.1, -0.6), foam = true, hole = null, uniforms: shared } = {}) {
  const group = new THREE.Group();
  group.name = "sea";
  const uniforms = shared || {
    uTime: { value: 0 },
    uAmp: { value: amp },
    uStep: { value: cell * 0.5 },
    uDepth: { value: 3 },
    uSunDir: { value: sunDir.clone().normalize() },
    uShip: { value: new THREE.Vector4(0, 0, 1, 0) },
    uShipSize: { value: new THREE.Vector3(10, 3, 0) },
    uIslands: { value: [0, 1, 2, 3].map(() => new THREE.Vector4(0, 0, 0, 0)) },
    uHole: { value: new THREE.Vector4(1e9, 1e9, -1e9, -1e9) },
    uDeep: { value: new THREE.Color(0x0f2c86) },
    uMid: { value: new THREE.Color(0x2463d6) },
    uHi: { value: new THREE.Color(0x5cc8ff) },
    uFoamCol: { value: new THREE.Color(0xf4f8ff) },
  };
  // each layer gets its own step/hole but shares the rest
  const local = { ...uniforms, uStep: { value: cell * 0.5 }, uHole: { value: hole ? new THREE.Vector4(...hole) : new THREE.Vector4(1e9, 1e9, -1e9, -1e9) } };
  const nx = Math.round(width / cell),
    nz = Math.round(depth / cell);
  const colGeo = new THREE.BoxGeometry(1, 1, 1);
  colGeo.translate(0, 0.5, 0);
  const cols = new THREE.InstancedMesh(colGeo, makeSeaMaterial(local), nx * nz);
  cols.receiveShadow = true;
  cols.frustumCulled = false;
  const m = new THREE.Matrix4();
  let i = 0;
  for (let a = 0; a < nx; a++)
    for (let b = 0; b < nz; b++) {
      m.makeScale(cell, 1, cell).setPosition(center[0] - width / 2 + (a + 0.5) * cell, 0, center[1] - depth / 2 + (b + 0.5) * cell);
      cols.setMatrixAt(i++, m);
    }
  group.add(cols);
  let foamMesh = null;
  if (foam) {
    const fGeo = new THREE.BoxGeometry(cell * 0.62, cell * 0.62, cell * 0.62);
    foamMesh = new THREE.InstancedMesh(fGeo, makeSeaMaterial(local, { foamLayer: true }), nx * nz);
    foamMesh.frustumCulled = false;
    foamMesh.castShadow = false;
    foamMesh.receiveShadow = true;
    for (let k = 0; k < nx * nz; k++) {
      cols.getMatrixAt(k, m);
      const p = new THREE.Vector3().setFromMatrixPosition(m);
      m.makeTranslation(p.x, 0, p.z);
      foamMesh.setMatrixAt(k, m);
    }
    group.add(foamMesh);
  }
  group.userData = { uniforms, columns: cols, foam: foamMesh, count: nx * nz };
  return group;
}

// far ocean out to the horizon (flat, glossy, fogged)
export function buildFarSea({ y = -0.2, color = 0x1e4fb8 } = {}) {
  const m = new THREE.Mesh(new THREE.PlaneGeometry(3000, 3000), new THREE.MeshStandardMaterial({ color, roughness: 0.22, metalness: 0.1 }));
  m.rotation.x = -Math.PI / 2;
  m.position.y = y;
  m.receiveShadow = false;
  return m;
}
