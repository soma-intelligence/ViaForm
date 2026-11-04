import { createHash, createHmac } from "node:crypto";
import type { LibraryItem } from "../../shared/library/types";
import type { Fetch, Keys } from "./distributors";

// General marketplaces through their official APIs, for the tools, modules, motors and supplies
// that distributors do not carry. Each needs an account the user opens and its terms accepted:
// Amazon through the Product Advertising API (an Associates account), AliExpress through its
// affiliate API, eBay through the Browse API. None of them is scraped.

const TIMEOUT = 15_000;

async function call(f: Fetch, url: string, init: RequestInit, who: string): Promise<any> {
  const r = await f(url, { ...init, signal: AbortSignal.timeout(TIMEOUT) });
  const text = await r.text();
  let j: any = {};
  try { j = text ? JSON.parse(text) : {}; } catch { /* not JSON */ }
  if (!r.ok) {
    const detail = j.Errors?.[0]?.Message ?? j.errors?.[0]?.message ?? j.error_description ?? j.message ?? text.slice(0, 200);
    throw new Error(`${who}: ${r.status} ${detail}`.trim());
  }
  return j;
}

const need = (keys: Keys, ids: string[], who: string) => {
  const missing = ids.filter((k) => !keys[k]);
  if (missing.length) throw new Error(`${who}: enter ${missing.join(", ")} in the source settings`);
};

// MARK: Amazon, Product Advertising API 5 (SearchItems), signed with AWS Signature Version 4

const hex = (b: Buffer | string) => createHash("sha256").update(b).digest("hex");
const hmac = (key: Buffer | string, data: string) => createHmac("sha256", key).update(data).digest();

/** The SigV4 headers of one POST: `x-amz-date` and `Authorization`. `now` is passed for the tests. */
export function sigv4(o: { host: string; path: string; body: string; target: string; access: string; secret: string; region: string; service: string; now?: Date }): Record<string, string> {
  const amzDate = (o.now ?? new Date()).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
  const day = amzDate.slice(0, 8);
  const headers: Record<string, string> = {
    "content-encoding": "amz-1.0",
    "content-type": "application/json; charset=utf-8",
    host: o.host,
    "x-amz-date": amzDate,
    "x-amz-target": o.target,
  };
  const names = Object.keys(headers).sort();
  const canonical = ["POST", o.path, "", ...names.map((n) => `${n}:${headers[n]}`), "", names.join(";"), hex(o.body)].join("\n");
  const scope = `${day}/${o.region}/${o.service}/aws4_request`;
  const toSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(canonical)].join("\n");
  const key = hmac(hmac(hmac(hmac(`AWS4${o.secret}`, day), o.region), o.service), "aws4_request");
  const signature = createHmac("sha256", key).update(toSign).digest("hex");
  return { ...headers, Authorization: `AWS4-HMAC-SHA256 Credential=${o.access}/${scope}, SignedHeaders=${names.join(";")}, Signature=${signature}` };
}

/** The PA-API host and region of each marketplace the user may pick. */
const AMAZON: Record<string, { host: string; region: string }> = {
  "www.amazon.com": { host: "webservices.amazon.com", region: "us-east-1" },
  "www.amazon.ca": { host: "webservices.amazon.ca", region: "us-east-1" },
  "www.amazon.co.uk": { host: "webservices.amazon.co.uk", region: "eu-west-1" },
  "www.amazon.fr": { host: "webservices.amazon.fr", region: "eu-west-1" },
  "www.amazon.de": { host: "webservices.amazon.de", region: "eu-west-1" },
  "www.amazon.co.jp": { host: "webservices.amazon.co.jp", region: "us-west-2" },
};

export async function amazon(f: Fetch, keys: Keys, q: string, limit = 10): Promise<{ items: LibraryItem[]; total: number }> {
  need(keys, ["accessKey", "secretKey", "partnerTag"], "Amazon");
  const marketplace = AMAZON[keys.marketplace] ? keys.marketplace : "www.amazon.com";
  const { host, region } = AMAZON[marketplace];
  const body = JSON.stringify({
    Keywords: q,
    PartnerTag: keys.partnerTag,
    PartnerType: "Associates",
    Marketplace: marketplace,
    ItemCount: Math.min(limit, 10),
    Resources: ["ItemInfo.Title", "ItemInfo.ByLineInfo", "ItemInfo.Classifications", "Offers.Listings.Price", "Offers.Listings.Availability.Message"],
  });
  const headers = sigv4({ host, path: "/paapi5/searchitems", body, target: "com.amazon.paapi5.v1.ProductAdvertisingAPIv1.SearchItems", access: keys.accessKey, secret: keys.secretKey, region, service: "ProductAdvertisingAPI" });
  const j = await call(f, `https://${host}/paapi5/searchitems`, { method: "POST", headers, body }, "Amazon");
  if (j.Errors?.length && !j.SearchResult) throw new Error(`Amazon: ${j.Errors[0].Message}`);
  return { items: (j.SearchResult?.Items ?? []).map(amazonItem), total: j.SearchResult?.TotalResultCount ?? 0 };
}

export function amazonItem(p: any): LibraryItem {
  const offer = p.Offers?.Listings?.[0];
  return {
    key: `amazon:${p.ASIN}`,
    source: "amazon",
    partNumber: p.ASIN,
    name: p.ItemInfo?.Title?.DisplayValue ?? p.ASIN,
    manufacturer: p.ItemInfo?.ByLineInfo?.Brand?.DisplayValue ?? p.ItemInfo?.ByLineInfo?.Manufacturer?.DisplayValue,
    category: p.ItemInfo?.Classifications?.ProductGroup?.DisplayValue,
    description: offer?.Availability?.Message,
    domain: "both",
    url: p.DetailPageURL,
    prices: offer?.Price ? [{ quantity: 1, price: offer.Price.Amount, currency: offer.Price.Currency }] : undefined,
    fetchedAt: new Date().toISOString(),
  };
}

// MARK: AliExpress, affiliate API (aliexpress.affiliate.product.query), signed with HMAC-SHA256

/** The Open Platform signature: HMAC-SHA256 of the sorted name+value pairs, upper-case hex. */
export function aliSign(params: Record<string, string>, secret: string): string {
  const text = Object.keys(params).sort().map((k) => k + params[k]).join("");
  return createHmac("sha256", secret).update(text).digest("hex").toUpperCase();
}

export async function aliexpress(f: Fetch, keys: Keys, q: string, limit = 20): Promise<{ items: LibraryItem[]; total: number }> {
  need(keys, ["appKey", "appSecret"], "AliExpress");
  const params: Record<string, string> = {
    method: "aliexpress.affiliate.product.query",
    app_key: keys.appKey,
    sign_method: "sha256",
    timestamp: String(Date.now()),
    format: "json",
    v: "2.0",
    keywords: q,
    page_size: String(Math.min(limit, 50)),
    target_currency: keys.currency || "USD",
    target_language: "EN",
    ...(keys.trackingId ? { tracking_id: keys.trackingId } : {}),
  };
  params.sign = aliSign(params, keys.appSecret);
  const j = await call(f, "https://api-sg.aliexpress.com/sync", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded;charset=utf-8" },
    body: new URLSearchParams(params),
  }, "AliExpress");
  if (j.error_response) throw new Error(`AliExpress: ${j.error_response.msg ?? j.error_response.code}`);
  const r = j.aliexpress_affiliate_product_query_response?.resp_result;
  if (r && r.resp_code !== 200 && r.resp_code !== undefined) throw new Error(`AliExpress: ${r.resp_msg ?? r.resp_code}`);
  const products = r?.result?.products?.product ?? [];
  return { items: products.map(aliItem), total: r?.result?.total_record_count ?? products.length };
}

export function aliItem(p: any): LibraryItem {
  const price = Number(p.target_sale_price ?? p.sale_price);
  return {
    key: `aliexpress:${p.product_id}`,
    source: "aliexpress",
    partNumber: String(p.product_id),
    name: p.product_title ?? String(p.product_id),
    category: p.second_level_category_name ?? p.first_level_category_name,
    description: p.shop_name ? `Shop: ${p.shop_name}` : undefined,
    domain: "both",
    url: p.promotion_link ?? p.product_detail_url,
    prices: Number.isFinite(price) ? [{ quantity: 1, price, currency: p.target_sale_price_currency ?? p.sale_price_currency ?? "USD" }] : undefined,
    fetchedAt: new Date().toISOString(),
  };
}

// MARK: eBay, Browse API (item_summary/search), application token

let ebayToken: { id: string; token: string; until: number } | null = null;

export async function ebay(f: Fetch, keys: Keys, q: string, limit = 20): Promise<{ items: LibraryItem[]; total: number }> {
  need(keys, ["clientId", "clientSecret"], "eBay");
  if (!ebayToken || ebayToken.id !== keys.clientId || ebayToken.until < Date.now()) {
    const t = await call(f, "https://api.ebay.com/identity/v1/oauth2/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded", Authorization: `Basic ${Buffer.from(`${keys.clientId}:${keys.clientSecret}`).toString("base64")}` },
      body: new URLSearchParams({ grant_type: "client_credentials", scope: "https://api.ebay.com/oauth/api_scope" }),
    }, "eBay");
    ebayToken = { id: keys.clientId, token: t.access_token, until: Date.now() + (Number(t.expires_in ?? 3600) - 60) * 1000 };
  }
  const url = `https://api.ebay.com/buy/browse/v1/item_summary/search?q=${encodeURIComponent(q)}&limit=${Math.min(limit, 50)}`;
  const j = await call(f, url, { headers: { Authorization: `Bearer ${ebayToken.token}`, "X-EBAY-C-MARKETPLACE-ID": keys.marketplace || "EBAY_US" } }, "eBay");
  return { items: (j.itemSummaries ?? []).map(ebayItem), total: j.total ?? 0 };
}

export function ebayItem(p: any): LibraryItem {
  const price = Number(p.price?.value);
  return {
    key: `ebay:${p.itemId}`,
    source: "ebay",
    partNumber: p.legacyItemId ?? p.itemId,
    name: p.title ?? p.itemId,
    category: p.categories?.[0]?.categoryName,
    description: [p.condition, p.seller?.username ? `Seller: ${p.seller.username}` : ""].filter(Boolean).join(" · ") || undefined,
    domain: "both",
    url: p.itemWebUrl,
    prices: Number.isFinite(price) ? [{ quantity: 1, price, currency: p.price.currency }] : undefined,
    fetchedAt: new Date().toISOString(),
  };
}

export function forgetMarketTokens(): void {
  ebayToken = null;
}

/**
 * The shop and its own product number in a product link the user pastes: nothing is fetched, the
 * link is only read. Amazon ASIN, AliExpress and Alibaba item numbers, eBay item, McMaster part
 * number, DigiKey and Mouser pages, Temu goods id.
 */
export function fromLink(raw: string): { source: string; partNumber: string; url: string } | null {
  let u: URL;
  try { u = new URL(raw.trim()); } catch { return null; }
  if (u.protocol !== "https:" && u.protocol !== "http:") return null;
  const h = u.hostname.replace(/^www\./, "").toLowerCase(), p = decodeURIComponent(u.pathname);
  const m = (re: RegExp) => re.exec(p)?.[1];
  const clean = `${u.origin}${u.pathname}`;
  let source: string | null = null, partNumber: string | undefined;
  if (/(^|\.)amazon\.[a-z.]+$/.test(h) || h === "a.co" || h === "amzn.to") { source = "amazon"; partNumber = m(/\/(?:dp|gp\/product|gp\/aw\/d|product)\/([A-Z0-9]{10})/i)?.toUpperCase(); }
  else if (/(^|\.)aliexpress\.[a-z.]+$/.test(h)) { source = "aliexpress"; partNumber = m(/\/item\/(\d+)\.html/); }
  else if (/(^|\.)alibaba\.com$/.test(h)) { source = "alibaba"; partNumber = m(/_(\d{6,})\.html/) ?? m(/\/(\d{6,})\.html/); }
  else if (/(^|\.)ebay\.[a-z.]+$/.test(h)) { source = "ebay"; partNumber = m(/\/itm\/(?:[^/]+\/)?(\d{9,})/); }
  else if (/(^|\.)temu\.com$/.test(h)) { source = "temu"; partNumber = m(/-g-(\d+)\.html/) ?? u.searchParams.get("goods_id") ?? undefined; }
  else if (h === "mcmaster.com") { source = "mcmaster"; partNumber = m(/^\/([0-9]{4,5}[A-Z][0-9]{1,4})/i)?.toUpperCase(); }
  else if (/(^|\.)digikey\.[a-z.]+$/.test(h)) { source = "digikey"; partNumber = m(/\/detail\/[^/]+\/([^/]+)\//); }
  else if (/(^|\.)mouser\.[a-z.]+$/.test(h)) { source = "mouser"; partNumber = m(/\/ProductDetail\/(?:[^/]+\/)?([^/?]+)/); }
  else if (/(^|\.)misumi-ec\.com$/.test(h)) { source = "misumi"; partNumber = m(/\/detail\/([^/]+)/); }
  else if (/(^|\.)lcsc\.com$/.test(h)) { source = "lcsc"; partNumber = m(/(C\d{3,})/); }
  if (!source) return { source: "custom", partNumber: "", url: clean };
  return { source, partNumber: partNumber ?? "", url: source === "amazon" && partNumber ? `${u.origin}/dp/${partNumber}` : clean };
}

export const MARKETPLACES: Record<string, (f: Fetch, keys: Keys, q: string, limit?: number) => Promise<{ items: LibraryItem[]; total: number }>> = { amazon, aliexpress, ebay };
