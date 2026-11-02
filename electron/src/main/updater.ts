import { app, BrowserWindow } from "electron";
import { autoUpdater } from "electron-updater";
import type { UpdateStatus } from "../shared/api";

// Self-update from the signed GitHub Releases of soma-intelligence/ViaForm (electron-builder's
// `publish` setting). A new version downloads in the background and installs on the next quit,
// or right away when the user picks Restart.
const EVERY = 4 * 60 * 60 * 1000;

let status: UpdateStatus = { state: "idle" };

function send(s: UpdateStatus): void {
  status = s;
  for (const w of BrowserWindow.getAllWindows()) w.webContents.send("update", s);
}

export function currentStatus(): UpdateStatus {
  return status;
}

export function startUpdater(): void {
  if (!app.isPackaged) {
    send({ state: "dev" });
    return;
  }
  autoUpdater.autoDownload = true;
  autoUpdater.autoInstallOnAppQuit = true;
  autoUpdater.on("checking-for-update", () => send({ state: "checking" }));
  autoUpdater.on("update-not-available", () => send({ state: "none" }));
  autoUpdater.on("update-available", (i) => send({ state: "available", version: i.version }));
  autoUpdater.on("download-progress", (p) =>
    send({ state: "downloading", version: status.state === "available" || status.state === "downloading" ? status.version : "", percent: p.percent }),
  );
  autoUpdater.on("update-downloaded", (i) => send({ state: "ready", version: i.version }));
  autoUpdater.on("error", (e) => send({ state: "error", message: e.message }));
  void checkNow();
  setInterval(() => void checkNow(), EVERY).unref();
}

export async function checkNow(): Promise<void> {
  if (!app.isPackaged) {
    send({ state: "dev" });
    return;
  }
  try {
    await autoUpdater.checkForUpdates();
  } catch (e) {
    send({ state: "error", message: e instanceof Error ? e.message : String(e) });
  }
}

export function installNow(): void {
  if (status.state === "ready") autoUpdater.quitAndInstall();
}
