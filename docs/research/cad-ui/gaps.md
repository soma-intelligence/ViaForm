# ViaForm Swift apps: gaps against the CAD reference sheets

Prioritised list of what the Swift apps (Mac `apple/Desk`, iPad and iPhone `apple/Touch`,
shared `apple/Shared`) lack compared with the reference sheets in this folder. Electron is out
of scope. Written 2026-11-23 from `viaform-today.md`, `shapr3d-ipad.md`, `fusion-desktop.md`,
`solidworks-desktop.md`, `docs/ui-reference.md` and `IMPROVEMENTS.md`, with spot checks in the
code. Paths are relative to `apple/` unless they start with `engines/` or `docs/`.

Owner rules applied: same layout, workflows and input mappings as the reference, ViaForm's own
SF Symbols, colours and names. Mac = Fusion layout plus SolidWorks behaviours where better.
iPad = Shapr3D.

Already fixed, not listed: Mac Edit Feature now opens `Shared/UI/EditFeatureSheet.swift`
(`timeline.inspect`, edit fields, changed fields only via `timeline.edit`), wired at
`Desk/StageDetail.swift:138-141`, `254`, `267` and `Shared/UI/CommonViews.swift:575-585`.

Legend:
- Priority: **P0** core workflow broken or missing (sketch, constrain, extrude, edit history,
  select); **P1** feels wrong against the reference; **P2** polish.
- Size: **S** under a day, **M** a few days, **L** a week or more.
- Engine: whether the SolidCraft core already has the command (ids from
  `engines/solidcraft/crates/engine/src/cmd/`). "UI only" means no engine work is needed.
- Ref cites the reference file (`S3D` = shapr3d-ipad.md, `FUS` = fusion-desktop.md, `SW` =
  solidworks-desktop.md) and `videoId @ mm:ss`.

## Top picks

1. **B-1 Sketch entity picking**: nothing else in constraints or dimensions can work until a curve or point can be selected in an open sketch.
2. **B-2 Constraint glyphs**: `sketch.glyphs` already returns name, anchor, failing and redundant per constraint; the app throws it away. Cheap and visible.
3. **B-3 Defined state**: the same call returns `dof` and `fully_constrained`; one colour rule plus a readout closes the biggest "is my sketch done" gap on both platforms.
4. **B-4 Contextual constraint list**: one shared mapping from selection to valid constraints feeds M-1 (Mac panel and pill) and T-2 (iPad column).
5. **B-5 Dimension by picking**: `sketch.dimension` (key D) exists; today it needs typed ids in a JSON form.
6. **T-1 Edit Feature on touch**: reuse `FeatureField` and the inspect/edit pair from the Mac sheet inside the History row; the only P0 history gap left.
7. **T-3 Sketch point drag on touch**: the Mac path exists; touch only lacks the gesture hook. Small, high value with Pencil.
8. **M-2 Edit Feature in the tool's own dialog**: move from the generic sheet to the real Extrude/Fillet dialog with live preview, plus Edit Sketch and Redefine from the timeline.
9. **B-7 Typed Extrude, Revolve, Fillet, Chamfer options**: direction, symmetric, taper, to-object, thin are in the engine but not in any dialog.
10. **T-4 Adaptive left tool column**: the single largest "this is not Shapr3D" gap on iPad (context pill instead of the column).

---

## Both (shared core and model work)

1. **B-1 [P0] Select sketch curves and points in an open sketch** (M; engine: UI only, data from `sketch.inspect`)
   - Ref: FUS 3.3, select entities first, then the constraint (D0TYcB-2_8o @ 27:09); S3D 5.2, tap a glyph or curve (FFeIJJ1pm70 @ 11:00); SW 3.2 Ctrl-click entities (YIguko4mXRM @ 0:08:00).
   - Today: picks are face or edge only (`Shared/Engine/Picking.swift:6-20`); in a sketch only point drag exists (`Shared/Model/DesignInteractions.swift:65-94`). No sketch selection set anywhere.
   - Build: a 2D hit test on the sketch's curves and points in `DesignModel`, a `sketchSelection` set with hover and selected styling, cleared on sketch exit. Delete key sends `sketch.delete`.

2. **B-2 [P0] Draw constraint glyphs, select and delete them** (S; engine: yes, `sketch.glyphs`)
   - Ref: S3D 5.2 icon squares beside geometry, tap then Delete Constraints (FFeIJJ1pm70 @ 11:00 to @ 12:00); FUS 3.3 grey glyphs, Delete key or menu (D0TYcB-2_8o @ 33:47); SW 3.2 glyph plus Delete (YIguko4mXRM @ 0:09:09).
   - Today: `Shared/Model/SketchInfo.swift:125-131` reads `sketch.glyphs` but keeps only dimensions. The engine returns `name`, `at`, `failing`, `redundant` for every constraint (`engines/.../cmd/sketch_constraints.rs:524-549`).
   - Build: a glyph layer next to `SketchDimensionLayer` (`Shared/Render/SketchCanvasLayers.swift:57-133`) with one SF Symbol per kind, dimmed when redundant, red when failing; glyphs join the B-1 selection; Delete removes the constraint. A "Show constraints" toggle.

3. **B-3 [P0] Sketch defined state: colour and readout** (S; engine: yes, `dof` and `fully_constrained` in `sketch.glyphs`, `status` in `sketch.solve`, `sketch.rs:3727`)
   - Ref: FUS 3.2 blue under-defined, black fully (7lKpzGtoQX0 @ 6:11); S3D 5.2 blue then green (vK4IXELjgkw @ 01:30); SW 3.4 colour plus "Under Defined / Fully Defined" in the status bar (XdWYW4HOLT4 @ 22:40).
   - Today: no state shown; only a red failing dimension chip (viaform-today.md 3, "Defined state").
   - Build: one ViaForm token pair (free vs defined) for sketch curves, plus a DOF count and "Over-constrained" warning. Per-entity colouring needs per-entity freedom, which `sketch.glyphs` does not return; do sketch-level first, ask upstream for per-entity later.

4. **B-4 [P0] Contextual constraint list from the selection** (M; engine: yes, 13 `sketch.constraint.*` commands)
   - Ref: FUS 3.3 only applicable constraints stay enabled, circle + line gives Tangent and Fix (D0TYcB-2_8o @ 27:09 to 27:39); S3D column greys invalid entries (FFeIJJ1pm70 frame @ 11:00); SW 3.2 filtered relation toolbar by type pair (YIguko4mXRM @ 0:08:30, XdWYW4HOLT4 @ 28:30).
   - Today: constraints run only from the JSON form with typed entity ids (viaform-today.md 3, "Constraints").
   - Build: a pure function in `Shared/Model` from the B-1 selection (kinds and count) to valid constraints and their params, plus a runner that builds the command. Symmetry asks for the axis as a third pick. Surfaces: M-1 and T-2.

5. **B-5 [P0] Create dimensions by picking** (M; engine: yes, `sketch.dimension`, key D, `sketch.rs:143`)
   - Ref: FUS 3.4 one entity for length or diameter, two for distance, place, type, Enter (7lKpzGtoQX0 @ 6:11); SW 3.3 orientation follows the mouse, right-click locks it (YIguko4mXRM @ 0:25:00, @ 0:26:00); S3D 5.2 icon before the number picks H, V or aligned (vK4IXELjgkw @ 03:30).
   - Today: D opens the JSON form; no click flow (viaform-today.md 3, "Dimensions"). Editing existing chips works.
   - Build: a Dimension tool: pick 1 or 2 entities from B-1, preview the dimension, place it, open the existing chip editor; over-constraining offers "make driven" (SW 3.3, XdWYW4HOLT4 @ 45:00).

6. **B-6 [P1] Auto constraints and inference lines while drawing** (M; engine: yes, `sketch.snap` returns snap kinds, `sketch.auto_constrain`)
   - Ref: FUS 3.3 H, V, perpendicular, coincident added as you draw (D0TYcB-2_8o @ 23:02); S3D 5.2 snapping on release adds constraints, purple inference line (W4MKAuDJ_I8 @ 02:00, @ 04:30); SW 3.1 dashed inference lines (YIguko4mXRM @ 0:29:25).
   - Today: snap moves the point only, drawing adds no constraint (`Shared/Model/DesignModel.swift:422-432`).
   - Build: keep the snap kind of each click and add the matching constraint after the entity command; draw a dashed inference line in a ViaForm accent colour.

7. **B-7 [P1] Typed options for Extrude, Revolve, Fillet, Chamfer, Shell** (M; engine: yes, `solid.extrude` takes `through_all`, `taper` and more, `features.rs:36-43`)
   - Ref: FUS 2.1 Extrude Direction One Side / Two Sides / Symmetric, Extent Distance / To Object / All, Taper, Thin, Objects To Cut (D0TYcB-2_8o @ 50:35, @ 52:55); FUS 2.2 Fillet G1/G2, Chamfer types, Shell direction (D0TYcB-2_8o @ 1:09:55 to 1:20:11); S3D 2.3 One-Sided / Symmetric, draft arrow (vK4IXELjgkw @ 16:00, 3jkPqc4VIVo frame @ 15:00).
   - Today: Extrude has distance and operation only (viaform-today.md 2, after the tool table).
   - Build: extend the tool dialog (Mac) and tool card (Touch) from the command schema, same field order as Fusion; Through All, To Object (face pick) and Symmetric first.

8. **B-8 [P1] Inline size fields while drawing, Tab to cycle** (M; engine: yes, `sketch.dimension` after creation)
   - Ref: FUS 3.4 rectangle width, Tab, height, Enter (7lKpzGtoQX0 @ 4:37); S3D width and height boxes while drawing (EHNsV2TvdIo @ 03:00); SW on-screen numeric input (YIguko4mXRM @ 0:45:10).
   - Today: the rubber band is a dashed line with no fields (`DesignModel.swift:514-538`).
   - Build: value boxes on the rubber band for line, rectangle, circle, polygon, slot; a typed value fixes the size and adds the dimension.

9. **B-9 [P1] Construction toggle** (S; engine: yes, `sketch.construction`)
   - Ref: FUS X key or Linetype button (D0TYcB-2_8o @ 38:53); S3D Construction mode toggle bottom left and Make Construction (FFeIJJ1pm70 @ 06:30, @ 07:00).
   - Today: X opens the JSON form (viaform-today.md 6, keys).
   - Build: toggle selected curves (B-1) and a drawing mode flag; draw construction curves dashed.

10. **B-10 [P1] Editable parameters and expressions in every value field** (M; engine: yes, `parameters.add`, `rename`, `delete`, `parameters.change`)
    - Ref: FUS 5.2 Change Parameters table, fx in fields (F0qnbGiJ1RY @ 18:55, @ 39:58); S3D variables at the top of History (AgFApKpygiU @ 01:30 to @ 03:00); SW 3.3 `=` menu and a marker on linked values (XdWYW4HOLT4 @ 25:30).
    - Today: parameters are read only in both apps (`Desk/InspectorPanel.swift:219-242`, Touch ItemsPanel `Touch/TouchRootView.swift:938-1046`).
    - Build: an editable parameter list (add, rename, expression, comment); name autocomplete in `NumberField`; a visible link marker on driven chips. Always link, never silent copy (SW "Things not to copy").

11. **B-11 [P1] Click-to-draw for the remaining sketch tools** (L; engine: yes)
    - Ref: FUS 2.8 CREATE dropdown variants (gKGP1iFhd1s @ 1:00:00); S3D 2.2 Rectangle Diagonal / Center / 3-Point, Project, Mirror, patterns (J9bHL6BvWSs @ 22:00, ihBSoDQNqFM @ 20:00).
    - Today: 12 tools draw; ellipse, 3-point rectangle, tangent arc, project, mirror, extend, patterns open the JSON form (viaform-today.md 8).
    - Build, in order: Project / Include (linked, own colour), Mirror, 3-point rectangle and circle variants, Ellipse, Extend, sketch patterns. Project matters most: sketching on a face needs its edges.

12. **B-12 [P1] Line tool makes a tangent arc** (S; engine: yes, `sketch.arc.tangent`, `sketch_create.rs:41`)
    - Ref: FUS drag from a line end (F0qnbGiJ1RY @ 1:53:36); SW move back over the endpoint (XdWYW4HOLT4 @ 26:00); S3D "Line/Arc (Automatic)" (FFeIJJ1pm70 frame @ 06:30).
    - Today: line only (`DesignModel.swift:452-459`).
    - Build: press and drag from the chain end switches to tangent arc for that segment (mouse and Pencil).

13. **B-13 [P1] Drag handles for fillet, chamfer, shell, revolve; move gizmo with Copy** (M; engine: yes, `solid.move` takes `axis`, `angle`, `copy`)
    - Ref: S3D arrow plus chip for Chamfer/Fillet (FFeIJJ1pm70 @ 17:30), Move/Rotate gizmo with Copy badge and movable centre (EHNsV2TvdIo @ 04:00, W4MKAuDJ_I8 @ 14:00); FUS Move/Copy arrows, rings, centre ball (7lKpzGtoQX0 @ 23:10); SW editable radius callout (YIguko4mXRM @ 3:15:30).
    - Today: handles only for Push / Pull and Extrude (`Shared/Render/DesignHandleView.swift`); Move is X/Y/Z fields (`Desk/DeskRootView.swift:560-568`).
    - Build: reuse `DesignHandleView` for radius and thickness arrows and a revolve arc; a translate and rotate gizmo with a Copy toggle.

14. **B-14 [P1] Construction planes and axes: guided flow and listing** (M; engine: yes, 20 `construct.*`)
    - Ref: S3D Add > Construction plane, type, references, Next, Done (W4MKAuDJ_I8 @ 14:30, tXdvSyuHoIE @ 18:30); FUS 2.3 CONSTRUCT list (D0TYcB-2_8o @ 1:24:20).
    - Today: only offset and at-angle are typed; built planes are not listed in the browser or Items (viaform-today.md 8, "Construction geometry").
    - Build: a pick-driven form per plane type (offset, midplane, at angle, through edge, on curve), and a Construction folder in both trees, each plane sketchable.

15. **B-15 [P2] Section view that really cuts** (M; engine: yes, `inspect.section`; renderer work)
    - Ref: S3D pick plane, drag arrow, hatched faces per body (3jkPqc4VIVo frame @ 07:30); FUS Section Analysis (D0TYcB-2_8o @ 1:20:11).
    - Today: touch sends XZ at 0 only; the renderer ignores `clip` (`Touch/TouchRootView.swift:598-602`, IMPROVEMENTS.md item 9).
    - Build: clip planes in the Metal pass, a plane pick and drag arrow, cap faces in a ViaForm hatch.

---

## iPad (Shapr3D)

1. **T-1 [P0] Edit Feature from History** (S; engine: yes, `timeline.inspect`, `timeline.edit`)
   - Ref: S3D 5.1 double tap or chevron expands the row in place with its values, Extrude: Profile, Distance, Draft Angle, Extent, Result (ihBSoDQNqFM frames @ 03:00, @ 08:30, @ 11:30).
   - Today: no Edit Feature on touch (`Touch/TouchRootView.swift:704-783`; viaform-today.md touch 4).
   - Build: an expandable row that renders `FeatureField.flatten` output and sends `FeatureField.changes` (`Shared/UI/EditFeatureSheet.swift`); sketch rows show Edit Sketch.

2. **T-2 [P0] Constraint column in sketch mode** (M; engine: yes; needs B-1, B-2, B-4)
   - Ref: S3D right column under History: Constraint Settings, Parallel, Perpendicular, Tangent, Coincident, Midpoint, Concentric, H/V, Equal, Symmetry, Disconnect, Lock, Make Construction; invalid ones grey, never hidden (FFeIJJ1pm70 frame @ 11:00).
   - Today: none on touch; constraints only in CommandBrowser as JSON (viaform-today.md touch 3).
   - Build: a fixed labelled column on the right while a sketch is open, fed by B-4; Delete becomes "Delete Constraints" when glyphs are selected; settings toggles Always Show Constraints and Dimensions.

3. **T-3 [P0] Drag sketch points on touch** (S; engine: yes, `sketch.drag`, `sketch.drag_end`)
   - Ref: S3D live 3D rebuild while dragging sketch points (vK4IXELjgkw @ 32:30).
   - Today: `beginSketchDrag` is only called from the macOS `mouseDown` (`Shared/Render/Viewport.swift:158`); one finger always orbits.
   - Build: in the iOS view, a one-finger or Pencil drag that starts within the point radius drags the point; elsewhere it orbits.

4. **T-4 [P1] Adaptive left tool column instead of the context pill** (M; engine: UI only)
   - Ref: S3D 3 and 9: the selection replaces the left column (Deselect All, Move/Rotate, Scale, Align, Chamfer/Fillet, Extrude, Shell, ...); a running tool shrinks it to Search, Deselect All and the tool with its mode (EHNsV2TvdIo frame @ 06:00, FFeIJJ1pm70 frames @ 16:30, @ 17:30).
   - Today: fixed Sketch and Solid groups (`Touch/TouchTools.swift:67-125`) plus a floating pill near the selection (`TouchTools.swift:283-343`).
   - Build: one column whose content is a function of selection and tool state, using `model.suggestions` widened to the S3D lists; drop the pill on iPad.

5. **T-5 [P1] Top level column: Search, Sketch, Add, Transform, Tools, with labels and mode subtitles** (M; engine: UI only)
   - Ref: S3D 1.1 and 1.2 (FFeIJJ1pm70 frame @ 05:00, vK4IXELjgkw frame @ 08:30); sub mode shown in grey under each label ("Center", "Pentagon") (FFeIJJ1pm70 frame @ 11:00).
   - Today: icon groups with menus "Shapes", "Combine", "More" (`Touch/TouchTools.swift:86-103`).
   - Build: regroup into those five with ViaForm names and SF Symbols; Search opens the palette; labels always on.

6. **T-6 [P1] Screen zones per the Shapr3D corrections** (M; engine: UI only)
   - Ref: S3D 9 table: workspace top left, Items top left sliding from the left, History top right sliding from the right, undo and redo circles bottom left, Construction / Isolate / Section View / Measure stack bottom left, title pill centre with Share and "..." (FFeIJJ1pm70 frames @ 11:00, @ 16:30, @ 17:30).
   - Today: one top capsule holds workspace, browser, undo, redo, Items/History switch, commands, jobs, share (`Touch/TouchChrome.swift:116-220`); Items and History share a right card (`TouchRootView.swift:280-296`); section and isolate sit in the eye menu (`374-400`).
   - Build: move each control to its S3D zone. Also update `docs/ui-reference.md` Touch section per S3D 9 (not done here).

7. **T-7 [P1] Double tap a face to sketch on it** (S; engine: yes, `sketch.create {face}`)
   - Ref: S3D double tap a face or plane enters sketch; double tap elsewhere selects the body (FFeIJJ1pm70 @ 05:00, EHNsV2TvdIo @ 04:00).
   - Today: double tap toggles the body or ends a chain (`Viewport.swift:358-362`); sketch needs the tool then PlaneChooser (`TouchRootView.swift:889-908`).
   - Build: double tap on a planar face with nothing armed starts the sketch; on a non-planar face it selects the body.

8. **T-8 [P1] Tap a profile to start Extrude** (S; engine: yes, `solid.extrude {profiles}`)
   - Ref: S3D tapping a profile starts Extrude directly (W4MKAuDJ_I8 @ 06:00).
   - Today: profiles are pickable only while Extrude is armed (`DesignInteractions.swift:25-32`).
   - Build: with Select and a closed sketch, a tap on a profile picks it and shows the Extrude arrow and chip.

9. **T-9 [P1] Value chip on the handle with a result menu; add Intersect** (S; engine: yes, `operation: intersect`)
   - Ref: S3D white value chip, tap to type, a small icon beside it for New Body / Union / Subtract / Intersect (FFeIJJ1pm70 @ 05:00, tXdvSyuHoIE frame @ 06:30).
   - Today: the operation picker is in the right card and lacks Intersect (`Touch/TouchStages.swift:241-394`).
   - Build: move value and result onto the handle chip; keep the card for secondary options.

10. **T-10 [P1] Tool mode pill under the title** (S; engine: UI only)
    - Ref: S3D "Line/Arc", "Extrude - One-Sided", "Chamfer/Fillet" with a chevron that lists modes (FFeIJJ1pm70 frames @ 05:30, @ 11:00, @ 17:30).
    - Today: hints live in `ToolSession.hint` (`Touch/TouchStages.swift:353-366`); no mode switch while a tool runs.
    - Build: a top centre pill naming the tool and mode; modes map to engine variants (rectangle two_point / center / three_point, extrude one side / symmetric).

11. **T-11 [P1] Box selection with Pencil or drag on empty canvas** (M; engine: yes, `select.set`)
    - Ref: S3D drag a box on empty canvas, direction picks window or crossing (EHNsV2TvdIo @ 14:30, @ 24:30).
    - Today: no box selection (viaform-today.md 7).
    - Build: a Pencil drag on empty canvas draws the box (finger still orbits); works on bodies, faces, edges and sketch entities (B-1).

12. **T-12 [P1] Selection readout at the bottom centre** (S; engine: yes, `inspect.measure`)
    - Ref: S3D "1 edge 5 mm", "2 edges & 2 constraints", "Body 02 (1)" with an (i) button (FFeIJJ1pm70 frame @ 11:00).
    - Today: SummaryCapsule shows document counts (`Touch/TouchTools.swift:455-472`).
    - Build: replace it with a selection summary plus length, area or distance; (i) opens the inspector card.

13. **T-13 [P1] History: draggable breakpoint, rename, reorder by drag, related filter** (M; engine: yes, `timeline.roll_to`, `rename`, `reorder`)
    - Ref: S3D long press, Insert Breakpoint; a grey bar to drag; rows below grey; tap bar to Delete (FFeIJJ1pm70 @ 19:00, ihBSoDQNqFM @ 07:30, @ 11:30); drag rows to reorder (W4MKAuDJ_I8 @ 15:30); rename rows (ihBSoDQNqFM frame @ 03:00); "Related to Selection" chip (3jkPqc4VIVo frame @ 10:00).
    - Today: tap a row rolls back; `.onMove` exists but no edit mode, so reorder may be unreachable (`TouchRootView.swift:760-763`); no rename.
    - Build: a breakpoint row with a grab handle, always-on drag reorder, rename in the row menu, a related filter using `timeline.dependents`.

14. **T-14 [P1] Items manager: rename, delete, folders, filter** (M; engine: yes, `body.rename`, `solid.remove`, `browser.group`)
    - Ref: S3D 6 filter All / Bodies / Sketches / Planes and Axes, folders, bottom bar Rename / Delete / More, empty states (ihBSoDQNqFM frame @ 07:30, FFeIJJ1pm70 frame @ 16:30, EHNsV2TvdIo @ 14:30).
    - Today: no rename, delete or group in ItemsPanel (`TouchRootView.swift:938-1046`); rename only in the Browser sheet alert.
    - Build: multi-select rows, bottom action bar, folder create and drag, the type filter, planes listed (B-14).

15. **T-15 [P2] Custom value keypad with arithmetic keys** (M; engine: UI only)
    - Ref: S3D keypad popover with field name, big value, operators, tall check key (ihBSoDQNqFM frame @ 15:00).
    - Today: system keyboard through `NumberField`, plus a slider.
    - Build: a keypad popover for every value chip on iPad; expressions still go through `VFExpression`.

16. **T-16 [P2] Snapping and grid mini rail** (S; engine: yes, `view.grid`)
    - Ref: S3D magnet menu and grid chip "1 mm" top right (FFeIJJ1pm70 frame @ 11:00); grid lock (EHNsV2TvdIo @ 02:30).
    - Today: no snapping or grid control on touch.
    - Build: a small vertical rail top right with snapping toggles and grid size.

17. **T-17 [P2] Sketch exit and orientation niceties** (S; engine: yes, `view.normal_to`)
    - Ref: S3D "Exit Sketching" as first column entry, leave by rotating away, "Normal to Sketch" pill (FFeIJJ1pm70 @ 04:30, ihBSoDQNqFM frame @ 03:00).
    - Today: Finish sits at the end of the tool group (`TouchTools.swift:73-82`).
    - Build: Exit first in the column, a Normal to Sketch pill when the view leaves the plane, optional exit on orbit.

18. **T-18 [P2] Hardware keyboard tool keys and left-handed layout** (S; engine: UI only)
    - Ref: S3D 4.3 L, A, I, R, C, G, O, T, E, F, H, V, M, S, Space (vK4IXELjgkw frame @ 01:30); mirrored layout (ihBSoDQNqFM frames @ 03:00 to @ 12:00).
    - Today: no single-letter keys on touch (`Touch/TouchChrome.swift:453-600`); no mirror option.
    - Build: reuse the registry `.key(...)` map from `Desk/DeskKeys.swift`; a setting that swaps the left and right zones.

---

## Mac (Fusion + SolidWorks)

1. **M-1 [P0] Constraints on pre-selection: ribbon panel, context pill, Delete** (M; engine: yes; needs B-1, B-2, B-4)
   - Ref: FUS 3.3 select first, click the constraint, invalid ones disabled (D0TYcB-2_8o @ 27:09 to 27:39); SW "Better than Fusion" 1, valid relations next to the cursor after a Cmd multi-select (YIguko4mXRM @ 0:10:20).
   - Today: CONSTRAINTS ribbon entries open the JSON form (`Desk/StageRibbon.swift:141-151`, `Desk/DeskRootView.swift:335-354`).
   - Build: route `sketch.constraint.*` through B-4 when the selection fits, keep the JSON form as fallback; show the same list in the context pill (`Desk/DesignOverlays.swift:272-291`).

2. **M-2 [P1] Edit Feature in the tool's own dialog, plus Edit Sketch and Redefine Plane** (M; engine: yes, `timeline.inspect`, `timeline.edit`, `timeline.redefine`, `sketch.edit`)
   - Ref: FUS 5.1 Edit Feature reopens its dialog (7lKpzGtoQX0 @ 30:18); sketch items: Edit Sketch, Redefine Sketch Plane (F0qnbGiJ1RY @ 1:48:47); SW Edit Sketch Plane (YIguko4mXRM @ 2:59:00).
   - Today: a generic sheet with flattened fields and no preview (`Shared/UI/EditFeatureSheet.swift`); geometry lists (profiles, edges) are skipped; no Edit Sketch or redefine on timeline tiles.
   - Build: for features with a dedicated tool, open that dialog pre-filled with checkpoint preview and commit via `timeline.edit`; double-click a tile does it; add Edit Sketch and Redefine Sketch Plane to sketch tiles.

3. **M-3 [P1] Sketch Palette on the right while sketching** (M; engine: yes, `sketch.construction`, `view.grid`, `view.normal_to`)
   - Ref: FUS 1.10 Feature Options, Linetype, Look At, Sketch Grid, Snap, Slice, Show Profile, Points, Dimensions, Constraints, Projected, Finish Sketch (7lKpzGtoQX0 @ 4:30, D0TYcB-2_8o @ 21:30).
   - Today: the inspector keeps showing design info while sketching (`Desk/InspectorPanel.swift:219-242`).
   - Build: a docked palette in the inspector column for the open sketch, with the DOF readout from B-3.

4. **M-4 [P1] Extrude on canvas: floating value box, auto Cut, Objects To Cut** (M; engine: yes, `operation` and target bodies)
   - Ref: FUS small input box beside the arrow, Tab to next value (D0TYcB-2_8o @ 50:35, 7lKpzGtoQX0 @ 5:07); dragging into material switches to Cut (7lKpzGtoQX0 @ 16:27); Objects To Cut list (F0qnbGiJ1RY @ 2:13:30).
   - Today: value in the dialog plus a read-only badge on the gizmo (`DesignOverlays.swift:221-259`).
   - Build: make the badge an editable field, flip the operation to Cut on a negative or inward drag, add the cut targets list. Pairs with B-7.

5. **M-5 [P1] Fusion-style dialog rows and commit keys** (S; engine: UI only)
   - Ref: FUS 1.9 selection rows "1 selected" with a clear button, OK greyed until required inputs are set, (i) help (gKGP1iFhd1s @ 2:20:00, 7lKpzGtoQX0 @ 25:15); SW Enter accepts the field then the feature, right-click OK (XdWYW4HOLT4 @ 43:50, YIguko4mXRM @ 3:17:00).
   - Today: selection row, value field, Cancel and Done (`Desk/DeskRootView.swift:530-608`).
   - Build: active or idle selection buttons with counts, disabled OK, Enter twice, OK in the right-click menu while a command runs.

6. **M-6 [P1] Fusion mouse mapping as the Mac default** (S; engine: UI only)
   - Ref: FUS 6.1 middle drag pan, Shift middle orbit, Cmd-click add or remove, Shift-click range, right-click marking menu (7lKpzGtoQX0 @ 5:20, @ 9:13; D0TYcB-2_8o @ 27:09); ui-reference.md double middle click fits.
   - Today: default preset "ViaForm": right drag orbits, Shift-click adds, double-click toggles the body (`Shared/UI/Components/Navigation.swift:8-86`, `Viewport.swift:149-209`).
   - Build: ship the Fusion preset as default, add double middle click to fit; keep the others in Settings.

7. **M-7 [P1] Marking menu: Fusion layout plus flick gestures** (M; engine: UI only)
   - Ref: FUS 6.3 Repeat north, Delete, Press Pull, Undo, Redo, Move, Hole, Sketch submenu south, overflow with Find in Browser / Timeline and selection items like "Delete Coincident" (D0TYcB-2_8o @ 24:04, @ 33:47); SW 6.3 a fast right-drag flick fires with no menu drawn, one wheel per mode (XdWYW4HOLT4 @ 23:00, @ 23:40).
   - Today: click-only slices; the documented drag is not implemented (`Desk/DeskPanels.swift:29-63`).
   - Build: right-drag direction picks a slice with a wedge highlight; a quick flick runs it on release; reorder slices to the Fusion compass.

8. **M-8 [P1] Box selection: window, crossing, freeform** (M; engine: yes, `select.set`)
   - Ref: FUS left to right window, right to left crossing, keys 1 / 2 / 3 (D0TYcB-2_8o @ 14:51, @ 13:50); SW same direction rule (YIguko4mXRM @ 0:11:27).
   - Today: none (viaform-today.md 7).
   - Build: left drag on empty canvas with Select armed draws the box (Fusion preset frees left drag); works in sketches on B-1 entities.

9. **M-9 [P1] Selection priority, filters and select-through** (M; engine: yes, `select.filter`, `edit.rs:117`)
   - Ref: FUS 2.6 and 6.5 Body / Face / Edge / Component priority (D0TYcB-2_8o @ 13:47); press and hold for a pick list of overlapping items (D0TYcB-2_8o @ 54:39).
   - Today: edges only pickable with Select, Fillet or Chamfer armed; bodies only by double-click or browser (`DesignModel.swift:312`, `375-380`).
   - Build: a SELECT ribbon panel and a status-bar filter control; long press opens a candidate list.

10. **M-10 [P1] Edit from the canvas: owning feature on a picked face** (M; engine: not checked, needs a face to feature lookup)
    - Ref: SW click a face, context toolbar offers Edit Feature, Edit Sketch, Suppress; breadcrumbs show the chain (YIguko4mXRM @ 2:56:00, @ 5:47:20).
    - Today: suggestions for one face are Push / Pull, Sketch, Shell, Delete (`DesignModel.swift:735-743`).
    - Build: add "Edit <feature>" and "Edit <sketch>" to the pill when the engine can name the face's feature; ask upstream if it cannot.

11. **M-11 [P1] Defined state in the browser and status bar** (S; engine: yes; needs B-3)
    - Ref: FUS padlock on fully constrained sketches, pencil otherwise (D0TYcB-2_8o @ 31:00); SW `(-)` prefix and "Under Defined" in the status bar (YIguko4mXRM @ 1:50:30, XdWYW4HOLT4 @ 22:40).
    - Today: sketch rows show a plain name (`Desk/BrowserSidebar.swift:205-527`); the status bar names the selection only (`Desk/ProjectWindow.swift:655-702`).
    - Build: a state glyph on sketch rows and timeline tiles, and the state text in the status bar while sketching.

12. **M-12 [P1] Live measure of the selection in the status bar** (S; engine: yes, `inspect.measure`)
    - Ref: FUS "1 Face | Area : 20.227 cm^2", two faces show the angle (D0TYcB-2_8o @ 13:50, @ 1:37:38); SW distance, radius, area, perimeter (XdWYW4HOLT4 @ 28:30, @ 45:30).
    - Today: "Face of X selected" (`ProjectWindow.swift:671-677`).
    - Build: query on selection change and append the key measure.

13. **M-13 [P1] Timeline: rename, groups, states, Parent/Child** (M; engine: yes, `timeline.rename`, `group`, `dependents`)
    - Ref: FUS 5.1 slow-click rename, Create Group, failed red and lost reference yellow, Roll Marker Here, Find in Browser (F0qnbGiJ1RY @ 12:27, @ 2:03:20; 4irYQjtHZjY @ 59:01); SW Parent/Child dialog and refused illegal reorder (YIguko4mXRM @ 2:55:11, @ 2:55:50).
    - Today: roll, reorder, suppress, delete, Edit Feature; red failed only (`Desk/StageDetail.swift:133-313`).
    - Build: those menu items, group tiles that collapse, a dependents popover, a clear message when a reorder is refused.

14. **M-14 [P1] Browser: named views, construction, sketch visibility** (M; engine: yes, `view.save`, `view.apply`, `browser.visibility`)
    - Ref: FUS 1.5 Document Settings, Named Views, Origin, Bodies, Sketches, Construction, eye per node, folder eye hides content (7lKpzGtoQX0 @ 9:20, D0TYcB-2_8o @ 1:09:24); SW flyout tree over the canvas while a command runs (YIguko4mXRM @ 2:44:10).
    - Today: no named views, no construction folder, no eye on sketches, planes or components (`BrowserSidebar.swift:205-527`).
    - Build: the missing folders and eyes; keep the outline pickable while the command dialog replaces the inspector.

15. **M-15 [P2] Contextual S bar** (S; engine: UI only)
    - Ref: SW "Better than Fusion" 2, S shows the likely tools for the mode with a search field under them (XdWYW4HOLT4 @ 22:27).
    - Today: S opens the plain palette (`Desk/ProjectWindow.swift:269-280`).
    - Build: put a grid of mode-specific tools above the palette's search field.

16. **M-16 [P2] Trim by dragging, chain select, sketch fillet edit** (S; engine: yes, `sketch.trim`)
    - Ref: FUS press and drag across curves to trim many, double-click a curve selects its chain (D0TYcB-2_8o @ 47:01, F0qnbGiJ1RY @ 30:12); SW power trim (YIguko4mXRM @ 1:11:42).
    - Today: one click per trim (`DesignModel.swift:462-463`).
    - Build: a drag path that trims every crossed segment; double-click chain selection on B-1.

17. **M-17 [P2] Navigation bar and ViewCube details** (S; engine: yes, `view.normal_to`)
    - Ref: FUS 1.7 Orbit, Pan, Zoom are modes driven by left drag, Zoom Window, Look At picks a face (D0TYcB-2_8o @ 3:07 to 5:39); FUS 1.6 cube 90 degree arrows and "Set current view as Home" (7lKpzGtoQX0 @ 9:58).
    - Today: Orbit nudges 40 pt, Pan only shows a toast (`Desk/StageDetail.swift:81-127`).
    - Build: real modes, Zoom Window, cube arrows and a cube context menu.

18. **M-18 [P2] Confirmation corner and discard sketch edits** (S; engine: yes, `sketch.cancel`)
    - Ref: SW top right check and X, the X leaves a sketch without keeping changes (YIguko4mXRM @ 0:03:00, @ 0:03:10).
    - Today: Done in the ribbon and the dialog only (`Desk/StageRibbon.swift:95-97`).
    - Build: check and X under the ViewCube while a sketch or command runs.

19. **M-19 [P2] Ribbon dropdown details** (S; engine: UI only)
    - Ref: FUS shortcut on each dropdown row, kebab with Pin to Toolbar and Change Keyboard Shortcut, rich hover tooltips (gKGP1iFhd1s @ 1:00:00, ZmckF8zYbp0 @ 11:55).
    - Today: caption menus list commands without shortcuts or pinning (`StageRibbon.swift:209-319`).
    - Build: shortcuts in menus, a pin action stored per user, a tooltip with the registry summary.

20. **M-20 [P2] Document tabs and file menu in the app bar** (L; engine: yes, `doc.*` and file commands)
    - Ref: FUS 1.2 one tab per document with version and unsaved `*`, File menu, Save (7lKpzGtoQX0 @ 4:30).
    - Today: no tabs or file menu in the toolbar (`ProjectWindow.swift:803-840`); no `DocumentGroup` (IMPROVEMENTS.md item 6).
    - Build: Mac windows as tabs on a `DocumentGroup` base, unsaved marker in the title.

21. **M-21 [P2] Mass properties report** (S; engine: yes, `inspect.measure`, `inspect.center_of_mass`)
    - Ref: SW mass, volume, area, centre of mass, inertia, "relative to" frame, Copy to Clipboard (XdWYW4HOLT4 @ 35:50).
    - Today: a toast with volume, area and mass (`DesignModel.swift:719-731`).
    - Build: a report panel with a copy button.
