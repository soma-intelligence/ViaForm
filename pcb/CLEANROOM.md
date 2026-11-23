# Clean-room log: `pcb` (viaform-pcb)

Rules followed (RUST-ENGINES 3B.1): no file under `engines/` was opened, read, searched or
listed; no KiCad source code and no GPL or LGPL source was read; PCBCraft was not looked up on
the web. The implementation is new and written from the sources below only.

## Task 1: first version (2026-11-22)

Sources consulted, all allowed by 3B.1 rule 2:

| Source | What it gave |
|---|---|
| `docs/specs/RUST-ENGINES.md` sections 0 to 2 and 3B | Scope v1, parity checklist 3B.3, conventions (errors with codes, determinism, licences, allowed crates) |
| `docs/specs/VIAFORM-SPEC.md` section 7.4 | Electronics stage purpose and acceptance additions |
| `bridge/include/viaform.h`, the `pcb_*` and `vf_link_*` declarations only | The C ABI surface: `pcb_execute(id, params_json)`, `pcb_inspect`, `pcb_checks`, `pcb_commands`, reply shape `{"ok"}` / `{"error"}` |
| `apple/Shared/Engine/PCBEngine.swift`, `apple/Shared/Model/PCBModel.swift` (ViaForm UI code) | Command ids and parameters the UI sends, the JSON shapes of `pcb_inspect` and `pcb_checks` the UI decodes |
| `apple/Shared/Library/LibraryModel.swift`, `apple/Desk/StageActions.swift`, `apple/Desk/DeskSamples.swift` (ViaForm UI code, PCB call sites only) | `component.place_library`, `footprint.assign`, `component.add` with `value`, Send to 3D and mount flow |
| `electron/src/test/drone.ts` (ViaForm's own sample and test) | The drone flight controller sample (parts, nets, layout, board size, holes), the commands it uses, the pad rotation convention it relies on |
| dev-docs.kicad.org, "Board File Format" and "S-Expression Format" pages (public documentation) | `.kicad_pcb` structure: header, layers, nets, footprint, pad, segment, via, zone, Edge.Cuts graphics, uuid; `.kicad_sym` pin syntax and electrical types |
| General knowledge of the public Gerber X2 specification (Ucamco) and the Excellon drill format | Gerber header (FS, MO, TF attributes), apertures with TA attributes, D01/D02/D03, regions G36/G37, arcs G75/G03, object attributes TO.N and TO.P; Excellon header, tools, M30 |
| KiCad 8 layer ordinal table (public format knowledge) | Layer numbers in the `layers` block |
| crates.io metadata (`cargo info`) and the `i_overlay` README and public API docs (MIT OR Apache-2.0 crate) | Integer overlay API, contour conventions, coordinate limits |

Third-party crates (licence checked with `cargo info` and `cargo tree -f '{p} {l}'`, none links
C or C++):

| Crate | Licence | Use |
|---|---|---|
| `rstar` 0.14 | MIT OR Apache-2.0 | R-tree over copper items, holes and board edges (DRC, connectivity) |
| `i_overlay` 9.2 | MIT OR Apache-2.0 | Polygon union, difference, intersection on i64 nanometre coordinates (zones, Gerber fracturing) |
| `i_float`, `i_shape`, `i_tree`, `i_key_sort` | MIT | Dependencies of `i_overlay` |
| `heapless`, `hash32`, `num-traits`, `smallvec`, `stable_deref_trait` | MIT OR Apache-2.0 | Dependencies of `rstar` |
| `ordered-float`, `libm`, `zmij` | MIT | Transitive |
| `byteorder`, `memchr` | Unlicense OR MIT | Transitive |
| `serde`, `serde_json` | MIT OR Apache-2.0 | Facade and files |

Not consulted: `engines/pcbcraft/` (any file), the bridge implementation (`bridge/src`), KiCad
source, any GPL or LGPL code, any `board.pcbcraft` file.
