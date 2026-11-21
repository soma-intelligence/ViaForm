# What is a .viaform file and how do I read one?

A `.viaform` file is a ViaForm project: a standard zip archive holding three entries,
`viaform.json` (a manifest with the format name and version), `design.solidcraft` (the 3D
design, saved by the SolidCraft engine) and `board.pcbcraft` (the schematic and board, saved by
PCBCraft). Any zip tool can list and extract it. The current format version is `1`, and a file
with a higher version is refused with a message to update ViaForm.

The format is defined in `core/src/project.rs` (`viaform-core`). The Electron app saves and
opens it; the Swift apps save the design and the PCB project as separate files today.

## Layout

```
project.viaform  (zip, Deflate)
├── viaform.json       manifest
├── design.solidcraft  SolidCraft design file
└── board.pcbcraft     PCBCraft project
```

The manifest, written with pretty JSON:

```json
{
  "format": "viaform",
  "version": 1,
  "app": "0.2.0"
}
```

| Field | Meaning |
|---|---|
| `format` | Always `"viaform"`. Anything else is rejected with "not a ViaForm project". |
| `version` | Format version (`FORMAT_VERSION` in `core/src/project.rs`, currently `1`). |
| `app` | The `viaform-core` crate version that wrote the file. |

## How saving works

`project::save` asks SolidCraft to write the design (`file.save_as`, falling back to
`file.save`) and PCBCraft to write the project (`pcbcraft_io::save`) into a scratch folder,
zips the three entries into a sibling file with the extension `.viaform-part`, then renames it
over the target. A crash mid-save leaves the old file in place.

## How opening works

`project::open` checks, in order:

1. The file is a zip (otherwise "not a ViaForm project: ...").
2. `viaform.json` exists and `format` is `"viaform"`.
3. `version` is not above `FORMAT_VERSION`. A newer file gets: "this project was saved by a
   newer ViaForm (format N); update ViaForm to open it".
4. `design.solidcraft` and `board.pcbcraft` both exist ("... is missing from the project").

It then loads both into a fresh workspace and swaps it in, so a failed open leaves the current
project untouched. The board to 3D link survives a round trip because the link state lives in
the design (component metadata), as the core test `a_project_round_trips` checks.

## Inspect a file from the command line

```bash
unzip -l project.viaform
unzip -p project.viaform viaform.json
```

## Use it from code

Node, through the addon the Electron app ships (`node/`):

```js
const native = require("./electron/native/viaform.node");
const w = new native.Workspace(true);  // true: start from PCBCraft's sample board
w.save("/tmp/demo.viaform");
const back = new native.Workspace(false);
back.open("/tmp/demo.viaform");
console.log(native.versions().format);  // 1
```

Build the addon first with `cd electron && npm ci && npm run native`.

In the Electron app, File > Save (Cmd/Ctrl+S) and Save As write `.viaform`, File > Open reads
it, and packaged builds register the `.viaform` extension as a "ViaForm project"
(`electron/electron-builder.yml`).

## Related

- [Architecture of the Rust core and FFI](architecture-rust-core-ffi.md)
- [Link a PCB to the 3D model](link-pcb-to-3d-model.md)
- [Build ViaForm from source](build-from-source.md)
- [README](../../README.md)
