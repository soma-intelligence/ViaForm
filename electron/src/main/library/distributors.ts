import type { LibraryItem, PriceBreak } from "../../shared/library/types";

// The distributors' official APIs. Each search is one or two HTTPS calls from the main process
// with the user's own keys; the answers are mapped to library items and nothing else is kept.
// `fetch` is passed in so the tests can answer for the distributors.

export type Fetch = typeof fetch;
export type Keys = Record<string, string>;

const TIMEOUT = 15_000;

async function json(f: Fetch, url: string, init: RequestInit, who: string): Promise<any> {
  const r = await f(url, { ...init, signal: AbortSignal.timeout(TIMEOUT) });
  const text = await r.text();
  if (!r.ok) {
    let detail = text.slice(0, 200);
    try {
      const j = JSON.parse(text);
      detail = j.detail ?? j.error_description ?? j.ErrorMessage ?? j.Errors?.[0]?.Message ?? j.message ?? detail;
    } catch { /* not JSON */ }
    throw new Error(`${who}: ${r.status} ${detail}`.trim());
  }
  return text ? JSON.parse(text) : {};
}

const num = (v: unknown): number | undefined => {
  const x = typeof v === "number" ? v : typeof v === "string" ? Number(v.replace(/[^0-9.]/g, "")) : NaN;
  return Number.isFinite(x) ? x : undefined;
};

/** One OAuth token per client, kept until a minute before it expires. */
const tokens = new Map<string, { token: string; until: number }>();

async function clientToken(f: Fetch, url: string, keys: Keys, who: string, scope?: string): Promise<string> {
  const id = keys.clientId, secret = keys.clientSecret;
  if (!id || !secret) throw new Error(`${who}: enter the client ID and secret in the source settings`);
  const cached = tokens.get(`${url}|${id}`);
  if (cached && cached.until > Date.now()) return cached.token;
  const body = new URLSearchParams({ client_id: id, client_secret: secret, grant_type: "client_credentials", ...(scope ? { scope } : {}) });
  const j = await json(f, url, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body }, who);
  if (!j.access_token) throw new Error(`${who}: no access token in the answer`);
  tokens.set(`${url}|${id}`, { token: j.access_token, until: Date.now() + (Number(j.expires_in ?? 600) - 60) * 1000 });
  return j.access_token;
}

export function forgetTokens(): void {
  tokens.clear();
}

// MARK: DigiKey, Product Information API v4 (keyword search)

export async function digikey(f: Fetch, keys: Keys, q: string, limit = 20): Promise<{ items: LibraryItem[]; total: number }> {
  const token = await clientToken(f, "https://api.digikey.com/v1/oauth2/token", keys, "DigiKey");
  const j = await json(f, "https://api.digikey.com/products/v4/search/keyword", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
      "X-DIGIKEY-Client-Id": keys.clientId,
      "X-DIGIKEY-Locale-Site": "US",
      "X-DIGIKEY-Locale-Language": "en",
      "X-DIGIKEY-Locale-Currency": "USD",
    },
    body: JSON.stringify({ Keywords: q, Limit: Math.min(limit, 50), Offset: 0 }),
  }, "DigiKey");
  return { items: (j.Products ?? []).map(digikeyItem), total: j.ProductsCount ?? 0 };
}

export function digikeyItem(p: any): LibraryItem {
  const v = p.ProductVariations?.[0];
  const dk = v?.DigiKeyProductNumber ?? p.DigiKeyProductNumber ?? p.ManufacturerProductNumber;
  const prices: PriceBreak[] = (v?.StandardPricing ?? p.StandardPricing ?? []).map((b: any) => ({ quantity: b.BreakQuantity, price: b.UnitPrice, currency: "USD" }));
  if (!prices.length && p.UnitPrice) prices.push({ quantity: 1, price: p.UnitPrice, currency: "USD" });
  return {
    key: `digikey:${dk}`,
    source: "digikey",
    partNumber: dk,
    name: p.ManufacturerProductNumber ?? dk,
    description: p.Description?.ProductDescription ?? p.Description?.DetailedDescription,
    manufacturer: p.Manufacturer?.Name,
    mpn: p.ManufacturerProductNumber,
    category: p.Category?.Name,
    domain: "electronics",
    url: p.ProductUrl,
    datasheet: p.DatasheetUrl || undefined,
    stock: num(p.QuantityAvailable),
    prices,
    fetchedAt: new Date().toISOString(),
  };
}

// MARK: Mouser, Search API v1 (keyword search)

export async function mouser(f: Fetch, keys: Keys, q: string, limit = 20): Promise<{ items: LibraryItem[]; total: number }> {
  if (!keys.apiKey) throw new Error("Mouser: enter the Search API key in the source settings");
  const j = await json(f, `https://api.mouser.com/api/v1/search/keyword?apiKey=${encodeURIComponent(keys.apiKey)}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ SearchByKeywordRequest: { keyword: q, records: Math.min(limit, 50), startingRecord: 0, searchOptions: "", searchWithYourSignUpLanguage: "" } }),
  }, "Mouser");
  if (j.Errors?.length) throw new Error(`Mouser: ${j.Errors.map((e: any) => e.Message).join("; ")}`);
  return { items: (j.SearchResults?.Parts ?? []).map(mouserItem), total: j.SearchResults?.NumberOfResult ?? 0 };
}

export function mouserItem(p: any): LibraryItem {
  const n = p.MouserPartNumber || p.ManufacturerPartNumber;
  return {
    key: `mouser:${n}`,
    source: "mouser",
    partNumber: n,
    name: p.ManufacturerPartNumber ?? n,
    description: p.Description,
    manufacturer: p.Manufacturer,
    mpn: p.ManufacturerPartNumber,
    category: p.Category,
    domain: "electronics",
    url: p.ProductDetailUrl,
    datasheet: p.DataSheetUrl || undefined,
    stock: num(p.AvailabilityInStock ?? p.Availability),
    prices: (p.PriceBreaks ?? []).map((b: any) => ({ quantity: b.Quantity, price: num(b.Price) ?? 0, currency: b.Currency ?? "USD" })),
    fetchedAt: new Date().toISOString(),
  };
}

// MARK: Octopart through Nexar, Supply GraphQL API

const NEXAR_QUERY = `query Search($q: String!, $limit: Int!) {
  supSearch(q: $q, limit: $limit) {
    hits
    results { part {
      mpn name shortDescription octopartUrl totalAvail
      manufacturer { name }
      category { name }
      bestDatasheet { url }
      sellers(authorizedOnly: true) { company { name } offers { sku inventoryLevel clickUrl prices { quantity price currency } } }
    } }
  }
}`;

export async function nexar(f: Fetch, keys: Keys, q: string, limit = 20): Promise<{ items: LibraryItem[]; total: number }> {
  const token = await clientToken(f, "https://identity.nexar.com/connect/token", keys, "Nexar", "supply.domain");
  const j = await json(f, "https://api.nexar.com/graphql", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify({ query: NEXAR_QUERY, variables: { q, limit: Math.min(limit, 20) } }),
  }, "Nexar");
  if (j.errors?.length) throw new Error(`Nexar: ${j.errors.map((e: any) => e.message).join("; ")}`);
  const s = j.data?.supSearch;
  return { items: (s?.results ?? []).map((r: any) => nexarItem(r.part)), total: s?.hits ?? 0 };
}

export function nexarItem(p: any): LibraryItem {
  // The cheapest single-unit offer among authorized sellers gives the price breaks shown.
  let best: { seller: string; prices: PriceBreak[] } | null = null;
  for (const s of p.sellers ?? []) for (const o of s.offers ?? []) {
    const prices: PriceBreak[] = (o.prices ?? []).filter((x: any) => x.currency === "USD").map((x: any) => ({ quantity: x.quantity, price: x.price, currency: x.currency }));
    if (prices.length && (!best || prices[0].price < best.prices[0].price)) best = { seller: s.company?.name, prices };
  }
  const mfr = p.manufacturer?.name;
  return {
    key: `nexar:${mfr ?? ""}:${p.mpn}`,
    source: "nexar",
    partNumber: p.mpn,
    name: p.mpn,
    description: p.shortDescription ?? p.name,
    manufacturer: mfr,
    mpn: p.mpn,
    category: p.category?.name,
    domain: "electronics",
    url: p.octopartUrl,
    datasheet: p.bestDatasheet?.url,
    stock: num(p.totalAvail),
    prices: best?.prices,
    notes: best?.seller ? `Prices from ${best.seller}` : undefined,
    fetchedAt: new Date().toISOString(),
  };
}

export const DISTRIBUTORS: Record<string, (f: Fetch, keys: Keys, q: string, limit?: number) => Promise<{ items: LibraryItem[]; total: number }>> = { digikey, mouser, nexar };
