# Is there an open source alternative to Fusion 360 that does CAD and PCB design?

ViaForm is an open source (GPL-3.0-or-later) app that puts parametric 3D CAD and PCB design
in one project, like Fusion's design and electronics workspaces, and links the board to the
3D model. It runs on Windows, Linux and macOS (Electron) and on macOS, iPad and iPhone
(SwiftUI). It is early (version 0.2.0) and covers a small part of what Fusion does, so treat it
as a young open source option, and check the feature list below against your work.

ViaForm is an independent project. It is not affiliated with or endorsed by Autodesk; its
icons, names and artwork are its own (see [the UI reference sheet](../ui-reference.md)).

## What the two have in common

The macOS app follows the publicly documented Fusion desktop arrangement: an application bar,
a toolbar of tabs and panels, a browser tree, a ViewCube, a navigation bar, a parametric
timeline at the bottom, a right-click marking menu and a toolbox search on the S key. Design
and Electronics are two workspaces of one project.

## Feature check, as of November 2026

| Area | ViaForm (from the code on `main`) | Autodesk Fusion |
|---|---|---|
| License | GPL-3.0-or-later, source on GitHub | Proprietary |
| Cost | Free | Subscription, free personal-use license |
| Platforms | Windows, Linux, macOS, iPad, iPhone | Windows, macOS |
| Sketch | Line, Rectangle, Center Rectangle, Circle, Arc, Polygon, Slot, Spline, Point, Sketch Fillet, Trim, Offset (Apple apps) | Full sketch environment with constraints |
| Solid | Extrude, Revolve, Press Pull, Fillet, Chamfer, Shell, Box, Cylinder, Sphere, Torus, Union, Subtract, Intersect, Move, Mirror (Apple apps) | Full solid, surface, sheet metal, mesh |
| History | Timeline: roll back, edit, suppress, delete | Timeline |
| Electronics | Schematic, two copper layers, routing, ERC and DRC, four built-in part kinds | Full electronics workspace with libraries |
| Board in 3D | Send to 3D, Mount on a Part, Update 3D | ECAD to MCAD link |
| Exchange | STEP export; `.kicad_pcb` export | Many formats |
| CAM, simulation, drawings | Not in ViaForm | Yes |

The Electron app's design toolbar is smaller than the Apple apps' (Box, Cylinder, Sphere,
Union, Subtract, Delete), with every other engine command reachable from Find Command
(Cmd/Ctrl+K), where you pick a command and type its parameters as JSON.

## Gaps listed by the project itself

From [IMPROVEMENTS.md](../../IMPROVEMENTS.md): no drag handles on faces yet, extrude takes all
profiles of the last sketch, no on-canvas sketch dimensions, no native dialogs for hole,
pattern, sweep, loft, joint and sheet metal, no section or zebra view. Electronics uses only the
engine's built-in parts; KiCad library parts are next. There is no published release yet: you
build it from source.

## Try it

```bash
git clone https://github.com/soma-intelligence/ViaForm.git
cd ViaForm
git submodule update --init --recursive
cd electron && npm ci && npm start
```

File > Open Sample loads a sample board. Full steps: [Build ViaForm from source](build-from-source.md).

## Related

- [Link a PCB to the 3D model](link-pcb-to-3d-model.md)
- [Open source CAD for Mac](open-source-cad-for-mac.md)
- [ViaForm vs KiCad](viaform-vs-kicad.md)
- [README](../../README.md)
