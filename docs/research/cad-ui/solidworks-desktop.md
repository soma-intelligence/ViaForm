# SolidWorks desktop: UI and workflow reference

Research note for ViaForm (Mac Swift app, Fusion-style layout today, see `docs/ui-reference.md`).
Goal: borrow SolidWorks workflows and input mappings where they beat Fusion. Never its assets:
ViaForm keeps its own icons, colours and command names.

## Sources and conventions

| Id | Video | Length | What it shows |
|----|-------|--------|---------------|
| YIguko4mXRM | The ULTIMATE SolidWorks Beginner Masterclass | ~7 h | SolidWorks 2019/2020 Student, sketching, features, configurations, design tables, assemblies, mates. Webcam overlay bottom right. |
| XdWYW4HOLT4 | SOLIDWORKS CSWA Practice Exam Walk-Through (official edu webinar) | ~53 min | Recent SolidWorks (Simplified Interface, Basic Modeling Tools tab), CSWA part questions 3 to 6, shortcuts, mouse gestures, mass properties. |
| CWbDrbiepSE | SolidWorks CSWA practice exam (teacher walk-through) | ~60 min | SolidWorks 2017 Education, CSWA test client, part questions and the chain-link assembly with angle mates. |

- Citation format: `(videoId @ time)`. Masterclass times are `h:mm:ss` because it runs past one hour; the CSWA videos use `mm:ss`.
- `frame` after a time means the claim comes from a still I read at that exact time (about 90 stills, extracted with ffmpeg at chosen timestamps). No `frame` means the narration.
- `[inferred]` marks my reading of a frame or general SolidWorks knowledge that no video states. `[not in videos]` marks topics the brief asked for that the three videos do not cover; those lines are general knowledge and should be verified before ViaForm relies on them.
- Command names below are SolidWorks' own, quoted only to identify behaviour. ViaForm must rename them.

---

## 1. Screen zones and their behaviour

Default part window, top to bottom, left to right (YIguko4mXRM @ 0:02:30 frame; YIguko4mXRM @ 1:43:10 frame).

| Zone | Position | Behaviour |
|------|----------|-----------|
| Menu bar | top strip, left | Logo, then File, Edit, View, Insert, Tools, Simulation, Window, Help, and a pin that keeps the menus open (YIguko4mXRM @ 0:02:30 frame). Insert holds every feature family plus Tables (Design Table, BOM) and Customize Menu (YIguko4mXRM @ 5:00:40 frame). Tools holds Equations (XdWYW4HOLT4 @ 20:00). |
| Quick access toolbar | top strip, right of menus | Home, New, Open, Save, Print, Undo, Select, Rebuild (traffic-light icon, tooltip "Rebuilds the part, assembly, or drawing"), File Properties, Options gear (CWbDrbiepSE @ 59:00 frame; YIguko4mXRM @ 2:41:20). |
| Search Commands | top right | Text box that searches commands (YIguko4mXRM @ 0:02:30 frame). |
| CommandManager | under the menu bar | Icon ribbon. Big icons with text for primary commands, small icon plus label rows for secondary ones, a small down arrow under a button opens variants (Fillet arrow holds Chamfer) (YIguko4mXRM @ 3:17:53). Tab strip sits **below** the icons, not above (YIguko4mXRM @ 2:44:10 frame). Tabs change with document type: part shows Features, Sketch, Surfaces, Mold Tools, Direct Editing, Evaluate, Add-Ins, Simulation, Analysis Preparation, CAM (YIguko4mXRM @ 2:44:10 frame); assembly shows Assembly, Layout, Sketch, Markup, Evaluate, Add-Ins, CAM, Simulation (YIguko4mXRM @ 6:03:20 frame). Recent releases add a "Basic Modeling Tools" tab and a "Simplified Interface" mode shown in the status bar (XdWYW4HOLT4 @ 19:30 frame). While a command runs, commands that cannot start grey out (YIguko4mXRM @ 2:44:10 frame). |
| Left pane (manager tabs) | left column | Row of manager icons at the top: FeatureManager tree, PropertyManager, ConfigurationManager, DimXpertManager, DisplayManager, more via arrows or by widening the pane (YIguko4mXRM @ 4:44:30). The pane can be split in two by dragging the splitter at its top, so the tree and ConfigurationManager show together (YIguko4mXRM @ 4:45:00). |
| FeatureManager design tree | left pane | Root `Part1 (Default<<Default>_Display State 1>)` (active configuration in the name), then History, Sensors, Annotations, Solid Bodies(n), Equations, Material, Front Plane, Top Plane, Right Plane, Origin, then features in build order, then the blue rollback bar (YIguko4mXRM @ 1:43:10 frame). Material node shows the assigned material name, e.g. "AISI 1020" (XdWYW4HOLT4 @ 22:40 frame). |
| PropertyManager (PM) | replaces the tree in the left pane while a command runs | Header: command name, OK (green check), Cancel (red X), and on features a detail-preview eye (YIguko4mXRM @ 2:44:10 frame). Body: collapsible group boxes with chevrons. A yellow message box at the top tells the user what to pick (YIguko4mXRM @ 1:10:10 frame; YIguko4mXRM @ 3:25:00 frame; YIguko4mXRM @ 5:32:30 frame). |
| Flyout FeatureManager | top left of the graphics area, while a PM is open | The tree collapses to a flyout so its items stay pickable during a command (YIguko4mXRM @ 2:44:10 frame). Expanded, it lets the user pick a component's planes for a mate (CWbDrbiepSE @ 55:30 frame; CWbDrbiepSE @ 52:00). |
| Breadcrumbs | top left of graphics | Selecting a face shows its feature and sketch chain (Boss-Extrude2 > Sketch2) (YIguko4mXRM @ 5:47:20 frame). In a sketch, the sketch plane name sits there (YIguko4mXRM @ 0:03:10 frame). |
| Heads-up View toolbar | top centre of graphics, transparent | Zoom to Fit, Zoom to Area, Previous View, Section View, View Orientation, Display Style, Hide/Show Items, Edit Appearance, Apply Scene, View Settings (YIguko4mXRM @ 0:09:20 frame, tooltip "Hide All Types"). Hide/Show Items holds "View Sketch Relations" (YIguko4mXRM @ 0:09:09). Section View is used to check internal pockets (CWbDrbiepSE @ 45:00). Display Style switches shaded with edges, hidden lines removed, hidden lines visible (XdWYW4HOLT4 @ 40:40; XdWYW4HOLT4 @ 48:00 frame). Exact button list order is from the frame tooltips I could read [inferred]. |
| Confirmation corner | top right of graphics | In a sketch: Exit Sketch (arrow over a sketch icon) and a red X that exits without keeping changes (YIguko4mXRM @ 0:03:00; YIguko4mXRM @ 0:03:10 frame). During a feature: green check and red X (YIguko4mXRM @ 2:44:10 frame). During a sketch tool such as Trim: green check only (YIguko4mXRM @ 1:10:10 frame). The narrators never say "confirmation corner"; the name is SolidWorks' official one [inferred]. |
| Task Pane | right column | SOLIDWORKS Resources, Design Library, File Explorer, appearances; vertical icon tabs; collapsible (YIguko4mXRM @ 0:02:30 frame). |
| Reference triad + view label | bottom left of graphics | XYZ triad; under it the current named view, `*Front`, `*Isometric`, `*Trimetric` (YIguko4mXRM @ 2:44:10 frame; XdWYW4HOLT4 @ 22:40 frame). |
| Model tabs | bottom strip, left | Model, 3D Views, Motion Study 1 (YIguko4mXRM @ 0:02:30 frame). |
| Status bar | very bottom | Left: hint for the hovered command or the current pick ("Select a handle to modify parameters", "Pick a sketch entity to define an open or closed contour") (YIguko4mXRM @ 2:44:10 frame; XdWYW4HOLT4 @ 45:30 frame). Right: live measurement of the current selection ("Distance between circular centers: 27.46mm", "Normal Distance", "Area / Perimeter" of a picked region, "Radius / Center") (XdWYW4HOLT4 @ 28:30 frame; XdWYW4HOLT4 @ 32:20 frame; XdWYW4HOLT4 @ 45:30 frame; XdWYW4HOLT4 @ 48:00 frame), cursor X Y Z, sketch state "Under Defined" or "Fully Defined", edit context "Editing Sketch1", "Editing Part", "Editing Assembly", then the unit system (MMGS, IPS) which is a clickable menu (XdWYW4HOLT4 @ 19:00; YIguko4mXRM @ 5:37:50). |

Document behaviour:
- New document: File > New, the New icon, or Ctrl+N, then pick Part, Assembly or Drawing template (YIguko4mXRM @ 0:00:30; YIguko4mXRM @ 5:31:50).
- Multiple documents are windows in one app; Window > Tile, Ctrl+Tab cycles open documents (YIguko4mXRM @ 5:39:50; YIguko4mXRM @ 5:40:00).
- Default planes are hidden; select a plane in the tree and click the eye in the context toolbar to show it (YIguko4mXRM @ 0:01:00).
- Sketches can stay visible in 3D through the same eye on the sketch node (YIguko4mXRM @ 2:40:00).

---

## 2. Command inventory by CommandManager tab

### 2.1 Common command pattern (applies to every tab)

- Four invocation routes for most commands: CommandManager button, Insert or Tools menu, right-click in the graphics area (Sketch Entities or Sketch Tools submenu, or on an edge: Fillet, Chamfer), and the S shortcut bar (YIguko4mXRM @ 0:36:00; YIguko4mXRM @ 1:09:30; YIguko4mXRM @ 3:12:56).
- Pre-selection is honoured: a sketch selected before Extruded Boss is used at once; with nothing selected the PM asks for a sketch, picked in the graphics or the flyout tree (YIguko4mXRM @ 2:43:30).
- Pre-selecting a face then clicking Extruded Cut opens a sketch on that face; exiting the sketch goes straight into the cut PM (XdWYW4HOLT4 @ 38:40).
- Selection boxes in a PM: click a box to make it active (it turns blue), clear it with right-click > Clear Selections, click an item again to remove it (YIguko4mXRM @ 3:33:00; YIguko4mXRM @ 5:47:20; YIguko4mXRM @ 1:24:00).
- Preview is live and editable in the graphics: translucent yellow body, drag arrows for depth, a reverse-direction button in the PM or a click on the arrow (YIguko4mXRM @ 2:44:10 frame; YIguko4mXRM @ 3:33:00).
- Confirm: green check in the PM or the confirmation corner, right-click > OK in the graphics (YIguko4mXRM @ 3:17:00), Enter ("press enter twice": one Enter accepts the value field, the next the feature) (XdWYW4HOLT4 @ 43:50). Cancel: red X or Escape (YIguko4mXRM @ 0:46:59).
- Edit later: click the feature in the tree or a face, a context toolbar offers Edit Feature, Edit Sketch, Edit Sketch Plane, Suppress (YIguko4mXRM @ 2:56:00; YIguko4mXRM @ 2:59:20 frame).

### 2.2 Sketch tab

Buttons left to right (YIguko4mXRM @ 0:03:10 frame; XdWYW4HOLT4 @ 22:40 frame; CWbDrbiepSE @ 35:20 frame):
Exit Sketch, Smart Dimension, Line (with Centerline, Midpoint Line), Corner Rectangle (5 variants), Slot, Circle (and Perimeter Circle), Arc (Centerpoint, Tangent, 3 Point), Polygon, Spline, Ellipse, Sketch Fillet (and Chamfer), Text, Point, Trim Entities, Convert Entities, Offset Entities, Offset On Surface, Mirror Entities, Linear Sketch Pattern, Move Entities, Display/Delete Relations (newer releases show "Add Relation"), Repair Sketch, Quick Snaps, Rapid Sketch, Instant2D, Shaded Sketch Contours, Dynamic Mirror Entities (2017 only).

| Command | PM fields | Selection and behaviour |
|---------|-----------|-------------------------|
| Sketch (start) | none | Click a plane or planar face then Sketch, or Sketch then pick; view rotates normal to the plane (YIguko4mXRM @ 0:02:20; YIguko4mXRM @ 0:05:00). Right-click a plane > Sketch (XdWYW4HOLT4 @ 22:00). |
| Line | Orientation: As sketched, Horizontal, Vertical, Angle; Options: For construction, Infinite length; Parameters: length, angle; Additional Parameters (YIguko4mXRM @ 0:31:40; YIguko4mXRM @ 0:27:10 frame) | Click-click chains segments; Escape ends; preset orientation locks every segment (YIguko4mXRM @ 0:32:00). Moving back onto the last endpoint and out again switches to a tangent arc, then back to line (XdWYW4HOLT4 @ 26:00; CWbDrbiepSE @ 13:00). |
| Rectangle | Rectangle Type (Corner, Center, 3 Point Corner, 3 Point Center, Parallelogram), Add construction lines From Corners / From Midpoints, Parameters (corner coordinates), Center Point (YIguko4mXRM @ 0:37:10 frame) | Type can be switched inside the running command without cancelling (YIguko4mXRM @ 0:37:00). |
| Circle / Arc | Circle Type (center, perimeter), Options: For construction, Add dimensions, Diameter dimensions; Parameters x, y, radius (YIguko4mXRM @ 2:41:20 frame) | Type switch inside the command (YIguko4mXRM @ 0:43:50). Tangent Arc picks the reference by the endpoint you hover first (YIguko4mXRM @ 0:47:00). On a 3-point arc, drag the middle to place the centre (XdWYW4HOLT4 @ 27:00). |
| Trim Entities | Message box with usage; Options: Power trim, Corner, Trim away inside, Trim away outside, Trim to closest; Keep trimmed entities as construction geometry; Ignore trimming of construction geometry (YIguko4mXRM @ 1:11:45 frame) | Power trim: hold the button and drag across segments; drag back over the trail to undo the last trims; Shift + drag extends (YIguko4mXRM @ 1:11:42; YIguko4mXRM @ 1:11:45 frame message text). Inside/outside take two boundaries then a third click (YIguko4mXRM @ 1:10:30). |
| Offset Entities | Distance, Add dimensions, Reverse, Select chain, Bi-directional, Cap ends (Arcs, Lines), Construction geometry: Base geometry, Offset geometry (YIguko4mXRM @ 1:24:30 frame) | Type the distance then click entities, or click and drag; click an entity again to deselect (YIguko4mXRM @ 1:24:00). Status: "Click on either side to complete, or click and drag for dynamic control" (CWbDrbiepSE @ 40:20 frame). Picking a whole face offsets its loop and needs no trim (CWbDrbiepSE @ 40:00). |
| Convert Entities | Entities list | Projects edges onto the sketch plane with relations that keep them linked (YIguko4mXRM @ 1:23:05). Pick edges one by one or a face for all its edges (CWbDrbiepSE @ 35:20; XdWYW4HOLT4 @ 47:30). |
| Smart Dimension | see section 3.3 | |
| Point | none | Used as a construction anchor, e.g. a virtual intersection for a dimension (XdWYW4HOLT4 @ 42:30). |

### 2.3 Features tab

Buttons (YIguko4mXRM @ 1:43:10 frame): Extruded Boss/Base, Revolved Boss/Base, Swept Boss/Base, Lofted Boss/Base, Boundary Boss/Base, Extruded Cut, Hole Wizard, Revolved Cut, Swept Cut, Lofted Cut, Boundary Cut, Fillet (and Chamfer), Linear Pattern (with Circular, Mirror, Curve Driven, Fill), Rib, Draft, Shell, Wrap, Intersect, Mirror, Reference Geometry (Plane, Axis, Point, Coordinate System), Curves, Instant3D, Move Face, Move/Copy Bodies, Delete Face. 2017 adds Thread (CWbDrbiepSE @ 45:10 frame).

| Command | PM fields | Selection, preview, behaviour |
|---------|-----------|-------------------------------|
| Extruded Boss/Base | From: Sketch Plane, Surface/Face/Plane, Vertex, Offset. Direction 1: end condition, reverse button, direction vector, depth, Merge result, Draft outward. Direction 2 checkbox. Thin Feature checkbox. Selected Contours (YIguko4mXRM @ 2:44:10 frame; YIguko4mXRM @ 2:45:30 frame) | Preview with a drag arrow; sketch dimensions stay visible in 3D during the preview (CWbDrbiepSE @ 21:40 frame). Merge result off makes a separate body (YIguko4mXRM @ 2:44:50). Thin Feature extrudes open profiles with a wall (YIguko4mXRM @ 2:46:30). |
| End conditions | Blind, Through All, Mid Plane (distance based); Up To Next, Up To Vertex, Up To Surface, Offset From Surface, Up To Body (geometry based) (YIguko4mXRM @ 2:28:35). Through All - Both for cuts (XdWYW4HOLT4 @ 39:00). | Up To Surface opens a pink face box in the PM, status "Select a face or surface to complete the specification of Direction 1" (XdWYW4HOLT4 @ 48:50 frame). Offset From Surface keeps a wall thickness when the part grows (CWbDrbiepSE @ 41:00). |
| Extruded Cut | as boss plus Flip side to cut (XdWYW4HOLT4 @ 45:30 frame) | One open line is enough: flip side and pick the region to remove (XdWYW4HOLT4 @ 44:40). Selected Contours: click inside a bounded area to pick a region, the status bar shows its area and perimeter (XdWYW4HOLT4 @ 45:30 frame; CWbDrbiepSE @ 44:30). "From: Offset" starts the cut away from the sketch plane (CWbDrbiepSE @ 36:50). |
| Fillet | Manual / FilletXpert tabs; Fillet Type (Constant size, Variable size, Face, Full round); Items To Fillet; Show selection toolbar; Tangent propagation; Full / Partial / No preview; Fillet Parameters (Symmetric, radius, Multi Radius Fillet, Profile Circular); Setback Parameters; Partial Edge Parameters; Fillet Options: Select through faces, Keep features, Round corners, Overflow type (YIguko4mXRM @ 3:13:20 frame; YIguko4mXRM @ 3:14:50 frame) | Hover shows the owning feature in a tooltip (YIguko4mXRM @ 3:14:50 frame). Select through faces picks hidden edges behind a face (YIguko4mXRM @ 3:14:05). Picking an edge pops a selection toolbar (connected to start face, loop, etc.) that previews and adds related edges (YIguko4mXRM @ 3:14:50; YIguko4mXRM @ 3:15:00). A radius callout in the graphics is editable and draggable (YIguko4mXRM @ 3:15:30 frame). |
| Chamfer | Angle Distance, Distance Distance, Vertex, Offset Face, Face Face; tangent propagation, previews, parameters, select through faces, keep features (YIguko4mXRM @ 3:18:00) | Same edge picking as Fillet. |
| Hole Wizard | Two tabs: Type and Positions. Type: Favorite, Hole Type (counterbore, countersink, hole, straight tap, tapered tap, legacy, three slot types), Standard, Type (fastener), Hole Specifications (Size, Fit, Show custom sizing), End Condition, Options (head clearance, near side countersink, under head countersink), Tolerance/Precision (YIguko4mXRM @ 3:23:20 frame; YIguko4mXRM @ 3:23:00) | Positions tab asks for a face, then points on it; a "3D Sketch" button places holes on several faces (YIguko4mXRM @ 3:25:00 frame). Holes made this way are annotated automatically in drawings (YIguko4mXRM @ 3:22:00). |
| Linear Pattern | Direction 1 (vector, Spacing and instances or Up to reference, spacing, count), Direction 2, Pattern seed only, Features and Faces, Bodies, Instances to Skip, Options (Vary sketch, Geometry pattern, Propagate visual properties, Full/Partial preview), Instances to Vary (YIguko4mXRM @ 3:32:20 frame) | Direction accepts any entity that defines a vector: line, axis, linear dimension, model edge (YIguko4mXRM @ 3:31:30). Pick the seed first to get a preview (YIguko4mXRM @ 3:32:00). An in-graphics callout edits spacing and instances (YIguko4mXRM @ 3:32:20 frame). |
| Circular Pattern | axis, angle, instances, equal spacing | Needs an axis; create a reference axis if the model has none (YIguko4mXRM @ 3:48:42). |
| Mirror | mirror face/plane, features, faces or bodies | Mirrors features, faces or whole bodies (YIguko4mXRM @ 3:51:03). |
| Shell | thickness, faces to remove | Faces picked as "faces to remove" become parent references (YIguko4mXRM @ 2:54:00). |
| Reference Plane | first, second, third reference; offset distance, Flip offset, count | Select a face, Features > Reference Geometry > Plane, type the offset, flip if needed (XdWYW4HOLT4 @ 39:40). |
| Curve Driven, Fill Pattern, Sweep, Loft | covered by chapter 2 lessons | (YIguko4mXRM @ 4:09:41; YIguko4mXRM @ 4:17:34; YIguko4mXRM @ 4:23:00) |

### 2.4 Evaluate tab

Part (XdWYW4HOLT4 @ 36:40 frame): Design Study, Interference Detection, Mass Properties, Measure, Markup, Sensor, Section Properties, Import Diagnostics, Performance Evaluation, Geometry Analysis, Body Compare, Check, Draft Analysis, Zebra Stripes, Curvature, Symmetry Check, Undercut Analysis, Parting Line Analysis, Thickness Analysis, Simulation and Xpress wizards, Costing, Sustainability.
Assembly (CWbDrbiepSE @ 58:10 frame): adds Clearance Verification, Hole Alignment, Assembly Visualization, Compare Documents, Check Active Document.

### 2.5 Assembly tab

Edit Component, Insert Components, Mate, Component Preview Window, Linear Component Pattern, Smart Fasteners, Move Component, Show Hidden Components, Assembly Features, Reference Geometry, New Motion Study, Bill of Materials, Exploded View, Instant3D, Update Speedpak, Take Snapshot, Large Assembly Mode (YIguko4mXRM @ 5:38:20 frame).

### 2.6 Other tabs seen

Surfaces, Mold Tools, Direct Editing, Simulation, Analysis Preparation, CAM, Sheet Metal, Structure System, Weldments, MBD Dimensions, Markup (XdWYW4HOLT4 @ 23:40 frame). Not demonstrated.

---

## 3. Sketch system

### 3.1 Entity creation

- Inference lines (dashed) show alignment with existing points; following them adds automatic Horizontal, Vertical, Perpendicular relations (YIguko4mXRM @ 0:29:25; YIguko4mXRM @ 0:30:00). A dotted inference can run across the whole viewport (XdWYW4HOLT4 @ 26:30 frame).
- Watch for unwanted automatic relations: a yellow glyph next to the cursor shows the relation that will be added; it can capture a far-away entity (CWbDrbiepSE @ 13:30). Over-captured relations are the usual reason a sketch refuses to become fully defined (XdWYW4HOLT4 @ 32:40).
- On-the-fly size: type a value while dragging and the entity is sized and dimensioned in one step. Needs Options > Sketch > "Enable on screen numeric input on entity creation" and "Create dimension only when value is entered" (YIguko4mXRM @ 0:45:10; YIguko4mXRM @ 2:41:20).
- Construction geometry: For construction checkbox in the PM, or the toggle in the context toolbar that appears after a selection, or right-click (YIguko4mXRM @ 0:34:00; XdWYW4HOLT4 @ 25:00). Construction lines draw dash-dot and are ignored by features (YIguko4mXRM @ 0:19:00; XdWYW4HOLT4 @ 25:30 frame).
- Shaded Sketch Contours fills every closed region in grey so open profiles are obvious (YIguko4mXRM @ 0:24:45 frame).
- CSWA tactic: draw a construction rectangle sized by the overall variables A and B as a "blocking box", then sketch the outline inside it (XdWYW4HOLT4 @ 18:30; CWbDrbiepSE @ 8:30).
- Sketch rough first, dimension second; drag geometry back into shape when a dimension flips it "inside out" (XdWYW4HOLT4 @ 27:50; CWbDrbiepSE @ 19:00).

### 3.2 Relations

- Relations exist only inside sketch edit (YIguko4mXRM @ 0:07:30).
- Ctrl + click several entities, release Ctrl and keep the mouse still: a context toolbar of valid relations appears next to the cursor. If the mouse moves it disappears, and the same list is always in the PM under Add Relations (YIguko4mXRM @ 0:08:00; YIguko4mXRM @ 0:10:20; XdWYW4HOLT4 @ 28:00).
- The offered list is filtered by the selection types: line + point gives Midpoint, Coincident, Fix (YIguko4mXRM @ 0:08:30 frame); two points give Horizontal, Vertical, Fix, Merge (YIguko4mXRM @ 0:10:20 frame); two arcs give Coradial, Tangent, Concentric, Equal, Fix, Equal Curve Length (XdWYW4HOLT4 @ 28:30 frame); a model edge + point give Midpoint, Coincident, Pierce (CWbDrbiepSE @ 35:20 frame).
- Multi-select PM ("Properties"): Selected Entities list, Existing Relations list, defined-state line with an info icon, Add Relations, Options (For construction) (YIguko4mXRM @ 0:08:30 frame).
- Full set taught: Coincident, Merge, Parallel, Perpendicular, Collinear, Horizontal, Vertical, Equal, Fix (anchor glyph), Midpoint, Symmetric (needs a centreline), Coradial, Concentric, Tangent; advanced Intersection, Pierce, On Surface (YIguko4mXRM @ 0:07:30 to 0:24:00).
- Tangency quick pick: select the shared endpoint plus nothing else, or the two entities, then Tangent (XdWYW4HOLT4 @ 28:00).
- Glyphs: small icons next to entities. Toggle all with Heads-up > Hide/Show Items > View Sketch Relations. Delete: click the glyph and press Delete, or right-click it > Delete (YIguko4mXRM @ 0:09:09).
- Fix is discouraged ("kind of cheating"); an anchor in a CSWA sketch is a warning sign (YIguko4mXRM @ 0:16:00; XdWYW4HOLT4 @ 32:00).
- Near-miss trap: clicking close to a midpoint snaps Midpoint instead of Coincident (XdWYW4HOLT4 @ 28:50).

### 3.3 Smart Dimension

- One tool for every dimension type. Result depends on what is picked and where the mouse is when placing: one line gives its length; two lines give a distance or an angle; moving the mouse switches between aligned, horizontal and vertical (YIguko4mXRM @ 0:24:39; YIguko4mXRM @ 0:25:00).
- Right-click while placing locks the current orientation; right-click again unlocks (YIguko4mXRM @ 0:26:00).
- Angles: the quadrant follows the mouse, from acute to the full outside angle; moving further out makes the acute angle easier to pick (YIguko4mXRM @ 0:26:30; XdWYW4HOLT4 @ 30:30).
- Slanted line: three candidate dimensions (true length, vertical, horizontal); check which one snapped (XdWYW4HOLT4 @ 30:00).
- Circles and arcs: line to circle defaults to the centre; hold Shift to dimension to the tangent edge (YIguko4mXRM @ 0:26:50). Click the circle alone for diameter or radius (YIguko4mXRM @ 0:27:00).
- Edit later: double-click the dimension (YIguko4mXRM @ 0:27:00).
- Modify box: floating dialog with the dimension name (`D1@Sketch1`), the value field with spinner, buttons OK, Cancel, Rebuild, Reverse the sense of the dimension, and a configuration-scope button next to the value (YIguko4mXRM @ 4:48:30 frame; CWbDrbiepSE @ 11:10 frame). Scope: This configuration, All configurations, Specify (YIguko4mXRM @ 4:48:30).
- Equations from the box: type `=` and a menu opens with Global Variables >, Functions >, File Properties > (XdWYW4HOLT4 @ 25:30 frame; XdWYW4HOLT4 @ 25:00). Typing a name in quotes ("B") links it; typing B without quotes only copies the value once and does not stay linked (XdWYW4HOLT4 @ 25:30; CWbDrbiepSE @ 7:50).
- A linked dimension shows a Σ prefix (`Σ 81.00`) (XdWYW4HOLT4 @ 26:30 frame; CWbDrbiepSE @ 13:30 frame). CWbDrbiepSE calls it a "Greek epsilon"; the frames show Σ (CWbDrbiepSE @ 11:00).
- Dimension PM (when a dimension is selected): Value, Leaders, Other tabs; Style; Tolerance/Precision; Primary Value (name, value, Configurations button); Dimension Text (`<DIM>`); Dual Dimension (YIguko4mXRM @ 4:48:30 frame; CWbDrbiepSE @ 11:10 frame).
- Over-defining: if a new dimension would over-constrain, it is created as a driven (reference) dimension instead (XdWYW4HOLT4 @ 45:00). The dialog that offers "make driven" is not shown [inferred].
- Type values even when the shown value looks right; it may be rounded (CWbDrbiepSE @ 16:55).

### 3.4 Defined-state colours and indicators

- Three states: under defined, fully defined, over defined (YIguko4mXRM @ 1:48:57).
- Colour: blue = under defined, can move; black = fully defined, cannot move (YIguko4mXRM @ 1:50:03; YIguko4mXRM @ 1:50:30 frame). Selected entity: orange (YIguko4mXRM @ 0:08:30 frame). Over defined colours (red/yellow) not shown [not in videos].
- Status bar text "Under Defined" or "Fully Defined" (YIguko4mXRM @ 1:49:00; XdWYW4HOLT4 @ 22:40 frame).
- Tree prefix: `(-) Sketch1` while under defined, plain `Sketch1` when fully defined (YIguko4mXRM @ 1:50:30 frame; YIguko4mXRM @ 1:59:10 frame). Assemblies reuse the prefixes on components: `(f)` fixed, `(-)` under defined (YIguko4mXRM @ 6:03:20; YIguko4mXRM @ 5:42:40 frame). `(+)` for over defined [inferred].
- Test by dragging: blue geometry and everything attached to it moves (YIguko4mXRM @ 1:50:30).
- An origin-less sketch can never be fully defined ("everything's in blue") (CWbDrbiepSE @ 9:00).
- Best practice reason: prevents a coworker from moving geometry by accident (YIguko4mXRM @ 1:59:54).

### 3.5 Instant 2D / 3D editing

- Instant2D and Instant3D are toggle buttons on the Sketch and Features tabs (YIguko4mXRM @ 0:03:10 frame; YIguko4mXRM @ 1:43:10 frame). No video demonstrates dragging dimension or face handles with them [not in videos]. General behaviour: Instant2D lets you drag a sketch dimension's arrow to change its value; Instant3D shows drag handles on a selected face or feature to change depth in 3D [inferred].
- What is shown instead: click a face, the feature dimensions appear in the graphics; double-click one to edit it in place without opening the sketch (YIguko4mXRM @ 4:48:00). Right-click Annotations > Show Feature Dimensions shows them all at once (YIguko4mXRM @ 4:59:30).
- During Extrude, the preview arrow is a drag handle for depth (YIguko4mXRM @ 2:44:10).

---

## 4. FeatureManager, configurations, equations

### 4.1 Tree behaviour

- Rollback bar: blue line at the end of the tree. Drag it up to view the model as it was; features below it are suppressed (greyed) and new features insert at the bar (YIguko4mXRM @ 2:52:36; YIguko4mXRM @ 2:52:50 frame). Used to read how a received model was built, one feature at a time (YIguko4mXRM @ 2:53:00).
- Reorder: drag a feature up or down; the tree refuses to drop it above its parents (YIguko4mXRM @ 2:55:11).
- Parent/Child: right-click a feature > Parent/Child opens a two-column dialog Parents | Children (YIguko4mXRM @ 2:55:37; YIguko4mXRM @ 2:55:50 frame). Removing the dependency (edit the feature and unpick the referenced faces) frees the reorder (YIguko4mXRM @ 2:56:00).
- Edit Sketch Plane: moves an existing sketch to a new face; the feature updates (YIguko4mXRM @ 2:59:00; YIguko4mXRM @ 2:59:20 frame).
- Suppress: click a feature, context toolbar > Suppress. Suppressed features are removed from memory and treated as absent (YIguko4mXRM @ 4:43:39; YIguko4mXRM @ 4:52:56). Mates can be suppressed the same way (YIguko4mXRM @ 6:27:35).
- Folders: Equations folder appears once an equation exists; Hide/Show Tree Items can force it always on (YIguko4mXRM @ 1:43:27; YIguko4mXRM @ 1:44:00). Assemblies get a Mates folder and per-component "Mates in Assem1" folders (YIguko4mXRM @ 6:19:00; CWbDrbiepSE @ 55:30 frame). ConfigurationManager has a Tables folder for design tables (YIguko4mXRM @ 6:49:00). Mate PM option "Add to new folder" (YIguko4mXRM @ 5:50:00 frame). User-created feature folders (Add to New Folder on features) not shown [not in videos].
- Delete: right-click > Delete, or Delete key (YIguko4mXRM @ 0:04:20; YIguko4mXRM @ 5:41:00).
- Rename: slow double-click or F2 (YIguko4mXRM @ 4:46:40).
- Rebuild: traffic-light button or Ctrl+B; a stoplight badge next to an edited item means a rebuild is pending (CWbDrbiepSE @ 58:58; CWbDrbiepSE @ 58:30).

### 4.2 Design intent (taught explicitly)

- Choose end conditions that survive changes: Up To Surface or Offset From Surface rather than a computed blind depth, Through All - Both for holes, Mid Plane for symmetry (CWbDrbiepSE @ 33:00; CWbDrbiepSE @ 41:00; XdWYW4HOLT4 @ 39:00; YIguko4mXRM @ 2:30:00).
- Sketch on the face the drawing dimensions from, so offsets need no arithmetic (CWbDrbiepSE @ 34:00).
- Relations over duplicate dimensions: one dimension plus Equal drives many entities (YIguko4mXRM @ 0:17:00).

### 4.3 Configurations

- Several versions of one part in one file: different dimension values, materials, suppression states (YIguko4mXRM @ 4:43:39).
- ConfigurationManager tab: root shows the file and active configuration; each configuration row has the file name in brackets; active one has a green tick and white text; Display States pane at the bottom (YIguko4mXRM @ 4:44:30 frame; YIguko4mXRM @ 4:46:20).
- Add: right-click the root > Add Configuration, PM with name, description, comment (YIguko4mXRM @ 4:45:45).
- Switch: double-click a configuration (YIguko4mXRM @ 4:47:00). Copy and paste with Ctrl+C, Ctrl+V; rename with F2; delete with right-click (YIguko4mXRM @ 4:50:00).
- Per-configuration value: in the Modify box choose "This configuration" before OK (YIguko4mXRM @ 4:48:30).
- Per-configuration suppression: suppress while that configuration is active, or right-click > Configure Feature, which opens a Modify Configurations grid (rows = configurations, column = feature Suppress checkbox, last row "< Creates a new configuration. >") (YIguko4mXRM @ 4:53:21; YIguko4mXRM @ 4:54:20 frame).
- Assembly configurations can suppress or resolve components (YIguko4mXRM @ 6:33:00; YIguko4mXRM @ 6:41:02). Move Component has a "This configuration" option, otherwise moves affect all configurations (YIguko4mXRM @ 6:08:00).

### 4.4 Design tables

- Insert > Tables > Design Table (YIguko4mXRM @ 5:00:21; YIguko4mXRM @ 5:00:40 frame).
- PM: Source Blank, Auto-create, From file (+ Link to file); Edit Control "Allow model edits to update the design table" or "Block model edits that would update the design table"; Options: new parameters, new configurations, warn when updating, enable cell drop-down lists (YIguko4mXRM @ 5:00:40; YIguko4mXRM @ 5:03:00 frame).
- Auto-create asks which dimensions to include (named dimensions help); then an embedded Excel sheet opens in place, the Excel ribbon replacing the CAD UI (YIguko4mXRM @ 5:02:00; YIguko4mXRM @ 5:03:00 frame).
- Add a column by clicking an empty header cell and double-clicking a dimension or feature in the graphics or tree; features enter as `$STATE@Name` (YIguko4mXRM @ 5:04:30). Rows are configurations; leave the sheet to rebuild (YIguko4mXRM @ 5:05:30). Assembly tables accept R and S (capitals) for resolved and suppressed (YIguko4mXRM @ 6:49:55).
- Edit later: ConfigurationManager > Tables > right-click > Edit Table (YIguko4mXRM @ 6:49:00).

### 4.5 Equations and global variables

- Open: Tools > Equations, or right-click the Equations folder > Manage Equations (YIguko4mXRM @ 1:37:30; XdWYW4HOLT4 @ 20:00).
- Dialog "Equations, Global Variables, and Dimensions": four views (Equations, Sketch Equations, Dimensions, Ordered), Filter All Fields search, a grid Name | Value / Equation | Evaluates to | Comments grouped into Global Variables, Features (suppression), Equations; Automatically rebuild, Angular equation units, Automatic solve order, Link to external file; OK, Cancel, Import, Export, Help (YIguko4mXRM @ 1:37:40 frame; YIguko4mXRM @ 1:38:00; YIguko4mXRM @ 1:43:10 frame).
- Spreadsheet keys: Tab moves to the next cell; typing a name auto-wraps it in quotes (XdWYW4HOLT4 @ 20:40; CWbDrbiepSE @ 7:50).
- Automatically rebuild acts as a live preview while typing (YIguko4mXRM @ 1:44:21). Automatic solve order avoids loops (YIguko4mXRM @ 1:38:42).
- Equations reference other dimensions by name: `"D6@Sketch3" = "D1@Sketch3" / 2` (YIguko4mXRM @ 1:37:40 frame). Driving several fillets from one variable: `"D1@Fillet3" = "SM Fillet"` (YIguko4mXRM @ 1:43:10 frame).
- Globals show under the Equations folder in the tree as `"A"=81.00` (XdWYW4HOLT4 @ 22:40 frame).
- Units in values are optional (XdWYW4HOLT4 @ 20:48).

---

## 5. Assemblies

### 5.1 Creating and inserting

- New assembly from template, or File > Make Assembly from Part (YIguko4mXRM @ 5:31:00).
- Begin Assembly PM: message, Create Layout (top-down), Part/Assembly to Insert (open documents list, Browse), Configuration, Thumbnail Preview, Options: Start command when creating new assembly, Automatic browse, Graphics preview, Make virtual, Envelope, Show Rotate context toolbar (YIguko4mXRM @ 5:32:30 frame; YIguko4mXRM @ 5:33:50 frame).
- Placement: the part follows the cursor; a rotate context toolbar (angle + X/Y/Z buttons) sits in the corner; status bar "use Tab or the rotate menu to change its orientation" (YIguko4mXRM @ 5:33:50 frame).
- First component: click the green check without clicking in the graphics and its origin lands on the assembly origin, planes aligned; it is fixed automatically (YIguko4mXRM @ 5:36:30; CWbDrbiepSE @ 48:30). Choose the part that holds everything else as first (CWbDrbiepSE @ 48:20).
- Later components float by default (YIguko4mXRM @ 5:39:21).
- Right-click a component > Float or Fix (YIguko4mXRM @ 5:38:39).
- Insert more: Insert Components (open documents listed), drag files from the OS file browser, or open the part and drag it into the tiled assembly window (YIguko4mXRM @ 5:41:00; YIguko4mXRM @ 5:39:50).
- Copy: hold Ctrl, drag a component, release the mouse, then Ctrl (CWbDrbiepSE @ 50:00). With a mated group selected, Ctrl-drag duplicates the components together with their mates (XdWYW4HOLT4 @ 49:00).
- Units of an assembly are separate from its parts and can change at any time via the status-bar unit menu (YIguko4mXRM @ 5:37:00; CWbDrbiepSE @ 57:00).

### 5.2 Moving components

- Left-drag moves an under-defined component, right-drag rotates it (YIguko4mXRM @ 5:42:00; YIguko4mXRM @ 6:03:20).
- Triad: right-click > Move with Triad. Arrows translate along an axis, plane squares translate in a plane, rings rotate. Right-click the triad for exact Translate XYZ, Translate Delta XYZ, rotation angles, Move to Selection, Align with Selection, align to component or assembly origin (YIguko4mXRM @ 5:43:50 frame; YIguko4mXRM @ 6:04:00; YIguko4mXRM @ 6:05:00).
- Move Component PM: Move (SmartMates, Free Drag, Along Assembly XYZ, Along Entity; By Delta XYZ and To XYZ [inferred]), Rotate, Options (Standard Drag, Collision Detection, Physical Dynamics), Check between All components or These components, Resume Drag, Stop at collision, Dragged part only, Dynamic Clearance with a component list and "Stop at specified clearance", Advanced Options (Highlight faces, Sound, Ignore complex surfaces, This configuration) (YIguko4mXRM @ 6:09:30 frame; YIguko4mXRM @ 6:12:50 frame; YIguko4mXRM @ 5:43:00).
- Dynamic clearance reports the minimum clearance live in the graphics and the PM (0.54 mm in the demo); this is a CSWA question type (YIguko4mXRM @ 6:13:00; YIguko4mXRM @ 6:02:00).

### 5.3 Mates

- Invocation: Assembly tab > Mate (paperclip), Insert > Mate, click a component then Mate in its context toolbar (selection pre-fills), or the S bar (YIguko4mXRM @ 5:47:00; YIguko4mXRM @ 6:16:00; YIguko4mXRM @ 5:47:20 frame).
- PM: Mates / Analysis tabs; Mate Selections box (`Face<1>@Axle-5`, `Face<2>@Wheel-2`) with a multiple-mate mode toggle; Standard Mates; Advanced Mates; Mechanical Mates; Mates list (mates made in this session); Options: Add to new folder, Show popup dialog, Show preview, Use for positioning only, Make first selection transparent (YIguko4mXRM @ 5:50:00 frame; YIguko4mXRM @ 6:17:00; CWbDrbiepSE @ 51:40 frame).
- Selectable entities: faces or surfaces, lines or linear edges, planes, axes or temporary axes, points, vertices, coordinate systems, arcs or circular edges; the selection decides which mate types are offered (YIguko4mXRM @ 6:15:47).
- Auto type: after two picks SolidWorks applies the most likely mate (two cylinders: Concentric) and greys out types that cannot apply (YIguko4mXRM @ 5:49:50; YIguko4mXRM @ 6:18:10 frame).
- Pop-up mate toolbar next to the cursor: mate type buttons, value field for distance or angle, flip alignment, undo selections, green check (YIguko4mXRM @ 6:18:00; CWbDrbiepSE @ 55:30 frame). Typing the angle there is enough; the PM is optional (CWbDrbiepSE @ 56:00).
- The Mate command stays open after each mate; selections clear and the next pair can be picked at once; a final green check closes it (YIguko4mXRM @ 5:50:16; YIguko4mXRM @ 6:18:40).
- Standard mates: Coincident, Parallel, Perpendicular, Tangent, Concentric (with Lock rotation), Lock, Distance, Angle (YIguko4mXRM @ 6:15:00; YIguko4mXRM @ 5:50:00 frame).
- Mate alignment: Aligned / Anti-Aligned buttons, plus Flip dimension for distance and angle. Use them instead of typing 180 minus the angle (YIguko4mXRM @ 6:26:00; CWbDrbiepSE @ 55:00).
- Angle mate: optional Reference entity (plane, planar face, linear edge, axis perpendicular to both faces) with an auto-fill button (YIguko4mXRM @ 6:28:20 frame; YIguko4mXRM @ 6:28:45).
- Advanced and Mechanical mates exist as collapsed group boxes; "you'll probably use [standard] 99% of the time" (YIguko4mXRM @ 5:48:03). CSWA uses standard mates only (CWbDrbiepSE @ 56:00). Their contents (width, path, linear coupler, profile center, symmetric, limit; cam, gear, hinge, rack and pinion, screw, slot, universal joint) are not shown [not in videos].
- Conflicts: contradictory mates (coincident plus a distance between the same faces) raise an error to resolve (YIguko4mXRM @ 5:48:26).
- Editing: Mates folder lists every mate with its two components in brackets; hovering a mate highlights its entities; click > Edit Feature reopens the PM with the stored selections (YIguko4mXRM @ 6:19:10; CWbDrbiepSE @ 58:10 frame; CWbDrbiepSE @ 58:00).
- CSWA tactic: leave the driving angle mates for last, check the remaining degrees of freedom by dragging (CWbDrbiepSE @ 54:00).
- Mate references (pre-defined mating entities stored in a part) are not covered [not in videos].

---

## 6. Input mappings

### 6.1 Mouse

| Input | Action | Source |
|-------|--------|--------|
| Middle drag | rotate view | (YIguko4mXRM @ 0:01:44) |
| Ctrl + middle drag | pan | (YIguko4mXRM @ 0:01:51) |
| Wheel | zoom | (YIguko4mXRM @ 0:01:51) |
| Shift + middle drag | fine zoom | (YIguko4mXRM @ 0:02:00) |
| Left click | select; Ctrl + click adds | (YIguko4mXRM @ 0:08:00) |
| Left drag from left to right | window select (only fully enclosed items) | (YIguko4mXRM @ 0:11:27) |
| Left drag from right to left | crossing select (anything touched) | (YIguko4mXRM @ 0:11:27). XdWYW4HOLT4 says the reverse at one point then corrects itself (XdWYW4HOLT4 @ 24:40); trust the masterclass. |
| Right-click drag | mouse gesture (see 6.3) | (XdWYW4HOLT4 @ 23:00) |
| Right-click (no drag) | context menu; in Smart Dimension it locks orientation; in a feature it offers OK | (YIguko4mXRM @ 0:31:00; YIguko4mXRM @ 0:26:00; YIguko4mXRM @ 3:17:00) |
| Left drag a component | move; right drag rotates | (YIguko4mXRM @ 5:42:00) |
| Hover still after a selection | context toolbar appears; moving away hides it | (YIguko4mXRM @ 0:10:20; XdWYW4HOLT4 @ 25:00) |
| Double-click a dimension | Modify box | (YIguko4mXRM @ 0:27:00) |
| Double-click a configuration | activate it | (YIguko4mXRM @ 4:47:00) |

### 6.2 Keyboard

| Key | Action | Source |
|-----|--------|--------|
| S | shortcut bar at the cursor, context sensitive (sketch tools in a sketch, features in a part, mate in an assembly); recent releases add a "Search All Commands" field: start typing to find any command | (YIguko4mXRM @ 0:32:44; XdWYW4HOLT4 @ 22:27; XdWYW4HOLT4 @ 22:40 frame; YIguko4mXRM @ 6:16:00) |
| L | Line | (XdWYW4HOLT4 @ 27:33) |
| F | zoom to fit | (XdWYW4HOLT4 @ 23:50) |
| Ctrl+7 | isometric view | (YIguko4mXRM @ 0:02:20; XdWYW4HOLT4 @ 34:19) |
| Ctrl+8 | normal to the selected face; again flips to the other side | (XdWYW4HOLT4 @ 34:19; XdWYW4HOLT4 @ 40:30) |
| Space bar | Orientation dialog plus the 3D view selector cage around the model; pick a face of the cage for that view | (XdWYW4HOLT4 @ 34:10; XdWYW4HOLT4 @ 34:14 frame) |
| Arrow keys | rotate the view in fixed steps | (XdWYW4HOLT4 @ 39:40) |
| Ctrl+1 | narrator says "zoom extents"; in standard SolidWorks Ctrl+1 is Front view and F is zoom to fit. Treat as a narrator error | (YIguko4mXRM @ 0:13:12) [inferred correction] |
| Ctrl+N, Ctrl+O | new, open | (YIguko4mXRM @ 0:00:30; YIguko4mXRM @ 5:39:21) |
| Ctrl+Tab | cycle open documents | (YIguko4mXRM @ 5:40:00) |
| Ctrl+Z | undo | (YIguko4mXRM @ 5:38:46) |
| Ctrl+B | rebuild | (CWbDrbiepSE @ 59:04) |
| Ctrl+C / Ctrl+V | copy, paste (configurations too) | (YIguko4mXRM @ 4:50:31) |
| F2 | rename tree item | (YIguko4mXRM @ 4:46:40) |
| Delete | delete selected entity, relation or component | (YIguko4mXRM @ 0:09:09; YIguko4mXRM @ 5:41:00) |
| Escape | end the current tool, close a dialog, clear selection | (YIguko4mXRM @ 0:31:40; YIguko4mXRM @ 0:46:59) |
| Enter | accept the field, then the feature | (XdWYW4HOLT4 @ 43:50) |
| Tab | next cell in the equations grid; rotate the component being placed | (XdWYW4HOLT4 @ 20:42; YIguko4mXRM @ 5:33:50 frame) |
| Shift (while dimensioning) | dimension to the arc or circle edge | (YIguko4mXRM @ 0:26:50) |
| Any key | user-mappable: one presenter maps M to Mass Properties | (CWbDrbiepSE @ 57:00) |

### 6.3 Mouse gestures

- Hold right button and flick in a direction: the command at that sector of an invisible wheel runs. Done fast, no menu is seen (XdWYW4HOLT4 @ 23:00).
- Tools > Customize > Mouse Gestures: enable, choose 2, 3, 4, 8 or 12 gestures, drag any command onto a sector; four separate wheels for Part, Sketch, Assembly, Drawing; Print Gesture Guide (XdWYW4HOLT4 @ 23:20; XdWYW4HOLT4 @ 23:40 frame).
- Used for view orientation too (flick right for the right view) with 8 gestures (CWbDrbiepSE @ 31:52).
- Customize dialog tabs: Toolbars, Shortcut Bars, Commands, Menus, Keyboard, Mouse Gestures (XdWYW4HOLT4 @ 23:40 frame). The shortcut bar contents are customizable per environment (YIguko4mXRM @ 6:16:00).

### 6.4 Context toolbars

- Appear next to the cursor on selection, before the right-click menu: plane show/hide, Sketch on face, Edit Feature, Edit Sketch, Edit Sketch Plane, Suppress, Mate for components (YIguko4mXRM @ 0:01:00; YIguko4mXRM @ 0:05:00; YIguko4mXRM @ 2:59:20 frame; YIguko4mXRM @ 5:47:20 frame).
- Right-click shows the same toolbar above a short menu; the double chevron at the bottom expands the full menu (YIguko4mXRM @ 6:06:00).
- Relation toolbar after a Ctrl multi-select (section 3.2). Construction toggle after a box select (XdWYW4HOLT4 @ 25:00).
- Fillet selection toolbar and radius callout (section 2.3). Mate toolbar (section 5.3). Rotate toolbar while placing a component (section 5.1).

### 6.5 Selection filters

- Not demonstrated in any of the three videos [not in videos]. General SolidWorks: F5 toggles a Selection Filter toolbar (edges, faces, vertices, sketch segments, dimensions, etc.), and selection boxes in a PM filter by themselves (a Direction box accepts only vector-giving entities) [inferred, the second half supported by YIguko4mXRM @ 3:31:30].
- Select Through Faces and Make first selection transparent are the per-command relatives seen on screen (YIguko4mXRM @ 3:14:05; YIguko4mXRM @ 6:18:10 frame).

### 6.6 Instant3D drag handles

- Button seen, behaviour not shown (section 3.5) [not in videos]. The demonstrated equivalents are the extrude preview arrow and the in-graphics callouts (radius for fillet, spacing and instances for linear pattern) (YIguko4mXRM @ 2:44:10; YIguko4mXRM @ 3:15:30 frame; YIguko4mXRM @ 3:32:20 frame).

---

## 7. Drawings and the CSWA measurement workflow

### 7.1 Drawings

- No video builds a drawing; the masterclass defers it ("separate lesson") (YIguko4mXRM @ 3:29:43) [not in videos].
- CSWA "drafting competency" questions only ask for view types from images: crop view (spline on a view), broken-out section, alternate position view (XdWYW4HOLT4 @ 15:50; XdWYW4HOLT4 @ 16:30; CWbDrbiepSE @ 6:00).
- Suggested prep: Help > Tutorials on drawings; in the exam, open a scratch drawing to compare view types (XdWYW4HOLT4 @ 16:53; CWbDrbiepSE @ 4:59).
- Hooks from the part side: Hole Wizard holes auto-annotate in drawings (YIguko4mXRM @ 3:22:00); the Modify box carries a mark-for-drawing button (YIguko4mXRM @ 4:48:30 frame) [inferred from the icon].
- The Mouse Gesture setup has a dedicated Drawing wheel (XdWYW4HOLT4 @ 23:40 frame).

### 7.2 Exam setup ritual (both CSWA videos agree)

1. Units first: click MMGS in the status bar or Options > Document Properties > Units (XdWYW4HOLT4 @ 13:20; CWbDrbiepSE @ 3:15).
2. Material: right-click Material in the tree > Edit Material, pick from the SOLIDWORKS Materials library, compare Mass Density with the exam's density (7900 kg/m^3 = 0.0079 g/mm^3 for AISI 1020; "cold rolled" is 7870 and gives a wrong mass) (XdWYW4HOLT4 @ 19:23; XdWYW4HOLT4 @ 20:00 frame; CWbDrbiepSE @ 22:17). Material dialog: library tree with search, tabs Properties, Appearance, CrossHatch, Custom, Application Data, Favorites, Sheet Metal; property table; Apply, Close, Config (XdWYW4HOLT4 @ 20:00 frame).
3. Global variables A, B, C in Equations before sketching (XdWYW4HOLT4 @ 14:06; CWbDrbiepSE @ 3:51).
4. Origin: place it where the drawing says, else where it is logical (centre of the main hole); it matters for centre of mass (XdWYW4HOLT4 @ 14:29; CWbDrbiepSE @ 9:00).
5. Save; then Save As a new file per question so earlier answers can be revisited (XdWYW4HOLT4 @ 21:30; CWbDrbiepSE @ 28:00).

### 7.3 Mass Properties

- Evaluate > Mass Properties (XdWYW4HOLT4 @ 35:43; CWbDrbiepSE @ 23:32).
- Dialog: selection box (whole part or assembly by default), Options, Override Mass Properties, Recalculate, Include hidden bodies/components, Create Center of Mass feature, Show weld bead mass, "Report coordinate values relative to" (default or a coordinate system), then a text report: density, mass, volume, surface area, centre of mass X Y Z, principal axes and moments, moments of inertia at centre of mass and at output coordinate system; Help, Print, Copy to Clipboard (XdWYW4HOLT4 @ 35:50 frame; CWbDrbiepSE @ 23:35 frame).
- Values can be copied from the report into the exam client (CWbDrbiepSE @ 25:00).
- Units trap: an assembly left in IPS gave a centre of mass about 25 times off; switch the assembly to MMGS at any time and the report updates (CWbDrbiepSE @ 57:00; CWbDrbiepSE @ 57:15 frame).
- Modify loop: change globals in Manage Equations, Rebuild (Ctrl+B), re-run Mass Properties (XdWYW4HOLT4 @ 36:00; CWbDrbiepSE @ 26:30).
- Changing assembly angles: right-click each angle mate in the Mates folder > Edit Feature, type the new value, Rebuild if nothing moves (CWbDrbiepSE @ 58:00).
- Get the first answer exact before moving on: later questions are scored against your own earlier geometry, so partial credit depends on it (XdWYW4HOLT4 @ 34:30).
- Visual checks before answering: Section View against the exam section drawing (CWbDrbiepSE @ 45:00); Measure and the status-bar readout for distances (XdWYW4HOLT4 @ 32:20 frame).

---

## 8. Better than Fusion: behaviours worth adopting

Each item names the SolidWorks behaviour, then why it would help a Fusion-style ViaForm (`docs/ui-reference.md`: S is a toolbox search, right-click is an 8-command marking menu, the dialog floats on the right, the timeline is a bottom strip).

1. **Context-filtered relation toolbar on Ctrl multi-select** (YIguko4mXRM @ 0:10:20; XdWYW4HOLT4 @ 28:30 frame). Why: the user picks geometry first and sees only the constraints that apply, in place, with no trip to a toolbar. Fusion makes you pick the constraint first.
2. **S shortcut bar = contextual palette plus search** (XdWYW4HOLT4 @ 22:27). Why: ViaForm's S is search only; showing the 12 to 16 most likely tools for the current mode at the cursor, with the search field under them, serves both the mouse user and the typist with one key.
3. **Directional mouse gestures with per-mode wheels, no visible menu when flicked fast** (XdWYW4HOLT4 @ 23:00; XdWYW4HOLT4 @ 23:40 frame). Why: same muscle memory as a marking menu, but a quick flick fires without waiting for the menu to draw; separate wheels for sketch, part, assembly, drawing keep each wheel relevant.
4. **Variables typed straight into any dimension field with `=`, a menu of globals and functions, and a visible Σ marker on linked values** (XdWYW4HOLT4 @ 25:30 frame; XdWYW4HOLT4 @ 26:30 frame). Why: the parameters table stays optional; the link is visible on the canvas. Keep the "quotes link, bare name copies" rule out of ViaForm: always link and offer "unlink" explicitly, since CWbDrbiepSE @ 7:50 shows how easy the silent copy is to get wrong.
5. **Defined-state everywhere: entity colour, status-bar text, `(-)` prefix in the tree, `(f)`/`(-)` on assembly components** (YIguko4mXRM @ 1:50:30 frame; YIguko4mXRM @ 5:42:40 frame). Why: under-constrained work is visible from the tree without opening anything, which is what both CSWA presenters check before every feature.
6. **Live measurement of the current selection in the status bar** (XdWYW4HOLT4 @ 28:30 frame; XdWYW4HOLT4 @ 45:30 frame). Why: distance, radius, area and perimeter for free on every pick, no Measure command needed for quick checks.
7. **Pre-select face, then cut: the sketch opens on it and exiting the sketch lands in the cut** (XdWYW4HOLT4 @ 38:40). Why: one action chain instead of sketch, finish, pick sketch, cut.
8. **Region picking for extrudes with area and perimeter feedback, and cutting from a single open line with "flip side"** (XdWYW4HOLT4 @ 44:40; XdWYW4HOLT4 @ 45:30 frame). Why: messy sketches stay usable; no trim pass needed before a feature.
9. **Commands that stay open (Mate) and in-canvas pop-up toolbars with the value field** (YIguko4mXRM @ 5:50:16; CWbDrbiepSE @ 55:30 frame). Why: batch work (twenty mates in the chain link) without re-invoking; the eye stays on the model.
10. **Auto-suggested mate type from the picked pair, with impossible types greyed** (YIguko4mXRM @ 5:49:50; YIguko4mXRM @ 6:18:10 frame). Why: most mates become two clicks plus Enter; Fusion joints need the joint type and snap points chosen up front.
11. **Ctrl-drag copies a mated group with its mates** (XdWYW4HOLT4 @ 49:00). Why: repeated sub-patterns (chains, hinges) build in seconds.
12. **Collision detection and dynamic clearance inside the move tool** (YIguko4mXRM @ 6:12:50 frame; YIguko4mXRM @ 6:13:00). Why: check a mechanism by dragging it, get the minimum gap as a number; no separate analysis step.
13. **Configurations with per-value scope in the Modify box, a Configure Feature grid, and design tables** (YIguko4mXRM @ 4:48:30; YIguko4mXRM @ 4:54:20 frame; YIguko4mXRM @ 5:03:00 frame). Why: part families (sizes, with and without holes) in one file. ViaForm could back the table with its own grid instead of Excel.
14. **Parent/Child dialog and reorder that refuses illegal moves** (YIguko4mXRM @ 2:55:11; YIguko4mXRM @ 2:55:50 frame). Why: users learn why a reorder fails instead of getting a broken rebuild.
15. **Edit Sketch Plane** (YIguko4mXRM @ 2:59:00). Why: move a feature to another face without redrawing; Fusion's equivalent (redefine) is buried.
16. **Flyout feature tree over the canvas while a command runs** (YIguko4mXRM @ 2:44:10 frame; CWbDrbiepSE @ 55:30 frame). Why: origin planes and earlier sketches stay pickable even when the side panel shows the command form.
17. **Tangent arc by returning to the last endpoint inside the Line tool** (XdWYW4HOLT4 @ 26:00). Why: line-arc-line profiles without switching tools.
18. **Window (left to right) vs crossing (right to left) box selection** (YIguko4mXRM @ 0:11:27). Why: precise bulk selection in dense sketches with no modifier key.
19. **Fillet edge-selection toolbar (loop, connected edges, features) and an editable radius callout** (YIguko4mXRM @ 3:14:50; YIguko4mXRM @ 3:15:30 frame). Why: chains of edges in one click, value edited where the user is looking.
20. **Confirmation corner plus right-click OK plus Enter** (YIguko4mXRM @ 0:03:00; YIguko4mXRM @ 3:17:00; XdWYW4HOLT4 @ 43:50). Why: three ways to commit, each near where the hand or eye already is; the red X in a sketch makes "discard sketch edits" explicit, which Fusion lacks.
21. **Mass Properties report with a "relative to" coordinate system and Copy to Clipboard** (XdWYW4HOLT4 @ 35:50 frame). Why: engineering answers (mass, centre of mass, inertia) in one copyable block, with the reference frame stated.

Things not to copy: the Fix relation as a quick way out (YIguko4mXRM @ 0:16:00), Excel-only design tables (YIguko4mXRM @ 5:03:00 frame), the silent value copy when a variable lacks quotes (CWbDrbiepSE @ 7:50), and a rebuild that sometimes needs a manual Ctrl+B to show changes (CWbDrbiepSE @ 58:30).
