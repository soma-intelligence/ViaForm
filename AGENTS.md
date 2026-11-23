# AGENTS.md

Notes for coding agents and contributors working in this repository.

## What this repo is

ViaForm: 3D CAD and PCB design in one app. Front ends (SwiftUI in `apple/`, Electron in
`electron/`) call one Rust core (`core/`, crate `viaform-core`) through a C ABI bridge
(`bridge/`, crate `solidcraft-ffi`) or an N-API addon (`node/`, crate `viaform-node`). The
engines are git submodules in `engines/solidcraft` and `engines/pcbcraft`.

## Setup

```bash
git submodule update --init --recursive
```

Nothing builds without the submodules: the root `Cargo.toml` depends on crates and vendored
patches inside them.

## Build and test

| Task | Command |
|---|---|
| Core tests | `cargo test --release -p viaform-core` |
| Electron addon | `cd electron && npm ci && npm run native` |
| Electron typecheck | `cd electron && npm run typecheck` |
| Electron end-to-end tests | `cd electron && npm test` |
| Run Electron app | `cd electron && npm start` |
| Package Electron app | `cd electron && npm run dist` |
| Apple bridge | `scripts/build-bridge.sh` (needs Rust targets `aarch64-apple-darwin`, `aarch64-apple-ios`, `aarch64-apple-ios-sim`) |
| Xcode project | `cd apple && xcodegen generate` (the `.xcodeproj` is generated from `apple/project.yml`) |
| Apple self-test | launch the app with `--selftest` |

CI (`.github/workflows/ci.yml`) runs the core tests, `npm run native`, `npm run typecheck`,
`npm test` and `npm run build:renderer` on macOS, Ubuntu and Windows. Run the same before
proposing a change.

## Layout

```
core/src/lib.rs      Workspace { cad, pcb }, PCB file commands
core/src/link.rs     board to 3D link (push, mount, linked_revision)
core/src/project.rs  .viaform zip (save, open, FORMAT_VERSION)
core/src/scene.rs    GPU-ready scene buffers
bridge/              C ABI for Swift; header in bridge/include/solidcraft.h
node/                N-API addon for Electron
electron/src/main    main process: menus, files, updater, the one Workspace
electron/src/preload window.viaform bridge
electron/src/renderer UI, three.js viewport, PCB canvas, command palette
electron/src/shared  api.ts: the renderer API types
apple/Shared         engine wrappers, Metal renderer, models, shared UI
apple/Desk           macOS layout
apple/Touch          iPad and iPhone layout
scripts/             build-bridge.sh, engine-sync.sh
docs/                screenshots, ui-reference.md, guides/
```

## Conventions

- Every user action is an engine command (id plus JSON params). Do not add geometry logic to
  the front ends; put anything that joins the two engines in `core/`.
- Keep the C header (`bridge/include/solidcraft.h`) in step with `bridge/src/lib.rs`. Every
  `char*` returned is freed with `sc_string_free`; every entry point catches panics.
- Bump `FORMAT_VERSION` in `core/src/project.rs` for any incompatible `.viaform` change; older
  apps must refuse newer files.
- UI layouts follow public descriptions of other CAD tools (`docs/ui-reference.md`) but use
  SF Symbols and ViaForm's own names, colors and artwork. Never copy another product's icons,
  logos or assets.
- Docs and comments are plain English; no em dashes.

## Do not touch

- `engines/`: submodules. Changes go upstream as pull requests to SolidCraft or PCBCraft
  (see `IMPROVEMENTS.md`); move them only with `scripts/engine-sync.sh`.
- `apple/SolidCraftNative.xcodeproj`: generated; edit `apple/project.yml`.
- `electron/package.json` `version` on `main`: a change there triggers the Release workflow
  (tag, signed builds, GitHub Release). The Engine sync workflow bumps it.
- Release signing secrets and `electron/electron-builder.yml` publish settings.

## Licence

GPL-3.0-or-later. New code must be compatible with it.
