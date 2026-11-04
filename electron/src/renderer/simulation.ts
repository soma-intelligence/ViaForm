import * as THREE from "three";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
import { rng, type V3 } from "../shared/sim/math";
import { MOTOR_ANGLES, MOTOR_SPIN } from "../shared/sim/physics";
import { Flight, PID_ONLY, quad3, TRAINED, type Brain, type Scenario } from "../shared/sim/sim";
import { clearance, obstacleCourse, randomCourse, type Course, type Obstacle } from "../shared/sim/world";
import { airDensity, WEATHERS, type Weather } from "../shared/sim/weather";
import { FRAME } from "../shared/sim/frame";
import { MOTOR_THRUST_3S_N, PARTS, partsMassKg } from "../shared/sim/parts";
import { TRAINED_SCORE } from "../shared/sim/trained";

// The Simulation workspace: the generatively designed 3-inch drone flying the obstacle course (or
// holding a hover) in the weather picked, drawn live from the same simulation the tests and the
// training run (src/shared/sim). Rain, snow, fog and wind are particles and fog driven by the
// weather model; the companion computer's view (its time-of-flight beams, occupancy map and plan)
// can be shown over the scene.

export type Mission = "course" | "hover" | "random";
export type BrainKind = "pid" | "tuned" | "nn";
export type CameraMode = "chase" | "orbit" | "top" | "fpv";
export type SimSettings = {
  mission: Mission;
  weather: number;
  brain: BrainKind;
  seed: number;
  speed: number;
  camera: CameraMode;
  show: { beams: boolean; map: boolean; path: boolean };
};

export const MISSIONS: { id: Mission; label: string }[] = [
  { id: "course", label: "Obstacle course" },
  { id: "hover", label: "Hover in place" },
  { id: "random", label: "Random course" },
];
export const BRAINS: { id: BrainKind; label: string }[] = [
  { id: "pid", label: "PID, default gains" },
  { id: "tuned", label: "PID, trained gains" },
  { id: "nn", label: "PID + neural net" },
];
export const CAMERAS: { id: CameraMode; label: string }[] = [
  { id: "chase", label: "Chase" },
  { id: "orbit", label: "Orbit" },
  { id: "top", label: "Overview" },
  { id: "fpv", label: "FPV" },
];

const MASS = partsMassKg(FRAME.massG);
const PARAMS = quad3(MASS, undefined, FRAME.arm / 1000);
const brainOf = (b: BrainKind): Brain => (b === "pid" ? PID_ONLY() : TRAINED(b === "nn"));

/** Koschmieder: the extinction that leaves 2 % contrast at the visibility distance. */
const fogDensity = (w: Weather) => (Number.isFinite(w.fogVisibilityM) ? 3.0 / w.fogVisibilityM : w.sun === 0 && w.rainMmH === 0 && w.snowMmH === 0 && w.temperatureC > 15 ? 0.004 : 0.008);

type Look = { skyTop: THREE.Color; skyHorizon: THREE.Color; ground: THREE.Color; sun: number; ambient: number; wet: number };
function lookOf(w: Weather): Look {
  const c = (h: string) => new THREE.Color(h);
  if (w.snowMmH > 0) return { skyTop: c("#8d98a6"), skyHorizon: c("#d7dde3"), ground: c("#e9edf2"), sun: 0.5, ambient: 1.7, wet: 0 };
  if (Number.isFinite(w.fogVisibilityM) && w.fogVisibilityM < 100) return { skyTop: c("#a5adb5"), skyHorizon: c("#c9cfd4"), ground: c("#6d7469"), sun: 0.25, ambient: 1.6, wet: 0.4 };
  if (w.rainMmH > 0) return { skyTop: c("#3b4450"), skyHorizon: c("#76808b"), ground: c("#3e4a3a"), sun: 0.4, ambient: 1.6, wet: 1 };
  if (w.sun === 0) return { skyTop: c("#1a1f27"), skyHorizon: c("#3a414c"), ground: c("#5b5f66"), sun: 0.9, ambient: 1.1, wet: 0 }; // indoor arena
  if (w.altitudeM > 1500) return { skyTop: c("#1f5fb8"), skyHorizon: c("#c8d9ea"), ground: c("#a08a63"), sun: 3.2, ambient: 0.9, wet: 0 };
  if (w.sun < 0.3) return { skyTop: c("#4f6178"), skyHorizon: c("#a9b6c2"), ground: c("#4f6d3e"), sun: 1.2, ambient: 1.2, wet: 0.1 };
  return { skyTop: c("#2f6fc4"), skyHorizon: c("#cfe0ee"), ground: c("#5c8a44"), sun: 2.6, ambient: 0.9, wet: 0 };
}

function canvasTexture(size: number, draw: (g: CanvasRenderingContext2D, s: number) => void): THREE.CanvasTexture {
  const cv = document.createElement("canvas");
  cv.width = cv.height = size;
  draw(cv.getContext("2d")!, size);
  const t = new THREE.CanvasTexture(cv);
  t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = 8;
  return t;
}

/** The field: mown stripes with a faint 1 m grid, tiled. */
const fieldTexture = () => canvasTexture(512, (g, s) => {
  for (let i = 0; i < 8; i++) {
    g.fillStyle = i % 2 ? "#e4e4e4" : "#f2f2f2";
    g.fillRect(0, (i * s) / 8, s, s / 8);
  }
  for (let k = 0; k < 4000; k++) {
    g.fillStyle = `rgba(0,0,0,${Math.random() * 0.06})`;
    g.fillRect(Math.random() * s, Math.random() * s, 2, 2);
  }
  g.strokeStyle = "rgba(255,255,255,0.35)";
  g.lineWidth = 2;
  for (let i = 0; i <= 4; i++) {
    g.beginPath(); g.moveTo((i * s) / 4, 0); g.lineTo((i * s) / 4, s); g.stroke();
    g.beginPath(); g.moveTo(0, (i * s) / 4); g.lineTo(s, (i * s) / 4); g.stroke();
  }
});

const padTexture = () => canvasTexture(256, (g, s) => {
  g.fillStyle = "#1d2127"; g.beginPath(); g.arc(s / 2, s / 2, s / 2, 0, Math.PI * 2); g.fill();
  g.strokeStyle = "#ffd23f"; g.lineWidth = 10; g.beginPath(); g.arc(s / 2, s / 2, s / 2 - 14, 0, Math.PI * 2); g.stroke();
  g.fillStyle = "#ffffff"; g.font = "bold 130px system-ui"; g.textAlign = "center"; g.textBaseline = "middle"; g.fillText("H", s / 2, s / 2 + 6);
});

const dotTexture = () => canvasTexture(64, (g, s) => {
  const r = g.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2);
  r.addColorStop(0, "rgba(255,255,255,1)"); r.addColorStop(0.5, "rgba(255,255,255,0.6)"); r.addColorStop(1, "rgba(255,255,255,0)");
  g.fillStyle = r; g.fillRect(0, 0, s, s);
});

/** Box between two corners, z up. */
function boxMesh(min: V3, max: V3, mat: THREE.Material): THREE.Mesh {
  const m = new THREE.Mesh(new THREE.BoxGeometry(max[0] - min[0], max[1] - min[1], max[2] - min[2]), mat);
  m.position.set((min[0] + max[0]) / 2, (min[1] + max[1]) / 2, (min[2] + max[2]) / 2);
  m.castShadow = m.receiveShadow = true;
  return m;
}

/** A vertical cylinder (three's cylinders run along y). */
function cylinder(r: number, h: number, mat: THREE.Material, seg = 24): THREE.Mesh {
  const m = new THREE.Mesh(new THREE.CylinderGeometry(r, r, h, seg), mat);
  m.geometry.rotateX(Math.PI / 2);
  m.castShadow = m.receiveShadow = true;
  return m;
}

// MARK: The drone, from the generative frame

type DroneModel = { group: THREE.Group; props: THREE.Group[]; blur: THREE.Mesh[]; frost: THREE.MeshStandardMaterial[]; leds: THREE.Mesh[] };

function buildDrone(): DroneModel {
  const g = new THREE.Group();
  const mm = 1 / 1000;
  const t = FRAME.thickness * mm;
  const carbon = new THREE.MeshPhysicalMaterial({ color: 0x17191d, roughness: 0.32, metalness: 0.15, clearcoat: 0.8, clearcoatRoughness: 0.25 });
  // Arms: the members the optimiser kept, at their widths.
  for (const m of FRAME.members) {
    const a = FRAME.nodes[m.a], b = FRAME.nodes[m.b];
    const len = Math.hypot(b.x - a.x, b.y - a.y) * mm;
    const bar = new THREE.Mesh(new THREE.BoxGeometry(len + m.w * mm, m.w * mm, t), carbon);
    bar.position.set(((a.x + b.x) / 2) * mm, ((a.y + b.y) / 2) * mm, 0);
    bar.rotation.z = Math.atan2(b.y - a.y, b.x - a.x);
    bar.castShadow = true;
    g.add(bar);
  }
  // Centre plate, motor pads.
  const plate = new THREE.Mesh(new THREE.BoxGeometry(0.036, 0.036, t), carbon);
  plate.rotation.z = Math.PI / 4;
  plate.castShadow = true;
  g.add(plate);
  const top = new THREE.Mesh(new THREE.BoxGeometry(0.034, 0.034, 0.0015), carbon);
  top.position.z = 0.024;
  top.castShadow = true;
  g.add(top);
  const alu = new THREE.MeshStandardMaterial({ color: 0x2f7dff, metalness: 0.8, roughness: 0.3 });
  for (const [x, y] of [[1, 1], [1, -1], [-1, 1], [-1, -1]]) {
    const s = cylinder(0.0022, 0.023, alu, 10);
    s.position.set(x * 0.01, y * 0.01, 0.012);
    g.add(s);
  }
  // Flight controller and ESC stack, companion board with its sensors.
  const pcbMat = new THREE.MeshStandardMaterial({ color: 0x14301f, roughness: 0.6 });
  for (const z of [0.008, 0.016]) {
    const b = new THREE.Mesh(new THREE.BoxGeometry(0.027, 0.027, 0.0016), pcbMat);
    b.position.z = z;
    g.add(b);
  }
  const xiao = new THREE.Mesh(new THREE.BoxGeometry(0.021, 0.0175, 0.004), new THREE.MeshStandardMaterial({ color: 0x0d5c99, roughness: 0.5 }));
  xiao.position.set(-0.004, 0, 0.0275);
  g.add(xiao);
  const tofMat = new THREE.MeshStandardMaterial({ color: 0x101010, roughness: 0.3 });
  for (const yaw of [0, 35, -35, 90, -90]) {
    const s = new THREE.Mesh(new THREE.BoxGeometry(0.004, 0.009, 0.006), tofMat);
    const r = (yaw * Math.PI) / 180;
    s.position.set(0.018 * Math.cos(r), 0.018 * Math.sin(r), 0.0275);
    s.rotation.z = r;
    g.add(s);
  }
  // Battery strapped underneath.
  const lipo = new THREE.Mesh(new THREE.BoxGeometry(0.066, 0.034, 0.024), new THREE.MeshStandardMaterial({ color: 0x23262b, roughness: 0.55 }));
  lipo.position.z = -0.0145;
  lipo.castShadow = true;
  g.add(lipo);
  const label = new THREE.Mesh(new THREE.BoxGeometry(0.0665, 0.0345, 0.008), new THREE.MeshStandardMaterial({ color: 0xffc928, roughness: 0.5 }));
  label.position.z = -0.0145;
  g.add(label);
  // Antenna.
  const ant = cylinder(0.0006, 0.035, new THREE.MeshStandardMaterial({ color: 0x111111 }), 6);
  ant.rotation.y = 0.9;
  ant.position.set(-0.03, 0, 0.03);
  g.add(ant);

  // Motors and tri-blade props, at the physics model's motor positions.
  const props: THREE.Group[] = [], blur: THREE.Mesh[] = [], frost: THREE.MeshStandardMaterial[] = [];
  const bell = new THREE.MeshStandardMaterial({ color: 0xc8ccd2, metalness: 0.9, roughness: 0.25 });
  const accent = new THREE.MeshStandardMaterial({ color: 0xd2232a, metalness: 0.6, roughness: 0.35 });
  MOTOR_ANGLES.forEach((deg, i) => {
    const r = (deg * Math.PI) / 180, x = PARAMS.arm * Math.cos(r), y = PARAMS.arm * Math.sin(r);
    const pad = cylinder(0.008, t, carbon, 20);
    pad.position.set(x, y, 0);
    g.add(pad);
    const stator = cylinder(0.009, 0.007, accent, 24);
    stator.position.set(x, y, t / 2 + 0.0035);
    const can = cylinder(0.0092, 0.006, bell, 24);
    can.position.set(x, y, t / 2 + 0.01);
    g.add(stator, can);
    const prop = new THREE.Group();
    prop.position.set(x, y, t / 2 + 0.0145);
    const color = i % 2 ? 0xff6a2b : 0x37c6ff;
    const pm = new THREE.MeshStandardMaterial({ color, roughness: 0.35, transparent: true, opacity: 0.95 });
    frost.push(pm);
    for (let k = 0; k < 3; k++) {
      const blade = new THREE.Mesh(new THREE.BoxGeometry(0.036, 0.0075, 0.0012), pm);
      blade.geometry.translate(0.019, 0, 0);
      blade.rotation.z = (k * 2 * Math.PI) / 3;
      blade.rotation.x = 0.18 * MOTOR_SPIN[i];
      prop.add(blade);
    }
    prop.add(cylinder(0.003, 0.004, accent, 12));
    props.push(prop);
    g.add(prop);
    const disc = new THREE.Mesh(new THREE.CircleGeometry(PARAMS.propRadius, 40), new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0, depthWrite: false, side: THREE.DoubleSide }));
    disc.position.copy(prop.position);
    blur.push(disc);
    g.add(disc);
  });
  // Navigation lights: red port (left), green starboard, white tail.
  const leds: THREE.Mesh[] = [];
  for (const [c, x, y] of [[0xff2020, 0.02, 0.012], [0x20ff60, 0.02, -0.012], [0xffffff, -0.035, 0]] as const) {
    const led = new THREE.Mesh(new THREE.SphereGeometry(0.0022, 10, 8), new THREE.MeshBasicMaterial({ color: c }));
    led.position.set(x, y, 0.004);
    leds.push(led);
    g.add(led);
  }
  return { group: g, props, blur, frost, leds };
}

// MARK: Weather particles

class Precipitation {
  readonly object: THREE.Object3D;
  private pos: Float32Array;
  private n: number;
  private kind: "rain" | "snow" | "wind";
  private seeds: Float32Array;
  constructor(kind: "rain" | "snow" | "wind", count: number, private half = 16, private height = 10) {
    this.kind = kind;
    this.n = count;
    const per = kind === "snow" ? 3 : 6;
    this.pos = new Float32Array(count * per);
    this.seeds = new Float32Array(count).map(() => Math.random());
    const geo = new THREE.BufferGeometry();
    geo.setAttribute("position", new THREE.BufferAttribute(this.pos, 3));
    if (kind === "snow") {
      this.object = new THREE.Points(geo, new THREE.PointsMaterial({ size: 0.1, map: dotTexture(), transparent: true, depthWrite: false, color: 0xffffff, opacity: 0.95 }));
    } else {
      const color = kind === "rain" ? 0xaec6dc : 0xffffff;
      this.object = new THREE.LineSegments(geo, new THREE.LineBasicMaterial({ color, transparent: true, opacity: kind === "rain" ? 0.45 : 0.18, depthWrite: false }));
    }
    this.object.frustumCulled = false;
    for (let i = 0; i < count; i++) this.respawn(i, new THREE.Vector3(), true);
  }

  private respawn(i: number, c: THREE.Vector3, anywhere: boolean): void {
    const x = c.x + (Math.random() * 2 - 1) * this.half, y = c.y + (Math.random() * 2 - 1) * this.half;
    const z = this.kind === "wind" ? 0.2 + Math.random() * 5 : anywhere ? Math.random() * this.height : this.height;
    const per = this.kind === "snow" ? 3 : 6;
    this.pos[i * per] = x; this.pos[i * per + 1] = y; this.pos[i * per + 2] = z;
    if (per === 6) { this.pos[i * per + 3] = x; this.pos[i * per + 4] = y; this.pos[i * per + 5] = z; }
  }

  /** Moves the particles by the wind for `dt`, around the point c. */
  update(dt: number, wind: V3, c: THREE.Vector3, t: number): void {
    const per = this.kind === "snow" ? 3 : 6;
    const fall = this.kind === "rain" ? 7.5 : this.kind === "snow" ? 0.9 : 0;
    const streak = this.kind === "rain" ? 0.035 : 0.12;
    for (let i = 0; i < this.n; i++) {
      const o = i * per, s = this.seeds[i];
      // Snow tumbles; the wind streaks show gust structure by varying a little per particle.
      const swirl = this.kind === "snow" ? 0.35 * Math.sin(t * 1.7 + s * 40) : 0;
      const vx = wind[0] * (0.85 + 0.3 * s) + swirl, vy = wind[1] * (0.85 + 0.3 * s) + swirl * 0.7, vz = wind[2] - fall * (0.8 + 0.4 * s);
      this.pos[o] += vx * dt; this.pos[o + 1] += vy * dt; this.pos[o + 2] += vz * dt;
      if (per === 6) {
        this.pos[o + 3] = this.pos[o] - vx * streak; this.pos[o + 4] = this.pos[o + 1] - vy * streak; this.pos[o + 5] = this.pos[o + 2] - vz * streak;
      }
      const dx = this.pos[o] - c.x, dy = this.pos[o + 1] - c.y;
      if (this.pos[o + 2] < 0 || Math.abs(dx) > this.half || Math.abs(dy) > this.half || (this.kind === "wind" && Math.random() < dt * 0.6)) this.respawn(i, c, this.kind === "wind");
    }
    ((this.object as THREE.Points).geometry.getAttribute("position") as THREE.BufferAttribute).needsUpdate = true;
  }
}

// MARK: The view

export class SimView {
  settings: SimSettings = { mission: "course", weather: 1, brain: "nn", seed: 1, speed: 1, camera: "chase", show: { beams: true, map: true, path: true } };
  playing = true;
  flight!: Flight;
  course: Course | null = null;
  /** Called when something the toolbar shows changes (play state, a finished flight). */
  onChange: () => void = () => {};

  private renderer: THREE.WebGLRenderer;
  private scene = new THREE.Scene();
  private camera = new THREE.PerspectiveCamera(55, 1, 0.02, 600);
  private controls: OrbitControls;
  private sun = new THREE.DirectionalLight(0xffffff, 2.5);
  private hemi = new THREE.HemisphereLight(0xffffff, 0x444444, 1);
  private sky: THREE.Mesh;
  private ground: THREE.Mesh;
  private world = new THREE.Group();
  private drone = buildDrone();
  private beams: THREE.LineSegments;
  private hitDots: THREE.Points;
  private cells: THREE.InstancedMesh;
  private pathLine: THREE.Line;
  private carrot: THREE.Mesh;
  private trail: THREE.Line;
  private trailPos = new Float32Array(1500 * 3);
  private trailCol = new Float32Array(1500 * 3);
  private trailN = 0;
  private marker: THREE.Mesh;
  private particles: Precipitation[] = [];
  private waypointMeshes: THREE.Mesh[] = [];
  private hud: HTMLElement;
  private card: HTMLElement;
  private banner: HTMLElement;
  private bench: HTMLElement;
  private active = false;
  private last = 0;
  private acc = 0;
  private frameNo = 0;
  private camPos = new THREE.Vector3(-3, -3, 3);
  private camLook = new THREE.Vector3();
  private benchRun: { cancel: boolean } | null = null;

  constructor(private host: HTMLElement) {
    this.renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
    this.renderer.setPixelRatio(window.devicePixelRatio);
    this.renderer.shadowMap.enabled = true;
    this.renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    this.renderer.toneMapping = THREE.ACESFilmicToneMapping;
    this.renderer.toneMappingExposure = 1.0;
    this.renderer.outputColorSpace = THREE.SRGBColorSpace;
    host.append(this.renderer.domElement);
    this.camera.up.set(0, 0, 1);
    this.controls = new OrbitControls(this.camera, this.renderer.domElement);
    this.controls.enableDamping = true;
    this.controls.enabled = false;
    this.renderer.domElement.addEventListener("pointerdown", () => {
      // Dragging in a following view switches to orbit around the drone.
      if (this.settings.camera === "chase" || this.settings.camera === "top") {
        this.settings.camera = "orbit";
        this.applyCamera();
        this.onChange();
      }
    });

    // Sky dome: a vertical gradient, the fog blends the far ground into its horizon.
    this.sky = new THREE.Mesh(
      new THREE.SphereGeometry(400, 32, 16),
      new THREE.ShaderMaterial({
        side: THREE.BackSide, depthWrite: false, fog: false,
        uniforms: { top: { value: new THREE.Color() }, horizon: { value: new THREE.Color() } },
        vertexShader: "varying vec3 vP; void main(){ vP = normalize(position); gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.0); }",
        fragmentShader: "uniform vec3 top; uniform vec3 horizon; varying vec3 vP; void main(){ float h = clamp(vP.z, 0.0, 1.0); gl_FragColor = vec4(mix(horizon, top, pow(h, 0.55)), 1.0); }",
      }),
    );
    this.scene.add(this.sky);
    const tex = fieldTexture();
    tex.wrapS = tex.wrapT = THREE.RepeatWrapping;
    tex.repeat.set(40, 40);
    this.ground = new THREE.Mesh(new THREE.PlaneGeometry(160, 160), new THREE.MeshStandardMaterial({ map: tex, roughness: 0.95 }));
    this.ground.position.set(20, 0, 0);
    this.ground.receiveShadow = true;
    this.scene.add(this.ground, this.world, this.hemi, this.sun, this.sun.target);
    this.sun.castShadow = true;
    this.sun.shadow.mapSize.set(4096, 4096);
    const sc = this.sun.shadow.camera;
    sc.left = -30; sc.right = 30; sc.top = 30; sc.bottom = -30; sc.near = 1; sc.far = 120;
    this.sun.shadow.bias = -0.0004;
    this.sun.shadow.normalBias = 0.02;
    this.drone.group.traverse((o) => { if ((o as THREE.Mesh).isMesh) (o as THREE.Mesh).castShadow = true; });
    this.scene.add(this.drone.group);

    // The companion computer's view.
    this.beams = new THREE.LineSegments(new THREE.BufferGeometry(), new THREE.LineBasicMaterial({ color: 0x46e0ff, transparent: true, opacity: 0.12, depthWrite: false }));
    this.beams.frustumCulled = false;
    this.hitDots = new THREE.Points(new THREE.BufferGeometry(), new THREE.PointsMaterial({ color: 0xff4d6d, size: 0.07, map: dotTexture(), transparent: true, depthWrite: false }));
    this.hitDots.frustumCulled = false;
    this.cells = new THREE.InstancedMesh(new THREE.BoxGeometry(0.19, 0.19, 0.19), new THREE.MeshStandardMaterial({ color: 0x29c4ff, transparent: true, opacity: 0.32, emissive: 0x0b5d80, depthWrite: false }), 6000);
    this.cells.count = 0;
    this.cells.frustumCulled = false;
    this.pathLine = new THREE.Line(new THREE.BufferGeometry(), new THREE.LineBasicMaterial({ color: 0xffe14d }));
    this.pathLine.frustumCulled = false;
    this.carrot = new THREE.Mesh(new THREE.SphereGeometry(0.035, 16, 12), new THREE.MeshBasicMaterial({ color: 0xffe14d }));
    const tg = new THREE.BufferGeometry();
    tg.setAttribute("position", new THREE.BufferAttribute(this.trailPos, 3));
    tg.setAttribute("color", new THREE.BufferAttribute(this.trailCol, 3));
    this.trail = new THREE.Line(tg, new THREE.LineBasicMaterial({ vertexColors: true, transparent: true, opacity: 0.9 }));
    this.trail.frustumCulled = false;
    this.marker = new THREE.Mesh(new THREE.RingGeometry(0.12, 0.16, 40), new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.5, depthWrite: false }));
    this.scene.add(this.beams, this.hitDots, this.cells, this.pathLine, this.carrot, this.trail, this.marker);

    this.hud = document.createElement("div");
    this.hud.className = "sim-hud float";
    this.card = document.createElement("div");
    this.card.className = "sim-card float";
    this.banner = document.createElement("div");
    this.banner.className = "sim-banner";
    this.banner.hidden = true;
    this.bench = document.createElement("div");
    this.bench.className = "sim-bench float";
    this.bench.hidden = true;
    host.append(this.hud, this.card, this.banner, this.bench);
    new ResizeObserver(() => this.resize()).observe(host);
    this.restart();
  }

  setActive(on: boolean): void {
    if (on === this.active) return;
    this.active = on;
    if (on) {
      this.resize();
      this.last = performance.now();
      requestAnimationFrame((t) => this.loop(t));
    }
  }

  set<K extends keyof SimSettings>(k: K, v: SimSettings[K]): void {
    this.settings[k] = v;
    if (k === "camera") this.applyCamera();
    else if (k !== "speed" && k !== "show") this.restart();
    this.onChange();
  }

  toggle(k: keyof SimSettings["show"]): void {
    this.settings.show[k] = !this.settings.show[k];
    this.onChange();
  }

  play(on = !this.playing): void {
    if (on && this.flight.finished) this.restart();
    this.playing = on;
    this.onChange();
  }

  /** A new flight with the current settings; `nextSeed` for another random draw of the weather. */
  restart(nextSeed = false): void {
    if (nextSeed) this.settings.seed++;
    const S = this.settings, w = WEATHERS[S.weather];
    this.course = S.mission === "course" ? obstacleCourse() : S.mission === "random" ? randomCourse(rng(S.seed * 7919)) : null;
    const sc: Scenario = this.course
      ? { weather: w, mission: { kind: "waypoints", course: this.course }, duration: 90, seed: S.seed }
      : { weather: w, mission: { kind: "hover", at: [0, 0, 1.6] }, duration: 40, seed: S.seed };
    this.flight = new Flight(PARAMS, brainOf(S.brain), sc);
    this.buildWorld(w);
    this.trailN = 0;
    this.acc = 0;
    this.banner.hidden = true;
    this.playing = true;
    const p = this.flight.s.p;
    this.camPos.set(p[0] - 2.5, p[1] - 1.2, p[2] + 1.2);
    this.camLook.set(p[0], p[1], p[2]);
    this.applyCamera();
  }

  private buildWorld(w: Weather): void {
    for (const c of [...this.world.children]) this.world.remove(c);
    for (const p of this.particles) this.scene.remove(p.object);
    this.particles = [];
    this.waypointMeshes = [];
    const look = lookOf(w);
    const sky = this.sky.material as THREE.ShaderMaterial;
    sky.uniforms.top.value.copy(look.skyTop);
    sky.uniforms.horizon.value.copy(look.skyHorizon);
    this.scene.background = look.skyHorizon;
    this.scene.fog = new THREE.FogExp2(look.skyHorizon.getHex(), fogDensity(w));
    const gm = this.ground.material as THREE.MeshStandardMaterial;
    gm.color.copy(look.ground);
    gm.roughness = 0.95 - 0.35 * look.wet;
    gm.metalness = 0;
    this.hemi.color.copy(look.skyTop).lerp(new THREE.Color(0xffffff), 0.5);
    this.hemi.groundColor.copy(look.ground).multiplyScalar(0.6);
    this.hemi.intensity = look.ambient;
    this.sun.intensity = look.sun;
    this.sun.position.set(-8, -22, 30);
    this.sun.target.position.set(20, 0, 0);
    this.renderer.toneMappingExposure = w.sun === 0 && w.rainMmH === 0 && w.snowMmH === 0 && !Number.isFinite(w.fogVisibilityM) ? 1.05 : 1.0;

    if (this.course) {
      const mats = new Map<string, THREE.Material>();
      const mat = (o: Obstacle) => {
        const c = o.color ?? "#8b93a1";
        if (!mats.has(c)) {
          const gate = c === "#ff6a2b";
          mats.set(c, new THREE.MeshStandardMaterial({ color: c, roughness: gate ? 0.35 : 0.75, metalness: gate ? 0.2 : 0, emissive: gate ? new THREE.Color(c) : new THREE.Color(0), emissiveIntensity: gate ? 0.35 : 0 }));
        }
        return mats.get(c)!;
      };
      for (const o of this.course.obstacles) {
        if (o.kind === "box") this.world.add(boxMesh(o.min, o.max, mat(o)));
        else {
          const c = cylinder(o.r, o.z1 - o.z0, mat(o), 32);
          c.position.set(o.c[0], o.c[1], (o.z0 + o.z1) / 2);
          this.world.add(c);
          // Hazard bands.
          for (let z = o.z0 + 0.4; z < o.z1; z += 0.8) {
            const band = cylinder(o.r + 0.004, 0.18, new THREE.MeshStandardMaterial({ color: 0xff3b3b, roughness: 0.6 }), 32);
            band.position.set(o.c[0], o.c[1], z);
            this.world.add(band);
          }
        }
      }
      const wps = this.course.waypoints;
      const end = wps[wps.length - 1];
      const pad = new THREE.Mesh(new THREE.CircleGeometry(0.6, 48), new THREE.MeshStandardMaterial({ map: padTexture(), roughness: 0.7 }));
      pad.position.set(end[0], end[1], 0.005);
      pad.receiveShadow = true;
      const start = new THREE.Mesh(new THREE.CircleGeometry(0.5, 48), new THREE.MeshStandardMaterial({ color: 0x2b2f36, roughness: 0.7 }));
      start.position.set(this.course.start[0], this.course.start[1], 0.004);
      this.world.add(pad, start);
      for (const p of wps.slice(0, -1)) {
        const m = new THREE.Mesh(new THREE.TorusGeometry(0.16, 0.012, 8, 32), new THREE.MeshBasicMaterial({ color: 0xffe14d, transparent: true, opacity: 0.55 }));
        m.position.set(p[0], p[1], p[2]);
        m.rotation.y = Math.PI / 2;
        this.waypointMeshes.push(m);
        this.world.add(m);
      }
    } else {
      const pad = new THREE.Mesh(new THREE.CircleGeometry(0.6, 48), new THREE.MeshStandardMaterial({ map: padTexture(), roughness: 0.7 }));
      pad.position.z = 0.005;
      this.world.add(pad);
      const target = new THREE.Mesh(new THREE.TorusGeometry(0.25, 0.01, 8, 48), new THREE.MeshBasicMaterial({ color: 0xffe14d, transparent: true, opacity: 0.7 }));
      target.position.set(0, 0, 1.6);
      this.world.add(target);
    }
    // A few trees and a windsock far off, for scale and to show the wind.
    if (w.sun > 0 || w.snowMmH > 0 || w.rainMmH > 0 || Number.isFinite(w.fogVisibilityM)) {
      const r = rng(5);
      const trunk = new THREE.MeshStandardMaterial({ color: 0x5b4330, roughness: 0.9 });
      const leaves = new THREE.MeshStandardMaterial({ color: w.snowMmH > 0 ? 0xdfe6ea : w.altitudeM > 1500 ? 0x5f6e3a : 0x2f5a2a, roughness: 0.9 });
      for (let i = 0; i < 26; i++) {
        // Behind the course from the overview camera, and well clear of it on the near side.
        const x = r.range(-20, 65), y = i % 3 ? r.range(12, 45) : -r.range(40, 70), h = r.range(4, 9);
        const tr = cylinder(0.18, h * 0.4, trunk, 8);
        tr.position.set(x, y, h * 0.2);
        const crown = new THREE.Mesh(new THREE.ConeGeometry(h * 0.28, h * 0.75, 10), leaves);
        crown.geometry.rotateX(Math.PI / 2);
        crown.position.set(x, y, h * 0.62);
        crown.castShadow = true;
        this.world.add(tr, crown);
      }
    } else {
      // Indoor arena: walls with light strips.
      const wall = new THREE.MeshStandardMaterial({ color: 0x2d3139, roughness: 0.9 });
      this.world.add(boxMesh([-8, -12, 0], [50, -11.6, 9], wall), boxMesh([-8, 11.6, 0], [50, 12, 9], wall), boxMesh([-8.4, -12, 0], [-8, 12, 9], wall), boxMesh([50, -12, 0], [50.4, 12, 9], wall));
      const strip = new THREE.MeshBasicMaterial({ color: 0xdfe9ff });
      for (let x = -4; x < 50; x += 6) this.world.add(boxMesh([x, -11.5, 8.6], [x + 3, 11.5, 8.7], strip));
    }
    const sock = new THREE.Group();
    const pole = cylinder(0.04, 4, new THREE.MeshStandardMaterial({ color: 0xdddddd, metalness: 0.6, roughness: 0.4 }), 8);
    pole.position.z = 2;
    sock.add(pole);
    const cone = new THREE.Mesh(new THREE.CylinderGeometry(0.22, 0.1, 1.2, 16, 1, true), new THREE.MeshStandardMaterial({ color: 0xff6a2b, side: THREE.DoubleSide, roughness: 0.7 }));
    cone.geometry.rotateZ(Math.PI / 2);
    cone.geometry.translate(0.6, 0, 0);
    cone.name = "sock";
    cone.position.z = 3.9;
    sock.add(cone);
    sock.position.set(-2, 5, 0);
    this.world.add(sock);

    if (w.rainMmH > 0) this.particles.push(new Precipitation("rain", Math.min(9000, 300 * w.rainMmH)));
    if (w.snowMmH > 0) this.particles.push(new Precipitation("snow", Math.min(9000, 2200 * w.snowMmH)));
    const meanWind = Math.hypot(w.wind.mean[0], w.wind.mean[1]);
    if (meanWind > 1) this.particles.push(new Precipitation("wind", Math.round(60 * meanWind), 14));
    for (const p of this.particles) this.scene.add(p.object);
  }

  private applyCamera(): void {
    this.controls.enabled = this.settings.camera === "orbit";
    const p = this.flight.s.p;
    if (this.settings.camera === "orbit") {
      this.controls.target.set(p[0], p[1], p[2]);
      if (this.camera.position.distanceTo(this.controls.target) > 30) this.camera.position.set(p[0] - 2.5, p[1] - 2.5, p[2] + 1.5);
    }
    this.camera.fov = this.settings.camera === "fpv" ? 95 : 50;
    this.camera.updateProjectionMatrix();
  }

  private resize(): void {
    const w = this.host.clientWidth, h = this.host.clientHeight;
    if (!w || !h) return;
    this.renderer.setSize(w, h, false);
    this.renderer.domElement.style.width = "100%";
    this.renderer.domElement.style.height = "100%";
    this.camera.aspect = w / h;
    this.camera.updateProjectionMatrix();
  }

  private loop(now: number): void {
    if (!this.active) return;
    const dt = Math.min(0.1, (now - this.last) / 1000);
    this.last = now;
    const f = this.flight;
    if (this.playing && !f.finished) {
      this.acc += dt * this.settings.speed;
      const ticks = Math.floor(this.acc / 0.002);
      this.acc -= ticks * 0.002;
      for (let i = 0; i < ticks && !f.finished; i++) f.tick();
      if (f.finished) {
        this.playing = false;
        this.showResult();
        this.onChange();
      }
    }
    this.draw(this.playing ? dt * this.settings.speed : 0, now / 1000);
    requestAnimationFrame((t) => this.loop(t));
  }

  private draw(dt: number, time: number): void {
    const f = this.flight, s = f.s, S = this.settings;
    const p = new THREE.Vector3(...s.p);
    // Drone pose (the physics quaternion is [w, x, y, z]).
    this.drone.group.position.copy(p);
    this.drone.group.quaternion.set(s.q[1], s.q[2], s.q[3], s.q[0]);
    this.drone.props.forEach((pr, i) => {
      const w = s.omega[i];
      // Shown slowed down (a real 3-inch prop turns at 300+ rev/s), with a blur disc.
      pr.rotation.z += MOTOR_SPIN[i] * Math.min(w * 0.004, 0.9) * (dt > 0 ? 1 : 0);
      const spin = Math.min(1, w / PARAMS.omegaMax);
      (this.drone.blur[i].material as THREE.MeshBasicMaterial).opacity = 0.1 + 0.22 * spin;
      this.drone.frost[i].opacity = 1 - 0.75 * spin;
      this.drone.frost[i].color.setHex(i % 2 ? 0xff6a2b : 0x37c6ff).lerp(new THREE.Color(0xf4fbff), f.exposure.ice);
    });
    const blink = Math.sin(time * 12) > 0.6;
    this.drone.leds[2].visible = blink;
    this.marker.position.set(s.p[0], s.p[1], 0.01);
    // The drone is 13 cm across: from afar, the ring under it grows so it can be found.
    this.marker.scale.setScalar(Math.max(1, this.camera.position.distanceTo(p) / 6));
    (this.marker.material as THREE.MeshBasicMaterial).opacity = 0.35 + 0.3 * Math.max(0, 1 - s.p[2] / 6);

    // Trail coloured by speed.
    if (this.frameNo++ % 2 === 0 && dt > 0) {
      const n = 1500;
      if (this.trailN >= n) {
        this.trailPos.copyWithin(0, 3);
        this.trailCol.copyWithin(0, 3);
        this.trailN = n - 1;
      }
      const sp = Math.min(1, Math.hypot(...s.v) / 4);
      const c = new THREE.Color().setHSL(0.55 - 0.55 * sp, 0.95, 0.55);
      this.trailPos.set([s.p[0], s.p[1], s.p[2]], this.trailN * 3);
      this.trailCol.set([c.r, c.g, c.b], this.trailN * 3);
      this.trailN++;
      this.trail.geometry.setDrawRange(0, this.trailN);
      this.trail.geometry.attributes.position.needsUpdate = true;
      this.trail.geometry.attributes.color.needsUpdate = true;
    }

    // Sensors, map and plan.
    this.beams.visible = this.hitDots.visible = S.show.beams && !!f.planner;
    if (this.beams.visible) {
      const seg: number[] = [], dots: number[] = [];
      for (const h of f.hits) {
        seg.push(s.p[0], s.p[1], s.p[2], h.point[0], h.point[1], h.point[2]);
        if (h.hit) dots.push(...h.point);
      }
      this.beams.geometry.setAttribute("position", new THREE.Float32BufferAttribute(seg, 3));
      this.hitDots.geometry.setAttribute("position", new THREE.Float32BufferAttribute(dots, 3));
    }
    this.cells.visible = S.show.map && !!f.planner;
    if (this.cells.visible && this.frameNo % 10 === 0) {
      const m = new THREE.Matrix4();
      const cells = f.planner!.map.occupiedCells();
      this.cells.count = Math.min(cells.length, 6000);
      for (let i = 0; i < this.cells.count; i++) this.cells.setMatrixAt(i, m.makeTranslation(cells[i][0], cells[i][1], cells[i][2]));
      this.cells.instanceMatrix.needsUpdate = true;
    }
    this.pathLine.visible = this.carrot.visible = S.show.path && !!f.plan;
    if (this.pathLine.visible && f.plan) {
      this.pathLine.geometry.setAttribute("position", new THREE.Float32BufferAttribute([s.p[0], s.p[1], s.p[2], ...f.plan.path.slice(1).flat()], 3));
      this.carrot.position.set(...f.plan.carrot);
    }
    const idx = f.plan?.index ?? 0;
    this.waypointMeshes.forEach((m, i) => {
      const mat = m.material as THREE.MeshBasicMaterial;
      mat.opacity = i < idx ? 0.12 : i === idx ? 1 : 0.5;
      m.scale.setScalar(i === idx ? 1 + 0.15 * Math.sin(time * 6) : 1);
    });

    // Weather.
    const wind = f.windNow;
    for (const pt of this.particles) pt.update(dt, wind, p, time);
    const sock = this.world.getObjectByName("sock");
    if (sock) {
      const sp = Math.hypot(wind[0], wind[1]);
      sock.rotation.z = Math.atan2(wind[1], wind[0]);
      sock.rotation.y = 1.3 * Math.max(0, 1 - sp / 8) + 0.05 * Math.sin(time * 9);
    }

    // Camera.
    const v = new THREE.Vector3(...s.v);
    const R = new THREE.Matrix4().makeRotationFromQuaternion(this.drone.group.quaternion);
    const fwd = new THREE.Vector3(1, 0, 0).applyMatrix4(R);
    fwd.z = 0;
    if (fwd.lengthSq() < 1e-6) fwd.set(1, 0, 0);
    fwd.normalize();
    const k = 1 - Math.exp(-4 * Math.max(dt, 0.016));
    if (S.camera === "chase") {
      const heading = v.length() > 0.6 ? new THREE.Vector3(v.x, v.y, 0).normalize() : fwd;
      const want = p.clone().addScaledVector(heading, -1.9).add(new THREE.Vector3(0, 0, 0.75));
      want.addScaledVector(new THREE.Vector3(-heading.y, heading.x, 0), 0.4);
      this.camPos.lerp(want, k);
      // Never behind a post or a wall: slide in toward the drone until the camera is clear.
      if (this.course) {
        const obs = this.course.obstacles;
        for (let i = 0; i < 12 && clearance(obs, [this.camPos.x, this.camPos.y, this.camPos.z]) < 0.2; i++) this.camPos.lerp(p, 0.2);
      }
      this.camLook.lerp(p.clone().addScaledVector(heading, 0.9), k * 1.5);
      this.camera.position.copy(this.camPos);
      this.camera.up.set(0, 0, 1);
      this.camera.lookAt(this.camLook);
    } else if (S.camera === "top") {
      const c = this.course ? new THREE.Vector3(20, 1, 0) : new THREE.Vector3(0, 0, 1);
      this.camera.position.lerp(this.course ? new THREE.Vector3(12, -17, 15) : new THREE.Vector3(-4, -6, 4), k);
      this.camera.up.set(0, 0, 1);
      this.camera.lookAt(this.course ? c : p);
    } else if (S.camera === "fpv") {
      const up = new THREE.Vector3(0, 0, 1).applyMatrix4(R);
      const ahead = new THREE.Vector3(1, 0, 0).applyMatrix4(R);
      // A 25° uptilted camera, as FPV pilots mount them.
      const cam = ahead.clone().multiplyScalar(Math.cos(0.44)).addScaledVector(up, Math.sin(0.44));
      this.camera.position.copy(p).addScaledVector(ahead, 0.03).addScaledVector(up, 0.03);
      this.camera.up.copy(up);
      this.camera.lookAt(this.camera.position.clone().add(cam));
    } else {
      const delta = p.clone().sub(this.controls.target);
      this.controls.target.add(delta);
      this.camera.position.add(delta);
      this.controls.update();
    }
    this.drone.group.visible = S.camera !== "fpv";
    this.sun.position.set(p.x - 8, p.y - 22, 30);
    this.sun.target.position.set(p.x, p.y, 0);
    this.renderer.render(this.scene, this.camera);
    if (this.frameNo % 6 === 0) this.renderHud();
  }

  private renderHud(): void {
    const f = this.flight, s = f.s, w = f.sc.weather;
    const speed = Math.hypot(...s.v), windNow = Math.hypot(f.windNow[0], f.windNow[1]);
    const windDir = (Math.atan2(f.windNow[1], f.windNow[0]) * 180) / Math.PI;
    const rho = airDensity(w);
    const thrust = f.exposure.thrustFactor() * (rho / 1.225);
    const twr = (4 * MOTOR_THRUST_3S_N * thrust) / ((MASS + f.exposure.snowKg) * 9.81);
    const total = f.planner ? f.planner.waypoints.length : 1;
    const reached = f.plan ? f.plan.index + (f.plan.done ? 1 : 0) : 0;
    const motors = s.omega.map((o) => Math.round((100 * o) / PARAMS.omegaMax));
    const bar = (v: number, cls = "") => `<span class="meter ${cls}"><i style="width:${Math.max(0, Math.min(100, v)).toFixed(0)}%"></i></span>`;
    const status = s.crashed ? `<b class="bad">CRASHED</b>` : f.collided ? `<b class="bad">COLLISION</b>` : f.plan?.done ? `<b class="good">LANDED</b>` : f.plan?.blocked ? `<b class="warn">SEARCHING</b>` : `<b class="good">FLYING</b>`;
    this.hud.innerHTML = `
      <div class="row big"><span>${s.t.toFixed(1)} s</span>${status}</div>
      <div class="grid">
        <span>Speed</span><b>${speed.toFixed(1)} m/s</b>
        <span>Altitude</span><b>${s.p[2].toFixed(2)} m</b>
        <span>Wind</span><b>${windNow.toFixed(1)} m/s <svg width="12" height="12" viewBox="-6 -6 12 12" style="transform:rotate(${-windDir}deg)"><path d="M-5 0H4M1-3l3 3-3 3" stroke="currentColor" fill="none" stroke-width="1.6"/></svg></b>
        <span>Air</span><b>${w.temperatureC.toFixed(0)} °C · ${rho.toFixed(3)} kg/m³</b>
        <span>Thrust</span><b>${(thrust * 100).toFixed(0)} % · T/W ${twr.toFixed(1)}</b>
        ${f.exposure.ice > 0.01 ? `<span>Ice</span><b class="warn">${(f.exposure.ice * 100).toFixed(0)} %</b>` : ""}
        ${f.exposure.snowKg > 0.0005 ? `<span>Snow load</span><b>${(f.exposure.snowKg * 1000).toFixed(1)} g</b>` : ""}
        <span>Sensors</span><b>${f.tof.range.toFixed(1)} m${f.tof.falseRate > 0 ? ` · ${(f.tof.falseRate * 100).toFixed(0)} % false` : ""}</b>
        <span>Battery</span><b>${f.battery.voltage.toFixed(2)} V ${bar(f.battery.soc * 100, f.battery.soc < 0.25 ? "low" : "")}</b>
        ${f.planner ? `<span>Waypoints</span><b>${Math.min(reached, total)} / ${total}</b>` : ""}
        ${f.brain.policy ? `<span>NN residual</span><b>${Math.hypot(...f.residual).toFixed(2)} m/s²</b>` : ""}
      </div>
      <div class="motors">${motors.map((m, i) => `<div><span>M${i + 1}</span>${bar(m, m > 95 ? "low" : "")}</div>`).join("")}</div>`;
    const P = FRAME;
    this.card.innerHTML = `
      <div class="title">${esc(w.name)}</div>
      <div class="sub">${esc(MISSIONS.find((m) => m.id === this.settings.mission)!.label)} · ${esc(BRAINS.find((b) => b.id === this.settings.brain)!.label)} · seed ${this.settings.seed}</div>
      <div class="sep"></div>
      <div class="sub">Generative frame: ${P.arm.toFixed(1)} mm arms, ${P.thickness} mm carbon, ${P.massG.toFixed(1)} g, ${P.stress.toFixed(0)} MPa, ${P.deflection.toFixed(3)} mm</div>
      <div class="sub">All-up ${(MASS * 1000).toFixed(0)} g · ${PARTS.length} Amazon parts · tracking cost ${TRAINED_SCORE.defaultPid.toFixed(2)} → ${TRAINED_SCORE.tunedPidNn.toFixed(2)} trained</div>`;
  }

  private showResult(): void {
    const f = this.flight, s = f.s;
    const ok = f.planner ? !!f.plan?.done : !s.crashed;
    const why = s.crashed ? "Crashed" : f.collided ? "Hit an obstacle" : f.planner ? (f.plan?.done ? "Course complete" : "Out of time") : "Hover held";
    const err = f.errN ? Math.sqrt(f.errSq / f.errN) : 0;
    this.banner.className = `sim-banner ${ok ? "good" : "bad"}`;
    this.banner.innerHTML = `<b>${why}</b><span>${s.t.toFixed(1)} s · ${(f.energyJ / 3600).toFixed(2)} Wh${f.planner ? ` · closest ${f.minClearance.toFixed(2)} m` : ` · RMS ${err.toFixed(2)} m`}</span>`;
    this.banner.hidden = false;
  }

  /** Sets up a scene and flies it to `at` seconds at once (screenshots for the docs and CI):
   *  e.g. {"weather":3,"camera":"chase","at":12}. */
  stage(o: Partial<Omit<SimSettings, "show">> & { at?: number }): void {
    const { at = 0, ...rest } = o;
    Object.assign(this.settings, rest);
    this.restart();
    while (!this.flight.finished && this.flight.s.t < at) this.flight.tick();
    for (let i = 0; i < 4; i++) this.draw(0.5, at + i * 0.5);
    this.playing = !this.flight.finished;
    if (this.flight.finished) this.showResult();
    this.onChange();
  }

  /** Flies every weather with the current mission and controller (three seeds each), off the
   *  render loop in small slices, and shows the table. */
  benchmark(): void {
    if (this.benchRun) { this.benchRun.cancel = true; this.benchRun = null; this.bench.hidden = true; this.onChange(); return; }
    const run = { cancel: false };
    this.benchRun = run;
    const rows: { name: string; ok: number; n: number; time: number[]; note: string[] }[] = WEATHERS.map((w) => ({ name: w.name, ok: 0, n: 0, time: [], note: [] }));
    const jobs = WEATHERS.flatMap((_, wi) => [1, 2, 3].map((seed) => ({ wi, seed })));
    const brain = this.settings.brain, mission = this.settings.mission;
    let j = 0;
    const show = () => {
      this.bench.hidden = false;
      this.bench.innerHTML = `<div class="title">Benchmark · ${esc(BRAINS.find((b) => b.id === brain)!.label)}</div>
        <table>${rows.map((r) => `<tr><td>${esc(r.name)}</td><td>${r.n ? `${r.ok}/${r.n}` : "…"}</td><td>${r.time.length ? `${(r.time.reduce((a, b) => a + b, 0) / r.time.length).toFixed(1)} s` : ""}</td><td class="note">${esc(r.note.join(", "))}</td></tr>`).join("")}</table>
        <div class="sub">${j < jobs.length ? `Flying ${j + 1} of ${jobs.length}…` : `${rows.reduce((a, r) => a + r.ok, 0)} of ${jobs.length} flights succeeded`}</div>`;
    };
    const next = () => {
      if (run.cancel) return;
      if (j >= jobs.length) { show(); this.benchRun = null; this.onChange(); return; }
      const { wi, seed } = jobs[j];
      const w = WEATHERS[wi];
      const course = mission === "random" ? randomCourse(rng(seed * 7919)) : obstacleCourse();
      const sc: Scenario = mission === "hover"
        ? { weather: w, mission: { kind: "hover", at: [0, 0, 1.6] }, duration: 20, seed }
        : { weather: w, mission: { kind: "waypoints", course }, duration: 90, seed };
      const f = new Flight(PARAMS, brainOf(brain), sc);
      while (!f.finished) f.tick();
      const r = rows[wi];
      r.n++;
      const ok = mission === "hover" ? !f.s.crashed : !!f.plan?.done;
      if (ok) { r.ok++; r.time.push(f.s.t); } else r.note.push(f.s.crashed ? "crash" : f.collided ? "hit" : "timeout");
      if (mission === "hover" && f.errN) r.note.push(`${Math.sqrt(f.errSq / f.errN).toFixed(2)} m`);
      j++;
      show();
      setTimeout(next, 0);
    };
    show();
    this.onChange();
    setTimeout(next, 30);
  }

  get benchmarking(): boolean {
    return !!this.benchRun;
  }
}

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
