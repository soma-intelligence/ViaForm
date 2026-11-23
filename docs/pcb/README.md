# viaform-pcb

Clean-room PCB engine (crate `pcb/`, MIT OR Apache-2.0) that replaces the GPL PCBCraft
submodule (RUST-ENGINES 3B, decisions E-16 and D-12). Sources used are logged in
`pcb/CLEANROOM.md`; swap status is in `pcb/PARITY.md`.

## Layout

| Module | Role |
|---|---|
| `geom` | Integer nanometre points, millidegree angles, distances, polygon booleans (`i_overlay`) |
| `model` | Library, schematic (sheets, components, wires, labels, nets), board (outline, cutouts, footprints, pads, tracks, vias, zones, keep-outs), rules, net classes |
| `library` | Built-in parts and JSON library definitions |
| `netlist` | Net extraction from wires, net assignments, labels and power symbols |
| `copper`, `checks` | Copper primitives, R-tree (`rstar`), connectivity, ratsnest, ERC, DRC |
| `zones` | Zone fill with clearances and thermal reliefs |
| `router` | Two-layer grid A* with vias, rip-up and retry; single-connection walkaround |
| `fab` | Gerber RS-274X with X2 attributes, Excellon, BOM and pick and place CSV |
| `sexpr`, `kicad` | KiCad symbol and footprint import, board export and import |
| `engine` | `Session`: JSON commands, undo and redo, `.vfpcb` files, `inspect`, `checks`, `commands` |
| `sample` | The drone flight controller sample |

## Using it

```rust
let mut s = viaform_pcb::Session::sample();          // or Session::new()
s.call("route.auto", &serde_json::json!({}))?;        // -> {"result": {"routed": 23, ...}}
let reply = s.execute("check.drc", "{}");             // ABI shape: {"ok": ...} or {"error": ...}
let ui = s.inspect();                                 // what pcb_inspect returns
let rules = s.checks();                               // what pcb_checks returns
let tools = viaform_pcb::commands();                  // what pcb_commands returns
```

Lengths cross the facade in millimetres and are stored as integer nanometres. Creating commands
reply `{"result": {"id": N}}`; ids are unique across all objects of a project and never reused.
Mutating commands are atomic and make one undo step; read-only commands (checks, exports,
`file.save`) make none.

## File format `board.vfpcb`

JSON, `{"format": "viaform-pcb", "version": 1, ...}`, the `Project` structure with lengths in
nanometres and angles in millidegrees. Maps are sorted and lists keep insertion order, so the
same project always writes the same bytes. Files with a newer version are refused.

## Coordinates

Board: origin at the top left corner of the outline box, x right, y down, positive rotation
counterclockwise on screen (KiCad convention). Gerber, drill and pick and place files negate y
(Gerber frame, y up). Schematic pin offsets are as in the library (y up).

## Tests

`cargo test --release -p viaform-pcb`. `cargo run --release -p viaform-pcb --example route_sample`
routes the sample and prints the report and the checks.
