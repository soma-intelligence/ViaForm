# What is a good open source CAD app for Mac?

ViaForm is an open source (GPL-3.0-or-later) CAD app with a native macOS build in SwiftUI and
Metal, on the SolidCraft Rust engine, and with a PCB workspace on the PCBCraft engine in the
same app. The Mac target needs macOS 14 or later on Apple silicon (arm64). An Electron build
of ViaForm also runs on macOS, Intel and Apple silicon. It is early (0.2.0) and built from
source.

## Two ways to run ViaForm on a Mac

| | Native macOS app (`apple/`, target `SolidCraft-macOS`) | Electron app (`electron/`) |
|---|---|---|
| UI | SwiftUI, Metal renderer | TypeScript, three.js (WebGL) |
| Mac hardware | Apple silicon (arm64 only) | Apple silicon and Intel (Release builds `--arm64` and `--x64`) |
| Design tools | Full sketch and solid toolset (below) | Box, Cylinder, Sphere, Union, Subtract, Delete, plus Find Command (Cmd+K) |
| Electronics | Schematic, board, routing, ERC and DRC, KiCad export | Same |
| Project file | Design as `.sc`, PCB project saved on its own | One `.viaform` file for both |
| Updates | Rebuild from source | Self-update from GitHub Releases (signed builds only) |
| App name | SolidCraft | ViaForm |

## What the native Mac app has

From `apple/Desk/` and `apple/Shared/`:

- Application bar with File (New Design, Open, Sample Bracket, Save As, Export), undo and redo.
- Toolbar with a workspace menu (Design, Electronics) and tabs of tools.
- Sketch: Line, Rectangle, Center Rectangle, Circle, Arc, Polygon, Slot, Spline, Point, Sketch
  Fillet, Trim, Offset.
- Solid: Sketch, Extrude, Revolve, Press Pull, Fillet, Chamfer, Shell, Box, Cylinder, Sphere,
  Torus, Union, Subtract, Intersect, Move, Mirror, Delete, Measure.
- Browser tree of bodies and sketches with show, hide, delete and Edit Sketch.
- ViewCube, display styles (Shaded with Edges, Shaded, Wireframe), grid toggle.
- Timeline: step through features, Roll History Marker Here, Edit Feature, Suppress, Delete.
- Marking menu on right-click, toolbox search on S.
- Keys from [the UI reference sheet](../ui-reference.md): L line, R rectangle, C circle, E
  extrude, Q press pull, F fillet.
- Open STEP, STL, OBJ, 3MF and SolidCraft files; export STEP, STL, OBJ or 3MF.

## Build the native Mac app

```bash
git clone https://github.com/soma-intelligence/ViaForm.git
cd ViaForm
git submodule update --init --recursive
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
brew install xcodegen
scripts/build-bridge.sh
cd apple && xcodegen generate && open SolidCraftNative.xcodeproj
```

Run the `SolidCraft-macOS` scheme. The Mac target signs ad hoc (`CODE_SIGN_IDENTITY: "-"`), so
it runs locally without a developer account. `--sample` opens the bracket sample and
`--selftest` runs the tool paths end to end, then exits.

## Related

- [Build ViaForm from source](build-from-source.md)
- [Open source Fusion 360 alternative](open-source-fusion-360-alternative.md)
- [Open source Shapr3D alternative for iPad](open-source-shapr3d-alternative-ipad.md)
- [README](../../README.md)
