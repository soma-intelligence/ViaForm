import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { LibraryItem, Use } from "../../shared/library/types";

// The KiCad libraries on this machine, indexed by reading the files directly: a symbol library is
// scanned for its top-level symbols and their description, keywords and footprint, a .pretty
// folder for its footprints, a .3dshapes folder for its STEP models. Only the part the user places
// is parsed in full, by the PCB engine (`component.place_library`, `footprint.assign`).

export interface SymbolEntry { lib: string; name: string; description: string; keywords: string; footprint: string; datasheet: string; path: string }
export interface FootprintEntry { lib: string; name: string; path: string }
export interface KicadIndex {
  roots: string[];
  symbolFiles: string[];
  footprintLibs: string[];
  modelLibs: string[];
  symbols: SymbolEntry[];
  footprints: FootprintEntry[];
}

/** Where KiCad installs its libraries on each platform, and the folders its variables point to. */
export function defaultRoots(env: NodeJS.ProcessEnv = process.env, platform = process.platform): string[] {
  const roots: string[] = [];
  if (platform === "darwin") roots.push("/Applications/KiCad/KiCad.app/Contents/SharedSupport", path.join(os.homedir(), "Library/Application Support/kicad"));
  else if (platform === "win32") for (const v of ["10.0", "9.0", "8.0"]) roots.push(`C:/Program Files/KiCad/${v}/share/kicad`);
  else roots.push("/usr/share/kicad", "/usr/local/share/kicad", path.join(os.homedir(), ".local/share/kicad"), "/var/lib/flatpak/app/org.kicad.KiCad/current/active/files/share/kicad");
  for (const v of ["10", "9", "8"]) for (const k of ["SYMBOL_DIR", "FOOTPRINT_DIR", "3DMODEL_DIR"]) {
    const p = env[`KICAD${v}_${k}`];
    if (p) roots.push(p);
  }
  return [...new Set(roots)];
}

const isDir = (p: string) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } };
const list = (p: string) => { try { return fs.readdirSync(p); } catch { return []; } };

/** The library files and folders under `roots`: each root, its symbols/, footprints/ and 3dmodels/. */
export function scan(roots: string[]): Pick<KicadIndex, "symbolFiles" | "footprintLibs" | "modelLibs"> {
  const symbolFiles = new Set<string>(), footprintLibs = new Set<string>(), modelLibs = new Set<string>();
  for (const root of roots) {
    if (!isDir(root)) continue;
    for (const dir of [root, path.join(root, "symbols"), path.join(root, "footprints"), path.join(root, "3dmodels")]) {
      for (const f of list(dir)) {
        const p = path.join(dir, f);
        if (f.endsWith(".kicad_sym")) symbolFiles.add(p);
        else if (f.endsWith(".pretty") && isDir(p)) footprintLibs.add(p);
        else if (f.endsWith(".3dshapes") && isDir(p)) modelLibs.add(p);
      }
    }
  }
  const sort = (s: Set<string>) => [...s].sort((a, b) => path.basename(a).localeCompare(path.basename(b)));
  return { symbolFiles: sort(symbolFiles), footprintLibs: sort(footprintLibs), modelLibs: sort(modelLibs) };
}

/**
 * The top-level symbols of a .kicad_sym text with their properties. A small reader of
 * S-expressions: it follows the depth and the quoted strings, and keeps the symbols one level
 * under `kicad_symbol_lib` (the units, `R_0_1` and the like, sit deeper and are skipped).
 */
export function readSymbols(text: string, lib: string, file: string): SymbolEntry[] {
  const out: SymbolEntry[] = [];
  let depth = 0, i = 0, current: SymbolEntry | null = null;
  const n = text.length;
  const readString = (): string => {
    let s = "";
    i++;
    while (i < n && text[i] !== '"') {
      if (text[i] === "\\" && i + 1 < n) { s += text[++i]; i++; continue; }
      s += text[i++];
    }
    i++;
    return s;
  };
  const skipSpace = () => { while (i < n && /\s/.test(text[i])) i++; };
  const readAtom = (): string => {
    skipSpace();
    if (text[i] === '"') return readString();
    const start = i;
    while (i < n && !/[\s()]/.test(text[i])) i++;
    return text.slice(start, i);
  };
  while (i < n) {
    const c = text[i];
    if (c === '"') { readString(); continue; }
    if (c === ")") { depth--; if (depth === 1 && current) { out.push(current); current = null; } i++; continue; }
    if (c !== "(") { i++; continue; }
    i++;
    depth++;
    const head = readAtom();
    if (head === "symbol" && depth === 2) {
      current = { lib, name: readAtom(), description: "", keywords: "", footprint: "", datasheet: "", path: file };
    } else if (head === "property" && depth === 3 && current) {
      const key = readAtom(), value = readAtom();
      if (key === "Description" || key === "ki_description") current.description ||= value;
      else if (key === "ki_keywords") current.keywords = value;
      else if (key === "Footprint") current.footprint = value;
      else if (key === "Datasheet" && value !== "~") current.datasheet = value;
    }
  }
  return out;
}

interface Cached { mtime: number; symbols: SymbolEntry[] }
const symbolCache = new Map<string, Cached>();

/** Builds the index of `roots`, rereading only the symbol files that changed since the last call. */
export function buildIndex(roots: string[]): KicadIndex {
  const found = scan(roots);
  const symbols: SymbolEntry[] = [];
  for (const file of found.symbolFiles) {
    let mtime = 0;
    try { mtime = fs.statSync(file).mtimeMs; } catch { continue; }
    let c = symbolCache.get(file);
    if (!c || c.mtime !== mtime) {
      try {
        c = { mtime, symbols: readSymbols(fs.readFileSync(file, "utf8"), path.basename(file, ".kicad_sym"), file) };
      } catch {
        c = { mtime, symbols: [] };
      }
      symbolCache.set(file, c);
    }
    symbols.push(...c.symbols);
  }
  const footprints: FootprintEntry[] = [];
  for (const dir of found.footprintLibs) {
    const lib = path.basename(dir, ".pretty");
    for (const f of list(dir)) if (f.endsWith(".kicad_mod")) footprints.push({ lib, name: f.slice(0, -10), path: path.join(dir, f) });
  }
  return { roots, ...found, symbols, footprints };
}

/** `Library:Name` to the footprint file, when that library is installed. */
export function footprintFile(index: KicadIndex, ref: string): string | undefined {
  const [lib, name] = ref.split(":");
  if (!lib || !name) return undefined;
  const dir = index.footprintLibs.find((d) => path.basename(d, ".pretty") === lib);
  const file = dir && path.join(dir, `${name}.kicad_mod`);
  return file && fs.existsSync(file) ? file : undefined;
}

/** The STEP model KiCad ships for a footprint (`<lib>.3dshapes/<name>.step`), when installed. */
export function modelFile(index: KicadIndex, lib: string, name: string): string | undefined {
  for (const dir of index.modelLibs) {
    if (path.basename(dir, ".3dshapes") !== lib) continue;
    for (const ext of [".step", ".stp"]) {
      const f = path.join(dir, name + ext);
      if (fs.existsSync(f)) return f;
    }
  }
  return undefined;
}

/** Every word of the query in the text, case-insensitive. */
function matches(words: string[], hay: string): boolean {
  const h = hay.toLowerCase();
  return words.every((w) => h.includes(w));
}

function rank(words: string[], name: string): number {
  const n = name.toLowerCase(), q = words.join(" ");
  return n === q ? 0 : n.startsWith(q) ? 1 : n.includes(q) ? 2 : 3;
}

export function search(index: KicadIndex, query: string, limit = 40): { items: LibraryItem[]; total: number } {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return { items: [], total: 0 };
  const syms = index.symbols.filter((s) => matches(words, `${s.lib} ${s.name} ${s.description} ${s.keywords}`));
  const fps = index.footprints.filter((f) => matches(words, `${f.lib} ${f.name}`));
  syms.sort((a, b) => rank(words, a.name) - rank(words, b.name) || a.name.localeCompare(b.name));
  fps.sort((a, b) => rank(words, a.name) - rank(words, b.name) || a.name.localeCompare(b.name));
  // Symbols first (what a schematic places), then footprints, half and half when both are many.
  const half = Math.ceil(limit / 2);
  const s = syms.slice(0, fps.length ? Math.max(half, limit - fps.length) : limit);
  const f = fps.slice(0, limit - s.length);
  return { items: [...s.map((x) => symbolItem(index, x)), ...f.map((x) => footprintItem(index, x))], total: syms.length + fps.length };
}

export function symbolItem(index: KicadIndex, s: SymbolEntry): LibraryItem {
  const fp = s.footprint ? footprintFile(index, s.footprint) : undefined;
  const use: Use = { kind: "kicad-symbol", path: s.path, symbol: s.name, ...(fp ? { footprint: fp } : {}) };
  const uses: Use[] = [use];
  const files = [{ label: "Symbol", path: s.path }];
  if (fp) {
    files.push({ label: `Footprint ${s.footprint}`, path: fp });
    const [lib, name] = s.footprint.split(":");
    const step = modelFile(index, lib, name);
    if (step) { uses.push({ kind: "step", path: step }); files.push({ label: "3D model", path: step }); }
  }
  return {
    key: `kicad:${s.lib}:${s.name}`,
    source: "kicad",
    partNumber: `${s.lib}:${s.name}`,
    name: s.name,
    description: s.description || undefined,
    category: s.lib,
    domain: "electronics",
    datasheet: /^https?:\/\//.test(s.datasheet) ? s.datasheet : undefined,
    files,
    uses,
    tags: s.keywords ? s.keywords.split(/\s+/) : undefined,
  };
}

export function footprintItem(index: KicadIndex, f: FootprintEntry): LibraryItem {
  const step = modelFile(index, f.lib, f.name);
  return {
    key: `kicad:${f.lib}:${f.name}`,
    source: "kicad",
    partNumber: `${f.lib}:${f.name}`,
    name: f.name,
    description: `Footprint, ${f.lib}`,
    category: f.lib,
    domain: "electronics",
    files: [{ label: "Footprint", path: f.path }, ...(step ? [{ label: "3D model", path: step }] : [])],
    uses: [{ kind: "kicad-footprint", path: f.path }, ...(step ? [{ kind: "step" as const, path: step }] : [])],
  };
}
