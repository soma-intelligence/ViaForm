import { DISTRIBUTORS, forgetTokens, type Fetch } from "./distributors";
import { MARKETPLACES, forgetMarketTokens, fromLink } from "./marketplaces";
import * as hardware from "./hardware";
import * as kicad from "./kicad";
import { SOURCES, source } from "../../shared/library/sources";
import { Secrets, Store } from "./store";
import type { LibraryItem, LibraryState, SearchHit, SourceStatus } from "../../shared/library/types";

// The side libraries as one service, independent of Electron so the tests drive it directly:
// searches fan out to every enabled source that can answer, each source answering on its own.

export interface Deps {
  store: Store;
  secrets: Secrets;
  fetch: Fetch;
  /** The engine's standard part families (`parts.library` with no family). */
  families: () => hardware.Family[];
  /** KiCad roots found by default on this machine; the user's own folders are added to them. */
  kicadDefaults?: string[];
}

const required = (s: { keys?: { id: string; optional?: boolean }[] }) => (s.keys ?? []).filter((k) => !k.optional).map((k) => k.id);

export class Library {
  private index: kicad.KicadIndex | null = null;
  private families: hardware.Family[] | null = null;

  constructor(private readonly d: Deps) {}

  get kicadRoots(): string[] {
    return [...new Set([...(this.d.kicadDefaults ?? kicad.defaultRoots()), ...this.d.store.settings.kicadRoots])];
  }

  kicad(refresh = false): kicad.KicadIndex {
    if (!this.index || refresh) this.index = kicad.buildIndex(this.kicadRoots);
    return this.index;
  }

  private hardware(): hardware.Family[] {
    this.families ??= this.d.families();
    return this.families;
  }

  enabled(id: string): boolean {
    return !this.d.store.settings.disabled.includes(id);
  }

  status(): SourceStatus[] {
    return SOURCES.map((s) => {
      const enabled = this.enabled(s.id);
      if (s.id === "kicad") {
        const ix = enabled ? this.kicad() : this.index;
        const detail = ix ? `${ix.symbolFiles.length} symbol libraries (${ix.symbols.length} symbols), ${ix.footprintLibs.length} footprint libraries, ${ix.modelLibs.length} 3D model folders` : "Not indexed yet";
        return { ...s, enabled, ready: !!ix && (ix.symbols.length > 0 || ix.footprints.length > 0), detail };
      }
      if (s.id === "standard") return { ...s, enabled, ready: true, detail: `${this.hardware().length} families` };
      if (s.access === "api") {
        const ready = this.d.secrets.has(s.id, required(s));
        return { ...s, enabled, ready, detail: ready ? "Keys in the keychain" : "No keys yet" };
      }
      const n = this.d.store.items.filter((i) => i.source === s.id).length;
      return { ...s, enabled, ready: true, detail: n ? `${n} saved` : undefined };
    });
  }

  state(): LibraryState {
    return { sources: this.status(), items: this.d.store.items, kicadRoots: this.d.store.settings.kicadRoots };
  }

  /** Searches every enabled source that answers searches, or only `only`. Saved items always match. */
  async search(q: string, only?: string[]): Promise<SearchHit[]> {
    const query = q.trim();
    if (!query) return [];
    const want = (id: string) => this.enabled(id) && (!only || only.includes(id));
    const jobs: Promise<SearchHit>[] = [];
    const run = (id: string, f: () => Promise<{ items: LibraryItem[]; total: number }> | { items: LibraryItem[]; total: number }) =>
      jobs.push(Promise.resolve().then(f).then((r) => ({ source: id, ...r }), (e: unknown) => ({ source: id, items: [], error: e instanceof Error ? e.message : String(e) })));
    if (want("mine")) run("mine", () => this.searchSaved(query));
    if (want("kicad")) run("kicad", () => kicad.search(this.kicad(), query));
    if (want("standard")) run("standard", () => hardware.search(this.hardware(), query));
    for (const s of SOURCES) {
      const api = DISTRIBUTORS[s.id] ?? MARKETPLACES[s.id];
      if (s.access !== "api" || !want(s.id) || !api) continue;
      if (!this.d.secrets.has(s.id, required(s))) continue;
      run(s.id, () => api(this.d.fetch, this.d.secrets.get(s.id), query));
    }
    return Promise.all(jobs);
  }

  private searchSaved(q: string): { items: LibraryItem[]; total: number } {
    const words = q.toLowerCase().split(/\s+/);
    const items = this.d.store.items.filter((i) => {
      const hay = [i.partNumber, i.name, i.description, i.manufacturer, i.mpn, i.category, i.notes, ...(i.tags ?? []), source(i.source)?.name].join(" ").toLowerCase();
      return words.every((w) => hay.includes(w));
    });
    return { items, total: items.length };
  }

  save(item: LibraryItem): LibraryItem {
    if (!source(item.source)) throw new Error(`unknown source ${item.source}`);
    return this.d.store.save(item);
  }

  remove(key: string): void { this.d.store.remove(key); }

  attach(key: string, file: string): LibraryItem { return this.d.store.attach(key, file); }

  setEnabled(id: string, on: boolean): void {
    const disabled = new Set(this.d.store.settings.disabled);
    if (on) disabled.delete(id); else disabled.add(id);
    this.d.store.setSettings({ disabled: [...disabled] });
  }

  setKeys(id: string, keys: Record<string, string>): void {
    const s = source(id);
    if (s?.access !== "api") throw new Error(`${id} takes no keys`);
    const allowed = new Set((s.keys ?? []).map((k) => k.id));
    // Fields left blank keep their saved value; no field at all forgets the source's keys.
    const typed = Object.fromEntries(Object.entries(keys).filter(([k, v]) => allowed.has(k) && v.trim()));
    this.d.secrets.set(id, Object.keys(keys).length ? { ...this.d.secrets.get(id), ...typed } : {});
    forgetTokens();
    forgetMarketTokens();
  }

  /** A pasted product link read for its shop and part number; a part already saved comes back whole. */
  fromLink(url: string): LibraryItem | null {
    const l = fromLink(url);
    if (!l) return null;
    const saved = l.partNumber ? this.d.store.item(`${l.source}:${l.partNumber}`) : undefined;
    return saved ?? { key: "", source: l.source, partNumber: l.partNumber, name: "", domain: source(l.source)?.domain ?? "both", url: l.url };
  }

  setKicadRoots(roots: string[]): void {
    this.d.store.setSettings({ kicadRoots: [...new Set(roots.filter(Boolean))] });
    this.index = null;
  }

  /** The footprint file of a KiCad `Library:Name` reference, for a symbol placed without one. */
  footprint(ref: string): string | undefined {
    return kicad.footprintFile(this.kicad(), ref);
  }
}
