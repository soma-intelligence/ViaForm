import type { LibraryItem } from "../../shared/library/types";

// Standard hardware from the design engine's tables (`parts.library`): each family and size is an
// item, inserted with `parts.insert`. Nothing is downloaded: the engine builds the solid.

export interface Family {
  family: string;
  name: string;
  standard: string;
  system: "metric" | "inch";
  sizes: { size: string; default_length?: number; [k: string]: unknown }[];
  lengths: number[] | null;
}

/** Search words that name the kind of part, beyond the engine's family names. */
const ALIASES: Record<string, string> = {
  socket_head_cap_screw: "screw bolt shcs cap socket allen vis",
  button_head_cap_screw: "screw bhcs button vis",
  hex_bolt: "screw bolt hex vis",
  hex_nut: "nut ecrou hex",
  washer: "washer rondelle",
  set_screw: "screw grub set vis",
  dowel_pin: "pin dowel goupille",
  bearing: "bearing roulement ball",
  hex_cap_screw_inch: "screw bolt hex inch imperial",
  hex_nut_inch: "nut hex inch imperial",
  washer_sae: "washer inch sae",
  washer_uss: "washer inch uss",
};

export function search(families: Family[], query: string, limit = 60): { items: LibraryItem[]; total: number } {
  const words = query.toLowerCase().replace(/[×*]/g, "x").split(/\s+/).filter(Boolean);
  // `M3x12` or `M3 12`: a size and a length. A bare number is a length, unless a size equals it (608).
  let length: number | undefined;
  const terms: string[] = [];
  for (const w of words) {
    const m = /^(m\d+(?:\.\d+)?)x(\d+(?:\.\d+)?)$/.exec(w);
    if (m) { terms.push(m[1]); length = Number(m[2]); }
    else terms.push(w);
  }
  const out: LibraryItem[] = [];
  let total = 0;
  for (const f of families) {
    const text = `${f.family.replace(/_/g, " ")} ${f.name} ${f.standard} ${ALIASES[f.family] ?? ""}`.toLowerCase();
    for (const s of f.sizes) {
      const size = s.size.toLowerCase();
      let len = length;
      const ok = terms.every((t) => {
        if (size === t) return true;
        if (/^\d+(\.\d+)?$/.test(t) && f.lengths) { len = Number(t); return true; }
        return text.includes(t);
      });
      if (!ok) continue;
      if (len != null && f.lengths && !f.lengths.includes(len)) continue;
      total++;
      if (out.length < limit) out.push(item(f, s.size, f.lengths ? len ?? s.default_length : undefined));
    }
  }
  return { items: out, total };
}

export function item(f: Family, size: string, length?: number): LibraryItem {
  const label = length != null ? `${size}${f.system === "inch" ? " x " : "x"}${length}` : size;
  return {
    key: `standard:${f.family}:${size}${length != null ? `:${length}` : ""}`,
    source: "standard",
    partNumber: `${f.standard} ${label}`,
    name: `${f.name} ${label}`,
    description: `${f.standard}${length != null ? `, length ${length} ${f.system === "inch" ? "in" : "mm"}` : ""}`,
    category: f.name,
    domain: "mechanical",
    uses: [{ kind: "hardware", family: f.family, size, ...(length != null ? { length } : {}) }],
  };
}
