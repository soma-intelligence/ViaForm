import type { LibraryItem, LibraryState, SearchHit, SourceStatus, Use } from "../shared/library/types";
import { icon } from "./icons";

// The Libraries panel: one search across the side libraries (KiCad on this machine, standard
// hardware, the distributors whose keys are set, the parts saved by hand), the user's saved
// parts, and the sources with their keys and terms. Parts go into the design or the schematic
// through the same engine commands as the toolbar.

export interface LibraryHost {
  workspace(): string;
  /** Runs a use of an item (insert, place, assign); the message on failure, else null. */
  use(item: LibraryItem, use: Use): Promise<string | null>;
  flash(text: string | null, error?: boolean): void;
}

type Tab = "search" | "saved" | "sources";
type Filter = "all" | "electronics" | "mechanical";

const lib = () => window.viaform.library;
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
const el = <K extends keyof HTMLElementTagNameMap>(tag: K, cls = "", html = ""): HTMLElementTagNameMap[K] => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (html) e.innerHTML = html;
  return e;
};
const button = (cls: string, html: string, title: string, f: () => void) => {
  const b = el("button", cls, html);
  b.title = title;
  b.onclick = (e) => { e.stopPropagation(); f(); };
  return b;
};

/** Schematic parts the engine draws itself, for a distributor part with no KiCad symbol yet. */
function guessPart(i: LibraryItem): string | null {
  const t = `${i.category ?? ""} ${i.description ?? ""} ${i.name}`.toLowerCase();
  if (/\bled\b|light emitting/.test(t)) return "led";
  if (/resistor|\bres\b|ohm|Ω/.test(t)) return "resistor";
  if (/capacitor|\bcap\b|\bmlcc\b|[µu]f\b|\bpf\b|\bnf\b/.test(t)) return "capacitor";
  if (/connector|header|terminal|socket|\bjst\b/.test(t)) return "connector";
  return null;
}

function money(i: LibraryItem): string {
  const p = i.prices?.[0];
  if (!p) return "";
  const cur = p.currency === "USD" ? "$" : p.currency === "EUR" ? "€" : `${p.currency} `;
  return `${cur}${p.price < 1 ? p.price.toFixed(3) : p.price.toFixed(2)}${p.quantity > 1 ? ` /${p.quantity}+` : ""}`;
}

export class LibraryPanel {
  readonly el = el("aside");
  private tab: Tab = "search";
  private filter: Filter = "all";
  private query = "";
  private hits: SearchHit[] = [];
  private searching = false;
  private state: LibraryState | null = null;
  private openSource: string | null = null;
  private adding = false;
  private seq = 0;

  constructor(private readonly host: LibraryHost) {
    this.el.id = "library";
    this.el.hidden = true;
  }

  get open(): boolean { return !this.el.hidden; }

  async toggle(on = this.el.hidden): Promise<void> {
    this.el.hidden = !on;
    if (on) {
      await this.refresh(!this.state);
      (this.el.querySelector(".lib-search input") as HTMLInputElement | null)?.focus();
    }
  }

  /** Opens the panel on a search, the way the toolbar's library buttons do. */
  async show(tab: Tab, filter?: Filter): Promise<void> {
    this.tab = tab;
    if (filter) this.filter = filter;
    await this.toggle(true);
  }

  /** `search:<query>`, `saved` or `sources:<source>`: for screenshots and the UI test. */
  async stage(spec: string): Promise<void> {
    const [tab, arg = ""] = spec.split(/:(.*)/s);
    await this.show(tab as Tab);
    if (tab === "search") await this.search(arg);
    if (tab === "sources") { this.openSource = arg || null; this.renderBody(); }
  }

  private async refresh(reindex = false): Promise<void> {
    const r = await lib().state(reindex);
    if ("ok" in r) this.state = r.ok;
    else this.host.flash(r.error, true);
    this.render();
  }

  private name(id: string): string {
    return id === "mine" ? "Saved parts" : this.state?.sources.find((s) => s.id === id)?.name ?? id;
  }

  private saved(key: string): boolean {
    return !!this.state?.items.some((i) => i.key === key);
  }

  async search(q: string): Promise<void> {
    this.query = q;
    const seq = ++this.seq;
    if (!q.trim()) { this.hits = []; this.render(); return; }
    this.searching = true;
    this.renderBody();
    const r = await lib().search(q);
    if (seq !== this.seq) return;
    this.searching = false;
    this.hits = "ok" in r ? r.ok : [{ source: "mine", items: [], error: r.error }];
    this.renderBody();
  }

  private render(): void {
    const head = el("div", "fhead", `${icon("library", 15)}<span>LIBRARIES</span><span class="grow"></span>`);
    head.append(button("", icon("close", 13), "Close", () => void this.toggle(false)));
    const tabs = el("div", "lib-tabs segmented");
    for (const [t, label] of [["search", "Search"], ["saved", `Saved${this.state ? ` ${this.state.items.length}` : ""}`], ["sources", "Sources"]] as const) {
      tabs.append(button(this.tab === t ? "on" : "", esc(label), label, () => { this.tab = t; this.render(); }));
    }
    this.el.replaceChildren(head, tabs, el("div", "lib-body"));
    this.renderBody();
  }

  private renderBody(): void {
    const body = this.el.querySelector(".lib-body");
    if (!body) return;
    body.replaceChildren(...(this.tab === "search" ? this.searchView() : this.tab === "saved" ? this.savedView() : this.sourcesView()));
  }

  // MARK: Search

  private searchBox(placeholder: string, value: string, onInput: (v: string) => void): HTMLElement {
    const box = el("div", "lib-search", icon("search", 14));
    const input = el("input");
    input.placeholder = placeholder;
    input.value = value;
    input.spellcheck = false;
    let t = 0;
    input.oninput = () => { clearTimeout(t); t = window.setTimeout(() => onInput(input.value), 250); };
    input.onkeydown = (e) => { if (e.key === "Enter") { clearTimeout(t); onInput(input.value); } };
    box.append(input);
    return box;
  }

  private filters(): HTMLElement {
    const f = el("div", "lib-filter segmented");
    for (const [id, label] of [["all", "All"], ["electronics", "Electronics"], ["mechanical", "Mechanical"]] as const) {
      f.append(button(this.filter === id ? "on" : "", label, `Show ${label.toLowerCase()} parts`, () => { this.filter = id; this.renderBody(); }));
    }
    return f;
  }

  private shown(i: LibraryItem): boolean {
    return this.filter === "all" || i.domain === "both" || i.domain === this.filter;
  }

  private searchView(): HTMLElement[] {
    const out: HTMLElement[] = [this.searchBox("Part, value, M3x12, 608, LM358…", this.query, (v) => void this.search(v)), this.filters()];
    if (this.searching) return [...out, el("div", "lib-empty", "Searching…")];
    if (!this.query.trim()) {
      const ready = this.state?.sources.filter((s) => s.enabled && s.ready && s.access !== "manual").map((s) => s.name) ?? [];
      return [...out, el("div", "lib-empty", `Searches ${esc(ready.join(", ") || "your saved parts")} and your saved parts. Shops without an API open on their own site from the Sources tab.`)];
    }
    for (const h of this.hits) {
      const items = h.items.filter((i) => this.shown(i));
      if (!items.length && !h.error) continue;
      const total = h.total && h.total > items.length ? ` of ${h.total}` : "";
      out.push(el("div", "dp-sec", `${esc(this.name(h.source).toUpperCase())} <span class="n">${items.length}${total}</span>`));
      if (h.error) out.push(el("div", "lib-error", esc(h.error)));
      out.push(...items.map((i) => this.row(i)));
    }
    // The shops without an API: their own search page, in the browser.
    const manual = this.state?.sources.filter((s) => s.enabled && s.searchUrl && (s.access === "manual" || !s.ready) && this.shownSource(s)) ?? [];
    if (manual.length) {
      out.push(el("div", "dp-sec", "SEARCH ON THE SHOP'S SITE"));
      const links = el("div", "lib-links");
      for (const s of manual) links.append(button("lib-chip", `${esc(s.name)} ${icon("export", 11)}`, `Open the search on ${s.name} in the browser`, () => void lib().openSearch(s.id, this.query)));
      out.push(links);
    }
    if (out.length === 2) out.push(el("div", "lib-empty", "Nothing found."));
    return out;
  }

  private shownSource(s: SourceStatus): boolean {
    return this.filter === "all" || s.domain === "both" || s.domain === this.filter;
  }

  /** What this item can do here: the first is the main button. */
  private actions(i: LibraryItem): { label: string; use: Use }[] {
    const ws = this.host.workspace();
    const out: { label: string; use: Use }[] = [];
    for (const u of i.uses ?? []) {
      if (ws === "design" && u.kind === "hardware") out.push({ label: "Insert", use: u });
      if (ws === "design" && u.kind === "step") out.push({ label: "Insert 3D model", use: u });
      if (ws === "electronics" && u.kind === "kicad-symbol") out.push({ label: "Place", use: u });
      if (ws === "electronics" && u.kind === "kicad-footprint") out.push({ label: "Assign footprint", use: u });
      if (ws === "electronics" && u.kind === "schematic") out.push({ label: "Place", use: u });
    }
    if (ws === "electronics" && !out.some((a) => a.label === "Place") && i.domain !== "mechanical") {
      const part = guessPart(i);
      if (part) out.push({ label: `Place as ${part}`, use: { kind: "schematic", part, value: i.mpn ?? i.name } });
    }
    return out;
  }

  private row(i: LibraryItem): HTMLElement {
    const r = el("div", "lib-row");
    const meta = [i.partNumber !== i.name ? i.partNumber : "", i.manufacturer].filter(Boolean).join(" · ");
    const stock = i.stock != null ? `${i.stock.toLocaleString()} in stock` : "";
    const price = money(i);
    r.append(el("div", "lib-main", `
      <div class="t">${esc(i.name)}</div>
      ${meta ? `<div class="m">${esc(meta)}</div>` : ""}
      ${i.description ? `<div class="d">${esc(i.description)}</div>` : ""}
      ${price || stock ? `<div class="p">${esc([price, stock].filter(Boolean).join(" · "))}</div>` : ""}
      ${i.files?.length ? `<div class="f">${esc(i.files.map((f) => f.label).join(" · "))}</div>` : ""}`));
    const bar = el("div", "lib-actions");
    const acts = this.actions(i);
    acts.forEach((a, n) => bar.append(button(n === 0 ? "btn primary" : "btn", esc(a.label), a.label, () => void this.run(i, a.use))));
    const saved = this.saved(i.key);
    bar.append(button(`ic${saved ? " on" : ""}`, icon(saved ? "check" : "plus", 14), saved ? "Saved in your library" : "Save in your library", () => void this.save(i)));
    if (i.url) bar.append(button("ic", icon("export", 14), "Open the product page", () => void lib().open(i.url!)));
    if (i.datasheet) bar.append(button("ic", icon("file", 14), "Open the datasheet", () => void lib().open(i.datasheet!)));
    r.append(bar);
    return r;
  }

  private async run(i: LibraryItem, u: Use): Promise<void> {
    const err = await this.host.use(i, u);
    this.host.flash(err ?? `${i.name}: done`, !!err);
  }

  private async save(i: LibraryItem): Promise<void> {
    const r = await lib().save(i);
    if ("error" in r) return this.host.flash(r.error, true);
    this.host.flash(`${i.name} saved in your library`);
    await this.refresh();
  }

  // MARK: Saved parts

  private savedView(): HTMLElement[] {
    const items = this.state?.items ?? [];
    const out: HTMLElement[] = [];
    const add = button("btn primary lib-add", `${icon("plus", 13)} Add a part by hand`, "Part number, link and notes from any shop", () => { this.adding = !this.adding; this.renderBody(); });
    out.push(add);
    if (this.adding) out.push(this.addForm());
    out.push(this.filters());
    if (!items.length) out.push(el("div", "lib-empty", "Nothing saved yet. Save parts from a search, or add one by hand: a McMaster or MISUMI part number, its link, and the CAD file you downloaded."));
    for (const i of items.filter((x) => this.shown(x))) {
      const r = this.row(i);
      const bar = r.querySelector(".lib-actions")!;
      bar.querySelector(".ic")?.remove(); // the save toggle: everything here is saved
      bar.prepend(el("span", "lib-src", esc(this.name(i.source))));
      bar.append(
        button("ic", icon("import", 14), "Attach a CAD or library file (.step, .kicad_mod, .kicad_sym)", () => void this.attach(i)),
        button("ic", icon("delete", 14), "Remove from your library", () => void this.remove(i)),
      );
      if (i.notes) r.querySelector(".lib-main")!.append(el("div", "d", esc(i.notes)));
      out.push(r);
    }
    return out;
  }

  private addForm(): HTMLElement {
    const f = el("form", "lib-form");
    const manual = this.state?.sources.filter((s) => s.access !== "local") ?? [];
    f.innerHTML = `
      <label class="drow"><span>Paste a link</span><input name="paste" placeholder="Amazon, AliExpress, eBay, McMaster… product page" /></label>
      <label class="drow"><span>Source</span><select name="source">${manual.map((s) => `<option value="${s.id}">${esc(s.name)}</option>`).join("")}</select></label>
      <label class="drow"><span>Part number</span><input name="partNumber" required placeholder="91290A115" /></label>
      <label class="drow"><span>Name</span><input name="name" placeholder="M3x10 socket head screw" /></label>
      <label class="drow"><span>Link</span><input name="url" type="url" placeholder="https://…" /></label>
      <label class="drow"><span>Kind</span><select name="domain"><option value="mechanical">Mechanical</option><option value="electronics">Electronics</option></select></label>
      <label class="drow"><span>Notes</span><input name="notes" placeholder="Material, finish, supplier…" /></label>
      <div class="lib-hint">Download the CAD model from the shop yourself, then attach it to the saved part.</div>`;
    const go = el("button", "btn primary", "Save");
    go.type = "submit";
    f.append(go);
    const sel = f.querySelector<HTMLSelectElement>("select[name=source]")!;
    sel.onchange = () => {
      const s = manual.find((x) => x.id === sel.value);
      if (s && s.domain !== "both") f.querySelector<HTMLSelectElement>("select[name=domain]")!.value = s.domain;
    };
    // A pasted product link fills the source, the part number (ASIN, item number) and the link.
    const paste = f.querySelector<HTMLInputElement>("input[name=paste]")!;
    paste.onchange = async () => {
      const r = await lib().fromLink(paste.value);
      if ("error" in r || !r.ok) return this.host.flash("Not a web link", true);
      const it = r.ok;
      const set = (n: string, v?: string) => { const x = f.querySelector<HTMLInputElement | HTMLSelectElement>(`[name=${n}]`); if (x && v != null && v !== "") x.value = v; };
      set("source", it.source);
      set("partNumber", it.partNumber);
      set("url", it.url);
      set("name", it.name);
      set("notes", it.notes);
      if (it.domain !== "both") set("domain", it.domain);
      if (it.savedAt) this.host.flash(`${it.name} is already in your library`);
      (f.querySelector<HTMLInputElement>(it.partNumber ? "input[name=name]" : "input[name=partNumber]"))!.focus();
    };
    f.onsubmit = async (e) => {
      e.preventDefault();
      const d = new FormData(f);
      const v = (k: string) => String(d.get(k) ?? "").trim();
      const item: LibraryItem = {
        key: "", source: v("source"), partNumber: v("partNumber"), name: v("name") || v("partNumber"),
        domain: v("domain") as LibraryItem["domain"], url: v("url") || undefined, notes: v("notes") || undefined,
      };
      const r = await lib().save(item);
      if ("error" in r) return this.host.flash(r.error, true);
      this.adding = false;
      await this.refresh();
    };
    return f;
  }

  private async attach(i: LibraryItem): Promise<void> {
    const r = await lib().attach(i.key);
    if ("error" in r) return this.host.flash(r.error, true);
    if (r.ok) await this.refresh();
  }

  private async remove(i: LibraryItem): Promise<void> {
    if (!confirm(`Remove ${i.name} from your library? Files attached to it are deleted from the library folder.`)) return;
    const r = await lib().remove(i.key);
    if ("error" in r) return this.host.flash(r.error, true);
    await this.refresh();
  }

  // MARK: Sources

  private sourcesView(): HTMLElement[] {
    const out: HTMLElement[] = [el("div", "lib-hint pad", "Keys stay in this computer's keychain, never in a project file or a Git repository. Shops without an open API are never scraped: save their parts by hand.")];
    for (const group of [["local", "ON THIS COMPUTER"], ["api", "SHOP APIS"], ["manual", "BY HAND"]] as const) {
      out.push(el("div", "dp-sec", group[1]));
      for (const s of this.state?.sources.filter((x) => x.access === group[0]) ?? []) out.push(this.sourceCard(s));
    }
    return out;
  }

  private sourceCard(s: SourceStatus): HTMLElement {
    const c = el("div", `lib-source${this.openSource === s.id ? " open" : ""}`);
    const status = s.planned ? "To study" : s.access === "manual" ? "By hand" : s.ready ? "Ready" : s.access === "api" ? "Needs keys" : "Not found";
    const head = el("div", "lib-shead", `<span class="dot ${s.ready && !s.planned ? "ok" : ""}"></span><span class="t">${esc(s.name)}</span><span class="st">${status}</span>`);
    const toggle = el("input");
    toggle.type = "checkbox";
    toggle.checked = s.enabled;
    toggle.title = s.enabled ? "In searches" : "Left out of searches";
    toggle.onclick = (e) => e.stopPropagation();
    toggle.onchange = async () => { await lib().enable(s.id, toggle.checked); await this.refresh(); };
    head.append(toggle);
    head.onclick = () => { this.openSource = this.openSource === s.id ? null : s.id; this.renderBody(); };
    c.append(head);
    if (this.openSource !== s.id) return c;
    const body = el("div", "lib-sbody", `<p>${esc(s.summary)}</p>${s.detail ? `<p class="m">${esc(s.detail)}</p>` : ""}${(s.caveats ?? []).map((x) => `<p class="warn">${esc(x)}</p>`).join("")}`);
    if (s.keys) body.append(this.keysForm(s));
    if (s.id === "kicad") body.append(this.kicadRoots());
    const links = el("div", "lib-links");
    if (s.signup) links.append(button("lib-chip", `Account ${icon("export", 11)}`, s.signup, () => void lib().open(s.signup!)));
    if (s.terms) links.append(button("lib-chip", `Terms ${icon("export", 11)}`, s.terms, () => void lib().open(s.terms!)));
    if (s.searchUrl && !s.searchUrl.includes("mcmaster.com/{q}")) links.append(button("lib-chip", `Website ${icon("export", 11)}`, "Open the shop", () => void lib().open(new URL(s.searchUrl!.replace("{q}", "")).origin)));
    if (links.childElementCount) body.append(links);
    c.append(body);
    return c;
  }

  private keysForm(s: SourceStatus): HTMLElement {
    const f = el("form", "lib-form");
    for (const k of s.keys ?? []) {
      const row = el("label", "drow", `<span>${esc(k.label)}</span>`);
      const input = el("input");
      input.name = k.id;
      input.autocomplete = "off";
      input.type = k.optional ? "text" : "password";
      input.placeholder = s.ready ? `Saved; type to replace${k.placeholder ? ` (${k.placeholder})` : ""}` : k.placeholder ?? (k.optional ? "Optional" : "");
      row.append(input);
      f.append(row);
    }
    const bar = el("div", "lib-links");
    const save = el("button", "btn primary", "Save keys");
    save.type = "submit";
    bar.append(save);
    if (s.ready) bar.append(button("btn", "Forget keys", "Remove the keys from the keychain", () => void this.setKeys(s, {})));
    f.append(bar);
    f.onsubmit = (e) => {
      e.preventDefault();
      const keys = Object.fromEntries([...new FormData(f).entries()].map(([k, v]) => [k, String(v)]));
      if (Object.values(keys).every((v) => !v.trim())) return;
      void this.setKeys(s, keys);
    };
    return f;
  }

  private async setKeys(s: SourceStatus, keys: Record<string, string>): Promise<void> {
    const r = await lib().keys(s.id, keys);
    if ("error" in r) return this.host.flash(r.error, true);
    this.host.flash(Object.keys(keys).length ? `${s.name}: keys saved in the keychain` : `${s.name}: keys forgotten`);
    await this.refresh();
  }

  private kicadRoots(): HTMLElement {
    const box = el("div", "lib-roots");
    for (const root of this.state?.kicadRoots ?? []) {
      const r = el("div", "lib-root", `<span title="${esc(root)}">${esc(root)}</span>`);
      r.append(button("ic", icon("close", 12), "Stop using this folder", async () => { await lib().removeRoot(root); await this.refresh(true); }));
      box.append(r);
    }
    const bar = el("div", "lib-links");
    bar.append(
      button("btn", "Add a library folder…", "A folder of .kicad_sym files, .pretty or .3dshapes folders", async () => { const r = await lib().addRoot(); if ("ok" in r && r.ok) await this.refresh(true); }),
      button("btn", "Rescan", "Read the libraries again", () => void this.refresh(true)),
    );
    box.append(bar);
    return box;
  }
}
