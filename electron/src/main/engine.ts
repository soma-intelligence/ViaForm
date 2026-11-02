import * as path from "node:path";
import { app } from "electron";

// The Rust core as a Node addon. Packaged, it sits in the app's resources (outside the asar
// archive, which cannot hold a native module); in development, in electron/native.
export interface NativeWorkspace {
  cad(id: string, params?: unknown): unknown;
  pcb(id: string, params?: unknown): unknown;
  pcbInspect(): unknown;
  pcbChecks(): unknown;
  commands(): unknown;
  scene(): unknown;
  linkPush(): unknown;
  linkMount(body: string, point: number[], normal: number[]): unknown;
  linkState(): unknown;
  save(path: string): unknown;
  open(path: string): unknown;
}

export interface Native {
  Workspace: new (sample?: boolean) => NativeWorkspace;
  versions(): { core: string; solidcraft: string; pcbcraft: string; format: number };
}

export function addonPath(): string {
  return app?.isPackaged
    ? path.join(process.resourcesPath, "viaform.node")
    : path.join(__dirname, "..", "..", "native", "viaform.node");
}

export function loadNative(file = addonPath()): Native {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  return require(file) as Native;
}

/** Runs `f`, turning a thrown engine message into `{error}`. */
export function reply<T>(f: () => T): { ok: T } | { error: string } {
  try {
    return { ok: f() };
  } catch (e) {
    return { error: e instanceof Error ? e.message : String(e) };
  }
}

/** Commands that change nothing, so they leave the document clean. */
const READ_ONLY = /^(component\.(list|metadata)$|joint\.list$|inspect\.|document\.inspect$|sketch\.snap$|edit\.checkpoint$)/;

export function changes(id: string): boolean {
  return !READ_ONLY.test(id);
}
