import * as fs from "node:fs";
import * as path from "node:path";
import { readSymbols } from "./kicad";
import type { LibraryItem, Use } from "../../shared/library/types";

// The user's own library, on this machine only (the app's data folder, outside every project and
// every Git repository): saved items in library.json, attached CAD files under files/, and the
// settings of the sources. API keys are not here: see Secrets.

export interface Settings {
  disabled: string[];
  kicadRoots: string[];
}

interface Saved { version: 1; items: LibraryItem[]; settings: Settings }

/** Encrypts and decrypts the API keys; the app backs it with the OS keychain (Electron safeStorage). */
export interface Cipher {
  available(): boolean;
  encrypt(text: string): Buffer;
  decrypt(data: Buffer): string;
}

export class Store {
  private data: Saved;

  constructor(readonly dir: string) {
    fs.mkdirSync(path.join(dir, "files"), { recursive: true });
    this.data = { version: 1, items: [], settings: { disabled: [], kicadRoots: [] } };
    try {
      const j = JSON.parse(fs.readFileSync(this.file, "utf8")) as Partial<Saved>;
      this.data.items = Array.isArray(j.items) ? j.items : [];
      this.data.settings = { ...this.data.settings, ...j.settings };
    } catch { /* first run */ }
  }

  private get file(): string { return path.join(this.dir, "library.json"); }

  private write(): void {
    const tmp = `${this.file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(this.data, null, 2));
    fs.renameSync(tmp, this.file);
  }

  get items(): LibraryItem[] { return this.data.items; }
  get settings(): Settings { return this.data.settings; }

  item(key: string): LibraryItem | undefined { return this.data.items.find((i) => i.key === key); }

  /** Saves or replaces an item; a manual entry without a key gets one from its source and part number. */
  save(item: LibraryItem): LibraryItem {
    const it: LibraryItem = { ...item, key: item.key || `${item.source}:${item.partNumber}`, savedAt: new Date().toISOString() };
    if (!it.partNumber?.trim()) throw new Error("a part number is required");
    if (it.url && !/^https?:\/\//.test(it.url)) throw new Error("the link must start with http:// or https://");
    const i = this.data.items.findIndex((x) => x.key === it.key);
    // Files attached earlier stay attached when the item is saved again from a search.
    if (i >= 0) {
      const old = this.data.items[i];
      it.files = mergeFiles(old.files, it.files);
      it.uses = mergeUses(old.uses, it.uses);
      it.notes ??= old.notes;
      this.data.items[i] = it;
    } else this.data.items.unshift(it);
    this.write();
    return it;
  }

  remove(key: string): void {
    const it = this.item(key);
    this.data.items = this.data.items.filter((x) => x.key !== key);
    // Only the copies in our own files/ folder are deleted, never a file elsewhere on the disk.
    for (const f of it?.files ?? []) if (this.owns(f.path)) fs.rmSync(f.path, { force: true });
    this.write();
  }

  owns(p: string): boolean {
    const rel = path.relative(path.join(this.dir, "files"), p);
    return !!rel && !rel.startsWith("..") && !path.isAbsolute(rel);
  }

  /** Copies `src` into files/ and attaches it to the item; a STEP file can then go into the design. */
  attach(key: string, src: string): LibraryItem {
    const it = this.item(key);
    if (!it) throw new Error("save the item before attaching files");
    const ext = path.extname(src).toLowerCase();
    const safe = `${key.replace(/[^\w.-]+/g, "_")}-${path.basename(src).replace(/[^\w.-]+/g, "_")}`;
    const dest = path.join(this.dir, "files", safe);
    fs.copyFileSync(src, dest);
    it.files = mergeFiles(it.files, [{ label: path.basename(src), path: dest }]);
    if (ext === ".step" || ext === ".stp") it.uses = mergeUses(it.uses, [{ kind: "step", path: dest }]);
    else if (ext === ".kicad_mod") it.uses = mergeUses(it.uses, [{ kind: "kicad-footprint", path: dest }]);
    else if (ext === ".kicad_sym") {
      // A symbol downloaded for this part (SnapMagic, a maker's site): its first symbol is placed,
      // with the footprint attached earlier if there is one.
      const sym = readSymbols(fs.readFileSync(dest, "utf8"), path.basename(src, ext), dest)[0];
      if (!sym) throw new Error("no symbol in this file");
      const fp = it.uses?.find((u): u is Extract<Use, { kind: "kicad-footprint" }> => u.kind === "kicad-footprint")?.path;
      it.uses = mergeUses([{ kind: "kicad-symbol", path: dest, symbol: sym.name, ...(fp ? { footprint: fp } : {}) }], it.uses);
    }
    this.write();
    return it;
  }

  setSettings(s: Partial<Settings>): void {
    this.data.settings = { ...this.data.settings, ...s };
    this.write();
  }
}

function mergeFiles(a: LibraryItem["files"] = [], b: LibraryItem["files"] = []): LibraryItem["files"] {
  const out = [...a];
  for (const f of b) if (!out.some((x) => x.path === f.path)) out.push(f);
  return out.length ? out : undefined;
}

function mergeUses(a: LibraryItem["uses"] = [], b: LibraryItem["uses"] = []): LibraryItem["uses"] {
  const out = [...a];
  for (const u of b) if (!out.some((x) => JSON.stringify(x) === JSON.stringify(u))) out.push(u);
  return out.length ? out : undefined;
}

/**
 * API keys, encrypted by the OS keychain and kept in secrets.bin beside the library. Without a
 * keychain (some Linux sessions) nothing is stored: the user is told instead of a plain-text file.
 */
export class Secrets {
  private cache: Record<string, Record<string, string>> | null = null;

  constructor(private readonly file: string, private readonly cipher: Cipher) {}

  private load(): Record<string, Record<string, string>> {
    if (this.cache) return this.cache;
    try {
      this.cache = JSON.parse(this.cipher.decrypt(fs.readFileSync(this.file)));
    } catch {
      this.cache = {};
    }
    return this.cache!;
  }

  get(source: string): Record<string, string> {
    return { ...this.load()[source] };
  }

  has(source: string, ids: string[]): boolean {
    const k = this.load()[source] ?? {};
    return ids.every((id) => !!k[id]);
  }

  set(source: string, keys: Record<string, string>): void {
    if (!this.cipher.available()) throw new Error("No OS keychain to encrypt the keys with: they are not saved.");
    const all = this.load();
    const clean = Object.fromEntries(Object.entries(keys).map(([k, v]) => [k, v.trim()]).filter(([, v]) => v));
    if (Object.keys(clean).length) all[source] = clean;
    else delete all[source];
    fs.writeFileSync(this.file, this.cipher.encrypt(JSON.stringify(all)), { mode: 0o600 });
  }
}
