// Builds the Rust addon (node/ in the repo root) and copies it to native/viaform.node, where the
// main process loads it in development and electron-builder picks it up for the package.
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "..", "..");
const target = process.env.VIAFORM_RUST_TARGET; // set by CI for cross builds (e.g. x86_64-apple-darwin)
const args = ["build", "--release", "-p", "viaform-node"];
if (target) args.push("--target", target);
execFileSync("cargo", args, { cwd: repo, stdio: "inherit" });

const file = { darwin: "libviaform_node.dylib", linux: "libviaform_node.so", win32: "viaform_node.dll" }[process.platform];
const built = join(repo, "target", ...(target ? [target] : []), "release", file);
mkdirSync(join(here, "..", "native"), { recursive: true });
// Replace the file rather than write over it: macOS caches a loaded library's code signature by
// file, and a library rewritten in place is killed on load (exit 137).
const dest = join(here, "..", "native", "viaform.node");
rmSync(dest, { force: true });
copyFileSync(built, dest);
console.log(`native/viaform.node <- ${built}`);
