import type { Json } from "../shared/api";
import { icon } from "./icons";

// The Generate tab's study: a design space (a plate in the XY plane), the supports that hold it,
// the loads that push it, the regions to keep empty or solid, a material and the solver's
// settings. The study answers a few candidates, drawn here from their outlines; the chosen one
// builds into the design as one body, one undo step (generative/src/spec.rs has the JSON).

export interface GenerativeHost {
  /** After a build: refresh the 3D scene, the browser and the timeline. */
  built(body: string): Promise<void>;
  flash(text: string | null, error?: boolean): void;
  /** The toolbar shows the study's state (running, a result to build). */
  changed(): void;
}

export type Method = "topology" | "frame";
type Fix = "all" | "x" | "y";
type Region = { shape: "rect"; min: [number, number]; max: [number, number] } | { shape: "circle"; center: [number, number]; radius: number };
type Kind = "support" | "load" | "keep_out" | "keep_in";
/** One row of the boundary list: a support, a load or a region to keep empty or solid. */
interface Item { kind: Kind; region: Region; fix: Fix; force: [number, number] }
interface Material { name: string; e: number; nu: number; density: number; allowable: number; color: string }

interface Candidate {
  id: number;
  method: Method;
  mass_g: number;
  compliance: number;
  max_stress: number;
  max_displacement: number;
  volume_fraction: number;
  feasible: boolean;
  history: number[];
  outlines: [number, number][][];
}
interface Outcome { candidates: Candidate[]; best: number }

interface Setup { width: number; height: number; thickness: number; resolution: number; items: Item[]; body: string }

/** Allowables are the yield (or the laminate's strength) over a safety factor of 1.5. */
export const MATERIALS: Material[] = [
  { name: "Aluminum 6061", e: 69_000, nu: 0.33, density: 2.7e-3, allowable: 180, color: "#b9c0c8" },
  { name: "Steel", e: 200_000, nu: 0.29, density: 7.85e-3, allowable: 235, color: "#8a9099" },
  { name: "PLA", e: 3_500, nu: 0.36, density: 1.24e-3, allowable: 33, color: "#d9d2c3" },
  { name: "Carbon Fiber", e: 70_000, nu: 0.1, density: 1.6e-3, allowable: 400, color: "#3a3d42" },
  { name: "Titanium", e: 114_000, nu: 0.34, density: 4.43e-3, allowable: 585, color: "#a7a196" },
];

const rect = (x0: number, y0: number, x1: number, y1: number): Region => ({ shape: "rect", min: [x0, y0], max: [x1, y1] });
const support = (region: Region, fix: Fix = "all"): Item => ({ kind: "support", region, fix, force: [0, 0] });
const load = (region: Region, fx: number, fy: number): Item => ({ kind: "load", region, fix: "all", force: [fx, fy] });
const keep = (kind: "keep_out" | "keep_in", region: Region): Item => ({ kind, region, fix: "all", force: [0, 0] });

/** The classic studies, in mm and N; the domain's corner is at the origin, Y up. */
export const PRESETS: { id: string; label: string; setup: () => Setup }[] = [
  { id: "cantilever", label: "Cantilever", setup: () => ({
    width: 120, height: 40, thickness: 6, resolution: 2, body: "Cantilever",
    items: [support(rect(0, 0, 2, 40)), load(rect(118, 17, 120, 23), 0, -800)],
  }) },
  { id: "beam", label: "Simply supported beam", setup: () => ({
    width: 160, height: 40, thickness: 6, resolution: 2, body: "Beam",
    items: [support(rect(0, 0, 4, 2)), support(rect(156, 0, 160, 2), "y"), load(rect(77, 38, 83, 40), 0, -1500)],
  }) },
  { id: "bracket", label: "L-bracket with keep-out", setup: () => ({
    width: 100, height: 100, thickness: 6, resolution: 2, body: "Bracket",
    items: [support(rect(0, 98, 40, 100)), keep("keep_out", rect(40, 40, 100, 100)), load(rect(98, 16, 100, 24), 0, -600)],
  }) },
  { id: "bridge", label: "Bridge", setup: () => ({
    width: 200, height: 60, thickness: 6, resolution: 2.5, body: "Bridge",
    items: [support(rect(0, 0, 6, 3)), support(rect(194, 0, 200, 3)), keep("keep_in", rect(0, 56, 200, 60)), load(rect(0, 57, 200, 60), 0, -2000)],
  }) },
];

const KINDS: Record<Kind, { label: string; color: string }> = {
  support: { label: "Support", color: "#3fbf7f" },
  load: { label: "Load", color: "#3d8bff" },
  keep_out: { label: "Keep-out", color: "#ef5b5b" },
  keep_in: { label: "Keep-in", color: "#f0a33a" },
};

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
const el = <K extends keyof HTMLElementTagNameMap>(tag: K, cls = "", html = ""): HTMLElementTagNameMap[K] => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (html) e.innerHTML = html;
  return e;
};
const fmt = (x: number, digits = 0) => (Number.isFinite(x) ? x.toFixed(digits) : "∞");
const clone = <T>(x: T): T => JSON.parse(JSON.stringify(x)) as T;

export class GenerativePanel {
  readonly el = el("aside");
  method: Method = "topology";
  width = 120;
  height = 40;
  thickness = 6;
  resolution = 2;
  volumeFraction = 0.35;
  variants = 4;
  iterations = 60;
  material = 0;
  preset = PRESETS[0].id;
  items: Item[] = [];
  body = "Generated";
  outcome: Outcome | null = null;
  chosen = 0;
  running = false;
  building = false;
  private error: string | null = null;
  /** The spec the outcome answers: Build uses it, whatever was edited since. */
  private studied: Json | null = null;
  private stale = false;
  private started = 0;
  private setupCanvas = el("canvas", "gen-setup");

  constructor(private readonly host: GenerativeHost) {
    this.el.id = "generative";
    this.el.hidden = true;
    this.load(this.preset);
  }

  get open(): boolean { return !this.el.hidden; }

  toggle(on = this.el.hidden): void {
    this.el.hidden = !on;
    if (on) this.render();
  }

  /** Loads a preset study: domain, supports, loads and regions. */
  load(id: string): void {
    const p = PRESETS.find((x) => x.id === id);
    if (!p) return;
    const s = p.setup();
    this.preset = id;
    this.width = s.width;
    this.height = s.height;
    this.thickness = s.thickness;
    this.resolution = s.resolution;
    this.items = s.items;
    this.body = s.body;
    this.edited();
    this.render();
  }

  setMethod(m: Method): void {
    this.method = m;
    this.edited();
    this.render();
  }

  setMaterial(i: number): void {
    this.material = i;
    this.edited();
    this.render();
  }

  /** The study as the engine reads it (Spec in generative/src/spec.rs). */
  spec(): Json {
    const regions = (k: Kind) => this.items.filter((i) => i.kind === k).map((i) => i.region);
    return clone({
      method: this.method,
      width: this.width,
      height: this.height,
      thickness: this.thickness,
      origin: [0, 0, 0],
      resolution: this.resolution,
      supports: this.items.filter((i) => i.kind === "support").map((i) => ({ region: i.region, fix: i.fix })),
      cases: [{ name: "Load case 1", loads: this.items.filter((i) => i.kind === "load").map((i) => ({ region: i.region, force: i.force })) }],
      keep_out: regions("keep_out"),
      keep_in: regions("keep_in"),
      material: MATERIALS[this.material],
      volume_fraction: this.volumeFraction,
      iterations: this.iterations,
      filter_radius: Math.max(3, 1.5 * this.resolution),
      variants: this.variants,
      body_name: this.body,
    }) as unknown as Json;
  }

  async run(): Promise<void> {
    if (this.running) return;
    const spec = this.spec();
    this.running = true;
    this.error = null;
    this.started = performance.now();
    this.render();
    this.host.changed();
    // Let the panel paint its running state before the main process takes the study.
    await new Promise((r) => requestAnimationFrame(() => setTimeout(r, 0)));
    const r = await window.viaform.generateStudy(spec);
    this.running = false;
    if ("error" in r) {
      this.error = r.error;
      this.host.flash(r.error, true);
    } else {
      this.outcome = r.ok as unknown as Outcome;
      this.chosen = this.outcome.best;
      this.studied = spec;
      this.stale = false;
      const secs = ((performance.now() - this.started) / 1000).toFixed(1);
      this.host.flash(`${this.outcome.candidates.length} candidates in ${secs} s`);
    }
    this.render();
    this.host.changed();
  }

  /** Builds the chosen candidate of the last study into the design. */
  async build(): Promise<void> {
    if (!this.outcome || !this.studied || this.building) return;
    this.building = true;
    this.render();
    this.host.changed();
    const r = await window.viaform.generate(this.studied, this.chosen);
    this.building = false;
    if ("error" in r) this.host.flash(r.error, true);
    else {
      const body = String((r.ok as { body?: Json }).body ?? this.body);
      await this.host.built(body);
      this.host.flash(`Built ${body} from candidate ${this.chosen + 1}`);
    }
    this.render();
    this.host.changed();
  }

  private edited(): void {
    if (this.outcome) this.stale = true;
    this.drawSetup();
  }

  // MARK: Rendering

  private render(): void {
    if (this.el.hidden) return;
    const keepScroll = this.el.querySelector(".gen-body")?.scrollTop ?? 0;
    const head = el("div", "fhead", `${icon("generate", 16)}<span class="grow">GENERATIVE STUDY</span>`);
    const close = el("button", "ic", icon("close", 14));
    close.title = "Close the study panel";
    close.onclick = () => { this.toggle(false); this.host.changed(); };
    head.append(close);

    const body = el("div", "gen-body");
    body.append(
      this.section("SETUP"),
      this.row("Preset", this.select(PRESETS.map((p) => p.label), PRESETS.findIndex((p) => p.id === this.preset), (i) => { this.load(PRESETS[i].id); this.host.changed(); })),
      this.setupCanvas,
      this.row("Method", this.segmented()),
      this.row("Domain, mm", this.numbers([
        ["W", this.width, (v) => (this.width = v)],
        ["H", this.height, (v) => (this.height = v)],
        ["T", this.thickness, (v) => (this.thickness = v)],
      ])),
      this.row(this.method === "frame" ? "Node spacing" : "Element, mm", this.number(this.resolution, (v) => (this.resolution = v), 0.5)),
      this.section("MATERIAL"),
      this.row("Material", this.select(MATERIALS.map((m) => m.name), this.material, (i) => { this.setMaterial(i); this.host.changed(); })),
      el("div", "gen-note", this.materialNote()),
      this.section("OBJECTIVE"),
      this.row("Volume", this.number(this.volumeFraction, (v) => (this.volumeFraction = v), 0.05, 0.02, 0.95)),
      this.row("Variants", this.number(this.variants, (v) => (this.variants = Math.round(v)), 1, 1, 16)),
      this.row(this.method === "frame" ? "Generations" : "Iterations", this.number(this.iterations, (v) => (this.iterations = Math.round(v)), 10, 1, 1000)),
      this.section("SUPPORTS, LOADS AND REGIONS"),
      ...this.items.map((it, i) => this.itemRow(it, i)),
      this.addRow(),
      this.section(`CANDIDATES${this.outcome ? ` <span class="n">${this.outcome.candidates.length}</span>` : ""}`),
      this.gallery(),
    );

    const foot = el("div", "dfoot");
    const run = el("button", "btn", this.running ? "Running…" : "Run Study");
    run.title = "Run the study (every variant)";
    run.disabled = this.running || this.building;
    run.onclick = () => void this.run();
    const build = el("button", "btn primary", this.building ? "Building…" : this.outcome ? `Build Candidate ${this.chosen + 1}` : "Build");
    build.title = "Build the chosen candidate into the design";
    build.disabled = !this.outcome || this.running || this.building;
    build.onclick = () => void this.build();
    foot.append(run, build);

    this.el.replaceChildren(head, body, foot);
    body.scrollTop = keepScroll;
    this.drawSetup();
  }

  private section(title: string): HTMLElement {
    return el("div", "dp-sec", title);
  }

  private row(label: string, control: HTMLElement): HTMLElement {
    const r = el("label", "gen-row", `<span>${esc(label)}</span>`);
    r.append(control);
    return r;
  }

  private select(options: string[], value: number, set: (i: number) => void): HTMLSelectElement {
    const s = el("select");
    s.innerHTML = options.map((o, i) => `<option value="${i}">${esc(o)}</option>`).join("");
    s.value = String(value);
    s.onchange = () => set(Number(s.value));
    return s;
  }

  private segmented(): HTMLElement {
    const g = el("div", "segmented");
    for (const [m, label] of [["topology", "Topology"], ["frame", "Frame"]] as const) {
      const b = el("button", this.method === m ? "on" : "", label);
      b.title = m === "topology" ? "Density-based topology optimisation (SIMP) on a grid" : "A ground structure of beams sized by an evolution strategy";
      b.onclick = (e) => { e.preventDefault(); this.setMethod(m); this.host.changed(); };
      g.append(b);
    }
    return g;
  }

  /** A numeric field that keeps its focus: edits redraw the setup, not the panel. */
  private number(value: number, set: (v: number) => void, step = 1, min?: number, max?: number): HTMLInputElement {
    const i = el("input");
    i.type = "number";
    i.step = String(step);
    if (min != null) i.min = String(min);
    if (max != null) i.max = String(max);
    i.value = String(value);
    i.oninput = () => {
      const v = Number(i.value);
      if (i.value === "" || !Number.isFinite(v)) return;
      set(v);
      this.edited();
    };
    return i;
  }

  private numbers(fields: [string, number, (v: number) => void][]): HTMLElement {
    const g = el("div", "gen-nums");
    for (const [label, value, set] of fields) {
      const f = el("label", "gen-num", `<span>${esc(label)}</span>`);
      f.append(this.number(value, set));
      g.append(f);
    }
    return g;
  }

  private materialNote(): string {
    const m = MATERIALS[this.material];
    return `E ${fmt(m.e / 1000, 1)} GPa · ν ${m.nu} · ${fmt(m.density * 1000, 2)} g/cm³ · allowable ${m.allowable} MPa`;
  }

  private itemRow(it: Item, index: number): HTMLElement {
    const k = KINDS[it.kind];
    const r = el("div", "gen-item");
    const top = el("div", "gen-item-head", `<i style="background:${k.color}"></i><b>${k.label}</b>`);
    const shape = this.select(["Rectangle", "Circle"], it.region.shape === "rect" ? 0 : 1, (s) => {
      const c = regionCenter(it.region);
      it.region = s === 0 ? rect(c[0] - 2, c[1] - 2, c[0] + 2, c[1] + 2) : { shape: "circle", center: c, radius: 3 };
      this.edited();
      this.render();
    });
    top.append(shape);
    if (it.kind === "support") {
      top.append(this.select(["Fixed", "Fix X", "Fix Y"], ["all", "x", "y"].indexOf(it.fix), (s) => {
        it.fix = (["all", "x", "y"] as const)[s];
        this.edited();
      }));
    }
    const del = el("button", "ic", icon("delete", 14));
    del.title = `Remove this ${k.label.toLowerCase()}`;
    del.onclick = () => { this.items.splice(index, 1); this.edited(); this.render(); };
    top.append(del);

    const reg = it.region;
    const nums: [string, number, (v: number) => void][] = reg.shape === "rect"
      ? [["x₀", reg.min[0], (v) => (reg.min[0] = v)], ["y₀", reg.min[1], (v) => (reg.min[1] = v)], ["x₁", reg.max[0], (v) => (reg.max[0] = v)], ["y₁", reg.max[1], (v) => (reg.max[1] = v)]]
      : [["x", reg.center[0], (v) => (reg.center[0] = v)], ["y", reg.center[1], (v) => (reg.center[1] = v)], ["r", reg.radius, (v) => (reg.radius = v)]];
    if (it.kind === "load") nums.push(["Fx", it.force[0], (v) => (it.force[0] = v)], ["Fy", it.force[1], (v) => (it.force[1] = v)]);
    r.append(top, this.numbers(nums));
    return r;
  }

  private addRow(): HTMLElement {
    const g = el("div", "gen-add");
    const w = this.width, h = this.height;
    const make: Record<Kind, () => Item> = {
      support: () => support(rect(0, 0, 2, h)),
      load: () => load(rect(w - 2, h / 2 - 2, w, h / 2 + 2), 0, -500),
      keep_out: () => keep("keep_out", { shape: "circle", center: [w / 2, h / 2], radius: Math.min(w, h) / 6 }),
      keep_in: () => keep("keep_in", rect(w / 2 - 4, h / 2 - 4, w / 2 + 4, h / 2 + 4)),
    };
    for (const kind of Object.keys(KINDS) as Kind[]) {
      const b = el("button", "lib-chip", `${icon("plus", 12)}${KINDS[kind].label}`);
      b.title = `Add a ${KINDS[kind].label.toLowerCase()}`;
      b.onclick = () => { this.items.push(make[kind]()); this.edited(); this.render(); };
      g.append(b);
    }
    return g;
  }

  private gallery(): HTMLElement {
    const g = el("div", "gen-gallery");
    if (this.running) {
      g.append(el("div", "gen-empty", `Running ${this.variants} variant${this.variants > 1 ? "s" : ""} of the ${this.method} study…`));
      return g;
    }
    if (this.error) g.append(el("div", "lib-error", esc(this.error)));
    if (!this.outcome) {
      g.append(el("div", "gen-empty", "Run the study to see candidates here. The lightest feasible one is chosen first."));
      return g;
    }
    if (this.stale) g.append(el("div", "gen-note warn", "The setup changed since this study: Build uses the setup it ran on."));
    const allowable = (this.studied as { material?: { allowable?: number } } | null)?.material?.allowable ?? MATERIALS[this.material].allowable;
    const grid = el("div", "gen-cards");
    this.outcome.candidates.forEach((c, i) => {
      const card = el("button", `gen-card${i === this.chosen ? " on" : ""}`);
      card.title = `Candidate ${i + 1}: click to choose it, double-click to build it`;
      const preview = el("canvas", "gen-preview");
      const ratio = Math.min(1, c.max_stress / allowable);
      card.innerHTML = `<div class="gen-card-head"><b>#${i + 1}</b>${i === this.outcome!.best ? '<span class="tag">BEST</span>' : ""}<span class="badge ${c.feasible ? "ok" : "bad"}">${c.feasible ? "Feasible" : "Over stress"}</span></div>`;
      card.append(preview);
      const stats = el("div", "gen-stats", `
        <span>Mass</span><b>${fmt(c.mass_g, 1)} g</b>
        <span>Stress</span><b class="${c.feasible ? "" : "bad"}">${fmt(c.max_stress)} / ${fmt(allowable)} MPa</b>
        <span>Volume</span><b>${fmt(c.volume_fraction * 100)} %</b>
        <span>Displ.</span><b>${fmt(c.max_displacement, 3)} mm</b>`);
      const bar = el("div", `meter${c.feasible ? "" : " low"}`, `<i style="width:${(ratio * 100).toFixed(0)}%"></i>`);
      const spark = el("canvas", "gen-spark");
      spark.title = "Objective per iteration";
      card.append(stats, bar, spark);
      card.onclick = () => { this.chosen = i; this.render(); this.host.changed(); };
      card.ondblclick = () => { this.chosen = i; void this.build(); };
      grid.append(card);
      requestAnimationFrame(() => {
        drawDomain(preview, this.studiedSetup(), c.outlines);
        drawSpark(spark, c.history);
      });
    });
    g.append(grid);
    return g;
  }

  /** The domain and boundary items the outcome was studied on, for its previews. */
  private studiedSetup(): { width: number; height: number; items: Item[] } {
    const s = this.studied as unknown as { width: number; height: number; supports: { region: Region; fix: Fix }[]; cases: { loads: { region: Region; force: [number, number] }[] }[]; keep_out: Region[]; keep_in: Region[] } | null;
    if (!s) return { width: this.width, height: this.height, items: this.items };
    return {
      width: s.width,
      height: s.height,
      items: [
        ...s.keep_out.map((r) => keep("keep_out", r)),
        ...s.keep_in.map((r) => keep("keep_in", r)),
        ...s.supports.map((x) => support(x.region, x.fix)),
        ...s.cases.flatMap((c) => c.loads.map((l) => load(l.region, l.force[0], l.force[1]))),
      ],
    };
  }

  private drawSetup(): void {
    if (this.el.hidden) return;
    requestAnimationFrame(() => drawDomain(this.setupCanvas, { width: this.width, height: this.height, items: this.items }, null));
  }
}

function regionCenter(r: Region): [number, number] {
  return r.shape === "circle" ? [r.center[0], r.center[1]] : [(r.min[0] + r.max[0]) / 2, (r.min[1] + r.max[1]) / 2];
}

/** Sizes a canvas to its box at the screen's pixel ratio; the context draws in CSS pixels. */
function fit(c: HTMLCanvasElement): CanvasRenderingContext2D | null {
  const w = c.clientWidth, h = c.clientHeight;
  if (!w || !h) return null;
  const dpr = window.devicePixelRatio || 1;
  c.width = Math.round(w * dpr);
  c.height = Math.round(h * dpr);
  const g = c.getContext("2d");
  g?.setTransform(dpr, 0, 0, dpr, 0, 0);
  return g;
}

function regionPath(g: CanvasRenderingContext2D, r: Region, s: number, x: (v: number) => number, y: (v: number) => number): void {
  g.beginPath();
  if (r.shape === "circle") g.arc(x(r.center[0]), y(r.center[1]), Math.max(1.5, r.radius * s), 0, Math.PI * 2);
  else g.rect(x(r.min[0]), y(r.max[1]), Math.max(1.5, (r.max[0] - r.min[0]) * s), Math.max(1.5, (r.max[1] - r.min[1]) * s));
}

/** The design space at its aspect, Y up: the solid's outlines filled even-odd, keep-out and
 * keep-in regions, supports hatched and loads as arrows onto their regions. */
function drawDomain(c: HTMLCanvasElement, d: { width: number; height: number; items: Item[] }, outlines: [number, number][][] | null): void {
  const g = fit(c);
  if (!g || !(d.width > 0 && d.height > 0)) return;
  const W = c.clientWidth, H = c.clientHeight, pad = 14;
  const s = Math.min((W - 2 * pad) / d.width, (H - 2 * pad) / d.height);
  const ox = (W - d.width * s) / 2, oy = (H - d.height * s) / 2;
  const x = (v: number) => ox + v * s;
  const y = (v: number) => oy + (d.height - v) * s;
  g.clearRect(0, 0, W, H);

  g.fillStyle = outlines ? "rgba(255,255,255,0.03)" : "rgba(61,139,255,0.08)";
  g.fillRect(x(0), y(d.height), d.width * s, d.height * s);
  g.strokeStyle = "rgba(255,255,255,0.22)";
  g.setLineDash([4, 3]);
  g.lineWidth = 1;
  g.strokeRect(x(0) + 0.5, y(d.height) + 0.5, d.width * s - 1, d.height * s - 1);
  g.setLineDash([]);

  for (const it of d.items.filter((i) => i.kind === "keep_out" || i.kind === "keep_in")) {
    regionPath(g, it.region, s, x, y);
    g.fillStyle = it.kind === "keep_out" ? "rgba(239,91,91,0.12)" : "rgba(240,163,58,0.16)";
    g.fill();
    g.setLineDash([3, 3]);
    g.strokeStyle = KINDS[it.kind].color;
    g.stroke();
    g.setLineDash([]);
  }

  if (outlines?.length) {
    g.beginPath();
    for (const loop of outlines) {
      loop.forEach(([px, py], i) => (i ? g.lineTo(x(px), y(py)) : g.moveTo(x(px), y(py))));
      g.closePath();
    }
    g.fillStyle = "#c7cdd6";
    g.fill("evenodd");
    g.strokeStyle = "#eef1f5";
    g.lineWidth = 0.8;
    g.stroke();
  }

  for (const it of d.items.filter((i) => i.kind === "support")) {
    regionPath(g, it.region, s, x, y);
    g.save();
    g.clip();
    g.strokeStyle = KINDS.support.color;
    g.lineWidth = 1.2;
    g.beginPath();
    for (let k = -H; k < W + H; k += 5) { g.moveTo(k, H); g.lineTo(k + H, 0); }
    g.stroke();
    g.restore();
    regionPath(g, it.region, s, x, y);
    g.strokeStyle = KINDS.support.color;
    g.lineWidth = 1.5;
    g.stroke();
    // A roller (one direction held) gets a small circle under its region.
    if (it.fix !== "all") {
      const [cx, cy] = regionCenter(it.region);
      g.beginPath();
      g.arc(x(cx), y(cy) + (it.fix === "y" ? 6 : 0), 3, 0, Math.PI * 2);
      g.stroke();
    }
  }

  for (const it of d.items.filter((i) => i.kind === "load")) {
    const [fx, fy] = it.force;
    const n = Math.hypot(fx, fy);
    regionPath(g, it.region, s, x, y);
    g.strokeStyle = KINDS.load.color;
    g.lineWidth = 1.2;
    g.stroke();
    if (!n) continue;
    const ux = fx / n, uy = -fy / n;
    const len = 30;
    // A spread load (a long region) shows a row of arrows; a point load shows one.
    const tips: [number, number][] = [];
    if (it.region.shape === "rect" && Math.max(it.region.max[0] - it.region.min[0], it.region.max[1] - it.region.min[1]) * s > 60) {
      const r = it.region, horizontal = r.max[0] - r.min[0] > r.max[1] - r.min[1];
      const count = Math.max(3, Math.round(((horizontal ? r.max[0] - r.min[0] : r.max[1] - r.min[1]) * s) / 28));
      for (let k = 0; k < count; k++) {
        const t = (k + 0.5) / count;
        tips.push(horizontal ? [x(r.min[0] + t * (r.max[0] - r.min[0])), y((r.min[1] + r.max[1]) / 2)] : [x((r.min[0] + r.max[0]) / 2), y(r.min[1] + t * (r.max[1] - r.min[1]))]);
      }
    } else {
      const [cx, cy] = regionCenter(it.region);
      tips.push([x(cx), y(cy)]);
    }
    g.strokeStyle = g.fillStyle = KINDS.load.color;
    g.lineWidth = 2;
    for (const [tx, ty] of tips) {
      const l = tips.length > 1 ? len * 0.6 : len;
      g.beginPath();
      g.moveTo(tx - ux * l, ty - uy * l);
      g.lineTo(tx - ux * 6, ty - uy * 6);
      g.stroke();
      g.beginPath();
      g.moveTo(tx, ty);
      g.lineTo(tx - ux * 8 - uy * 4, ty - uy * 8 + ux * 4);
      g.lineTo(tx - ux * 8 + uy * 4, ty - uy * 8 - ux * 4);
      g.closePath();
      g.fill();
    }
    const [cx, cy] = regionCenter(it.region);
    g.font = "10px system-ui, sans-serif";
    g.fillText(`${fmt(n)} N`, Math.min(W - 44, x(cx) - ux * (len + 4) + 4), Math.max(10, y(cy) - uy * (len + 4)));
  }
}

/** The objective per iteration, scaled to its own range. */
function drawSpark(c: HTMLCanvasElement, history: number[]): void {
  const g = fit(c);
  const h = history.filter(Number.isFinite);
  if (!g || h.length < 2) return;
  const W = c.clientWidth, H = c.clientHeight;
  const lo = Math.min(...h), hi = Math.max(...h), span = hi - lo || 1;
  g.beginPath();
  h.forEach((v, i) => {
    const px = (i / (h.length - 1)) * (W - 2) + 1;
    const py = H - 2 - ((v - lo) / span) * (H - 4);
    i ? g.lineTo(px, py) : g.moveTo(px, py);
  });
  g.strokeStyle = "#3d8bff";
  g.lineWidth = 1.2;
  g.stroke();
}
