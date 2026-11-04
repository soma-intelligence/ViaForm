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
  library: {
    state: (reindex) => ipcRenderer.invoke("library:state", reindex),
    search: (q, only) => ipcRenderer.invoke("library:search", q, only),
    save: (item) => ipcRenderer.invoke("library:save", item),
    remove: (key) => ipcRenderer.invoke("library:remove", key),
    attach: (key) => ipcRenderer.invoke("library:attach", key),
    enable: (source, on) => ipcRenderer.invoke("library:enable", source, on),
    keys: (source, keys) => ipcRenderer.invoke("library:keys", source, keys),
    addRoot: () => ipcRenderer.invoke("library:addRoot"),
    removeRoot: (root) => ipcRenderer.invoke("library:removeRoot", root),
    footprint: (ref) => ipcRenderer.invoke("library:footprint", ref),
    fromLink: (url) => ipcRenderer.invoke("library:fromLink", url),
    open: (url) => ipcRenderer.invoke("library:open", url),
    openSearch: (source, q) => ipcRenderer.invoke("library:openSearch", source, q),
    reveal: (file) => ipcRenderer.invoke("library:reveal", file),
  },
};

contextBridge.exposeInMainWorld("viaform", api);
