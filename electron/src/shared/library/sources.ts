import type { SourceInfo } from "./types";

// Every source the library knows. The terms of each shop change: the caveats say what was not
// checked, and the app never scrapes a site. A shop without an open API is a `manual` source: the
// user copies the part number and the link, and downloads the CAD model from the shop themselves.

export const SOURCES: SourceInfo[] = [
  // Local, nothing leaves the machine
  {
    id: "kicad",
    name: "KiCad libraries",
    domain: "electronics",
    access: "local",
    summary: "The official KiCad symbols, footprints and 3D models installed on this machine, plus any library folder you add. Placed parts carry their symbol and footprint into the project.",
    terms: "https://www.kicad.org/libraries/license/",
    caveats: ["CC-BY-SA 4.0 with an exception for designs that use them; third-party libraries keep their own licenses."],
  },
  {
    id: "standard",
    name: "Standard hardware",
    domain: "mechanical",
    access: "local",
    summary: "Screws, nuts, washers, set screws, dowel pins and ball bearings, built by the design engine from the ISO, ASME and ANSI dimension tables. No download, any size in the tables.",
  },
  // Distributors with an official API: keys in the OS keychain, never in the project or Git
  {
    id: "digikey",
    name: "DigiKey",
    domain: "electronics",
    access: "api",
    summary: "Product Information API v4: price breaks, stock, datasheet and product page. You create the developer account and the app (client credentials) yourself.",
    keys: [{ id: "clientId", label: "Client ID" }, { id: "clientSecret", label: "Client secret" }],
    signup: "https://developer.digikey.com/",
    terms: "https://developer.digikey.com/terms-and-conditions",
    searchUrl: "https://www.digikey.com/en/products/result?keywords={q}",
    caveats: ["Daily call limits and terms not checked by ViaForm: read them on the developer portal.", "Prices are read for the US site in USD."],
  },
  {
    id: "mouser",
    name: "Mouser",
    domain: "electronics",
    access: "api",
    summary: "Search API v1: price breaks, stock, datasheet and product page, with a free Search API key from your Mouser account.",
    keys: [{ id: "apiKey", label: "Search API key" }],
    signup: "https://www.mouser.com/api-hub/",
    terms: "https://www.mouser.com/api-hub/",
    searchUrl: "https://www.mouser.com/c/?q={q}",
    caveats: ["Call limits and terms not checked by ViaForm.", "The API takes the key in the request URL: it goes to Mouser over HTTPS only."],
  },
  {
    id: "nexar",
    name: "Octopart (Nexar)",
    domain: "electronics",
    access: "api",
    summary: "One search across many distributors (offers, stock, datasheets) through the Nexar Supply GraphQL API. A free tier exists with a monthly part limit.",
    keys: [{ id: "clientId", label: "Client ID" }, { id: "clientSecret", label: "Client secret" }],
    signup: "https://portal.nexar.com/",
    terms: "https://nexar.com/legal",
    searchUrl: "https://octopart.com/search?q={q}",
    caveats: ["Free tier limits and terms not checked by ViaForm."],
  },
  // Manual: part number and link typed by the user, CAD downloaded by the user
  {
    id: "mcmaster",
    name: "McMaster-Carr",
    domain: "mechanical",
    access: "manual",
    summary: "No public API. Type the part number and the link, download the CAD model from the product page and attach it: the app never scrapes the site.",
    searchUrl: "https://www.mcmaster.com/{q}",
    terms: "https://www.mcmaster.com/help/terms-and-conditions-of-use",
    caveats: ["Their terms limit automated extraction: to confirm in their conditions.", "McMaster gives some approved customers a Product Information API on request; not wired here."],
  },
  {
    id: "misumi",
    name: "MISUMI",
    domain: "mechanical",
    access: "manual",
    summary: "Configurable mechanical parts (shafts, linear guides, extrusions). Enter the configured part number and attach the CAD file you download.",
    searchUrl: "https://us.misumi-ec.com/vona2/result/?Keyword={q}",
    caveats: ["No public search API known; terms to check."],
  },
  {
    id: "robotshop",
    name: "RobotShop",
    domain: "both",
    access: "manual",
    summary: "Motors, controllers, sensors and kits for robots. Manual entries for now.",
    searchUrl: "https://www.robotshop.com/search?q={q}",
    planned: true,
    caveats: ["API access to study."],
  },
  {
    id: "adafruit",
    name: "Adafruit",
    domain: "electronics",
    access: "manual",
    summary: "Breakout boards and modules; most come with open KiCad or Eagle files and Fritzing parts on GitHub. Manual entries for now.",
    searchUrl: "https://www.adafruit.com/?q={q}",
    planned: true,
    caveats: ["A public product listing exists; its terms of use to study before wiring it."],
  },
  {
    id: "sparkfun",
    name: "SparkFun",
    domain: "electronics",
    access: "manual",
    summary: "Breakout boards and modules with open hardware files (KiCad and Eagle) on GitHub. Manual entries for now.",
    searchUrl: "https://www.sparkfun.com/search/?term={q}",
    planned: true,
    caveats: ["API access to study."],
  },
  // More sources worth a look, listed so the user can save parts from them today
  {
    id: "lcsc",
    name: "LCSC / JLCPCB parts",
    domain: "electronics",
    access: "manual",
    summary: "The parts JLCPCB assembles from, with LCSC numbers (C-numbers) that go straight into an assembly order. Useful with the KiCad export.",
    searchUrl: "https://www.lcsc.com/search?q={q}",
    planned: true,
    caveats: ["No open API known for search; terms to check."],
  },
  {
    id: "farnell",
    name: "Farnell / element14 / Newark",
    domain: "electronics",
    access: "manual",
    summary: "Distributor with an official Product Search API (key from their partner portal). Manual entries until it is wired.",
    searchUrl: "https://www.farnell.com/search?st={q}",
    signup: "https://partner.element14.com/",
    planned: true,
  },
  {
    id: "tme",
    name: "TME",
    domain: "electronics",
    access: "manual",
    summary: "European distributor with an official API (token and secret from your account). Manual entries until it is wired.",
    searchUrl: "https://www.tme.eu/en/katalog/?search={q}",
    signup: "https://developers.tme.eu/",
    planned: true,
  },
  {
    id: "snapmagic",
    name: "SnapMagic / Ultra Librarian / SamacSys",
    domain: "electronics",
    access: "manual",
    summary: "Symbols, footprints and 3D models made from datasheets, as KiCad files after a free sign-in. Download, then attach the .kicad_sym, .kicad_mod or .step here.",
    searchUrl: "https://www.snapeda.com/search/?q={q}",
    caveats: ["Each site has its own license for the models: check it per part."],
  },
  {
    id: "grabcad",
    name: "GrabCAD / Printables",
    domain: "mechanical",
    access: "manual",
    summary: "Community CAD models (STEP) of motors, modules and enclosures. Download the STEP and attach it.",
    searchUrl: "https://grabcad.com/library?query={q}",
    caveats: ["Each model has its own license, often non-commercial: check it per model."],
  },
  {
    id: "custom",
    name: "My parts",
    domain: "both",
    access: "manual",
    summary: "Anything else: a part number, a link, notes and the CAD files you attach.",
  },
];

export const source = (id: string): SourceInfo | undefined => SOURCES.find((s) => s.id === id);

/** The shop's own search page for `q`, opened in the browser. */
export function searchPage(id: string, q: string): string | undefined {
  const s = source(id);
  return s?.searchUrl?.replace("{q}", encodeURIComponent(q.trim()));
}
