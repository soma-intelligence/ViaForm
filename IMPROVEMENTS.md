# Improvements

What could come next, front end first, then the core. Nothing here is done yet.

## Front end (this repo)

1. **Drag handles.** Shapr3D-style arrows on the picked face and on the extrude profile, dragged to set
   the distance (the value card stays for typing). The preview path already exists (`applyPreview`).
2. **Profile picking.** Click profiles of a sketch to extrude only some of them (`profiles:` parameter);
   today extrude takes all profiles of the last sketch.
3. **Sketch dimensions and constraints on canvas.** Draw dimension text from `sketch.glyphs` and edit
   values in place; drag points with `sketch.drag` live frames.
4. **Background scene build.** `sc_scene_build` runs on the main thread. Move it to a worker and
   double-buffer; big imports (STEP assemblies) will need it.
5. **GPU picking.** Render face and edge ids to an offscreen target instead of the CPU ray cast, for
   large meshes.
6. **Documents.** `DocumentGroup` on iOS and macOS (Files, iCloud, recent files, autosave through
   `doc.recovery_*`), multiple windows on the Mac.
7. **Native dialogs for more commands.** Hole, pattern, mirror, sweep, loft, joint and sheet metal get
   generated forms from the command schemas (`crates/engine/src/schema`) instead of raw JSON.
8. **Apple Pencil Pro.** Squeeze for the tool palette, barrel roll for rotation, hover preview.
9. **Section view, zebra, draft** through the scene's `clip` and `analysis` fields (already exported by
   the engine, not drawn yet).
10. **XCFramework + Swift package** for the bridge, so another app (the Soma iOS app, Matex) can embed
    the CAD view.

## Core (upstream, as pull requests to SolidCraft)

1. **An official C ABI crate.** Our bridge needs `unsafe`, which upstream forbids outside an allowlist.
   Proposing `crates/ffi` with the allowlist entry would let every native front end share it.
2. **A scene diff.** The scene is rebuilt whole on each change; a revision per body would let front
   ends re-upload only what changed.
3. **iOS in CI.** The core builds for `aarch64-apple-ios` today without changes; a CI job would keep it
   that way.

Upstream rules to respect for any PR: clean-room only, no GPL code read or copied, everything is a
command with schemas, `cargo xtask ci` before each commit (see `engines/solidcraft/AGENTS.md`).
