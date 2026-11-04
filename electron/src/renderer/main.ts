import type { DocState, Json, LinkState, UpdateStatus, ViaFormAPI } from "../shared/api";
import { icon } from "./icons";
import { PART_KINDS, PcbCanvas, PcbModel } from "./pcb";
import { BRAINS, CAMERAS, MISSIONS, SimView, type SimSettings } from "./simulation";
import { WEATHERS } from "../shared/sim/weather";
import { ViewCube } from "./viewcube";
import { Viewport, type Hit, type NavMode, type ViewName, type VisualStyle } from "./viewport";

declare global {
  interface Window { viaform: ViaFormAPI }
}

// The app shell: one project, two workspaces (Design and Electronics) over the same Workspace in
// the main process, and the link between them shown in both; a third, Simulation, flies the drone. The layout follows the usual desktop
// CAD arrangement (docs/ui-reference.md): application bar, toolbar of tabs and panels, a floating
// browser, ViewCube, navigation bar, timeline, marking menu, command dialog and command search.

type Workspace = "design" | "electronics" | "simulation";
type PlaceTool = "box" | "cylinder" | "sphere";
interface Component { id: number; name: string; bodies: string[]; occurrences: { name: string }[] }
interface Spec { id: string; label: string; tab: string; panel: string; params: string; icon: string; key: string | null }
interface Feature { id: number; name: string; type: string; suppressed: boolean; rolled_back: boolean; error: string | null; warning: string | null }
interface DocInspect {
  name: string;
  active_sketch: Json;
  bodies: { name: string; visible: boolean; feature: number }[];
  sketches: { id?: number; name?: string; visible?: boolean }[];
  hidden_origin: string[];
  timeline: Feature[];
  marker: number;
  units: string;
}

const api = window.viaform;
const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
const el = <K extends keyof HTMLElementTagNameMap>(tag: K, cls = "", html = ""): HTMLElementTagNameMap[K] => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (html) e.innerHTML = html;
  return e;
};

const state = {
  ws: "design" as Workspace,
  tab: "SOLID",
  place: null as PlaceTool | null,
  size: 20,
  selected: new Set<string>(),
  components: [] as Component[],
  inspect: null as DocInspect | null,
  doc: { path: null, dirty: false } as DocState,
  link: { linked_revision: null, revision: 0, out_of_date: false } as LinkState,
  facePick: false,
  lastHit: null as Hit | null,
  feature: null as number | null,
  open: new Set(["root", "bodies", "components", "pcb:parts", "pcb:board"]),
  browserCollapsed: false,
  nav: "select" as NavMode,
  style: "shaded_with_edges" as VisualStyle,
  dialog: null as Spec | null,
  message: null as { text: string; error: boolean } | null,
  update: { state: "idle" } as UpdateStatus,
};

const viewport = new Viewport($("view3d"));
const cube = new ViewCube((v) => viewport.look(v));
$("view3d").append(cube.el);
viewport.onCamera = (c) => cube.update(c);
const pcb = new PcbModel();
const sheet = new PcbCanvas($<HTMLCanvasElement>("sheet-canvas"), pcb);
let simView: SimView | null = null;
/** Built on first use: the simulation has its own WebGL context and render loop. */
function sim(): SimView {
  if (!simView) {
    simView = new SimView($("sim"));
    simView.onChange = () => { if (state.ws === "simulation") renderToolbar(); };
  }
  return simView;
}

function flash(text: string | null, error = false): void {
  state.message = text ? { text, error } : null;
  renderPills();
}

async function cad(id: string, params: Record<string, unknown> = {}, quiet = false): Promise<Json | undefined> {
  const r = await api.cad(id, params as Json);
  if ("error" in r) {
    flash(r.error, true);
    return undefined;
  }
  if (!quiet) flash(null);
  await refreshDesign();
  return r.ok;
}

// MARK: Engine commands, grouped the way the toolbar shows them

let specs: Spec[] = [];
const spec = (id: string) => specs.find((s) => s.id === id);

const DESIGN_TABS = ["SOLID", "SURFACE", "SHEET METAL", "PLASTIC", "WELDMENTS"];
const PANEL_ORDER = ["FINISH SKETCH", "CREATE", "AUTOMATE", "MODIFY", "CONSTRAINTS", "PATTERN", "ASSEMBLE", "POSITION", "CONFIGURE", "CONSTRUCT", "INSPECT", "INSERT", "SETUP"];

// The big buttons of a panel; the rest are in its dropdown. Panels not named here show their first three.
const FEATURED: Record<string, string[]> = {
  "SOLID/CREATE": ["sketch.create", "solid.extrude", "solid.revolve", "solid.box", "solid.cylinder", "solid.hole"],
  "SOLID/MODIFY": ["solid.press_pull", "solid.fillet", "solid.chamfer", "solid.shell", "solid.combine", "solid.remove"],
  "SOLID/ASSEMBLE": ["component.create", "joint.create", "joint.as_built", "joint.rigid_group"],
  "SOLID/POSITION": ["component.capture_position"],
  "SOLID/CONFIGURE": ["config.configure"],
  "SOLID/CONSTRUCT": ["construct.plane.offset", "construct.plane.at_angle", "construct.axis.through_cylinder", "construct.point.vertex"],
  "SOLID/INSPECT": ["inspect.measure", "inspect.interference", "inspect.section"],
  "SOLID/INSERT": ["file.insert_step", "parts.fastener"],
  "SURFACE/CREATE": ["surface.extrude", "surface.patch", "surface.loft", "surface.offset", "surface.thicken"],
  "SURFACE/MODIFY": ["surface.trim", "surface.stitch", "surface.extend"],
  "SHEET METAL/CREATE": ["sheet.flange", "sheet.convert", "sheet.flat_pattern"],
  "SHEET METAL/MODIFY": ["sheet.unfold", "sheet.refold"],
  "PLASTIC/CREATE": ["plastic.boss", "plastic.lip", "plastic.snap_fit", "plastic.rest"],
  "SKETCH/CREATE": ["sketch.line", "sketch.rectangle.two_point", "sketch.circle.center", "sketch.arc.three_point", "sketch.polygon.inscribed", "sketch.slot.center_to_center", "sketch.dimension"],
  "SKETCH/MODIFY": ["sketch.fillet", "sketch.trim", "sketch.offset", "sketch.move"],
  "SKETCH/CONSTRAINTS": ["sketch.constraint.horizontal_vertical", "sketch.constraint.coincident", "sketch.constraint.tangent", "sketch.constraint.equal", "sketch.constraint.parallel", "sketch.constraint.perpendicular", "sketch.constraint.fix"],
  "SKETCH/PATTERN": ["sketch.mirror"],
  "SKETCH/INSPECT": ["inspect.measure"],
  "SKETCH/INSERT": ["sketch.insert_dxf", "sketch.insert_svg"],
};

const PLACE: Record<string, PlaceTool> = { "solid.box": "box", "solid.cylinder": "cylinder", "solid.sphere": "sphere" };

function panelsOf(tab: string): { name: string; items: Spec[] }[] {
  const byPanel = new Map<string, Spec[]>();
  // Inspect and Insert commands show in every modeling tab, the way they do in the Solid tab.
  for (const s of specs) {
    if (s.tab === tab || (tab !== "SKETCH" && tab !== "SOLID" && s.tab === "SOLID" && (s.panel === "INSPECT" || s.panel === "INSERT"))) {
      if (!byPanel.has(s.panel)) byPanel.set(s.panel, []);
      byPanel.get(s.panel)!.push(s);
    }
  }
  return [...byPanel.entries()]
    .sort((a, b) => rank(a[0]) - rank(b[0]))
    .map(([name, items]) => ({ name, items }));
}

function rank(panel: string): number {
  const i = PANEL_ORDER.indexOf(panel);
  return i < 0 ? 99 : i;
}

function sketching(): boolean {
  return state.inspect?.active_sketch != null;
}

/** Starts a command: primitives place by clicking, a few run at once, the rest open the command dialog. */
function run(s: Spec): void {
  closeMenus();
  if (PLACE[s.id]) {
    state.place = PLACE[s.id];
    state.facePick = false;
    openDialog(s);
    return;
  }
  const sel = [...state.selected];
  if (s.id === "solid.remove" && sel.length) return void deleteBodies();
  if (s.id === "sketch.finish" || s.id === "sketch.cancel" || s.id === "edit.undo" || s.id === "edit.redo") return void cad(s.id, {}, true);
  openDialog(s);
}

function prefill(s: Spec): Record<string, unknown> {
  const sel = [...state.selected];
  const p: Record<string, unknown> = {};
  if (s.id === "solid.combine" && sel.length) Object.assign(p, { target: sel[0], tools: sel.slice(1), operation: "join" });
  else if (/\bbodies\??:/.test(s.params) && sel.length) p.bodies = sel;
  else if (/\bbody\??:/.test(s.params) && sel.length) p.body = sel[0];
  if (s.id === "sketch.create") p.plane = "XY";
  if (s.id === "solid.extrude") p.distance = "10 mm";
  if (/^timeline\./.test(s.id) && state.feature != null) p.feature = state.feature;
  return p;
}

// MARK: Command dialog (floating, right of the canvas)

function openDialog(s: Spec, params?: Record<string, unknown>): void {
  state.dialog = s;
  const d = $("dialog");
  d.hidden = false;
  d.className = "float";
  const head = el("div", "fhead", `${icon(s.icon, 15)}<span>${esc(s.label.toUpperCase())}</span><span class="grow"></span>`);
  const x = el("button", "", icon("close", 13));
  x.title = "Cancel";
  x.onclick = () => closeDialog();
  head.append(x);
  dragBy(head, d);
  const body = el("div", "dbody");
  const ok = el("button", "btn primary");
  ok.textContent = "OK";
  const cancel = el("button", "btn");
  cancel.textContent = "Cancel";
  cancel.onclick = () => closeDialog();
  if (PLACE[s.id]) {
    const size = el("input");
    size.type = "number";
    size.min = "0.1";
    size.value = String(state.size);
    size.oninput = () => (state.size = Number(size.value) || 20);
    const row = el("div", "drow");
    row.append(Object.assign(el("label"), { textContent: s.id === "solid.box" ? "Size" : "Diameter" }), size);
    body.append(row, el("div", "muted", "Click in the view, on the grid or on a face, to place it. Each click places one more."));
    ok.onclick = () => closeDialog();
  } else {
    if (s.params) body.append(el("pre", "ddoc", esc(s.params)));
    const ta = el("textarea", "dparams");
    ta.spellcheck = false;
    ta.value = JSON.stringify(params ?? prefill(s), null, 1);
    body.append(ta);
    ok.onclick = async () => {
      let p: Record<string, unknown>;
      try {
        p = JSON.parse(ta.value || "{}");
      } catch (e) {
        return flash(`Parameters: ${(e as Error).message}`, true);
      }
      const r = await cad(s.id, p);
      if (r !== undefined) {
        closeDialog();
        flash(`${s.label} done`);
      }
    };
    ta.onkeydown = (e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) ok.click(); };
    requestAnimationFrame(() => ta.focus());
  }
  const foot = el("div", "dfoot");
  foot.append(ok, cancel);
  d.replaceChildren(head, body, foot);
  render();
}

function closeDialog(): void {
  state.dialog = null;
  state.place = null;
  $("dialog").hidden = true;
  render();
}

function dragBy(handle: HTMLElement, box: HTMLElement): void {
  handle.onpointerdown = (e) => {
    if ((e.target as HTMLElement).closest("button")) return;
    const r = box.getBoundingClientRect(), host = box.offsetParent!.getBoundingClientRect();
    const dx = e.clientX - r.left, dy = e.clientY - r.top;
    const move = (m: PointerEvent) => {
      box.style.left = `${Math.max(0, m.clientX - host.left - dx)}px`;
      box.style.top = `${Math.max(0, m.clientY - host.top - dy)}px`;
      box.style.right = "auto";
    };
    const up = () => { removeEventListener("pointermove", move); removeEventListener("pointerup", up); };
    addEventListener("pointermove", move);
    addEventListener("pointerup", up);
  };
}

// MARK: Refresh

async function refreshDesign(): Promise<void> {
  viewport.show(await api.scene());
  const list = (await api.cad("component.list")) as { ok?: { components: Component[] } };
  state.components = list.ok?.components ?? [];
  const insp = (await api.cad("document.inspect")) as { ok?: DocInspect };
  const wasSketching = sketching();
  state.inspect = insp.ok ?? null;
  if (sketching() && !wasSketching) state.tab = "SKETCH";
  if (!sketching() && state.tab === "SKETCH") state.tab = "SOLID";
  state.doc = await api.doc();
  const bodies = new Set(state.components.flatMap((c) => c.bodies));
  for (const b of [...state.selected]) if (!bodies.has(b)) state.selected.delete(b);
  viewport.select(state.selected);
  await refreshLink();
}

async function refreshLink(): Promise<void> {
  state.link = await api.linkState();
  render();
}

async function refreshAll(): Promise<void> {
  await pcb.refresh();
  await refreshDesign();
}

pcb.onChange = () => {
  if (state.ws === "electronics") {
    sheet.draw();
    renderBrowser();
    renderInspector();
    renderToolbar();
    renderPills();
  }
  void Promise.all([api.linkState(), api.doc()]).then(([l, d]) => {
    const changed = l.out_of_date !== state.link.out_of_date || l.linked_revision !== state.link.linked_revision || d.dirty !== state.doc.dirty;
    state.link = l;
    state.doc = d;
    if (changed) render();
  });
};

// MARK: Link (the same core code as the Swift apps)

async function sendTo3D(): Promise<void> {
  const first = state.link.linked_revision == null;
  const r = await api.linkPush();
  if ("error" in r) return flash(r.error, true);
  await refreshDesign();
  if (first) viewport.fit();
  flash(first ? "Board sent to the 3D design" : "3D board updated");
}

async function startMount(): Promise<void> {
  if (state.link.linked_revision == null) await sendTo3D();
  if (state.link.linked_revision == null) return;
  switchTo("design");
  closeDialog();
  state.facePick = true;
  render();
}

async function mountOn(hit: Hit): Promise<void> {
  state.facePick = false;
  const r = await api.linkMount(hit.body, hit.point, hit.normal);
  if ("error" in r) flash(r.error, true);
  else flash(`Board mounted on ${hit.body} with a rigid joint`);
  await refreshDesign();
}

// MARK: Canvas input

viewport.onClick = (hit, e) => {
  if (state.ws !== "design") return;
  if (hit) state.lastHit = hit;
  if (state.facePick) {
    if (hit) void mountOn(hit);
    return;
  }
  if (state.place) {
    const at = hit?.point ?? viewport.ground(e.clientX, e.clientY, 1);
    if (at) void place(state.place, at);
    return;
  }
  if (!hit) {
    if (!e.shiftKey) state.selected.clear();
  } else if (state.selected.has(hit.body) && (e.shiftKey || state.selected.size === 1)) state.selected.delete(hit.body);
  else {
    if (!e.shiftKey) state.selected.clear();
    state.selected.add(hit.body);
  }
  viewport.select(state.selected);
  render();
};

viewport.onDoubleClick = (hit) => {
  if (hit) viewport.lookAlong(hit.normal);
};

viewport.onContext = (hit, e) => {
  if (state.ws !== "design") return;
  if (hit) {
    state.lastHit = hit;
    if (!state.selected.has(hit.body)) {
      state.selected = new Set([hit.body]);
      viewport.select(state.selected);
      render();
    }
  }
  markingMenu(e.clientX, e.clientY, hit);
};

async function place(tool: PlaceTool, c: [number, number, number]): Promise<void> {
  const v = Math.max(state.size, 0.1);
  if (tool === "box") await cad("solid.box", { length: v, width: v, height: v, corner: [c[0] - v / 2, c[1] - v / 2, c[2]] });
  if (tool === "cylinder") await cad("solid.cylinder", { diameter: v, height: v, base: c });
  if (tool === "sphere") await cad("solid.sphere", { diameter: v, center: [c[0], c[1], c[2] + v / 2] });
}

async function deleteBodies(): Promise<void> {
  if (!state.selected.size) return;
  await cad("solid.remove", { bodies: [...state.selected] });
  state.selected.clear();
}

async function undo(): Promise<void> {
  if (state.ws === "design") await cad("edit.undo", {}, true);
  else await pcb.run("undo");
}

async function redo(): Promise<void> {
  if (state.ws === "design") await cad("edit.redo", {}, true);
  else await pcb.run("redo");
}

// MARK: Menus: dropdowns, context menus and the marking menu

type MenuEntry = { icon?: string; label: string; key?: string | null; run: () => void; disabled?: boolean } | "-" | { head: string };

function closeMenus(): void {
  const layer = $("menu-layer");
  layer.hidden = true;
  layer.replaceChildren();
  for (const n of document.querySelectorAll(".panel .name.on")) n.classList.remove("on");
}

function menuBox(entries: MenuEntry[]): HTMLElement {
  const m = el("div", "menu");
  for (const e of entries) {
    if (e === "-") m.append(el("div", "msep"));
    else if ("head" in e) m.append(el("div", "mhead", esc(e.head)));
    else {
      const b = el("button", "mi", `${icon(e.icon ?? "part", 16)}<span>${esc(e.label)}</span>${e.key ? `<span class="k">${esc(e.key)}</span>` : ""}`);
      b.disabled = !!e.disabled;
      b.onclick = () => { closeMenus(); e.run(); };
      m.append(b);
    }
  }
  return m;
}

function showMenu(entries: MenuEntry[], x: number, y: number, below?: HTMLElement): void {
  closeMenus();
  const layer = $("menu-layer");
  const m = menuBox(entries);
  layer.append(m);
  layer.hidden = false;
  layer.onpointerdown = (e) => { if (e.target === layer) closeMenus(); };
  layer.oncontextmenu = (e) => { e.preventDefault(); closeMenus(); };
  if (below) {
    const r = below.getBoundingClientRect();
    x = r.left;
    y = r.bottom + 2;
  }
  const w = m.offsetWidth, h = m.offsetHeight;
  m.style.left = `${Math.min(x, innerWidth - w - 6)}px`;
  m.style.top = `${Math.min(y, innerHeight - h - 6)}px`;
}

const entry = (id: string, override: Partial<{ label: string; run: () => void }> = {}): MenuEntry => {
  const s = spec(id);
  return s ? { icon: s.icon, label: override.label ?? s.label, key: s.key, run: override.run ?? (() => run(s)) } : { label: id, run: () => {}, disabled: true };
};

/** The wheel around the cursor: eight commands, then a list of the rest. */
function markingMenu(x: number, y: number, hit: Hit | null): void {
  closeMenus();
  const layer = $("menu-layer");
  const wheel = el("div", "marking");
  wheel.style.left = `${x}px`;
  wheel.style.top = `${y}px`;
  wheel.append(el("div", "hub"));
  const wedges: [string, string, () => void][] = [
    ["sketch", "Create Sketch", () => run(spec("sketch.create")!)],
    ["extrude", "Extrude", () => run(spec("solid.extrude")!)],
    ["fillet", "Fillet", () => run(spec("solid.fillet")!)],
    ["hole", "Hole", () => run(spec("solid.hole")!)],
    ["delete", "Delete", () => void deleteBodies()],
    ["presspull", "Press Pull", () => run(spec("solid.press_pull")!)],
    ["undo", "Undo", () => void undo()],
    ["redo", "Redo", () => void redo()],
  ];
  wedges.forEach(([ic, label, f], i) => {
    const a = (i / 8) * Math.PI * 2 - Math.PI / 2;
    const b = el("button", "wedge", `${icon(ic, 15)}<span>${esc(label)}</span>`);
    b.style.left = `${Math.cos(a) * 112}px`;
    b.style.top = `${Math.sin(a) * 82}px`;
    b.onclick = () => { closeMenus(); f(); };
    wheel.append(b);
  });
  const sel = [...state.selected];
  const rest: MenuEntry[] = [
    { icon: "fit", label: "Fit", key: "F6", run: () => viewport.fit() },
    { icon: "home", label: "Home View", run: () => viewport.look("home") },
    ...(hit ? [{ icon: "look_at", label: "Look At", run: () => viewport.lookAlong(hit.normal) } as MenuEntry] : []),
    "-",
    ...(sel.length ? [
      { icon: "eye_off", label: sel.length > 1 ? "Hide Bodies" : `Hide ${sel[0]}`, run: () => void setVisible(sel, false) } as MenuEntry,
      { icon: "appearance", label: "Appearance…", key: "A", run: () => run(spec("appearance.assign")!) } as MenuEntry,
    ] : []),
    { icon: "eye", label: "Show All Bodies", run: () => void cad("browser.visibility", { visible: true, folder: "bodies" }) },
    { icon: "search", label: "Find Command…", key: "S", run: () => void openPalette() },
  ];
  const over = menuBox(rest);
  over.classList.add("overflow");
  wheel.append(over);
  layer.append(wheel);
  layer.hidden = false;
  layer.onpointerdown = (e) => { if (e.target === layer) closeMenus(); };
  layer.oncontextmenu = (e) => { e.preventDefault(); closeMenus(); };
}

async function setVisible(items: string[], visible: boolean): Promise<void> {
  await cad("browser.visibility", { visible, items });
}

// MARK: Application bar

function ab(name: string, title: string, onClick: (b: HTMLButtonElement) => void, opts: { chevron?: boolean; on?: boolean; disabled?: boolean } = {}): HTMLButtonElement {
  const b = el("button", `ab${opts.on ? " on" : ""}`, icon(name, 18) + (opts.chevron ? icon("chevron", 12) : ""));
  b.title = title;
  b.disabled = !!opts.disabled;
  b.onclick = () => onClick(b);
  return b;
}

function fileMenu(anchor: HTMLElement): void {
  showMenu([
    { icon: "file", label: "New Design", key: "Ctrl+N", run: () => void fileAction("new") },
    { icon: "folder", label: "Open…", key: "Ctrl+O", run: () => void fileAction("open") },
    { icon: "board", label: "Open Sample Project", run: () => void fileAction("sample") },
    "-",
    { icon: "save", label: "Save", key: "Ctrl+S", run: () => void fileAction("save") },
    { icon: "save", label: "Save As…", key: "Ctrl+Shift+S", run: () => void fileAction("saveAs") },
    "-",
    { icon: "export", label: "Export STEP…", run: () => void fileAction("exportStep") },
    { icon: "export", label: "Export KiCad Board…", run: () => void fileAction("exportKicad") },
  ], 0, 0, anchor);
}

async function fileAction(a: "new" | "open" | "save" | "saveAs" | "exportKicad" | "exportStep" | "sample"): Promise<void> {
  $("datapanel").hidden = true;
  const r = await api.file(a);
  if ("error" in r) {
    if (r.error !== "cancelled") flash(r.error, true);
  } else if (a.startsWith("export")) flash(a === "exportStep" ? "STEP exported" : "KiCad board exported");
  else if (a === "save" || a === "saveAs") flash("Saved");
  state.doc = await api.doc();
  render();
}

function docName(): string {
  const p = state.doc.path;
  return p ? p.split(/[\\/]/).pop()!.replace(/\.viaform$/, "") : state.inspect?.name || "Untitled";
}

function renderAppbar(): void {
  const left = $("appbar-left");
  left.replaceChildren(
    ab("apps", "Show the data panel", () => toggleData(), { on: !$("datapanel").hidden }),
    ab("file", "File", (b) => fileMenu(b), { chevron: true }),
    ab("save", "Save (Ctrl+S)", () => void fileAction("save")),
    el("span", "ab-sep"),
    ab("undo", "Undo (Ctrl+Z)", () => void undo()),
    ab("redo", "Redo (Ctrl+Shift+Z)", () => void redo()),
  );
  const tab = el("div", "doctab", `${icon(state.ws === "design" ? "box" : "board", 15)}<span class="name">${esc(docName())}</span>${state.doc.dirty ? '<span class="dirty" title="Unsaved changes"></span>' : ""}`);
  tab.title = state.doc.path ?? "Not saved yet";
  const plus = ab("plus", "New design", () => void fileAction("new"));
  plus.classList.add("newtab");
  $("doctabs").replaceChildren(tab, plus);
  $("appbar-right").replaceChildren(
    ab("search", "Search commands (S)", () => void openPalette()),
    ab("help", "About ViaForm", () => void about()),
  );
}

function toggleData(): void {
  const p = $("datapanel");
  p.hidden = !p.hidden;
  if (!p.hidden) {
    p.className = "";
    const head = el("div", "fhead", `<span>${esc(docName())}</span><span class="grow"></span>`);
    const x = el("button", "", icon("close", 13));
    x.onclick = () => toggleData();
    head.append(x);
    const item = (ic: string, label: string, k: string, f: () => void) => {
      const b = el("button", "dp-item", `${icon(ic, 18)}<span>${esc(label)}</span>${k ? `<span class="k">${k}</span>` : ""}`);
      b.onclick = f;
      return b;
    };
    p.replaceChildren(
      head,
      el("div", "dp-sec", "PROJECT"),
      item("file", "New design", "Ctrl+N", () => void fileAction("new")),
      item("folder", "Open…", "Ctrl+O", () => void fileAction("open")),
      item("board", "Open the sample project", "", () => void fileAction("sample")),
      item("save", "Save", "Ctrl+S", () => void fileAction("save")),
      item("save", "Save as…", "", () => void fileAction("saveAs")),
      el("div", "dp-sec", "EXPORT"),
      item("export", "STEP", "", () => void fileAction("exportStep")),
      item("export", "KiCad board", "", () => void fileAction("exportKicad")),
      el("div", "dp-sec", "WORKSPACES"),
      item("box", "Design", "Ctrl+1", () => { toggleData(); switchTo("design"); }),
      item("board", "Electronics", "Ctrl+2", () => { toggleData(); switchTo("electronics"); }),
    );
  }
  renderAppbar();
}

// MARK: Toolbar: workspace menu, tabs, panels

function tool(name: string, label: string, onClick: () => void, opts: { on?: boolean; disabled?: boolean; dot?: boolean } = {}): HTMLButtonElement {
  const b = el("button", `tool${opts.on ? " on" : ""}`, icon(name, 26) + (opts.dot ? '<span class="dot"></span>' : ""));
  b.title = label;
  b.disabled = !!opts.disabled;
  b.onclick = onClick;
  return b;
}

function panel(name: string, children: HTMLElement[], dropdown?: () => MenuEntry[]): HTMLElement {
  const g = el("div", "panel");
  const t = el("div", "tools");
  t.append(...children);
  const n = el("button", "name", `${esc(name)}${dropdown ? icon("chevron", 11) : ""}`);
  if (dropdown) n.onclick = () => { showMenu(dropdown(), 0, 0, n); n.classList.add("on"); };
  else n.disabled = true;
  g.append(t, n);
  return g;
}

function specTool(s: Spec): HTMLButtonElement {
  const on = (PLACE[s.id] && state.place === PLACE[s.id]) || state.dialog?.id === s.id;
  const label = `${s.label}${s.key ? ` (${s.key})` : ""}`;
  if (s.id === "sketch.finish") {
    const b = el("button", "tool finish", `${icon("finish", 20)}<span>Finish Sketch</span>`);
    b.title = label;
    b.onclick = () => run(s);
    return b;
  }
  const disabled = (s.id === "solid.combine" && state.selected.size < 2) || (s.id === "solid.remove" && !state.selected.size);
  return tool(s.icon, label, () => run(s), { on: !!on, disabled });
}

function workspaceMenu(anchor: HTMLElement): void {
  showMenu([
    { head: "WORKSPACES" },
    { icon: "box", label: "Design", key: "Ctrl+1", run: () => switchTo("design") },
    { icon: "board", label: "Electronics", key: "Ctrl+2", run: () => switchTo("electronics") },
    { icon: "play", label: "Simulation", key: "Ctrl+3", run: () => switchTo("simulation") },
  ], 0, 0, anchor);
}

function electronicsPanel(): HTMLElement {
  const linked = state.link.linked_revision != null;
  return panel("ELECTRONICS", [
    tool("board", "Open the electronics (Ctrl+2)", () => switchTo("electronics")),
    tool("cube3d", linked ? "Update the 3D board" : "Send the board to the 3D design", () => void sendTo3D(), { dot: state.link.out_of_date }),
    tool("mount", "Mount the board on a part of the assembly", () => void startMount(), { on: state.facePick }),
  ], () => [
    { icon: "board", label: "Open Electronics", key: "Ctrl+2", run: () => switchTo("electronics") },
    { icon: "cube3d", label: linked ? "Update 3D Board" : "Send Board to 3D", run: () => void sendTo3D() },
    { icon: "mount", label: "Mount Board on a Part", run: () => void startMount() },
  ]);
}

/** A labelled drop-down in a toolbar panel. */
function choice<T extends string | number>(options: { id: T; label: string }[], value: T, set: (v: T) => void, width = 150): HTMLElement {
  const f = el("label", "field");
  const s = el("select");
  s.style.width = `${width}px`;
  s.innerHTML = options.map((o, i) => `<option value="${i}">${esc(o.label)}</option>`).join("");
  s.value = String(options.findIndex((o) => o.id === value));
  s.onchange = () => set(options[Number(s.value)].id);
  f.append(s);
  return f;
}

function simulationPanels(): HTMLElement[] {
  const v = sim(), S = v.settings;
  const set = <K extends keyof SimSettings>(k: K) => (x: SimSettings[K]) => v.set(k, x);
  return [
    panel("MISSION", [choice(MISSIONS, S.mission, set("mission"), 140)]),
    panel("WEATHER", [choice(WEATHERS.map((w, i) => ({ id: i, label: w.name })), S.weather, set("weather"), 170)]),
    panel("CONTROLLER", [choice(BRAINS, S.brain, set("brain"), 150)]),
    panel("FLY", [
      tool(v.playing ? "pause" : "play", v.playing ? "Pause (Space)" : "Fly (Space)", () => v.play()),
      tool("revert", "Fly again from the start (R)", () => v.restart()),
      tool("next", "Next random draw of the weather (N)", () => v.restart(true)),
      choice([0.25, 0.5, 1, 2, 4].map((x) => ({ id: x, label: `${x}×` })), S.speed, set("speed"), 58),
    ]),
    panel("VIEW", [
      choice(CAMERAS, S.camera, set("camera"), 92),
      tool("route", "Show the sensor beams", () => v.toggle("beams"), { on: S.show.beams }),
      tool("grid", "Show the occupancy map", () => v.toggle("map"), { on: S.show.map }),
      tool("line", "Show the planned path", () => v.toggle("path"), { on: S.show.path }),
    ]),
    panel("TEST", [tool("check", v.benchmarking ? "Stop the benchmark" : "Fly every weather three times and tabulate", () => v.benchmark(), { on: v.benchmarking })]),
  ];
}

function renderTabs(): void {
  const tabs = $("tabs");
  const ws = el("button", "ws-menu", `${state.ws.toUpperCase()}${icon("chevron", 12)}`);
  ws.title = "Change workspace";
  ws.onclick = () => workspaceMenu(ws);
  const list = state.ws === "design" ? [...(sketching() ? ["SKETCH"] : []), ...DESIGN_TABS] : state.ws === "simulation" ? ["FLIGHT"] : ["SCHEMATIC", "PCB"];
  const current = state.ws === "design" ? state.tab : state.ws === "simulation" ? "FLIGHT" : pcb.sheet === "schematic" ? "SCHEMATIC" : "PCB";
  tabs.replaceChildren(ws, ...list.map((t) => {
    const b = el("button", `tab${t === current ? " on" : ""}${t === "SKETCH" ? " contextual" : ""}`);
    b.textContent = t;
    b.onclick = () => {
      if (state.ws === "simulation") return;
      if (state.ws === "design") state.tab = t;
      else { pcb.sheet = t === "PCB" ? "board" : "schematic"; pcb.tool = { kind: "select" }; }
      render();
    };
    return b;
  }));
}

function renderToolbar(): void {
  renderTabs();
  const bar = $("toolbar");
  bar.replaceChildren();
  if (state.ws === "simulation") return void bar.append(...simulationPanels());
  if (state.ws === "design") {
    for (const p of panelsOf(state.tab)) {
      const featured = FEATURED[`${state.tab}/${p.name}`]?.map(spec).filter((s): s is Spec => !!s) ?? p.items.slice(0, 3);
      bar.append(panel(p.name, featured.map(specTool), () => p.items.map((s) => entry(s.id))));
      if (state.tab === "SOLID" && p.name === "CONSTRUCT") bar.append(electronicsPanel());
    }
    bar.append(panel("SELECT", [
      tool("select", "Select (Esc)", () => { closeDialog(); state.facePick = false; render(); }, { on: !state.place && !state.facePick }),
    ], () => [
      entry("select.clear", { run: () => { state.selected.clear(); viewport.select(state.selected); render(); } }),
      entry("select.same_look"),
      entry("select.filter"),
    ]));
    return;
  }
  const t = pcb.tool;
  const tools: HTMLElement[] = [];
  if (pcb.sheet === "schematic") {
    tools.push(
      panel("PLACE", PART_KINDS.map((k) => tool(k, `Place a ${k}`, () => (pcb.tool = { kind: "place", part: k }), { on: t.kind === "place" && t.part === k })),
        () => PART_KINDS.map((k) => ({ icon: k, label: `Place ${k[0].toUpperCase()}${k.slice(1)}`, run: () => (pcb.tool = { kind: "place", part: k }) }))),
      panel("CONNECT", [tool("wire", "Wire (W)", () => (pcb.tool = { kind: "wire" }), { on: t.kind === "wire" })]),
    );
  } else {
    const layer = el("select");
    layer.innerHTML = `<option>F.Cu</option><option>B.Cu</option>`;
    layer.value = pcb.layer;
    layer.onchange = () => { pcb.layer = layer.value; sheet.draw(); };
    const f = el("label", "field");
    f.append(layer);
    tools.push(panel("ROUTE", [
      tool("route", "Route (X)", () => (pcb.tool = { kind: "route" }), { on: t.kind === "route" }),
      tool("routeAll", "Route all airwires", () => void pcb.routeAll()),
      f,
    ]));
  }
  const linked = state.link.linked_revision != null;
  tools.push(
    panel("BOARD", [tool("update", "Update PCB from schematic", () => void pcb.updateBoard().then(render))]),
    panel("MODIFY", [
      tool("select", "Select (Esc)", () => (pcb.tool = { kind: "select" }), { on: t.kind === "select" }),
      tool("rotate", "Rotate (R)", () => void pcb.rotateSelection(), { disabled: pcb.selection == null }),
      tool("delete", "Delete", () => void pcb.deleteSelection(), { disabled: pcb.selection == null }),
    ]),
    panel("3D", [
      tool("cube3d", linked ? "Update the 3D board" : "Send the board to the 3D design", () => void sendTo3D(), { dot: state.link.out_of_date }),
      tool("mount", "Mount the board on a part of the assembly", () => void startMount(), { on: state.facePick }),
    ]),
    panel("OUTPUT", [tool("export", "Export KiCad board", () => void fileAction("exportKicad"))]),
  );
  bar.append(...tools);
}

// MARK: Browser

function node(depth: number, key: string | null, ic: string, label: string, opts: {
  sub?: string; on?: boolean; dim?: boolean; visible?: boolean; onEye?: () => void; onClick?: () => void; onContext?: (e: MouseEvent) => void; badge?: string; children?: () => HTMLElement[];
} = {}): HTMLElement[] {
  const row = el("div", `node${opts.on ? " on" : ""}${opts.dim ? " dim" : ""}`);
  row.style.paddingLeft = `${6 + depth * 14}px`;
  const tw = el("span", "twisty");
  if (key && opts.children) {
    const open = state.open.has(key);
    tw.classList.toggle("open", open);
    tw.innerHTML = icon("chevron_right", 12);
    tw.onclick = (e) => { e.stopPropagation(); open ? state.open.delete(key) : state.open.add(key); renderBrowser(); };
  }
  row.append(tw);
  if (opts.onEye) {
    const eye = el("span", `eye${opts.visible === false ? " off" : ""}`, icon(opts.visible === false ? "eye_off" : "eye", 14));
    eye.title = opts.visible === false ? "Show" : "Hide";
    eye.onclick = (e) => { e.stopPropagation(); opts.onEye!(); };
    row.append(eye);
  }
  row.insertAdjacentHTML("beforeend", `${icon(ic, 15)}<span class="label">${esc(label)}</span>${opts.sub ? `<span class="sub">${esc(opts.sub)}</span>` : ""}${opts.badge ?? ""}`);
  if (opts.onClick) row.onclick = opts.onClick;
  if (opts.onContext) row.oncontextmenu = (e) => { e.preventDefault(); opts.onContext!(e); };
  const out: HTMLElement[] = [row];
  if (key && opts.children && state.open.has(key)) out.push(...opts.children());
  return out;
}

function bodyNode(depth: number, b: string): HTMLElement[] {
  const vis = state.inspect?.bodies.find((x) => x.name === b)?.visible !== false;
  return node(depth, null, "part", b, {
    on: state.selected.has(b), dim: !vis, visible: vis,
    onEye: () => void setVisible([b], !vis),
    onClick: () => toggleBody(b),
    onContext: (e) => showMenu([
      { icon: vis ? "eye_off" : "eye", label: vis ? "Hide" : "Show", run: () => void setVisible([b], !vis) },
      { icon: "sketch", label: "Rename…", run: () => openDialog(spec("body.rename")!, { body: b, name: b }) },
      { icon: "appearance", label: "Appearance…", run: () => { state.selected = new Set([b]); run(spec("appearance.assign")!); } },
      "-",
      { icon: "delete", label: "Delete", key: "Del", run: () => void cad("solid.remove", { bodies: [b] }) },
    ], e.clientX, e.clientY),
  });
}

function renderBrowser(): void {
  const b = $("browser");
  b.className = `float${state.browserCollapsed ? " collapsed" : ""}`;
  const head = el("div", "fhead", `<span>BROWSER</span><span class="grow"></span>`);
  const fold = el("button", "", icon(state.browserCollapsed ? "plus" : "minus", 13));
  fold.title = state.browserCollapsed ? "Expand" : "Collapse";
  fold.onclick = () => { state.browserCollapsed = !state.browserCollapsed; renderBrowser(); };
  head.append(fold);
  const body = el("div", "fbody");
  if (state.ws === "design") body.append(...designTree());
  else body.append(...electronicsTree());
  b.replaceChildren(head, body);
}

function designTree(): HTMLElement[] {
  const insp = state.inspect;
  const root = state.components.find((c) => c.id === 0);
  const comps = state.components.filter((c) => c.id !== 0);
  const hidden = new Set(insp?.hidden_origin ?? []);
  const originItems = ["O", "X", "Y", "Z", "XY", "XZ", "YZ"];
  const originVisible = originItems.some((o) => !hidden.has(o));
  const sketches = insp?.sketches ?? [];
  return node(0, "root", "file", docName(), {
    badge: state.doc.dirty ? '<span class="badge">edited</span>' : "",
    children: () => [
      ...node(1, "settings", "settings", "Document Settings", {
        children: () => node(2, null, "dimension", `Units: ${insp?.units ?? "mm"}`, { onClick: () => openDialog(spec("document.units")!, { units: insp?.units ?? "mm" }) }),
      }),
      ...node(1, "origin", "origin", "Origin", {
        visible: originVisible,
        onEye: () => void cad("browser.visibility", { visible: !originVisible, folder: "origin" }),
        children: () => originItems.flatMap((o) => node(2, null, o.length === 1 ? (o === "O" ? "point" : "axis_two_points") : "plane", o, {
          visible: !hidden.has(o), dim: hidden.has(o), onEye: () => void setVisible([o], hidden.has(o)),
        })),
      }),
      ...(root?.bodies.length ? node(1, "bodies", "folder", "Bodies", {
        visible: root.bodies.some((x) => insp?.bodies.find((y) => y.name === x)?.visible !== false),
        onEye: () => void cad("browser.visibility", { visible: !root.bodies.some((x) => insp?.bodies.find((y) => y.name === x)?.visible !== false), folder: "bodies" }),
        children: () => root.bodies.flatMap((x) => bodyNode(2, x)),
      }) : []),
      ...(sketches.length ? node(1, "sketches", "folder", "Sketches", {
        children: () => sketches.flatMap((s, i) => node(2, null, "sketch", s.name ?? `Sketch${s.id ?? i + 1}`, {
          visible: s.visible !== false, dim: s.visible === false,
          onEye: () => void setVisible([String(s.name ?? s.id)], s.visible === false),
        })),
      }) : []),
      ...comps.flatMap((c) => {
        const isBoard = c.name.startsWith("PCB ") && state.link.linked_revision != null;
        const badge = isBoard ? `<span class="badge${state.link.out_of_date ? " warn" : ""}">${state.link.out_of_date ? "out of date" : `rev ${state.link.linked_revision}`}</span>` : "";
        return node(1, `c${c.id}`, isBoard ? "cpu" : "component", c.name, {
          badge,
          on: c.bodies.length > 0 && c.bodies.every((x) => state.selected.has(x)),
          onClick: () => { state.selected = new Set(c.bodies); viewport.select(state.selected); render(); },
          onContext: (e) => showMenu([
            ...(isBoard ? [
              { icon: "cube3d", label: "Update 3D Board", run: () => void sendTo3D() } as MenuEntry,
              { icon: "mount", label: "Mount Board on a Part", run: () => void startMount() } as MenuEntry,
              "-" as MenuEntry,
            ] : []),
            { icon: "eye_off", label: "Hide Bodies", run: () => void setVisible(c.bodies, false) },
            { icon: "eye", label: "Show Bodies", run: () => void setVisible(c.bodies, true) },
            { icon: "sketch", label: "Rename…", run: () => openDialog(spec("component.rename")!, { component: c.name, name: c.name }) },
          ], e.clientX, e.clientY),
          children: () => c.bodies.flatMap((x) => bodyNode(2, x)),
        });
      }),
    ],
  });
}

function electronicsTree(): HTMLElement[] {
  const p = pcb.project;
  if (!p) return [];
  return node(0, "root", "board", docName(), {
    children: () => [
      ...node(1, "pcb:parts", "folder", "Parts", {
        sub: String(p.components.length),
        children: () => p.components.flatMap((c) => node(2, null, c.kind, c.reference, { sub: c.value, on: pcb.selection === c.id, onClick: () => { pcb.selection = c.id; pcb.onChange(); } })),
      }),
      ...node(1, "pcb:nets", "folder", "Nets", {
        sub: String(p.nets.length),
        children: () => p.nets.flatMap((n) => node(2, null, "net", n.name)),
      }),
      ...node(1, "pcb:board", "folder", "Board", {
        sub: `${Math.round(p.board.width)} × ${Math.round(p.board.height)} mm`,
        children: () => p.board.tracks.flatMap((t) => node(2, null, "route", pcb.nets.get(t.net) ?? "net", { sub: `on ${t.layer}`, on: pcb.selection === t.id, onClick: () => { pcb.selection = t.id; pcb.onChange(); } })),
      }),
    ],
  });
}

function toggleBody(b: string): void {
  if (state.selected.has(b)) state.selected.delete(b);
  else state.selected.add(b);
  viewport.select(state.selected);
  render();
}

// MARK: Inspector (Electronics: the link to 3D and the checks)

function renderInspector(): void {
  const box = $("inspector");
  box.hidden = state.ws !== "electronics";
  if (box.hidden) return;
  box.className = "float";
  const body = el("div", "fbody");
  const linked = state.link.linked_revision != null;
  body.append(el("div", "", `<b>Board in 3D</b><div class="muted">${
    linked
      ? state.link.out_of_date
        ? `Built from revision ${state.link.linked_revision}; the board is now at ${state.link.revision}.`
        : `Up to date with board revision ${state.link.revision}.`
      : "The board is not in the 3D design yet."
  }</div>`));
  const row = el("div", "card-row");
  const send = el("button", "btn primary");
  send.textContent = linked ? "Update 3D" : "Send to 3D";
  send.onclick = () => void sendTo3D();
  const mount = el("button", "btn");
  mount.textContent = "Mount on a part";
  mount.onclick = () => void startMount();
  row.append(send, mount);
  body.append(row);
  const f = pcb.findings;
  body.append(el("div", "checks-head", `<span class="${f.length ? "warn" : "ok"}">${icon(f.length ? "warn" : "check", 16)}</span>${f.length ? `${f.length} findings` : "No ERC or DRC findings"}<span class="badge">${pcb.checks?.airwires.length ?? 0} unrouted</span>`));
  for (const x of f) {
    const b = el("button", `finding ${x.severity}`, `${icon("warn", 14)}<span>${esc(x.message)}</span>`);
    b.onclick = () => { pcb.selection = x.objects?.[0] ?? null; pcb.onChange(); };
    body.append(b);
  }
  box.replaceChildren(el("div", "fhead", "<span>INSPECTOR</span>"), body);
}

// MARK: Navigation bar

function nb(name: string, title: string, onClick: (b: HTMLButtonElement) => void, opts: { on?: boolean; chevron?: boolean } = {}): HTMLButtonElement {
  const b = el("button", `nb${opts.on ? " on" : ""}`, icon(name, 17) + (opts.chevron ? icon("chevron", 11) : ""));
  b.title = title;
  b.onclick = () => onClick(b);
  return b;
}

function setNav(mode: NavMode): void {
  state.nav = state.nav === mode ? "select" : mode;
  viewport.setNav(state.nav);
  renderNavbar();
}

function renderNavbar(): void {
  const bar = $("navbar");
  bar.className = "float";
  if (state.ws === "electronics") {
    bar.replaceChildren(
      nb("minus", "Zoom out", () => sheet.zoom(1 / 1.3)),
      nb("plus", "Zoom in", () => sheet.zoom(1.3)),
      nb("fit", "Fit (F6)", () => sheet.fit()),
    );
    return;
  }
  const styles: [VisualStyle, string][] = [["shaded_with_edges", "Shaded with Visible Edges"], ["shaded", "Shaded"], ["wireframe", "Wireframe"]];
  bar.replaceChildren(
    nb("orbit", "Orbit (Shift + middle drag, or right drag)", () => setNav("orbit"), { on: state.nav === "orbit" }),
    nb("look_at", "Look At the last picked face", () => { if (state.lastHit) viewport.lookAlong(state.lastHit.normal); else flash("Click a face first, then Look At"); }),
    nb("pan", "Pan (middle drag)", () => setNav("pan"), { on: state.nav === "pan" }),
    nb("zoom", "Zoom (wheel)", () => setNav("zoom"), { on: state.nav === "zoom" }),
    nb("fit", "Fit (F6)", () => viewport.fit()),
    el("span", "nb-sep"),
    nb("style", "Display settings", (b) => showMenu([
      { head: "VISUAL STYLE" },
      ...styles.map(([s, label]) => ({ icon: state.style === s ? "check" : "style", label, run: () => { state.style = s; viewport.setStyle(s); } })),
    ], 0, 0, b), { chevron: true }),
    nb("grid", "Grid", () => { viewport.gridVisible = !viewport.gridVisible; renderNavbar(); }, { on: viewport.gridVisible }),
  );
}

// MARK: Timeline

const FEATURE_ICON: [RegExp, string][] = [
  [/sketch/i, "sketch"], [/box/i, "box"], [/cylinder/i, "cylinder"], [/sphere/i, "sphere"], [/torus/i, "torus"], [/cone/i, "cone"],
  [/extrude/i, "extrude"], [/revolve/i, "revolve"], [/sweep/i, "sweep"], [/loft/i, "loft"], [/hole/i, "hole"], [/fillet/i, "fillet"],
  [/chamfer/i, "chamfer"], [/shell/i, "shell"], [/combine/i, "combine"], [/mirror/i, "mirror"], [/pattern/i, "pattern_rect"],
  [/presspull|offsetface/i, "presspull"], [/move/i, "move"], [/joint|rigid/i, "joint"], [/plane/i, "plane"], [/axis/i, "axis_two_points"],
  [/component|link|pcb|board/i, "component"], [/appearance/i, "appearance"], [/remove|delete/i, "delete"], [/scale/i, "scale"],
];

const featureIcon = (type: string) => FEATURE_ICON.find(([r]) => r.test(type))?.[1] ?? "part";

async function rollTo(position: number | "end"): Promise<void> {
  await cad("timeline.roll_to", { position }, true);
}

let playing = false;
async function play(): Promise<void> {
  const insp = state.inspect;
  if (!insp || playing) return;
  playing = true;
  if (insp.marker >= insp.timeline.length) await rollTo(0);
  while (playing && state.inspect && state.inspect.marker < state.inspect.timeline.length) {
    await new Promise((r) => setTimeout(r, 450));
    await rollTo(state.inspect.marker + 1);
  }
  playing = false;
}

function renderTimeline(): void {
  const tl = $("timeline");
  tl.hidden = state.ws !== "design";
  if (tl.hidden) return;
  const insp = state.inspect;
  const n = insp?.timeline.length ?? 0, marker = insp?.marker ?? 0;
  const b = (ic: string, title: string, f: () => void) => {
    const x = el("button", "tl-btn", icon(ic, 14));
    x.title = title;
    x.onclick = f;
    return x;
  };
  const track = el("div", "tl-track");
  const marks: HTMLElement[] = [];
  insp?.timeline.forEach((f, i) => {
    const chip = el("button", `tl-item${state.feature === f.id ? " on" : ""}${i >= marker ? " rolled" : ""}${f.suppressed ? " suppressed" : ""}${f.error ? " error" : f.warning ? " warning" : ""}`, icon(featureIcon(f.type), 16));
    chip.title = `${f.name}${f.error ? `: ${f.error}` : f.warning ? `: ${f.warning}` : ""}`;
    chip.onclick = () => { state.feature = state.feature === f.id ? null : f.id; renderTimeline(); };
    chip.ondblclick = () => openDialog(spec("timeline.edit")!, { feature: f.id, set: {} });
    chip.oncontextmenu = (e) => {
      e.preventDefault();
      state.feature = f.id;
      renderTimeline();
      showMenu([
        { head: f.name.toUpperCase() },
        { icon: "sketch", label: "Edit Feature", run: () => openDialog(spec("timeline.edit")!, { feature: f.id, set: {} }) },
        { icon: "rollback", label: "Roll History Marker Here", run: () => void cad("timeline.roll_to", { feature: f.id }, true) },
        { icon: "suppress", label: f.suppressed ? "Unsuppress Feature" : "Suppress Feature", run: () => void cad("timeline.suppress", { feature: f.id }) },
        { icon: "sketch", label: "Rename…", run: () => openDialog(spec("timeline.rename")!, { feature: f.id, name: f.name }) },
        "-",
        { icon: "delete", label: "Delete", run: () => void cad("timeline.delete", { feature: f.id }) },
      ], e.clientX, e.clientY);
    };
    if (i === marker) track.append(markerEl(marks));
    marks.push(chip);
    track.append(chip);
  });
  if (n === 0) track.append(el("span", "tl-empty", "The timeline fills as you model."));
  else if (marker >= n) track.append(markerEl(marks));
  tl.replaceChildren(
    b("first", "Move to the beginning", () => void rollTo(0)),
    b("prev", "Step back", () => void rollTo(Math.max(0, marker - 1))),
    b("play", "Play", () => void play()),
    b("next", "Step forward", () => void rollTo(Math.min(n, marker + 1))),
    b("last", "Move to the end", () => void rollTo("end")),
    el("span", "tl-sep"),
    track,
  );
}

/** The history marker: drag it between features to roll the model back or forward. */
function markerEl(chips: HTMLElement[]): HTMLElement {
  const m = el("div", "tl-marker");
  m.title = "History marker: drag to roll back";
  m.onpointerdown = (e) => {
    m.setPointerCapture(e.pointerId);
    let pos = state.inspect?.marker ?? 0;
    m.onpointermove = (ev) => {
      const all = [...document.querySelectorAll<HTMLElement>(".tl-item")];
      pos = all.filter((c) => { const r = c.getBoundingClientRect(); return r.left + r.width / 2 < ev.clientX; }).length;
      all.forEach((c, i) => c.classList.toggle("rolled", i >= pos));
    };
    m.onpointerup = () => {
      m.onpointermove = null;
      m.onpointerup = null;
      void rollTo(pos);
    };
  };
  void chips;
  return m;
}

// MARK: Pills (prompts and messages over the canvas)

function pill(text: string, error = false, button?: [string, () => void], cancel?: () => void): HTMLElement {
  const p = el("div", `pill${error ? " error" : ""}`);
  p.append(text);
  if (button) {
    const b = el("button", "primary");
    b.textContent = button[0];
    b.onclick = button[1];
    p.append(b);
  }
  if (cancel) {
    const b = el("button");
    b.textContent = "Cancel";
    b.onclick = cancel;
    p.append(b);
  }
  return p;
}

let messageTimer = 0;
function renderPills(): void {
  const pills = $("pills");
  pills.replaceChildren();
  if (state.ws === "design") {
    if (state.facePick) pills.append(pill("Click the face the board sits on", false, undefined, () => { state.facePick = false; render(); }));
    else if (state.link.out_of_date) pills.append(pill("The board changed in Electronics", false, ["Update 3D", () => void sendTo3D()]));
  } else if (pcb.hint) pills.append(pill(pcb.hint));
  const m = state.ws === "electronics" ? pcb.message : state.message;
  if (m) {
    pills.append(pill(m.text, m.error));
    clearTimeout(messageTimer);
    if (!m.error && state.ws === "design") messageTimer = window.setTimeout(() => flash(null), 3500);
  }
}

// MARK: Render

function render(): void {
  $("view3d").hidden = state.ws !== "design";
  $("sheet").hidden = state.ws !== "electronics";
  $("sim").hidden = state.ws !== "simulation";
  for (const id of ["browser", "navbar"]) $(id).style.display = state.ws === "simulation" ? "none" : "";
  renderAppbar();
  renderToolbar();
  renderBrowser();
  renderInspector();
  renderNavbar();
  renderTimeline();
  renderPills();
  if (state.ws === "electronics") sheet.draw();
}

function switchTo(ws: Workspace): void {
  if (state.ws === ws) return;
  state.ws = ws;
  if (ws !== "design") closeDialog();
  render();
  if (ws === "simulation") sim().setActive(true);
  else simView?.setActive(false);
  if (ws === "electronics") requestAnimationFrame(() => sheet.draw());
}

// MARK: Command search (S): every engine command

let paletteIndex = 0;

async function openPalette(): Promise<void> {
  closeMenus();
  $("palette").hidden = false;
  const input = $<HTMLInputElement>("palette-input");
  input.value = "";
  input.focus();
  paletteIndex = 0;
  listPalette();
}

function matches(): Spec[] {
  const q = $<HTMLInputElement>("palette-input").value.trim().toLowerCase();
  const all = specs.filter((s) => s.tab && (!q || s.label.toLowerCase().includes(q) || s.id.includes(q) || s.panel.toLowerCase().includes(q)));
  return all.slice(0, 60);
}

function listPalette(): void {
  const ul = $("palette-list");
  ul.replaceChildren();
  matches().forEach((s, i) => {
    const li = el("li", i === paletteIndex ? "on" : "", `${icon(s.icon, 16)}<span>${esc(s.label)}</span><span class="where">${esc(s.tab)} › ${esc(s.panel)}</span>${s.key ? `<span class="k">${esc(s.key)}</span>` : ""}`);
    li.onclick = () => choose(s);
    ul.append(li);
  });
  ul.querySelector("li.on")?.scrollIntoView({ block: "nearest" });
}

function choose(s: Spec): void {
  closePalette();
  if (state.ws !== "design") switchTo("design");
  run(s);
}

function closePalette(): void {
  $("palette").hidden = true;
}

$("palette-input").addEventListener("input", () => { paletteIndex = 0; listPalette(); });
$("palette-input").addEventListener("keydown", (e) => {
  const list = matches();
  if (e.key === "ArrowDown") { paletteIndex = Math.min(paletteIndex + 1, list.length - 1); listPalette(); e.preventDefault(); }
  if (e.key === "ArrowUp") { paletteIndex = Math.max(paletteIndex - 1, 0); listPalette(); e.preventDefault(); }
  if (e.key === "Enter" && list[paletteIndex]) choose(list[paletteIndex]);
});
$("palette").addEventListener("click", (e) => { if (e.target === $("palette")) closePalette(); });

// MARK: Keys and menus

document.addEventListener("keydown", (e) => {
  if ((e.target as Element).closest?.("input, textarea, select")) {
    if (e.key === "Escape") { closePalette(); (e.target as HTMLElement).blur(); }
    return;
  }
  const mod = e.metaKey || e.ctrlKey;
  if (e.key === "Escape") {
    closePalette();
    closeMenus();
    closeDialog();
    state.facePick = false;
    pcb.tool = { kind: "select" };
    if (state.nav !== "select") setNav(state.nav);
    render();
    return;
  }
  if (e.key === "F6") return state.ws === "design" ? viewport.fit() : sheet.fit();
  if (mod && e.key.toLowerCase() === "k") { e.preventDefault(); return void openPalette(); }
  if (mod || e.altKey) return;
  if (e.key === "s" || e.key === "S") { e.preventDefault(); return void openPalette(); }
  if (state.ws === "simulation") {
    const v = sim();
    if (e.key === " ") { e.preventDefault(); v.play(); }
    if (e.key === "r") v.restart();
    if (e.key === "n") v.restart(true);
    return;
  }
  if (state.ws === "electronics") {
    if (e.key === "w") pcb.tool = { kind: "wire" };
    if (e.key === "x") pcb.tool = { kind: "route" };
    if (e.key === "r") void pcb.rotateSelection();
    if (e.key === "Delete" || e.key === "Backspace") void pcb.deleteSelection();
    return;
  }
  if (e.key === "Delete" || e.key === "Backspace") return void deleteBodies();
  // Single-letter shortcuts from the engine (E extrude, F fillet, L line...); sketch tools win while sketching.
  const k = e.key.toUpperCase();
  const hits = specs.filter((s) => s.key === k && s.tab && s.tab !== "RENDER");
  const s = hits.find((x) => (x.tab === "SKETCH") === sketching()) ?? hits[0];
  if (s) { e.preventDefault(); run(s); }
});

api.onMenu((c) => {
  if (c === "undo") void undo();
  else if (c === "redo") void redo();
  else if (c === "search") void openPalette();
  else if (c === "fit") state.ws === "design" ? viewport.fit() : sheet.fit();
  else if (c === "about") void about();
  else if (c.startsWith("workspace:")) switchTo(c.slice(10) as Workspace);
  else if (c.startsWith("sim:")) { switchTo("simulation"); sim().stage(JSON.parse(c.slice(4))); }
  else if (c.startsWith("sheet:")) { pcb.sheet = c.slice(6) as "schematic" | "board"; render(); }
  else if (c.startsWith("view:")) viewport.look(c.slice(5) as ViewName);
});

api.onDocChanged(() => {
  state.selected.clear();
  state.feature = null;
  pcb.selection = null;
  void refreshAll().then(() => viewport.fit());
});

// MARK: Updates and versions

function renderUpdate(): void {
  const s = state.update;
  const banner = $("update-banner");
  banner.replaceChildren();
  banner.hidden = !(s.state === "ready" || s.state === "downloading");
  if (s.state === "downloading") banner.append(`Downloading ViaForm ${s.version}… ${Math.round(s.percent ?? 0)}%`);
  if (s.state === "ready") {
    const b = el("button");
    b.textContent = "Restart now";
    b.onclick = () => void api.installUpdate();
    banner.append(`ViaForm ${s.version} is ready. It installs when you quit, or now.`, b);
  }
}

function updateText(s: UpdateStatus): string {
  switch (s.state) {
    case "dev": return "Development build: updates are off";
    case "checking": return "Checking for updates…";
    case "none": return "ViaForm is up to date";
    case "available": return `ViaForm ${s.version} is available`;
    case "downloading": return `Downloading ${s.version}`;
    case "ready": return `${s.version} ready to install`;
    case "error": return `Update check failed: ${s.message}`;
    default: return "";
  }
}

api.onUpdate((s) => {
  state.update = s;
  renderUpdate();
});

async function about(): Promise<void> {
  const v = await api.versions();
  const d = $<HTMLDialogElement>("about");
  d.innerHTML = `<h2>ViaForm ${esc(v.app)}</h2><div class="muted">3D design and electronics, one project.</div>
    <table>
      <tr><td>Core</td><td>${esc(v.core)}</td></tr>
      <tr><td>SolidCraft engine</td><td>${esc(v.solidcraft)}</td></tr>
      <tr><td>PCBCraft engine</td><td>${esc(v.pcbcraft)}</td></tr>
      <tr><td>Project format</td><td>${v.format}</td></tr>
      <tr><td>Electron</td><td>${esc(v.electron)}</td></tr>
    </table>
    <div class="muted" id="about-update">${esc(updateText(state.update))}</div>
    <div class="row"><button id="about-check">Check for Updates</button><button id="about-close">Close</button></div>`;
  d.showModal();
  $("about-check").onclick = () => void api.checkForUpdates();
  $("about-close").onclick = () => d.close();
}

// MARK: Start

async function demo(): Promise<void> {
  // --pcb-3d: an enclosure with the sample board mounted on its top, for screenshots and checks.
  await api.cad("solid.box", { length: 80, width: 60, height: 12, corner: [-10, -50, 0], body_name: "Enclosure" });
  await api.cad("appearance.assign", { bodies: ["Enclosure"], color: "#b9bec6" });
  await api.linkPush();
  await api.linkMount("Enclosure", [30, -20, 12], [0, 0, 1]);
}

void (async () => {
  specs = (await api.commands()) as unknown as Spec[];
  if (new URLSearchParams(location.search).get("demo") === "pcb-3d") await demo();
  await refreshAll();
  viewport.fit();
  render();
})();
