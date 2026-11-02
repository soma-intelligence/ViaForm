import * as THREE from "three";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
import type { SceneData } from "../shared/api";

/** What a click hit: a body's face, at a world point, with the face's world normal. */
export interface Hit {
  body: string;
  face: number;
  point: [number, number, number];
  normal: [number, number, number];
}

const SELECT = new THREE.Color("#ffb347");
const HOVER = new THREE.Color("#7fb2ff");

/** The 3D view: the engine's meshes and edges, z up, orbit with the right or middle button. */
export class Viewport {
  readonly renderer: THREE.WebGLRenderer;
  readonly camera: THREE.PerspectiveCamera;
  readonly controls: OrbitControls;
  private scene = new THREE.Scene();
  private model = new THREE.Group();
  private grid: THREE.GridHelper;
  private meshes: THREE.Mesh[] = [];
  private raycaster = new THREE.Raycaster();
  private selected = new Set<string>();
  private hovered: string | null = null;
  private fitted = false;
  onClick: (hit: Hit | null, e: MouseEvent) => void = () => {};
  onDoubleClick: (hit: Hit | null) => void = () => {};
  onContext: (hit: Hit | null, e: MouseEvent) => void = () => {};

  constructor(private host: HTMLElement) {
    this.renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, preserveDrawingBuffer: true });
    this.renderer.setClearColor(0x000000, 0);
    this.renderer.setPixelRatio(window.devicePixelRatio);
    host.appendChild(this.renderer.domElement);

    THREE.Object3D.DEFAULT_UP.set(0, 0, 1);
    this.camera = new THREE.PerspectiveCamera(35, 1, 0.1, 100000);
    this.camera.up.set(0, 0, 1);
    this.camera.position.set(120, -160, 110);
    this.controls = new OrbitControls(this.camera, this.renderer.domElement);
    this.controls.enableDamping = true;
    this.controls.dampingFactor = 0.18;
    // Left button selects; orbit with the right button, pan with the middle one (or Shift+right).
    this.controls.mouseButtons = { LEFT: null as unknown as THREE.MOUSE, MIDDLE: THREE.MOUSE.PAN, RIGHT: THREE.MOUSE.ROTATE };

    this.scene.add(new THREE.HemisphereLight(0xf4f6ff, 0x3a3328, 1.6));
    const key = new THREE.DirectionalLight(0xffffff, 2.2);
    key.position.set(1, -1.4, 2.2);
    this.scene.add(key);
    const rim = new THREE.DirectionalLight(0xb8c8ff, 0.7);
    rim.position.set(-1.5, 1.2, 0.6);
    this.scene.add(rim);
    this.camera.add(new THREE.PointLight(0xffffff, 0.4, 0, 0));
    this.scene.add(this.camera);

    this.grid = new THREE.GridHelper(400, 40, 0x3a4150, 0x262b33);
    this.grid.rotation.x = Math.PI / 2;
    this.scene.add(this.grid);
    this.scene.add(this.model);
    this.scene.add(axes());

    this.bindPointer();
    new ResizeObserver(() => this.resize()).observe(host);
    this.resize();
    const loop = () => {
      this.controls.update();
      this.renderer.render(this.scene, this.camera);
      requestAnimationFrame(loop);
    };
    loop();
  }

  private resize(): void {
    const { clientWidth: w, clientHeight: h } = this.host;
    if (w === 0 || h === 0) return;
    this.renderer.setSize(w, h, false);
    this.renderer.domElement.style.width = `${w}px`;
    this.renderer.domElement.style.height = `${h}px`;
    this.camera.aspect = w / h;
    this.camera.updateProjectionMatrix();
  }

  /** Replaces the model with the engine's scene. */
  show(s: SceneData): void {
    for (const o of [...this.model.children]) {
      this.model.remove(o);
      o.traverse((c) => {
        const m = c as THREE.Mesh;
        m.geometry?.dispose();
        (m.material as THREE.Material | undefined)?.dispose?.();
      });
    }
    this.meshes = [];
    const top = s.background.slice(0, 4), bottom = s.background.slice(4, 8);
    if (top.some((v) => v > 0)) {
      this.host.style.background = `linear-gradient(${rgb(top)}, ${rgb(bottom)})`;
    }
    for (const m of s.meshes) {
      const g = new THREE.BufferGeometry();
      g.setAttribute("position", new THREE.BufferAttribute(m.positions, 3));
      g.setAttribute("normal", new THREE.BufferAttribute(m.normals, 3));
      g.setIndex(new THREE.BufferAttribute(m.indices, 1));
      const base = new THREE.Color(m.color[0], m.color[1], m.color[2]);
      const mat = new THREE.MeshStandardMaterial({
        color: base,
        metalness: 0.05,
        roughness: 0.55,
        transparent: m.color[3] < 0.999,
        opacity: m.color[3],
        polygonOffset: true,
        polygonOffsetFactor: 1,
        polygonOffsetUnits: 1,
      });
      const mesh = new THREE.Mesh(g, mat);
      mesh.userData = { body: m.body, triFace: m.triFace, base };
      this.model.add(mesh);
      this.meshes.push(mesh);

      // B-rep edges: one polyline per edge, drawn as segments.
      const seg: number[] = [];
      for (let e = 0; e + 1 < m.edgeOffsets.length; e++) {
        for (let i = m.edgeOffsets[e]; i + 1 < m.edgeOffsets[e + 1]; i++) {
          seg.push(m.edgePoints[i * 3], m.edgePoints[i * 3 + 1], m.edgePoints[i * 3 + 2]);
          seg.push(m.edgePoints[i * 3 + 3], m.edgePoints[i * 3 + 4], m.edgePoints[i * 3 + 5]);
        }
      }
      if (seg.length) {
        const eg = new THREE.BufferGeometry();
        eg.setAttribute("position", new THREE.Float32BufferAttribute(seg, 3));
        this.model.add(new THREE.LineSegments(eg, new THREE.LineBasicMaterial({ color: 0x15181d, transparent: true, opacity: 0.75 })));
      }
    }
    for (const l of s.lines) {
      if (l.points.length < 6) continue;
      const g = new THREE.BufferGeometry();
      g.setAttribute("position", new THREE.BufferAttribute(l.points, 3));
      const mat = new THREE.LineBasicMaterial({ color: new THREE.Color(l.color[0], l.color[1], l.color[2]), transparent: true, opacity: l.color[3], depthTest: !l.onTop });
      const line = new THREE.Line(g, mat);
      if (l.onTop) line.renderOrder = 10;
      this.model.add(line);
    }
    this.paint();
    if (!this.fitted && s.meshes.length) {
      this.fit();
      this.fitted = true;
    }
  }

  /** Frames every body. */
  fit(): void {
    const box = new THREE.Box3().setFromObject(this.model);
    if (box.isEmpty()) return;
    const c = box.getCenter(new THREE.Vector3());
    const r = Math.max(box.getSize(new THREE.Vector3()).length() / 2, 5);
    const dir = this.camera.position.clone().sub(this.controls.target).normalize();
    const d = r / Math.sin(THREE.MathUtils.degToRad(this.camera.fov / 2)) * 1.1;
    this.controls.target.copy(c);
    this.camera.position.copy(c).addScaledVector(dir, d);
    const size = Math.pow(10, Math.ceil(Math.log10(r * 4)));
    this.grid.scale.setScalar(size / 400);
  }

  /** Looks at the model from a named direction. */
  look(dir: "top" | "front" | "right" | "home"): void {
    const v = { top: [0, -0.0001, 1], front: [0, -1, 0], right: [1, 0, 0], home: [0.55, -0.7, 0.5] }[dir];
    this.camera.position.copy(this.controls.target).add(new THREE.Vector3(...v).normalize().multiplyScalar(this.camera.position.distanceTo(this.controls.target)));
  }

  select(bodies: Iterable<string>): void {
    this.selected = new Set(bodies);
    this.paint();
  }

  private paint(): void {
    for (const m of this.meshes) {
      const mat = m.material as THREE.MeshStandardMaterial;
      const body = m.userData.body as string;
      mat.color.copy(m.userData.base as THREE.Color);
      mat.emissive.set(0x000000);
      if (this.selected.has(body)) mat.emissive.copy(SELECT).multiplyScalar(0.35);
      else if (this.hovered === body) mat.emissive.copy(HOVER).multiplyScalar(0.18);
    }
  }

  /** The face under a client point. */
  pick(x: number, y: number): Hit | null {
    const r = this.renderer.domElement.getBoundingClientRect();
    const ndc = new THREE.Vector2(((x - r.left) / r.width) * 2 - 1, -((y - r.top) / r.height) * 2 + 1);
    this.raycaster.setFromCamera(ndc, this.camera);
    const hit = this.raycaster.intersectObjects(this.meshes, false)[0];
    if (!hit || hit.faceIndex == null || !hit.face) return null;
    const mesh = hit.object as THREE.Mesh;
    const n = hit.face.normal.clone().transformDirection(mesh.matrixWorld);
    if (n.dot(this.raycaster.ray.direction) > 0) n.negate();
    const tri = mesh.userData.triFace as Uint32Array;
    return {
      body: mesh.userData.body as string,
      face: tri[hit.faceIndex] ?? -1,
      point: [hit.point.x, hit.point.y, hit.point.z],
      normal: [n.x, n.y, n.z],
    };
  }

  /** The ground (z = 0) under a client point, on the grid's step. */
  ground(x: number, y: number, step = 1): [number, number, number] | null {
    const r = this.renderer.domElement.getBoundingClientRect();
    const ndc = new THREE.Vector2(((x - r.left) / r.width) * 2 - 1, -((y - r.top) / r.height) * 2 + 1);
    this.raycaster.setFromCamera(ndc, this.camera);
    const p = this.raycaster.ray.intersectPlane(new THREE.Plane(new THREE.Vector3(0, 0, 1), 0), new THREE.Vector3());
    return p ? [Math.round(p.x / step) * step, Math.round(p.y / step) * step, 0] : null;
  }

  private bindPointer(): void {
    const el = this.renderer.domElement;
    let down: { x: number; y: number; b: number } | null = null;
    el.addEventListener("pointerdown", (e) => (down = { x: e.clientX, y: e.clientY, b: e.button }));
    el.addEventListener("pointerup", (e) => {
      if (!down) return;
      const still = Math.hypot(e.clientX - down.x, e.clientY - down.y) < 4;
      const b = down.b;
      down = null;
      if (!still) return;
      if (b === 0) this.onClick(this.pick(e.clientX, e.clientY), e);
      if (b === 2) this.onContext(this.pick(e.clientX, e.clientY), e);
    });
    el.addEventListener("dblclick", (e) => this.onDoubleClick(this.pick(e.clientX, e.clientY)));
    el.addEventListener("contextmenu", (e) => e.preventDefault());
    el.addEventListener("pointermove", (e) => {
      if (down) return;
      const h = this.pick(e.clientX, e.clientY)?.body ?? null;
      if (h !== this.hovered) {
        this.hovered = h;
        this.paint();
      }
    });
  }

  /** A PNG of the view, for screenshots. */
  snapshot(): string {
    return this.renderer.domElement.toDataURL("image/png");
  }
}

function rgb(c: number[]): string {
  return `rgb(${Math.round(c[0] * 255)}, ${Math.round(c[1] * 255)}, ${Math.round(c[2] * 255)})`;
}

function axes(): THREE.Group {
  const g = new THREE.Group();
  const add = (to: [number, number, number], color: number) => {
    const geo = new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(0, 0, 0), new THREE.Vector3(...to)]);
    g.add(new THREE.Line(geo, new THREE.LineBasicMaterial({ color, transparent: true, opacity: 0.8 })));
  };
  add([30, 0, 0], 0xd9534f);
  add([0, 30, 0], 0x5cb85c);
  add([0, 0, 30], 0x4a8cf7);
  return g;
}
