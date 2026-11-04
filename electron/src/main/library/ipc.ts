import * as path from "node:path";
import { app, dialog, ipcMain, safeStorage, shell, type BrowserWindow } from "electron";
import type { Family } from "./hardware";
import { Library } from "./service";
import { searchPage } from "../../shared/library/sources";
import { Secrets, Store } from "./store";
import type { LibraryItem } from "../../shared/library/types";

// The side libraries in the main process: the user's library in the app's data folder, the API
// keys encrypted by the OS keychain, every network call to a distributor made from here (the
// renderer's content security policy allows none).

export function startLibrary(window: () => BrowserWindow | null, families: () => Family[]): Library {
  const dir = path.join(app.getPath("userData"), "library");
  const store = new Store(dir);
  const secrets = new Secrets(path.join(dir, "secrets.bin"), {
    available: () => safeStorage.isEncryptionAvailable(),
    encrypt: (t) => safeStorage.encryptString(t),
    decrypt: (b) => safeStorage.decryptString(b),
  });
  const lib = new Library({ store, secrets, fetch: globalThis.fetch, families });

  const handle = (channel: string, f: (...a: any[]) => unknown) =>
    ipcMain.handle(channel, async (_e, ...a) => {
      try { return { ok: await f(...a) }; } catch (e) { return { error: e instanceof Error ? e.message : String(e) }; }
    });

  handle("library:state", (reindex?: boolean) => {
    if (reindex) lib.kicad(true);
    return lib.state();
  });
  handle("library:search", (q: string, only?: string[]) => lib.search(q, only));
  handle("library:save", (item: LibraryItem) => lib.save(item));
  handle("library:remove", (key: string) => lib.remove(key));
  handle("library:attach", async (key: string) => {
    const w = window();
    const r = await (w ? dialog.showOpenDialog(w, { properties: ["openFile"], filters: CAD_FILES }) : dialog.showOpenDialog({ properties: ["openFile"], filters: CAD_FILES }));
    if (r.canceled || !r.filePaths[0]) return null;
    return lib.attach(key, r.filePaths[0]);
  });
  handle("library:enable", (id: string, on: boolean) => lib.setEnabled(id, on));
  handle("library:keys", (id: string, keys: Record<string, string>) => lib.setKeys(id, keys));
  handle("library:addRoot", async () => {
    const w = window();
    const opts = { properties: ["openDirectory" as const], message: "A folder with .kicad_sym files, .pretty footprint folders or .3dshapes model folders" };
    const r = await (w ? dialog.showOpenDialog(w, opts) : dialog.showOpenDialog(opts));
    if (r.canceled || !r.filePaths[0]) return null;
    lib.setKicadRoots([...lib.state().kicadRoots, r.filePaths[0]]);
    lib.kicad(true);
    return lib.state();
  });
  handle("library:removeRoot", (root: string) => {
    lib.setKicadRoots(lib.state().kicadRoots.filter((r) => r !== root));
    return lib.state();
  });
  handle("library:footprint", (ref: string) => lib.footprint(ref) ?? null);
  handle("library:open", (url: string) => openUrl(url));
  handle("library:openSearch", (id: string, q: string) => {
    const url = searchPage(id, q);
    if (!url) throw new Error("this source has no search page");
    return openUrl(url);
  });
  handle("library:reveal", (file: string) => shell.showItemInFolder(file));
  return lib;
}

const CAD_FILES = [
  { name: "CAD and library files", extensions: ["step", "stp", "kicad_mod", "kicad_sym", "pdf", "zip"] },
  { name: "All files", extensions: ["*"] },
];

/** Opens a web page in the user's browser; only http and https, never a file or a custom scheme. */
async function openUrl(url: string): Promise<void> {
  const u = new URL(url);
  if (u.protocol !== "https:" && u.protocol !== "http:") throw new Error("only web links open from the library");
  await shell.openExternal(u.toString());
}
