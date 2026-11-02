# UI reference sheet

ViaForm matches the layout, workflows and input mappings of two well known CAD apps.
It does not copy their assets: icons are SF Symbols or our own drawings, and colors,
type, logo and names are ours. Public help pages were used as reference only.

Sources:
- Autodesk help, "Fusion interface (desktop)"
- Shapr3D support articles and "Refreshing the Shapr3D User Interface" (May 2023)

## Desktop (macOS): Fusion-style layout

| Zone | Position | Behavior |
|------|----------|----------|
| Application bar | top strip | data panel toggle, file menu, save, undo and redo, design tabs, new design tab, then jobs, notifications, help and profile on the right |
| Toolbar | under the app bar | workspace menu on the left, then tabs (Solid, Surface, Sheet, Tools...), panels with a big first button and a dropdown arrow; sketch mode adds a contextual tab and a Finish Sketch button |
| Data panel | slides in from the left | projects and recent files, thumbnails |
| Browser | floating, top left of canvas | tree: document settings, named views, origin, bodies, sketches; eye toggles per node |
| ViewCube | top right of canvas | faces give standard views, edges and corners give iso views, drag orbits, home button |
| Navigation bar | bottom center | orbit, look at, pan, zoom, fit, display settings, grid |
| Timeline | bottom strip | feature icons in order, drag the marker to roll back, right-click to edit or suppress, drag icons to reorder |
| Marking menu | right-click on canvas | wheel of 8 commands around the cursor plus an overflow list |
| Command dialog | floating, right of canvas | inputs, OK and Cancel; live preview in canvas |
| Toolbox search | S key | search all commands by name |

Mouse: middle drag pans, shift + middle drag orbits, wheel zooms at cursor, double middle fits.
Keys: S search, L line, R rectangle, C circle, E extrude, Q press pull, F fillet, Delete, Esc.

## Touch (iPad and iPhone): Shapr3D-style layout

| Zone | Position | Behavior |
|------|----------|----------|
| Top bar | top center | project sidebar toggle, items manager toggle, history toggle, undo and redo, section view, isolate, export |
| Project sidebar | left | spaces: Modeling, Visualization, 2D Drawings; design list |
| Items manager | right | bodies, sketches, planes; show, hide, lock, group |
| History sidebar | right | parametric feature list with edit in place |
| Tool panel | left edge column | sketch tools, then solid tools; opens a sub panel per group |
| Adaptive suggestions | near the selection | tools that fit the current selection (face gives extrude, offset, sketch on face; edge gives fillet, chamfer) |
| Value entry | next to the drag handle | tap the number to type a value with arithmetic |
| View cube | top right | tap face for standard view |

Gestures: one finger orbits, two fingers pan, pinch zooms, Pencil draws and selects, tap selects,
double tap selects the whole body, two finger tap undoes.

## iPhone

Same zones folded: sidebars become sheets, the tool panel becomes a bottom bar,
suggestions show as a single row above it.
