// The side libraries without Electron: KiCad indexing and placement through the addon, standard
// hardware from the engine's tables, the distributors' answers mapped to items (with a stand-in
// for the network), and the user's library with its encrypted keys.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as kicad from "../main/library/kicad";
import * as hardware from "../main/library/hardware";
import { digikeyItem, mouserItem, nexarItem, type Fetch } from "../main/library/distributors";
import { Library } from "../main/library/service";
import { Secrets, Store, type Cipher } from "../main/library/store";
import { SOURCES, searchPage } from "../shared/library/sources";

// eslint-disable-next-line @typescript-eslint/no-require-imports
const native = require(path.join(__dirname, "..", "..", "native", "viaform.node"));
const FIXTURES = path.join(__dirname, "..", "..", "..", "engines", "pcbcraft", "crates", "library", "tests", "fixtures");

/** A KiCad install in miniature: symbols/, footprints/Resistor_SMD.pretty, 3dmodels/Resistor_SMD.3dshapes. */
function fakeKicad(): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "viaform-kicad-"));
  fs.mkdirSync(path.join(root, "symbols"));
  const device = fs.readFileSync(path.join(FIXTURES, "device.kicad_sym"), "utf8").replace('(property "Footprint" ""', '(property "Footprint" "Resistor_SMD:R_0805_2012Metric"');
  fs.writeFileSync(path.join(root, "symbols", "Device.kicad_sym"), device);
  fs.copyFileSync(path.join(FIXTURES, "lm358.kicad_sym"), path.join(root, "symbols", "Amplifier_Operational.kicad_sym"));
  fs.mkdirSync(path.join(root, "footprints", "Resistor_SMD.pretty"), { recursive: true });
  fs.copyFileSync(path.join(FIXTURES, "R_0805_2012Metric.kicad_mod"), path.join(root, "footprints", "Resistor_SMD.pretty", "R_0805_2012Metric.kicad_mod"));
  fs.mkdirSync(path.join(root, "3dmodels", "Resistor_SMD.3dshapes"), { recursive: true });
  fs.writeFileSync(path.join(root, "3dmodels", "Resistor_SMD.3dshapes", "R_0805_2012Metric.step"), "ISO-10303-21;");
  return root;
}

const plainCipher: Cipher = { available: () => true, encrypt: (t) => Buffer.from(t.split("").reverse().join("")), decrypt: (b) => b.toString().split("").reverse().join("") };

test("a KiCad symbol library is read for its top-level symbols only", () => {
  const syms = kicad.readSymbols(fs.readFileSync(path.join(FIXTURES, "device.kicad_sym"), "utf8"), "Device", "x");
  assert.deepEqual(syms.map((s) => s.name), ["R", "LED"]);
  assert.equal(syms[0].description, "Resistor");
  assert.equal(syms[0].keywords, "R res resistor");
  const lm = kicad.readSymbols(fs.readFileSync(path.join(FIXTURES, "lm358.kicad_sym"), "utf8"), "Amp", "y");
  assert.equal(lm[0].datasheet, "http://www.ti.com/lit/ds/symlink/lm358.pdf");
});

test("KiCad search finds symbols with their footprint and 3D model, and they place on the board", () => {
  const root = fakeKicad();
  const ix = kicad.buildIndex([root]);
  assert.deepEqual(ix.symbols.map((s) => s.name).sort(), ["LED", "LM2904", "LM358", "R"]);
  const r = kicad.search(ix, "resistor");
  const item = r.items[0];
  assert.equal(item.name, "R");
  const use = item.uses!.find((u) => u.kind === "kicad-symbol");
  assert.ok(use && use.kind === "kicad-symbol" && use.footprint?.endsWith("R_0805_2012Metric.kicad_mod"));
  assert.ok(item.uses!.some((u) => u.kind === "step"));
  assert.equal(kicad.search(ix, "dual opamp").items[0].name, "LM2904");
  assert.equal(kicad.search(ix, "0805").items[0].uses![0].kind, "kicad-footprint");

  // What the library panel does with it: place the symbol, then give it its footprint.
  const w = new native.Workspace(false);
  const placed = w.pcb("component.place_library", { path: use.path, symbol: use.symbol, position: { x: 0, y: 0 }, reference: "R1", value: "10k" }).result;
  w.pcb("footprint.assign", { id: placed.id, path: use.footprint });
  w.pcb("board.sync");
  const p = w.pcbInspect().project;
  assert.equal(p.components[0].value, "10k");
  assert.equal(p.board.footprints.length, 1);
  assert.equal(p.board.footprints[0].pads.length, 2);
});

test("standard hardware comes from the engine's tables and inserts as a part", () => {
  const w = new native.Workspace(false);
  const families = w.cad("parts.library", {}).families as hardware.Family[];
  assert.ok(families.length >= 10);
  const shcs = hardware.search(families, "socket M3x12");
  assert.equal(shcs.items[0].name, "Socket head cap screw M3x12");
  assert.deepEqual(shcs.items[0].uses, [{ kind: "hardware", family: "socket_head_cap_screw", size: "M3", length: 12 }]);
  assert.equal(hardware.search(families, "bearing 608").items[0].partNumber.endsWith("608"), true);
  assert.ok(hardware.search(families, "nut M5").items.some((i) => i.name === "Hex nut M5"));
  assert.equal(hardware.search(families, "screw M3 999").total, 0, "a length outside the table matches nothing");
  const u = shcs.items[0].uses![0];
  assert.ok(u.kind === "hardware");
  w.cad("parts.insert", { family: u.family, size: u.size, length: u.length });
  assert.equal(w.scene().meshes.length, 1);
});

test("distributor answers become items with prices, stock and links", () => {
  const dk = digikeyItem({
    ManufacturerProductNumber: "RC0805FR-0710KL", Manufacturer: { Name: "YAGEO" }, Description: { ProductDescription: "RES 10K OHM 1% 1/8W 0805" },
    ProductUrl: "https://www.digikey.com/x", DatasheetUrl: "https://ds", QuantityAvailable: 1234567, Category: { Name: "Resistors" },
    ProductVariations: [{ DigiKeyProductNumber: "311-10.0KCRCT-ND", StandardPricing: [{ BreakQuantity: 1, UnitPrice: 0.1 }, { BreakQuantity: 10, UnitPrice: 0.019 }] }],
  });
  assert.equal(dk.key, "digikey:311-10.0KCRCT-ND");
  assert.equal(dk.prices![1].price, 0.019);
  assert.equal(dk.stock, 1234567);
  const mo = mouserItem({ MouserPartNumber: "603-RC0805FR-0710KL", ManufacturerPartNumber: "RC0805FR-0710KL", Manufacturer: "YAGEO", AvailabilityInStock: "500000", PriceBreaks: [{ Quantity: 1, Price: "$0.10", Currency: "USD" }] });
  assert.equal(mo.prices![0].price, 0.1);
  assert.equal(mo.stock, 500000);
  const nx = nexarItem({ mpn: "LM358", manufacturer: { name: "TI" }, totalAvail: 99, sellers: [
    { company: { name: "A" }, offers: [{ prices: [{ quantity: 1, price: 0.5, currency: "USD" }] }] },
    { company: { name: "B" }, offers: [{ prices: [{ quantity: 1, price: 0.3, currency: "USD" }] }] },
  ] });
  assert.equal(nx.prices![0].price, 0.3);
  assert.equal(nx.notes, "Prices from B");
});

test("the library searches every ready source, keeps keys encrypted and files attached", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "viaform-lib-"));
  const calls: string[] = [];
  const fakeFetch: Fetch = async (url, init) => {
    calls.push(String(url));
    const body = String(url).includes("oauth2/token")
      ? { access_token: "t", expires_in: 600 }
      : { Products: [{ ManufacturerProductNumber: "LM358DR", ProductVariations: [{ DigiKeyProductNumber: "296-1014-1-ND", StandardPricing: [] }] }], ProductsCount: 1 };
    assert.ok(init?.signal, "every call has a timeout");
    return new Response(JSON.stringify(body), { status: 200 });
  };
  const store = new Store(dir);
  const secrets = new Secrets(path.join(dir, "secrets.bin"), plainCipher);
  const families = new native.Workspace(false).cad("parts.library", {}).families;
  const lib = new Library({ store, secrets, fetch: fakeFetch, families: () => families, kicadDefaults: [fakeKicad()] });

  // No keys: DigiKey is not asked.
  let hits = await lib.search("LM358");
  assert.ok(!hits.some((h) => h.source === "digikey"));
  assert.equal(hits.find((h) => h.source === "kicad")!.items.length > 0, true);

  lib.setKeys("digikey", { clientId: "id", clientSecret: "secret", stray: "dropped" });
  assert.ok(!fs.readFileSync(path.join(dir, "secrets.bin"), "utf8").includes("secret"), "keys are not stored in plain text");
  assert.deepEqual(secrets.get("digikey"), { clientId: "id", clientSecret: "secret" });
  hits = await lib.search("LM358");
  assert.equal(hits.find((h) => h.source === "digikey")!.items[0].partNumber, "296-1014-1-ND");
  assert.ok(calls.some((c) => c.startsWith("https://api.digikey.com/")));

  // A McMaster part typed in by hand, with the STEP the user downloaded attached to it.
  const saved = lib.save({ key: "", source: "mcmaster", partNumber: "91290A115", name: "M3x10 socket head screw", domain: "mechanical", url: "https://www.mcmaster.com/91290A115/" });
  assert.equal(saved.key, "mcmaster:91290A115");
  const step = path.join(dir, "download.step");
  fs.writeFileSync(step, "ISO-10303-21;");
  const withFile = lib.attach(saved.key, step);
  assert.ok(withFile.uses!.some((u) => u.kind === "step" && store.owns(u.path)));
  assert.throws(() => lib.save({ key: "", source: "mcmaster", partNumber: "1", name: "x", domain: "mechanical", url: "javascript:alert(1)" }), /http/);

  // Saved again from a search, it keeps its attached file; a fresh store reads it all back.
  lib.save({ ...saved, notes: undefined });
  const again = new Store(dir);
  assert.equal(again.item("mcmaster:91290A115")!.files!.length, 1);
  hits = await lib.search("91290A115");
  assert.equal(hits.find((h) => h.source === "mine")!.items.length, 1);

  lib.setEnabled("kicad", false);
  hits = await lib.search("LM358");
  assert.ok(!hits.some((h) => h.source === "kicad"));

  const copy = withFile.files![0].path;
  lib.remove(saved.key);
  assert.ok(!fs.existsSync(copy), "the copy in the library folder goes with the item");
  assert.ok(fs.existsSync(step), "the user's own file stays");
});

test("every source says what it is and links only to web pages", () => {
  const ids = new Set<string>();
  for (const s of SOURCES) {
    assert.ok(!ids.has(s.id), `duplicate ${s.id}`);
    ids.add(s.id);
    for (const u of [s.signup, s.terms, s.searchUrl]) if (u) assert.match(u, /^https:\/\//);
    if (s.access === "api") assert.ok(s.keys?.length, `${s.id} names its keys`);
  }
  for (const id of ["digikey", "mcmaster", "kicad", "standard", "mouser", "misumi", "robotshop", "adafruit", "sparkfun"]) assert.ok(ids.has(id), id);
  assert.equal(searchPage("mcmaster", "91290A115"), "https://www.mcmaster.com/91290A115");
  assert.equal(searchPage("digikey", "10k 0805"), "https://www.digikey.com/en/products/result?keywords=10k%200805");
});

test("marketplaces: signed requests, answers as items, product links read without fetching", async () => {
  const { sigv4, amazon, aliexpress, aliSign, ebay, fromLink } = await import("../main/library/marketplaces");
  // SigV4: the scope, the signed headers and a 64-digit signature, stable for one instant.
  const now = new Date("2026-11-04T12:00:00Z");
  const o = { host: "webservices.amazon.com", path: "/paapi5/searchitems", body: "{}", target: "t", access: "AK", secret: "SK", region: "us-east-1", service: "ProductAdvertisingAPI", now };
  const h = sigv4(o);
  assert.equal(h["x-amz-date"], "20261104T120000Z");
  assert.match(h.Authorization, /^AWS4-HMAC-SHA256 Credential=AK\/20261104\/us-east-1\/ProductAdvertisingAPI\/aws4_request, SignedHeaders=content-encoding;content-type;host;x-amz-date;x-amz-target, Signature=[0-9a-f]{64}$/);
  assert.equal(sigv4(o).Authorization, h.Authorization);
  assert.notEqual(sigv4({ ...o, body: "{ }" }).Authorization, h.Authorization);
  assert.equal(aliSign({ b: "2", a: "1" }, "s"), aliSign({ a: "1", b: "2" }, "s"));

  const seen: { url: string; init?: RequestInit }[] = [];
  const answer = (url: string): unknown => {
    if (url.includes("paapi5")) return { SearchResult: { TotalResultCount: 1, Items: [{ ASIN: "B07XYZ1234", DetailPageURL: "https://www.amazon.com/dp/B07XYZ1234", ItemInfo: { Title: { DisplayValue: "Digital caliper 150 mm" }, ByLineInfo: { Brand: { DisplayValue: "Acme" } } }, Offers: { Listings: [{ Price: { Amount: 19.99, Currency: "USD" } }] } }] } };
    if (url.includes("aliexpress")) return { aliexpress_affiliate_product_query_response: { resp_result: { resp_code: 200, result: { total_record_count: 1, products: { product: [{ product_id: 1005001, product_title: "MG90S servo", target_sale_price: "2.15", target_sale_price_currency: "USD", promotion_link: "https://s.click.aliexpress.com/x" }] } } } } };
    if (url.includes("oauth2/token")) return { access_token: "e", expires_in: 7200 };
    return { total: 1, itemSummaries: [{ itemId: "v1|1234567890|0", legacyItemId: "1234567890", title: "Hakko soldering station", price: { value: "89.00", currency: "USD" }, itemWebUrl: "https://www.ebay.com/itm/1234567890", condition: "New" }] };
  };
  const f: Fetch = async (url, init) => { seen.push({ url: String(url), init }); return new Response(JSON.stringify(answer(String(url))), { status: 200 }); };

  const a = await amazon(f, { accessKey: "AK", secretKey: "SK", partnerTag: "me-20", marketplace: "www.amazon.fr" }, "caliper");
  assert.equal(a.items[0].key, "amazon:B07XYZ1234");
  assert.equal(a.items[0].prices![0].price, 19.99);
  assert.equal(seen[0].url, "https://webservices.amazon.fr/paapi5/searchitems");
  assert.match(String((seen[0].init!.headers as Record<string, string>).Authorization), /eu-west-1/);
  await assert.rejects(amazon(f, { accessKey: "AK" }, "x"), /secretKey, partnerTag/);

  const ali = await aliexpress(f, { appKey: "k", appSecret: "s" }, "servo");
  assert.equal(ali.items[0].name, "MG90S servo");
  assert.equal(ali.items[0].prices![0].price, 2.15);
  const sent = new URLSearchParams(String(seen.at(-1)!.init!.body));
  const { sign, ...rest } = Object.fromEntries(sent);
  assert.equal(sign, aliSign(rest, "s"), "the request carries its own signature");

  const e = await ebay(f, { clientId: "c", clientSecret: "s" }, "soldering station");
  assert.equal(e.items[0].partNumber, "1234567890");
  assert.equal(e.items[0].prices![0].price, 89);

  assert.deepEqual(fromLink("https://www.amazon.fr/Pied-coulisse-num%C3%A9rique/dp/B07XYZ1234/ref=sr_1_3?tag=x"), { source: "amazon", partNumber: "B07XYZ1234", url: "https://www.amazon.fr/dp/B07XYZ1234" });
  assert.equal(fromLink("https://www.aliexpress.com/item/1005004321.html?spm=a2g0o")!.partNumber, "1005004321");
  assert.equal(fromLink("https://www.alibaba.com/product-detail/CNC-Aluminum-Part_1600123456789.html")!.partNumber, "1600123456789");
  assert.equal(fromLink("https://www.ebay.com/itm/1234567890")!.source, "ebay");
  assert.equal(fromLink("https://www.mcmaster.com/91290A115/")!.partNumber, "91290A115");
  assert.equal(fromLink("https://www.temu.com/goods-g-601099512345678.html")!.partNumber, "601099512345678");
  assert.equal(fromLink("https://example.com/thing")!.source, "custom");
  assert.equal(fromLink("javascript:alert(1)"), null);
});
