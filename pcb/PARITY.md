# Parity checklist (RUST-ENGINES 3B.3), status 2026-11-22

Gate for swapping PCBCraft out of the bridge. Tests: `cargo test --release -p viaform-pcb`
(33 tests, all green). Sample: `crate::sample` rebuilds the drone flight controller from
`electron/src/test/drone.ts` through the command facade.

| Item | Status | Test |
|---|---|---|
| Schematic drawn (12 parts, 12 nets, custom library parts) | Done | `sample_schematic_is_drawn_and_erc_clean` |
| ERC clean on the sample; ERC finds unconnected pins, conflicting drivers, undriven power pins, duplicate references, missing footprints | Done | same, `erc_finds_unconnected_and_conflicting_drivers` |
| Board updated from the schematic (footprints, pad nets) | Done | `sample_board_is_updated_and_placed` |
| Placed (move, rotate, flip) | Done | sample layout incl. J6 at 90 degrees; `kicad_export_round_trips` checks pad positions |
| Routed by the autorouter | Done: 23 of 23 connections, no vias needed, about 0.2 s | `sample_autoroutes_drc_clean` |
| DRC clean after routing | Done | same |
| DRC rules each detected (clearance, short, width, annular ring, drill, hole to hole, edge and cutout, outside board, unrouted, net class clearance) | Done | `drc_catches_each_rule`, `net_classes_widen_clearance` |
| Router: vias, rip-up and retry, walkaround `track.route`, keep-outs | Done | `router_uses_vias_to_cross_a_wall`, `router_rips_up_and_retries`, `track_route_walks_around` |
| Zones with clearance and thermal reliefs | Done | `zones_fill_with_clearance_and_thermals` |
| Gerbers that a public Gerber viewer opens without errors | **Open**: files are checked by a structural reader in the tests (header, apertures defined before use, regions closed, M02); no public viewer (gerbv, tracespace, Ucamco Reference Viewer) has opened them yet | `gerbers_and_drills_are_well_formed` |
| Excellon drill files | Done structurally (hit count matches pads plus vias); same viewer check open | same |
| KiCad export that KiCad 9 opens | **Open**: written as KiCad 8 (`version 20240108`) from the public docs, parsed back by our own reader with identical pads, tracks, vias, outline and zero DRC errors; KiCad is not installed here, so opening it in KiCad 9 is still to do. Zones are exported as outlines without fill (KiCad refills them) | `kicad_export_round_trips` |
| BOM and pick and place CSV | Done | `bom_and_pick_and_place` |
| Native file `board.vfpcb`, versioned, newer versions refused | Done | `save_and_open_vfpcb` |
| Undo and redo, atomic errors | Done | `undo_redo_and_atomic_errors` |
| Determinism (same input, same output) | Done for routing, file and Gerbers | `autoroute_is_deterministic` |
| Send to 3D | **Partly**: `link.geometry` returns outline, thickness, holes, copper polygons and part boxes; `vf_link_push` in `viaform-core` still reads a PCBCraft session and must be rewritten on this output | `link_geometry_for_send_to_3d` |
| Mount on a Part | **Open**: lives in `vf_link_mount` (core), unchanged until the bridge swap | none |
| Every PCB command used by the Apple and Electron UIs | **Mostly**: all ids found in the Swift UI and in `drone.ts` exist (`commands_listing_covers_the_swift_surface`). Not checked: the Electron UI sources beyond `drone.ts`, and whether `component.metadata` is a PCB command | listing test |

## Known gaps and differences

- Pad rotation follows KiCad and `drone.ts` (offset turned by minus the angle on the y-down
  board). `PCBFootprint.padPosition` in Swift turns by plus the angle; for symmetric two-pad
  parts the set of positions is the same but the pad numbers swap. Fix the Swift helper at swap.
- `pcb_inspect` adds fields (`labels`, `vias`, `zones`, `outline`, pad `geometry`, `drill`); the
  Swift decoder ignores unknown keys. Pad `diameter` is the larger pad dimension.
- Legacy `board.pcbcraft` migration on open: not written (needs sample files read as data).
- KiCad import: `.kicad_sym` symbols and `.kicad_mod` footprints, and `.kicad_pcb` boards. Not
  yet: `.kicad_sch` import and export, `.kicad_sym` and `.kicad_mod` export, IPC-356.
- Router: two layers only (4 layers and 150 nets not measured yet), no push and shove, no
  differential pairs, no length tuning. Track width per net class is used by `track.add` and
  `track.route`; `route.auto` uses one width for all nets.
- Zone fill: minimum width is enforced by area only (no erode and dilate), no hatch fill.
- Silkscreen layers are not exported (no text rendering).
- Buses, hierarchical sheets (one root sheet), and the `core::flow::Worker` job interface for
  long routes are not done.
- The bridge still links PCBCraft: the swap (`pcb_*` in `bridge/src` calling `Session::execute`,
  `inspect`, `checks`, `commands`, and `vf_link_*` and `vf_bom_call` in core reading `Project`)
  is the next step and is outside this crate.
