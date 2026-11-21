# How do I put my PCB into the 3D model and keep it in sync?

In ViaForm, press Send to 3D in the Electronics workspace: the core builds the board as a
component of the 3D design (a 1.6 mm board, copper, plated holes and simple part bodies),
tagged with the PCB revision. Then use Mount on a Part and click a face to seat the board there
with a rigid group. When the board changes, the button turns into Update 3D, which rebuilds the
bodies inside the same component so its placement and joints stay.

The logic lives in `core/src/link.rs` (`viaform-core`) and is shared by the Electron, macOS,
iPad and iPhone apps.

## Steps

1. Draw the schematic and press **Update PCB from schematic** (`board.sync`).
2. Place and route the board.
3. Press **Send to 3D** (Electron: the 3D group of the toolbar; Mac: "Send board to the 3D
   design"; iPad: "Send to 3D Design"). A component named `PCB <project name>` (or
   `PCB Board`) appears in the design.
4. Model or open the enclosure in the Design workspace.
5. Press **Mount on a Part**, then click the face the board should sit on.
6. Edit the electronics later. The design shows that the board changed in Electronics; press
   **Update 3D**.

## What gets built

All in the board component's frame, PCB x to x and PCB y to -y, board top at z = 1.6 mm:

| Body | Built from |
|---|---|
| `PCB Board` | A box the size of the board outline, 1.6 mm thick, green; cutouts become cylinder cuts |
| `PCB Copper` | Pad rings and tracks, 0.05 mm thick, on top (`F.Cu`) or under the board (`B.Cu`), metallic gold |
| Holes | A cut at each pad through board and copper |
| `PCB <reference>` per part | Stand-ins sized from the pad span: a lying cylinder for resistors, an upright can for capacitors, a domed cylinder for LEDs, a block for anything else |

Only horizontal and vertical track segments become copper bodies in this version.

The component's metadata records `description: "Linked to ViaForm PCB"`, `revision:
"pcb-<n>"` and the part number. `linked_revision` reads it back, and `link_state` returns
`{linked_revision, revision, out_of_date}` for the UI.

## How mounting works

`link::mount(cad, pcb, target, point, normal)`:

1. Finds the board component (error "Send the board to 3D first" if missing).
2. Finds the component owning the picked body. A body at the design root is first turned into
   its own component (`component.from_bodies`), because joints join components. Picking the
   board itself is refused.
3. Moves the board occurrence so its bottom face is centred on `point`, with its z axis along
   `normal` (`occurrence.move`).
4. Holds both with `joint.rigid_group`.

## How updating keeps the assembly

`link::push` looks for the component by name. If it exists, it removes the old bodies and
rebuilds new ones inside the same component, so the occurrence, its transform and the rigid
group stay. The core test `board_goes_to_3d_and_mounts_on_a_face` (`core/src/link.rs`) checks
that the joint list is unchanged after an update, and the Electron end-to-end test checks the
same flow through the addon.

## From code

```js
const w = new native.Workspace(true);   // sample board
w.cad("solid.box", { length: 80, width: 60, height: 10, corner: [-10, -50, 0], body_name: "Enclosure" });
w.linkPush();                            // { component, revision, created: true }
w.linkMount("Enclosure", [30, -20, 10], [0, 0, 1]);
w.pcb("component.add", { kind: "capacitor", position: { x: 50, y: 30 } });
w.linkState().out_of_date;               // true
w.linkPush();                            // created: false, same component
```

Swift calls the same functions through `vf_link_push`, `vf_link_mount` and `vf_link_revision`.

## Related

- [Architecture of the Rust core and FFI](architecture-rust-core-ffi.md)
- [The .viaform file format](viaform-file-format.md)
- [ViaForm vs KiCad](viaform-vs-kicad.md)
- [README](../../README.md)
