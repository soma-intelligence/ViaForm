# ViaForm today: CAD Design workspace inventory (Swift apps)

Snapshot of the working tree on branch `fusion-layout` (2026-11-23), uncommitted changes from
another session included as they stand. Read only; nothing here was run. Paths are relative to
`apple/` unless they start with `engines/`, `core/`, `bridge/` or `docs/`.

Shared ground for both apps:

- One model drives both front ends: `Shared/Model/DesignModel.swift` (tools, clicks, selection,
  preview, suggestions). Tools are the `Tool` enum in `Shared/Model/Tools.swift:5-169`: 12 sketch
  tools, 7 solid tools, 4 primitives, 6 combine/arrange tools, Measure, Select.
- Every action is an engine command. `DesignModel.run(id, params)` at
  `Shared/Model/DesignModel.swift:111-125` calls `CADEngine.execute`, then `refresh()`
  (`sketch.inspect`, `component.list`, scene rebuild).
- The engine registry (`sc_commands`, `bridge/src/lib.rs:154-169`) is loaded once into
  `CADEngine.commands` (`Shared/Engine/Engine.swift:198-201`). It holds 560 commands
  (counted from `engines/solidcraft/crates/engine/src/cmd/mod.rs:312` and the 60 modules it lists).
  231 have a ribbon tab, 329 have none.
- Commands without a dedicated tool open the generic form `GenericCommandForm`
  (`Shared/UI/CommonViews.swift:221`). It is a typed form for the 26 commands that
  `core/src/commands.rs:161-290` describes (solid.box, cylinder, sphere, torus, cone, extrude,
  revolve, fillet, chamfer, shell, draft, offset_face, press_pull, hole, both patterns, mirror,
  move, scale, combine, split_body, remove, body.rename, construct.plane.offset,
  construct.plane.at_angle, parameters.add). Edge and face fields take the viewport selection
  through a "Use Selection" button (`CommonViews.swift:362-375`). Every other command gets an
  "Advanced" raw JSON editor with the registry's one-line parameter doc
  (`CommonViews.swift:439-493`).
- The old Mac layout (`Desk/DeskRootView.swift`: AppBar, Ribbon, BrowserPanel, TimelineBar,
  ToolboxSearch) only opens under `--legacy-ui` (`Desk/DeskCommands.swift:258-293`). Everything
  below about the Mac describes `ProjectWindow`, the default. Two legacy types are still used by
  the new window: `CommandRouter` (`DeskRootView.swift:335-354`) and `CommandDialog`
  (`DeskRootView.swift:487-613`). `MarkingMenu` lives in `Desk/DeskPanels.swift:9-128`.

---

## MAC (Desk, `ProjectWindow`)

### 1. Screen zones

| Zone | Where (file:line) | Behaviour |
|---|---|---|
| Start screen | `Desk/ProjectWindow.swift:90-116`, `Desk/StartWindow.swift:10` | Templates and recent projects in place of the project. "Close Start" returns to the project. |
| Window toolbar | `ProjectWindow.swift:803-840` | Left: Projects (toggles the Data panel), Undo, Redo. The undo target depends on the stage (`undoTarget`, `ProjectWindow.swift:446-469`). Centre: job capsule, shown only while a job runs (`819-821`). Right: command search field (Command-K, `927-960`, icon only below 1150 pt), Flow Graph, Jobs, BOM (Shift-Command-B), Libraries (Shift-Command-L), Inspector toggle. There are no design tabs and no file menu in the toolbar. |
| Sidebar: BROWSER over PIPELINE OUTPUTS | `ProjectWindow.swift:166-168`, `Desk/BrowserSidebar.swift:10-52` | A NavigationSplitView column (256 pt ideal). It collapses on its own in a narrow window unless you chose otherwise (`ProjectWindow.swift:406-412`). In Design/Assemble/Render it shows `DesignOutline` (section 5). PIPELINE OUTPUTS (`BrowserSidebar.swift:56-87`) lists flow artifacts with Update All. |
| Ribbon row | `ProjectWindow.swift:208-234` | Workspace dropdown at the far left (`Desk/WorkspaceDropdown.swift:8`, Command-0, 9 stages), then `StageRibbon`. |
| Ribbon tabs | `Desk/StageRibbon.swift:115-131`, `170-200` | Tabs come from the registry: SOLID, SURFACE, SHEET METAL, PLASTIC, WELDMENTS, INSERT, INSPECT in Design. Render gets only RENDER tabs, Assemble gets ASSEMBLY plus INSPECT and INSERT. SKETCH is added while a sketch is open and selected on its own (`58-60`). |
| Ribbon panels | `StageRibbon.swift:141-151`, `209-319` | One panel per registry `panel`. Each panel shows up to 4 big icons (commands with a key first, `241-244`) and a caption menu that lists every command of the panel. Panels that do not fit fold into "More" (`209-233`). The FINISH SKETCH panel is left out (`145`). Clicking a command runs `CommandRouter.run`. |
| Ribbon trailing | `StageRibbon.swift:63-101` | Stage primary actions. "Done" (accent, Return) finishes the running command or closes an open sketch. |
| Canvas | `Desk/StageDetail.swift:9-78` | Metal viewport (`Shared/Render/Viewport.swift:11-24`) with sketch overlays. ViewCube 92 pt at top right (`41-45`). The command dialog sits under the cube when the inspector is hidden (`47-50`). Also: board link banner, error banner (errors stay until dismissed, confirmations become toasts, `54-58`, `72-76`), axis triad at bottom left, NavPill at bottom centre, marking menu (`69`). |
| Context pill / gizmo layer | `Desk/DesignOverlays.swift:162-316` | Floats beside the selection (placed by `AnchorLayout`, kept clear of the cube, dialog and nav pill, `209-217`). With a tool armed it shows a gizmo instead: a linear arrow or a revolve arc, plus a value badge (`221-259`). |
| NavPill | `StageDetail.swift:81-127` | Orbit (a fixed 40 pt nudge), Pan (only shows a toast explaining the gesture), Zoom in, Fit, Look At (selected face normal or sketch plane), Views menu (Perspective toggle and the standard views), Visual Style menu (`view.visual_style`: shaded with edges, shaded, wireframe; `view.grid`). |
| ViewCube | `Shared/UI/ViewCube.swift:4-5` | Click a face for a standard view, an edge or corner for that view, drag to orbit, home button. |
| Command dialog | `Desk/DeskRootView.swift:487-613`; docked at `ProjectWindow.swift:345-356` | Replaces the inspector column while a tool or generic command runs, or floats under the cube when the inspector is off. Holds the selection rows, the value field, pickers, Cancel and Done (section 2). |
| Inspector | `ProjectWindow.swift:248-251`, `Desk/InspectorPanel.swift`; compact overlay `ProjectWindow.swift:366-398` | Selection card, flow links, stage section. For Design (`InspectorPanel.swift:219-242`): units, body/sketch/feature counts, then the selected body's material, volume, mass, faces, edges, then the parameters. Everything is read only. Under about the compact width it floats over the stage (Esc closes it). |
| Bottom panel: timeline | `ProjectWindow.swift:779-799`, `StageDetail.swift:133-313` | `FeatureTimeline` in Design and Assemble (section 4). Toggled with Option-Command-B. |
| BOM panel | `ProjectWindow.swift:198-201`, `975-1009` | Resizable drawer between 200 and 720 pt. |
| Status bar | `ProjectWindow.swift:205-206`, `655-702` | "Face of X selected" or stage status, units, body count, core-ok mark. |
| Data panel | `ProjectWindow.swift:179-182`, `Desk/DeskPanels.swift:204` | Slides in from the left: new design, sample, recent files. |
| Command palette | `ProjectWindow.swift:269-280`, `Desk/CommandPalette.swift` | Command-K or S. Searches the flow catalog of every stage plus window commands. Recent commands come first. |
| Shortcut sheet | `ProjectWindow.swift:281-290`, `Desk/DeskKeys.swift:136` | Opened with ? or Command-/. |
| Toasts and undo flash | `ProjectWindow.swift:186-196`, `293-304` | "Undid Extrude1" and "Redid ..." over the stage. |
| Stale banner | `ProjectWindow.swift:768-777` | Shown at the canvas top when a stage is stale. |

### 2. CAD commands exposed in the UI

Routing: `CommandRouter.run` (`DeskRootView.swift:335-354`) behaves like this:
- `sketch.finish` finishes the sketch; `edit.undo`/`edit.redo` undo and redo.
- `solid.combine` opens the generic form.
- `solid.remove` calls `deleteSelection` (`solid.remove` for bodies, `face.delete` for faces, `DesignModel.swift:706-717`).
- `inspect.measure` calls `measureSelection` (a toast with volume, area and mass, `719-731`).
- Any id that matches a `Tool.commandID` arms that tool. Sketch on a selected face calls `sketchOnSelectedFace`.
- Anything else opens the generic form.

All palette and ribbon paths go through `StageActions.run` (`Desk/StageActions.swift:75`), and from there to `CommandRouter`.

Dedicated tools (armed in the canvas, value in the dialog, live preview through checkpoints):

| Tool | Core command and params sent | Where (DesignModel.swift unless noted) |
|---|---|---|
| Sketch | `sketch.create {plane: XY/XZ/YZ or face: [x,y,z]}`, then the camera looks along the normal and Line is armed | `402-406`; plane buttons in the dialog `DeskRootView.swift:572-575` |
| Line | `sketch.line {points:[a,b]}` per click, chained; clicking the first point closes the chain | `452-459` |
| Rectangle / Center Rect | `sketch.rectangle.two_point {p0,p1}` / `sketch.rectangle.center {center,corner}` | `478-481` |
| Circle | `sketch.circle.center {center, radius}` | `482-484` |
| Arc | `sketch.arc.three_point {start,end,through}` | `489-490` |
| Polygon | `sketch.polygon.inscribed {center,radius,sides,angle}`; sides come from the value (default 6) | `485-488` |
| Slot | `sketch.slot.center_to_center {p0,p1,width}` (3 clicks) | `491-497` |
| Spline | `sketch.spline.fit_point {points}` on Return or Done | `506-511` |
| Point | `sketch.point {point}` | `498-499` |
| Sketch Fillet | `sketch.fillet {point: snapped point id, radius}` | `466-467` |
| Trim | `sketch.trim {curve, at}` | `462-463` |
| Offset | `sketch.offset {curves:[c], distance}` | `464-465` |
| Extrude | `solid.extrude {distance, operation?, profiles?}`. Finishes an open sketch first and takes the last sketch. | `575-579`, `553-556` |
| Revolve | `solid.revolve {axis: x/y/X/Y/Z, angle: "N deg", operation?}` | `580-583` |
| Press Pull (Push / Pull) | `solid.press_pull {face, distance}` | `584-586` |
| Fillet / Chamfer | `solid.fillet {edges, radius}` / `solid.chamfer {edges, distance}` | `587-592` |
| Shell | `solid.shell {faces, thickness}` | `593-595` |
| Box, Cylinder, Sphere, Torus | `solid.box/cylinder/sphere/torus`, one size value, placed by a click on a face or the grid-snapped ground plane | `665-675`, `382-388` |
| Union / Subtract / Intersect | `solid.combine {target, tools, operation: join/cut/intersect}` with 2 or more bodies (from the pill or marking menu). From the ribbon, `solid.combine` opens the typed generic form. | `687-692`, `DesignOverlays.swift:307-309` |
| Move | `solid.move {bodies, translate}` with X, Y, Z fields on Done | `694-698`, `DeskRootView.swift:560-568` |
| Mirror | `solid.mirror {bodies, plane: XY/XZ/YZ}` | `700-704` |
| Delete | `solid.remove {bodies}` or `face.delete {faces}` | `706-717` |
| Measure | `inspect.measure {bodies?}` | `719-731` |

Preview mechanism: `edit.checkpoint` / `edit.restore_checkpoint`. Each value change replaces the
last preview. Commit runs `restore_checkpoint {forget:true}` (`DesignModel.swift:601-656`).
Command dialog fields (`DeskRootView.swift:530-576`):
- the selection row (Profile, Faces, Edges or Bodies);
- a `ValueField` (units and arithmetic through `NumberField`/`VFExpression`; step 1, or 15 for degrees);
- an Operation picker for Extrude/Revolve (Automatic, New Body, Join, Cut, Intersect);
- a Revolve axis picker (Sketch X, Sketch Y, X, Y, Z);
- Move X/Y/Z fields, a Mirror plane segmented control and the Sketch plane buttons.

Extrude has no direction, taper, two-sides, to-object or thin options in this dialog. Those
are only in the engine params (`engines/solidcraft/crates/engine/src/cmd/features.rs:36-43`).

Entry points:
- **Ribbon**: every registry command with a tab, in its panel (231 commands). Only the 12 sketch
  tools and the solid tools in the table above have canvas behaviour. The rest open the generic
  form, typed or JSON.
- **Marking menu** (right click or Control-click on the canvas, `DeskPanels.swift:29-63`).
  Outside a sketch the wheel holds Sketch, Push / Pull, Extrude, Redo, Move, Delete, Fillet,
  Undo. In a sketch it holds Line, Finish Sketch, Rectangle, Redo, Trim, Delete, Circle, Undo.
  The overflow list under it holds Repeat Last (`lastTool`), Fit, Measure and Toolbox Search
  (which opens the palette, `ProjectWindow.swift:312-315`). The slices are buttons (click). A
  drag toward a slice is mentioned in the doc comment but no drag gesture is implemented.
- **Command palette** (Command-K or S): every non-planned registry command (the flow catalog
  takes all `command_specs`, `core/src/flow/commands.rs:123-134`; untabbed ones are in group
  "MORE"), plus window commands (`ProjectWindow.swift:596-621`: panels, next and previous
  stage, undo, redo, theme, Zoom to Fit, 7 standard views). The palette is the only place
  where the 329 untabbed commands are reachable.
- **Context pill** (`DesignOverlays.swift:272-291`): up to 4 entries of `model.suggestions`,
  then Joint (when there are components, outside Assemble), Show Board (body linked to a PCB),
  Stress Here (`simulate.stress`), and More (opens the marking menu at the anchor).
- **Keys**: see section 6.
- **Browser**: Sketch on a plane, Edit Sketch, Rename body (`body.rename` through
  `renameBody`, `Shared/UI/CommonViews.swift:527`), Hide/Show (`browser.visibility`), Delete.

### 3. Sketch system

- **Start**: the Sketch tool, then a click on a planar face or the XY/XZ/YZ buttons in the
  dialog (`DesignModel.swift:346-350`). Other ways in: K, the marking menu, Return or a
  double-click on an Origin plane in the browser (`BrowserSidebar.swift:236-244`, `377`).
  The camera turns normal to the plane (`DesignModel.swift:404`, `414-420`). Edit an existing
  sketch with `sketch.edit` from the browser (`BrowserSidebar.swift:412-415`).
- **Tools with canvas behaviour**: the 12 in section 2. The SKETCH ribbon tab also lists all
  SKETCH registry panels: CREATE 42, CONSTRAINTS 15, MODIFY 12, PATTERN 3, INSERT 5,
  INSPECT 10. Ellipse, 3-point rectangle, tangent arc, conic, text, mirror, patterns, project,
  extend, break, chamfers and similar open the generic JSON form, with no click-to-draw.
- **Snapping**: `sketch.snap {at, radius}` on every hover and click, radius 3 percent of the view
  half height. The first snap that is not "on_curve" wins; the fallback is half the grid step
  (`DesignModel.swift:422-432`). The cursor ring grows on a snap, and a label shows the
  coordinates and the snap type (`Viewport.swift:52-58`). The rubber band preview is a dashed
  polyline (`DesignModel.swift:514-538`, `Viewport.swift:42-47`).
- **Ending**: Return or Escape ends a line chain or spline (`Viewport.swift:270-271`). Done in
  the ribbon or the dialog finishes the sketch (`StageRibbon.swift:95-97`,
  `DeskRootView.swift:600-608`). `sketch.finish` also runs when Extrude or Revolve is armed
  (`DesignModel.swift:555`).
- **Constraints**: the drawing tools do not add or show constraints. The 15 constraint commands
  (`sketch.constraint.*`, `sketch.auto_constrain*`, `sketch.constrainer`) appear only as ribbon
  and palette entries. Each opens the JSON form, which needs entity ids typed by hand. No
  constraint glyphs are drawn: `sketch.glyphs` is read for dimensions only
  (`Shared/Model/SketchInfo.swift:125-131`).
- **Dimensions**: shown as chips on the canvas while a sketch is open
  (`Shared/Render/SketchCanvasLayers.swift:57-133`). A driven dimension is shown in grey and in
  parentheses and cannot be edited. A failing dimension is red. Click to type a number, a unit
  or an expression; Return sends `parameters.change {name: param, expression}`
  (`Shared/Model/DesignInteractions.swift:49-62`). Creating a dimension (`sketch.dimension`,
  key D) only works through the JSON form. There is no click-two-entities flow.
- **Point drag**: with Select in an open sketch, dragging a point (8 pt radius, not fixed
  points) sends live `sketch.drag {entity, from, to, live:true}` frames and `sketch.drag_end`
  on release (`DesignInteractions.swift:65-94`, `Viewport.swift:158-162`, `172-177`,
  `184-187`). Points are drawn as rings; fixed points are grey (`SketchCanvasLayers.swift:41-49`).
- **Profiles**: while Extrude is armed, the last sketch's profiles are drawn. Picked profiles are
  filled, the others dashed, and the hovered one is washed (`SketchCanvasLayers.swift:25-40`).
  A click toggles a profile; picking all or none takes them all
  (`DesignInteractions.swift:25-32`, `DesignModel.swift:330-334`).
- **Defined state**: nothing shows under, fully or over-constrained state. There is no
  degrees-of-freedom readout and no colouring by solve state (grep for constrained, dof and
  fully in Desk, Touch and Shared found none). The only solve feedback is the red failing
  dimension chip.

### 4. History / timeline

`FeatureTimeline` (`Desk/StageDetail.swift:133-313`):
- **Layout**: a "History" caption with "N of M built", transport buttons, then one 40 pt tile
  per feature on a rail. The rail is solid up to the playhead and dashed after it. Tiles show
  the feature icon; failed tiles are red, suppressed tiles have a dashed border and warning
  tint, rolled back tiles are faded (`219-236`).
- **Rollback**: click a tile (`timeline.roll_to {position}` via `rollTimeline`, `239`). You can
  also drag the playhead (`285-297`) or use start / step back / play to end / step forward /
  end (`147-165`).
- **Reorder**: drag a tile onto another to send `timeline.reorder {feature, position}`
  (`253-258`). The context menu also has Move Earlier and Move Later (`264-266`).
- **Suppress**: context menu `timeline.suppress {feature}`, toggles (`262`).
- **Delete**: context menu `timeline.delete {feature}` (`268`).
- **Edit**: the context menu "Edit Feature" sends `timeline.edit {feature: name}` with no
  `set` (`261`, `248`). The engine refuses that call: "`set` must be an object of fields"
  (`engines/solidcraft/crates/engine/src/cmd/edit.rs:1181`). No UI loads a feature back into
  its dialog. `timeline.inspect` and `timeline.redefine` are never called from Swift. In
  practice, editing a feature's values is not available. The workaround is changing a
  parameter, but the Inspector parameter list is read only.
- No feature folders, rename, dependents view or copy/paste in the UI. Those commands
  (`timeline.group`, `rename`, `dependents`, `copy`, `paste`) are reachable only through the
  palette JSON form.

### 5. Browser / items

`DesignOutline` (`Desk/BrowserSidebar.swift:205-527`) is a real `List` with multi-select.
Click replaces, Shift extends, Command toggles; type-select, Return and double-click run the
row's primary action.
- **Rows**: the document (product title), Settings (Units), Origin (XY, XZ, YZ planes),
  Components (when the assembly is not empty: grounded pin, PCB link mark), Bodies (eye toggle,
  rename in place), Sketches, Parameters (`name = expression`, read only).
- **Visibility**: the eye on each body row, and Hide/Show in the context menu, send
  `browser.visibility {visible, items}` (`DesignModel.swift:810-812`). Hidden state comes from
  `snapshot.bodies[].visible`, with a local fallback set (`BrowserSidebar.swift:423-433`).
  Sketches, planes and components have no visibility toggle. There is no lock.
- **Selecting** bodies or components in the browser sets `model.selectedBodies` and clears
  face/edge picks (`313-326`).
- **Delete** sends `solid.remove`, with Undo in a toast (`436-446`).
- No feature list in the browser, no named views, no folders or groups, no drag to reparent.

### 6. Input mappings

Mouse (preset "ViaForm", the default; Settings > Navigation offers ViaForm, Fusion, Blender and
Onshape, `Shared/UI/Components/Navigation.swift:8-86`):
- Left click: pick (replace). Shift-click adds. Command-click without a drag toggles
  (`Shared/Render/Viewport.swift:149-168`, `189-193`).
- Double-click: toggles the whole body in `selectedBodies` (`DesignModel.swift:375-380`).
- Right click without a drag: marking menu. Right drag: orbit. Control-click: marking menu
  (`Viewport.swift:154`, `197-209`).
- Middle drag: pan. Shift + middle drag: orbit.
- Option + left drag: orbit. Command + left drag: pan.
- Scroll wheel: zoom toward the point under the cursor (`243-258`).
- In the Fusion preset, right drag does nothing and middle/Shift-middle work as Fusion does.

Trackpad:
- Two-finger scroll: pan. Shift or Option + two fingers: orbit.
- Pinch: zoom at the cursor (`Viewport.swift:245-264`).
- Command + scroll: zoom.

Keys:
- **Window key monitor** (`ProjectWindow.swift:505-574`, `Desk/DeskKeys.swift:13-133`): every
  single-letter registry shortcut runs its command from anywhere in the 3D stages unless a text
  field has focus. L Line, R Rectangle, C Circle, D Dimension (JSON form), X Construction
  (JSON), O Offset, T Trim, G Transform (JSON), P Project (JSON), E Extrude, F Fillet, H Hole
  (typed form), Q Press Pull, M Move, J Joint, I Measure, A Appearance. The list comes from
  the registry `.key(...)` calls.
- **Window keys**: S command palette, K sketch on the selected face or arm Sketch, 6 isometric,
  Control-1 to Control-7 standard views, F6 fit, ? shortcut sheet.
- **Escape off the viewport**, in order: close the marking menu, cancel the tool or generic
  command, hint how to stop a running job, else clear the selection.
- **Viewport keys** (`Viewport.swift:266-287`): Escape cancels the preview or ends the chain.
  Return/Enter commits the preview or ends the chain. Delete/Forward Delete deletes the
  selection.
- **Menu bar**: Command-Z and Shift-Command-Z (stage aware), Command-K, Command-1 to 9 stages,
  Command-[ and Command-], Command-Return stage primary, Command-. stop job, Option-Command-I
  inspector, Option-Command-B bottom panel (`Desk/DeskCommands.swift:158-238`).
- **Distance handle**: Shift snaps to 5 mm, Command drags freely, default step 0.5 mm
  (`Shared/Render/DesignHandleView.swift:79-87`).

### 7. Selection model and contextual suggestions

- **Picks**: `Pick.face(mesh, face, point, normal)` or `Pick.edge(mesh, edge, point)`
  (`Shared/Engine/Picking.swift:6-20`). CPU ray cast. Engine commands receive world points.
- **Edges** are pickable only with Select, Fillet or Chamfer armed (`DesignModel.swift:312`).
- **Bodies** are a separate set, `selectedBodies`, filled by double-click or the browser.
- **Hover** highlights the face or edge under the mouse (`DesignModel.swift:296-310`,
  `Viewport.swift:139`).
- No box, window or lasso selection, and no selection filter UI. `select.filter` exists only
  in the registry.
- **Suggestions** (`DesignModel.swift:735-743`):
  - Open sketch: Extrude, Revolve.
  - One body: Move, Mirror, Shell, Delete, Measure.
  - Two or more bodies: Union, Subtract, Intersect, Move, Delete.
  - Edges only: Fillet, Chamfer.
  - One face: Push / Pull, Sketch, Shell, Delete.
  - Several faces: Shell, Delete.
- **Face handle**: with a single face picked and Select active, a Shapr3D-style distance handle
  appears on it (`DesignInteractions.swift:99-101`, `DesignOverlays.swift:183-188`). Dragging
  it arms Push / Pull quietly and commits on release as one undo step
  (`DesignInteractions.swift:136-164`). While Extrude is armed the handle sits at the area
  centroid of the picked profiles (`105-113`).
- **Status bar** names the selection ("Face of Bracket selected", `ProjectWindow.swift:671-677`).

---

## TOUCH (iPad and iPhone, `TouchShell`)

`compact` means an iPhone, or an iPad window narrower than 820 pt (`Touch/TouchRootView.swift:79`).

### 1. Screen zones

| Zone | Where (file:line) | Behaviour |
|---|---|---|
| Top capsule | `TouchRootView.swift:351-367`, `Touch/TouchChrome.swift:116-220` | Workspace button (9 stages, popover on iPad, sheet on iPhone), Browser (sheet), title and revision, Undo (named), Redo, Items or History switch (inline segments, or a menu when narrow), Commands (palette), Jobs, Share menu. |
| View cluster | `TouchRootView.swift:374-400` | iPad, not compact. ViewCube 52 pt and an eye menu: Home View (iso), Perspective, Zoom to Fit, standard views, Section View (`inspect.section {plane: XZ, at: 0}` or `{clear:true}`, `598-602`), Isolate Selection (hides the other bodies with `browser.visibility`, `605-615`). |
| Tool groups | `TouchRootView.swift:242-247`, `269-278`; `Touch/TouchTools.swift:67-125` | Left edge, mid height, 76 pt columns. Design gets two groups (section 2). Assemble and Render get catalog groups (`TouchTools.swift:144-165`). |
| Right card | `TouchRootView.swift:280-296` | 320 pt floating card: Items, or History, or the stage inspector. `TouchDesignInspector` (`Touch/TouchStages.swift:8-62`) shows the tool card (value, slider, pickers, Cancel, Done) while a tool is armed. With bodies selected it shows volume, mass (assumed PA12), faces, material and flow rows. Otherwise it shows design counts and flow rows. |
| Anchor layer | `TouchRootView.swift:237-239`, `TouchTools.swift:283-343` | Context pill placed under the selection, then beside it, then above it (`171-194`). Also the distance handle with a 44 pt grip, and a value bubble with a dotted arc while a tool is armed. Design and Assemble only. |
| Bottom stack | `TouchRootView.swift:254-261` | Board link banner, message banner, PlaneChooser while Sketch is armed (`889-908`), HistoryBar (Design only, hidden while anything is selected, `257-260`), SummaryCapsule (bodies, components, steps or joints/motors, revision, `455-472` of TouchTools). |
| Compact layout | `TouchRootView.swift:299-318` | ViewCube 70 pt at the top right. The bottom shows PlaneChooser, or the `ToolSession` bar while a tool is armed, or the `SuggestionBar`, then the `ToolRail` strip (`812-827`). Items and History open as sheets (`154-161`). No anchor layer and no history bar in compact. |
| Sheets | `TouchRootView.swift:123-168` | Browser sheet (`Touch/TouchSheets.swift:7`), palette overlay (`TouchSheets.swift:209`), CommandBrowser (All Commands, `TouchRootView.swift:1111-1154`), generic command form as a sheet (`162-164`), library, BOM full screen, file import, export (design .sc, STEP, STL, KiCad). |
| Stage intro | `TouchRootView.swift:118-122` | Shown at the bottom on the first visit. |

### 2. CAD commands exposed in the UI

The same `Tool` set and `DesignModel` commands as the Mac (see the Mac table for core
commands). Tapping a tool runs `TouchToolActions.activate` (`TouchTools.swift:129-140`).
Combine, Delete and Measure act at once. Sketch on a picked face starts the sketch. A second
tap on an armed tool disarms it.

- **iPad Sketch group** (`TouchTools.swift:73-82`): Select, then Sketch and Measure. With a
  sketch open: Select, the 12 sketch tools, Finish.
- **iPad Solid group** (`TouchTools.swift:86-103`): Extrude, Revolve, Push / Pull, Fillet.
  "Shapes" menu: Box, Cylinder, Sphere, Torus. "Combine" menu: Union, Subtract, Intersect.
  "More" menu: Chamfer, Shell, Move, Mirror, Delete, All Commands (opens the palette, because
  `showCommands` is bound to `showPalette` at `TouchRootView.swift:272`).
- **iPhone ToolRail strip** (`TouchRootView.swift:812-827`): solid and primitive tools, or the
  sketch tools plus Finish. "All Commands" opens `CommandBrowser`. The iPad column variant
  (`829-854`) exists but is only used in compact.
- **Tool session** (`Touch/TouchStages.swift:241-394`):
  - `NumberField` with expressions, plus a slider in the card (range 0 to max(100, 4x
    default), 0 to 360 degrees, 3 to 24 sides).
  - Operation picker: Auto, New Body, Join, Cut. There is no Intersect, unlike the Mac.
  - Revolve axis picker.
  - Move X/Y/Z fields; Return moves to the next field.
  - Mirror plane picker.
  - Cancel and Done (Command-Return).
- **Palette** (`TouchSheets.swift:209-240`, run at `TouchRootView.swift:537-552`): the flow
  catalog, the same set as the Mac palette. Design-source commands arm the matching tool or open
  the generic form sheet. PCB commands jump to Electronics.
- **CommandBrowser**: every registry command grouped by tab, searchable. It arms the tool or
  opens the generic form (`TouchRootView.swift:1123-1129`).
- **Context pill**: up to 5 suggestions, plus Stress Here (opens Generate) and Fly It (opens
  Simulation) when bodies are selected (`TouchRootView.swift:321-327`, `TouchTools.swift:332-338`).
  Shown only while Select is the tool (`TouchTools.swift:320`).
- **Suggestion bar** (compact): all suggestions plus a clear button (`TouchRootView.swift:911-935`).
- **View menu**: section, isolate, views (see zones).
- No marking menu and no ribbon on touch.

### 3. Sketch system

- **Start**: the Sketch tool shows PlaneChooser ("Tap a face, or pick a plane", XY/XZ/YZ,
  cancel; `TouchRootView.swift:889-908`). Tapping a face starts the sketch on it. Sketch from
  the context pill on a picked face. Edit an existing sketch from Items (`1041-1045`) or the
  Browser sheet.
- **Tools**: the same 12 with the same core commands. Hints are in `ToolSession.hint`
  (`TouchStages.swift:353-366`), for example "Tap points; double-tap ends".
- **Ending**: a double tap ends a line chain or spline (`Viewport.swift:358-362`). Done in the
  tool session calls `endChain`. Finish in the tool group closes the sketch.
- **Snapping and rubber band**: shared with the Mac. Hover runs on taps, on pointer hover and
  on Pencil hover (`Viewport.swift:351-356`, `364-366`).
- **Dimensions**: the same `SketchDimensionLayer` is in the shared `Viewport`, so the chips show
  and are tappable to type a value (`Viewport.swift:20`, `SketchCanvasLayers.swift:57-133`).
- **Point drag**: not available. The iOS `CADView` has no sketch-drag path; `beginSketchDrag`
  is only called from the macOS `mouseDown` (`Viewport.swift:158`).
- **Constraints, defined state, constraint glyphs**: same as the Mac. Reachable only as JSON
  form commands from the palette or CommandBrowser; no glyphs; no solve-state colouring.
- **Profiles**: the profile layer is shared. A tap toggles a profile while Extrude is armed.

### 4. History

- **iPad HistorySidebar card**, iPhone sheet (`TouchRootView.swift:704-783`): a vertical list.
  Each row shows icon, name, and type plus state ("Extrude · Rolled back", "· Suppressed",
  "· Error"). Tap a row to roll back to it (`timeline.roll_to`). An ellipsis menu, a long
  press and swipe actions offer Roll Back Here, Suppress/Unsuppress and Delete (with Undo in a
  toast) (`658-680`). There is a "Roll to End" row.
- **Reorder**: `.onMove` sends `timeline.reorder` (`760-763`). The file has no EditButton or
  edit mode toggle, so whether drag-to-reorder is reachable was not verified.
- **HistoryBar** (iPad Design, bottom): horizontal chips. Tap rolls back. Rolled back chips are
  dimmed and dashed; error chips show a triangle. Long press gives the step actions. There is
  also a Roll to End button and a Steps menu (`1050-1108`).
- **Hardware keyboard**: arrow keys step the marker (`683-700`).
- No Edit Feature on touch at all.

### 5. Items

- **ItemsPanel** (`TouchRootView.swift:938-1046`):
  - Components: tap selects their bodies; PCB link and grounded marks.
  - Bodies: tap toggles selection; the eye sends `browser.visibility`; a volume subtitle; long
    press gives Select/Deselect and Hide/Show.
  - Sketches: an Edit button.
  - Parameters: read only.
  - No rename, delete, lock or group here.
- **Browser sheet** (`Touch/TouchSheets.swift:7-200`): the stage's flow tree with eye and lock
  (flow-level lock, `flow.setLocked`), Rename Body through an alert, pipeline outputs, files
  (new, open, save design) and samples.

### 6. Input mappings

Gestures (`Shared/Render/Viewport.swift:312-401`):
- **Tap** (finger or Pencil): pick in toggle mode (`click(additive:true)` maps to `.toggle`,
  `DesignModel.swift:319-321`, `Viewport.swift:351-356`).
- **Double tap**: ends the chain while a sketch tool is armed, else toggles the whole body.
- **One finger drag** (direct touch only): orbit.
- **Two finger drag**: pan.
- **Pinch**: zoom toward the touched point. It runs alongside the pan.
- **Two finger tap** on the 3D view: undo, with a toast offering Redo. Installed on the window
  and ignored while a sheet is up (`TouchTools.swift:479-529`, `TouchRootView.swift:102`,
  `483-494`).
- **Pointer hover** (trackpad or Pencil hover): highlight (`UIHoverGestureRecognizer`).
- **Distance handle**: drag the 44 pt grip, 0.5 mm steps (no modifier snapping on touch).

Apple Pencil:
- A Pencil pan gesture "clicks" at stroke begin and end (`Viewport.swift:335-337`,
  `368-373`). With Line, one stroke therefore places two points.
- The Pencil never orbits.
- Pencil double tap (iPadOS 17.5 and later) switches between the current tool and Select
  (`Touch/TouchSampleDrone.swift:39-63`, `TouchRootView.swift:110`).
- No squeeze, barrel roll or hover preview.

Hardware keyboard (`Touch/TouchChrome.swift:453-600`): Command-Z, Shift-Command-Z, Command-K
palette, Command-0 workspaces, Command-1 to 9 stages, Command-[ and Command-], Command-Return
(finish the tool or sketch, else the stage action, `TouchRootView.swift:443-456`), Command-.,
Shift-Command-U, Option-Command-I inspector, Shift-Command-B, Shift-Command-L, Escape
(palette, then the tool, then the selection, `430-440`), Command-/ shortcuts. There are no
single-letter tool keys on touch.

### 7. Selection and suggestions

- Same `DesignModel` selection, suggestions and anchor as the Mac, except that a tap toggles
  (there is no replace mode). Clearing goes through the pill's X, the suggestion bar's X or
  Escape.
- The context pill is anchored by `AnchorLayout` and placed by `TouchAnchor`, under the
  selection first. Compact uses the bottom `SuggestionBar` instead.
- The inspector card switches to the selection card when bodies are selected
  (`TouchStages.swift:18-25`).

---

## 8. Core modelling commands with no dedicated UI

"Dedicated UI" means a canvas tool, a native dialog or a browser/timeline action. On both
platforms every non-planned registry command is reachable through the palette (and
CommandBrowser on touch) and runs through `GenericCommandForm`: typed for the 26 commands
listed at the top, raw JSON for the rest. A `*` below marks commands that also have a Mac
ribbon place; touch has no ribbon. Source: `engines/solidcraft/crates/engine/src/cmd/*`, the
modules listed in `command_specs` (`cmd/mod.rs:312`).

- **Sketch creation without click-to-draw** (generic form only):
  - rectangles and circles: `sketch.rectangle.three_point*`, `rectangle.rounded*`,
    `circle.two_point*`, `circle.three_point*`, `circle.two_tangent*`, `circle.three_tangent*`;
  - arcs: `arc.center_point*`, `arc.tangent*`;
  - polygons: `polygon.circumscribed*`, `polygon.edge*`;
  - slots: `slot.overall*`, `slot.center_point*`, `slot.arc_three_point*`, `slot.arc_center*`;
  - curves: `ellipse*`, `spline.control_point*`, `spline.control_point_5*`, `conic*`,
    `centerline*`, `line.midpoint*`, `text*`, `equation_curve*`;
  - references: `project*` (P), `intersect*`, `include_3d*`, `project_to_surface*`,
    `intersection_curve*`, `spun_profile*`, `isoparametric_curve*`, `fit_curves_to_section*`;
  - `sketch.infinite`, the 3D sketch commands (`line3d`, `spline3d`, `arc3d`, `point3d`,
    `move3d`) and `draw.dimensioned`.
- **Sketch constraints and dimensions**:
  - `sketch.constraint.horizontal_vertical*`, `coincident*`, `tangent*`, `equal*`,
    `parallel*`, `perpendicular*`, `fix*`, `midpoint*`, `concentric*`, `collinear*`,
    `symmetry*`, `curvature*`, `polygon*`;
  - `sketch.auto_constrain*`, `auto_constrain_from_datum*`, `finish_auto_constrain*`,
    `constrainer*`;
  - `sketch.dimension*` (D, creation), `toggle_driven`, `toggle_diameter`, `dimension_text`,
    `construction*` (X), `solve`.
- **Sketch modify**:
  - chamfers: `sketch.chamfer.equal_distance*`, `distance_angle*`, `two_distance*`;
  - `extend*`, `break*`, `scale*`, `transform*` (G), `move*`, `blend_curve*`;
  - patterns: `mirror*`, `pattern.circular*`, `pattern.rectangular*`;
  - `trim.path`, `offset.break`;
  - splines: `spline.insert_point`, `remove_point`, `reverse`;
  - `delete`, `copy`, `cut`, `paste`, `redefine`, `loose_ends`, `loose_ends.tie`,
    `insert_dxf*`, `insert_svg*`, `export_dxf`, `cancel*`.
- **Solid**:
  - typed form: `solid.hole*` (H), `pattern.rectangular*`, `pattern.circular*`, `draft*`,
    `offset_face*`, `scale*`, `split_body*`, `cone*`;
  - JSON form: `solid.sweep*`, `loft*`, `pattern.path*`, `pipe*`, `thread*`, `coil*`, `rib*`,
    `web*`, `emboss*`, `split_face*`, `replace_face*`, `boundary_fill*`, `bounding_solid*`,
    `align*`;
  - `body.repair`, `body.print_face`, `mesh.convert`.
- **Construction geometry**: 20 `construct.*` commands (planes, axes, points), all `*`. Only
  `plane.offset` and `plane.at_angle` are typed. The browser shows only XY, XZ and YZ; built
  construction geometry is not listed.
- **Surface**: 18 `surface.*` commands, all `*`.
- **Sheet metal**: 13 `sheet.*`.
- **Plastic**: 7 `plastic.*`.
- **Weldment frame**: `frame.member*`, `frame.profile.*`.
- **Point cloud**: `pointcloud.*`.
- **Timeline**: `timeline.inspect`, `timeline.redefine`, and `timeline.edit` sent with a
  working `set`; also `rename`, `group`, `ungroup`, `rename_group`, `move_to_group`,
  `move_many`, `reorder_many`, `dependents`, `copy`, `paste`, `compute_all*`, `play*`,
  `export_script`.
- **Parameters**: `parameters.add` (typed form) and `list`, `rename`, `delete`, `favorite`,
  `move`, `comment`, `users`, `graph`, `export`, `import`. Dimension chips use
  `parameters.change`; there is no parameter table editor.
- **Browser and selection**: `browser.reparent`, `group`, `ungroup`, `move`, `order`,
  `expand_all`, `collapse_all`; `select.set`, `filter`, `clear`, `same_look`;
  `selection.delete`.
- **View**: `view.save`, `apply`, `list` (named views), `view.normal_to`, `view.spin`,
  `view.ground_shadow`, `view.ambient_occlusion` and the rest of the 40 `view.*` commands.
  Only `view.visual_style` and `view.grid` are wired (Mac NavPill); the standard views and fit
  are done in Swift on the camera.
- **Inspect**: `inspect.zebra*`, `draft*`, `curvature_comb*`, `curvature_map*`,
  `minimum_radius*`, `isocurve*`, `continuity*`, `interference*`, `center_of_mass*`,
  `section*` (Mac). On touch, `inspect.section` is wired (XZ at 0 only). No clip or analysis
  handling was found in `apple/Shared/Render`; whether the engine's scene output already cuts
  the mesh was not checked. Also `inspect.clearance` and `compare`.
- **Components**: 32 `component.*` (create, activate, edit in place, from_bodies,
  insert_design, links, ...). Only `component.list` and `component.metadata` are read, to fill
  the browser. Joints (`joint.*`, 19) belong to the Assemble stage and are out of scope here.

## 9. Known gaps listed in IMPROVEMENTS.md

`IMPROVEMENTS.md:5-25` (front end). The file opens with "Nothing here is done yet." The code
disagrees on several items:

1. **Drag handles**. Listed as to do; implemented (`Shared/Render/DesignHandleView.swift`,
   `DesignInteractions.swift:96-166`). Push / Pull and Extrude only. No handles for fillet,
   chamfer, shell, revolve or move.
2. **Profile picking**. Implemented (`DesignInteractions.swift:25-44`, `SketchCanvasLayers.swift:25-40`).
3. **Sketch dimensions and constraints on canvas**. Partly done: dimension text is editable in
   place and points drag live. Still missing: constraint glyphs, dimension creation and
   constraint creation on canvas.
4. **Background scene build**. Implemented as a worker with double buffering
   (`DesignModel.swift:151-189`, `838-866`).
5. **GPU picking**. Not done; picking is a CPU ray cast (`Shared/Engine/Picking.swift`).
6. **Documents** (`DocumentGroup`, iCloud, autosave, multiple Mac windows). No
   `DocumentGroup` was found in `apple/`.
7. **Native dialogs for hole, pattern, mirror, sweep, loft, joint, sheet metal**. Partly done:
   the typed schema forms cover hole, both patterns and mirror. Sweep, loft, joint and sheet
   metal remain JSON.
8. **Apple Pencil Pro** (squeeze, barrel roll, hover preview). Only double tap is wired.
9. **Section, zebra, draft through the scene's `clip` and `analysis` fields**. Not drawn by the
   renderer (no handling in `Shared/Render`).
10. **XCFramework + Swift package**. Not checked.

Core items (`IMPROVEMENTS.md:27-34`): an official C ABI crate upstream, a scene diff, iOS in
CI. These are outside the Swift apps.

Other gaps seen in the code and not listed in IMPROVEMENTS.md:
- The Mac "Edit Feature" sends no `set`, so the engine refuses it. No feature dialog
  round-trip exists.
- There is no sketch solve-state display.
- The marking menu has no drag gesture.
- Touch has no sketch point drag, and its Operation picker has no Intersect.
- No box selection and no selection filters.
- Parameters are read only in both apps.
