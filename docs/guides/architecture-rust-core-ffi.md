# How is ViaForm built: the Rust core, the C ABI bridge and the Node addon

ViaForm has one Rust core, `viaform-core` (`core/`), that holds a SolidCraft CAD session and a
PCBCraft PCB session side by side and owns everything joining them: the board to 3D link, the
`.viaform` file and the GPU-ready scene. Two thin bindings expose it: `solidcraft-ffi`
(`bridge/`, a C ABI static library) for the SwiftUI apps, and `viaform-node` (`node/`, an
N-API addon) for the Electron app. Front ends do every edit by sending command ids with JSON
parameters to the engines.

## Diagram

```
 SwiftUI apps (apple/)                      Electron app (electron/)
 Desk (macOS)  Touch (iOS)                  renderer (three.js) --IPC--> main process
        |  Metal                                                          |
        v                                                                 v
 bridge/  solidcraft-ffi                    node/  viaform-node
 staticlib, C header solidcraft.h           cdylib loaded as viaform.node (napi 3)
        \                                       /
         \------------> core/  viaform-core <--/
                        Workspace { cad, pcb }
                        link.rs  project.rs  scene.rs
                             |             |
          engines/solidcraft (git submodule)   engines/pcbcraft (git submodule)
          solidcraft-engine                    pcbcraft-engine, pcbcraft-io
```

## Cargo workspace

The root `Cargo.toml` is one workspace with members `core`, `bridge` and `node`, version
`0.2.0`, edition 2024, license `GPL-3.0-or-later`. The engines are excluded (they are
workspaces of their own) and pulled in by path. The root also applies the same
`[patch.crates-io]` entries for vendored `truck-*` crates that SolidCraft uses, because patches
only apply from the root workspace.

## core/ (viaform-core)

| File | Role |
|---|---|
| `src/lib.rs` | `Workspace { cad: solidcraft_engine::Session, pcb: pcbcraft_engine::Session }`; `cad_execute`, `pcb_execute` (adds `undo`, `redo`, `file.open`, `file.save`, `file.export_kicad` on top of PCBCraft's commands), `pcb_revision`, `link_state` |
| `src/link.rs` | Board to 3D: `push` builds or rebuilds the board component, `mount` seats it on a face with a rigid group, `linked_revision` reads the tag |
| `src/project.rs` | The `.viaform` zip: `save`, `open`, `FORMAT_VERSION = 1` |
| `src/scene.rs` | Flattens SolidCraft's render scene to `f32` and `u32` buffers (positions, normals, indices, per-triangle B-rep face ids, edge polylines) for Metal and WebGL |

## bridge/ (solidcraft-ffi, for Swift)

A `staticlib` with the header `bridge/include/solidcraft.h` and a Clang module map, built by
`scripts/build-bridge.sh` for `aarch64-apple-darwin`, `aarch64-apple-ios` and
`aarch64-apple-ios-sim`.

| Group | Functions |
|---|---|
| CAD session | `sc_session_new`, `sc_session_free`, `sc_execute`, `sc_run_script`, `sc_commands`, `sc_home_camera`, `sc_bounds`, `sc_sketch_plane` |
| Scene | `sc_scene_build`, `sc_scene_free`, `sc_scene_radius`, `sc_scene_background`, `sc_scene_mesh_count`, `sc_scene_mesh`, `sc_scene_body_name`, `sc_scene_line_count`, `sc_scene_line` |
| PCB session | `pcb_session_new`, `pcb_session_free`, `pcb_execute`, `pcb_inspect`, `pcb_checks`, `pcb_commands` |
| Link | `vf_link_push`, `vf_link_mount`, `vf_link_revision` |
| Memory | `sc_string_free` frees every `char*` the library returns |

Conventions: strings cross as UTF-8 C strings; commands answer JSON `{"ok": ...}` or
`{"error": ...}`; every entry point catches panics so an engine panic never unwinds into Swift;
scene pointers (`ScMeshView`, `ScLineView`) stay valid until `sc_scene_free`. The Swift side
holds a CAD session and a PCB session and passes both to the `vf_link_*` calls.

## node/ (viaform-node, for Electron)

A `cdylib` built with napi 3 (`napi8` feature). `electron/scripts/build-native.mjs` copies it to
`electron/native/viaform.node`; packaged apps load it from the resources folder, outside the
asar archive.

```ts
const native = require(".../viaform.node");
native.versions();            // { core, solidcraft, pcbcraft, format }
const w = new native.Workspace(sample?: boolean);
w.cad(id, params?)            // design command, throws the engine's message
w.pcb(id, params?)            // PCB command
w.pcbInspect(); w.pcbChecks(); w.commands(); w.bounds(); w.sketchPlane();
w.scene();                    // meshes and lines as Float32Array / Uint32Array
w.linkPush(); w.linkMount(body, point, normal); w.linkState();
w.save(path); w.open(path);   // .viaform
```

`node/build.rs` records each engine's `git describe` as `VIAFORM_SOLIDCRAFT` and
`VIAFORM_PCBCRAFT` for `versions()` and the About box. In the app, only the main process holds
the `Workspace`; the preload script exposes `window.viaform` (`electron/src/shared/api.ts`) and
replies arrive as `{ok}` or `{error}`.

## Why the commands-only design matters

Every action, from a toolbar click to the command palette, is an engine command id plus JSON
parameters. That keeps the Swift and Electron front ends thin, lets `sc_commands` and
`Workspace.commands()` drive a searchable command list, and keeps the board to 3D link
identical on every platform because it lives in the core.

## Testing

- `cargo test --release -p viaform-core`: project round trip, newer format refused, link push,
  mount and update keeping the joint.
- `npm test` in `electron/`: the same flows through the addon under plain Node.
- CI runs both on macOS, Ubuntu and Windows (`.github/workflows/ci.yml`).

## Related

- [The .viaform file format](viaform-file-format.md)
- [Link a PCB to the 3D model](link-pcb-to-3d-model.md)
- [Build ViaForm from source](build-from-source.md)
- [README](../../README.md)
