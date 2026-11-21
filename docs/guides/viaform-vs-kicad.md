# ViaForm vs KiCad: how do they compare?

KiCad is a mature, open source (GPL-3.0) schematic and PCB suite for Windows, macOS and Linux.
ViaForm is a young open source (GPL-3.0-or-later) app that combines 3D CAD with a small PCB
workspace on the PCBCraft engine and links the board to the 3D model. ViaForm exports boards
to KiCad's `.kicad_pcb` format, so the two work together: sketch and fit the board in ViaForm,
then continue in KiCad if you need its libraries and fabrication outputs.

ViaForm is an independent project and is not affiliated with or endorsed by the KiCad project.

## Side by side, as of November 2026

ViaForm facts are from the code on `main`; KiCad facts are from its public site.

| | ViaForm | KiCad |
|---|---|---|
| License | GPL-3.0-or-later | GPL-3.0 |
| Maturity | Version 0.2.0, no published release | Long-running project with stable releases |
| Platforms | Windows, Linux, macOS (Electron); macOS, iPad, iPhone (SwiftUI) | Windows, macOS, Linux |
| Schematic | Place parts, wire pins, rotate, delete | Full schematic editor, hierarchy, symbol libraries |
| Parts | Four built-in kinds: resistor, capacitor, LED, connector | Large symbol and footprint libraries |
| Board | Update from schematic, route pad to pad or all airwires | Full PCB editor, interactive router |
| Copper layers | `F.Cu` and `B.Cu` | Many layers |
| Checks | ERC and DRC | ERC and DRC |
| 3D | The board becomes a solid component of a parametric CAD design you can mount and update | 3D viewer of the board |
| Mechanical CAD | Yes (SolidCraft engine) | No |
| KiCad interop | Exports `.kicad_pcb`; does not import KiCad files yet | Native |
| Fabrication outputs | Not in ViaForm | Gerber, drill and more |

## Moving a board from ViaForm to KiCad

1. Build the board in ViaForm's Electronics workspace (Update PCB from schematic, then route).
2. Export: Electron File > Export KiCad Board..., Mac "Export KiCad board" in the Electronics
   toolbar, iPad "Export KiCad".
3. Open the `.kicad_pcb` in KiCad's PCB editor.

Under the hood the export is the core's `file.export_kicad` command
(`core/src/lib.rs`), which writes `pcbcraft_io::kicad_board` output atomically. The app's
end-to-end test checks the file starts with `(kicad_pcb`.

## When to pick which

- Pick KiCad for production boards: libraries, many layers, fabrication files.
- Pick ViaForm when you want the board and its enclosure in one project, want to check fit in
  3D early, or want to sketch a board on an iPad.

## Related

- [Link a PCB to the 3D model](link-pcb-to-3d-model.md)
- [PCB design on iPad](pcb-design-on-ipad.md)
- [Open source Fusion 360 alternative](open-source-fusion-360-alternative.md)
- [README](../../README.md)
