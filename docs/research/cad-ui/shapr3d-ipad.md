# Shapr3D on iPad: layout, tools, gestures, history

Reference for ViaForm's iPad app. Goal: match Shapr3D's layout, workflows and gestures,
never its assets (ViaForm keeps its own icons, colours and names).

Built on 2026-11-23 from 11 tutorial videos (transcripts read in full or grepped, about 110
frames inspected). Every claim carries a citation `(videoId @ mm:ss)`. Frame citations use
the frame time (frame N = N x 30 s). "Inferred" or "not seen" marks anything not directly
observed. This file extends `docs/ui-reference.md` (Touch section) and corrects it where the
videos disagree (see section 9).

## 0. Sources and which UI each one shows

The Mac app is the iPad app (same layout, mouse and keyboard on top), and the Windows app
shares it, so desktop videos are valid evidence for layout and tool behaviour. Gestures and
Pencil come only from the three iPad videos.

| Id | Title (short) | Platform | UI generation |
|----|---------------|----------|---------------|
| FFeIJJ1pm70 | Beginners part 7, iPad to 3D printing | iPad Pro + Pencil, light | newest iPad seen (export file dated 2024-12-17, frame @ 23:30) |
| ihBSoDQNqFM | New feature tree (Braun LE02 speaker) | iPad + Pencil, light, parametric beta | 2024 beta; panels mirrored (tools on the right, see 1.4) |
| EHNsV2TvdIo | Furniture design for beginners | iPad + Pencil, light | pre-refresh UI (about 2023) |
| W4MKAuDJ_I8 | Parametric in 30 minutes (stool) | Mac, light, parametric beta | 2024 beta, raw feature names |
| vK4IXELjgkw | Fundamentals: extrude, revolve, loft (bottle) | Mac, dark, labels on | 2025 |
| tXdvSyuHoIE | 5 mistakes (2026) | Windows, light | 2026 |
| J9bHL6BvWSs | Model any shape from an image | Windows, dark, free tier | newest seen (2026-09-22 clock in frame) |
| AgFApKpygiU | Laptop stand, variables | Windows, dark | 2025/2026, "Insert" and "Construct" groups |
| mbCUQTHdWhg | 17 ft media center | Windows, dark | 2025 |
| 3jkPqc4VIVo | CNC tool holder (no voice) | Windows, light | 2025-07-30 (clock in frame) |
| KWw70t7xdCs | 3D printed drone (no voice) | Mac, light | 2025 |

## 1. Screen zones

### 1.1 Newest iPad layout (FFeIJJ1pm70, frames @ 05:00 to 23:00)

```
+--------------------------------------------------------------------------------+
| [ws icon] Modeling        [home] title v  [Share]  (...)      view cube  [mag] |
| [stack]   Items                [tool mode pill v]                         [1mm]|
|                                                                  History [clk] |
| [Search]                                         Constraint Settings [gear]    |
| [Sketch] / sketch tools when sketching                [constraint column]      |
| [Add]                                                                          |
| [Transform]                  canvas                                            |
| [Tools]                                                                        |
|                                                                                |
| [Section View] Off                                                             |
| [Measure]                                                                      |
| (undo) (redo)              "1 edge  \ 5 mm  (i)"                               |
+--------------------------------------------------------------------------------+
```

| Zone | Position | Holds | Open / close |
|------|----------|-------|--------------|
| Workspace switch | top left, first icon | Modeling (icon + label); taps open Modeling, Visualization, Drawings | always visible (FFeIJJ1pm70 frame @ 05:00) |
| Items button | top left, under workspace | opens the Items manager | panel slides in from the LEFT edge and pushes the tool column right (FFeIJJ1pm70 frame @ 16:30) |
| Title pill | top center | home icon, project name with a cloud/sync check, blue Share button, "..." menu | always; greys out under modal sheets (FFeIJJ1pm70 frame @ 23:00) |
| Tool mode pill | top center, under the title pill | name of the active tool plus its sub mode and a chevron: "Line/Arc", "Extrude - One-Sided", "Move/Rotate", "Mirror", "Chamfer/Fillet", "Trim" | appears only while a tool runs; tap opens the mode list (FFeIJJ1pm70 frames @ 05:30, 11:00, 13:00, 15:30, 16:30) |
| Tool hint card | top center (older and desktop builds) | play button (short video), tool name, one line of instructions, collapse chevron | appears on tool start; collapsible (EHNsV2TvdIo frame @ 03:00 and @ 43:00; 3jkPqc4VIVo frame @ 02:00). Newest iPad replaces it with the mode pill (FFeIJJ1pm70 frames) |
| View cube | top right | named faces, two small orbit arrows around it | tap face or corner for preset view, drag to orbit (EHNsV2TvdIo @ 01:30) |
| Right mini rail | far top right, vertical | magnet (snapping menu), grid size chip ("1 mm", "5 mm"), a view/axes options icon | always (FFeIJJ1pm70 frame @ 11:00; ihBSoDQNqFM frame @ 07:30) |
| History button | right, under the rail | clock icon + "History" label | toggles the History sidebar, which slides in from the RIGHT (FFeIJJ1pm70 frame @ 17:30) |
| Constraint column | right, under History, only in sketch mode | "Constraint Settings" gear, then Parallel, Perpendicular, Tangent, Coincident, Midpoint, Concentric, Horizontal/Vertical, Equal, Symmetry, Disconnect, Lock, Make Construction | entries grey until the selection allows them (FFeIJJ1pm70 frame @ 11:00) |
| Tool column | left edge, labels to the right of icons | top level: Search, Sketch, Add, Transform, Tools; in sketch mode the full sketch tool list; with a selection the adaptive list (section 3) | content swaps with context; while a tool runs it shrinks to Search, Deselect All and the running tool with its mode subtitle (FFeIJJ1pm70 frame @ 17:30) |
| Bottom left stack | left, bottom | Construction (sketch only), Isolate (Off/On), Section View (Off/On), Measure; under them undo and redo circles | always (FFeIJJ1pm70 frame @ 11:00) |
| Selection readout | bottom center | "1 edge  5 mm", "2 edges & 2 constraints", "Body 02 (1)", "6 edges 332.98 mm" plus an (i) button | appears with any selection (FFeIJJ1pm70 frame @ 11:00; ihBSoDQNqFM frames @ 15:00, @ 20:30) |
| Done / Cancel | stacked near the tool column or the right rail | blue check "Done", option rows (for example "Keep Originals", "Projection Type"), red X "Cancel" | shown for multi step tools (Mirror, Project, Plane) (FFeIJJ1pm70 frame @ 15:30; ihBSoDQNqFM frame @ 20:30) |

Labels next to icons are on in every iPad video seen; the desktop builds show them too when
"show labels" is on, with the shortcut in a grey chip (vK4IXELjgkw frame @ 01:30).

### 1.2 Desktop newest layout (same app, for reference)

- Left: Items panel docked (filter "All Items / Bodies / Sketches / Planes and Axes"), then a
  slim icon rail; hovering shows a label with shortcut (3jkPqc4VIVo frames @ 02:00 to @ 20:00).
- Workspace group at the top of the rail: Modeling, Visualization, Drawings (Ctrl Shift \ or
  Shift Cmd \), Items (Ctrl Alt S) (J9bHL6BvWSs frame @ 06:00; vK4IXELjgkw frame @ 01:30).
  In 2025/2026 Windows builds the first entry reads "Project / Modeling" (AgFApKpygiU frame @ 01:30).
- Middle group of the rail, nothing selected: Search (Cmd F / Ctrl F), Sketch, Insert,
  Construct, Transform, Tools, Visualize (AgFApKpygiU frame @ 02:00; J9bHL6BvWSs frame @ 26:30).
  On the newest iPad and the 2025 Mac build the same slot holds Search, Sketch, Add, Transform,
  Tools (FFeIJJ1pm70 frame @ 05:00; vK4IXELjgkw frame @ 08:30). So "Add" was later split into
  "Insert" (image, files) and "Construct" (planes, axes, points); inferred from the names.
- Right column: Display Modes (Shaded), Screenshot, History (Alt Cmd P / Ctrl Alt H) as
  labelled round buttons, then the constraint column in sketch mode (vK4IXELjgkw frame @ 01:30).
- Right sidebar: History panel (title with chevron, filter icon, "Select" button, "Related to
  Selection" chip with "Clear") (3jkPqc4VIVo frame @ 02:00).
- Bottom left: Construction, Isolate, Section View, Measure; bottom left corner icons for new
  folder and collapse (vK4IXELjgkw frame @ 01:30).

### 1.3 Pre-refresh iPad (EHNsV2TvdIo, about 2023)

- Top left icon row: projects grid, help "?" with a red notification badge, import, export,
  cloud (EHNsV2TvdIo frame @ 06:00).
- Top right: blue Share pill, "lock # 1 mm" grid chip, settings (same frame).
- Left column is always the adaptive tool list; with nothing selected: Sketch, Add, Transform,
  Tools, Measurements, then Visualization and 2D Drawings at the bottom (EHNsV2TvdIo frame @ 13:00).
- Bottom right: Items manager, snapping, settings gear; bottom left: undo, redo (frame @ 06:00).
- Items manager slides from the left with "All Items" filter and a close X (frame @ 14:30).

### 1.4 Mirrored layout in the feature tree video (ihBSoDQNqFM)

Tools and Search are on the right edge, the constraint column and History button on the left,
the History sidebar docks left and Items docks right (ihBSoDQNqFM frames @ 03:00 to @ 12:00).
Every other iPad video has tools on the left, so this is most likely the left handed layout
setting (inferred, the setting itself is not shown). ViaForm should offer the same mirror.

### 1.5 Where videos disagree

- Tool group names: Add (iPad 2024, Mac 2025) vs Insert + Construct (Windows 2025/2026).
- Tool help: hint card with play button (2023 iPad, 2025 desktop) vs mode pill only (2024 iPad).
- Sketches on one plane: grouped into one "Sketch plane" item in the old UI (EHNsV2TvdIo @ 15:00)
  vs separate sketches per plane in the parametric builds (W4MKAuDJ_I8 @ 06:30).
- Feature names: raw in the beta ("SketchPlane", "CGPlaneWithFaceOffset") (W4MKAuDJ_I8 frame @ 18:30)
  vs friendly later ("Plane - Offset 01", "Sketch 02") (vK4IXELjgkw frame @ 22:30).

## 2. Tool inventory

Common pattern for every tool: start it from the left column or from the adaptive list, the
mode pill (or hint card) names it, on-canvas arrows or gizmo plus a value chip appear, typing
uses the in-app keypad, and it ends with Done (check), Cancel (X), picking another tool,
Escape on desktop, or by tapping empty canvas for single step tools (inferred from repeated
use, never stated as a rule).

### 2.1 Value entry

- Every drag handle carries a white value chip; tap it to type (FFeIJJ1pm70 @ 05:00).
- iPad shows its own keypad popover, not the system keyboard: header with the field name
  ("Spacing distance", "Distance #2"), big value, backspace, +/-, divide, multiply, minus,
  plus, digits, decimal point and a tall blue check key (ihBSoDQNqFM frame @ 15:00;
  FFeIJJ1pm70 frame @ 17:30). Arithmetic in the field is therefore supported.
- Revolve angle field accepts "360 x 4" for four turns (vK4IXELjgkw @ 40:00).
- Sketch dimension chips carry a lock glyph when driving and a diagonal move glyph to drag
  the dimension line (FFeIJJ1pm70 frame @ 11:00; ihBSoDQNqFM frame @ 07:30).
- A dimension driven by Equal has no lock (ihBSoDQNqFM @ 15:30).
- Variables: create a Number variable (unitless multiplier) or a Length variable; expressions
  reference other variables (`screenIn * 25.4`); variables list at the top of History as
  "Screen_in = 15", "Screen_mm = fx 381 mm" (AgFApKpygiU @ 01:30 to @ 02:30, frame @ 03:00).
  Older beta had no formulas yet (W4MKAuDJ_I8 @ 26:00).

### 2.2 Sketch tools

Entering sketch: double tap a face or plane (FFeIJJ1pm70 @ 05:00), tap a view cube face then
Sketch (EHNsV2TvdIo @ 03:00), or desktop Space on a selected face (tXdvSyuHoIE @ 05:30). A
"Normal to Sketch" black pill at the top re-aligns the view (ihBSoDQNqFM frame @ 03:00). Leave
with "Exit Sketching" (first entry of the tool column, subtitle = sketch name) or by rotating
the view away (FFeIJJ1pm70 @ 04:30).

Sketch column, newest desktop order (AgFApKpygiU frame @ 08:00): Exit Sketching, Line, Arc,
Spline (Control), Rectangle (Center), Circle, Ellipse, Polygon (Hexagon), Project, Offset Edge,
Text, Move/Rotate, Scale Sketch, Pattern - Linear, Pattern - Circular, Rotate Around Axis,
Mirror, Trim, Delete, then Construction, Isolate, Section View. iPad 2024 merges Line and Arc
as "Line/Arc (Automatic)" and shows Project - Sketches, Text, Trim, Delete, More (FFeIJJ1pm70
frame @ 06:30; ihBSoDQNqFM frame @ 03:30).

| Tool | Invoke and input | Handles, fields, options | Ends |
|------|------------------|--------------------------|------|
| Line/Arc | tap tool (L), tap or drag points with Pencil; dragging from an end point bends into a tangent arc (inferred from "Automatic" subtitle) | live length and angle chips; snaps to origin, axes, midpoints; horizontal shows a purple inference line (W4MKAuDJ_I8 @ 02:00) | drop the tool: tap tool again, two right clicks (vK4IXELjgkw @ 01:00), Escape (tXdvSyuHoIE @ 15:00), Backspace removes the rubber band segment (J9bHL6BvWSs @ 08:30) |
| Arc | A, 3-Point Arc mode: 2 end points then a third point (KWw70t7xdCs frame @ 02:30 hint) | radius chip | Return or Escape |
| Spline | I; modes Control (control points) and Fit (through points) (vK4IXELjgkw frame @ 05:00) | points placed on a guide line get a coincident constraint and slide only along it; 1 point = G1, 2 points = G2 (vK4IXELjgkw @ 04:30 to @ 05:30); Lock freezes the shape (vK4IXELjgkw @ 30:00) | two right clicks |
| Rectangle | R; modes Diagonal, Center, 3-Point (J9bHL6BvWSs @ 22:00) | width and height text boxes while drawing (EHNsV2TvdIo @ 03:00) | finishes on second point |
| Circle | C; center then radius | diameter chip with lock (FFeIJJ1pm70 frame @ 08:30) | finishes on release |
| Ellipse, Polygon (G, Hexagon/Pentagon/Octagon), Text (Aa) | in column (FFeIJJ1pm70 frame @ 11:00; vK4IXELjgkw frame @ 01:30) | not shown in use | not seen |
| Offset Edge | O; modes Single and Loop in a flyout labelled "Offset Type" (EHNsV2TvdIo @ 07:00, frame @ 07:00) | drag arrow or type distance | on Done |
| Offset (sketch curve) | select curve, Offset, distance (vK4IXELjgkw @ 29:30) | same shape, more control points | Done |
| Trim | T; tap segments to delete | warning: trimming deletes constraints (W4MKAuDJ_I8 @ 05:30) | tap tool again |
| Construction | bottom left toggle: anything drawn while On is construction (FFeIJJ1pm70 @ 06:30) | dashed lines | toggle Off |
| Make Construction / Make Regular | constraint column, on a selection (FFeIJJ1pm70 @ 07:00; ihBSoDQNqFM frame @ 05:30) | | immediate |
| Project (Project - Sketches) | select source sketches (or body edges) then target plane; dialog offers Project vs Pattern (ihBSoDQNqFM @ 20:00 to @ 20:30); "Projection Type: Sketches" option row (ihBSoDQNqFM frame @ 20:30) | projected curves are purple and stay linked to the source (ihBSoDQNqFM @ 21:00) | Done |
| Mirror (sketch) | select curves, then the axis line (J9bHL6BvWSs @ 11:00) | mirrored copy stays linked: dragging one side moves the other (J9bHL6BvWSs @ 21:30) | immediate |
| Pattern - Linear (sketch) | select curve, Spacing + Quantity (ihBSoDQNqFM @ 15:00, @ 16:30) | | Done |
| Pattern - Circular | select lines, rotate 180 deg; keeps constraints, unlike Move (AgFApKpygiU @ 36:00) | | Done |
| Delete / Delete Constraints | trash at the bottom of the column; label changes to "Delete Constraints" when a constraint glyph is selected (FFeIJJ1pm70 frame @ 11:30) | | immediate |

### 2.3 Solid and surface tools (Add / Tools groups and the adaptive list)

| Tool | Selection needed | Handles and fields | Options | Ends |
|------|------------------|--------------------|---------|------|
| Extrude (E) | one or more sketch profiles or faces; tapping a profile starts it directly (W4MKAuDJ_I8 @ 06:00) | arrow on the face plus value chip; a second small icon beside the chip opens the result menu: New Body, Union, Subtract, Intersect (tXdvSyuHoIE frame @ 06:30) | modes One-Sided, Symmetric (vK4IXELjgkw @ 16:00); draft by a second arrow ("drag arrows to extrude and add draft", 3jkPqc4VIVo frame @ 15:00); in History: Extent Distance or Object (bound to a face), Draft Angle, Result (W4MKAuDJ_I8 @ 13:00; ihBSoDQNqFM frame @ 08:30) | default result is Union when touching a body, Subtract when cutting into it (EHNsV2TvdIo @ 12:30) |
| Offset Face | face(s); the arrow appears right after selecting a face (EHNsV2TvdIo @ 06:00) | arrow along the face normal + chip | type Total (3jkPqc4VIVo frame @ 07:30) | recorded as "Face Offset NN" |
| Chamfer/Fillet (F) | edges, or faces (all bounding edges) (J9bHL6BvWSs @ 24:00) | arrow + chip with a "Fillet v" type chip | Fillet, Chamfer, 2-Distance Chamfer (FFeIJJ1pm70 @ 17:30); History: Size Type Radius, Continuity G1/G2, Corner Rolling Ball, Overflow Auto, Curvature, Include Tangent Edges, Y-Shaped Blend (vK4IXELjgkw frame @ 35:00) | errors as toasts: "Operation failed because resulting body couldn't be valid", "Range of blend is too large" (J9bHL6BvWSs @ 24:30 to @ 25:30), "Illegal overlap" (FFeIJJ1pm70 @ 21:30) |
| Shell (H) | body or face | thickness | | (vK4IXELjgkw @ 12:00) |
| Revolve (V) | profile + axis (shift select on desktop) | angle chip, height arrow for helix | readout "Z axis & 1 face, angle, dX dY dZ"; multiply angle for turns (vK4IXELjgkw @ 39:00, frame @ 40:00) | error if self intersecting (vK4IXELjgkw @ 40:00) |
| Loft | two or more faces or profiles | | Profiles Edit..., Periodic Loft toggle, Guides Edit..., Start/End Continuity None/G1/G2, magnitudes (vK4IXELjgkw frame @ 08:30) | Done |
| Sweep | profile, then shift select the path (vK4IXELjgkw @ 20:00) | | path end defines the end, so later edits propagate better than Extrude (ihBSoDQNqFM @ 21:30) | Done |
| Union / Subtract / Intersect | bodies; Subtract marks each body with + (keep, remove from) or - (tool) and the user flips them (EHNsV2TvdIo @ 13:00) | | Keep Originals toggle (FFeIJJ1pm70 @ 16:00); History: keep target bodies, keep tool bodies (mbCUQTHdWhg @ 49:00) | Done |
| Split Body | body + curve or plane ("think of a hot wire") (vK4IXELjgkw @ 29:00; mbCUQTHdWhg @ 54:30) | | | Done |
| Replace Face | face to move + target face; extends and matches curved targets (W4MKAuDJ_I8 @ 19:00; EHNsV2TvdIo @ 30:30) | | | Done |
| Add Plane / Construction plane | Add > Construction plane, pick type, pick references, "Next", drag or type offset, "Done" (W4MKAuDJ_I8 @ 14:30) | | types seen: Offset from face, Midplane (2 faces) (tXdvSyuHoIE @ 18:30), Parallel to face at point (W4MKAuDJ_I8 @ 17:00), Perpendicular to edge at point (ihBSoDQNqFM @ 08:30), At edge with angle (ihBSoDQNqFM @ 16:00), On curve at point (vK4IXELjgkw @ 19:00), Through edge at angle (AgFApKpygiU @ 49:30) | plane rows land in History and Items |
| Add Axis | cylindrical face, or 2 planes (ihBSoDQNqFM @ 15:30; EHNsV2TvdIo frame @ 06:00) | | Type "Along Edge" (ihBSoDQNqFM frame @ 16:00) | Done |
| Insert Image | Insert > image, snaps to the active sketch rectangle (J9bHL6BvWSs @ 06:00) | "Edit Image" mode: resize, Opacity slider (J9bHL6BvWSs frame @ 06:30, @ 11:30) | | Done |

### 2.4 Transform

| Tool | Behaviour |
|------|-----------|
| Move/Rotate (M) | gizmo at the object center: 3 arrows, rotation arcs, a free move handle, plus a "Copy" badge to toggle copy mode (EHNsV2TvdIo @ 04:00; tXdvSyuHoIE frame @ 14:30). The gizmo center can be dragged to a corner first, to rotate about it (W4MKAuDJ_I8 @ 14:00). With Copy left on, each typed move is measured from the original, giving several copies (EHNsV2TvdIo @ 27:00). Distances are center to center, not edge to edge (EHNsV2TvdIo @ 04:30). Recorded as "Movement/Rotation NN" (tXdvSyuHoIE frame @ 17:00). |
| Scale (S) | Uniform / Non-uniform modes; gizmo center can be moved to scale from a corner (J9bHL6BvWSs @ 07:00, @ 13:00) |
| Align | pick an edge or face on the moving part, then the mating one; snaps midpoint to midpoint and lays the part flat (EHNsV2TvdIo @ 05:30, @ 36:30) |
| Translate (N) | pick start and end points up front (EHNsV2TvdIo @ 36:00) |
| Rotate Around Axis | angle chip with Copy badge (vK4IXELjgkw frame @ 22:30) |
| Mirror | select items, then a plane or linear item; Keep Originals toggle (FFeIJJ1pm70 @ 15:30). Hint text: "Select items to mirror. Select a plane or linear item to set it as the mirror reference." (tXdvSyuHoIE frame @ 11:00) |
| Pattern | Linear: Total Distance or Spacing, Quantity (EHNsV2TvdIo @ 23:00) |
| Project | also listed under Transform (P) (vK4IXELjgkw frame @ 22:30) |

### 2.5 Measure, section, display

- Tapping an edge shows its length in the bottom readout; two items show distance, angle and
  dX dY dZ components (EHNsV2TvdIo frame @ 06:00, @ 20:00).
- Measure tool: "+" next to Point to Point, pick points, Done; measurements stay pinned and
  reappear whenever Measure is on (EHNsV2TvdIo @ 11:00). Desktop "Object measurement" has a pin
  icon to keep it on canvas and an Unpin (tXdvSyuHoIE @ 16:30).
- Section View: pick a plane, drag the arrow; cut faces are hatched per body colour; panel
  offers Delete Section and Ortho View (vK4IXELjgkw frame @ 26:00; 3jkPqc4VIVo frame @ 07:30).
- Isolate (Off/On) shows only the selection (FFeIJJ1pm70 frame @ 11:00).
- Display Modes menu: Shaders Wireframe, Shaded, Visualized; Surface Analysis Zebra, Curvature
  Map; Options Show Edges, Show Hidden Edges (vK4IXELjgkw frame @ 35:00).

### 2.6 Visualization workspace

- Switch from the workspace button (W4MKAuDJ_I8 @ 27:30). iPad version shows a left column
  Visualization, Properties, View, AR, Capture (ihBSoDQNqFM frame @ 02:30).
- Select bodies (drag a box), tap "Change", pick from Plastics, Metal, Wood, Glass, Stone,
  Leather, Fabric, Utility (W4MKAuDJ_I8 @ 27:30 to @ 28:00).
- Right panel tabs Material, Environment, Camera, with "Search Materials" and swatch grid
  (vK4IXELjgkw frame @ 43:30). Wood grain rotate (90 deg) and scale (W4MKAuDJ_I8 @ 28:00).
- Environments (Carousel 2, gradient background) and lighting (W4MKAuDJ_I8 @ 28:30; vK4IXELjgkw @ 44:00).
- Buttons Capture and Generative Render (vK4IXELjgkw frame @ 43:30); AR to place the model in
  a room on iPad (W4MKAuDJ_I8 @ 29:00; mbCUQTHdWhg @ 61:30).

### 2.7 Drawings

"Create Drawing" sits in the body selection list (FFeIJJ1pm70 frame @ 16:30; EHNsV2TvdIo frame
@ 14:30) and Drawings is a workspace (vK4IXELjgkw frame @ 01:30). No video shows the drawing
editor itself: not seen.

### 2.8 Export and sharing

iPad (FFeIJJ1pm70 @ 23:00, frame @ 23:00): Share > Export > Export project opens a sheet:
left list with "All Formats" filter, Favorites (3MF, STEP, Image, each starred), Everything
Else (Shapr3D, Parasolid file, DXF from Sketch, DXF from Drawing, IGES, STL...), stars to
favourite; right pane per format, for 3MF "3D Manufacturing Format" description, Resolution
Low / High / Custom segmented control, Include Mesh Bodies, file name field, Include Hidden
Items, Save Each 1st-Level Item Separately; top bar Cancel, Select, format name, share icon
(AirDrop) and Export. Desktop: File > Export to... STL, low quality (J9bHL6BvWSs @ 26:30).
Pro is required to export (FFeIJJ1pm70 @ 02:30). Free tier shows a "Limited Access Version /
Upgrade" pill at the top (J9bHL6BvWSs frame @ 06:00).

## 3. Selection model and adaptive suggestions

- Tap selects a face, edge, sketch profile or point; selected faces turn cyan, the active
  sketch surface is more saturated than its neighbours (EHNsV2TvdIo @ 08:30).
- Double tap selects the whole body (EHNsV2TvdIo @ 04:00, @ 29:30; FFeIJJ1pm70 @ 15:30).
  On a sketch face double tap enters the sketch on it (FFeIJJ1pm70 @ 05:00). On desktop,
  double click selects a whole rectangle (W4MKAuDJ_I8 @ 09:00).
- Multi select: keep tapping on iPad (inferred: EHNsV2TvdIo @ 05:30 says mouse users hold
  Shift, implying taps add on iPad); drag a box on empty canvas (EHNsV2TvdIo @ 14:30), the
  drag direction matters for crossing vs window (EHNsV2TvdIo @ 24:30, inferred from "drag from
  right to left"); Items rows also select.
- Select through: desktop right click "Select Through This Point" lists stacked candidates
  (Body, Face, Sketch, Profile) in a small popup (vK4IXELjgkw @ 31:30; KWw70t7xdCs frame @ 08:00).
- Tab on desktop shows a selection slider to filter edges by size (vK4IXELjgkw @ 36:00).
- Selection count and summary always at the bottom center (section 1.1).

Adaptive tool list (left column replaces Search, Sketch, Add, Transform, Tools):

| Selection | Entries seen |
|-----------|--------------|
| 1 face (pre-refresh) | Deselect All, Sketch, Move/Rotate, Scale (Uniform), Align, Offset Face, Chamfer/Fillet (Auto), Extrude, Shell, Add Plane (Offset), Add Axis, Visualize, More, Delete, Measurements (EHNsV2TvdIo frame @ 03:30) |
| 2 faces | Deselect All, Move/Rotate, Scale, Align, Mirror, Offset Face, Chamfer/Fillet, Extrude, Shell, Loft, Replace Face, Add Axis (2 Planes), Visualize, More, Delete, Measurements (EHNsV2TvdIo frame @ 06:00) |
| 1 edge | Deselect All, Move/Rotate, Scale, Align, Chamfer/Fillet, Offset Edge (Single), Add Plane (Perp. to Curve), Add Axis (Edge), More, Measurements (EHNsV2TvdIo frame @ 05:30) |
| body (newest iPad) | Search, Deselect All (Body 02 (1)), Move/Rotate, Scale (Uniform), Pattern (Linear), Align, Chamfer/Fillet (Auto), Shell, Visualize, Create Drawing, Translate, Rotate Around Axis, Mirror, Union, More, Delete, then Isolate, Section View, Measure (FFeIJJ1pm70 frame @ 16:30) |
| several bodies | Deselect All, Move/Rotate, Scale, Pattern, Align, Rotate Around Axis, Mirror, Create Drawing, More, Delete, Measurements (EHNsV2TvdIo frame @ 14:30) |
| sketch plane | Deselect All, Sketch, Move/Rotate, Scale, Pattern, Rotate Around Axis, Mirror, Offset Edge, More, Delete (EHNsV2TvdIo frame @ 16:30) |
| sketch curve | suggestion to add a plane on the curve ("roller coaster") (vK4IXELjgkw @ 19:00) |
| sketch entities in sketch mode | the constraint column lights up only the constraints valid for the pair (FFeIJJ1pm70 frame @ 11:00) |
| face + tool running | column collapses to Search, Deselect All and the tool with its mode (FFeIJJ1pm70 frame @ 17:30) |

Selecting a profile directly starts Extrude; selecting a face directly shows the Offset Face
arrow, which surprises users (EHNsV2TvdIo @ 06:00, they warn to use Move instead).

## 4. Gestures, Pencil, keyboard

### 4.1 Touch (iPad)

| Input | Action | Source |
|-------|--------|--------|
| one finger drag on canvas | orbit | EHNsV2TvdIo @ 01:00 |
| two finger drag | pan | EHNsV2TvdIo @ 01:00 |
| pinch | zoom | EHNsV2TvdIo @ 01:00 |
| drag the view cube | orbit; tap face or corner for preset view | EHNsV2TvdIo @ 01:30 |
| double tap (cube) | back to iso view | EHNsV2TvdIo @ 01:30 (wording unclear, inferred on the cube) |
| tap | select | all iPad videos |
| double tap | select body, or enter sketch on a face | section 3 |
| drag on empty canvas with Pencil | selection box | EHNsV2TvdIo @ 14:30 (inferred tool: Pencil) |
| long press a History row | row menu with Insert Breakpoint | FFeIJJ1pm70 @ 19:00 |
| long press an Items row then drag | move it between folders | EHNsV2TvdIo @ 27:00 |
| tap undo / redo circles | undo / redo | bottom left (FFeIJJ1pm70 frame @ 11:00) |
| two finger tap | undo | not seen (claimed in ui-reference.md) |

### 4.2 Pencil

- Pencil draws and picks; the other hand stays on the glass for orbit and pan, palm resting
  on the screen while drawing (FFeIJJ1pm70 frames @ 06:30 to @ 14:00). Palm rejection is
  therefore required (inferred). One user wishes for a drawing glove (FFeIJJ1pm70 @ 14:00).
- Pencil taps value chips and the keypad (FFeIJJ1pm70 frame @ 17:30).
- Hover, squeeze, double tap on Pencil: not seen.

### 4.3 Keyboard and mouse (desktop, also valid with an iPad keyboard, inferred)

Navigation: wheel zoom, right button pan, Shift + right button orbit (EHNsV2TvdIo @ 01:30).
Shortcuts seen in labels (vK4IXELjgkw frames @ 01:30, @ 22:30; J9bHL6BvWSs frame @ 06:00;
tXdvSyuHoIE frames; KWw70t7xdCs frame):

| Key | Command | Key | Command |
|-----|---------|-----|---------|
| L | Line | E | Extrude |
| A | Arc | F | Chamfer/Fillet |
| I | Spline | H | Shell |
| R | Rectangle | V | Revolve |
| C | Circle | M | Move/Rotate |
| G | Polygon | S | Scale |
| O | Offset Edge | N | Translate |
| T | Trim | P | Project |
| Cmd F / Ctrl F | Search | Ctrl U | Union |
| Shift Cmd A | Deselect All | Alt Cmd P / Ctrl Alt H | History |
| Shift Cmd \ / Ctrl Shift \ | Drawings | Ctrl Alt S | Items |
| Ctrl Shift H | Show/Hide | Ctrl A | Select All |
| Space | sketch on selected face / plane | Backspace | end the line chain |
| Escape | drop tool | Return | finish (hint text) |

Constraint keys appear as a modifier plus letter in the column (Parallel A, Perpendicular P,
Tangent T, Coincident N, Midpoint M, Concentric C, Horizontal/Vertical V, Equal E, Symmetry S,
Lock L); the modifier glyph is too small to read, Shift is inferred (vK4IXELjgkw frame @ 01:30).

Right click menu on canvas (desktop; iPad long press equivalent inferred, not seen): Select
All, Select Through This Point, Sketch on Face, Section View, Show/Hide, Isolate, Zoom to, Show
Grid, Show World Axes, Show Edges, Show Hidden Edges, Reveal in Items Sidebar, Search Commands
(J9bHL6BvWSs frame @ 11:30).

## 5. Parametric history and sketch constraints

### 5.1 History sidebar

- Every action is a row with a type icon and an auto name: Sketch 01, Extrusion 01, Revolution
  01, Loft 01, Deletion 01, Boolean 01, Fillet 01, Shell 01, Chamfer 01, Mirror 01, Sweep 01,
  Split Body 01, Face Offset 04, Movement/Rotation 02, Plane - Offset 01, Plane - On Curve at
  Point 01, Axis 01 (vK4IXELjgkw frame @ 33:30; ihBSoDQNqFM frame @ 03:00). Direct push-pull
  edits are recorded too, so direct and parametric modeling mix (ihBSoDQNqFM @ 01:30).
- Rows can be renamed ("Driving sketch", "Body outline", "Top button sketch") (ihBSoDQNqFM frame @ 03:00).
- Header: "History" with chevron, a filter icon and "Select" (FFeIJJ1pm70 frame @ 17:30). With
  a selection, a "Related to Selection" chip filters rows and shows hidden counts "(15)" between
  them; "Clear" removes the filter (3jkPqc4VIVo frame @ 10:00).
- Edit: double tap (iPad) or click the chevron to expand a row in place, showing its
  parameters: for a sketch "Plane: Select..."; for an extrusion Profile Edit..., Distance 80
  mm, Draft Angle 0 deg, Extent Distance, Result New Body (ihBSoDQNqFM frames @ 03:00, @ 08:30,
  @ 11:30). Editing a sketch re-enters it; the 3D model updates live while dragging
  (vK4IXELjgkw @ 32:30).
- Reorder: drag a row up or down; the model rebuilds in the new order (moving a Face Offset
  above a Mirror applies it to both halves) (W4MKAuDJ_I8 @ 15:30 to @ 16:00; vK4IXELjgkw @ 14:00;
  mbCUQTHdWhg @ 05:00).
- Breakpoint (rollback): long press a row > Insert Breakpoint (FFeIJJ1pm70 @ 19:00) or drag the
  grey "Breakpoint" bar with a grab handle; rows below it turn grey and the canvas shows the
  model up to that point (ihBSoDQNqFM @ 07:30, frame @ 07:30). Tapping the bar offers a red
  "Delete" with trash; deleting it rebuilds everything (ihBSoDQNqFM frame @ 11:30; FFeIJJ1pm70
  @ 20:30). New features are inserted at the breakpoint (vK4IXELjgkw @ 17:30).
- Delete a feature: right click > Delete (vK4IXELjgkw @ 08:00).
- Suppress / unsuppress a step; copy a value to the clipboard before recreating it (AgFApKpygiU
  @ 77:00 to @ 78:30).
- Broken steps show yellow arrows in the tree (ihBSoDQNqFM @ 23:30); inside a broken sketch,
  missing references and constraints are red (AgFApKpygiU @ 64:00, @ 76:30).
- Imported or legacy geometry appears as one "Merged Steps" row (3jkPqc4VIVo frame @ 07:30).
- A user could not find how to clear history after deleting all items (J9bHL6BvWSs @ 03:30):
  ViaForm should make this obvious.

### 5.2 Constraints and dimensions

- Colour state: blue = free, green = fully constrained (vK4IXELjgkw @ 01:30; AgFApKpygiU @
  36:30 "until the sketch is green").
- Constraint Settings toggles: Always Show Constraints, Always Show Dimensions (vK4IXELjgkw @ 01:00).
- Auto constraints: snapping on release adds coincident, horizontal, midpoint (W4MKAuDJ_I8 @
  04:30; mbCUQTHdWhg @ 08:30 "already set to auto constraint").
- Constraint glyphs sit beside the geometry as small icon squares; tap one and Delete
  Constraints removes it (FFeIJJ1pm70 @ 11:00 to @ 12:00, frame @ 11:30).
- Lock a single point (lock icon in the column) rather than the whole line (W4MKAuDJ_I8 @ 03:00).
- Dimensions: select one item for its length, two for a distance; an icon in front of the
  number chooses Vertical, Horizontal or aligned distance (vK4IXELjgkw @ 03:30 to @ 04:00).
- Symmetry: select two items, then tap the axis line (FFeIJJ1pm70 @ 09:30).
- Equal chains propagate without dimensions (ihBSoDQNqFM @ 15:30).
- Projected references (purple) keep the link to earlier sketches (ihBSoDQNqFM @ 21:00).
- A purple dot on a point means it is attached to an earlier sketch (ihBSoDQNqFM @ 09:30).

## 6. Items manager

- Opens from "Items" (top left, iPad) and slides in from the left (FFeIJJ1pm70 frame @ 16:30);
  in the mirrored layout it docks right (ihBSoDQNqFM frame @ 07:30).
- Header filter: All Items, Bodies, Sketches, Planes and Axes (ihBSoDQNqFM frames @ 12:00,
  @ 21:30; 3jkPqc4VIVo frame @ 02:00); new folder icon top right or bottom left.
- Rows: type icon, name, subtitle count ("0 items", "34 sketches", "0 geometries, 5 items"),
  a round chevron to open a folder, eye toggle (hidden rows grey with a struck eye)
  (ihBSoDQNqFM frame @ 07:30). Images show an opacity value (J9bHL6BvWSs frame @ 24:00).
- Selected rows turn solid blue with white text; bottom bar Rename, Delete, More...
  (FFeIJJ1pm70 frame @ 16:30).
- Folders: select items, tap folder+ to group, rename (EHNsV2TvdIo @ 14:30); the open folder
  is the active one, new sketches land in it (EHNsV2TvdIo @ 27:00).
- Copies are named "Body 02 (1)" (FFeIJJ1pm70 frame @ 16:30).
- Reveal in Items Sidebar from the canvas (J9bHL6BvWSs @ 11:30).
- Empty states: folder illustration with "Workspace is empty" (W4MKAuDJ_I8 frame @ 01:30) and
  "Folder is empty" (mbCUQTHdWhg frame @ 02:30).
- Colour and material are set in Visualization, not in Items (section 2.6). Lock per item:
  not seen.

## 7. End to end workflows

### 7.1 iPad part to 3D print (FFeIJJ1pm70 @ 03:00 to @ 23:30)
1. New project, set units mm, lock grid 1 mm, turn on all snapping (magnet).
2. Top view, Sketch, Rectangle Center from origin, type 25 x 15.
3. Rotate away (exits sketch), tap profile, Extrude 6 mm.
4. Double tap top face, Circle 10 mm, extrude down 4 mm (cut); double tap the new floor,
   Circle 7 mm, push through.
5. Double tap side face, Construction on, draw a floating horizontal line, H/V constraint,
   Construction off, circles 8 and 4.5 mm on it, tangent lines, Symmetry about the line,
   delete conflicting constraints, Trim.
6. Exit, extrude 5 mm, fillet 0.5 and 1 mm.
7. Double tap body, Mirror about the origin plane, Keep Originals on, Done.
8. Box select all, Union, Keep Originals off.
9. Chamfer/Fillet in 2-Distance mode, edit distances in History.
10. Fix: long press the sketch in History, Insert Breakpoint, edit, delete the breakpoint, model rebuilds.
11. Share > Export > Export project > 3MF (High) > share icon > AirDrop to the Mac > slicer.

### 7.2 Parametric stool (W4MKAuDJ_I8 @ 01:00 to @ 29:30)
1. Units, grid lock, snapping. Left view via the cube, Sketch, 4 lines, dimensions 300, 83 deg.
2. Lock only the origin point; construction center line; circle center coincident on it.
3. Tap profile, Extrude 30 mm.
4. Sketch on the face (new sketch on the same plane), center rectangle, symmetry, coincident.
5. Cut a hole with Extent = Object (back face) so it always goes through.
6. Move/Rotate the leg 10 deg about a moved gizmo center; rotate faces back flat.
7. Add > Construction plane > Offset from face 220 mm, Transform > Mirror.
8. Reorder Face Offset above Mirror in History to drive both legs.
9. Stretcher: plane parallel to face at point, rectangle, extrude, bound to the other leg face,
   Replace Face for the far end.
10. Sanity check by editing the first sketch, then Visualization, wood material, AR.

### 7.3 Bottle with revolve, loft, shell, sweep (vK4IXELjgkw @ 00:00 to @ 44:30)
1. Front view, sketch the half profile, horizontal/vertical, dimensions until green.
2. Revolve cap and bottom, Loft between the two faces with G2 both ends.
3. Shell 2 mm, fillet 10 mm, drag the fillet above the shell in History.
4. Plane offset 120 mm, spline, plane on curve at point, profile, Sweep, Subtract, Mirror.
5. Rename bodies, group sketches in folders.
6. Sculpt the cap with two sketches and symmetric extrude cuts, Split Body by a spline.
7. Fillets in G1, switch to G2 at the end in History.
8. Thread: triangle profile, Revolve with height 5 mm and angle 360 x 4, Union.
9. Visualization: car paint, powder coat, matte plastic, gradient environment.

### 7.4 Trace from an image (J9bHL6BvWSs @ 05:00 to @ 27:30)
1. Sketch a 220 x 245 box on the top plane, Exit, Insert image, rotate 90, Transform > Scale
   from a corner to fit the box.
2. Construction center line, Spline trace one half, overshoot and Trim, Mirror the curve.
3. Repeat on the side and front planes; extrude the top profile, extrude the others as
   symmetric cuts through.
4. Fillet faces, then edges with trial values, File > Export STL.

### 7.5 Off-origin mirror (tXdvSyuHoIE @ 12:30 to @ 20:00)
1. Body as New Body (result menu next to the value chip), rename it.
2. Move/Rotate with Copy to reuse it.
3. Add > Construction plane > Midplane between two faces, Done.
4. Mirror the small body about the new plane; hide bodies with the eye to reach the plane.

### 7.6 Debug a broken parametric model (AgFApKpygiU @ 61:00 to @ 78:30)
1. Change the master variable, look for broken rows.
2. Open the sketch feeding the first broken row, find lost references.
3. Undo to an unbroken state, add a connecting line so the solver keeps sides.
4. Move the History break one step at a time; reselect profiles and edges.
5. Copy a value, suppress the step, recreate it, paste; suppress then unsuppress as last resort.

## 8. Details that make it feel native

- Tool hint card with a play button (video) and one line of instructions, collapsible
  (EHNsV2TvdIo @ 43:00; 3jkPqc4VIVo frame @ 02:00).
- Mode pill under the title with a chevron (FFeIJJ1pm70 frames).
- Labels beside every icon with a grey subtitle for the current sub mode ("Automatic",
  "Center", "Pentagon", "Single", "Linear", "Off") (FFeIJJ1pm70 frame @ 11:00).
- Disabled constraints stay visible but grey, so the column never jumps (same frame).
- Purple inference lines for horizontal and alignment, purple guide points on the active
  face, magenta guide line for spline control (W4MKAuDJ_I8 @ 02:00; EHNsV2TvdIo @ 08:30;
  vK4IXELjgkw @ 30:30). "Show guide points" is a snapping option (EHNsV2TvdIo @ 08:30).
- Unconstrained blue vs constrained green sketch (vK4IXELjgkw @ 01:30).
- Grid size locks so snapping stays fine when zoomed out (EHNsV2TvdIo @ 02:30); unit menu:
  mm, cm, m, in, ft, fractions or decimals, degree format (mbCUQTHdWhg @ 02:00, frame @ 02:30).
- Live 3D rebuild while dragging sketch points (vK4IXELjgkw @ 32:30).
- Hatched, per body coloured section faces (3jkPqc4VIVo frame @ 07:30).
- Copy badge on the gizmo instead of a separate Duplicate command (tXdvSyuHoIE @ 14:30).
- Custom keypad with arithmetic keys instead of the system keyboard (ihBSoDQNqFM frame @ 15:00).
- Error toasts in plain words for fillet failures (J9bHL6BvWSs @ 24:30).
- Empty states with an illustration (W4MKAuDJ_I8 frame @ 01:30).
- Home screen: Recents, "What's New?" cards, Recent Projects thumbnails, project folders in
  the sidebar (mbCUQTHdWhg @ 01:30, frame @ 01:30).
- Title pill collapses to home + "..." when both side panels are open (ihBSoDQNqFM frame @ 07:30).
- In-app tutorials and a help badge (EHNsV2TvdIo @ 43:00).
- Animations: panel slides and breakpoint drag were seen moving but frame sampling (30 s)
  cannot show timing; durations not seen.

## 9. Corrections to docs/ui-reference.md (Touch section)

| ui-reference.md says | Videos show |
|----------------------|-------------|
| Top bar holds project sidebar, items, history, undo/redo, section, isolate, export | top center pill holds only home, title, Share, "..."; Items is top left; History is top right; undo/redo bottom left; Section View, Isolate, Measure bottom left (FFeIJJ1pm70 frame @ 11:00) |
| Items manager on the right | slides in from the left (FFeIJJ1pm70 frame @ 16:30); right only in the mirrored layout |
| Project sidebar with spaces | workspace switcher is the first top left icon (Modeling, Visualization, Drawings); projects live on the home screen |
| Adaptive suggestions near the selection | they replace the left tool column, not a popover near the selection (EHNsV2TvdIo frame @ 06:00; FFeIJJ1pm70 frame @ 16:30) |
| Two finger tap undoes | not seen in any video |
| Value entry "tap the number to type with arithmetic" | confirmed, via a custom keypad popover (ihBSoDQNqFM frame @ 15:00) |
