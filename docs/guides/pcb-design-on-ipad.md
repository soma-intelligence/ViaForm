# Can I design a PCB on an iPad?

Yes, with ViaForm's open source iPad and iPhone app: its Electronics space lets you place parts
on a schematic, wire pins, update the board, route connections on front or back copper, read
ERC and DRC findings and export a `.kicad_pcb` file for KiCad. It runs on the PCBCraft Rust
engine, and the same app can send the board into a 3D design. It is early: only four built-in
part kinds, and you build the app from source with Xcode.

## What you can do in the Electronics space

From `apple/Touch/TouchPCBView.swift` and `apple/Shared/Model/PCBModel.swift`:

| Step | On iPad and iPhone |
|---|---|
| Open | Project sidebar, then Electronics |
| Place parts | Resistor, capacitor, LED, connector (the engine's built-in kinds) |
| Connect | Wire tool: tap a first pin, then a second |
| Board | Update: syncs the board from the schematic (`board.sync`) |
| Route | Route one connection pad to pad, or Route All airwires; switch between `F.Cu` and `B.Cu` |
| Edit | Rotate, Delete, Undo, Redo |
| Check | Checks sidebar: ERC and DRC findings |
| Parts list | Parts sidebar |
| 3D | Send to 3D Design or Update 3D Board, then Mount on a Part |
| Export | Export KiCad: writes a `.kicad_pcb` and offers a Share button |

On iPhone the tool column becomes a horizontal row and the sidebars open as sheets.

## Limits today

- Parts are the four built-in kinds; KiCad library parts are listed as next in the README.
- The iPad app has no save for the PCB project yet; export the board as `.kicad_pcb`. The Mac
  app opens and saves PCBCraft projects, and the Electron app saves design and board together
  as one `.viaform` file.
- No published build: install from Xcode onto your own device.

## Build and install

```bash
git clone https://github.com/soma-intelligence/ViaForm.git
cd ViaForm
git submodule update --init --recursive
rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin
scripts/build-bridge.sh
cd apple && xcodegen generate && open SolidCraftNative.xcodeproj
```

Run the `SolidCraft-iOS` scheme on an iPad or iPhone with iOS 17 or later, after choosing your
team under Signing. The app is listed as SolidCraft on the home screen.

## Related

- [Link a PCB to the 3D model](link-pcb-to-3d-model.md)
- [ViaForm vs KiCad](viaform-vs-kicad.md)
- [Open source Shapr3D alternative for iPad](open-source-shapr3d-alternative-ipad.md)
- [README](../../README.md)
