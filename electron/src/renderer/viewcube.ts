import * as THREE from "three";
import { icon } from "./icons";
import type { ViewName } from "./viewport";

// The orientation cube at the top right of the 3D view, drawn with CSS 3D transforms and turned
// with the camera every frame. A click on a face looks from that side; the house goes home.

const SIZE = 64;

// Each face in world coordinates (z up): its outward normal, and the directions its label reads
// along (right) and down.
const FACES: { view: ViewName; label: string; n: number[]; right: number[]; down: number[] }[] = [
  { view: "top", label: "TOP", n: [0, 0, 1], right: [1, 0, 0], down: [0, -1, 0] },
  { view: "bottom", label: "BOTTOM", n: [0, 0, -1], right: [1, 0, 0], down: [0, 1, 0] },
  { view: "front", label: "FRONT", n: [0, -1, 0], right: [1, 0, 0], down: [0, 0, -1] },
  { view: "back", label: "BACK", n: [0, 1, 0], right: [-1, 0, 0], down: [0, 0, -1] },
  { view: "right", label: "RIGHT", n: [1, 0, 0], right: [0, 1, 0], down: [0, 0, -1] },
  { view: "left", label: "LEFT", n: [-1, 0, 0], right: [0, -1, 0], down: [0, 0, -1] },
];

export class ViewCube {
  readonly el: HTMLElement;
  private cube: HTMLElement;
  private last = "";

  constructor(onLook: (view: ViewName) => void) {
    this.el = document.createElement("div");
    this.el.id = "viewcube";
    const home = document.createElement("button");
    home.className = "vc-home";
    home.title = "Home view";
    home.innerHTML = icon("home", 15);
    home.onclick = () => onLook("home");
    this.cube = document.createElement("div");
    this.cube.className = "vc-cube";
    const h = SIZE / 2;
    for (const f of FACES) {
      const face = document.createElement("button");
      face.className = "vc-face";
      face.textContent = f.label;
      face.title = `${f.label[0]}${f.label.slice(1).toLowerCase()} view`;
      const [r, d, n] = [f.right, f.down, f.n];
      face.style.transform = `matrix3d(${r[0]},${r[1]},${r[2]},0, ${d[0]},${d[1]},${d[2]},0, ${n[0]},${n[1]},${n[2]},0, ${n[0] * h},${n[1] * h},${n[2] * h},1)`;
      face.onclick = () => onLook(f.view);
      this.cube.append(face);
    }
    const stage = document.createElement("div");
    stage.className = "vc-stage";
    stage.append(this.cube);
    this.el.append(home, stage);
  }

  /** Turns the cube to match the camera: world to view rotation, with y flipped for CSS. */
  update(camera: THREE.Camera): void {
    const m = new THREE.Matrix4().extractRotation(camera.matrixWorldInverse).elements;
    // Rows of the rotation are m[0],m[4],m[8] / m[1],m[5],m[9] / m[2],m[6],m[10] (column-major).
    const css = [m[0], -m[1], m[2], 0, m[4], -m[5], m[6], 0, m[8], -m[9], m[10], 0, 0, 0, 0, 1].map((v) => v.toFixed(4)).join(",");
    if (css === this.last) return;
    this.last = css;
    this.cube.style.transform = `matrix3d(${css})`;
  }
}
