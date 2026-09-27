// Golden-hour look: low warm sun key, cool sky fill, soft shadows, ACES, bloom.
import * as THREE from "three";
import { EffectComposer } from "three/addons/postprocessing/EffectComposer.js";
import { RenderPass } from "three/addons/postprocessing/RenderPass.js";
import { UnrealBloomPass } from "three/addons/postprocessing/UnrealBloomPass.js";
import { OutputPass } from "three/addons/postprocessing/OutputPass.js";

export function createRenderer(canvas) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: "high-performance" });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.5));
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.05;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  return renderer;
}

// sunDir points from the scene toward the sun
export function createSky(sunDir) {
  const mat = new THREE.ShaderMaterial({
    side: THREE.BackSide,
    depthWrite: false,
    fog: false,
    uniforms: { sunDir: { value: sunDir.clone().normalize() } },
    vertexShader: /* glsl */ `
      varying vec3 vDir;
      void main(){ vDir = normalize(position); vec4 p = projectionMatrix * modelViewMatrix * vec4(position,1.0); gl_Position = p.xyww; }`,
    fragmentShader: /* glsl */ `
      varying vec3 vDir; uniform vec3 sunDir;
      float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1,311.7))) * 43758.5453); }
      float noise(vec2 p){ vec2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
        return mix(mix(hash(i),hash(i+vec2(1,0)),f.x), mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),f.x), f.y); }
      float fbm(vec2 p){ float a=0.5, s=0.0; for(int i=0;i<5;i++){ s+=a*noise(p); p*=2.03; a*=0.5; } return s; }
      void main(){
        vec3 d = normalize(vDir);
        float e = d.y;
        vec3 sd = normalize(sunDir);
        float s = max(dot(d, sd), 0.0);
        vec3 zen = vec3(0.05, 0.20, 0.72);
        vec3 mid = vec3(0.22, 0.46, 0.95);
        vec3 horAway = vec3(0.95, 0.60, 0.78);
        vec3 horSun = vec3(1.0, 0.58, 0.22);
        vec3 hor = mix(horAway, horSun, pow(s, 2.5));
        vec3 col = mix(hor, mid, smoothstep(-0.02, 0.28, e));
        col = mix(col, zen, smoothstep(0.28, 0.85, e));
        col = mix(col, vec3(1.0, 0.70, 0.38), pow(s, 6.0) * 0.85 * (1.0 - smoothstep(0.0, 0.5, e)));
        // blocky cumulus: pixelated fbm in (azimuth, elevation) space
        float az = atan(d.z, d.x);
        vec2 cp = vec2(az * 18.0, e * 44.0);
        vec2 q = floor(cp * 3.0) / 3.0;
        float c = fbm(q * vec2(0.55, 0.9) + vec2(3.0, 0.0));
        float band = smoothstep(0.02, 0.12, e) * (1.0 - smoothstep(0.35, 0.6, e));
        float cl = smoothstep(0.56, 0.66, c) * band;
        float lit = fbm(q * vec2(0.55, 0.9) + vec2(3.0, -0.35));
        vec3 cloudBody = mix(vec3(0.72, 0.52, 0.78), vec3(1.0, 0.72, 0.62), smoothstep(0.4, 0.75, lit));
        cloudBody = mix(cloudBody, vec3(1.0, 0.86, 0.62), pow(s, 4.0) * 0.8);
        col = mix(col, cloudBody * 1.05, cl * 0.92);
        // crepuscular rays
        vec3 up = vec3(0.0, 1.0, 0.0);
        vec3 tx = normalize(cross(up, sd));
        vec3 ty = cross(sd, tx);
        float ang = atan(dot(d, ty), dot(d, tx));
        float rays = pow(max(0.0, sin(ang * 15.0)), 5.0) * smoothstep(0.78, 0.97, s) * step(0.0, dot(d, ty));
        col += vec3(1.0, 0.75, 0.45) * rays * 0.18;
        col += vec3(1.0, 0.72, 0.42) * pow(s, 80.0) * 1.3;
        float disc = smoothstep(0.9986, 0.9990, s);
        col = mix(col, vec3(7.0, 5.2, 3.0), disc);
        if (e < 0.0) col = mix(hor, vec3(0.20, 0.30, 0.70), smoothstep(0.0, -0.15, e));
        gl_FragColor = vec4(col, 1.0);
        #include <tonemapping_fragment>
        #include <colorspace_fragment>
      }`,
  });
  const dome = new THREE.Mesh(new THREE.SphereGeometry(900, 48, 24), mat);
  dome.frustumCulled = false;
  dome.renderOrder = -10;
  return dome;
}

// Adds lights to the scene; returns handles for quality/shadow framing.
export function createLights(scene, { sunDir, shadowCenter = new THREE.Vector3(), shadowExtent = 30, mapSize = 2048 } = {}) {
  const hemi = new THREE.HemisphereLight(0x9cc0ff, 0xf2b286, 1.25);
  scene.add(hemi);
  const sun = new THREE.DirectionalLight(0xffd6a0, 3.4);
  const sd = sunDir.clone().normalize();
  sun.position.copy(shadowCenter).addScaledVector(sd, 120);
  sun.target.position.copy(shadowCenter);
  sun.castShadow = true;
  sun.shadow.mapSize.set(mapSize, mapSize);
  const cam = sun.shadow.camera;
  cam.left = -shadowExtent;
  cam.right = shadowExtent;
  cam.top = shadowExtent;
  cam.bottom = -shadowExtent;
  cam.near = 20;
  cam.far = 260;
  sun.shadow.bias = -0.0004;
  sun.shadow.normalBias = 0.03;
  sun.shadow.radius = 4;
  scene.add(sun, sun.target);
  // cool fill from the opposite side keeps shadowed faces blue, like the paintings
  const fill = new THREE.DirectionalLight(0x8fb4ff, 0.7);
  fill.position.set(-sd.x * 100, 60, -sd.z * 100);
  scene.add(fill);
  return { hemi, sun, fill };
}

export function createComposer(renderer, scene, camera, { strength = 0.55, radius = 0.4, threshold = 0.92 } = {}) {
  const size = renderer.getDrawingBufferSize(new THREE.Vector2());
  const rt = new THREE.WebGLRenderTarget(size.x, size.y, { type: THREE.HalfFloatType, samples: 4 });
  const composer = new EffectComposer(renderer, rt);
  const renderPass = new RenderPass(scene, camera);
  composer.addPass(renderPass);
  const bloom = new UnrealBloomPass(new THREE.Vector2(size.x, size.y), strength, radius, threshold);
  composer.addPass(bloom);
  composer.addPass(new OutputPass());
  return { composer, bloom, renderPass };
}

export function setShadows(renderer, scene, on) {
  renderer.shadowMap.enabled = on;
  scene.traverse((o) => {
    if (o.material) {
      const ms = Array.isArray(o.material) ? o.material : [o.material];
      ms.forEach((m) => (m.needsUpdate = true));
    }
  });
}
