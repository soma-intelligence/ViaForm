# Is there an open source Shapr3D alternative for iPad?

ViaForm has an open source (GPL-3.0-or-later) touch app for iPad and iPhone whose layout
follows the publicly described Shapr3D arrangement: a tool column on the left edge, items and
history sidebars, and tools suggested from what you select. It models with the SolidCraft Rust
engine and also has an Electronics space for schematic and PCB work. You build it from source
with Xcode; GPL rules out App Store distribution.

ViaForm is an independent project and is not affiliated with or endorsed by Shapr3D. Icons are SF
Symbols, and colors, names and artwork are ViaForm's own.

## What the iPad app has

From `apple/Touch/TouchRootView.swift` and `apple/Shared/Model/Tools.swift`:

- Top bar: project sidebar, undo and redo, section view, isolate, items manager, history, export.
- Project sidebar: the Modeling and Electronics spaces are live. Visualization and 2D
  Drawings are not.
- Tool column (a bottom row on iPhone): Line, Rectangle, Center Rectangle, Circle, Arc,
  Polygon, Slot, Spline, Point, Sketch Fillet, Trim, Offset, Sketch, Extrude, Revolve, Press
  Pull, Fillet, Chamfer, Shell, Box, Cylinder, Sphere, Torus, Union, Subtract, Intersect, Move,
  Mirror, Delete, Measure.
- Suggestions: tools that fit the current selection, in a bar under the canvas.
- Value entry next to the tool for distances and angles.
- History: one chip per feature; tap one to roll the design back to it.
- Files: open STEP and mesh files (STL, OBJ, 3MF, PLY, glTF), save the design (`.sc`), export
  STEP or STL.
- Gestures from [the UI reference sheet](../ui-reference.md): one finger orbits, two fingers
  pan, pinch zooms.

## Compared with Shapr3D, as of November 2026

| | ViaForm (iPad app) | Shapr3D |
|---|---|---|
| License | GPL-3.0-or-later | Proprietary |
| Cost | Free | Subscription, free plan |
| Distribution | Build from source with Xcode | App Store and other stores |
| Platforms | iPad, iPhone, macOS (plus Windows and Linux through Electron) | iPad, macOS, Windows |
| PCB design | Electronics space (schematic, board, KiCad export) | No |
| Drag handles on faces | Not yet (value card instead) | Yes |
| Apple Pencil Pro gestures | Not yet | Yes |
| Visualization, drawings | Not yet | Yes |

Planned touch work (drag handles, Apple Pencil Pro squeeze and barrel roll, Files and iCloud
documents) is in [IMPROVEMENTS.md](../../IMPROVEMENTS.md).

## Build it for your iPad

```bash
git submodule update --init --recursive
rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin
scripts/build-bridge.sh
cd apple && xcodegen generate && open SolidCraftNative.xcodeproj
```

Pick the `SolidCraft-iOS` scheme, set your signing team in Xcode (the project has none set),
and run on the device. The app appears as SolidCraft. Details: [Build ViaForm from source](build-from-source.md).

## Related

- [PCB design on iPad](pcb-design-on-ipad.md)
- [Open source CAD for Mac](open-source-cad-for-mac.md)
- [Open source Fusion 360 alternative](open-source-fusion-360-alternative.md)
- [README](../../README.md)
