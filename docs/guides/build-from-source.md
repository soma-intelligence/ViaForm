# How do I build ViaForm from source?

Clone the repository with its two engine submodules, then build either the Electron app
(`cd electron && npm ci && npm start`, any OS, needs Rust and Node 22) or the Apple apps
(`scripts/build-bridge.sh`, then `xcodegen generate` in `apple/` and run from Xcode). Rust is
always required because every front end links the shared Rust core. There is no published
binary release yet, so building is the way to run ViaForm today.

## 1. Get the code

```bash
git clone https://github.com/soma-intelligence/ViaForm.git
cd ViaForm
git submodule update --init --recursive
```

This fetches `engines/solidcraft` and `engines/pcbcraft`. The root `Cargo.toml` points at
crates and vendored patches inside them, so nothing builds without the submodules.

## 2a. Electron app (Windows, Linux, macOS)

Prerequisites: a stable Rust toolchain (the workspace uses edition 2024) and Node 22 (what CI
uses).

```bash
cd electron
npm ci
npm start
```

What the scripts in `electron/package.json` do:

| Script | Does |
|---|---|
| `npm run native` | `cargo build --release -p viaform-node`, then copies the library to `electron/native/viaform.node` (`scripts/build-native.mjs`) |
| `npm run build` | native addon, main process (`tsc`), renderer (`vite build`) |
| `npm start` | build, then launch Electron |
| `npm test` | end-to-end tests on the addon under plain Node (`src/test/workspace.test.ts`) |
| `npm run typecheck` | `tsc --noEmit` for main and renderer |
| `npm run dist` | package for the current platform with electron-builder, no publishing |

Packages from `npm run dist`: dmg and zip on macOS, an NSIS installer on Windows, AppImage
and deb on Linux (`electron/electron-builder.yml`). Set `VIAFORM_RUST_TARGET` (for example
`x86_64-apple-darwin`) to cross-build the addon, as the Release workflow does for Intel Macs.

## 2b. Apple apps (macOS, iPad, iPhone)

Prerequisites: Xcode with Swift 6, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and three
Rust targets.

```bash
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
brew install xcodegen
scripts/build-bridge.sh            # or: scripts/build-bridge.sh debug
cd apple
xcodegen generate
open SolidCraftNative.xcodeproj
```

`scripts/build-bridge.sh` builds `bridge/` (`solidcraft-ffi`, a static library) for the three
targets with `IPHONEOS_DEPLOYMENT_TARGET=17.0` and `MACOSX_DEPLOYMENT_TARGET=14.0`. The Xcode
project (from `apple/project.yml`) links `-lsolidcraft_ffi` from `target/<triple>/release`, so
rerun the script after any Rust change.

| Target | Platform | Notes |
|---|---|---|
| `SolidCraft-macOS` | macOS 14+, arm64 only | Ad hoc signing (`CODE_SIGN_IDENTITY: "-"`), runs locally |
| `SolidCraft-iOS` | iOS and iPadOS 17+ | Set your own team under Signing to run on a device; the simulator build excludes x86_64 |

Both build an app named SolidCraft. Launch arguments: `--selftest` runs the tool paths end to
end (sketch, extrude, press pull, fillet, undo, primitives, scene, PCB, board to 3D) and exits;
`--sample` opens the bracket sample.

## 3. Run the tests

```bash
cargo test --release -p viaform-core      # link and .viaform file tests
cd electron && npm run native && npm run typecheck && npm test
```

This is what `.github/workflows/ci.yml` runs on macOS, Ubuntu and Windows.

## Troubleshooting

- **Cargo cannot find `engines/solidcraft/crates/engine`**: the submodules are missing. Run
  `git submodule update --init --recursive`.
- **Xcode: library not found for `-lsolidcraft_ffi`**: run `scripts/build-bridge.sh` first,
  with the matching profile (the project searches `release`).
- **Electron cannot load `native/viaform.node`**: run `npm run native` (it is part of
  `npm start` and `npm run build`).
- **macOS will not apply an update**: updates install only on a signed app; local builds are
  unsigned unless you set the signing variables listed in the README.

## Related

- [Architecture of the Rust core and FFI](architecture-rust-core-ffi.md)
- [Open source CAD for Mac](open-source-cad-for-mac.md)
- [AGENTS.md](../../AGENTS.md)
- [README](../../README.md)
