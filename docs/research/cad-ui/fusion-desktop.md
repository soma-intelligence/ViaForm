# Autodesk Fusion (desktop): UI and workflow reference from tutorial videos

Purpose: a precise picture of how Fusion desktop looks and behaves, so the ViaForm Mac app can
match its layout, workflows and input mappings. ViaForm keeps its own icons, colours and names.
This file extends `docs/ui-reference.md` (Desktop section) and does not replace it.

## Sources

| videoId | Title (short) | UI version seen | Transcript |
|---|---|---|---|
| 7lKpzGtoQX0 | "Fusion 360 Year 2026, 30 minute guide" | newest (files dated Jan 2025): MANAGE tab, CONFIGURE panel | yes |
| gKGP1iFhd1s | "Fusion 360 Complete Tutorial (2025)" | newest, title bar "Autodesk Fusion", Sept 2025 | no, frames only |
| B9eJBHes9Js | "Complete 3D Modelling Marathon" | newest (personal licence) | music only, frames only |
| D0TYcB-2_8o | "complete beginner tutorial, step by step" | 2024 ("Autodesk Fusion 360", AUTOMATE panel, no MANAGE tab) | yes |
| 4irYQjtHZjY | "Module 1, CAM, absolute beginners (2026)" | newest, Manufacture workspace | yes |
| M0TQR8t0pQ8 | "Learn Fusion 360 in 2.25 hours (2023)" | 2023 | no, frames only |
| F0qnbGiJ1RY | "Crash course, workflow advice + tips" | about 2022 (live stream) | yes |
| ZmckF8zYbp0 | "Robotic gripper" | about 2021 ("Fusion 360 (Personal)") | yes |

Citation format: (videoId @ mm:ss) or (videoId @ h:mm:ss). "frame" means seen on screen.
"(inferred)" marks anything not directly said or seen. About 130 frames were examined in total
(own extracts plus two delegated passes over F0qnbGiJ1RY and 4irYQjtHZjY).

---

## 1. Screen zones (newest UI) and version differences

### 1.1 Overall layout (newest)

Frame 7lKpzGtoQX0 @ 0:40, 4:30, 23:10; gKGP1iFhd1s @ 8:00, 1:00:00.

```
+------------------------------------------------------------------------------------------+
| [grid][file v][save][undo v][redo v][home] | doc tab | doc tab* | ... [+] [ext][jobs][bell][?][avatar] |  app bar
+------------------------------------------------------------------------------------------+
| [DESIGN v]  SOLID SURFACE MESH SHEET METAL PLASTIC MANAGE UTILITIES [SKETCH]              |  tab row
|             [icons...] CREATE v | AUTOMATE v | MODIFY v | ASSEMBLE v | CONFIGURE v | ...   |  panels
+------------------------------------------------------------------------------------------+
| BROWSER (floating, top left)                                   ViewCube (top right)      |
|                                         canvas                 Sketch Palette / dialog   |
|                                                                (docked right)            |
| COMMENTS (bottom left)        nav bar (bottom centre)          status text (bottom right)|
+------------------------------------------------------------------------------------------+
| |< < > >|  timeline feature icons ............ marker                       [gear]      |  timeline
+------------------------------------------------------------------------------------------+
```

### 1.2 Application bar

- Left: data panel toggle (3x3 grid), File menu (page icon with arrow), Save, Undo with history
  arrow, Redo with arrow, Home (opens the project home) (frame 7lKpzGtoQX0 @ 4:30; gKGP1iFhd1s @ 1:00:00).
- Centre: one tab per open document, name plus version ("Baseplate v1", "Bracket v5"). A trailing
  `*` marks unsaved changes (frame 7lKpzGtoQX0 @ 4:30). A read-only or other-user file shows a lock
  icon on its tab (frame ZmckF8zYbp0 @ 14:20; B9eJBHes9Js @ 13:20).
- Right: `+` new document tab, then (newest) an extensions/upgrade icon, job status (clock with a
  count), notifications bell, help `?`, profile avatar (frame B9eJBHes9Js @ 13:20; 7lKpzGtoQX0 @ 0:40).
  Older versions show an "N of 10" editable-document counter here (frame ZmckF8zYbp0 @ 11:55;
  F0qnbGiJ1RY @ 2:40).
- Out-of-date references: in an assembly whose linked child changed, an update icon (warning
  triangle) appears next to undo/redo with tooltip "Update 1 child component to latest
  non-milestone version or milestone version if available" (frame 7lKpzGtoQX0 @ 29:30).
- Profile menu holds Preferences (D0TYcB-2_8o @ 19:25).

### 1.3 Banners under the toolbar

- "Unsaved: Changes may be lost | Save" on a new document (frame ZmckF8zYbp0 @ 14:20; M0TQR8t0pQ8 @ 11:40).
- "Read-Only: Document is not editable | Make Editable" in an inserted reference (F0qnbGiJ1RY @ 2:40).

### 1.4 Toolbar: workspace switcher, tabs, panels

- Workspace switcher: big button at far left, "DESIGN v", tooltip "Change Workspace"
  (frame D0TYcB-2_8o @ 1:40). Workspaces named: Design, Generative Design, Render, Animation,
  Simulation, Manufacture, Drawing (D0TYcB-2_8o @ 1:33). Frames show RENDER (gKGP1iFhd1s @ 3:40:00),
  ANIMATION (M0TQR8t0pQ8 @ 1:15:00), SIMULATION (gKGP1iFhd1s @ 4:10:00), MANUFACTURE (4irYQjtHZjY @ 1:30),
  DRAWING (gKGP1iFhd1s @ 3:50:00).
- Tabs are small caps text; the active tab is underlined in blue. Each tab holds panels: a row of
  big icons with the panel name and a `v` dropdown beneath. The dropdown lists every command of the
  panel, with its shortcut on the right; icons on the row are a subset (frame gKGP1iFhd1s @ 1:00:00).
- Every dropdown entry has a kebab `⋮` with "Pin to Toolbar", "Pin to Shortcuts",
  "Change Keyboard Shortcut..." (frame gKGP1iFhd1s @ 1:00:00).
- Hover tooltips: title, one-line summary, illustration, "Press Ctrl+/ for more help"
  (frame ZmckF8zYbp0 @ 11:55, 27:17).

Design workspace tabs by version:

| Version | Tabs | SOLID panels |
|---|---|---|
| about 2021 | SOLID SURFACE MESH SHEET METAL PLASTIC UTILITIES | CREATE, MODIFY, ASSEMBLE, CONSTRUCT, INSPECT, INSERT, SELECT, (POSITION when parts moved) (frame ZmckF8zYbp0 @ 14:20) |
| 2023 | same | CREATE, MODIFY, ASSEMBLE, CONSTRUCT, INSPECT, INSERT, SELECT (frame M0TQR8t0pQ8 @ 11:40) |
| 2024 | same | CREATE, AUTOMATE, MODIFY, ASSEMBLE, CONSTRUCT, INSPECT, INSERT, SELECT (frame D0TYcB-2_8o @ 1:40) |
| newest | SOLID SURFACE MESH SHEET METAL PLASTIC MANAGE UTILITIES (plus SKETCH when sketching) | CREATE, AUTOMATE, MODIFY, ASSEMBLE, CONFIGURE, CONSTRUCT, INSPECT, INSERT, SELECT, (POSITION) (frame 7lKpzGtoQX0 @ 0:40, 25:15) |

Newest SOLID row icons, left to right (frame 7lKpzGtoQX0 @ 0:40): Create Sketch, Extrude, Revolve,
Hole, Rectangular Pattern, Create Form (purple) | Automate | Press Pull, Fillet, Chamfer, Shell,
Combine, Move/Copy | New Component, Joint, (as-built/BOM style third icon, unclear) | Configure x2 |
Offset Plane | Measure | Insert Derive, Insert Fastener (bolt), Canvas | Select.
Icon identities are from shape (inferred) except Create Sketch, Extrude, Press Pull, Fillet,
Move, Joint, Measure, which the videos use by name.

The POSITION panel (Capture Position, Revert) appears at the right once a component has been moved
(frame 7lKpzGtoQX0 @ 25:15; F0qnbGiJ1RY @ 3:06:50).

### 1.5 Browser

- Floating panel, top left, header "BROWSER" with `<<` collapse and a pin/close dot
  (frame 7lKpzGtoQX0 @ 4:30).
- Root row: document name with version, a radio dot on the right meaning "active"
  (frame 7lKpzGtoQX0 @ 9:20).
- Children, in order: Document Settings (expand shows "Units: mm"; newest also "Part Design"
  and "Units: mm, g") (frame 7lKpzGtoQX0 @ 9:20; B9eJBHes9Js @ 3:20), Named Views, Origin (hidden by
  default: eye struck through), then Analysis, Joints (newest: "Relationships > Joints"), Bodies,
  Sketches, Construction, then components (frame gKGP1iFhd1s @ 3:10:00; D0TYcB-2_8o @ 6:20).
- Each row: expand triangle, eye toggle, type icon, name. Hiding a folder hides its whole content
  (D0TYcB-2_8o @ 1:09:24).
- Sketch icons: padlock on the sketch icon when fully constrained, pencil when not
  (D0TYcB-2_8o @ 31:00; frame 7lKpzGtoQX0 @ 28:15 shows red-pencil sketches).
- Components: "Name:1" instance suffix; a colour strip at the left edge when component colour
  cycling is on (frame ZmckF8zYbp0 @ 21:30); a chain-link icon for inserted (linked) designs, e.g.
  "Baseplate v2:1"; a pin icon on the grounded one (frame 7lKpzGtoQX0 @ 25:15). Out-of-date linked
  rows show a warning triangle (frame 7lKpzGtoQX0 @ 29:30).
- Joints show as "Rev1", "Revolute 6", "Slider 8", "Motion Link 9" with type icons
  (frame ZmckF8zYbp0 @ 23:40; gKGP1iFhd1s @ 3:10:00).
- Rename: slow second click (click, wait, click), never a double click (4irYQjtHZjY @ 59:01;
  F0qnbGiJ1RY @ 1:04:34 "long click").

### 1.6 ViewCube

- Top right; labelled faces (TOP, FRONT, RIGHT...), red X / green Y / blue Z triad
  (frame 7lKpzGtoQX0 @ 4:30).
- Click a face for that view; click an edge or corner for 45 degree / iso views; drag to orbit;
  in face view, arrows rotate 90 degrees around the view axis (clockwise / anticlockwise curved
  arrows) (7lKpzGtoQX0 @ 9:28; D0TYcB-2_8o @ 4:39).
- Home button (house) gives the home view, default south-west isometric (D0TYcB-2_8o @ 5:09).
- Right-click the cube: "Set current view as Home" (7lKpzGtoQX0 @ 9:58).

### 1.7 Navigation bar (bottom centre)

Frame D0TYcB-2_8o @ 6:20; 7lKpzGtoQX0 @ 0:40. Left to right:
- Orbit with dropdown: Free Orbit, Constrained Orbit (constrained is "more precise")
  (D0TYcB-2_8o @ 3:07).
- Look At (pick a face, view goes normal to it) (D0TYcB-2_8o @ 4:08).
- Pan (left drag while active) (D0TYcB-2_8o @ 5:09).
- Zoom (drag up/down) with dropdown: Zoom Window, Fit (D0TYcB-2_8o @ 5:39).
- Display Settings: Visual Style (Shaded Ctrl+4, Shaded with Hidden Edges Ctrl+5,
  Shaded with Visible Edges Only Ctrl+6 (default), Wireframe Ctrl+7, Wireframe with Hidden Edges
  Ctrl+8, Wireframe with Visible Edges Only Ctrl+9), Environment (Photo Booth default, Grey Room,
  Dark Sky, Tranquility Blue, River Rubicon...), Effects (Environment Dome, Ground Plane, Ground
  Shadow, Ground Reflection, Ambient Occlusion, Anti-Aliasing), Object Visibility, Camera,
  Ground Plane Offset, Enter Full Screen Ctrl+Shift+F (frame D0TYcB-2_8o @ 6:20; 6:09 to 10:45).
- Grid and Snaps (Layout Grid on/off) (7lKpzGtoQX0 @ 3:04; D0TYcB-2_8o @ 10:45).
- Viewports: Single View, Multiple Views (four viewports; the ViewCube lives in the active one,
  click a viewport to activate) (D0TYcB-2_8o @ 10:45 to 11:35).
- In Manufacture, an extra sync menu: "Sync view / visibility / ViewCube with active setup"
  (4irYQjtHZjY @ 22:31).

### 1.8 Timeline (bottom strip)

- Playback buttons `|< < > >|`: go to start, step back, play, step forward, go to end
  (D0TYcB-2_8o @ 11:46 to 12:17).
- Feature icons in creation order; marker (a thin handle with a triangle head) at the end; drag it
  to roll back (7lKpzGtoQX0 @ 27:55). Hover shows a tooltip with the feature name and document
  version ("Sketch1 / Bracket v5") (frame 7lKpzGtoQX0 @ 28:15).
- Icons are tinted by component colour when colour cycling is on (frame ZmckF8zYbp0 @ 21:30).
- Groups appear as a single bracket icon `▯▯▯` with a `+` under it to expand (frame F0qnbGiJ1RY @ 12:37).
- Failed feature: red icon; lost reference: yellow icon (F0qnbGiJ1RY @ 2:03:20, 2:28:50).
- A settings gear at the far right of the strip (frame 7lKpzGtoQX0 @ 0:40).

### 1.9 Command dialogs

- Docked at the right edge of the canvas, title in caps with a collapse dot and `▸▸`
  (frame D0TYcB-2_8o @ 50:35).
- Rows: label left, control right. Selection rows are buttons: active one is blue
  "1 selected" with an `×` to clear, inactive ones white "Select" (frame gKGP1iFhd1s @ 2:20:00).
- Some dialogs have tabs (Sweep: Feature | Analysis; Joint: Position | Motion; CAM ops: Tool,
  Geometry, Heights, Passes, Linking) (frames gKGP1iFhd1s @ 2:20:00; 7lKpzGtoQX0 @ 25:15; 4irYQjtHZjY @ 30:30).
- Footer: `(i)` help at left, OK and Cancel at right; OK greyed until required inputs are set
  (frame 7lKpzGtoQX0 @ 25:15).
- On-canvas twin of the main value: a small floating input box beside the drag arrow with a `⋮`
  menu (frame D0TYcB-2_8o @ 50:35). Tab moves to the next value (7lKpzGtoQX0 @ 5:07).
- Errors: toast at bottom right "1 error(s). The operation failed. Try adjusting the values or
  changing the input geometry. More info" (frame gKGP1iFhd1s @ 3:30:00).

### 1.10 Sketch Palette (right, while a sketch is active)

Frame 7lKpzGtoQX0 @ 4:30; D0TYcB-2_8o @ 21:30. Title "SKETCH PALETTE", `▸▸` collapse.
- "Feature Options" section appears on top when a sketch tool is active (e.g. Rectangle: type
  icons; Circle: type icons) (frame M0TQR8t0pQ8 @ 25:00; B9eJBHes9Js @ 3:20).
- "Options": Linetype (normal / construction toggle icons), Look At (button), Sketch Grid,
  Snap, Slice, Show Profile, Show Points, Show Dimensions, Show Constraints, Show Projected
  Geometries, Construction Geometries (newest), 3D Sketch (checkboxes).
- Footer button "Finish Sketch".

### 1.11 Status line (bottom right of canvas)

Shows the current selection and quick measures: "1 Face | Area : 20.227 cm^2",
"1 Profile | Area : 2165.00 mm^2", "2 selections", "Sketch Point | X: .. Y: .. Z: ..",
"Perpendicular Constraint" on hover (frames D0TYcB-2_8o @ 13:50, 50:35, 1:32:30, 24:04).
Selecting two faces shows the angle there without opening Measure (D0TYcB-2_8o @ 1:37:38).

### 1.12 Data panel (slides in from the left)

- Tabs Data | People; blue Upload button; New Folder; settings gear; breadcrumb with home icon
  ("Fusion Tutorial"); top icons refresh, search, close (frame 7lKpzGtoQX0 @ 23:10).
- Each design: thumbnail, name, date, version pill "V2 v" (frame 7lKpzGtoQX0 @ 23:10); older UI adds
  "Read-Only v" / "Editable v" pill (F0qnbGiJ1RY @ 2:40).
- Double-click opens in a new tab; drag a design onto the canvas, or right-click >
  "Insert into Current Design" (7lKpzGtoQX0 @ 22:49). Home lists projects; "New Project"
  (D0TYcB-2_8o @ 16:53).

### 1.13 Preferences

Profile > Preferences. Left tree: General (API, Design, Manufacture, Electronics..., Render,
Drawing, Simulation and Generative Design), Tokens and Cloud Credits, Material, Graphics,
Network, Data Collection and Use, Unit and Value Display, Default Units (Design, Simulation...),
Preview Features. Footer: Restore Defaults, Apply, OK, Cancel (frame D0TYcB-2_8o @ 19:40).
- Default Units > Design: "Default units for new design" mm, cm, m, in, ft. Affects new documents
  only (D0TYcB-2_8o @ 19:25).
- General > Design: "Auto look at sketch" (view turns normal to the plane on sketch create)
  (D0TYcB-2_8o @ 21:29).

---

## 2. Command inventory

Conventions seen everywhere: the command dialog opens on the right, the first selection row is
active, the canvas shows a live preview, the value can be typed in the dialog or in the floating
box or set by dragging the arrow, OK or Enter commits, Esc cancels (D0TYcB-2_8o @ 50:04 to 53:37).

### 2.1 Design > SOLID > CREATE

- **Create Sketch**: pick one of the three origin planes shown as coloured squares (YZ, XZ, XY)
  or a planar face; view turns to look at it; SKETCH tab opens (7lKpzGtoQX0 @ 3:35 to 4:06).
  A plane hidden behind geometry: press and hold left click to get a pick list of everything
  under the cursor (D0TYcB-2_8o @ 54:39).
- **Extrude** (E). Fields: Type (Solid | Thin; thin adds Wall Thickness and side), Profiles,
  Start (Profile Plane | Offset | Object), Direction (One Side | Two Sides | Symmetric), Extent
  Type (Distance | To Object | All; "To Object" has Extend option "to adjacent faces"), Measurement
  (half or whole length, Symmetric only), Distance, Taper Angle (also a ring handle on canvas),
  Operation (Join | Cut | Intersect | New Body | New Component), Objects To Cut (list with
  checkboxes, when cutting) (frames D0TYcB-2_8o @ 50:35, 52:55; 50:04 to 57:40; F0qnbGiJ1RY @ 2:13:30).
  Behaviour: a selected profile is pre-filled; dragging into existing material switches the
  operation to Cut automatically, negative distance too (7lKpzGtoQX0 @ 16:27; D0TYcB-2_8o @ 54:39).
  Island profiles: clicking inside a closed region selects that region; several can be added by
  clicking (7lKpzGtoQX0 @ 13:55, 18:58).
- **Revolve**: Profile, Axis (origin axes or any model line), Extent Type Full | Partial, Direction
  One Side | Two Sides | Symmetric, Angle, Operation (D0TYcB-2_8o @ 57:40 to 59:43).
- **Sweep**: tabs Feature | Analysis. Type (Single Path...), Profile, Path, Chain Selection,
  Distance (0 to 1 fraction of path), Taper Angle, Twist Angle (any degrees, e.g. 720),
  Orientation (Perpendicular | Parallel), Operation (frame gKGP1iFhd1s @ 2:20:00; D0TYcB-2_8o @ 1:00:13 to 1:05:51).
- **Loft**: profile list in order; first and last profile end condition Connected | Direction;
  Guide Type Rails | Center Line; rail selection rows (D0TYcB-2_8o @ 1:06:22 to 1:08:53).
- **Hole**, **Thread** (pick a cylindrical face; Thread Type ISO Metric profile; Size, Designation
  auto from diameter e.g. M15x1.5; Class; Direction right/left; Modeled) (7lKpzGtoQX0 @ 20:00).
- **Pattern**: Rectangular | Circular | Pattern on Path (type icons at top). Rectangular fields:
  Object Type (Bodies | Faces | Features | Components), Objects, Axes (second axis auto at 90),
  Distribution (Extent | Spacing), Suppression (per-instance checkboxes on canvas), Axis 1 and 2:
  Quantity, Distance, Direction; Compute Type (Adjust). On-canvas arrows drag the distance, a
  spinner box sets the count (frame D0TYcB-2_8o @ 1:32:30). Circular: Objects, Axis, Quantity,
  Full | Partial angle, Suppression (D0TYcB-2_8o @ 1:33:31). Patterning Bodies gives separate
  bodies; patterning Features keeps one body (F0qnbGiJ1RY @ 2:39:40).
- **Mirror** (Type: Components / bodies / features, Objects, Mirror Plane) (ZmckF8zYbp0 @ 19:14).
- **Emboss**: Sketch profile (text), Face, Emboss | Deboss, Depth (D0TYcB-2_8o @ 1:28:56).
- **Create Form** opens the T-spline Form contextual environment (icon seen, not demonstrated).

### 2.2 SOLID > MODIFY (dropdown, frame F0qnbGiJ1RY @ 1:39:05)

Press Pull **Q**, Fillet **F**, Chamfer, Shell, Draft, Scale, Combine, Offset Face, Replace Face,
Split Face, Split Body, Silhouette Split, Move/Copy **M**, Align, Delete **Del**, Remove,
Arrange, Simplify, Physical Material, Appearance **A**, Manage Materials, Change Parameters,
Compute All **Ctrl+B**.

- **Press Pull**: pick a face; acts as offset face, fillet edit or extrude depending on pick.
  Offset Type: Automatic | Modify Existing Feature | New Offset. With Modify Existing the original
  feature is edited and nothing is added to the timeline (a highlight appears on that timeline
  icon) (D0TYcB-2_8o @ 1:20:42 to 1:23:49).
- **Fillet**: select edges or faces (a face fillets all its edges); radius by drag arrow or value;
  Type Constant Radius; continuity Tangent (G1) | Curvature (G2); corner type Rolling Ball |
  Setback (D0TYcB-2_8o @ 1:09:55 to 1:12:30). Ctrl adds more edges (F0qnbGiJ1RY @ 2:22:38).
- **Chamfer**: edges or faces; Type Equal Distance | Two Distances | Distance and Angle; corner
  Chamfer | Blend | Miter (D0TYcB-2_8o @ 1:12:30 to 1:14:32).
- **Shell**: Faces/Bodies to remove, Inside Thickness, Direction Inside | Outside | Both; picking
  the whole body makes a hollow closed solid. Adding a second face requires thickness 0 first
  (as shown) (D0TYcB-2_8o @ 1:18:37 to 1:20:11).
- **Combine**: Target Body, Tool Bodies, Operation Join | Cut | Intersect, Keep Tools
  (D0TYcB-2_8o @ 1:03:17, 1:16:03).
- **Move/Copy**: Move Object (Components | Bodies | Faces | Sketch objects), Selection, Move Type
  (Free Move, Translate, Rotate, Point to Point, Point to Position), Set Pivot, X/Y/Z Distance,
  X/Y/Z Angle, Create Copy; on insert also "Ground To Parent" (frame 7lKpzGtoQX0 @ 23:10, dialog
  "INITIAL POSITION"; F0qnbGiJ1RY @ 2:57:30). Canvas manipulator: arrows, rotation rings, centre ball.
- **Appearance** (A): Apply To Bodies/Components | Faces; "In This Design" swatches; Library with
  Fusion Appearances | My Appearances | Favorites, search, folders; drag a swatch onto a body
  (frame M0TQR8t0pQ8 @ 11:40; 7lKpzGtoQX0 @ 10:20).
- **Split Body**: body, splitting tool (plane or face) (F0qnbGiJ1RY @ 1:38:40).

### 2.3 CONSTRUCT

Offset Plane, Plane at Angle, Tangent Plane, Midplane, Plane Through Two Edges, Plane Through
Three Points, Plane Along Path (0.5 = midpoint); Axis Through Cylinder/Cone/Torus, Axis Through
Two Points; Point at Vertex, Point Through Two Edges, Point Along Path (D0TYcB-2_8o @ 1:24:20 to 1:27:23;
F0qnbGiJ1RY @ 1:23:40 to 1:26:00). Shift-click to multi-select construction items in the
browser, then delete; a sketch that loses its plane errors (D0TYcB-2_8o @ 1:26:23).

### 2.4 INSPECT

- **Measure** (I): Selection Filter (body/face/edge/vertex icons), Precision, Secondary Units,
  Clear Selection, Show Snap Points; results: area, loop length, centre position, distance,
  angle, radius, diameter (frame D0TYcB-2_8o @ 1:36:05; 1:35:37 to 1:37:38).
- **Section Analysis**: pick a plane, drag the cut (D0TYcB-2_8o @ 1:20:11). Not for mesh bodies
  (F0qnbGiJ1RY @ 1:06:40).
- **Interference**: select top assembly, Include Coincident Faces, Compute (F0qnbGiJ1RY @ 3:01:56).

### 2.5 INSERT

Insert Derive, Insert Fastener (newest; timeline item right-click: Insert Similar Fastener, Edit
Fastener, Replace Fastener) (frame gKGP1iFhd1s @ 2:30:00), Insert McMaster-Carr Component
(F0qnbGiJ1RY @ 3:14:19), Canvas (attach an image: Image, Face, Canvas Opacity slider, Display
Through, Selectable, X/Y Distance, Z Angle, Scale X/Y, Flip H/V) (frame M0TQR8t0pQ8 @ 33:20),
Insert Mesh / SVG / DXF (inferred from panel).

### 2.6 SELECT (dropdown, frame D0TYcB-2_8o @ 13:50)

Select, Window Selection **1**, Freeform Selection **2**, Paint Selection **3**, Selection Tools,
Component Drag (checkbox), Selection Priority (Select Body / Face / Edge / Component Priority),
Selection Filters. Tooltip: "Hold Ctrl (Windows) or Command (macOS) to add or remove objects
from the selection".

### 2.7 Other Design tabs

- **SURFACE** (newest row): Create Sketch plus surface create tools (Extrude, Patch, Offset and others, icons only), Create Form |
  Trim, Untrim, Split, Stitch | assemble and construct panels (frame gKGP1iFhd1s @ 3:30:00, icons
  only). Ruled surface dialog: tabs Feature | Analysis; Edges, Chain Selection, Type (Tangent),
  Distance, Angle, Mitered Corners, Operation (frame gKGP1iFhd1s @ 3:30:00).
- **SHEET METAL**: document gets a Sheet Metal Rule row in the browser ("Rule: Steel (mm)")
  (frame gKGP1iFhd1s @ 3:20:00). Flange dialog "EDIT FEATURE": Type, edge list (Full Edge), Edges/Profiles,
  Height, Angle, Height Datum (Outer Faces), Bend Position (Inside, Outside, Adjacent, Tangent),
  Flip, Miter Corners, Override Rules (frame M0TQR8t0pQ8 @ 1:26:40).
- **MESH**: convert solid to mesh, tessellate, edit like a mesh modeller (F0qnbGiJ1RY @ 1:44:21).
- **PLASTIC**: tab present in all versions, not demonstrated.
- **UTILITIES** (older layout): MAKE, ADD-INS (Scripts and Add-Ins **Shift+S**, Fusion App Store),
  UTILITY, INSPECT, SELECT (frame ZmckF8zYbp0 @ 11:55). Scripts and Add-Ins dialog lists scripts;
  SpurGear (Python) dialog: Standard (Metric), Pressure Angle 20, Module, Number of Teeth,
  Backlash, Root Fillet Radius, Gear Thickness, Hole Diameter (ZmckF8zYbp0 @ 11:59 to 12:31).
- **MANAGE** (newest): Change Parameters lives here and in MODIFY (inferred from tab order).

### 2.8 SKETCH contextual tab

Row (newest, frame gKGP1iFhd1s @ 1:00:00; 7lKpzGtoQX0 @ 4:30): CREATE (Line, Rectangle, Circle,
Spline, Mirror, Sketch Dimension, Point) | MODIFY (Fillet, Trim, Offset, curve tool) |
CONSTRAINTS | CONFIGURE | INSPECT | INSERT | SELECT | FINISH SKETCH (big green check, with
dropdown). The other tabs stay visible; SKETCH is added and highlighted.

CREATE dropdown (frame gKGP1iFhd1s @ 1:00:00): Line **L**, Rectangle > (2-Point, 3-Point, Center),
Circle > (Center Diameter, 2-Point, 3-Point, 2-Tangent, 3-Tangent), Arc > (3-Point, Center Point,
Tangent), Polygon > (Circumscribed, Inscribed, Edge), Ellipse, Slot > (Center to Center, Overall,
Center Point, Three Point Arc, Center Point Arc), Spline > (Fit Point, Control Point), Conic Curve,
Point, Text, Mirror, Circular Pattern, Rectangular Pattern, Project / Include >, Sketch
Dimension **D** (submenu contents from D0TYcB-2_8o @ 40:23 to 46:01).

MODIFY dropdown: Fillet, Trim, Extend, Break, Offset, Move/Copy, Scale, Change Parameters
(D0TYcB-2_8o @ 47:01 to 49:34; rest inferred).

Project / Include > Project, Intersect (dialog: Geometry, Selection Filter, Projection Link)
(F0qnbGiJ1RY @ 2:08:12).

Tool behaviour details:
- Rectangle 2-point: click corner (snaps to origin), move, type width, Tab, height, Enter
  (7lKpzGtoQX0 @ 4:37 to 5:14).
- Line: click points; a dotted tracking line and angle readout show horizontal / vertical
  inference; Esc or the green check ends (D0TYcB-2_8o @ 22:00 to 22:31). Press and drag from a line
  end makes a tangent arc (F0qnbGiJ1RY @ 1:53:36).
- Circle: click centre, type diameter, Enter (7lKpzGtoQX0 @ 6:42).
- Polygon: centre, radius, then side count field (Tab to switch) (D0TYcB-2_8o @ 44:28).
- Spline: click points, finish with the green check (Esc discards); tangent handles edit weight
  and angle (D0TYcB-2_8o @ 35:51).
- Trim: click segments, or press and drag across them to trim many (D0TYcB-2_8o @ 47:01).
- Extend: extends to the next boundary, real or virtual, each click goes one boundary further
  (D0TYcB-2_8o @ 49:02).
- Offset: Sketch curves, Chain Selection (untick for a single curve), Offset Position (drag or
  type), Flip (D0TYcB-2_8o @ 48:01; F0qnbGiJ1RY @ 2:00:25).
- Sketch Fillet: pick two lines or a corner, type radius; double-click the radius later to edit
  (D0TYcB-2_8o @ 47:31).
- Sketch Mirror: Objects, Mirror Line; result stays associative (D0TYcB-2_8o @ 46:31).
- Text: drag a box, type, Height, Angle, then drag to place (D0TYcB-2_8o @ 1:28:25).

### 2.9 ASSEMBLE

ASSEMBLE dropdown (frame ZmckF8zYbp0 @ 25:30): New Component, Joint **J**, As-built Joint
**Shift+J**, Joint Origin, Rigid Group, Tangent Relationship, Drive Joints, Motion Link,
Enable Contact Sets, Enable All Contact, Motion Study. Details in section 4.

### 2.10 Drawing workspace (newest)

- Tabs DRAWING | MANAGE. Panels: CREATE (Base View, Projected View, Section View, Detail View,
  Break View, ...), MODIFY (Move, Rotate...), GEOMETRY (Centerline, Center Mark, ...),
  DIMENSIONS, TEXT, SYMBOLS (surface texture, datum, feature control, ...), INSERT (image),
  TABLES (Table, Balloon), EXPORT (PDF) (frame gKGP1iFhd1s @ 3:50:00; icons beyond panel names inferred).
- Browser: Document Settings (Font: Arial, Text Height Group: Medium, Dimension Units: mm, Line
  Width Group: Medium, Revision Scope: Drawing), Sheet1 (Sheet Settings, model reference "rtrt v2:1"
  with Bodies, Sketches) (frame gKGP1iFhd1s @ 3:50:00).
- Sheet: grey background, white sheet with zone arrows on its borders, title block (Project,
  Title, Approved, Checked, Drawn with name and date, Size, Code, DWG No, Rev, Scale 1:1, Weight,
  Sheet 1/1); a sheet strip at the bottom with `+` to add sheets (frame gKGP1iFhd1s @ 3:50:00).
- Views shown: front with hidden lines dashed, top, right (frame gKGP1iFhd1s @ 3:50:00).

### 2.11 Other workspaces (glimpses)

- Render: tabs RENDER; panels SETUP, IN-CANVAS RENDER, RENDER; rendering gallery strip at the bottom
  "Use the Render tool to save renderings to your gallery" (frame gKGP1iFhd1s @ 3:40:00).
- Animation: STORYBOARD, TRANSFORM, ANNOTATION, VIEW, PUBLISH; a dope-sheet "ANIMATION TIMELINE"
  with tracks View, Components, per-component bars (frame M0TQR8t0pQ8 @ 1:15:00).
- Simulation: SETUP tab; STUDY, SIMPLIFY, MATERIALS, CONSTRAINTS, LOADS, CONTACTS, DISPLAY, MANAGE,
  SOLVE, ANSYS, RESULTS, INSPECT, SELECT; browser Simulation Model 1 > Study 1 - Static Stress >
  Study Materials, Load Case, Contacts, Mesh, Results; HTML Study Report (frame gKGP1iFhd1s @ 4:10:00, 4:20:00).
- Export (File > Export): Name, Type list: Fusion Archive (.f3d), DXF, FBX, IGES, OBJ, SAT,
  SketchUp, SMT, STEP, STL, USDZ; Cancel / Export (frame gKGP1iFhd1s @ 4:00:00; D0TYcB-2_8o @ 16:23).

### 2.12 Manufacture (CAM) basics (4irYQjtHZjY)

- Tabs: MILLING, TURNING, ADDITIVE, INSPECTION, FABRICATION, UTILITIES. MILLING panels: SETUP
  (New Setup, NC Program), 2D (Face, 2D Adaptive, 2D Contour, ...), 3D, DRILLING, MULTI-AXIS, MODIFY,
  ACTIONS (Simulate, Post, Setup Sheet), MANAGE (Tool Library, Machine Library), INSPECT, SELECT
  (frame 4irYQjtHZjY @ 1:30).
- CAM browser: CAM Root > Units: in, Named Views, Origin, Models (the design body), NC Programs,
  Setups > "Setup 1 - Finish Side 1" > machine node, operations "[T1] Face R/F", "[T2] 2D Adaptive R"
  (prefix [Tn] = tool number). Active setup has a radio dot (4irYQjtHZjY @ 49:00).
- Right-click Setups: New Setup, Create NC Program, Generate (Cmd+G / Ctrl+G), Simulate, Post Process,
  Setup Sheet (frame 4irYQjtHZjY @ 1:30).
- Setup dialog tabs: Setup (Machine Select..., Operation Type Milling, WCS Orientation "Z axis/plane
  & X axis" etc., Flip Z / Flip X, Origin Stock box point | Model box point with clickable white
  corner/edge/face points, Model body, Fixture), Stock (Mode Fixed size box | Relative size box |
  cylinder | tube | from solid | From preceding setup; Width/Depth/Height with Model Position;
  Round Up to Nearest), Part Position, Post Process (Program Name/Number 1001, Comment, WCS Offset
  G54) (4irYQjtHZjY @ 1:08 to 22:31).
- Operation dialog tabs: Tool (tool select, Feed and Speed preset, spindle, surface speed, feeds,
  coolant), Geometry (contour or pocket chains), Heights (Clearance, Retract, Feed, Top, Bottom, each
  "from" + offset, drawn as coloured planes), Passes (tolerance, stepover, direction, multiple
  depths, stock to leave radial/axial), Linking (lead-in/out, transitions) (4irYQjtHZjY @ 24:35 to 37:23).
- Toolpath colours: red arrow entry, green arrow exit, blue cutting, green leads, yellow rapids
  and transitions (4irYQjtHZjY @ 37:23). Status icons: green check done, orange needs generate
  (4irYQjtHZjY @ 52:20). Changing inputs marks ops out of date; regenerate with Generate.
- Simulate: own toolbar (TOOL, DISPLAY, INFORMATION, INSPECT, EXIT SIMULATION green check), side
  panel Display | Info | Statistics, player bar (start, previous op, step, play, step, next op, end,
  speed slider), op strip timeline; stock Comparison colours green at size, blue leftover, red
  gouge (4irYQjtHZjY @ 38:24 to 42:04).
- NC Program dialog: Settings | Operations tabs; machine, post, program number, output folder, units,
  "Open NC file in editor", Post button (4irYQjtHZjY @ 1:09:49 to 1:12:55).
- Status line shows "Machining time" per op and "Total machining time" per setup (frame 4irYQjtHZjY @ 38:00, 1:09:00).

---

## 3. Sketch system

### 3.1 Entering and leaving

- Create Sketch > pick plane or face > view auto-orients (if Preferences "Auto look at sketch" is on)
  > SKETCH tab + Sketch Palette appear (7lKpzGtoQX0 @ 3:35; D0TYcB-2_8o @ 21:29).
- Sketch grid with axis labels (25, 50, 75...) and red X / green Y axis lines (frame 7lKpzGtoQX0 @ 4:30).
- Finish Sketch: green check in the toolbar or button in the palette (7lKpzGtoQX0 @ 8:13).
- Re-edit: right-click the sketch in the browser or timeline > Edit Sketch (7lKpzGtoQX0 @ 28:40;
  D0TYcB-2_8o @ 53:37). Right-click > Redefine Sketch Plane moves it, but projected references can die
  (F0qnbGiJ1RY @ 1:48:47).

### 3.2 Colours and states

- Under-defined curves: blue. Fully constrained: black (7lKpzGtoQX0 @ 6:11 to 6:42; D0TYcB-2_8o @ 22:31 to 23:02).
- A curve whose start point is on the origin is partially fixed, so starting at the origin is
  recommended (D0TYcB-2_8o @ 22:00 to 24:04).
- Closed profiles fill light blue (frame 7lKpzGtoQX0 @ 8:20).
- Construction curves: dashed (orange in some themes) (D0TYcB-2_8o @ 38:53; F0qnbGiJ1RY frames).
- Fully constrained sketch: browser icon gets a padlock; deleting a constraint flips it back to a
  pencil (D0TYcB-2_8o @ 30:42 to 31:15).
- Projected geometry: linked curves (purple in Fusion, inferred); when the source is lost they turn
  green and stay dead (F0qnbGiJ1RY @ 2:05, 1:48:47).
- Selected curves: blue highlight; hovered: lighter (frames).

### 3.3 Constraints

- Panel row (newest, left to right, from icon shapes, inferred order): (AutoConstrain, newest only),
  Horizontal/Vertical, Coincident, Tangent, Equal, Parallel, Perpendicular, Fix/UnFix, Midpoint,
  Concentric, Collinear, Symmetry, Curvature (frames 7lKpzGtoQX0 @ 4:30, gKGP1iFhd1s @ 1:00:00,
  D0TYcB-2_8o @ 25:40). Hover tooltip gives the name (F0qnbGiJ1RY @ 29:00).
- Context filtering: with a selection, only applicable constraints stay enabled (e.g. circle + line:
  only Tangent and Fix) (D0TYcB-2_8o @ 27:09 to 27:39).
- Apply: select entities first (Ctrl adds), then click the constraint (D0TYcB-2_8o @ 27:09).
  Symmetry asks for entity 1, entity 2, then the symmetry line (D0TYcB-2_8o @ 35:21).
- Automatic inference while drawing: horizontal, vertical, perpendicular, coincident are added as
  you draw, with small grey glyphs near the geometry (D0TYcB-2_8o @ 23:02 to 23:33; frame 31:00).
- Midpoint snap shows a small triangle glyph while hovering (D0TYcB-2_8o @ 26:37).
- Delete a constraint: select its glyph (or window-select it), right-click > Delete, or Delete key;
  marking-menu overflow names it ("Delete Coincident") (D0TYcB-2_8o @ 33:47 frame, 24:01).
- Applying a redundant constraint is refused; this reveals over-constraining (D0TYcB-2_8o @ 39:23).
- Curvature (G2) between spline and line (D0TYcB-2_8o @ 35:51 to 37:22).

### 3.4 Dimensions

- Sketch Dimension (D): click one entity (length/diameter) or two (distance), place, type the value
  in the inline box, Enter (7lKpzGtoQX0 @ 6:11). Right-click while placing on a circle: switch
  Diameter / Radius; "Aligned" for slanted distances (ZmckF8zYbp0 @ 2:30, 3:27).
- Inline value box shows the full precision value selected, plus a `⋮` (frame D0TYcB-2_8o @ 40:25).
- While typing a value, clicking another dimension inserts its name ("d31"); expressions like
  `d31/2` or parameter names work (F0qnbGiJ1RY @ 45:19, 2:35:43). A dimension driven by an
  expression is shown with an "fx:" prefix (frame gKGP1iFhd1s @ 1:10:00). Hovering shows "d6 : Dimension
  Value" (frame B9eJBHes9Js @ 36:40).
- Double-click a dimension to edit it (D0TYcB-2_8o @ 47:31).
- During shape creation, dimension inputs appear live on the rubber band: first field active, Tab to
  next, Enter to commit (7lKpzGtoQX0 @ 4:37).

### 3.5 Construction and projection

- Toggle construction: select curves, press **X** (D0TYcB-2_8o @ 38:53; F0qnbGiJ1RY @ 22:13), or the
  Linetype buttons in the palette.
- Project / Include brings edges into the sketch; Intersect makes curves where the sketch plane
  cuts bodies (F0qnbGiJ1RY @ 2:08:12).
- Edges of the sketched face are auto-projected when you sketch on a face (inferred from
  7lKpzGtoQX0 @ 12:52, where wall rectangles snap to the existing outline).

---

## 4. Components, bodies, joints, motion

- Bodies inside one component cannot move relative to each other; anything that moves needs its own
  component (F0qnbGiJ1RY @ 10:53). Rigid multi-piece parts: one component, several bodies (F0qnbGiJ1RY @ 47:24).
- Extrude Operation "New Component" creates a component directly (ZmckF8zYbp0 @ 4:37, 6:39).
- New Component: ASSEMBLE > New Component, or right-click in the browser (F0qnbGiJ1RY @ 21:42).
- Activate a component (radio dot) before adding features or inserting parts so they land inside it
  (F0qnbGiJ1RY @ 2:55:43).
- Insert a saved design: drag from the data panel; "Initial Position" dialog (Move dialog plus
  "Ground To Parent"). The first inserted part is grounded (7lKpzGtoQX0 @ 22:49 to 24:37). Ground:
  right-click > Ground; ground a component inside the assembly, not the root (F0qnbGiJ1RY @ 3:11).
- Copy / Paste vs Paste New: Paste keeps a linked instance (edits propagate); Paste New makes an
  independent copy (ZmckF8zYbp0 @ 14:37, 25:24).
- **Joint** (J). Tabs Position | Motion. Position: Component 1 (Origin Mode: Simple | Between Two
  Faces | Two Edge Intersection; Snap Select), Component 2 (same) (frame 7lKpzGtoQX0 @ 25:15).
  Hovering a face shows snap points (centre, corners, mid-edges); the face you hover decides which
  side the joint origin lies on (7lKpzGtoQX0 @ 25:38). After both picks, the part jumps and animates;
  a rotate wheel and offset values adjust (7lKpzGtoQX0 @ 26:09, rotate -45). Motion: Type Rigid,
  Revolute, Slider, Cylindrical, Pin-Slot, Planar, Ball; Rotate axis (Z Axis); Flip; OK
  (F0qnbGiJ1RY @ 2:59:40; 7lKpzGtoQX0 @ 25:08).
- **Edit Joint Limits** (right-click joint): Motion (Rotate), Minimum checkbox + value, Maximum
  checkbox + value, Rest, Flip, Animate (frame ZmckF8zYbp0 @ 23:40).
- **Motion Link**: pick Joint 1 and Joint 2, angles (360 : 180 for a 2:1 gear), Reverse, Animate
  (ZmckF8zYbp0 @ 21:17, 33:20).
- **Rigid Group**: tooltip "Locks the relative position of the selected components. The components are
  treated as a single object when moved or when joints are applied" (frame ZmckF8zYbp0 @ 27:17).
- **Capture Position / Revert**: after dragging parts to test motion, Revert returns them; Capture
  stores the new pose (POSITION panel) (ZmckF8zYbp0 @ 15:10, 20:15).
- Drag components on canvas to test joints (Component Drag in SELECT must be on) (D0TYcB-2_8o @ 13:50 frame).
- Joint glyphs on canvas; Joints folder eye hides them; right-click > Edit Joint (7lKpzGtoQX0 @ 29:47).
- Motion Study, Drive Joints, Contact Sets exist in the ASSEMBLE menu (frame ZmckF8zYbp0 @ 25:30), not demonstrated.
- Linked part edits: open the part (right-click > Open in data panel), edit, save; in the assembly
  the browser and app bar show warning icons; click update; joints survive (7lKpzGtoQX0 @ 27:42 to 31:05;
  F0qnbGiJ1RY @ 3:05:03).

---

## 5. Timeline and parameters

### 5.1 Timeline

- Drag the marker back to roll back; features after it grey out and hide; new features are inserted
  at the marker (7lKpzGtoQX0 @ 27:55; F0qnbGiJ1RY @ 13:28). Move the marker back to the end when done
  (7lKpzGtoQX0 @ 30:33).
- Right-click a feature: Edit Feature (reopens its dialog, e.g. change profiles or 40 to 60)
  (7lKpzGtoQX0 @ 30:18; D0TYcB-2_8o @ 1:18:12). Sketch item: Edit Sketch, Redefine Sketch Plane.
- Right-click menu on a selection (frame F0qnbGiJ1RY @ 12:37; gKGP1iFhd1s @ 2:30:00): Create Selection
  Set, Create Group, Configure (newest), Delete (Del), Remove, Rename, Roll Timeline Marker Here
  (older: "Roll History Marker Here"), Convert to DM Feature (older), Suppress Features, Find in
  Browser, Find in Window.
- Groups: select a range, Create Group; groups collapse to one icon (F0qnbGiJ1RY @ 12:27).
  Quirk: with the marker after a group, new features land between groups; workaround: put the
  marker inside the group, add a dummy feature, drag the marker to the end (F0qnbGiJ1RY @ 15:02 to 16:03).
- Reorder by dragging icons; a sketch cannot move before features it references (F0qnbGiJ1RY @ 13:59).
- Suppress keeps the feature but skips it (menu). Failed = red, lost reference = yellow
  (F0qnbGiJ1RY @ 2:03:20, 2:28:50).
- Press Pull "Modify Existing Feature" edits the earlier feature in place; the timeline does not grow
  (D0TYcB-2_8o @ 1:21:45).
- Sketch-internal edits are not timeline steps (only undo) (F0qnbGiJ1RY @ 31:22).
- Capture Design History toggle: not shown in these videos (Fusion has it under the root
  component's right-click, inferred from general knowledge, not verified here).

### 5.2 Parameters

- MODIFY > Change Parameters (also searchable). Dialog "PARAMETERS": toolbar (fx add, filter,
  favourites star), "Filter all parameters", "+ User Parameter", "Automatic Update" (newest:
  "Automatic Compute"); tree Favorites, User Parameters, Model Parameters (per component > per
  sketch / feature); columns Parameter, Name, Unit, Expression, Value, Comments; star per row
  (frames gKGP1iFhd1s @ 1:10:00; M0TQR8t0pQ8 @ 1:40:00; F0qnbGiJ1RY @ 18:55).
- Add User Parameter: Name, Unit, Expression (red until valid), Value, Comment (F0qnbGiJ1RY @ 18:55).
- Model parameters are named d1, d2... and can reference each other: `d23 / 2`, `d24 * 0.75`
  (frame gKGP1iFhd1s @ 1:10:00).
- Any value field accepts a parameter name with autocomplete, or a formula; field then shows fx
  (F0qnbGiJ1RY @ 39:58, 2:51:00).

---

## 6. Input mappings

### 6.1 Mouse

| Input | Action | Source |
|---|---|---|
| Middle drag | Pan | 7lKpzGtoQX0 @ 5:20; D0TYcB-2_8o @ 5:09 |
| Shift + middle drag | Orbit | 7lKpzGtoQX0 @ 9:13; D0TYcB-2_8o @ 3:37 |
| Wheel | Zoom (toward cursor, inferred) | 7lKpzGtoQX0 @ 5:31 |
| Left click | Select (face priority by default) | D0TYcB-2_8o @ 13:17 |
| Ctrl/Cmd + click | Add/remove from selection | D0TYcB-2_8o @ 27:09; tooltip @ 13:50 |
| Shift + click | Range select (browser, tool bodies) | F0qnbGiJ1RY @ 2:40:20; D0TYcB-2_8o @ 1:26:23 |
| Drag left to right | Window: only objects fully inside | D0TYcB-2_8o @ 14:51 |
| Drag right to left | Crossing: inside plus touching | D0TYcB-2_8o @ 14:51 |
| Press and hold left | Pick list of overlapping objects (select-through) | D0TYcB-2_8o @ 54:39 |
| Double-click sketch curve | Select connected chain | F0qnbGiJ1RY @ 30:12 |
| Double-click dimension | Edit value | D0TYcB-2_8o @ 47:31 |
| Double-click CAM op icon | Open its dialog | 4irYQjtHZjY @ 25:37 |
| Click, pause, click on name | Rename (browser, timeline) | 4irYQjtHZjY @ 59:01; F0qnbGiJ1RY @ 1:04:34 |
| Right-click canvas | Marking menu (6.3) | D0TYcB-2_8o @ 24:04 |
| Right-click + flick up | Repeat last command (e.g. Joint again) | ZmckF8zYbp0 @ 27:18 to 28:17 (inferred from dialog reopening) |
| Drag arrow handle | Set distance / radius / angle | D0TYcB-2_8o @ 50:04 |
| Drag from line end (Line tool) | Tangent arc | F0qnbGiJ1RY @ 1:53:36 |
| Drag over curves (Trim tool) | Trim many | D0TYcB-2_8o @ 47:01 |
| Drag data-panel item to canvas | Insert into current design | 7lKpzGtoQX0 @ 22:49 |
| Drag appearance swatch to body | Apply appearance | 7lKpzGtoQX0 @ 10:20 |

### 6.2 Keyboard shortcuts seen

| Key | Command | Source |
|---|---|---|
| L | Line | gKGP1iFhd1s @ 1:00:00; ZmckF8zYbp0 @ 7:09 |
| C | Circle | ZmckF8zYbp0 @ 2:33 |
| D | Sketch Dimension | 7lKpzGtoQX0 @ 6:11; gKGP1iFhd1s @ 1:00:00 |
| X | Toggle construction | D0TYcB-2_8o @ 38:53 |
| E | Extrude | 7lKpzGtoQX0 @ 8:26 |
| Q | Press Pull | F0qnbGiJ1RY @ 1:39:05 |
| F | Fillet | F0qnbGiJ1RY @ 1:39:05 |
| M | Move/Copy | F0qnbGiJ1RY @ 1:39:05 |
| A | Appearance | F0qnbGiJ1RY @ 1:39:05 |
| J | Joint | 7lKpzGtoQX0 @ 25:08; ZmckF8zYbp0 @ 25:30 |
| Shift+J | As-built Joint | ZmckF8zYbp0 @ 25:30 |
| I | Measure | 7lKpzGtoQX0 @ 28:56; D0TYcB-2_8o @ 1:35:37 |
| Del | Delete | F0qnbGiJ1RY @ 1:39:05 |
| Ctrl+B | Compute All | F0qnbGiJ1RY @ 1:39:05 |
| Shift+S | Scripts and Add-Ins | ZmckF8zYbp0 @ 11:55 |
| S | Toolbox / command search (said "you can search it") | F0qnbGiJ1RY @ 17:10 (key not named; inferred) |
| 1 / 2 / 3 | Window / Freeform / Paint selection | D0TYcB-2_8o @ 13:50 |
| Ctrl+4 ... Ctrl+9 | Visual styles | D0TYcB-2_8o @ 6:20 |
| Ctrl+Shift+F | Full screen | D0TYcB-2_8o @ 6:20 |
| Shift+1 ("Shift and !") | Back to single viewport / default view (as said) | D0TYcB-2_8o @ 11:35 |
| Shift+N | Component colour cycling (said "press shift and n", inferred) | ZmckF8zYbp0 @ 4:37 |
| Ctrl+Z / Ctrl+C / Ctrl+V | Undo / copy / paste (paste component instance) | D0TYcB-2_8o @ 31:15; ZmckF8zYbp0 @ 24:54 |
| Tab | Next value field (sketch rubber band, dialogs) | 7lKpzGtoQX0 @ 5:07; 4irYQjtHZjY @ 33:46 |
| Enter | Commit value / command | 7lKpzGtoQX0 @ 5:14 |
| Esc | End current tool or chain; stop timeline playback | D0TYcB-2_8o @ 22:31, 12:17 |
| Cmd+G / Ctrl+G | Generate toolpaths (CAM) | 4irYQjtHZjY @ 52:20 |
| Ctrl+/ | Extended help for hovered tooltip | ZmckF8zYbp0 @ 11:55 frame |

### 6.3 Marking menu (right-click on canvas)

Seen with a sketch line selected (frame D0TYcB-2_8o @ 24:04) and with a sketch point selected (@ 33:47):

```
                 [ Repeat <last command> ]          (north)
     [ Delete  x ]                  [ Press Pull ]  (NW / NE)
     [ Undo  <- ]                      [ Redo -> ]  (W / E)
     [ Move/Copy ]                       [ Hole ]   (SW / SE)
                    [ Sketch  v ]                   (south: submenu of sketch tools)
     ---------------------------------------------
     Create Selection Set
     <selection-specific items: Fix/UnFix, Delete Coincident ...>
     Copy                                   Ctrl+C
     Find in Browser
     Find in Window
     Find in Timeline
```

- A translucent wedge from the click point toward the cursor highlights the item the flick will
  hit (frame D0TYcB-2_8o @ 24:04).
- The north item names the last command ("Repeat Line", "Repeat Fix/UnFix") (frames @ 24:04, 33:47).

### 6.4 Right-click menus

- Browser node (body/component): Ground, Revert Position, Edit Joint, Edit Joint Limits, Open,
  Insert into Current Design (data panel) (F0qnbGiJ1RY @ 3:11; ZmckF8zYbp0 @ 23:24; 7lKpzGtoQX0 @ 22:49).
- Timeline item: see 5.1. Sketch: Edit Sketch, Redefine Sketch Plane.
- ViewCube: Set current view as Home (7lKpzGtoQX0 @ 9:58).
- CAM tree: New Setup, Create NC Program, Generate, Simulate, Post Process, Setup Sheet, Copy, Paste,
  Duplicate (4irYQjtHZjY @ 1:30, 1:06:00).

### 6.5 Selection filters

SELECT > Selection Priority (Body / Face / Edge / Component) and Selection Filters; default is face
priority; body priority picks whole bodies (D0TYcB-2_8o @ 13:47 to 14:19). Measure has its own filter
icons (frame D0TYcB-2_8o @ 1:36:05). Project/Intersect has a Selection Filter row (F0qnbGiJ1RY @ 2:08:12).

---

## 7. End-to-end workflows (as performed)

### 7.1 First part: base plate (7lKpzGtoQX0 @ 1:33 to 10:50)
1. File > Save, name "Base plate", Location > New Project "Fusion tutorial", Save.
2. Optional: Document Settings > Units; nav bar Grid off; Display Settings > Environment.
3. SOLID > Create Sketch > XY plane.
4. 2-Point Rectangle from origin: 90, Tab, 90, Enter.
5. Line across a corner; D: end point to origin 20, other end 20 (sketch turns black).
6. Circle, diameter 35; D from edges 40 and 40.
7. Sketch Fillet on three corners, 10 each.
8. Finish Sketch. E (Extrude): pick outer profile only, Distance 10, New Body, OK.
9. ViewCube Home; Shift+middle to orbit.
10. MODIFY > Appearance: drag "Paint Enamel Glossy (Red)" onto the body.

### 7.2 Bracket with walls and holes (7lKpzGtoQX0 @ 10:50 to 17:57)
1. File > New Design, Save into the project.
2. Sketch footprint, extrude 10.
3. Create Sketch on the top face; two rectangles 10 thick snapped to the outline.
4. Extrude three profiles 40, Operation Join.
5. Fillet edge 5, outer 15.
6. Sketch circle on a wall face, Ø15, dims 35 and 20; Extrude -10 (auto Cut).

### 7.3 Fastener (7lKpzGtoQX0 @ 17:57 to 21:33)
1. Sketch on XZ (chosen for assembly orientation), circle Ø15, extrude 30.
2. Sketch on shank end face, Ø25, select both profiles, extrude 5.
3. Chamfer two edges, Equal Distance 2.
4. CREATE > Thread on the shank: ISO Metric, M15x1.5 auto.
5. Sketch circumscribed polygon, flat-to-centre 5, extrude -5 Cut (hex key socket).

### 7.4 Assembly from saved parts (7lKpzGtoQX0 @ 21:33 to 27:42)
1. New design "Assembly file", save in project.
2. Show Data Panel, open project, drag Base plate in; Initial Position at 0; first part grounded.
3. Drag Bracket in, raise Z 40; drag two fasteners, rotate 180 and 90 with wheels.
4. J (Joint): Component 1 snap on base plate corner (hover the correct face), Component 2 on the
   bracket corner; rotate -45; Motion Rigid; OK.
5. Joint fasteners: hole circle centre to fastener circle centre, Rigid.

### 7.5 Edit a part and update the assembly (7lKpzGtoQX0 @ 27:42 to 31:05)
1. Data panel > right-click Bracket > Open.
2. Drag timeline marker back; right-click Sketch1 > Edit Sketch; Ø30 to 35; Finish.
3. I (Measure) to confirm; Save.
4. Open assembly: warning icons in browser and app bar; click "Update child component".
5. Edit Feature on the wall extrude 40 to 60, marker to end, save, update again; joints hold.

### 7.6 Constrained sketch from a drawing (D0TYcB-2_8o @ 24:35 to 31:15)
1. Line tool, click rough outline from lower left, ignore exactness.
2. Select near-vertical line > Horizontal/Vertical.
3. Circle at midpoint (triangle snap); Trim extra; second circle; Ctrl-select circle + line > Tangent.
4. D: dimensions 14, 3, 4, 3, 10, 2.4, R2; Collinear/Coincident to fix the corner; R3.
5. Coincident a free point to the origin: sketch turns fully black, padlock in browser.
6. Add construction lines (X) for dimension anchors; trim; dimension to them.

### 7.7 Master-sketch layout and assembly (F0qnbGiJ1RY, whole stream)
1. Create user parameters (servo sizes, insert diameter).
2. Component "Master Sketches"; top layout sketch with pivots, construction lines, mirrors, equal
   constraints until fully defined; more sketches on other planes projecting pivots.
3. One component per moving part; Extrude Two Sides / To Object up to master geometry.
4. Details, then fillets and chamfers last; group timeline by feature area.
5. Save master; new design for assembly; sub-components; activate target; drag master in.
6. Ground base, Revert Position; copy/paste instances, hide unused bodies.
7. Revolute joints with limits; Interference check.
8. Change master value, save, update the assembly (F0qnbGiJ1RY @ 3:05:03).

### 7.8 Gear gripper mechanism (ZmckF8zYbp0)
1. Sketch slot (Center to Center), circles, perpendicular, aligned dims; extrude 3 as New Component.
2. Base plate, mirror half-sketch about a construction line; extrude New Component.
3. UTILITIES > ADD-INS > Scripts and Add-Ins > SpurGear (Python): module 1.125, 24 teeth, 3 mm.
4. Right-click base > Ground.
5. Joint gear hole to base hole, Motion Revolute; Copy, then Paste New for the second gear.
6. Drag gears apart in top view so teeth mesh; Capture Position.
7. Mirror components about a midplane (Construct > Midplane); repeat revolute joints (right-click flick up).
8. ASSEMBLE > Motion Link Rev1 to Rev2, 360 to 360, Reverse.
9. Right-click joint > Edit Joint Limits: min 0, max 60, Animate.
10. Copy/paste parts for the second layer (linked Paste), offset -3; Rigid Group with the gear.
11. Revolve punches as New Component, rigid-joint and paste copies.

### 7.9 CAM job (4irYQjtHZjY @ 0:36 to 1:12:55)
1. Workspace > Manufacture; close data panel.
2. New Setup > Machine Select (library, e.g. Haas VF-4), save the machine into a project.
3. WCS Orientation "Z axis/plane & X axis", pick faces, Origin Stock box point at the fixed-jaw corner, Z0 at bottom.
4. Model = body; Stock Fixed size box; Post Process tab: program 1001, G54; OK; sync options on; rename setup.
5. 2D Face (face mill), Heights defaults, Passes: pass direction, multiple depths; OK.
6. Simulate with stock comparison; Exit Simulation.
7. 2D Adaptive roughing (stock to leave), 2D Contour finishing (climb), 2D Chamfer (engrave tool).
8. Setup 2 from preceding setup stock; copy/paste ops; Generate (Cmd+G).
9. NC Program: machine config, post, units, choose ops, Post; duplicate for 1002.

---

## 8. Tips the creators stress (candidate ViaForm defaults)

1. Start sketches at the origin; it anchors geometry and is the first step to fully constrained
   (D0TYcB-2_8o @ 21:59 to 24:04). Default: snap first click to origin.
2. Fully constrain every sketch before 3D (D0TYcB-2_8o @ 37:22). Show the defined state clearly:
   blue vs black plus browser padlock (7lKpzGtoQX0 @ 6:11).
3. Draw rough shape first, then constrain, then dimension (D0TYcB-2_8o @ 25:05).
4. Make design intent visible with construction lines, midpoints, equal, symmetry instead of hidden
   alignment and duplicate numbers (F0qnbGiJ1RY @ 23:17, 1:00:57 to 1:02:31).
5. Use parameters for anything repeated; type names and formulas in any field (F0qnbGiJ1RY @ 18:37 to 19:40).
6. Sketches and extrudes first, fillets and chamfers last; never dimension to filleted edges
   (F0qnbGiJ1RY @ 11:24 to 12:27).
7. Group the timeline and insert features at the right history point, not at the end
   (F0qnbGiJ1RY @ 12:27 to 13:28).
8. Drive layout from master sketches, not from other parts' faces; lost references leave dead green
   curves and Fusion does not repair them (F0qnbGiJ1RY @ 1:03, 2:05, 3:42 to 5:46).
9. Anything that moves is its own component; bodies inside a component are rigid (F0qnbGiJ1RY @ 10:53).
10. Keep one tidy master file and one messy assembly file for joints (F0qnbGiJ1RY @ 17:35).
11. Ground the first component; activate the target component before inserting (7lKpzGtoQX0 @ 24:37;
    F0qnbGiJ1RY @ 2:55:43).
12. Hover the correct face when picking joint snaps; the face decides the side (7lKpzGtoQX0 @ 25:38).
13. Paste vs Paste New matters: linked vs independent (ZmckF8zYbp0 @ 14:37).
14. Watch the Operation default (New Body vs Join vs Cut) and Objects To Cut; uncheck bodies you do
    not want cut (D0TYcB-2_8o @ 55:09; F0qnbGiJ1RY @ 2:13:20, 1:47:41).
15. Bodies must be Combined (Join) before a fillet treats them as one (D0TYcB-2_8o @ 1:15:33).
16. Prefer G1 fillets; G2 is slow (D0TYcB-2_8o @ 1:11:28).
17. Do not change units of an existing design; set default units in Preferences (D0TYcB-2_8o @ 18:54).
18. Create a project per job and save immediately so parts, assemblies and drawings stay together
    (7lKpzGtoQX0 @ 1:33). Save often (F0qnbGiJ1RY @ 1:32:30).
19. Avoid 3D sketches; use offset or angled planes plus 2D sketches (F0qnbGiJ1RY @ 1:46:24).
20. Change values in small steps; large jumps can break the solve (F0qnbGiJ1RY @ 1:51:57).
21. Hide master sketches while sketching to avoid picking the wrong curve (F0qnbGiJ1RY @ 50:32).
22. Use add-ins and catalogue parts for gears and fasteners rather than modelling them
    (F0qnbGiJ1RY @ 3:13:19; ZmckF8zYbp0 @ 11:28).
23. Run Interference before printing or ordering (F0qnbGiJ1RY @ 3:01:56).
24. Turn off heavy display effects without a dedicated GPU (D0TYcB-2_8o @ 10:45).
25. CAM: trust the defaults ("99% of the time OK works"), Z0 at the bottom, WCS on a fixed stock
    corner, adaptive for roughing, contour for finishing (4irYQjtHZjY @ 13:55, 28:41, 51:50).

### Implications for ViaForm (inferred, for discussion)

- Default sketch flow: snap to origin, inline dimension boxes with Tab cycling, live blue/black
  state, padlock in the browser.
- Extrude defaults: auto Cut when the drag goes into material, auto New Body for the first feature,
  explicit Objects To Cut list.
- Marking menu with Repeat on top and a right-click flick to repeat, plus the overflow list
  (Create Selection Set, context items, Find in Browser/Window/Timeline).
- Timeline: groups, rename by slow click, roll marker by drag and by menu, red/yellow states.
- Every dropdown command pinnable and rebindable from its kebab.
