import { contextBridge, ipcRenderer } from "electron";
import type { ViaFormAPI } from "../shared/api";

const api: ViaFormAPI = {
  cad: (id, params) => ipcRenderer.invoke("cad", id, params),
  pcb: (id, params) => ipcRenderer.invoke("pcb", id, params),
  pcbInspect: () => ipcRenderer.invoke("pcbInspect"),
  pcbChecks: () => ipcRenderer.invoke("pcbChecks"),
  commands: () => ipcRenderer.invoke("commands"),
  scene: () => ipcRenderer.invoke("scene"),
  linkPush: () => ipcRenderer.invoke("linkPush"),
  linkMount: (body, point, normal) => ipcRenderer.invoke("linkMount", body, point, normal),
  linkState: () => ipcRenderer.invoke("linkState"),
  file: (action) => ipcRenderer.invoke("file", action),
  doc: () => ipcRenderer.invoke("doc"),
  versions: () => ipcRenderer.invoke("versions"),
  checkForUpdates: () => ipcRenderer.invoke("checkForUpdates"),
  installUpdate: () => ipcRenderer.invoke("installUpdate"),
  onMenu: (h) => void ipcRenderer.on("menu", (_e, c: string) => h(c)),
  onUpdate: (h) => void ipcRenderer.on("update", (_e, s) => h(s)),
  onDocChanged: (h) => void ipcRenderer.on("doc-changed", () => h()),
};

contextBridge.exposeInMainWorld("viaform", api);
