import * as path from "node:path";
import { app, BrowserWindow, dialog, ipcMain, Menu, shell, type MenuItemConstructorOptions } from "electron";
import { changes, loadNative, reply, type NativeWorkspace } from "./engine";
import { checkNow, currentStatus, installNow, startUpdater } from "./updater";
import type { DocState } from "../shared/api";

// One window, one Workspace: the design and the electronics of one project, saved together as a
// .viaform file.
const native = loadNative();
let ws: NativeWorkspace = new native.Workspace(process.argv.includes("--sample") || process.argv.includes("--pcb-3d"));
const doc: DocState = { path: null, dirty: false };
let win: BrowserWindow | null = null;

function title(): void {
  if (!win) return;
  const name = doc.path ? path.basename(doc.path) : "Untitled";
  win.setTitle(`${name}${doc.dirty ? " (edited)" : ""} · ViaForm`);
  win.setDocumentEdited(doc.dirty);
  if (doc.path) win.setRepresentedFilename(doc.path);
}

function touched(): void {
  doc.dirty = true;
  title();
}

function docChanged(): void {
  title();
  win?.webContents.send("doc-changed");
}

const FILTER = [{ name: "ViaForm project", extensions: ["viaform"] }];

/** Asks before throwing away edits. True when it is fine to go on. */
async function keepOrDiscard(): Promise<boolean> {
  if (!doc.dirty || !win) return true;
  const r = await dialog.showMessageBox(win, {
    type: "warning",
    message: "Save the changes to this project?",
    detail: "Your changes are lost if you don't save them.",
    buttons: ["Save", "Don't Save", "Cancel"],
    defaultId: 0,
    cancelId: 2,
  });
  if (r.response === 2) return false;
  if (r.response === 0) return "ok" in (await save(false));
  return true;
}

async function save(as: boolean): Promise<{ ok: unknown } | { error: string }> {
  let target = doc.path;
  if (as || !target) {
    const r = await dialog.showSaveDialog(win!, { defaultPath: target ?? "Untitled.viaform", filters: FILTER });
    if (r.canceled || !r.filePath) return { error: "cancelled" };
    target = r.filePath.endsWith(".viaform") ? r.filePath : `${r.filePath}.viaform`;
  }
  const out = reply(() => ws.save(target!));
  if ("ok" in out) {
    doc.path = target;
    doc.dirty = false;
    app.addRecentDocument(target!);
    docChanged();
  }
  return out;
}

async function openPath(file: string): Promise<{ ok: unknown } | { error: string }> {
  const out = reply(() => ws.open(file));
  if ("ok" in out) {
    doc.path = file;
    doc.dirty = false;
    app.addRecentDocument(file);
    docChanged();
  }
  return out;
}

async function fileAction(action: string): Promise<{ ok: unknown } | { error: string }> {
  switch (action) {
    case "new":
    case "sample":
      if (!(await keepOrDiscard())) return { error: "cancelled" };
      ws = new native.Workspace(action === "sample");
      doc.path = null;
      doc.dirty = false;
      docChanged();
      return { ok: null };
    case "open": {
      if (!(await keepOrDiscard())) return { error: "cancelled" };
      const r = await dialog.showOpenDialog(win!, { properties: ["openFile"], filters: FILTER });
      if (r.canceled || !r.filePaths[0]) return { error: "cancelled" };
      return openPath(r.filePaths[0]);
    }
    case "save":
      return save(false);
    case "saveAs":
      return save(true);
    case "exportKicad":
    case "exportStep": {
      const kicad = action === "exportKicad";
      const base = doc.path ? path.basename(doc.path, ".viaform") : "Untitled";
      const r = await dialog.showSaveDialog(win!, {
        defaultPath: `${base}.${kicad ? "kicad_pcb" : "step"}`,
        filters: [kicad ? { name: "KiCad board", extensions: ["kicad_pcb"] } : { name: "STEP", extensions: ["step", "stp"] }],
      });
      if (r.canceled || !r.filePath) return { error: "cancelled" };
      const file = r.filePath;
      return reply(() => (kicad ? ws.pcb("file.export_kicad", { path: file }) : ws.cad("file.export_step", { path: file })));
    }
    default:
      return { error: `unknown file action ${action}` };
  }
}

function ipc(): void {
  ipcMain.handle("cad", (_e, id: string, params?: unknown) => {
    const r = reply(() => ws.cad(id, params ?? {}));
    if ("ok" in r && changes(id)) touched();
    return r;
  });
  ipcMain.handle("pcb", (_e, id: string, params?: unknown) => {
    const r = reply(() => ws.pcb(id, params ?? {}));
    if ("ok" in r && !id.startsWith("file.")) touched();
    return r;
  });
  ipcMain.handle("pcbInspect", () => ws.pcbInspect());
  ipcMain.handle("pcbChecks", () => ws.pcbChecks());
  ipcMain.handle("commands", () => ws.commands());
  ipcMain.handle("scene", () => ws.scene());
  ipcMain.handle("linkPush", () => {
    const r = reply(() => ws.linkPush());
    if ("ok" in r) touched();
    return r;
  });
  ipcMain.handle("linkMount", (_e, body: string, point: number[], normal: number[]) => {
    const r = reply(() => ws.linkMount(body, point, normal));
    if ("ok" in r) touched();
    return r;
  });
  ipcMain.handle("linkState", () => ws.linkState());
  ipcMain.handle("file", (_e, action: string) => fileAction(action));
  ipcMain.handle("doc", () => doc);
  ipcMain.handle("versions", () => ({ ...native.versions(), app: app.getVersion(), electron: process.versions.electron }));
  ipcMain.handle("checkForUpdates", () => checkNow());
  ipcMain.handle("installUpdate", () => installNow());
  ipcMain.handle("updateStatus", () => currentStatus());
}

function menu(): void {
  const send = (command: string) => () => win?.webContents.send("menu", command);
  const file = (action: string) => () => void fileAction(action).then((r) => "error" in r && r.error !== "cancelled" && dialog.showErrorBox("ViaForm", r.error));
  const mac = process.platform === "darwin";
  const template: MenuItemConstructorOptions[] = [
    ...(mac ? [{ role: "appMenu" as const }] : []),
    {
      label: "File",
      submenu: [
        { label: "New", accelerator: "CmdOrCtrl+N", click: file("new") },
        { label: "Open…", accelerator: "CmdOrCtrl+O", click: file("open") },
        { role: "recentDocuments", submenu: [{ role: "clearRecentDocuments" }] } as MenuItemConstructorOptions,
        { label: "Open Sample", click: file("sample") },
        { type: "separator" },
        { label: "Save", accelerator: "CmdOrCtrl+S", click: file("save") },
        { label: "Save As…", accelerator: "CmdOrCtrl+Shift+S", click: file("saveAs") },
        { type: "separator" },
        { label: "Export KiCad Board…", click: file("exportKicad") },
        { label: "Export STEP…", click: file("exportStep") },
        ...(mac ? [] : [{ type: "separator" as const }, { role: "quit" as const }]),
      ],
    },
    {
      label: "Edit",
      submenu: [
        { label: "Undo", accelerator: "CmdOrCtrl+Z", click: send("undo") },
        { label: "Redo", accelerator: "CmdOrCtrl+Shift+Z", click: send("redo") },
        { type: "separator" },
        { role: "cut" },
        { role: "copy" },
        { role: "paste" },
        { label: "Find Command…", accelerator: "CmdOrCtrl+K", click: send("search") },
      ],
    },
    {
      label: "View",
      submenu: [
        { label: "Design", accelerator: "CmdOrCtrl+1", click: send("workspace:design") },
        { label: "Electronics", accelerator: "CmdOrCtrl+2", click: send("workspace:electronics") },
        { label: "Simulation", accelerator: "CmdOrCtrl+3", click: send("workspace:simulation") },
        { type: "separator" },
        { label: "Zoom to Fit", accelerator: "F6", registerAccelerator: false, click: send("fit") },
        { label: "Home View", click: send("view:home") },
        { type: "separator" },
        { role: "toggleDevTools" },
        { role: "togglefullscreen" },
      ],
    },
    {
      label: "Help",
      submenu: [
        { label: "Check for Updates…", click: () => void checkNow() },
        { label: "About ViaForm", click: send("about") },
        { label: "Source Code", click: () => void shell.openExternal("https://github.com/soma-intelligence/ViaForm") },
      ],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

function createWindow(): void {
  win = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 960,
    minHeight: 600,
    backgroundColor: "#1a1c20",
    title: "ViaForm",
    webPreferences: { preload: path.join(__dirname, "..", "preload", "preload.js"), contextIsolation: true, sandbox: true },
  });
  void win.loadFile(path.join(__dirname, "..", "renderer", "index.html"), { query: process.argv.includes("--pcb-3d") ? { demo: "pcb-3d" } : {} });
  win.on("close", (e) => {
    if (!doc.dirty) return;
    e.preventDefault();
    void keepOrDiscard().then((go) => {
      if (go) {
        doc.dirty = false;
        win?.destroy();
      }
    });
  });
  win.webContents.on("did-finish-load", () => {
    win?.webContents.send("update", currentStatus());
    // --screenshot=<file.png> [--workspace=electronics] [--sheet=board] [--sim=...]: saves the window and quits (docs, CI smoke test).
    const shot = process.argv.find((a) => a.startsWith("--screenshot="))?.slice(13);
    if (shot) {
      // Renderer errors to stderr, so a smoke test that captures a broken page says why.
      win?.webContents.on("console-message", (e) => { if (e.level === "error" || e.level === "warning") process.stderr.write(`renderer ${e.level}: ${e.message}\n`); });
      const ws = process.argv.find((a) => a.startsWith("--workspace="))?.slice(12);
      setTimeout(() => {
        if (ws) win?.webContents.send("menu", `workspace:${ws}`);
        // --sim={"weather":3,"at":12,"camera":"chase"}: a simulation scene, flown to that time.
        const simArg = process.argv.find((a) => a.startsWith("--sim="))?.slice(6);
        if (simArg) win?.webContents.send("menu", `sim:${simArg}`);
        const sheetArg = process.argv.find((a) => a.startsWith("--sheet="))?.slice(8);
        if (sheetArg) win?.webContents.send("menu", `sheet:${sheetArg}`);
        setTimeout(async () => {
          const img = await win!.webContents.capturePage();
          require("node:fs").writeFileSync(shot, img.toPNG());
          doc.dirty = false;
          app.exit(0);
        }, 1500);
      }, 2500);
    }
  });
  title();
}

// A .viaform opened from the Finder or Explorer before or after launch.
let pendingOpen: string | null = process.argv.find((a) => a.endsWith(".viaform")) ?? null;
app.on("open-file", (e, file) => {
  e.preventDefault();
  if (win) void keepOrDiscard().then((go) => { if (go) void openPath(file); });
  else pendingOpen = file;
});

if (!app.requestSingleInstanceLock()) app.quit();
app.on("second-instance", (_e, argv) => {
  const file = argv.find((a) => a.endsWith(".viaform"));
  if (file) void keepOrDiscard().then((go) => { if (go) void openPath(file); });
  win?.focus();
});

void app.whenReady().then(() => {
  ipc();
  menu();
  createWindow();
  if (pendingOpen) void openPath(pendingOpen);
  startUpdater();
});

app.on("window-all-closed", () => app.quit());
