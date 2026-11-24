# ViaForm UI and UX audit (Mac and iPad)

Date: 2026-11-22. Scope: `apple/` (SwiftUI, macOS and iPadOS targets). Read only: no file under `apple/` was changed and nothing was built. Evidence comes from the code (line numbers as of this date, on top of the uncommitted work of the Assemble and arm Simulate agent) and from the captures in `docs/specs/screens/phase1/`.

Standards: Apple HIG for macOS and iPadOS (Liquid Glass era), the owner's premium checklist, pro CAD tool norms (Fusion, Onshape, Shapr3D, Blender, Figma), and the ViaForm design system (`ThemeTokens.swift`, VIAFORM-SPEC 6, FRONTEND-SPEC 5 and 7).

## Summary

The shell is in good shape: the workspace dropdown (D-10), the token file with a WCAG test, the status words on `VFStatusDot`, the Workspace menu with Command-digit shortcuts, the command palette, and tooltips on most ribbon buttons. The problems are underneath.

1. **Reliability (P0).** Undo goes to the wrong document. Nothing stops you closing, opening or creating a project over unsaved work, and a failed save says nothing. Deletes in the BOM, Library and timeline cannot be undone and are not confirmed. Several engine and network calls block the main thread, and one freezes the app on Stop. Esc can kill a 10-minute solve. The robot e-stop has poor contrast in dark mode and shows safety limits that are not real.
2. **No component library (P1).** None of the FRONTEND-SPEC 5 components exist (`NumberField`, `ConfirmSheet`, `EmptyState`, `Toast`, `InlineError`, `KVRow`, `CostLine`, `StatusDot`, `JobCapsule` controls). Each screen rebuilds its own, so states, colours and verbs drift. Generate, Simulate, Touch legacy panels and PCB bypass tokens: 221 `.font(.system(size:))`, 60 `Color(red:)`, about 100 raw `.red/.orange/.green`, 61 literal corner radii.
3. **Accessibility and adaptation (P2).** No Dynamic Type (`VFFont` uses fixed sizes), no Reduce Transparency, no Increase Contrast, Reduce Motion read in one place only, no String Catalog (D-22), many icon-only controls under 44 pt on iPad, status told by colour alone in several places. The deployment target is macOS 14 and iOS 17, while D-11 says macOS 26 and iPadOS 26 with Liquid Glass; no `glassEffect` is used and materials sit on content panels.
4. **Signature polish (P3).** Stable button widths while loading, hover on iPad pointer, haptics, consistent precision, truncation.

Counts: **P0 18, P1 34, P2 26, P3 14** (92 findings).

### Top 10

1. P0-1 Menu Undo and Redo always act on the Design model (Cmd-Z in Assemble, Generate or Electronics undoes an invisible design edit) and replace the text undo of fields.
2. P0-2 No unsaved-changes protection: New, Open, template start, window close and Quit discard work silently.
3. P0-3 One `DesignModel` and `PCBModel` shared by every Mac window, while each window has its own flow, BOM and stage models.
4. P0-4 Save failures are silent (`ProjectFiles.save` returns false, nobody reads it).
5. P0-7 `SimTraining.cancel()` spins `Thread.sleep` on the main actor: Stop freezes the app.
6. P0-8 Generate Cancel is bound to Esc (`.cancelAction`), the same key that clears the selection.
7. P0-12 Robot e-stop: white on `#FF7B70` in dark is about 2.5:1, and "60 %" / "30 %" limits are hard-coded as if armed.
8. P0-10 BOM and Library deletes are instant with no undo and no confirm.
9. P1-1 Build the missing component library (NumberField with units and expressions first).
10. P2-1 Dynamic Type, Reduce Transparency and Increase Contrast handled once, in `VFFont` and `vfSurface`.

## Files owned by the other agent (do not touch until it lands)

Untracked or modified by the Assemble and arm Simulate work: `apple/Shared/Assemble/*` (including `MotionStudyPanel.swift`, `AssembleHand.swift`), `apple/Desk/AssembleRibbon.swift`, `apple/Shared/Sim/ArmSimModel.swift`, `ArmSimulationView.swift`, `PhysService.swift`, `apple/Shared/Generate/LoadsFromSimSheet.swift`, `apple/Shared/Robot/RobotSafety.swift`. Also modified in the working tree by that work: `Desk/ProjectWindow.swift`, `Desk/BrowserSidebar.swift`, `Desk/InspectorPanel.swift`, `Desk/RobotStage.swift`, `Shared/Flow/FlowModel.swift`, `Touch/TouchChrome.swift`, `Touch/TouchRobotStage.swift`. Findings in those files are grouped in batch 8 of the plan.

## Conventions

Each finding: **ID. file:line.** Rule broken. Impact. Fix. **[SC]** marks a shared-component fix (do it first, it removes many local findings). **[AO]** marks a file listed above (after the other agent). Line numbers come from this audit; recheck before editing because the other agent is moving lines.

---

## Status (2026-11-22, fix pass stopped by the owner)

The pass stopped after batches 1 to 7 and part of 8, when the owner split the remaining P0 work across parallel agents. The tree compiles: xcodegen runs, and clean macOS and iOS simulator builds succeed with no new warnings (16 and 35 lines against a baseline of 29 and 43). `--selftest` reports ALL PASS, `--flow-selftest` and the new `--robot-selftest` (21 checks) pass, and ViaFormThemeTests passes (13 tests). The screenshots in `screens/uiux/before/` were taken. The after set was not: the capture returned window 0, and the pass stopped before a retry. Nothing was checked by hand in the running app.

Shared components now in the tree:
- `Shared/UI/Components/NumberField.swift`: NumberField and NumberRow, with `submitNext` and `focusBinding` for focus order.
- `Shared/UI/Components/VFFormat.swift`: VFFormat, VFUnit and VFExpression, a safe parser with units.
- `Shared/UI/Components/Feedback.swift`: EmptyState, InlineError, ErrorBanner, DelayedProgress, SkeletonBlock, ToastCenter with `.toastHost`, and ConfirmRequest with `.confirmSheet`.
- `Shared/UI/Components/Controls.swift`: VFIconButton, `.vfTouch`, HoldButton, KVRow, MoneyText, `.vfDisabled(_:reason:)` and `.vfEngineGate()`.
- `Shared/UI/Components/Navigation.swift`: MousePreset, NavigationSettings and StageIntro.
- `Shared/UI/Components/SafetyBar.swift`: SafetyBar and EStopButton.
- `Shared/UI/Theme/ThemeSwiftUI.swift`: VFStatusDot (a shape per state, with a reason), button styles with a loading state, `.vfSurface(.control)` for Liquid Glass, and the Reduce Motion helpers.
- Per-window documents: `Desk/DeskCommands.swift` (DeskWindowRoot, DeskFocus, UndoTarget), `Desk/FileActions.swift` (FileActions, ProjectGuard, ProjectWindowGuard, the app delegate) and the ProjectFiles registry.
- `Shared/Resources/Localizable.xcstrings`: 1,770 keys, English and French. The French is a first pass in "tu" and needs owner review.

P0:
- P0-1 fixed. The menu, toolbar and palette undo the open stage's document (design, assembly, board, study) or the BOM when it was edited last. Touch does the same. Simulate, Train and Robot have nothing to undo, so the control is disabled.
- P0-2 fixed. Close, quit, open, new and template start ask Save, Don't Save or Cancel. The close button shows the edited dot. Touch New Design asks first.
- P0-3 fixed. Each window owns its design, board, BOM, flow and models.
- P0-4 fixed. A failed save shows an alert with Save As. Export reports failure.
- P0-5 to P0-7 fixed. In P0-7, `runToEnd` still sleeps, but only in the self-test path.
- P0-8 fixed. Esc no longer stops a run; Stop and Command-. do. A stop now keeps the best design so far: the engine answers the stopped variant's best iterate (feasible first, sharpest, lowest objective), analysed and surfaced, with `converged` false, `stopped_at` and `kept_iteration`, plus the variants already finished; `cancelled` only when no solid had formed yet. A run older than 30 s asks first (ConfirmSheet): Keep Best So Far (default), Discard, or Cancel, which keeps it running (the shared sheet names that button Cancel). The kept candidate reads "Stopped at iteration N" with a Not converged badge, in the strip, the results pane and its VoiceOver label. Tested in generative, the bridge (`a_stopped_job_keeps_its_best_design`, repeated cancel) and `--selftest`.
- P0-9 and P0-10 fixed.
- P0-11 fixed. Project save and open, bringing design or PCB parts into the BOM, the assembly and component file imports, the `.sc` save, the BOM export write and `flow.json` run off the main actor. The BOM queue holds the design and board sessions for the call (`CADEngine.withSession`, and `PCBEngine` now has a lock of its own). `flow.json` is written and read through a separate pipeline handle on a worker. `joint.list` runs on a worker, once per design revision (`DesignJoints`). The window shows "Saving" or "Opening" after 300 ms. A failed open shows an ErrorBanner with Try Again, and failed BOM actions show Try Again too. The Save, Don't Save, Cancel prompt and the failed-save alert now wait for the async save. `--selftest` times each action with `ActionTiming` (the click handler, plus the longest main-actor stall on a 4 ms heartbeat): click 0.1 ms or less, longest stall 1 to 4 ms for save, import, sync and `joint.list`, and 10 to 18 ms for open (it rebuilds the views). The budget is 100 ms. Debug builds log the figures under the `timing` category.
- P0-12 and P0-13 fixed.
- P0-14 fixed (2026-11-22). A `RobotLink` protocol (`Shared/Robot/RobotLink.swift`) with `SimulatedRobotLink`, a servo model capped by speed and torque. Every motion verb (jog, dragged pose, demo replay, Run on Robot, Mac and iPad) goes through one gate, `RobotSafety.submit` and `request`: it needs a link, no latched e-stop and this session's confirmation, sends the caps from `RobotSafety` and fences the targets. The e-stop turns torque off on the link at once, so motion stops within one tick; re-enable is the HoldButton and asks for a new confirmation. The Robot stage offers "Connect Simulated Robot". Covered by `--robot-selftest` and the `ViaFormRobotTests` target. The real bus and bridge links remain task P7-2. Follow-up after P0-VERIFICATION: the Mac Robot stage overflowed the window (unbounded wrapping text under a zero-width size query, and a telemetry row wider than the canvas); fixed and captured in `screens/uiux/after/robot-*.png` at 1280x800, 1600x1000 and 2560x1440, light and dark. Space while the e-stop is latched is left to the focused Re-enable Motors (P0-13). The ribbon Connect Robot connects the simulated robot, and Assemble's IK pose goes to the robot with Send Pose to Robot, through the same gate.
- P0-15 to P0-18 fixed.

P1:
- Fixed: P1-1 to P1-4, P1-9 to P1-11, P1-13 to P1-32 and P1-34.
- P1-5 fixed (2026-11-23). `core/src/commands.rs` gives 26 registry commands a typed parameter schema (key, label, kind: length, angle, number, integer, bool, enum, string, body, bodies, sketch, edges, faces, point, vector; unit, default, min, max, help, optional), listed by `sc_commands` as `schema` and by the `command.schema` command. `GenericCommandForm` draws them with `NumberField` (units and expressions), toggles, pickers, the body list and the viewport picks, sends lengths as `"12.5 mm"` and angles as `"30 deg"`, leaves untouched options to the engine, says what is missing inline, keeps a failed run in the form and names the button by the verb ("Run Fillet"). Commands without a schema keep the JSON form, now labelled Advanced. Tested in `core/tests/commands.rs` (every schema key is one the command takes; primitives, extrude, revolve, fillet, chamfer, shell, draft, hole, press pull, offset face, patterns, mirror, move, scale, combine, split, remove and planes run from form values) and `--selftest`.
- P1-6 to P1-8 fixed (2026-11-23). The legacy `DeskRootView` and `Shared/Render/*` are on tokens too: viewport and handle colours come from `viaFormTheme` (light, dark and Increase Contrast through `viewportTheme`), the Metal clear colour from `ViewportTheme.clearColor`, the flight scene from `VFSimSceneColors` (new `Theme/ThemeScenes.swift`), fixed-size symbols use the new `VFFont.icon`. No `.system(size:` and no `Color(red:` remain outside `Shared/UI/Theme` (24 and 23 before) except `Shared/Generate/GenerateScene.swift` (computed SceneKit colours, allowlisted). `scripts/lint-ui-tokens.sh` enforces it in CI (job `ui-tokens`), exceptions in `scripts/lint-ui-tokens.allow`. The legacy layout's own bar sizes are named in `LegacyMetrics`; not checked by eye in the running app.
- P1-12 fixed (2026-11-23). The engine did have `body.rename`; the core now runs it through `viaform_core::commands::rename_body` (trimmed, not empty, no line break or tab, not another body's name, one undoable step, the reason as a sentence). The Mac browser renames a body in place: Return or the Rename menu item opens a field, Return commits, Esc cancels, clicking away commits, a refused name stays open with the reason under it. The iPad browser renames from the row's context menu (a prompt that comes back with the reason when refused). Tested in `core/tests/commands.rs` and `--selftest`.
- P1-33 fixed (2026-11-23). `generative/src/solid/checks.rs` checks each candidate's surface: watertight (open edges), manifold (edges shared by more than two faces), bodies against the study's limit, wall thickness by ray casting against the process minimum (FDM 0.8, SLS 0.7, resin 0.5, milling and extrusion 1.0 mm; the wall 99 % of the surface reaches, so voxel knife edges do not read as hairlines), overhang area against the build direction for additive processes, trapped voids for powder and resin, triangle count; each with value, limit, unit, a sentence and the worst spot. `export::write` saves STL, 3MF or OBJ in place (STEP is not offered: a candidate is a mesh). The bridge answers both through `vf_generate_check_mesh` and `vf_generate_export_mesh`. The Outcomes screen (`Shared/Generate/GenerateOutcomes.swift`) sorts by mass, safety factor, stress, displacement, cost or iterations, draws mass against safety factor in Swift Charts with the Pareto front, a legend, the required factor, an audio graph descriptor and click to select, compares two candidates side by side with every difference signed and judged, lists the mesh checks per candidate (Show frames the worst spot) and exports from a save panel on the Mac or `fileExporter` on iPad, off the main actor, with failures inline and a retry. Inspector sections (7.10.1) fold with their state remembered and show complete, missing or error as an icon and a word (`GenerateSections.swift`). Tested in the generative and bridge crates and `--selftest`; captured in `screens/uiux/after/outcomes-light.png` and `outcomes-dark.png` at 1440x900. Checked by eye on iPad portrait (2026-11-23): the strip and the chart now stack when the panel is narrower than the chart plus two cards, so no card is cut. Not done: overhang, wall and tool access maps on the canvas.

P2:
- Fixed: P2-1 to P2-6, P2-8 to P2-11, P2-13 to P2-19, P2-21, P2-22, P2-24 and P2-25.
- P2-7 fixed (2026-11-23). The minimum window is 760 x 560 and every compact width is named in `Desk/CompactLayout.swift`. The stage ribbon folds its last groups into More (labelled, then icons, then one group at a time), keeping every command with its label, enabled state and reason. Under 1100 pt the inspector floats over the stage on a floating surface, opened by the same toggle and closed with Esc. Under 900 pt the sidebar collapses, and a choice the reader made at that width is kept. Tested in `--selftest`; captured in `screens/uiux/after/compact-760-light.png`, `compact-760-dark.png` and `compact-1000-light.png`. Not done: the Assemble ribbon has fixed tabs with no More fold, and Generate's study panel sits under the floating inspector at 760.
- P2-12 fixed (2026-11-23). The Design viewport gives VoiceOver one element per body (`Shared/Render/ViewportAccessibility.swift`), framed where the body shows on screen, with its name, visibility, volume, size and selected state, and the actions select, Frame and Hide or Show. Move has X, Y and Z fields with units on Mac and iPad.
- P2-20 fixed (2026-11-23). Toast, InlineError and ErrorBanner (both severities) and the stale stage banner pairs are tested in every theme, including Increase Contrast. All pass AA with no token change.
- P2-23 fixed (2026-11-23). Settings has General, Navigation, Units and Privacy tabs, and the window resizes per tab. Units (length, angle, mass, decimal places) drive `VFFormat` and `NumberField`; the engine stays in mm, degrees and grams. Privacy has a usage data switch (off, and nothing is sent: there is no reporting code), Clear Recent Projects with a confirmation, and the data and cache folders. The iPad browser sheet has the same Units and Privacy sections. Not done: about 100 strings built by hand with a literal "mm" still ignore the unit setting.
- P2-26 fixed (2026-11-23). With Differentiate Without Color on, the stress legend shows worded bands (Low, At limit from 80 % of the limit, Over limit) with their MPa ranges, dots for At limit and a hatch with an outline for Over limit, and a line says how many regions are over the limit and how much of the surface they cover. Scene colours are unchanged. Captured in `screens/uiux/after/heatmap-dwc-light.png` and `heatmap-dwc-dark.png`.

P3:
- Fixed: P3-1 to P3-14.
- P3-14 fixed (2026-11-23). Both apps carry the Glass lattice icon (checked in the built bundles). iPad offers Default or Graphite in the browser sheet, with previews and an inline error if the change fails. About ViaForm (Mac app menu and iPad sheet) shows the version, the build, GPL-3.0-or-later and the engines and components with their licences and links, from one shared list (`Shared/UI/AboutCredits.swift`) checked by `--selftest`. MuJoCo is not listed: the app is built without it and only writes MJCF files. Captured in `screens/uiux/after/about-light.png` and `about-dark.png`. Checked on the iPad simulator (2026-11-23): the Graphite choice changes the home screen icon and About lists every entry. The small iPad view cube no longer overlaps its face words: they shrink to fit and a face too small to read stays blank.

## P0: reliability, data loss, safety

**P0-1 [SC] Undo goes to the wrong document.** `Shared/ViaFormApp.swift:37-40` replaces the Undo group with `model.undo()` on the Design model, always enabled except when the engine is shut. `Desk/ProjectWindow.swift:549-554` [AO] routes the toolbar buttons to Assemble, but the menu, the palette (`ProjectWindow.swift:391-392`) and Touch (`TouchRootView.swift:311-312, 363-376`, Cmd-Z in `TouchChrome.swift:328-329` [AO]) do not. Rule: HIG undo targets the focused context; FRONTEND 7.1 "everything is undoable". Impact: Cmd-Z in Assemble, Generate, Electronics or BOM undoes an unseen design edit; Cmd-Z inside a text field undoes the model instead of the typing; the menu item never greys out and never names the step. Fix: add an `undoTarget` to `DeskFocus` (`Desk/DeskCommands.swift:5-19`) with `canUndo`, `canRedo`, `undoName`, `undo`, `redo`, set per workspace by ProjectWindow; menu reads it, titles "Undo Extrude"; when a text field is first responder, do not replace `.undoRedo` (keep the system group and forward via `NSResponder` when no field has focus, or bridge the engine stacks into the window `UndoManager`). On Touch return `false` for stages without a stack and skip Cmd-Z while a field is focused.

**P0-2 No unsaved-changes protection.** `Desk/DeskRootView.swift:703-756` (`FileActions.open`, `newDesign`), `Shared/Flow/ProjectFiles.swift:46-62`, `Desk/ProjectWindow.swift:99-133` (template start calls `model.newDesign()`), `ViaFormApp.swift:17-23` (plain `WindowGroup`, no close or quit hook). `snapshot.dirty` exists (`Shared/Engine/DesignSnapshot.swift:45`) but only drives a dot in the legacy view (`DeskRootView.swift:205`). Rule: HIG documents: edited indicator in the close button, "Do you want to save" on close, quit and replace; checklist "protect edited forms from accidental close". Impact: one click on a template or Open loses hours of modelling. Fix: a `ProjectGuard.confirmDiscard(context) async -> Bool` sheet (Save, Don't Save, Cancel) called by New, Open, template start, close and `applicationShouldTerminate`; set `NSWindow.isDocumentEdited` from the dirty flag of design, PCB, BOM and flow; longer term move to `DocumentGroup` or NSDocument for autosave and Versions.

**P0-3 Multi-window shares half the state.** `ViaFormApp.swift:6-7` keeps one `DesignModel` and `PCBModel` at App level; `ProjectWindow.swift:17-24` [AO] creates a new flow, BOM, generate, assemble and sim per window. `ProjectFiles.current` is a static (`ProjectFiles.swift:19`). Rule: HIG multi-window, one document per window. Impact: Window > New Window or a tab shows the same design with a different pipeline; saving from one window writes the other's flow. Fix: create the design and PCB inside the window scene (a `ProjectSession` owning all models), pass it down; until then disable new windows (`.commandsRemoved()` for New Window and `.windowResizability`/`Window` instead of `WindowGroup`).

**P0-4 Silent save failure.** `Desk/DeskRootView.swift:720-726` ignores the Bool of `ProjectFiles.save` (`ProjectFiles.swift:27-34`); `model.save(to:)` and `export(to:)` report nothing either. Rule: checklist "error with retry"; FRONTEND 7.6. Impact: the user believes the project is saved. Fix: return a `Result`, show an alert with the reason and "Try Again" and "Save As…"; a success `Toast` "Saved" with Reveal on export.

**P0-5 Touch export overwrites and dead-ends.** `Touch/TouchRootView.swift:905-930` (`ExportSheet`): fixed 220 pt height, no Cancel or Done, error in red with no Retry, silently overwrites the same file name; `Touch/TouchPCBView.swift:201-206` KiCad export failure shows no sheet. Rule: VIAFORM-SPEC 6.4 (export overwrite confirmed), checklist. Fix [SC]: one shared `ExportFlow` (progress, success with Share/Reveal, error with Retry, overwrite confirm) used by both.

**P0-6 Two-finger tap undo fires everywhere.** `Touch/TouchTools.swift:481-491` installed on the window at `TouchRootView.swift:83`. Rule: no hidden-only action, gestures scoped to their surface. Impact: a two-finger tap on the BOM sheet, the palette or a form undoes the design underneath, with no feedback. Fix: attach to the viewport only, ignore while a presentation is up, show a toast "Undone: Extrude" (the Mac already flashes one, `ProjectWindow.swift:247-250`).

**P0-7 Stop freezes the app.** `Shared/Sim/SimModel.swift:305-313` loops `Thread.sleep(0.05)` on the main actor until the training iteration ends; `start()` calls it too. Fix: set `stopping = true`, let the poll task observe the end and clean up; show "Stopping…".

**P0-8 Esc kills a long solve.** `Shared/Generate/GenerateView.swift:170-173` binds Cancel to `.cancelAction`. FRONTEND 7.3 makes Esc clear the selection. Help text "Stop waiting for this run" is also wrong (the run stops). Fix: Cmd-. (spec 6.4, not implemented anywhere: no `keyboardShortcut(".")` in the app) for the current job; confirm a stop when the run is older than 30 s, with "Keep best so far".

**P0-9 Simulate replaces the Generate study.** `Shared/Sim/HandGraspView.swift:35` calls `generate.openSample("hand")`, which loads the first study (`GenerateModel.swift:421-429`) over the user's setup. Same family: template, sample and study taps replace the setup without asking (`GenerateModel.swift:176-182`, `GenerateProjectView.swift:17, 44`). Fix: read the hand project without touching `model.study`; otherwise `ConfirmSheet` "Replace the current study setup?" with Replace / Cancel, or make it undoable.

**P0-10 Destructive actions with no undo or confirm.** BOM: Remove Line and Remove origin (N lines) `Shared/Bom/BomView.swift:205, 287, 475`, no undo in `BomModel`. Library: delete saved part with its CAD files, Forget Keys, remove KiCad folder `Shared/Library/LibraryView.swift:174, 236, 280`. Touch timeline delete `TouchRootView.swift:511-514, 836`. Browser body Delete `Desk/BrowserSidebar.swift:201-205` [AO] (not `role: .destructive`). Generate case, region and impact removal `GenerateInspector.swift:174, 275, 313`. Rule: FRONTEND 7.1, HIG destructive role. Fix: undo via the engine plus `Toast` "Removed. Undo"; `confirmationDialog` naming the object and count for irreversible ones (Keychain, files on disk); `role: .destructive` on every delete.

**P0-11 Main thread blocking.** `BomModel.swift:276-283, 395, 542-571` (BomEngine synchronous: import, save, open, export); `SimModel.swift:146-153` (Run to the end: up to 120 `engine.advance` in a button action); `SimulationView.swift:69` with `SimModel.swift:88-91` (every option change restarts the flight synchronously); `FlowReporting.swift:33, 72-73, 156` (`joint.list` on every design revision); `GenerateModel.swift:480-489, 507-510` (joint drive per slider tick and per 80 ms play tick); `GenerateView.swift:149-154` (SceneKit thumbnails on main); `LibraryView.swift:273` (Keychain read inside `body`). Rule: spec 7.2 click to response under 100 ms; non-blocking runs. Fix: engine work in actors or detached tasks with a busy state; debounce option changes; throttle drives to display rate; move the Keychain read into `load()`.

**P0-12 Robot e-stop and limits.** `Desk/RobotStage.swift:118-122` [AO]: white "E-STOP" on `danger` `#FF7B70` in dark (`ThemeTokens.swift:267`), about 2.5:1, looks disabled in `robot-stage-1440-dark.png`. `RobotStage.swift:82, 84` and `InspectorPanel.swift:296-301` [AO], `TouchRobotStage.swift:14-20` [AO]: "60 %" and "30 %" speed and torque caps are literals shown as active. Touch e-stop is a non-interactive Label. Rule: FRONTEND 7.9 and SafetyBar spec, R-8. Fix [SC]: tokens `dangerFill` (`#C4261D` both themes) and `onDanger` with a contrast test in `Theme/Tests`; a shared `SafetyBar` with a real 44 pt Button on both platforms; caps read from `RobotSafety`, shown "n/a" with no robot.

**P0-13 Re-enable after e-stop.** `RobotStage.swift:149-158` [AO]: a `Text` with `onLongPressGesture`, 30 pt high, no progress, no keyboard focus, and the VoiceOver action re-enables at once. Fix [SC]: `HoldButton` (focusable Button, 1 s ring, static under Reduce Motion, 44 pt, VoiceOver action asks for confirmation).

**P0-14 Motion confirmation does not exist yet.** `Shared/Robot/RobotSafety.swift:10-43` [AO] has no `sessionConfirmed` or `moving`. Fix: add them now with tests, plus `ConfirmSheet` "Run on robot" and a `MotionFrame` red border, so P7-2 cannot ship without them.

**P0-15 E-stop keys swallowed by text focus.** `Desk/DeskKeys.swift:115` returns every key to a focused `NSText` before `ProjectWindow.handleKey` (`ProjectWindow.swift:297-300` [AO]) sees Space or Esc twice. Impact: while typing a value in the Robot inspector, Esc twice does not stop the robot. Fix: in the monitor, handle the Robot stage Esc-twice before the text check (Space can stay text).

**P0-16 Return commits the tool while typing.** `Touch/TouchStages.swift:73` puts `.keyboardShortcut(.return, modifiers: [])` on Done while a `ValueField` on the same screen has focus. Fix: Cmd-Return (spec 6.4), and plain Return commits the field only.

**P0-17 Generate state lost on return.** `GenerateView.swift:146-155, 306` with `ProjectWindow.swift:481-483` [AO]: thumbnails and camera are view `@State`; after a stage switch every candidate card spins forever. Rule: checklist "keep context on return". Fix: keep thumbnails and camera in `GenerateModel` keyed by `outcomeVersion`; render in `.task(id:)`.

**P0-18 Run pane locks itself.** `GenerateInspector.swift:27` disables the whole stack including the pane `Picker` (line 12) while a run is going: Results and Project are unreachable. Fix: disable only the form, show "Locked while the study runs. Stop to edit".

---

## P1: consistency and design system

### Shared components first

**P1-1 [SC] Component library missing.** FRONTEND-SPEC 5 lists `apple/Shared/UI/Components`; the folder does not exist. Build in this order, each with light and dark, hover, pressed, focused, disabled with reason, loading, error, VoiceOver label and value:
- `NumberField`: units (`25 mm`, `1 in`), expressions, preview of result, arrows step 1 / Shift 10 / Option 0.1, Esc reverts, Return commits one command, drag-scrub on the label, error beside the field. Replaces `Shared/UI/CommonViews.swift:4-50` `ValueField` (no units parsing, no Esc, `"%.3g"` precision, fixed 82 pt, steppers with empty label) and `GenerateInspector.swift:385-408` (no units, silent clamping at 393, empty title so VoiceOver reads nothing, `Vec3Row` 449-452). Also replace step-only controls with huge ranges (`GenerateInspector.swift:88-92, 104, 165, 178`; `SimulationView.swift:384-385`).
- `StatusDot`: one shape per state (filled current, triangle stale, xmark failed, ring running, hollow empty) plus text and reason. Today three systems: `Desk/PipelineBar.swift:147-168, 307-322` (system `.green/.orange/.red`, `.black`), `Shared/Flow/WorkspaceMenu.swift:100-124, 295-297` (badge white or black literal), `VFStatusDot` (`ThemeSwiftUI.swift:271-293`, stale and current are both filled circles).
- `InlineError` and `ErrorBanner(retry:)`: red for blocking, orange for warnings, a sentence that says what to do, Retry, Details disclosure. Replaces `MessageBanner` (`CommonViews.swift:110-131`, orange for errors, never dismisses), Generate orange errors (`GenerateView.swift:244`, `GenerateLive.swift:209`), Simulate red (`SimulationView.swift:119, 318, 356, 414`), Library and BOM messages (`LibraryView.swift:26-35`, `BomView.swift:357-359, 562`), raw engine text ("start: the options did not parse", `SimEngine.swift:22, 28`), the fragile `"cancelled"` match (`GenerateModel.swift:271`).
- `EmptyState` (icon, one sentence, one action) and `ContentUnavailableView.search` for no results.
- `Toast` (bottom, 3 s, Undo or Reveal), `ConfirmSheet` (verb buttons, never OK), `KVRow` (multi-line value allowed), `CostLine` and `MoneyText`, `HoldButton`, `SafetyBar`, `VFIconButton(symbol:label:)` (label mandatory, 44 pt minimum on iOS, hover effect), `ChartPanel` (legend, playhead, chart descriptor).

**P1-2 [SC] Primary button style.** `ThemeSwiftUI.swift:328-342` `VFPrimaryButtonStyle`: 24 pt min height on iPad, no hover, no focus ring, no loading state. Fix: platform height (`VFSize.touchTarget` on iOS), hover, `isLoading` that overlays a spinner and keeps width (also fixes P3-1).

**P1-3 [SC] Job controls incomplete.** `Shared/Flow/FlowReporting.swift:91-92` registers Generate with cancel only and no progress, so the toolbar capsule and the jobs list lack pause and n of total, while the canvas panel has them. Cancel glyph and verb vary (`stop.fill`, `xmark.circle.fill`, "Stop", "Cancel": `PipelineBar.swift:481`, `GenerateLive.swift:25`). Fix: pass pause and resume and call `flow.progress(job:done:total:)`; one glyph and the verb "Stop" everywhere; Cmd-. stops the focused job.

**P1-4 [SC] Disabled without a reason.** Every `.disabled(EngineGate.shared.shut)` (`ViaFormApp.swift:29-39`, `ProjectWindow.swift:179, 190, 507` [AO], `GenerateView.swift:191`, `GenerateProjectView.swift:92`, `HandGraspView.swift:153`, whole Touch capsule `TouchRootView.swift:323`) and palette rows at 0.45 opacity (`Desk/CommandPalette.swift:133`, Return does nothing at 147). Fix: a `.vfDisabled(reason:)` modifier adding `.help` and an accessibility hint; one engine banner "ViaForm core stopped. Restart" with an action.

**P1-5 [SC] Generic command form asks for JSON.** `CommonViews.swift:52-108`: the user types raw JSON parameters and confirms with "OK". Rule: pro norms (typed fields), FRONTEND 5 ConfirmSheet "never OK". Fix: generate fields from the command's parameter schema with `NumberField`; button named by the verb ("Run Fillet").

### Tokens bypassed

**P1-6 [SC] Hard-coded type.** 221 `.font(.system(size:))` outside `VFFont`. Hot spots: `Desk/StageRibbon.swift:68, 168, 293, 361`; `Desk/DesignOverlays.swift:26, 31, 43, 47, 76` (sizes 8, 10.5, 12.5, 15); `Desk/BrowserSidebar.swift:105, 114, 181-182, 242, 268` [AO]; `Desk/InspectorPanel.swift:370, 397` [AO]; `Desk/ProjectWindow.swift:681` [AO]; `Desk/DeskPCBView.swift:94-103, 217, 296`; `Desk/DeskPanels.swift:204, 215, 237`; `SimulationView.swift:174, 430, 445` and `HandGraspView.swift:110, 123` (10 pt bold captions instead of `VFCaption`); Touch `TouchChrome.swift:110, 112, 125, 160` [AO], `TouchTools.swift:52, 222, 255, 352`, `TouchRootView.swift:587, 613`. Fix: map to `VFFont`, add `VFFont.glyph(_ size:)` for SF Symbols inside chips; a CI grep rule forbidding `.system(size:` outside `Shared/UI/Theme`.

**P1-7 [SC] Hard-coded colours.** 60 `Color(red:)`, about 100 `.red/.orange/.green/.blue/.yellow`, plus `Color.accentColor` and `.white` on accent. `ViaFormApp.swift:46` and `Desk/DeskCommands.swift:122` tint with literals; the iOS root never applies `.viaFormTheme()` (`ViaFormApp.swift:44-47`), so Touch reads the environment default (light) rather than the user's setting. Generate and Simulate never read `viaFormTheme` (`GenerateLive.swift:39-41, 195-196`, `GenerateView.swift:313, 338-339`). Touch legacy panels (`TouchRootView.swift:495-848`: ToolRail, HistorySidebar, ItemsPanel, HistoryBar, SuggestionBar, PlaneChooser), `TouchPCBView.swift:114-115, 123, 159-171, 179-180, 188, 196`, `ViewCube` colours (`TouchRootView.swift:266, 333`, white in dark mode), PCB palettes (`Shared/UI/PCBCanvas.swift:32-43, 372-384`). Fix: `.viaFormTheme()` on the iOS root; theme colours everywhere; move PCB colours into a `pcbPalette` token set with a high-contrast variant.

**P1-8 [SC] Radii, spacing and sizes.** 61 literal radii (Touch 28, 22, 20, 18, 16, 11, 10: `TouchChrome.swift:75`, `TouchTools.swift:28, 56, 227, 245, 363, 451`, `TouchRootView.swift:352`, `TouchSheets.swift:239`; Generate and Simulate HUD cards `cornerRadius: 12` and `.padding(12)`: `GenerateView.swift:137-141`, `GenerateLive.swift:47-48`, `SimulationView.swift:190-191`; `ProjectWindow.swift:155` radius 13 [AO]). Inspector widths 340 (`GenerateView.swift:64`, `SimulationView.swift:63`) and min 260 (`ProjectWindow.swift:225` [AO]) versus `VFSize.inspector` 280. Browser rows 24 pt (`BrowserSidebar.swift:125, 185` [AO]) versus `VFSize.macRow` 29. Magic offsets `ProjectWindow.swift:156, 234, 516` [AO] (72, 90, 80). Fix: add `VFRadius.capsule` and `touchFloating`, use `vfSurface(.floating)` for every HUD; tokens for overlay offsets.

**P1-9 Theme default contradicts D-20.** `ThemeTokens.swift:69-70` defaults to Light; D-20 says follow system. The Settings help repeats it (`ThemeSwiftUI.swift:147`). Fix: default `.system`; keep Light as the screenshot override.

**P1-10 Legacy layout in Settings.** `Desk/DeskCommands.swift:105-146` and the 757-line `DeskRootView.swift` (forced dark, own tint). Impact: a second, unmaintained UI one toggle away; undo, file and token fixes must be done twice. Fix: drop the toggle and the view (keep `FileActions`, moving it to its own file).

### Shell, selection and commands (Mac)

**P1-11 Selection model differs per surface.** Viewport: Shift or Control click adds, Command click is ignored and Command drag pans (`Shared/Render/Viewport.swift:145, 154, 166`); Browser body click toggles (`BrowserSidebar.swift:198` [AO]); flow rows replace (`BrowserSidebar.swift:129`). FRONTEND 7.3: click selects, Shift adds, Cmd toggles; Control click on the Mac is a secondary click. Fix: one `SelectionGesture` rule (replace / add / toggle) shared by viewport, browser, BOM table and outline; Control click opens the marking menu.

**P1-12 Browser is not a real list.** `BrowserSidebar.swift:90-131, 160-215` [AO]: `onTapGesture` rows, no `List(selection:)`, so no arrow keys, no type-select, no multi-select, no rename (Return), no Delete key, no focus ring. Planes sketch only by double-click (line 170), sketches have no single-click action (212-213), context menu shows Hide and Show together. Rule: HIG sidebars and outline views; FRONTEND 7.8 full keyboard. Fix: `List(selection:)` with `OutlineGroup`, `.contextMenu(forSelectionType:)`, `.onDeleteCommand`, rename on Return, only the relevant of Hide or Show.

**P1-13 Trackpad mapping differs from the spec.** `Viewport.swift:213-219`: Shift two fingers orbits; FRONTEND 7.4 says Option. D-21 mouse presets in Settings do not exist (`DeskSettingsView` has Appearance and Legacy only). Fix: align with the spec and add presets (ViaForm, Fusion, Onshape, Blender) in Settings with a diagram.

**P1-14 Missing shortcuts from spec 6.4.** No Cmd-. (stop job), no Esc-to-clear on Touch, Touch lacks Cmd-Return, Shift-Cmd-U, Opt-Cmd-I, Shift-Cmd-B, Shift-Cmd-L, Cmd-/ (`TouchChrome.swift:326-334` [AO]); `PipelineBar.swift:90` still says "Command-1 to Command-8" for nine stages. Mac BOM and Libraries shortcuts live on toolbar buttons only (`ProjectWindow.swift:566-573` [AO]) so they do not appear in a menu. Fix: a View menu (Show Sidebar, Inspector, Bottom Panel, BOM, Libraries, Flow Graph, standard views, Zoom to Fit) and a Job menu item "Stop Job ⌘."; same `.keyboardShortcut` set on iPad so the Cmd-hold overlay lists them, grouped.

**P1-15 Help menu empty.** No `CommandGroup(replacing: .help)`; FRONTEND 7.7 asks for local help per stage. Fix: Help items "ViaForm Help", "<Stage> Help", "Keyboard Shortcuts".

**P1-16 Overlays are not modal.** Command palette and shortcut sheet are `ZStack` overlays with a 0.001 opacity tap catcher (`ProjectWindow.swift:228-245` [AO]). VoiceOver can reach the canvas behind, focus is not trapped. Fix: `.accessibilityAddTraits(.isModal)` on the card, `.accessibilityHidden` behind, or present the palette as a borderless panel; Esc closes both (check shortcut sheet Esc path, `ProjectWindow.swift:291`).

**P1-17 Several primaries at once.** Capture `workspace-dropdown-1440-light.png`: "Re-run on Model v13" in the ribbon, the stale banner and the inspector, all accent filled. FRONTEND 7.1: one primary per context. The banner says "Waiting on Frame v12" but offers "Re-run on Model v13"; spec 6.0 says the action names the input revision. Fix: banner keeps the primary, ribbon and inspector use bordered; action text built from the same input as the reason.

**P1-18 Bottom panel not resizable.** BOM fixed at 420 pt (`ProjectWindow.swift:165` [AO]); the toggle shows the same symbol in both states (line 460). Fix: a draggable divider with min and max and remembered height; filled or outline symbol by state.

**P1-19 Palette details.** Rows use `onTapGesture` (`CommandPalette.swift:79`, no button trait); hover moves the keyboard cursor while typing (`:80`); revision list stops at 8 with no "Show all" (`PipelineBar.swift:437`); workspace menu keyboard and hover highlights can both show (`WorkspaceMenu.swift:222`); handoff to the flow graph waits a fixed 0.2 s (`WorkspaceDropdown.swift:39`). Fix: Buttons, hover only highlights, typing a digit jumps to the stage.

### Screens

**P1-20 Generate run readiness.** `GenerateView.swift:175`: Run never checks for a support and a load; VIAFORM-SPEC 7.10.1 wants Run disabled with the missing section named and a check line under Run. Fix: `model.readiness` returning the reason.

**P1-21 Units missing or unclear.** Variant table "δ max", "f1", "SF", "$" (`GenerateLive.swift:180-207`); result columns are units alone (`GenerateResults.swift:115-118`); "Clearance 4.00 mm" next to "4.0 mm room" (`ElectronicsOverlays.swift:58`); Push/Pull field "12" next to the handle "12.00 mm" (`design-handles.png`). FRONTEND 7.5 precision (0.1 mm, 0.1 degree, money 2 decimals). Fix [SC]: one `VFFormat.length/angle/mass/money` used by every label and field.

**P1-22 Money and unknown values.** `BomModel.swift:599-601` uses 3 decimals under 1 and returns "" for missing; `BomView.swift:61` shows unknown cost as "0"; `BomView.swift:181` raw ISO dates. Fix: `MoneyText` 2 decimals, "No price" text and count of unpriced lines, relative dates with full date in the tooltip.

**P1-23 BOM editing.** Qty is free text with silent revert, no number keyboard, lost on blur (`BomView.swift:146, 376, 515`); notes Save button appears and disappears, edits lost on row change (`:196-200`); context menu acts on the first id only, no Copy (`:470-477`). Fix: `TextField(value:format:)`, commit on blur and on selection change, inline "Whole number, 0 or more", `Set` selection with batch actions and `.copyable`.

**P1-24 BOM price refresh.** `BomModel.swift:488-516`: sequential, not cancellable, stops at the first network error, no offline state; label width jumps (`BomView.swift:290-293`). Fix: cancellable task, per-line errors, "38 checked, 2 failed (offline). Retry failed", `NWPathMonitor`, fixed-width button with determinate progress.

**P1-25 Library states.** `LibraryView.swift:64, 69-85`: no first-search invitation, one "Nothing found" per source, source errors without Retry or offline label, spinner pushes the field; `LibraryModel.swift:228-230` key status wrong on first load. Fix: `EmptyState`, aggregate no-result, per-source error with Retry, reserved spinner slot and dimmed stale hits.

**P1-26 Start window.** `Desk/StartWindow.swift:265-272, 147`: "Product" chip shows an empty grid; `:113-140` the hero prompt answers "not in this build". Fix: hide empty filters or show `EmptyState`; hide the prompt behind a flag or mark it "Coming soon" and disabled.

**P1-27 Touch tool UI duplicated.** `TouchRootView.swift:647-710` (ToolCard) and `TouchStages.swift:27-108` implement the same tool session twice; iPhone buttons 34 pt (`TouchRootView.swift:675-677`). Fix: one `ToolSession` view.

**P1-28 Touch actions only by long press.** "Roll Back Here" only on HistoryBar long press (`TouchRootView.swift:834-837`) while HistorySidebar uses swipe for Delete and Suppress (`:511-514`); no context menu on Items rows or the viewport (FRONTEND 7.4 long press = context menu). Fix: same actions as `.contextMenu` and visible buttons in both views.

**P1-29 Strings that leak internals.** "Surfacing", "Stop below change", "Projection sharpness", "Robust threshold shift" (`GenerateInspector.swift:100-103`), JSON keys `mass_target_g` (`:108`) and `component_ref` (`GenerateProjectView.swift:100`), repo paths in empty states (`HandGraspView.swift:46`, `SimulationView.swift:322, 359`), "Look again" (`:325`), "Stopped by Button" (`RobotStage.swift:145` [AO]), "1 bodies" in the status bar (`ProjectWindow.swift:444` [AO], visible in `design-handles.png`), sample entries in the Touch browser (`TouchSheets.swift:52-53`). Fix: plain words with `.help` explanations, inflected plurals.

**P1-30 Close versus Done.** `TouchRootView.swift:880` CommandBrowser uses "Close"; Library and DeskPanels use a bare xmark with no label (`LibraryView.swift:18`, `DeskPanels.swift:206`); `ProjectWindow.swift:88` "Close Start" with xmark in the toolbar. Rule: HIG sheets: Done for viewers, Cancel plus verb for editors. Fix: Done in a toolbar `confirmationAction` for viewers, Cancel and verb for editors.

**P1-31 Status by colour in Electronics, BOM, Library.** Unsourced red only (`BomView.swift:418-419, 442, 448`), stock green or orange, source dot (`LibraryView.swift:154, 293`), F.Cu and B.Cu only red and blue (`PCBPanels.swift:61-71`), "board out of date" orange dot (`TouchPCBView.swift:113-116, 123`), untitled severity column (`BomView.swift:416-421`). Fix: icon or word next to colour, column title "Status", dashed pattern for B.Cu under Differentiate Without Color.

**P1-32 Heat map and charts.** Rainbow stress legend (`GenerateScene.swift:17-31`) where FRONTEND 7.8 asks viridis by default; training chart has no legend (`SimulationView.swift:395-404`); "over limit" only orange (`GenerateResults.swift:93-99`); live charts lack chart descriptors (`GenerateLive.swift:91`). Fix: `ChartPanel` with legend and descriptor, viridis default plus red-blue option, "Over limit" text and icon.

**P1-33 Outcomes screen incomplete versus 7.10.3.** No mesh checks, export, compare, sort or Pareto chart; inspector sections have no collapse or status icon (7.10.1). Track as feature work, not polish.

**P1-34 Flow graph overflows.** `FlowGraphView.swift:39-78` fixed widths without ScrollView; stale banner truncates failure text to one line with a 20 pt dismiss (`:170, 177`); long names only on hover (`:124`). Fix: scrollable graph that fits to width, two-line banner, 44 pt dismiss on iPad, names wrap.

---

## P2: adaptation and accessibility

**P2-1 [SC] Dynamic Type.** `ThemeSwiftUI.swift:153-171` fixed `.system(size:)` plus a +2 iPad bump; no `dynamicTypeSize` anywhere. FRONTEND 7.8 requires it on Touch. Fix: build `VFFont` on text styles (`.system(.body)`, `.caption`, with `relativeTo:` for custom sizes), `@ScaledMetric` for row heights and icon frames, cap chrome capsules at `.accessibility2`; remove fixed heights that clip (`RobotStage.swift:182, 198` [AO], `TouchChrome.swift:116` [AO] 80 to 210 pt title).

**P2-2 [SC] Reduce Transparency.** `vfFlatSurfaces` exists (`ThemeSwiftUI.swift:76`) but is never tied to `accessibilityReduceTransparency`; 104 raw materials bypass `vfSurface` (`CommonViews.swift:126`, `RobotStage.swift:29-31, 45` [AO], `StartWindow.swift:177`, `DeskPCBView.swift:86, 102`, Touch panels). Fix: set the flag in `ViaFormThemeRoot.Resolve` from the environment, route every material through `vfSurface`.

**P2-3 [SC] Increase Contrast.** No `colorSchemeContrast` read. Hairlines `#DADADA` and `#34373D`, `floatingStroke` 10 percent, `inkTertiary` stay faint. Fix: a high-contrast palette variant per theme (hairline, strokes, tertiary ink, selection) with tests in `Theme/Tests`.

**P2-4 [SC] Reduce Motion.** Read once (`WorkspaceMenu.swift:317`); `.animation` and `.transition(.move)` elsewhere (`ProjectWindow.swift:150, 161, 517` [AO], `TouchRootView.swift:86-87, 112, 256`, `TouchPCBView.swift:82`, `TouchChrome.swift:192` [AO]); camera fit animation. Fix: `View.vfAnimation(_:value:)` and `vfTransition` returning nil or opacity under Reduce Motion; camera jumps instead of flying.

**P2-5 Platform targets versus D-11.** `apple/project.yml:4-6` targets iOS 17 and macOS 14; D-11 sets macOS 26 and iPadOS 26 with Liquid Glass. No `glassEffect`, no `GlassEffectContainer`. Fix: raise targets (owner decision), then put glass only on navigation and controls: toolbar capsules, workspace dropdown, nav pill, context pill, Touch top capsule and tool rail, job capsule.

**P2-6 Glass and materials on content.** Touch HistorySidebar (`TouchRootView.swift:525`), ItemsPanel (`:808`), inspector card, PCB lists, Generate and Simulate HUD cards with result numbers. Rule: HIG Liquid Glass: never on content. Fix: opaque `theme.panel` for lists, tables, inspectors and result cards.

**P2-7 Window minimum size.** `ViaFormApp.swift:21` `minWidth: 1000, minHeight: 640`: macOS tiling at half of a 13 inch screen (about 735 pt) is refused. VIAFORM-SPEC 6.1 asks for a compact ribbon on 13 inch. Fix: about 760 x 560, with the ribbon folding into MORE, the inspector becoming an overlay, and the sidebar auto-collapsing under a threshold.

**P2-8 iPad Stage Manager and Split View.** Fixed widths: workspace popover 380 x 640 with a large empty area (`TouchChrome.swift:214` [AO], capture `ipad-workspace-dropdown.png`), cards 280 x 420 (`TouchRootView.swift:524, 807`), inspector 320, PCB lane 300 (`TouchPCBView.swift:29`). No `UIApplicationSceneManifest` multi-scene in `project.yml:33-44`. Fix: size to content with `maxHeight`, switch to the compact layout under about 820 pt width, declare multiple scenes once each scene owns its project (see P0-3).

**P2-9 Keep context with SceneStorage.** No `@SceneStorage` anywhere: stage, open panel, inspector mode, ribbon tab, bottom panel height, camera are lost on relaunch or scene restore (`TouchRootView.swift:38-57`, `ProjectWindow.swift:17-48` [AO]). Fix: SceneStorage for navigation and layout; camera per document.

**P2-10 Touch targets under 44 pt.** `TouchPCBView.swift:122, 187` (40), `TouchRootView.swift:546-550` (44 x 40), `:675-677` (34), `:736` (about 20), `:775-777` (eye, no frame), `:828, 840` (30), `:634-636`, `TouchSheets.swift:169`, `TouchChrome.swift:128` [AO] (36), `PCBCanvas.swift:62-66, 74` (30 x 28), `DeskPanels.swift:111, 252` (24 x 28), Flow banner dismiss (`FlowGraphView.swift:177`). Fix: `VFIconButton` with `.frame(minWidth: VFSize.touchTarget, minHeight: VFSize.touchTarget)` on iOS.

**P2-11 VoiceOver labels.** Icon-only buttons without a label: `TouchRootView.swift:636, 675, 677, 736, 775-777, 839-841`; PCB zoom (`PCBCanvas.swift:62-66`, read as "minus.magnifyingglass"); Simulate transport and run bar setup (`SimulationView.swift:133-139, 152`); hand transport (`HandGraspView.swift:141-144`); MessageBanner close (`CommonViews.swift:120`); `DesignOverlays.swift:31`. Candidate cards drop mass, safety factor and feasibility (`GenerateView.swift:280`). Fix: `VFIconButton` makes the label mandatory; card label lists the key numbers.

**P2-12 Canvases invisible to VoiceOver.** Metal viewport (`Viewport.swift:113` `CADView`), PCB `Canvas` (`PCBCanvas.swift:47-58`), flow graph. FRONTEND 7.8: canvas exposes the browser tree; gizmo drags have inspector equivalents. Fix: `accessibilityChildren` from the browser rows and PCB components; "Move…" with X and Y in the inspector; `SimJoystick` gets `accessibilityAdjustableAction` (`SimulationView.swift:488-500`).

**P2-13 Status dot reason.** `VFStatusDot` (`ThemeSwiftUI.swift:291`) says "Stale" but not why; FRONTEND 5 and 7.8 ask for state and reason. Fix: optional `reason` parameter used as accessibility value and tooltip.

**P2-14 Localisation.** No String Catalog (D-22 "String Catalog from day one"); 0 uses of `String(localized:)`; interpolated and hand-pluralised strings (`ProjectWindow.swift:444, 551, 554` [AO], `TouchRootView.swift:296-297`), `String(format:)` for units (`TouchRootView.swift:772`, `TouchStages.swift:119-120`, `ProjectWindow.swift:418` [AO]). Fix: add `Localizable.xcstrings` to both targets, `LocalizedStringResource` for computed titles, `^[\(n) body](inflect: true)`, `Measurement` formatting; English only for v1 but keyed now. French strings later must follow the owner's French rules.

**P2-15 Hover on iPad pointer.** No `.hoverEffect` anywhere and the workspace menu turns hover off on touch (`WorkspaceMenu.swift:132`); `.buttonStyle(.plain)` on TouchBarButton (`TouchChrome.swift:42` [AO]), PadToolButton (`TouchTools.swift:59`). Fix: `.hoverEffect(.highlight)` in `VFIconButton` and the Touch button style; keep hover rows on iPad with a pointer.

**P2-16 Pressed feedback on Touch.** Same plain styles show no press state. Fix [SC]: `VFTouchButtonStyle` (wash on press, scale 0.97 unless Reduce Motion, dimmed when disabled).

**P2-17 Forms: focus order and keyboard.** `TouchStages.swift:51-54` X, Y, Z fields have no focus order or `.submitLabel(.next)`; Touch generic form can be swiped away while edited (`TouchRootView.swift:126-128`, no `interactiveDismissDisabled`). Fix: `@FocusState` enum per form, `.submitLabel`, `interactiveDismissDisabled(isEdited)` with a discard confirmation.

**P2-18 Gesture-only controls.** PCB part move by drag only (`PCBCanvas.swift:47-58`); variant badges explained only on hover (`GenerateLive.swift:195-196`); plane sketch by double-click only on Mac (`BrowserSidebar.swift:170` [AO]). Fix: visible or menu equivalents.

**P2-19 Truncation.** Inspector hint "Nothing selected. Click a body, a face or an…" and "From Assemble joint l…" (captures); browser names cut by the dropdown; Flow summary `lineLimit(1)` (`TouchTools.swift:405`). Fix: allow two lines in `KVRow` and hints, tooltip with the full text.

**P2-20 Contrast of stage tones and badges.** Badge text white or black literal (`WorkspaceMenu.swift:295-297`); dark `accent` `#2A6BDA` with white is fine but `accentText` on `selection` needs the test extended to new components (FRONTEND 7.8 "extend ThemeTests"). Fix: add badge, e-stop, banner, toast pairs to `Theme/Tests`.

**P2-21 Charts and telemetry heights.** Fixed 150 x 54 telemetry wells clipped at large text (`RobotStage.swift:182-198` [AO]). Fix: flexible frames with min sizes.

**P2-22 Keyboard on iPad for every stage.** Escape to clear selection, arrow keys in lists, Tab through inspector are absent on Touch. Fix: `.onKeyPress` handlers on the root and `focusable()` lists.

**P2-23 Settings window.** `DeskCommands.swift:131-146` fixed 420 pt, two settings only; FRONTEND 7.7 onboarding reset, D-21 mouse presets, D-23 telemetry opt-in, units default all missing. Fix: `TabView` Settings (General, Navigation, Units, Privacy).

**P2-24 Onboarding cards.** FRONTEND 7.7 first-visit card per stage does not exist. Fix: `StageIntroCard` shown once, reset in Settings.

**P2-25 Haptics.** No `sensoryFeedback` on iPad for undo, tool armed, snap, export done, e-stop. Fix: add on those five events only.

**P2-26 Differentiate Without Color.** Not read anywhere. Fix: in `StatusDot`, PCB layers, BOM flags, heat map legend, add shapes or patterns when set.

---

## P3: signature polish

**P3-1** Buttons change width when they switch to a spinner or a new label: Build (`GenerateView.swift:188`), Insert (`GenerateProjectView.swift:90`, `HandGraspView.swift:60`), Run and Cancel, Refresh Prices. Fix: overlay the spinner, fixed label width (via P1-2).
**P3-2** Spinner appears at once; spec 7.2 says after 300 ms. Fix: `DelayedProgress` in the component library.
**P3-3** Skeletons for galleries and charts while loading (FRONTEND 7.6) instead of spinners in each card.
**P3-4** Undo flash text "Undone · ⇧⌘Z redoes" (`ProjectWindow.swift:248` [AO]) should name the step ("Undid Extrude").
**P3-5** Context pill and handles: 8 pt xmark (`DesignOverlays.swift:31`), 10.5 pt titles; align to `VFFont.small` and a 20 pt hit area on Mac, 44 on iPad.
**P3-6** PCB labels overlap wires and each other ("D1GND", capture electronics); draw a paper-coloured backing (`PCBCanvas.swift:156`) and offset labels.
**P3-7** Toolbar: the "Data" grid button (`ProjectWindow.swift:547` [AO]) has a vague name; rename "Projects" with a matching symbol.
**P3-8** Workspace popover on iPad leaves empty space under the footer (capture); size to content.
**P3-9** Done button in the ribbon shows "↩" glyph (`StageRibbon.swift:361`); use the system shortcut display via `.keyboardShortcut` rather than a drawn glyph.
**P3-10** `ExportSheet` spinner has no label; add "Exporting STEP…".
**P3-11** Toast for confirmations ("Exported 7 files", "Saved") with Reveal, replacing persistent messages.
**P3-12** Command palette: show recent commands first and the shortcut on each row (already partly), add "No commands match" empty state.
**P3-13** Stage accent only on the dropdown icon (spec 6.4): check the `Assemble` purple pill in the inspector header (capture) against that rule; use neutral.
**P3-14** App icon and About panel credits once the icon work in `scripts/icons` lands.

---

## Fix plan

Order follows P0 reliability, P1 consistency, P2 adaptation, P3 signature. Batches 1 to 7 avoid every file the other agent touches. Each batch ends with a build of both targets into a private derived data path and screenshots at 1440 light and dark plus iPad landscape.

1. **Theme foundations** (`Shared/UI/Theme/ThemeTokens.swift`, `ThemeSwiftUI.swift`, `Theme/Tests`). Default theme System (P1-9). Tokens `dangerFill`, `onDanger`, `capsule`, `touchFloating`, overlay offsets (P0-12 tokens, P1-8). High-contrast palette (P2-3). `VFFont` on text styles plus `@ScaledMetric` helpers (P2-1). `vfSurface` honouring Reduce Transparency, `vfAnimation` honouring Reduce Motion (P2-2, P2-4). `VFPrimaryButtonStyle` with platform height, hover, loading (P1-2). `VFStatusDot` with shapes and reason (P1-1 StatusDot, P2-13, P2-26). Contrast tests for new pairs (P2-20).
2. **Component library** (new `Shared/UI/Components/`). NumberField, InlineError and ErrorBanner, EmptyState, Toast, ConfirmSheet, KVRow, CostLine and MoneyText, `VFFormat`, VFIconButton, VFTouchButtonStyle, HoldButton, SafetyBar, ChartPanel, DelayedProgress, ExportFlow, `.vfDisabled(reason:)` (P1-1, P1-4, P1-21, P2-10, P2-11, P2-16, P3-2). Replace `ValueField` and `MessageBanner` and the JSON form in `Shared/UI/CommonViews.swift` (P1-5).
3. **App, menus, files** (`Shared/ViaFormApp.swift`, `Desk/DeskCommands.swift`, `Desk/DeskRootView.swift` FileActions part, `Shared/Flow/ProjectFiles.swift`, `apple/project.yml`). `DeskFocus.undoTarget` and a context-aware Undo menu (P0-1, menu half). `ProjectGuard` discard confirmation, edited dot, quit hook, save errors (P0-2, P0-4). Block extra windows until P0-3 lands. View, Job (Cmd-.) and Help menus (P1-14, P1-15). Settings tabs (P2-23). Remove legacy layout (P1-10). `.viaFormTheme()` on iOS root, no literal tints (P1-7). String Catalog wired in project.yml (P2-14). Window min size (P2-7). Target bump only on owner approval (P2-5).
4. **Generate and Simulate** (`Shared/Generate/*` except LoadsFromSimSheet, `Shared/Sim/SimModel.swift`, `SimulationView.swift`, `SimEngine.swift`, `HandGraspView.swift`, `Shared/Flow/FlowReporting.swift`, `FlowGraphView.swift`). P0-7, P0-8, P0-9, P0-11 (Generate and Sim parts), P0-17, P0-18, P1-3, P1-20, P1-21, P1-29, P1-32, P1-34, tokens P1-6 to P1-8, a11y P2-11, P2-12 (joystick), P3-1.
5. **BOM, Library, PCB, Start** (`Shared/Bom/*`, `Shared/Library/*`, `Shared/UI/PCBCanvas.swift`, `PCBPanels.swift`, `Desk/DeskPCBView.swift`, `ElectronicsOverlays.swift`, `DeskPanels.swift`, `StartWindow.swift`). P0-10 (BOM, Library), P0-11 (BOM, Keychain), P1-22 to P1-26, P1-31, P2-10, P2-12 (PCB), P3-6.
6. **Mac shell pieces not held by the other agent** (`Desk/StageRibbon.swift`, `DesignOverlays.swift`, `CommandPalette.swift`, `WorkspaceDropdown.swift`, `Shared/Flow/WorkspaceMenu.swift`, `Desk/PipelineBar.swift`, `Desk/DeskKeys.swift`, `Shared/Render/Viewport.swift`). Selection rule in the viewport (P1-11), trackpad mapping and presets (P1-13), palette and menu fixes (P1-19), PipelineBar text (P1-14), e-stop Esc-twice before text focus in the key monitor (P0-15), StatusDot unification (P1-1), P3-5, P3-9, P3-12.
7. **Touch, files not held** (`Touch/TouchRootView.swift`, `TouchTools.swift`, `TouchSheets.swift`, `TouchStages.swift`, `TouchPCBView.swift`, `TouchSimulation.swift`). P0-1 Touch half, P0-5, P0-6, P0-16, P1-27, P1-28, P1-30, tokens, P2-6, P2-8 (except the popover), P2-9, P2-10, P2-15 to P2-18, P2-22, P2-25.

**After the other agent** (batch 8, once its work is committed):

8a. `Desk/ProjectWindow.swift`: publish `undoTarget` per workspace and route palette undo (P0-1), per-window session for P0-3, overlays modal (P1-16), single primary and banner wording (P1-17), resizable bottom panel (P1-18), SceneStorage (P2-9), tokens and strings (P1-8, P1-29, P2-14), P3-4, P3-7.
8b. `Desk/BrowserSidebar.swift`: `List(selection:)` outline with keyboard, rename, delete, context menus, destructive role, row height token (P0-10, P1-11, P1-12, P2-18).
8c. `Desk/InspectorPanel.swift`, `Desk/RobotStage.swift`, `Shared/Robot/RobotSafety.swift`, `Touch/TouchRobotStage.swift`: SafetyBar, HoldButton, real caps, motion confirmation and frame (P0-12 to P0-14), truncation (P2-19), heights (P2-21), P3-13.
8d. `Touch/TouchChrome.swift`: full shortcut set and focus-aware Cmd-Z (P0-1, P1-14), popover size (P2-8, P3-8), targets and hover.
8e. `Shared/Flow/FlowModel.swift`: job pause and progress hooks if FlowReporting needs model changes (P1-3).
8f. Assemble and arm Simulate files (`Shared/Assemble/*`, `Desk/AssembleRibbon.swift`, `Shared/Sim/ArmSim*.swift`, `PhysService.swift`, `Generate/LoadsFromSimSheet.swift`): not audited in depth here; apply the same checklist (tokens, NumberField, StatusDot, ConfirmSheet, Cmd-. on solves, undo routing via `undoTarget`, VoiceOver for the IK drag) once that work lands.

## Notes for implementation

- Check every file with `git status` first; the other agent works in the same checkout. Never `git add -A`.
- Build into `/private/tmp/viaform-dd` only, never the shared DerivedData.
- Screenshot flags exist: `--window-size=1440x900`, `--theme light|dark`, `--show-workspaces`, `--show-palette`, `--show-shortcuts`, `--board`, `--arm`, `--hand`, `--drone`, `--library`, `--no-inspector`.
- Owner decisions needed: deployment target bump to 26 (P2-5), removing the legacy layout (P1-10), default theme System (P1-9, already D-20), mouse preset list (P1-13).
- Findings marked from subagent reads (Touch, Generate and Simulate, BOM and Library and PCB and Robot) were spot-checked on SimModel cancel, Generate Cancel, e-stop and Touch key commands; recheck the others' line numbers before editing.
