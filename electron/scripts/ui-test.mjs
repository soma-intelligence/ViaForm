// The shell's UI test (`npm run test:ui`): starts the built app on the --pcb-3d demo, drives it
// over the DevTools protocol the way a user would (clicks, keys, menus) and checks the result in
// the DOM and in the engine's document. Needs a display; CI runs it under xvfb on Linux.
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const dir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const electron = createRequire(import.meta.url)("electron");
const PORT = 9333;
const args = [dir, "--pcb-3d", `--remote-debugging-port=${PORT}`, ...(process.platform === "linux" ? ["--no-sandbox"] : [])];
const app = spawn(electron, args, { stdio: "ignore" });
// SIGKILL: on SIGTERM the app asks whether to keep the unsaved test document and stays open.
const deadline = setTimeout(() => { console.log("FAIL timed out"); app.kill("SIGKILL"); process.exit(1); }, 180_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let ws, id = 0;
const pending = new Map();
const errors = [];
const results = [];

async function connect() {
  for (let i = 0; i < 40; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
      const page = list.find((p) => p.type === "page");
      if (page) {
        ws = new WebSocket(page.webSocketDebuggerUrl);
        await new Promise((r) => (ws.onopen = r));
        ws.onmessage = (m) => {
          const d = JSON.parse(m.data);
          if (d.id && pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); }
          if (d.method === "Runtime.exceptionThrown") errors.push(d.params.exceptionDetails.exception?.description ?? d.params.exceptionDetails.text);
          if (d.method === "Runtime.consoleAPICalled" && d.params.type === "error") errors.push(d.params.args.map((a) => a.value ?? a.description).join(" "));
        };
        return;
      }
    } catch {}
    await sleep(500);
  }
  throw new Error("no page");
}

function send(method, params = {}) {
  return new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
}

async function js(expr) {
  const r = await send("Runtime.evaluate", { expression: `(async () => { ${expr} })()`, awaitPromise: true, returnByValue: true });
  if (r.result?.exceptionDetails) throw new Error(r.result.exceptionDetails.exception?.description ?? "eval error");
  return r.result?.result?.value;
}

async function check(name, expr, ok = (v) => v === true) {
  try {
    const v = await js(expr);
    const pass = ok(v);
    results.push([pass, name, JSON.stringify(v)?.slice(0, 160)]);
  } catch (e) {
    results.push([false, name, String(e).slice(0, 200)]);
  }
}

const H = `
  const q = (s) => document.querySelector(s);
  const qa = (s) => [...document.querySelectorAll(s)];
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const ins = async () => (await window.viaform.cad("document.inspect")).ok;
  const canvas = () => q("#view3d canvas");
  const clickAt = async (x, y, button = 0) => {
    const c = canvas(); const r = c.getBoundingClientRect();
    const o = { clientX: r.left + x * r.width, clientY: r.top + y * r.height, button, bubbles: true, pointerId: 1 };
    c.dispatchEvent(new PointerEvent("pointerdown", o)); c.dispatchEvent(new PointerEvent("pointerup", o)); await wait(500);
  };
  const key = async (k) => { document.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true })); await wait(300); };
  const btn = (title) => qa("button").find((b) => (b.title || "").startsWith(title));
`;

await connect().catch((e) => { console.log(`FAIL ${e.message}`); app.kill("SIGKILL"); process.exit(1); });
await send("Runtime.enable");
await sleep(4000);

await check("app bar, doc tab", H + `return !!q("#appbar .doctab") && qa("#appbar-left .ab").length >= 5;`);
await check("design tabs", H + `return qa("#tabs .tab").map(t => t.textContent);`, (v) => v.join() === "SOLID,SURFACE,SHEET METAL,PLASTIC,WELDMENTS");
await check("solid panels", H + `return qa("#toolbar .panel .name").map(n => n.textContent);`, (v) => ["CREATE", "MODIFY", "ASSEMBLE", "CONSTRUCT", "ELECTRONICS", "INSPECT", "INSERT", "SELECT"].every((p) => v.includes(p)));
await check("CREATE dropdown lists all commands", H + `qa("#toolbar .panel .name")[0].click(); await wait(200); const n = qa("#menu-layer .mi").length; q("#menu-layer").dispatchEvent(new PointerEvent("pointerdown", {bubbles:true})); await wait(100); return n;`, (v) => v > 15);
await check("dropdown closes", H + `return q("#menu-layer").hidden;`);
await check("SURFACE tab switches panels", H + `qa("#tabs .tab")[1].click(); await wait(200); const t = btn("Surface Extrude"); qa("#tabs .tab")[0].click(); await wait(200); return !!t;`);
await check("browser tree", H + `return qa("#browser .node .label").map(n => n.textContent);`, (v) => v.includes("Document Settings") && v.includes("Origin") && v.includes("Enclosure"));
await check("viewcube 6 faces", H + `return qa(".vc-face").length;`, (v) => v === 6);
await check("navbar", H + `return qa("#navbar .nb").length;`, (v) => v >= 7);
const n0 = await js(H + `return (await ins()).timeline.length;`);
await check("timeline chips match features", H + `return qa(".tl-item").length === (await ins()).timeline.length && !!q(".tl-marker");`);

await check("Box tool opens dialog", H + `btn("Box").click(); await wait(200); return !q("#dialog").hidden && q("#dialog .fhead").textContent.includes("BOX");`);
await check("click places a box", H + `await clickAt(0.15, 0.85); return (await ins()).timeline.length;`, (v) => v === n0 + 1);
await check("timeline grew", H + `return qa(".tl-item").length;`, (v) => v === n0 + 1);
await check("Esc closes dialog", H + `await key("Escape"); return q("#dialog").hidden;`);

await check("click selects body", H + `await clickAt(0.15, 0.85); return qa("#browser .node.on .label").map(n=>n.textContent);`, (v) => Array.isArray(v) && v.length >= 1);
await check("eye hides body", H + `
  const b = (await ins()).bodies.at(-1).name;
  const row = qa("#browser .node").find(n => n.querySelector(".label")?.textContent === b);
  row.querySelector(".eye").click(); await wait(500);
  const v = (await ins()).bodies.find(x => x.name === b).visible;
  qa("#browser .node").find(n => n.querySelector(".label")?.textContent === b).querySelector(".eye").click(); await wait(500);
  return [v, (await ins()).bodies.find(x => x.name === b).visible];`, (v) => v[0] === false && v[1] === true);
await check("Delete removes selected body", H + `
  const b = (await ins()).bodies.at(-1).name;
  const row = qa("#browser .node").find(n => n.querySelector(".label")?.textContent === b); if (!row.classList.contains("on")) row.click(); await wait(200);
  await key("Delete"); await wait(400); return (await ins()).bodies.some(x => x.name === b);`, (v) => v === false);
await check("undo restores it", H + `btn("Undo").click(); await wait(600); return (await ins()).bodies.length;`, (v) => v >= 2);

await check("marking menu on right click", H + `await clickAt(0.5, 0.5, 2); const n = qa(".marking .wedge").length; await key("Escape"); return [n, q("#menu-layer").hidden];`, (v) => v[0] === 8 && v[1] === true);
await check("viewcube TOP turns camera", H + `const before = q(".vc-cube").style.transform; qa(".vc-face")[0].click(); await wait(600); return before !== q(".vc-cube").style.transform;`);
await check("home view", H + `q(".vc-home").click(); await wait(500); return true;`);
await check("visual style menu", H + `btn("Display settings").click(); await wait(200); const items = qa("#menu-layer .mi").map(m=>m.textContent); qa("#menu-layer .mi")[2].click(); await wait(200); return items;`, (v) => v.length === 3);
await check("grid toggle", H + `const g = btn("Grid"); const was = g.classList.contains("on"); g.click(); await wait(100); const now = btn("Grid").classList.contains("on"); btn("Grid").click(); return was !== now;`);
await check("orbit mode toggles", H + `btn("Orbit").click(); await wait(100); const on = btn("Orbit").classList.contains("on"); await key("Escape"); return on && !btn("Orbit").classList.contains("on");`);

await check("S opens command search", H + `await key("s"); return !q("#palette").hidden;`);
await check("search finds extrude", H + `const i = q("#palette-input"); i.value = "extrude"; i.dispatchEvent(new Event("input")); await wait(100); return qa("#palette-list li").map(l => l.textContent).slice(0, 3);`, (v) => v.some((t) => t.startsWith("Extrude")));
await check("Enter opens Extrude dialog", H + `q("#palette-input").dispatchEvent(new KeyboardEvent("keydown", {key: "Enter", bubbles: true})); await wait(300); const t = q("#dialog .fhead").textContent; await key("Escape"); return t;`, (v) => typeof v === "string" && v.includes("EXTRUDE"));

await check("Create Sketch via dialog shows SKETCH tab", H + `btn("Create Sketch").click(); await wait(200); qa("#dialog .btn").find(b => b.textContent === "OK").click(); await wait(800); return qa("#tabs .tab").map(t=>t.textContent);`, (v) => v[0] === "SKETCH");
await check("sketch panels + Finish Sketch", H + `return [qa("#toolbar .panel .name").map(n=>n.textContent), !!q(".tool.finish")];`, (v) => v[1] && v[0].includes("CONSTRAINTS"));
await check("L opens Line dialog while sketching", H + `await key("l"); const t = q("#dialog .fhead")?.textContent; await key("Escape"); return t;`, (v) => typeof v === "string" && v.includes("LINE"));
await check("Finish Sketch returns to SOLID", H + `q(".tool.finish").click(); await wait(800); return q("#tabs .tab.on").textContent;`, (v) => v === "SOLID");

await check("timeline: roll to start", H + `qa(".tl-btn")[0].click(); await wait(800); return [(await ins()).marker, qa(".tl-item.rolled").length];`, (v) => v[0] === 0 && v[1] > 0);
await check("timeline: step forward", H + `qa(".tl-btn")[3].click(); await wait(800); return (await ins()).marker;`, (v) => v === 1);
await check("timeline: roll to end", H + `qa(".tl-btn")[4].click(); await wait(800); const i = await ins(); return [i.marker, i.timeline.length, qa(".tl-item.rolled").length];`, (v) => v[0] === v[1] && v[2] === 0);
await check("timeline context menu", H + `const c = qa(".tl-item")[0]; c.dispatchEvent(new MouseEvent("contextmenu", {bubbles: true, clientX: 300, clientY: 700})); await wait(200); const m = qa("#menu-layer .mi").map(x=>x.textContent); await key("Escape"); return m;`, (v) => v.includes("Suppress Feature") && v.includes("Roll History Marker Here"));

await check("file menu", H + `btn("File").click(); await wait(200); const m = qa("#menu-layer .mi").map(x=>x.textContent); await key("Escape"); return m;`, (v) => v.some((t) => t.startsWith("Save")) && v.includes("Export STEP…"));
await check("data panel", H + `btn("Show the data panel").click(); await wait(200); const ok = !q("#datapanel").hidden && qa(".dp-item").length >= 8; btn("Show the data panel").click(); await wait(100); return ok && q("#datapanel").hidden;`);
await check("dirty dot on doc tab", H + `return !!q(".doctab .dirty");`);

await check("workspace menu to Electronics", H + `q(".ws-menu").click(); await wait(200); qa("#menu-layer .mi").find(m => m.textContent.includes("Electronics")).click(); await wait(500);
  return [qa("#tabs .tab").map(t=>t.textContent), q("#timeline").hidden, q("#inspector").hidden, q("#view3d").hidden];`, (v) => v[0].join() === "SCHEMATIC,PCB" && v[1] && !v[2] && v[3]);
await check("electronics browser", H + `return qa("#browser .node .label").map(n=>n.textContent);`, (v) => v.includes("Parts") && v.includes("Nets"));
await check("PCB tab", H + `qa("#tabs .tab")[1].click(); await wait(300); return qa("#toolbar .panel .name").map(n=>n.textContent);`, (v) => v.includes("ROUTE"));
await check("route all", H + `btn("Route all airwires").click(); await wait(1200); return q("#inspector").textContent;`, (v) => /0 unrouted/.test(v));
await check("PCB undo", H + `btn("Undo").click(); await wait(800); return q("#inspector").textContent;`, (v) => !/ 0 unrouted/.test(v));
await check("back to design", H + `q(".ws-menu").click(); await wait(200); qa("#menu-layer .mi").find(m => m.textContent.includes("Design")).click(); await wait(500); return !q("#view3d").hidden && !q("#timeline").hidden;`);

results.push([errors.length === 0, "no renderer errors", ""]);

for (const [p, n, v] of results) console.log(`${p ? "PASS" : "FAIL"} ${n}${p ? "" : `  -> ${v}`}`);
if (errors.length) console.log("ERRORS:\n" + errors.join("\n"));
console.log(`${results.filter((r) => r[0]).length}/${results.length} passed`);
clearTimeout(deadline);
app.kill("SIGKILL");
process.exit(results.every((r) => r[0]) ? 0 : 1);
