# ViaForm

3D design and electronics as one app, on open source Rust engines (SolidCraft for CAD,
PCBCraft for PCB).

- **Windows, Linux and macOS**: an Electron app (`electron/`). Design and Electronics are two
  workspaces of one project, saved together as a `.viaform` file. It updates itself from this
  repository's GitHub Releases.
- **macOS**: a desktop layout with a ribbon of tabs and panels, a browser tree, a timeline,
  a right-click marking menu, command search on S and a ViewCube.
- **iPad and iPhone**: a touch-first layout with a project sidebar, items and history
  sidebars, a tool column (a bottom row on iPhone) and tools suggested from the selection.

The Apple apps draw with Metal, the Electron app with WebGL. All of them run every action
through the engines' command APIs, and share one Rust core (`core/`) for everything that joins
the two engines, so the board to 3D link behaves the same everywhere.

![Electron: board mounted in the assembly](docs/electron-design.png)
![Electron: schematic](docs/electron-schematic.png)

![macOS](docs/macos.png)
![iPad](docs/ipad.png)
![Schematic](docs/macos-schematic.png)
![Board](docs/macos-board.png)
![Board in the assembly](docs/macos-pcb-3d.png)

## Layout

```
engines/solidcraft   submodule: tangency-labs/solidcraft, parametric 3D CAD in Rust
engines/pcbcraft     submodule: tangency-labs/pcbcraft, KiCad-compatible PCB engine in Rust
core/                viaform-core: one workspace over both engines, the board to 3D link, the .viaform file
bridge/              solidcraft-ffi: a C ABI static library over the core, for the Swift apps
node/                viaform-node: a Node addon (N-API) over the core, for the Electron app
electron/            the cross-platform app: main process, preload, renderer (TypeScript, three.js)
apple/               XcodeGen project: Shared (engine, renderer, model), Desk (macOS), Touch (iOS)
docs/                screenshots and the UI reference sheet
scripts/             build-bridge.sh (Apple bridge), engine-sync.sh (move the engines to upstream)
.github/workflows/   CI, Release (signed builds and the update feed), Engine sync (daily)
```

## Build

```bash
git submodule update --init --recursive
```

Electron app (any platform, needs Rust and Node 22):

```bash
cd electron && npm ci && npm start
```

`npm test` runs the app's end-to-end tests on the addon; `cargo test -p viaform-core` runs the
core's. `npm run dist` packages for the current platform.

Apple apps:

```bash
scripts/build-bridge.sh
```

```bash
cd apple && xcodegen generate && open SolidCraftNative.xcodeproj
```

`SolidCraft --selftest` runs the tool paths end to end (sketch, extrude, press pull, fillet,
undo, primitives, scene) and exits. `--sample` opens the bracket sample.

## Notes

- The layouts follow public descriptions of how common CAD tools are arranged
  (see `docs/ui-reference.md`). Icons are SF Symbols; colours, names and artwork are our own.
- Electronics workspace (Mac: workspace menu, iPad and iPhone: Project sidebar): place parts, wire
  pins, update the board, route (one pair or every airwire), read ERC and DRC, export a
  `.kicad_pcb`. Parts are the engine's four built-in kinds for now; KiCad library parts are next.
- Board to 3D: Send to 3D builds the board as a component of the design (board, copper, holes,
  part stand-ins) tagged with the PCB revision. Mount on a Part seats it on a picked face with a
  rigid group. When the board changes, Update 3D rebuilds it inside the same component, so the
  placement and joints stay.
- Updates, two ways. The app checks the latest GitHub Release at launch and every four hours,
  downloads a newer version in the background and installs it on quit (or right away from the
  banner). The Engine sync workflow moves SolidCraft and PCBCraft to their upstream tips every
  day, builds and tests the whole app on them and opens a pull request with a patch version
  bump; merging it makes Release build, sign and publish that version, which installed copies
  then pick up. A `.viaform` saved by a newer format is refused with a message to update,
  never half read.
- Signing: Release reads `CSC_LINK`, `CSC_KEY_PASSWORD`, `APPLE_ID`,
  `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`, `WIN_CSC_LINK` and `WIN_CSC_KEY_PASSWORD`
  from the repository secrets. macOS only applies updates to a signed app.
- Next steps are in `IMPROVEMENTS.md`.

## Licence

GPL-3.0-or-later (see `LICENSE`), because the core links PCBCraft, which is GPL.
SolidCraft itself is MIT or Apache-2.0. GPL rules out App Store distribution.
