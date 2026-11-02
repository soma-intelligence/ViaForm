// The surface the preload script exposes to the renderer as `window.viaform`. Every engine call
// goes to the main process, which holds the one Workspace (design and electronics together).

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

export interface SceneMesh {
  body: string;
  positions: Float32Array;
  normals: Float32Array;
  indices: Uint32Array;
  triFace: Uint32Array;
  edgePoints: Float32Array;
  edgeOffsets: Uint32Array;
  color: number[];
}

export interface SceneLine {
  points: Float32Array;
  color: number[];
  width: number;
  onTop: boolean;
}

export interface SceneData {
  meshes: SceneMesh[];
  lines: SceneLine[];
  radius: number;
  background: number[];
}

export interface LinkState {
  linked_revision: number | null;
  revision: number;
  out_of_date: boolean;
}

export interface Versions {
  app: string;
  core: string;
  solidcraft: string;
  pcbcraft: string;
  format: number;
  electron: string;
}

export type UpdateStatus =
  | { state: "idle" | "checking" | "none" | "dev" }
  | { state: "available" | "downloading"; version: string; percent?: number }
  | { state: "ready"; version: string }
  | { state: "error"; message: string };

/** A reply from the main process: the value, or the engine's message. */
export type Reply<T = Json> = { ok: T } | { error: string };

export interface DocState {
  path: string | null;
  dirty: boolean;
}

export interface ViaFormAPI {
  cad(id: string, params?: Json): Promise<Reply>;
  pcb(id: string, params?: Json): Promise<Reply>;
  pcbInspect(): Promise<Json>;
  pcbChecks(): Promise<Json>;
  commands(): Promise<Json>;
  scene(): Promise<SceneData>;
  linkPush(): Promise<Reply>;
  linkMount(body: string, point: number[], normal: number[]): Promise<Reply>;
  linkState(): Promise<LinkState>;
  file(action: "new" | "open" | "save" | "saveAs" | "exportKicad" | "exportStep" | "sample"): Promise<Reply>;
  doc(): Promise<DocState>;
  versions(): Promise<Versions>;
  checkForUpdates(): Promise<void>;
  installUpdate(): Promise<void>;
  onMenu(handler: (command: string) => void): void;
  onUpdate(handler: (status: UpdateStatus) => void): void;
  onDocChanged(handler: () => void): void;
}
