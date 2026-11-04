// Side libraries: light catalogues of parts kept beside the project, never inside it. A source is
// one place parts come from (the KiCad libraries on this machine, the engine's standard hardware,
// a distributor's official API, or a shop the user copies part numbers from by hand). An item is
// one part found there or saved in the user's own library.

/** What a source can do. `api` sources answer searches; `manual` ones only take entries typed in. */
export type SourceAccess = "local" | "api" | "manual";

/** Electronics (symbols, footprints, distributors), mechanics (hardware, CAD models) or both. */
export type Domain = "electronics" | "mechanical" | "both";

export interface SourceInfo {
  id: string;
  name: string;
  domain: Domain;
  access: SourceAccess;
  /** One or two sentences: what it gives and on what terms. */
  summary: string;
  /** The keys a user enters for an `api` source, stored in the OS keychain. */
  keys?: { id: string; label: string; optional?: boolean; placeholder?: string }[];
  /** Where the user creates an account or reads the terms. */
  signup?: string;
  terms?: string;
  /** A search page on the shop's own site, `{q}` for the query: opened in the browser, never fetched. */
  searchUrl?: string;
  /** Points the user should check themselves before relying on the source. */
  caveats?: string[];
  /** Listed for later: not wired yet. */
  planned?: boolean;
}

export interface SourceStatus extends SourceInfo {
  enabled: boolean;
  /** For `api` sources: every key is in the keychain. For local ones: something was found. */
  ready: boolean;
  detail?: string;
}

export interface PriceBreak {
  quantity: number;
  price: number;
  currency: string;
}

/** What the app can do with an item, beyond keeping it. */
export type Use =
  | { kind: "kicad-symbol"; path: string; symbol: string; footprint?: string }
  | { kind: "kicad-footprint"; path: string }
  | { kind: "step"; path: string }
  | { kind: "hardware"; family: string; size: string; length?: number }
  | { kind: "schematic"; part: string; value: string };

export interface LibraryItem {
  /** Unique within the user's library: `<source>:<part number>`. */
  key: string;
  source: string;
  /** The source's own part number (DigiKey, Mouser or McMaster number, KiCad symbol name...). */
  partNumber: string;
  name: string;
  description?: string;
  manufacturer?: string;
  mpn?: string;
  category?: string;
  domain: Domain;
  url?: string;
  datasheet?: string;
  stock?: number;
  prices?: PriceBreak[];
  /** CAD files the user attached (copied into the library folder), or found locally. */
  files?: { label: string; path: string }[];
  uses?: Use[];
  notes?: string;
  tags?: string[];
  /** When the item was saved, or when its price and stock were read. */
  savedAt?: string;
  fetchedAt?: string;
}

export interface SearchHit {
  source: string;
  items: LibraryItem[];
  total?: number;
  error?: string;
}

export interface LibraryState {
  sources: SourceStatus[];
  items: LibraryItem[];
  kicadRoots: string[];
}
