"""Spec mockups for ViaForm, made with Azure gpt-image-2.5-flare (images/generations).

These are target-state concept screens for docs/specs/VIAFORM-SPEC.md. They cover the screens
that the v2 design round did not draw: Mechanics, Training (local and cloud), Render, Manufacture,
Parts and BOM, Robot, the design agent, the cloud run sheet, project start and iPad Robot.

usage: python3 gen.py [screen ...]        # default: every screen in SCREENS
       -> <screen>.png next to this file (an existing file is moved to <name>.try<k>.png first)
Serialised with the shared lock /tmp/viaform-azure.lock (other agents use the same deployment).
The key is read from the Azure CLI at run time and never written to disk.
"""
import base64, json, os, pathlib, subprocess, sys, time, urllib.error, urllib.request

HERE = pathlib.Path(__file__).resolve().parent
EP = ("https://temple-ai-provider.cognitiveservices.azure.com/openai/deployments/gpt-image-2.5-flare/"
      "images/generations?api-version=2025-04-01-preview")
LOCK = "/tmp/viaform-azure.lock"

CHROME = (
    "A crisp, pixel-perfect, realistic screenshot of a professional native macOS desktop engineering application "
    "called ViaForm, shown full frame as one macOS window (red, yellow, green traffic light buttons top left, no "
    "wallpaper, no device frame, flat straight-on screenshot, not a photo of a screen). Light theme: white and very "
    "light grey chrome, hairline grey separators, SF Pro system font, small dense but legible English labels, one "
    "blue accent #2F6BFF. Layout: (a) a slim unified window toolbar: sidebar toggle, a grid button, undo and redo, "
    "the project title in bold with a grey subtitle under it, an empty centre (no row of stage chips, no pipeline "
    "bar, no tabs in the toolbar), and on the right a search icon, a small graph icon, a history icon, a jobs icon, "
    "a library icon and an inspector toggle; (b) a left sidebar titled BROWSER with a collapsible tree (chevrons, "
    "small line icons, eye toggles) and at its bottom a section PIPELINE OUTPUTS listing rows like 'Model v12  Up "
    "to date' with green, orange or hollow dots; (c) under the toolbar a ribbon. At the FAR LEFT of the ribbon a "
    "single large WORKSPACE SWITCHER button, about 90 px wide and as tall as the ribbon, framed with a thin border: "
    "a big icon of the active workspace on top, the workspace name in capitals under it, and a small dropdown "
    "chevron; a small orange circle badge with the number 2 on its top right corner. To the right of that button "
    "a row of all-caps tab labels with the active tab underlined in blue, then a strip of grouped square tool "
    "buttons with all-caps captions and small blue chevrons; (d) a large central canvas; (e) a right INSPECTOR "
    "column with all-caps "
    "section headers (SELECTION, FLOW, and workspace sections) and key value rows; (f) a thin status bar at the "
    "bottom with a green dot and short status text. All text must be real readable English words, spelled "
    "correctly, short, no lorem ipsum. Absolutely no third party product names or logos: no Autodesk, no Fusion, "
    "no Shapr3D, no Apple logo, no Microsoft or Azure logo, no watermark. The only product name is ViaForm. "
)

AG = "IMPORTANT LAYOUT for this screen: to the LEFT of the BROWSER sidebar an extra first column titled AGENTS, about 260 px wide, with one row selected: a round avatar with a purple ring, title 'First part tour', state line '{state}', and a small chip 'Starter credits 4.60 left'. The canvas has a slim purple banner at the top reading 'Tour guide is driving . Take over'. Inspector tabs Properties, Agent (active), Comments; the Agent tab shows a PLAN of six numbered steps: 1 Meet your arm, 2 Mark the finger, 3 Generate shapes, 4 Pick one, 5 Test the grip, 6 Export to print, with green checks up to step {done}, a spinner on step {cur}, and below a THREAD of short friendly chat bubbles from the guide. "
GD = "IMPORTANT LAYOUT for this screen: to the LEFT of the BROWSER sidebar an extra first column titled AGENTS, about 260 px wide, with one selected row: a round avatar with a purple ring, title '{title}', state line '{state}', chip 'Starter credits 4.70 left'. A slim purple banner at the top of the canvas reads 'Tour guide is driving . Take over'. Inspector tabs Properties, Agent (active), Comments; the Agent tab shows a PLAN of numbered steps {steps} with green checks before the current step and a spinner on the current step, and a THREAD of short friendly chat bubbles from the guide plus a field 'Ask the guide anything'. "

BASE = "A crisp, pixel-perfect, ultra premium screenshot of a native macOS 26 professional CAD application called ViaForm, at the polish level of Apple's own pro apps: one window, traffic lights, no wallpaper, no device frame, flat straight-on, retina sharp. macOS 26 Liquid Glass design: toolbars and side panels are translucent frosted glass with soft refraction and a subtle specular rim, floating with rounded 16 px corners and a gentle drop shadow over the 3D viewport, which continues underneath them. Typography: SF Pro with tight tracking, clear hierarchy, small caps section labels in secondary grey, tabular numbers. Icons: thin consistent line icons like SF Symbols light weight. Viewport: a studio quality engineering render, soft neutral grey to off-white gradient background, soft contact shadow, ambient occlusion, crisp dark grey silhouette and feature edges, bead blasted aluminium material with subtle reflections. Content: the Design workspace of project 'Wall bracket': an L shaped aluminium bracket with two countersunk holes, a 4 mm fillet on the inner bend highlighted with a thin glowing accent line, precise engineering dimension annotations '60', '40', 'R4', 'Ø6.5' with thin leader lines, a small orthographic view cube with soft glass faces. Colours: neutral greys, one refined accent. All text real English, spelled correctly. No third party product names or logos, only the name ViaForm. "

SCREENS = {
    "01-mechanics": CHROME + (
        "This screen: the Assemble workspace; switcher button reads ASSEMBLE with a gears icon. Project title: Desk Arm, subtitle Assemble . "
        "Assembly v4. Ribbon tabs: JOINTS (active), MOTION, CONTACT, MASS. Browser tree: Desk Arm, Base, Shoulder, "
        "Upper Arm, Forearm, Wrist, Gripper, Joints (6), Motors (6), Rigid Groups. Canvas: a light grey gradient "
        "with a faint grid floor and a realistic 6 axis desktop robot arm made of white 3D printed parts and small "
        "black servo motors at each joint; the elbow joint is selected, shown with a blue rotation arc and a value "
        "badge reading 72 deg, and a faint ghost of the arm at the joint limit. Bottom panel MOTION STUDY: a "
        "timeline with six coloured joint angle curves (J1 to J6) over 4 seconds and a vertical playhead. Inspector: "
        "SELECTION Elbow joint, revolute; LIMITS -10 to 135 deg; MOTOR STS3215 servo, 30 kg.cm, 12 V; MASS "
        "PROPERTIES total 1.42 kg, centre of mass x 12 y 0 z 188 mm; FLOW consumes Model v12, produces Assembly v4 "
        "for Simulate. Status bar: Assembly v4 . 6 joints . no interference."
    ),
    "02-training-cloud": CHROME + (
        "This screen: the Train workspace; switcher button reads TRAIN with a brain icon. Project title: Desk "
        "Arm, subtitle Train . Policy v5. Ribbon tabs: TASKS (active), RUNS, EVALUATE, EXPORT. Browser tree: Tasks "
        "(Reach point, Pick cube), Runs (Run 14 cloud, Run 13 local, Run 12 local), Datasets (Demos 40), Policies "
        "(Policy v4, Policy v5). Canvas split in two: on the left a 3D view of the white desk robot arm reaching a "
        "small red cube on a table, with five faint translucent ghost arms behind it showing parallel simulated "
        "episodes; on the right a clean chart panel with a rising reward curve (blue) and a success rate curve "
        "(green) over 2.4 million steps, light grid, axis labels. Above the charts a small capsule: Run 14 . Cloud "
        "GPU . 61% . 18 min left . Pause. Inspector: RUN Run 14, Cloud, 1 x A100 GPU, 2048 parallel envs; SEED 7; "
        "ALGORITHM PPO after imitation; COST so far 4.10 USD of 15.00 USD cap, a thin progress bar; ARTIFACTS "
        "checkpoints 6, logs streaming; FLOW consumes Assembly v4 and Scenario Reach, produces Policy v6. Status bar: "
        "Run 14 streaming metrics . last update 3 s ago."
    ),
    "03-render": CHROME + (
        "This screen: the Render workspace; switcher reads RENDER. Project title: Racer 3in, subtitle Render . Frame "
        "v12. Ribbon tabs: SCENE (active), LIGHT, MATERIAL, CAMERA, QUEUE. Browser tree: Scene, Environment Studio "
        "Soft, Cameras (Hero, Top, Detail), Materials (Carbon, Anodised red, Rubber). Canvas: a beautiful "
        "photoreal studio render of a small 3 inch FPV racing drone with a dark carbon generative frame, red "
        "anodised motors and grey propellers on a soft white seamless background with gentle reflection; a thin "
        "progress line at the bottom of the canvas reading 412 of 512 samples. Bottom panel RENDER QUEUE: three "
        "thumbnail rows, Hero 3840 x 2160 done, Top in progress, Detail queued. Inspector: CAMERA Hero, 50 mm, "
        "f 4; OUTPUT 3840 x 2160 PNG; SAMPLES 512; DENOISE on; FLOW consumes Assembly v4, produces Renders 3."
    ),
    "04-manufacture": CHROME + (
        "This screen: the Make workspace; switcher reads MAKE. Project title: Racer 3in, subtitle Make . Bundle rev C. "
        "Ribbon tabs: PACKAGE (active), PRINT, BOARD, CHECKS. Browser tree: Bundle rev C, Printed parts (4), "
        "Board files, BOM, Assembly guide. Canvas: a clean grid of export cards, each with a small preview thumbnail "
        "and a green check: Frame.step, Frame.3mf, Canopy.3mf, Gerbers.zip, flight-controller.kicad_pcb, "
        "bom.csv, assembly-guide.pdf; one card Canopy.3mf shows an orange warning 'overhang 62 deg, add support'. "
        "Below the cards a CHECKS list: Printability passed with warning, DRC passed, ERC passed, BOM priced 41 "
        "of 42 lines, Revisions consistent. Inspector: BUNDLE rev C, 7 files, 18.4 MB; SOURCE REVISIONS Frame v12, "
        "Board rev C, Assembly v4; ACTIONS a blue button Export bundle and a grey button Reveal in Finder. Status "
        "bar: 1 warning . nothing ordered automatically."
    ),
    "05-parts-bom": CHROME + (
        "This screen: the Libraries and BOM panel open as a wide sheet over the Assemble workspace. Project title: "
        "Desk Arm, subtitle BOM . Assembly v4. The sheet has a search field reading 'servo 30 kg.cm 12V' and source "
        "filter pills: KiCad, Standard hardware, DigiKey, Mouser, Nexar, By hand. Left half: search results as rows "
        "with a small part image, manufacturer part number, key specs, a source tag and a price. Right half: a BILL "
        "OF MATERIALS table with columns Part, Qty, Source, Unit price, Stock, Lead time, Link; rows include STS3215 "
        "servo x6, M3x12 screw x48, 608 bearing x4, Driver board x1, 12 V 5 A supply x1; prices in USD, stock "
        "numbers, a few green and one orange stock badge. At the bottom a total line 'Estimated 214.60 USD . prices "
        "refreshed 2 min ago' and two buttons: Export CSV (blue) and Open supplier carts (grey), with a small note "
        "'ViaForm never places orders'."
    ),
    "06-robot": CHROME + (
        "This screen: the Robot workspace; switcher button reads ROBOT with a robot arm icon. "
        "Project title: Desk Arm, subtitle Robot . connected over USB. Ribbon tabs: CONNECT, TELEOP (active), "
        "RECORD, DEPLOY. Browser tree: Device Desk Arm 01, Firmware 1.4.2, Joints (6) each with a live angle, "
        "Recordings (40 demos). Canvas split: left a live 3D twin of the white desk robot arm, with a semi "
        "transparent blue ghost showing the commanded pose slightly ahead of the solid measured pose; right a "
        "small live camera feed of the real arm on a wooden desk. Bottom panel: six live telemetry sparklines (joint "
        "position, current, temperature) with values, and a red REC button with 'Demo 41 . 00:12'. Inspector: "
        "DEVICE connected, latency 4 ms; SAFETY a large red Stop button, torque limit 60 percent, workspace fence "
        "on; POLICY Policy v5 ready, a grey button Run on robot with a lock icon and the note 'requires confirm'. "
        "Status bar: Robot connected . e-stop armed."
    ),
    "07-agent": CHROME + (
        "This screen: the Design workspace (switcher reads DESIGN) with the ViaForm design agent open as a floating command panel in the "
        "upper middle of the canvas, like a spotlight style palette with rounded corners and a soft shadow. Project "
        "title: Desk Arm, subtitle Design . Model v12. The panel input reads: 'Make the forearm 20 percent lighter, "
        "keep the servo mounts'. Under it a PLAN list with numbered steps and status icons: 1 Read Forearm body and "
        "mounts (done, green check), 2 Create generative study with preserve regions (done), 3 Run study on cloud, "
        "24 outcomes (running, spinner, 'est. 0.40 USD'), 4 Compare mass and stress (pending), 5 Propose Forearm "
        "v13 for your review (pending). At the bottom of the panel two buttons: Approve and continue (blue) and "
        "Stop (grey), and a small line 'Agent edits are undoable . nothing is bought or sent'. Behind the panel the "
        "canvas shows the white robot arm forearm with blue preserve regions at the two servo mounts and a "
        "translucent design space volume."
    ),
    "08-cloud-run-sheet": CHROME + (
        "This screen: a macOS modal sheet titled 'Run in the cloud' sliding down over the Train workspace, which is "
        "dimmed behind it. Project title: Desk Arm. The sheet has clear form rows: Job: Train Policy v6 on task Pick "
        "cube; Compute: a segmented control with Local Mac, Cloud CPU, Cloud GPU (selected); GPU: a popup reading '1 "
        "x A100 80 GB'; Parallel environments: 2048; Max duration: 2 h; Spending cap: 15.00 USD with a small note "
        "'run stops at the cap'; Estimated cost: 6.20 to 9.80 USD; Data sent: Assembly v4 snapshot 3.1 MB, Scenario "
        "Pick cube, Demos 40 (128 MB); Region: East US 2; a checkbox 'Delete uploaded data 7 days after run'. At "
        "the bottom right a grey Cancel and a blue Start run button."
    ),
    "09-project-start": CHROME.split("Layout:")[0] + (
        "This screen: the ViaForm start window, no toolbar ribbon. Left column: Recent projects with small "
        "thumbnails (Racer 3in, Humanoid Hand, Desk Arm) and an Open button. Right area titled 'Start a project' "
        "with a grid of large template cards, each with a clean rendered thumbnail: Blank part, Desk robot arm (6 "
        "axis, servos), FPV drone 3 inch, Robotic hand, Electronics board, Import STEP or KiCad. Under the cards a "
        "single wide text field with a sparkle icon: 'Describe what you want to build' and placeholder text 'a "
        "two finger gripper for a 30 kg.cm servo'. Bottom bar: Sign in to sync (optional), and a small gear "
        "for settings. Calm, spacious, Apple-like. No third party logos."
    ),
    "10-ipad-robot": (
        "A crisp, pixel-perfect, realistic screenshot of an iPad Pro app in landscape called ViaForm, light theme, "
        "flat straight-on, no device frame. Full screen 3D viewport with a light grey gradient and a white desk "
        "robot arm. Top: a floating rounded capsule with a menu button, title 'Desk Arm . Robot', undo and redo, "
        "and at its far left a rounded workspace button: robot arm icon, the word Robot, a down chevron, a small orange badge 2; no strip of stage icons. Left: a column of "
        "large labelled tool buttons: Connect, Teleop, Record, Replay. Right: a floating 320 point white card "
        "titled JOINTS with six sliders J1 to J6 and live values, and below it a big red STOP button. Bottom: a "
        "transport capsule with a red record dot, 'Demo 12 . 00:08', play and stop. All text real readable English, "
        "no third party names or logos, the only product name is ViaForm."
    ),
    "11-workspace-dropdown": CHROME + (
        "This screen: the Assemble workspace with the WORKSPACE SWITCHER DROPDOWN OPEN. Project title: Desk Arm, "
        "subtitle Assemble . Assembly v4. Directly under the switcher button at the far left of the ribbon hangs a "
        "white menu with a soft shadow and rounded corners, about 360 px wide, listing nine rows in this order, each "
        "row with an icon, a name, a grey revision, a status dot and a grey shortcut on the right: Design, Model v12, "
        "green dot, Cmd 1; Generate, Frame v12, green dot, Cmd 2; Assemble, Assembly v4, highlighted row with a blue "
        "background and white text, Cmd 3; Electronics, Board rev C, green dot, Cmd 4; Simulate, Reach v2, orange "
        "dot, and a second grey line 'Assembly v4 replaced v3', Cmd 5; Train, Policy v5, orange dot, second line "
        "'Waiting on Simulate', Cmd 6; Render, Renders 3, green dot, Cmd 7; Make, not built, hollow dot, Cmd 8; "
        "Robot, Session 12, green dot, Cmd 9. A thin separator, then two footer rows: 'Update all stale' with "
        "'Shift Cmd U' and 'Show flow graph'. Behind the menu the canvas shows the white 6 axis desk robot arm "
        "assembly on a light grid."
    ),
    "12-generate-setup": CHROME + (
        "This screen: the Generate workspace; switcher button reads GENERATE with a sparkle icon. Project title: "
        "Desk Arm, subtitle Generate . Forearm study 3. Ribbon tabs: DEFINE, LOADS, MAKE (active), RUN, EXPLORE. "
        "Canvas: a translucent light blue box design space around a robot forearm area, two blue solid preserve "
        "cylinders at each end (servo mounts), a red hatched obstacle cylinder in the middle, three orange load "
        "arrows with labels 18 N, 25 N, 4 N.m, small anchor glyphs at one end, and a large green arrow labelled "
        "BUILD pointing up. Inspector titled STUDY with collapsible rows each with a small green check or orange "
        "warning: Design space 1.02M voxels; Preserve 2; Obstacles 1; Supports 1; Load cases 3; Objective Lightest "
        "for limits; Limits safety factor 1.5; PROCESS expanded with a picker reading FDM printing, a slider "
        "Overhang angle 45 deg, Build direction +Z, Min wall 1.2 mm; Material PETG; Variants 6. At the bottom of "
        "the inspector a blue Run button and grey text 'about 2 min on this Mac . 2.4 GB'."
    ),
    "13-generate-outcomes": CHROME + (
        "This screen: the Generate workspace, EXPLORE tab active; switcher reads GENERATE. Project title: Desk Arm, "
        "subtitle Generate . Forearm study 3. Canvas: a smooth organic generative robot forearm part with branching "
        "struts between two round servo mounts, coloured with a stress colour map blue to red with a small vertical "
        "legend 0 to 32 MPa. Bottom panel split: left a horizontal row of six outcome thumbnails with mass labels "
        "(48 g, 52 g, 57 g, 61 g, 66 g, 72 g), the third highlighted; right a scatter chart titled PARETO with mass "
        "on the x axis and max stress on the y axis, six dots, a curved front line, the third dot highlighted. "
        "Inspector: OUTCOME 3, mass 57 g, max stress 21.4 MPa, first frequency 412 Hz; MESH CHECKS rows with green "
        "checks: Watertight, Manifold, 1 body, Min wall 1.3 mm, Overhangs ok, No voids, 184k triangles; buttons "
        "Use as Forearm (blue), Compare, Export 3MF."
    ),
    "14-loads-from-sim": CHROME + (
        "This screen: a wide macOS modal sheet titled 'Loads from simulation' over the dimmed Generate workspace. "
        "Left column: list of simulation runs: Reach v3 (selected), Pick cube v2, Drop test v1, each with a date. "
        "Centre: a line chart titled 'Forearm wrench' showing force magnitude over 10 seconds with four red dots "
        "marking peaks, a vertical playhead, and a small 3D thumbnail of a white robot arm above the chart. Right: a "
        "segmented control Peaks (selected), Envelope, At time; a Count stepper 4; a list of four load cases with "
        "checkboxes: t 1.24 s 21 N 0.8 N.m; t 3.02 s 18 N 1.1 N.m; t 5.66 s 26 N 0.6 N.m; t 8.10 s 15 N 1.4 N.m. "
        "Bottom right: grey Cancel and blue 'Add 4 load cases' buttons."
    ),
    "15-ik-drag": CHROME + (
        "This screen: the Assemble workspace, MOTION tab active, tool 'Drag tip' highlighted; switcher reads "
        "ASSEMBLE. Project title: Desk Arm, subtitle Assemble . Assembly v4. Canvas: the white 6 axis desk robot "
        "arm reaching toward the viewer, with a 6 axis gizmo at the gripper tip: three coloured arrows (red, green, "
        "blue) and three coloured rotation rings; the elbow joint glows orange as near its limit; a dashed grey "
        "line from the gripper tip to the mouse cursor labelled '14 mm out of reach'. Inspector titled IK: TARGET "
        "x 312.0 y 48.5 z 196.2 mm, roll 0 pitch 90 yaw 12 deg; SOLVER badge Analytic; JOINTS six rows J1 to J6 "
        "each with an angle and a thin limit bar, J3 bar orange; toggles Keep orientation on, Posture Elbow up; a "
        "blue Save pose button."
    ),
    "16-hand-grasp": CHROME + (
        "This screen: the Assemble workspace, MOTION tab, tool Grasp active; switcher reads ASSEMBLE. Project "
        "title: Humanoid Hand, subtitle Assemble . Assembly v3. Canvas: a white and light grey robotic humanoid "
        "hand with five fingers closing around a matte blue cylinder; small coloured spheres on each fingertip "
        "touching the cylinder with numbers 1 to 5, thin normal lines at the contacts. Inspector titled GRASP: "
        "Object Cylinder 40 mm x 120 mm; FINGERS five rows Thumb, Index, Middle, Ring, Little, each with a green "
        "dot 'reached', a drive badge (Tendon or Motor), and small joint values; ACTUATORS tendon values in mm; "
        "buttons Save grasp (blue) and Test in simulation."
    ),
    "17-path-planner": CHROME + (
        "This screen: the Robot workspace, DEPLOY tab, tool Paths; switcher reads ROBOT. Project title: Desk Arm, "
        "subtitle Robot . Path Pick and place. Canvas: the white desk robot arm on a table with two grey boxes as "
        "obstacles and a small red cube; a coloured tube path from the gripper: straight blue segments and a curved "
        "green segment going over a box, five numbered white spheres as waypoints, a faint translucent swept "
        "ghost of the arm along one segment. Bottom panel: joint position curves J1 to J6 over 6 seconds with "
        "shaded limit bands and a playhead. Inspector PATH: waypoints list 1 Home, 2 Above cube (Line), 3 Grasp "
        "(Line), 4 Over box (Plan), 5 Place (Line); Speed 30 percent; Cycle time 5.8 s; CHECKS 'No collisions . "
        "min clearance 12 mm' with a green check; a grey button Run on robot with a lock icon."
    ),
    "18-mobile-base": CHROME + (
        "This screen: the Simulate workspace; switcher reads SIMULATE. Project title: Rover 1, subtitle Simulate . "
        "Warehouse v2. Canvas split: left a 3D view of a small four wheeled mecanum robot base with a mini white "
        "robot arm on top, in a simple warehouse aisle with shelves; right a top-down occupancy grid map in grey "
        "and white with a blue planned path curving between obstacles and the robot footprint rectangles along it. "
        "Bottom panel: telemetry curves for wheel speeds FL, FR, RL, RR and heading over time. Inspector: BASE "
        "Mecanum, 4 wheels, mass 6.2 kg; PLANNER Hybrid A*, path 7.4 m, clearance 0.18 m; DRIVE keyboard or "
        "gamepad; buttons Run (blue)."
    ),
    "19-carbon-plate": CHROME + (
        "This screen: the Make workspace, PACKAGE tab; switcher reads MAKE. Project title: Racer 3in, subtitle Make "
        ". Bundle rev C. Canvas: a white sheet layout showing a black 2D outline drawing of a generative 3 inch "
        "drone frame plate with four organic arms, motor hole patterns and a central stack mount, with small blue "
        "dimension labels; a scale bar 50 mm. Inspector PLATE: Thickness 3 mm carbon, Outline 1 closed, Holes 22 "
        "(M2, M3), CHECKS min slot 2.1 mm ok, min bridge 2.8 mm ok, all with green checks; buttons Export DXF "
        "(blue) and Export SVG."
    ),
    "20-agent-manager": CHROME + (
        "IMPORTANT LAYOUT CHANGE for this screen: to the LEFT of the BROWSER sidebar there is an extra first "
        "column titled AGENTS, about 260 px wide, with a small orange badge 1 next to the title and a + button. "
        "Its rows, each with a round avatar with a coloured ring, a title, a state line and small chips: 'You' "
        "(grey avatar, 'Manual'); 'Lighter forearm' (purple ring, selected row highlighted, 'Running step 3 of 5', "
        "chip Forearm, '0.32 USD'); 'Route board' (teal ring, 'Waiting for approval' with an orange dot, chip "
        "Board rev C); 'Pick cube policy' (green ring, 'Waiting for Assembly (held by You)', grey); 'Price BOM' "
        "(blue ring, 'Done', green check). This screen: the Generate workspace in follow mode for the agent "
        "'Lighter forearm'; switcher reads GENERATE. Project title: Desk Arm. A slim purple banner at the top of "
        "the canvas reads 'Lighter forearm is editing Forearm . Take over'. Canvas: a smooth generative robot "
        "forearm part being optimised, half transparent design space box, purple outline glow on the part. "
        "Inspector with tabs Properties, Agent (active), Comments: PLAN five numbered steps with checks and a "
        "spinner on step 3; CHECKPOINT card 'Run study on cloud, est. 0.40 USD' with Approve (blue) and Reject; "
        "THREAD with two short chat bubbles."
    ),
    "21-coediting": CHROME + (
        "This screen: the Assemble workspace of a shared project with real-time co-editing; switcher reads "
        "ASSEMBLE. Project title: Desk Arm, subtitle 'Shared . 3 people . 2 agents'. In the toolbar next to the "
        "search icon a row of five small round avatars with coloured rings (two people photos replaced by "
        "initials QC and ML, one initials JD, two small robot icons for agents). Canvas: the white 6 axis desk "
        "robot arm; the gripper outlined in teal with a small floating label 'ML editing'; the base outlined in "
        "orange with label 'JD'; a small teal mouse cursor with name tag ML near the gripper; a comment pin with "
        "the number 2 on the forearm. Browser rows show tiny avatar badges next to Gripper (ML) and Base (JD), "
        "and a lock icon. Inspector Comments tab active with a short thread: 'Can we add 2 mm clearance here?' "
        "and a reply. Status bar: 'Synced . 3 people online'."
    ),
    "22-first-launch": CHROME + (
        "This screen: the very first launch of the app. Switcher button reads DESIGN with a cube icon. Project "
        "title 'Untitled', subtitle 'Design . not saved'. Ribbon tabs: BODY (active), FREEFORM, FOLD, MOLD, "
        "FRAMES, IMPORT, CHECK, with tool buttons Sketch, Extrude, Revolve, Fillet, Shell, Hole. Browser tree "
        "only: Untitled, Origin, Sketches, Bodies (all empty). Canvas: an empty light grey 3D space with a "
        "faint grid floor, the three origin planes faintly tinted and a small view cube top right. Over the "
        "canvas near the right edge, a floating rounded card with a soft shadow titled 'New here?' with text "
        "'Take a 10 minute tour with the guide.' and four small rows with icons: 'Design a part', 'Make it "
        "lighter', 'Design a board', 'Product with electronics', a 'Show all tours' link and a small close X. "
        "Bottom panel: an empty feature timeline. Inspector: SELECTION Nothing selected; DOCUMENT Units mm, "
        "Material none. Status bar: 'Ready . Offline works'. No robot anywhere on screen."
    ),
    "23-learn-panel": CHROME + (
        "This screen: the Design workspace with the LEARN panel open as a right side column replacing the "
        "inspector; switcher reads DESIGN. Project title 'Untitled'. Canvas: a simple grey bracket part. The "
        "LEARN panel: title LEARN, a search field, then a section TOURS with six cards, each with a small "
        "illustration, title, duration and domain chip: 'Design a part . 10 min . CAD', 'Make it lighter . "
        "10 min . Generative', 'Design a board . 15 min . PCB', 'Product with electronics . 15 min . "
        "Mechatronics', 'Simulate a mechanism . 10 min . Simulation', 'Train a robot . 15 min . Robotics'; the "
        "first card has a green check 'Done'. Under it a section GUIDE: 'Sign in with Apple to claim 5 USD of "
        "starter credits' (black button with a small key icon) and grey text 'Without sign-in, tours run "
        "offline with a scripted guide.' Then a section SHORTCUTS with three rows of keyboard shortcuts."
    ),
    "24-tour-part": CHROME + (
        "%s"
        "This screen: the Design workspace; switcher reads DESIGN. Project title 'Wall bracket'. Ribbon tab "
        "BODY active with the Extrude button highlighted with a purple pulsing ring. Canvas: an L shaped wall "
        "bracket being extruded from a blue sketch profile, a blue drag arrow with a value badge '40 mm', "
        "two holes sketched; a callout 'Drag the arrow or type 40.' Bottom panel: feature timeline with "
        "Sketch 1, Extrude 1 (active). Thread bubble: 'Now we turn the sketch into a solid.'"
    ) % GD.format(title="Design a part", state="Step 3 of 6 . Extrude", steps="1 Sketch the profile, 2 Add dimensions, 3 Extrude, 4 Fillet edges, 5 Add holes, 6 Export STL"),
    "25-tour-board": CHROME + (
        "%s"
        "This screen: the Electronics workspace; switcher reads ELECTRONICS with a chip icon. Project title "
        "'LED driver board'. Ribbon tabs: SCHEMATIC, LAYOUT (active), ROUTE, CHECK, EXPORT. Canvas: a top view "
        "of a small green two layer circuit board outline with a USB C connector, a small microcontroller, "
        "resistors and LEDs placed; thin white ratsnest lines between pads; one red copper trace being routed "
        "with a purple cursor; a callout 'Follow the thin lines: each one is a connection to route.' Browser "
        "tree: Schematic, Board, Components (12), Nets (9), Layers. Thread bubble: 'I routed power. Want to "
        "try the next trace?' with buttons 'I will do it' and 'You do it'."
    ) % GD.format(title="Design a board", state="Step 4 of 6 . Route traces", steps="1 Draw the schematic, 2 Pick parts, 3 Place parts, 4 Route traces, 5 Check rules, 6 Export Gerbers"),
    "26-tour-product": CHROME + (
        "%s"
        "This screen: the Design workspace of a mechatronic product; switcher reads DESIGN. Project title "
        "'Desk sensor'. Canvas: a rounded white two part enclosure shown half transparent, with the green "
        "circuit board inside it shown as a solid 3D board with components, a USB C cutout on the enclosure "
        "side lined up with the connector and highlighted green, four screw bosses under the board mounting "
        "holes; a small red warning marker on one component touching the lid with label 'Clearance 0.4 mm, "
        "needs 1 mm'. Browser tree: Enclosure (Base, Lid), Board (linked, rev B), Screws (4). Thread bubble: "
        "'The board comes from Electronics. If you move a part there, the case updates here.'"
    ) % GD.format(title="Product with electronics", state="Step 4 of 6 . Fit the case", steps="1 Open the board, 2 Make the case, 3 Add bosses, 4 Fit the case, 5 Check clearance, 6 Export for print"),
    "27-project-start": CHROME + (
        "OVERRIDE for this screen: there is NO ribbon, NO workspace switcher button, NO browser sidebar, NO "
        "pipeline outputs and NO inspector; the toolbar title reads 'ViaForm' with subtitle 'Start'. Under "
        "the toolbar one single full-width start page on a white background. The status bar text is 'Ready'. "
        "This screen: the project start view. Left column: 'New' with buttons Blank design and Blank board, then 'Recent' with three "
        "thumbnail rows (Wall bracket, LED driver board, Desk sensor). Main area: 'Templates' with filter chips "
        "All, Part, Board, Product with electronics, Robot, Import; a grid of template cards with clean "
        "thumbnails: 'Wall bracket' (part), 'Phone stand' (part), 'USB LED board' (board), 'Sensor breakout' "
        "(board), 'Desk sensor' (enclosure with board), 'Smart lamp' (product), 'Desk arm' (robot arm), 'FPV "
        "drone 3 inch' (robot), 'Import STEP or KiCad'. At the top a wide input 'Describe what you want to "
        "build' with a purple sparkle icon, and at the right a small card 'Learn . 6 tours'."
    ),
    "28-style-a-calm-pro": (
        "%sSTYLE A, CALM PRO: warm off-white background #FAF9F7, warm grey hairlines, near monochrome, one "
        "muted terracotta accent #C96442 used only for selection and the primary button, SF Pro font, generous "
        "spacing. Top: a slim toolbar with the project name and a small workspace dropdown 'Design' with a "
        "chevron. Under it ONE single row of about 10 small monochrome line icons with short captions (Sketch, "
        "Extrude, Revolve, Fillet, Shell, Hole, Pattern, Measure), no tabs. Left: a narrow feature tree with "
        "rows Origin, Sketch 1, Extrude 1, Fillet 1, Hole 1 in plain text. Right: a quiet inspector with three "
        "key value rows for the selected Fillet 1 (Radius 4 mm). Bottom: a thin feature timeline with small "
        "square markers. Lots of empty space, no shadows, no gradients."
    ) % BASE,
    "29-style-b-minimal": (
        "%sSTYLE B, MINIMAL CANVAS: the viewport fills the whole window edge to edge, warm off-white #FAF9F7, "
        "no ribbon, no sidebars. Floating elements only: top left a small rounded pill with the project name "
        "'Wall bracket' and a workspace dropdown 'Design'; top right a small pill with search, history and an "
        "agent sparkle icon; at the bottom centre a floating rounded tool bar with 8 monochrome icons (select, "
        "sketch, extrude, fillet, hole, measure, section, more); next to the selected fillet edge a small "
        "floating context menu with 'Radius 4 mm' field and 'Fillet', 'Chamfer', 'Edit sketch'. Left edge a "
        "collapsed thin tab 'Tree'. Bottom right a tiny timeline strip. One muted terracotta accent #C96442. "
        "Soft and quiet, nothing else on screen."
    ) % BASE,
    "30-style-c-text-first": (
        "%sSTYLE C, TEXT FIRST: warm off-white #FAF9F7 window. Left 60 percent: the 3D viewport with the "
        "bracket, a tiny floating tool pill at the top (sketch, extrude, fillet, hole, measure). Right 40 "
        "percent: a calm text column like a coding assistant transcript in a monospace font (SF Mono) on the "
        "same warm background, with a thin left border: lines such as '> make the bracket 20 percent "
        "lighter', then indented grey lines 'Reading Wall bracket . 5 features', 'Plan: 1 shell to 3 mm, 2 add "
        "two lightening holes, 3 check stress', a small diff style block 'Shell 1  thickness 3 mm  (new)' in "
        "green, and at the bottom a single input line with a '>' prompt and placeholder 'Ask or type a "
        "command'. Top: one slim line with 'Wall bracket', a workspace dropdown 'Design' and a terracotta dot. "
        "Bottom of the viewport a thin feature timeline. One muted terracotta accent #C96442, no icons in the "
        "text column, no chat bubbles."
    ) % BASE,
}


def key():
    return subprocess.check_output(["az", "cognitiveservices", "account", "keys", "list", "-n", "temple-ai-provider",
                                    "-g", "temple-ai-rg", "--query", "key1", "-o", "tsv"], text=True).strip()


def lock():
    while True:
        try:
            os.mkdir(LOCK)
            return
        except FileExistsError:
            time.sleep(3)


def unlock():
    try:
        os.rmdir(LOCK)
    except OSError:
        pass


def run(name, k):
    out = HERE / f"{name}.png"
    if out.exists():
        i = 1
        while (HERE / f"{name}.try{i}.png").exists():
            i += 1
        out.rename(HERE / f"{name}.try{i}.png")
    body = json.dumps({"prompt": SCREENS[name], "size": "1536x1024", "quality": "high",
                       "output_format": "png", "n": 1}).encode()
    for attempt in range(6):
        req = urllib.request.Request(EP, data=body, method="POST",
                                     headers={"api-key": k, "Content-Type": "application/json"})
        lock()
        try:
            with urllib.request.urlopen(req, timeout=600) as r:
                data = json.load(r)["data"][0]["b64_json"]
            out.write_bytes(base64.b64decode(data))
            print(name, "ok", flush=True)
            return
        except urllib.error.HTTPError as e:
            print(name, "http", e.code, e.read().decode()[:200], flush=True)
            if e.code not in (429, 500, 502, 503, 504):
                return
        except Exception as e:
            print(name, "error", e, flush=True)
        finally:
            unlock()
        time.sleep(20 * (attempt + 1))


if __name__ == "__main__":
    import signal
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(1))
    names = sys.argv[1:] or list(SCREENS)
    k = key()
    for n in names:
        run(n, k)
