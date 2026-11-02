// The electronics workspace: one PCBCraft project seen as a schematic or as a board. The flow is
// the KiCad one: place parts and wire pins in the schematic, update the board, place footprints,
// route the airwires, check the rules, export a .kicad_pcb.

export interface Pt { x: number; y: number }
export interface Pin { number: string; name: string; net?: number | null; offset: Pt }
export interface Part { id: number; reference: string; value: string; kind: string; position: Pt; rotation: number; pins: Pin[] }
export interface Wire { id: number; net: number; from: { component: number; pin: string }; to: { component: number; pin: string } }
export interface Net { id: number; name: string }
export interface Pad { number: string; offset: Pt; diameter: number; net?: number | null }
export interface Footprint { id: number; component: number; position: Pt; rotation: number; pads: Pad[] }
export interface Track { id: number; net: number; start: Pt; end: Pt; width: number; layer: string }
export interface Cutout { id: number; center: Pt; radius: number }
export interface Board { width: number; height: number; clearance: number; cutouts: Cutout[]; footprints: Footprint[]; tracks: Track[] }
export interface Project { name?: string | null; components: Part[]; wires: Wire[]; nets: Net[]; board: Board }
export interface Finding { code: string; message: string; severity: string; objects?: number[] }
export interface Airwire { from: Pt; to: Pt; net: number }
export interface Checks { erc: Finding[]; drc: Finding[]; airwires: Airwire[] }

export type Sheet = "schematic" | "board";
export type PcbTool = { kind: "select" } | { kind: "place"; part: string } | { kind: "wire" } | { kind: "route" };

export const PART_KINDS = ["resistor", "capacitor", "led", "connector"];

const rot = (p: Pt, deg: number): Pt => {
  const a = (deg * Math.PI) / 180;
  return { x: p.x * Math.cos(a) - p.y * Math.sin(a), y: p.x * Math.sin(a) + p.y * Math.cos(a) };
};
const add = (a: Pt, b: Pt): Pt => ({ x: a.x + b.x, y: a.y + b.y });
const dist = (a: Pt, b: Pt) => Math.hypot(a.x - b.x, a.y - b.y);
export const pinAt = (c: Part, p: Pin) => add(c.position, rot(p.offset, c.rotation));
export const padAt = (f: Footprint, p: Pad) => add(f.position, rot(p.offset, f.rotation));

export class PcbModel {
  project: Project | null = null;
  checks: Checks | null = null;
  revision = 0;
  undoCount = 0;
  redoCount = 0;
  sheet: Sheet = "schematic";
  private toolValue: PcbTool = { kind: "select" };
  layer = "F.Cu";
  trackWidth = 0.4;
  selection: number | null = null;
  pending: { object: number; pin: string } | null = null;
  message: { text: string; error: boolean } | null = null;
  onChange: () => void = () => {};

  get tool(): PcbTool { return this.toolValue; }
  set tool(t: PcbTool) { this.toolValue = t; this.pending = null; this.onChange(); }

  async refresh(): Promise<void> {
    const i = (await window.viaform.pcbInspect()) as { revision: number; project: Project; history: { undo: number; redo: number } } | null;
    if (i) {
      this.project = i.project;
      this.revision = i.revision;
      this.undoCount = i.history.undo;
      this.redoCount = i.history.redo;
    }
    this.checks = (await window.viaform.pcbChecks()) as unknown as Checks;
    this.onChange();
  }

  async run(id: string, params: Record<string, unknown> = {}): Promise<unknown> {
    const r = await window.viaform.pcb(id, params as never);
    if ("error" in r) {
      this.message = { text: r.error, error: true };
      this.onChange();
      return undefined;
    }
    this.message = null;
    await this.refresh();
    return r.ok;
  }

  get nets(): Map<number, string> { return new Map((this.project?.nets ?? []).map((n) => [n.id, n.name])); }
  part(id: number) { return this.project?.components.find((c) => c.id === id); }
  footprint(id: number) { return this.project?.board.footprints.find((f) => f.id === id); }
  get findings(): Finding[] { return [...(this.checks?.erc ?? []), ...(this.checks?.drc ?? [])]; }

  pinNear(p: Pt, radius: number): [Part, Pin] | null {
    let best: [Part, Pin, number] | null = null;
    for (const c of this.project?.components ?? []) for (const pin of c.pins) {
      const d = dist(pinAt(c, pin), p);
      if (d < radius && d < (best?.[2] ?? Infinity)) best = [c, pin, d];
    }
    return best && [best[0], best[1]];
  }

  padNear(p: Pt, slack: number): [Footprint, Pad] | null {
    let best: [Footprint, Pad, number] | null = null;
    for (const f of this.project?.board.footprints ?? []) for (const pad of f.pads) {
      const d = dist(padAt(f, pad), p);
      if (d < pad.diameter / 2 + slack && d < (best?.[2] ?? Infinity)) best = [f, pad, d];
    }
    return best && [best[0], best[1]];
  }

  objectAt(p: Pt): number | null {
    const list = this.sheet === "schematic" ? this.project?.components ?? [] : this.project?.board.footprints ?? [];
    const reach = this.sheet === "schematic" ? 6 : 5;
    let best: { id: number; d: number } | null = null;
    for (const o of list) {
      const d = dist(o.position, p);
      if (d < reach && d < (best?.d ?? Infinity)) best = { id: o.id, d };
    }
    return best?.id ?? null;
  }

  async click(p: Pt, scale: number): Promise<void> {
    const slack = 8 / Math.max(scale, 0.01);
    const t = this.tool;
    if (t.kind === "select") {
      this.selection = this.objectAt(p);
      this.onChange();
    } else if (t.kind === "place") {
      const snap = { x: Math.round(p.x / 2.54) * 2.54, y: Math.round(p.y / 2.54) * 2.54 };
      const r = (await this.run("component.add", { kind: t.part, position: snap })) as { result?: { id?: number } } | undefined;
      if (r?.result?.id != null) { this.selection = r.result.id; this.onChange(); }
    } else if (t.kind === "wire") {
      const hit = this.pinNear(p, Math.max(slack, 1.5));
      if (!hit) return;
      const [c, pin] = hit;
      if (this.pending) {
        if (this.pending.object !== c.id || this.pending.pin !== pin.number) {
          await this.run("wire.connect", { from: { component: this.pending.object, pin: this.pending.pin }, to: { component: c.id, pin: pin.number } });
        }
        this.pending = null;
      } else this.pending = { object: c.id, pin: pin.number };
      this.onChange();
    } else {
      const hit = this.padNear(p, slack);
      if (!hit) return;
      const [f, pad] = hit;
      if (this.pending) {
        if (this.pending.object !== f.id || this.pending.pin !== pad.number) {
          await this.run("track.route", { from: { footprint: this.pending.object, pad: this.pending.pin }, to: { footprint: f.id, pad: pad.number }, width: this.trackWidth, layer: this.layer });
        }
        this.pending = null;
      } else this.pending = { object: f.id, pin: pad.number };
      this.onChange();
    }
  }

  async move(id: number, p: Pt): Promise<void> {
    const at = { x: Math.round(p.x * 100) / 100, y: Math.round(p.y * 100) / 100 };
    await this.run(this.sheet === "schematic" ? "component.move" : "footprint.move", { id, position: at });
  }

  async rotateSelection(): Promise<void> {
    const id = this.selection;
    if (id == null) return;
    const c = this.part(id), f = this.footprint(id);
    if (this.sheet === "schematic" && c) await this.run("component.rotate", { id, degrees: (c.rotation + 90) % 360 });
    else if (f) await this.run("footprint.rotate", { id, degrees: (f.rotation + 90) % 360 });
  }

  async deleteSelection(): Promise<void> {
    if (this.selection == null) return;
    await this.run("object.delete", { id: this.selection });
    this.selection = null;
  }

  async updateBoard(): Promise<void> {
    await this.run("board.sync");
    this.sheet = "board";
    this.onChange();
  }

  /** Routes every airwire with the engine's orthogonal router, one at a time. */
  async routeAll(): Promise<void> {
    const wires = this.checks?.airwires ?? [];
    if (!wires.length) {
      this.message = { text: "Nothing left to route", error: false };
      this.onChange();
      return;
    }
    let routed = 0;
    for (const a of wires) {
      const h1 = this.padNear(a.from, 0.05), h2 = this.padNear(a.to, 0.05);
      if (!h1 || !h2) continue;
      const r = await window.viaform.pcb("track.route", { from: { footprint: h1[0].id, pad: h1[1].number }, to: { footprint: h2[0].id, pad: h2[1].number }, width: this.trackWidth, layer: this.layer });
      if ("ok" in r) routed++;
    }
    await this.refresh();
    this.message = { text: `Routed ${routed} of ${wires.length} connections`, error: routed < wires.length };
    this.onChange();
  }

  get hint(): string | null {
    const t = this.tool;
    if (t.kind === "place") return `Click to place a ${t.part}.`;
    if (t.kind === "wire") return this.pending ? "Click the second pin." : "Click a first pin.";
    if (t.kind === "route") return this.pending ? "Click a pad on the same net." : "Click a first pad.";
    return null;
  }
}

interface Palette { paper: string; grid: string; ink: string; inkSoft: string; pin: string; wire: string; select: string; board: string; edge: string; front: string; back: string; pad: string; air: string }

const SCHEMATIC: Palette = { paper: "#f7f7f2", grid: "rgba(0,0,0,0.07)", ink: "#333845", inkSoft: "rgba(51,56,69,0.75)", pin: "#bf3333", wire: "#1a805a", select: "#2f7bf6", board: "", edge: "", front: "", back: "", pad: "", air: "" };
const BOARD: Palette = { paper: "#12141a", grid: "rgba(255,255,255,0.05)", ink: "#d9d9d9", inkSoft: "rgba(217,217,217,0.45)", pin: "", wire: "", select: "#ffd94d", board: "#1c3329", edge: "#f2d966", front: "#d94d40", back: "#4d80e6", pad: "#ccad4d", air: "rgba(255,255,255,0.55)" };

/** The sheet, drawn from the project in millimetres. Click runs the tool; dragging the selected
 * part moves it, dragging elsewhere pans; the wheel zooms about the cursor. */
export class PcbCanvas {
  private ctx: CanvasRenderingContext2D;
  private center: Pt = { x: 30, y: 20 };
  private scale = 12;
  private drag: { id: number | null; last: { x: number; y: number }; start: { x: number; y: number } } | null = null;
  private ghost: Pt | null = null;
  private fittedSheet: Sheet | null = null;

  constructor(readonly canvas: HTMLCanvasElement, private model: PcbModel) {
    this.ctx = canvas.getContext("2d")!;
    new ResizeObserver(() => this.draw()).observe(canvas.parentElement!);
    canvas.addEventListener("pointerdown", (e) => this.down(e));
    canvas.addEventListener("pointermove", (e) => this.moveTo(e));
    canvas.addEventListener("pointerup", (e) => void this.up(e));
    canvas.addEventListener("wheel", (e) => this.wheel(e), { passive: false });
  }

  private get size() { return { w: this.canvas.clientWidth, h: this.canvas.clientHeight }; }
  private toView(p: Pt) { const s = this.size; return { x: s.w / 2 + (p.x - this.center.x) * this.scale, y: s.h / 2 + (p.y - this.center.y) * this.scale }; }
  private toSheet(e: { clientX: number; clientY: number }): Pt {
    const r = this.canvas.getBoundingClientRect(), s = this.size;
    return { x: this.center.x + (e.clientX - r.left - s.w / 2) / this.scale, y: this.center.y + (e.clientY - r.top - s.h / 2) / this.scale };
  }

  fit(): void {
    const p = this.model.project;
    const { w, h } = this.size;
    if (!p || w < 10) return;
    let pts: Pt[] = [];
    if (this.model.sheet === "board") pts = [{ x: 0, y: 0 }, { x: p.board.width, y: p.board.height }];
    else for (const c of p.components) pts.push(c.position, ...c.pins.map((pin) => pinAt(c, pin)));
    if (!pts.length) { this.center = { x: 0, y: 0 }; this.scale = 12; this.draw(); return; }
    const xs = pts.map((q) => q.x), ys = pts.map((q) => q.y);
    const [minX, maxX, minY, maxY] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)];
    this.center = { x: (minX + maxX) / 2, y: (minY + maxY) / 2 };
    this.scale = Math.min(w / Math.max(maxX - minX + 12, 10), h / Math.max(maxY - minY + 12, 10));
    this.draw();
  }

  zoom(f: number): void { this.scale = Math.min(200, Math.max(1, this.scale * f)); this.draw(); }

  private down(e: PointerEvent): void {
    this.canvas.setPointerCapture(e.pointerId);
    const hit = this.model.objectAt(this.toSheet(e));
    const grab = hit != null && hit === this.model.selection && this.model.tool.kind === "select" && e.button === 0;
    this.drag = { id: grab ? hit : null, last: { x: e.clientX, y: e.clientY }, start: { x: e.clientX, y: e.clientY } };
  }

  private moveTo(e: PointerEvent): void {
    const d = this.drag;
    if (!d) return;
    const moved = Math.hypot(e.clientX - d.start.x, e.clientY - d.start.y) > 3;
    if (d.id != null) this.ghost = moved ? this.toSheet(e) : null;
    else if (moved) this.center = { x: this.center.x - (e.clientX - d.last.x) / this.scale, y: this.center.y - (e.clientY - d.last.y) / this.scale };
    d.last = { x: e.clientX, y: e.clientY };
    this.draw();
  }

  private async up(e: PointerEvent): Promise<void> {
    const d = this.drag;
    this.drag = null;
    this.ghost = null;
    if (!d) return;
    const moved = Math.hypot(e.clientX - d.start.x, e.clientY - d.start.y) > 3;
    if (d.id != null && moved) await this.model.move(d.id, this.toSheet(e));
    else if (!moved && e.button === 0) await this.model.click(this.toSheet(e), this.scale);
    this.draw();
  }

  private wheel(e: WheelEvent): void {
    e.preventDefault();
    const before = this.toSheet(e);
    this.scale = Math.min(200, Math.max(1, this.scale * Math.exp(-e.deltaY * 0.0015)));
    const after = this.toSheet(e);
    this.center = { x: this.center.x + before.x - after.x, y: this.center.y + before.y - after.y };
    this.draw();
  }

  draw(): void {
    const { w, h } = this.size;
    if (w === 0) return;
    const dpr = window.devicePixelRatio;
    if (this.canvas.width !== Math.round(w * dpr)) { this.canvas.width = Math.round(w * dpr); this.canvas.height = Math.round(h * dpr); }
    if (this.canvas.height !== Math.round(h * dpr)) this.canvas.height = Math.round(h * dpr);
    if (this.fittedSheet !== this.model.sheet && this.model.project) { this.fittedSheet = this.model.sheet; this.fit(); return; }
    const c = this.ctx;
    c.setTransform(dpr, 0, 0, dpr, 0, 0);
    const pal = this.model.sheet === "schematic" ? SCHEMATIC : BOARD;
    c.fillStyle = pal.paper;
    c.fillRect(0, 0, w, h);
    this.drawGrid(pal);
    const p = this.model.project;
    if (!p) return;
    if (this.model.sheet === "schematic") this.drawSchematic(p, pal);
    else this.drawBoard(p, pal);
  }

  private drawGrid(pal: Palette): void {
    const c = this.ctx, { w, h } = this.size;
    const step = this.model.sheet === "schematic" ? 2.54 : 1;
    const every = step * this.scale < 8 ? step * 5 : step;
    const a = this.toSheet({ clientX: this.canvas.getBoundingClientRect().left, clientY: this.canvas.getBoundingClientRect().top });
    c.beginPath();
    for (let x = Math.floor(a.x / every) * every; ; x += every) { const v = this.toView({ x, y: 0 }).x; if (v > w) break; c.moveTo(v, 0); c.lineTo(v, h); }
    for (let y = Math.floor(a.y / every) * every; ; y += every) { const v = this.toView({ x: 0, y }).y; if (v > h) break; c.moveTo(0, v); c.lineTo(w, v); }
    c.strokeStyle = pal.grid;
    c.lineWidth = 1;
    c.stroke();
  }

  private label(text: string, x: number, y: number, size: number, color: string, weight = 400): void {
    const c = this.ctx;
    c.font = `${weight} ${size}px system-ui, -apple-system, "Segoe UI", sans-serif`;
    c.fillStyle = color;
    c.textAlign = "center";
    c.textBaseline = "middle";
    c.fillText(text, x, y);
  }

  private drawSchematic(p: Project, pal: Palette): void {
    const c = this.ctx, m = this.model, nets = m.nets, s = this.scale;
    for (const wire of p.wires) {
      const c1 = m.part(wire.from.component), c2 = m.part(wire.to.component);
      const p1 = c1?.pins.find((q) => q.number === wire.from.pin), p2 = c2?.pins.find((q) => q.number === wire.to.pin);
      if (!c1 || !c2 || !p1 || !p2) continue;
      const a = this.toView(pinAt(c1, p1)), b = this.toView(pinAt(c2, p2));
      c.beginPath(); c.moveTo(a.x, a.y); c.lineTo(b.x, a.y); c.lineTo(b.x, b.y);
      c.strokeStyle = m.selection === wire.id ? pal.select : pal.wire;
      c.lineWidth = 2;
      c.stroke();
      const n = nets.get(wire.net);
      if (n) { c.textAlign = "left"; this.label(n, b.x + 4 + n.length * 3, a.y - 9, 10, pal.wire, 600); }
    }
    for (const part of p.components) {
      const selected = m.selection === part.id;
      const ink = selected ? pal.select : pal.ink;
      const at = this.ghost && selected ? this.toView(this.ghost) : this.toView(part.position);
      c.save();
      c.translate(at.x, at.y);
      c.rotate((part.rotation * Math.PI) / 180);
      symbol(c, part.kind, s, ink);
      c.lineWidth = 1.6;
      for (const pin of part.pins) {
        const e = { x: pin.offset.x * s, y: pin.offset.y * s };
        c.beginPath(); c.moveTo(e.x * 0.55, e.y * 0.55); c.lineTo(e.x, e.y); c.stroke();
      }
      c.restore();
      for (const pin of part.pins) {
        const q = this.ghost && selected ? this.toView(add(this.ghost, rot(pin.offset, part.rotation))) : this.toView(pinAt(part, pin));
        const here = m.pending?.object === part.id && m.pending?.pin === pin.number;
        const r = here ? 5 : 3;
        c.beginPath(); c.arc(q.x, q.y, r, 0, Math.PI * 2);
        c.fillStyle = here ? pal.select : pal.pin;
        c.fill();
      }
      this.label(part.reference, at.x, at.y - 2.6 * s - 6, 11, ink, 700);
      this.label(part.value, at.x, at.y + 2.6 * s + 6, 10, selected ? pal.select : pal.inkSoft);
    }
  }

  private drawBoard(p: Project, pal: Palette): void {
    const c = this.ctx, m = this.model, s = this.scale, nets = m.nets;
    const o = this.toView({ x: 0, y: 0 });
    c.fillStyle = pal.board;
    c.fillRect(o.x, o.y, p.board.width * s, p.board.height * s);
    c.strokeStyle = pal.edge;
    c.lineWidth = 1.5;
    c.strokeRect(o.x, o.y, p.board.width * s, p.board.height * s);
    for (const cut of p.board.cutouts) {
      const q = this.toView(cut.center);
      c.beginPath(); c.arc(q.x, q.y, cut.radius * s, 0, Math.PI * 2);
      c.fillStyle = pal.paper; c.fill();
      c.lineWidth = 1.2; c.stroke();
    }
    // Back copper under front copper.
    c.lineCap = "round";
    for (const layer of ["B.Cu", "F.Cu"]) {
      for (const t of p.board.tracks.filter((t) => t.layer === layer)) {
        const a = this.toView(t.start), b = this.toView(t.end);
        c.beginPath(); c.moveTo(a.x, a.y); c.lineTo(b.x, b.y);
        c.globalAlpha = m.layer === layer ? 1 : 0.55;
        c.strokeStyle = m.selection === t.id ? pal.select : layer === "F.Cu" ? pal.front : pal.back;
        c.lineWidth = Math.max(1, t.width * s);
        c.stroke();
        c.globalAlpha = 1;
      }
    }
    for (const f of p.board.footprints) {
      const selected = m.selection === f.id;
      const shift = this.ghost && selected ? { x: this.ghost.x - f.position.x, y: this.ghost.y - f.position.y } : { x: 0, y: 0 };
      const pads = f.pads.map((pad) => add(padAt(f, pad), shift));
      if (pads.length) {
        const xs = pads.map((q) => q.x), ys = pads.map((q) => q.y);
        const a = this.toView({ x: Math.min(...xs) - 1.6, y: Math.min(...ys) - 1.6 }), b = this.toView({ x: Math.max(...xs) + 1.6, y: Math.max(...ys) + 1.6 });
        c.beginPath(); c.roundRect(a.x, a.y, b.x - a.x, b.y - a.y, 3);
        c.strokeStyle = selected ? pal.select : pal.inkSoft;
        c.lineWidth = selected ? 2 : 1;
        c.stroke();
        const part = m.part(f.component);
        if (part) this.label(part.reference, (a.x + b.x) / 2, a.y - 8, 10, pal.ink, 600);
      }
      f.pads.forEach((pad, i) => {
        const q = this.toView(pads[i]), r = (pad.diameter / 2) * s;
        const here = m.pending?.object === f.id && m.pending?.pin === pad.number;
        c.beginPath(); c.arc(q.x, q.y, r, 0, Math.PI * 2);
        c.fillStyle = here ? pal.select : pal.pad; c.fill();
        c.beginPath(); c.arc(q.x, q.y, r * 0.45, 0, Math.PI * 2);
        c.fillStyle = pal.paper; c.fill();
        const n = pad.net != null ? nets.get(pad.net) : undefined;
        if (s > 9 && n) this.label(n, q.x, q.y + r + 7, 8, pal.inkSoft);
      });
    }
    c.setLineDash([4, 3]);
    c.strokeStyle = pal.air;
    c.lineWidth = 1;
    for (const a of m.checks?.airwires ?? []) {
      const p1 = this.toView(a.from), p2 = this.toView(a.to);
      c.beginPath(); c.moveTo(p1.x, p1.y); c.lineTo(p2.x, p2.y); c.stroke();
    }
    c.setLineDash([]);
  }
}

/** Original symbol drawings, in a component frame where one unit is one millimetre. */
function symbol(c: CanvasRenderingContext2D, kind: string, s: number, ink: string): void {
  c.beginPath();
  switch (kind) {
    case "resistor":
      c.roundRect(-2.75 * s, -1 * s, 5.5 * s, 2 * s, 0.3 * s);
      break;
    case "capacitor":
      c.moveTo(-0.6 * s, -2 * s); c.lineTo(-0.6 * s, 2 * s);
      c.moveTo(0.6 * s, -2 * s); c.lineTo(0.6 * s, 2 * s);
      c.moveTo(-2.75 * s, 0); c.lineTo(-0.6 * s, 0);
      c.moveTo(0.6 * s, 0); c.lineTo(2.75 * s, 0);
      break;
    case "led":
      c.moveTo(-1.5 * s, -1.6 * s); c.lineTo(1.2 * s, 0); c.lineTo(-1.5 * s, 1.6 * s); c.closePath();
      c.moveTo(1.2 * s, -1.6 * s); c.lineTo(1.2 * s, 1.6 * s);
      c.moveTo(-0.2 * s, -2 * s); c.lineTo(0.8 * s, -3 * s);
      c.moveTo(0.7 * s, -1.9 * s); c.lineTo(1.7 * s, -2.9 * s);
      break;
    default:
      c.roundRect(-2.75 * s, -1.8 * s, 5.5 * s, 3.6 * s, 0.5 * s);
  }
  c.strokeStyle = ink;
  c.lineWidth = 1.8;
  c.stroke();
}
