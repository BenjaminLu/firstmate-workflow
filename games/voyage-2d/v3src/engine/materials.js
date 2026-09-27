// Shared materials and the palette.
// Voxel materials use vertex colours (jitter + AO baked by the mesher) and a
// per-face UV that the fragment shader turns into a soft darkened seam, faded
// out by screen-space derivatives once a block gets smaller than a few pixels.
import * as THREE from "three";
import { M, meshGrid } from "./voxel.js";

export const PAL = {
  wood: 0x8a5230,
  woodLight: 0xa66a3c,
  woodDark: 0x5a331b,
  woodDeep: 0x3d2212,
  deck: 0xc4905a,
  deckB: 0xb07c48,
  iron: 0x3b3d46,
  ironLight: 0x5c606b,
  rivet: 0x8a8e98,
  gold: 0xf2b53a,
  goldDark: 0xb87c1e,
  cream: 0xf4e6c8,
  creamShade: 0xdcc9a4,
  navy: 0x1f2f86,
  navyDark: 0x16205c,
  navyCoat: 0x1b2340,
  white: 0xf7f8fb,
  offWhite: 0xe3e6ee,
  skin: 0xf6c9a0,
  skinShade: 0xe0a882,
  blush: 0xf29a8e,
  hair: 0x1e1612,
  hairHi: 0x3a2a20,
  beard: 0x241812,
  black: 0x15151c,
  mouth: 0x7a1f24,
  tongue: 0xe8667a,
  red: 0xd83a2c,
  redDark: 0x9c2419,
  green: 0x2f9a4a,
  greenDark: 0x1f6b34,
  brown: 0x6b4226,
  leather: 0x5a3a22,
  rope: 0xa98355,
  purple: 0x5a2f8f,
  purpleDark: 0x351a5e,
  purpleLight: 0x8250c0,
  sucker: 0xe99aa6,
  suckerDark: 0xb86478,
  glowWarm: 0xffc46b,
  glowBlue: 0x39b6ff,
  glowPurple: 0xc050ff,
  grass: 0x5aa83a,
  grassDark: 0x3f8230,
  rock: 0x8a7f96,
  rockDark: 0x5f5670,
};

const seamChunk = /* glsl */ `
  #ifdef USE_FACEUV
    vec2 fw = fwidth(vFaceUv.xy);
    vec2 ed = min(vFaceUv.xy, 1.0 - vFaceUv.xy);
    float px = max(fw.x, fw.y);
    float edge = min(ed.x, ed.y);
    float seamW = 0.05 + px * 1.2;
    float s = 1.0 - smoothstep(0.0, seamW, edge);
    float fade = 1.0 - smoothstep(0.12, 0.35, px);
    diffuseColor.rgb *= 1.0 - vFaceUv.z * s * fade;
    // faint bevel highlight just inside the top edge of each block face
    float hl = smoothstep(seamW, seamW * 2.5, edge) * (1.0 - smoothstep(seamW * 2.5, seamW * 4.0, 1.0 - vFaceUv.y)) * fade;
    diffuseColor.rgb *= 1.0 + 0.08 * vFaceUv.z * hl;
  #endif
`;

function voxelize(mat) {
  mat.vertexColors = true;
  mat.defines = { ...(mat.defines || {}), USE_FACEUV: "" };
  mat.onBeforeCompile = (sh) => {
    sh.vertexShader = sh.vertexShader
      .replace("#include <common>", "#include <common>\nattribute vec3 faceUv;\nvarying vec3 vFaceUv;")
      .replace("#include <uv_vertex>", "#include <uv_vertex>\nvFaceUv = faceUv;");
    sh.fragmentShader = sh.fragmentShader
      .replace("#include <common>", "#include <common>\nvarying vec3 vFaceUv;")
      .replace("#include <color_fragment>", "#include <color_fragment>\n" + seamChunk);
  };
  mat.customProgramCacheKey = () => "voxel-" + mat.type;
  return mat;
}

export const materials = {
  lit: voxelize(new THREE.MeshStandardMaterial({ roughness: 0.82, metalness: 0.0 })),
  metal: voxelize(new THREE.MeshStandardMaterial({ roughness: 0.42, metalness: 0.55 })),
  cloth: voxelize(new THREE.MeshStandardMaterial({ roughness: 0.95, metalness: 0.0, side: THREE.DoubleSide })),
  glow: new THREE.MeshBasicMaterial({ vertexColors: true, color: new THREE.Color(3.2, 3.2, 3.2) }),
  rope: new THREE.MeshStandardMaterial({ color: PAL.rope, roughness: 0.95 }),
  ropeDark: new THREE.MeshStandardMaterial({ color: 0x6e5132, roughness: 0.95 }),
};
const KIND_MAT = [materials.lit, materials.glow, materials.metal, materials.cloth];

export const stats = { triangles: 0, meshes: 0 };

// Grid -> Group of meshes (one per material kind present)
export function toMesh(grid, { size = 1, origin = [0, 0, 0], cast = true, receive = true, name } = {}) {
  const { geometries, triangles } = meshGrid(grid, { size, origin });
  const g = new THREE.Group();
  if (name) g.name = name;
  geometries.forEach((geo, k) => {
    if (!geo) return;
    const mesh = new THREE.Mesh(geo, KIND_MAT[k]);
    mesh.castShadow = cast && k !== M.GLOW;
    mesh.receiveShadow = receive && k !== M.GLOW;
    g.add(mesh);
    stats.meshes++;
  });
  stats.triangles += triangles;
  g.userData.triangles = triangles;
  return g;
}

// count triangles below an object (meshes + instanced meshes)
export function countTriangles(obj) {
  let t = 0,
    inst = 0,
    draws = 0;
  obj.traverse((o) => {
    if (!o.isMesh || !o.visible) return;
    const g = o.geometry;
    const n = g.index ? g.index.count / 3 : g.attributes.position.count / 3;
    const c = o.isInstancedMesh ? o.count : 1;
    if (o.isInstancedMesh) inst += c;
    t += n * c;
    draws++;
  });
  return { triangles: Math.round(t), instances: inst, draws };
}
