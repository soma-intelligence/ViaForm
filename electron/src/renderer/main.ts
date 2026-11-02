import type { Json, LinkState, UpdateStatus, ViaFormAPI } from "../shared/api";
import { icon } from "./icons";
import { PART_KINDS, PcbCanvas, PcbModel } from "./pcb";
import { Viewport, type Hit } from "./viewport";

declare global {
  interface Window { viaform: ViaFormAPI }
}

// The app shell: one project, two workspaces (Design and Electronics) over the same Workspace in
// the main process, and the link between them shown in both.

type Workspace = "design" | "electronics";
type DesignTool = "select" | "box" | "cylinder" | "sphere";
interface Component { id: number; name: string; bodies: string[]; occurrences: { name: string }[] }

const api = window.viaform;
const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

const state = {
  ws: "design" as Workspace,
  tool: "select" as DesignTool,
  size: 20,
  selected: new Set<string>(),
  components: [] as Component[],
  link: { linked_revision: null, revision: 0, out_of_date: false } as LinkState,
  facePick: false,
  message: null as { text: string; error: boolean } | null,
  update: { state: "idle" } as UpdateStatus,
};

const viewport = new Viewport($("view3d"));
const pcb = new PcbModel();
const sheet = new PcbCanvas($<HTMLCanvasElement>("sheet-canvas"), pcb);

function flash(text: string | null, error = false): void {
  state.message = text ? { text, error } : null;
  renderPills();
  const s = $("status-msg");
  s.textContent = text ?? "";
  s.className = error ? "error" : "";
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

// MARK: Refresh

async function refreshDesign(): Promise<void> {
  viewport.show(await api.scene());
  const list = (await api.cad("component.list")) as { ok?: { components: Component[] } };
  state.components = list.ok?.components ?? [];
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
    renderLeft();
    renderRight();
    renderToolbar();
    renderPills();
  }
  void api.linkState().then((l) => {
    const changed = l.out_of_date !== state.link.out_of_date || l.linked_revision !== state.link.linked_revision;
    state.link = l;
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
  state.tool = "select";
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

// MARK: Design tools

viewport.onClick = (hit, e) => {
  if (state.ws !== "design") return;
  if (state.facePick) {
    if (hit) void mountOn(hit);
    return;
  }
  if (state.tool !== "select") {
    const at = hit?.point ?? viewport.ground(e.clientX, e.clientY, 1);
    if (at) void place(state.tool, at);
    return;
  }
  if (!hit) {
    if (!e.shiftKey) state.selected.clear();
  } else if (state.selected.has(hit.body)) state.selected.delete(hit.body);
  else {
    if (!e.shiftKey) state.selected.clear();
    state.selected.add(hit.body);
  }
  viewport.select(state.selected);
  render();
};

async function place(tool: DesignTool, c: [number, number, number]): Promise<void> {
  const v = Math.max(state.size, 0.1);
  if (tool === "box") await cad("solid.box", { length: v, width: v, height: v, corner: [c[0] - v / 2, c[1] - v / 2, c[2]] });
  if (tool === "cylinder") await cad("solid.cylinder", { diameter: v, height: v, base: c });
  if (tool === "sphere") await cad("solid.sphere", { diameter: v, center: [c[0], c[1], c[2] + v / 2] });
}

async function combine(operation: "join" | "cut"): Promise<void> {
  const b = [...state.selected];
  if (b.length < 2) return flash("Select a target body, then the tool bodies (Shift-click)", true);
  await cad("solid.combine", { target: b[0], tools: b.slice(1), operation });
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

// MARK: Rendering

function btn(name: string, label: string, onClick: () => void, opts: { on?: boolean; disabled?: boolean; dot?: boolean } = {}): HTMLButtonElement {
  const b = document.createElement("button");
  b.className = `tool${opts.on ? " on" : ""}`;
  b.title = label;
  b.innerHTML = icon(name) + (opts.dot ? '<span class="dot"></span>' : "");
  b.disabled = !!opts.disabled;
  b.onclick = onClick;
  return b;
}

function group(name: string, ...children: HTMLElement[]): HTMLElement {
  const g = document.createElement("div");
  g.className = "group";
  const t = document.createElement("div");
  t.className = "tools";
  t.append(...children);
  const n = document.createElement("div");
  n.className = "name";
  n.textContent = name;
  g.append(t, n);
  return g;
}

function field(label: string, input: HTMLElement): HTMLElement {
  const f = document.createElement("label");
  f.className = "field";
  f.append(label, input);
  return f;
}

function linkGroup(): HTMLElement {
  const linked = state.link.linked_revision != null;
  return group(
    "3D",
    btn("cube3d", linked ? "Update the 3D board" : "Send the board to the 3D design", () => void sendTo3D(), { dot: state.link.out_of_date }),
    btn("mount", "Mount the board on a part of the assembly", () => void startMount(), { on: state.facePick }),
  );
}

function renderToolbar(): void {
  const bar = $("toolbar");
  bar.replaceChildren();
  if (state.ws === "design") {
    const size = document.createElement("input");
    size.type = "number";
    size.value = String(state.size);
    size.min = "0.1";
    size.onchange = () => (state.size = Number(size.value) || 20);
    const pick = (t: DesignTool) => () => { state.tool = state.tool === t ? "select" : t; state.facePick = false; render(); };
    bar.append(
      group("SELECT", btn("select", "Select (Esc)", pick("select"), { on: state.tool === "select" && !state.facePick })),
      group("CREATE",
        btn("box", "Box: click to place", pick("box"), { on: state.tool === "box" }),
        btn("cylinder", "Cylinder: click to place", pick("cylinder"), { on: state.tool === "cylinder" }),
        btn("sphere", "Sphere: click to place", pick("sphere"), { on: state.tool === "sphere" }),
        field("mm", size)),
      group("MODIFY",
        btn("union", "Union the selected bodies", () => void combine("join"), { disabled: state.selected.size < 2 }),
        btn("subtract", "Subtract the other selected bodies from the first", () => void combine("cut"), { disabled: state.selected.size < 2 }),
        btn("trash", "Delete the selected bodies", () => void deleteBodies(), { disabled: !state.selected.size })),
      group("ELECTRONICS", btn("board", "Open the electronics", () => switchTo("electronics"))),
      linkGroup(),
      group("INSPECT", btn("fit", "Zoom to fit (F)", () => viewport.fit()), btn("search", "Find any command (Cmd/Ctrl+K)", () => openPalette())),
    );
  } else {
    const sheetPick = document.createElement("div");
    sheetPick.className = "segmented";
    for (const s of ["schematic", "board"] as const) {
      const b = document.createElement("button");
      b.textContent = s.toUpperCase();
      b.className = pcb.sheet === s ? "on" : "";
      b.onclick = () => { pcb.sheet = s; pcb.tool = { kind: "select" }; render(); };
      sheetPick.append(b);
    }
    const t = pcb.tool;
    const tools: HTMLElement[] = [group("SHEET", sheetPick)];
    if (pcb.sheet === "schematic") {
      tools.push(
        group("PLACE", ...PART_KINDS.map((k) => btn(k, `Place a ${k}`, () => (pcb.tool = { kind: "place", part: k }), { on: t.kind === "place" && t.part === k }))),
        group("CONNECT", btn("wire", "Wire (W)", () => (pcb.tool = { kind: "wire" }), { on: t.kind === "wire" })),
      );
    } else {
      const layer = document.createElement("select");
      layer.innerHTML = `<option>F.Cu</option><option>B.Cu</option>`;
      layer.value = pcb.layer;
      layer.onchange = () => { pcb.layer = layer.value; sheet.draw(); };
      tools.push(group("ROUTE",
        btn("route", "Route (X)", () => (pcb.tool = { kind: "route" }), { on: t.kind === "route" }),
        btn("routeAll", "Route all airwires", () => void pcb.routeAll()),
        field("", layer)));
    }
    tools.push(
      group("BOARD", btn("update", "Update PCB from schematic", () => void pcb.updateBoard().then(render))),
      group("MODIFY",
        btn("select", "Select (Esc)", () => (pcb.tool = { kind: "select" }), { on: t.kind === "select" }),
        btn("rotate", "Rotate (R)", () => void pcb.rotateSelection(), { disabled: pcb.selection == null }),
        btn("trash", "Delete", () => void pcb.deleteSelection(), { disabled: pcb.selection == null })),
      linkGroup(),
      group("OUTPUT", btn("export", "Export KiCad board", () => void exportKicad())),
    );
    bar.append(...tools);
  }
  const h = $("history");
  h.replaceChildren(btn("undo", "Undo (Cmd/Ctrl+Z)", () => void undo()), btn("redo", "Redo (Cmd/Ctrl+Shift+Z)", () => void redo()));
}

async function exportKicad(): Promise<void> {
  const r = await api.file("exportKicad");
  if ("error" in r) { if (r.error !== "cancelled") flash(r.error, true); }
  else flash("KiCad board exported");
}

function item(iconName: string, label: string, sub: string, on: boolean, onClick: () => void, extra = ""): HTMLElement {
  const d = document.createElement("div");
  d.className = `item${on ? " on" : ""}`;
  d.innerHTML = `${icon(iconName, 15)}<span>${esc(label)}</span><span class="sub">${esc(sub)}</span>${extra}`;
  d.onclick = onClick;
  return d;
}

function heading(text: string): HTMLElement {
  const h = document.createElement("h3");
  h.textContent = text;
  return h;
}

function renderLeft(): void {
  const left = $("left");
  left.replaceChildren();
  if (state.ws === "design") {
    const root = state.components.find((c) => c.id === 0);
    if (root?.bodies.length) left.append(heading("BODIES"));
    for (const b of root?.bodies ?? []) left.append(item("part", b, "", state.selected.has(b), () => toggleBody(b)));
    const comps = state.components.filter((c) => c.id !== 0);
    if (comps.length) left.append(heading("COMPONENTS"));
    for (const c of comps) {
      const isBoard = c.name.startsWith("PCB ") && state.link.linked_revision != null;
      const badge = isBoard ? `<span class="badge${state.link.out_of_date ? " warn" : ""}">${state.link.out_of_date ? "out of date" : `rev ${state.link.linked_revision}`}</span>` : "";
      left.append(item(isBoard ? "cpu" : "box", c.name, "", false, () => { c.bodies.forEach((b) => state.selected.add(b)); viewport.select(state.selected); render(); }, badge));
      for (const b of c.bodies) {
        const el = item("part", b, "", state.selected.has(b), () => toggleBody(b));
        el.classList.add("child");
        left.append(el);
      }
    }
    if (!root?.bodies.length && !comps.length) {
      const p = document.createElement("p");
      p.className = "muted";
      p.style.padding = "0 12px";
      p.textContent = "Pick Box, Cylinder or Sphere and click in the view, or send the board from Electronics.";
      left.append(p);
    }
  } else {
    const p = pcb.project;
    if (!p) return;
    left.append(heading("PARTS"));
    for (const c of p.components) left.append(item(c.kind, c.reference, c.value, pcb.selection === c.id, () => { pcb.selection = c.id; pcb.onChange(); }));
    left.append(heading("NETS"));
    for (const n of p.nets) left.append(item("net", n.name, "", false, () => {}));
    left.append(heading("BOARD"));
    left.append(item("board", `${Math.round(p.board.width)} × ${Math.round(p.board.height)} mm`, `${p.board.tracks.length} tracks`, false, () => {}));
    for (const t of p.board.tracks) left.append(item("route", pcb.nets.get(t.net) ?? "net", `on ${t.layer}`, pcb.selection === t.id, () => { pcb.selection = t.id; pcb.onChange(); }));
  }
}

function toggleBody(b: string): void {
  if (state.selected.has(b)) state.selected.delete(b);
  else state.selected.add(b);
  viewport.select(state.selected);
  render();
}

function renderRight(): void {
  const right = $("right");
  right.replaceChildren();
  const card = document.createElement("div");
  card.className = "card";
  const linked = state.link.linked_revision != null;
  card.innerHTML = `<h4>${icon("link", 14)} Board in 3D</h4><div class="muted">${
    linked
      ? state.link.out_of_date
        ? `Built from revision ${state.link.linked_revision}; the board is now at ${state.link.revision}.`
        : `Up to date with board revision ${state.link.revision}.`
      : "The board is not in the 3D design yet."
  }</div>`;
  const row = document.createElement("div");
  row.className = "row";
  const send = document.createElement("button");
  send.textContent = linked ? "Update 3D" : "Send to 3D";
  send.onclick = () => void sendTo3D();
  const mount = document.createElement("button");
  mount.textContent = "Mount on a part";
  mount.onclick = () => void startMount();
  row.append(send, mount);
  card.append(row);
  right.append(card);

  if (state.ws === "electronics") {
    const f = pcb.findings;
    const head = document.createElement("div");
    head.className = "checks-head";
    head.innerHTML = `<span class="${f.length ? "warn" : "ok"}">${icon(f.length ? "warn" : "check", 16)}</span>${f.length ? `${f.length} findings` : "No ERC or DRC findings"}<span class="badge">${pcb.checks?.airwires.length ?? 0} unrouted</span>`;
    right.append(head);
    for (const x of f) {
      const b = document.createElement("button");
      b.className = `finding ${x.severity}`;
      b.innerHTML = `${icon(x.severity === "error" ? "warn" : "warn", 14)}<span>${esc(x.message)}</span>`;
      b.onclick = () => { pcb.selection = x.objects?.[0] ?? null; pcb.onChange(); };
      right.append(b);
    }
  } else {
    const sel = document.createElement("div");
    sel.className = "card";
    sel.innerHTML = `<h4>Selection</h4><div class="muted">${state.selected.size ? [...state.selected].map(esc).join(", ") : "Click a body; Shift-click adds."}</div>`;
    right.append(sel);
  }
}

function pill(text: string, error = false, button?: [string, () => void], cancel?: () => void): HTMLElement {
  const p = document.createElement("div");
  p.className = `pill${error ? " error" : ""}`;
  p.append(text);
  if (button) {
    const b = document.createElement("button");
    b.className = "primary";
    b.textContent = button[0];
    b.onclick = button[1];
    p.append(b);
  }
  if (cancel) {
    const b = document.createElement("button");
    b.textContent = "Cancel";
    b.onclick = cancel;
    p.append(b);
  }
  return p;
}

function renderPills(): void {
  const pills = $("pills");
  pills.replaceChildren();
  if (state.ws === "design") {
    if (state.facePick) pills.append(pill("Click the face the board sits on", false, undefined, () => { state.facePick = false; render(); }));
    else if (state.link.out_of_date) pills.append(pill("The board changed in Electronics", false, ["Update 3D", () => void sendTo3D()]));
    else if (state.tool !== "select") pills.append(pill(`Click in the view to place a ${state.tool} (${state.size} mm).`));
  } else if (pcb.hint) pills.append(pill(pcb.hint));
  const m = state.ws === "electronics" ? pcb.message : state.message;
  if (m) pills.append(pill(m.text, m.error));
}

function render(): void {
  for (const b of document.querySelectorAll<HTMLButtonElement>("#workspace button")) b.classList.toggle("on", b.dataset.ws === state.ws);
  $("view3d").hidden = state.ws !== "design";
  $("sheet").hidden = state.ws !== "electronics";
  renderToolbar();
  renderLeft();
  renderRight();
  renderPills();
  if (state.ws === "electronics") sheet.draw();
}

function switchTo(ws: Workspace): void {
  if (state.ws === ws) return;
  state.ws = ws;
  render();
  if (ws === "electronics") requestAnimationFrame(() => sheet.draw());
}

for (const b of document.querySelectorAll<HTMLButtonElement>("#workspace button")) b.onclick = () => switchTo(b.dataset.ws as Workspace);

// View buttons over the 3D view, and the sheet's zoom buttons.
const views = document.createElement("div");
views.className = "views";
for (const [n, label] of [["home", "Home"], ["top", "Top"], ["front", "Front"], ["right", "Right"], ["fit", "Fit"]] as const) {
  const b = document.createElement("button");
  b.title = label;
  b.innerHTML = icon(n, 16);
  b.onclick = () => (n === "fit" ? viewport.fit() : viewport.look(n));
  views.append(b);
}
$("view3d").append(views);
for (const [label, f] of [["−", () => sheet.zoom(1 / 1.3)], ["+", () => sheet.zoom(1.3)], ["⤢", () => sheet.fit()]] as const) {
  const b = document.createElement("button");
  b.textContent = label;
  b.onclick = f;
  $("zoom").append(b);
}

// MARK: Command search: every engine command, with its parameters as JSON

interface Spec { id: string; label: string; tab: string; panel: string; params: string }
let specs: Spec[] = [];
let paletteIndex = 0;
let chosen: Spec | null = null;

async function openPalette(): Promise<void> {
  if (!specs.length) specs = (await api.commands()) as unknown as Spec[];
  $("palette").hidden = false;
  $("palette-form").hidden = true;
  $("palette-list").hidden = false;
  const input = $<HTMLInputElement>("palette-input");
  input.value = "";
  input.focus();
  listPalette();
}

function matches(): Spec[] {
  const q = $<HTMLInputElement>("palette-input").value.trim().toLowerCase();
  const all = specs.filter((s) => !q || s.label.toLowerCase().includes(q) || s.id.includes(q) || s.panel.toLowerCase().includes(q));
  return all.slice(0, 60);
}

function listPalette(): void {
  const ul = $("palette-list");
  ul.replaceChildren();
  matches().forEach((s, i) => {
    const li = document.createElement("li");
    li.className = i === paletteIndex ? "on" : "";
    li.innerHTML = `<span>${esc(s.label)} <span class="muted">${esc(s.tab)} · ${esc(s.panel)}</span></span><span class="id">${esc(s.id)}</span>`;
    li.onclick = () => choose(s);
    ul.append(li);
  });
}

function choose(s: Spec): void {
  chosen = s;
  $("palette-list").hidden = true;
  $("palette-form").hidden = false;
  $("palette-title").textContent = `${s.label} (${s.id})`;
  $("palette-doc").textContent = s.params || "No parameters.";
  const ta = $<HTMLTextAreaElement>("palette-params");
  ta.value = state.selected.size ? JSON.stringify({ bodies: [...state.selected] }, null, 1) : "{}";
  ta.focus();
}

function closePalette(): void {
  $("palette").hidden = true;
  chosen = null;
}

$("palette-input").addEventListener("input", () => { paletteIndex = 0; listPalette(); });
$("palette-input").addEventListener("keydown", (e) => {
  const list = matches();
  if (e.key === "ArrowDown") { paletteIndex = Math.min(paletteIndex + 1, list.length - 1); listPalette(); e.preventDefault(); }
  if (e.key === "ArrowUp") { paletteIndex = Math.max(paletteIndex - 1, 0); listPalette(); e.preventDefault(); }
  if (e.key === "Enter" && list[paletteIndex]) choose(list[paletteIndex]);
});
$("palette-back").onclick = () => void openPalette();
$("palette-run").onclick = async () => {
  if (!chosen) return;
  let params: Record<string, unknown>;
  try {
    params = JSON.parse($<HTMLTextAreaElement>("palette-params").value || "{}");
  } catch (e) {
    return flash(`Parameters: ${(e as Error).message}`, true);
  }
  const id = chosen.id;
  closePalette();
  const r = await cad(id, params);
  if (r !== undefined) flash(`${id} done`);
};
$("palette").addEventListener("click", (e) => { if (e.target === $("palette")) closePalette(); });

// MARK: Keys and menus

document.addEventListener("keydown", (e) => {
  if ((e.target as HTMLElement).closest("input, textarea, select")) {
    if (e.key === "Escape") closePalette();
    return;
  }
  if (e.key === "Escape") {
    closePalette();
    state.facePick = false;
    state.tool = "select";
    pcb.tool = { kind: "select" };
    render();
  }
  if (state.ws === "electronics") {
    if (e.key === "w") pcb.tool = { kind: "wire" };
    if (e.key === "x") pcb.tool = { kind: "route" };
    if (e.key === "r") void pcb.rotateSelection();
    if (e.key === "Delete" || e.key === "Backspace") void pcb.deleteSelection();
  } else {
    if (e.key === "f") viewport.fit();
    if (e.key === "Delete" || e.key === "Backspace") void deleteBodies();
  }
});

api.onMenu((c) => {
  if (c === "undo") void undo();
  else if (c === "redo") void redo();
  else if (c === "search") void openPalette();
  else if (c === "fit") state.ws === "design" ? viewport.fit() : sheet.fit();
  else if (c === "about") void about();
  else if (c.startsWith("workspace:")) switchTo(c.slice(10) as Workspace);
  else if (c.startsWith("sheet:")) { pcb.sheet = c.slice(6) as "schematic" | "board"; render(); }
});

api.onDocChanged(() => {
  state.selected.clear();
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
    const b = document.createElement("button");
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

async function versions(): Promise<void> {
  const v = await api.versions();
  $("status-versions").textContent = `ViaForm ${v.app} · SolidCraft ${v.solidcraft} · PCBCraft ${v.pcbcraft}`;
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
  if (new URLSearchParams(location.search).get("demo") === "pcb-3d") await demo();
  await refreshAll();
  viewport.fit();
  await versions();
  render();
})();
