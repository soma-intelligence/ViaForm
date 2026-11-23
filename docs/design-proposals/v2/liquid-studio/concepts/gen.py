"""Liquid Glass Studio concept screens for ViaForm, Azure gpt-image-2.5-flare images/generations.

usage: python3 gen.py <screen> [suffix]   -> <screen><suffix>.png next to this file
One call at a time across agents: the caller holds /tmp/viaform-azure.lock (see run.sh).
"""
import base64, json, pathlib, subprocess, sys, time, urllib.error, urllib.request

HERE = pathlib.Path(__file__).resolve().parent
EP = ("https://temple-ai-provider.cognitiveservices.azure.com/openai/deployments/gpt-image-2.5-flare/"
      "images/generations?api-version=2025-04-01-preview")

STYLE = (
    "A crisp, pixel-perfect, high resolution UI screenshot of a professional native macOS 26 desktop application "
    "called ViaForm, a 3D CAD and engineering studio. Design language: Apple Liquid Glass. The whole window is one "
    "full-bleed dark 3D viewport (deep graphite #121316 to #1B1D22 soft vertical gradient, faint perspective grid "
    "on the ground plane). All chrome floats over the viewport as rounded translucent frosted glass panels with "
    "soft blur of the scene behind, a thin bright specular rim on the top edge, 1 px hairline border, gentle drop "
    "shadow, 18 px corner radius, 10 px gap from the window edge. Standard macOS window chrome: red, yellow, green "
    "traffic light buttons at top left, inside a floating glass title toolbar. Typography: SF Pro, small and dense "
    "like a pro CAD app (11 to 13 px labels, 15 px panel titles in semibold), white and light grey text, numeric "
    "values in SF Mono. Icons: monochrome satin black and silver 3D tool icons and simple SF Symbols line glyphs. "
    "The viewport content is calm and photoreal like a clean studio CAD render, generous empty space around the "
    "model. Panels are information dense like a professional engineering application. All UI text is short, "
    "legible English. The only product name visible anywhere is ViaForm. No other brand names, no logos of any "
    "company, no watermark. "
)

COMMON_TOP = (
    "Top of window: a floating glass toolbar strip. Left: traffic lights, a sidebar toggle, the project title "
    "'{project}' with a small 'Edited' subtitle, undo and redo arrows. Centre: a glass capsule segmented control "
    "of eight workspace tabs reading exactly: Design, Generative, Mechanics, Electronics, Simulation, Training, "
    "Render, Manufacture. The active tab '{ws}' is a filled pill tinted {accent}. Right: a small jobs indicator "
    "'2 jobs', search magnifier, share button and inspector toggle. "
)

SCREENS = {
    "1-design": dict(
        project="Humanoid Hand", ws="Design", accent="ViaForm Design accent electric blue #3B82F6",
        body=(
            "Under the toolbar a second slim floating glass ribbon, Fusion-like density: groups labelled CREATE, "
            "MODIFY, ASSEMBLE, CONSTRUCT, INSPECT, each with 3 to 5 small satin black 3D icons and a tiny dropdown "
            "chevron, and a group label under each. "
            "Left: a tall floating glass sidebar titled 'Browser' with a dense tree: Hand Assembly v4, Palm, "
            "Index Finger (expanded: Proximal, Middle, Distal, Joint MCP, Joint PIP, Joint DIP, Motor M1, Motor M2, "
            "Motor M3), Middle Finger, Ring Finger, Little Finger, Thumb, Wrist, Tendons, Origin. Small eye toggles "
            "on the right of each row, one row 'Index Finger' highlighted with a blue capsule. "
            "Centre viewport: a large photoreal humanoid robotic hand, open palm slightly curled, seen in three "
            "quarter view: matte white organic generative lattice finger links, dark grey joints, small black "
            "cylindrical micro motors at every knuckle (one motor per joint), thin steel tendon cables, the index "
            "finger selected with a glowing blue outline and a blue rotation gizmo arc at the PIP joint with a small "
            "floating value chip '42.0 deg'. Next to the selection a small floating glass context pill with actions "
            "'Fillet', 'Drive joint', 'Edit motor'. "
            "Top right of viewport: a small glass view cube labelled TOP FRONT RIGHT. "
            "Right: a floating glass inspector sheet titled 'Joint PIP . Index' with sections: Type Revolute, "
            "Limits 0 to 95 deg, Motor M2 Micro BLDC 12 mm, Torque 0.18 N m, Gear 1:64, Speed 120 deg/s, Material "
            "PA12 lattice, Mass 6.4 g, and a blue 'Apply' button. "
            "Bottom centre: a floating glass navigation capsule with orbit, pan, zoom, fit, display icons. "
            "Bottom: a floating glass timeline strip with a row of 14 small parametric feature icons and a blue "
            "playhead marker."
        )),
    "2-generative": dict(
        project="Racer 3in", ws="Generative", accent="ViaForm Generative accent vivid magenta #E0409B",
        body=(
            "Left: floating glass sidebar titled 'Study 2 . Frame' with dense sections: Preserve (Motor pads x4, "
            "Stack mount 30.5), Obstacles (Prop sweep x4, Battery bay, Camera pod), Load cases (Crash 12 g, Full "
            "thrust 4 x 820 gf, Hover gust), Objectives (Minimise mass, Stiffness at least 40 N/mm), Material "
            "Carbon PA12, Manufacturing Additive. Each row has a small coloured dot or icon. "
            "Centre viewport, left two thirds: a large photoreal 3-inch FPV quadcopter frame, organic generative "
            "topology-optimised branching arms like bone structure, shown with a smooth stress colour map gradient "
            "blue to green to yellow to red on the arms, red near the motor pad roots; small magenta load arrows on "
            "the motor pads; translucent pale cylinders showing the prop sweep keep-out zones. A floating glass "
            "colour legend bar 'Von Mises MPa 0 to 182' in the bottom left of the viewport. "
            "Right: a floating glass panel titled 'Outcomes 74 / 120' containing a 3 by 3 gallery grid of small "
            "dark thumbnail cards each with a different generative drone frame shape and tiny labels like '#14 11.6 g "
            "52 N/mm', the first card '#14' outlined in magenta with a 'Best' tag; below the grid a small scatter plot "
            "titled 'Mass vs stiffness' with magenta dots and a highlighted Pareto curve, and two buttons 'Use as Frame' "
            "(magenta filled) and 'Compare'. "
            "Bottom centre: floating glass progress capsule 'Generating 74 of 120 . 3 min left' with a thin magenta "
            "progress bar."
        )),
    "3-simulation": dict(
        project="Racer 3in", ws="Simulation", accent="ViaForm Simulation accent bright teal green #14C9A0",
        body=(
            "The full window viewport shows a realistic 3D outdoor flight simulation scene at dusk: a small dark "
            "3-inch FPV drone in mid flight banking through a course of glowing teal rectangular race gates and "
            "orange obstacle poles over a grass field, a dotted teal flight path line curving through the gates, "
            "faint white wind streamlines blowing across the scene from the left, a small glass wind compass chip "
            "'Wind 6.2 m/s . gust 9.0'. "
            "Left: slim floating glass tool rail with play, pause, step, camera and wind icons, then a floating glass "
            "panel titled 'Scenario' listing: Obstacle course A (14 gates), Wind Breezy dusk, Airframe Frame v8 153 g, "
            "Controller PID + Policy v5, Seed 1. "
            "Top right: floating glass HUD card with big SF Mono numbers '19.7 s', Speed 14.2 m/s, Altitude 3.1 m, "
            "Gates 9 / 14, Battery 15.2 V, four tiny motor bars M1 to M4 in teal. "
            "Right lower: a floating glass telemetry panel titled 'Telemetry' with three stacked small line charts "
            "with thin teal, white and amber lines: 'Attitude roll pitch yaw', 'Motor RPM', 'Altitude m', each with "
            "tiny axis labels. "
            "Bottom: floating glass transport timeline scrubber with playback controls, time '00:19.7 / 00:42.0', "
            "teal playhead, and a teal filled button 'Re-run on Frame v8'."
        )),
    "4-electronics": dict(
        project="Racer 3in", ws="Electronics", accent="ViaForm Electronics accent warm amber #F5A524",
        body=(
            "Centre: a large top-down flat view of a square 30.5 mm drone flight controller printed circuit board "
            "with a dark green solder mask, four mounting holes at the corners with gold rings, a central square QFP "
            "microcontroller labelled 'U1 STM32F405', a small IMU chip 'U2', a USB-C connector at one edge, "
            "neat copper traces in orange and red on different layers, small 0402 passives, silkscreen labels "
            "in white like 'FC rev 196', 'J1', 'M1 M2 M3 M4' at the motor pads. A thin amber ratsnest line highlighted. "
            "Left: a floating glass sidebar titled 'Board rev 196' with layer toggles (F.Cu orange, In1, In2, B.Cu "
            "blue, Silk, Mask) as small coloured chips, then a dense list: Schematic sheets (Power 5V 3V3, MCU, ESC "
            "4 in 1, Sensors), Components U1 STM32F405, U2 ICM-42688, J1 XT30, J2 Camera, Nets 112. Row 'U1' "
            "highlighted in an amber capsule. "
            "Top right: a floating glass picture-in-picture card titled '3D link . Mounted in Frame v8' showing a "
            "small 3D render of the same green board sitting on the stack mount of a black carbon quadcopter frame, "
            "with an amber 'Clearance 0.6 mm' badge. "
            "Right: floating glass inspector sheet titled 'U1 . STM32F405' with Package LQFP64, Layer Top, Position "
            "15.25, 15.25 mm, Rotation 45 deg, Nets 48, DRC 0 errors, and buttons 'Route' (amber filled) and "
            "'Show in 3D'. "
            "Bottom left: a slim floating glass tool rail with route, via, zone, measure icons. Bottom centre: glass "
            "status capsule 'DRC passed . 4 layers . 36 x 36 mm'."
        )),
}

IPAD = (
    "A crisp, pixel-perfect, high resolution UI screenshot of an iPad Pro app in landscape, iPadOS 26 Apple "
    "Liquid Glass design, the 3D CAD app called ViaForm, touch first and calm like a modern direct-modelling iPad "
    "app. The whole screen is a full-bleed dark graphite 3D viewport (#121316 to #1B1D22) with a faint ground "
    "grid. iPad status bar at the very top with time 9:41 and battery. "
    "Top centre: a floating glass capsule with the eight workspace tabs as compact icons with short labels: "
    "Design, Generative, Mechanics, Electronics, Simulation, Training, Render, Manufacture; 'Design' is a filled "
    "electric blue #3B82F6 pill. Top left: round glass buttons for projects sidebar, undo, redo. Top right: round "
    "glass buttons for items, history, export, and a small glass view cube. "
    "Left edge: a vertical floating glass tool column with large 44 pt touch targets, satin black 3D tool icons "
    "for sketch, extrude, fillet, shell, joint, motor, measure, the 'joint' one highlighted blue. "
    "Centre: a large photoreal humanoid robotic hand, palm up and fingers gently curled, matte white generative "
    "lattice finger links, dark grey joints, small black micro motors at every knuckle, thin steel tendons; the "
    "thumb selected with a glowing blue outline, a large blue drag handle arrow with a floating value bubble "
    "'35.0 deg' next to it. Just above the selection a floating glass suggestion bar with big touch pills: "
    "'Drive joint', 'Set limits', 'Swap motor', 'Fillet'. "
    "Right: a floating glass sheet titled 'Thumb CMC joint' with large touch rows: Type Revolute, Range 0 to 70 "
    "deg, Motor Micro BLDC 12 mm, Torque 0.22 N m, Gear 1:64, and a blue 'Done' button. "
    "Bottom centre: a floating glass capsule showing 'Hand Assembly v4 . 21 joints . 21 motors'. "
    "An Apple Pencil tip resting near the hand. SF Pro typography, white and light grey text, legible English "
    "labels. The only product name visible is ViaForm. No other brand names, no logos, no watermark."
)


def prompt(name):
    if name == "5-ipad-hand":
        return IPAD
    s = SCREENS[name]
    return STYLE + COMMON_TOP.format(project=s["project"], ws=s["ws"], accent=s["accent"]) + s["body"]


def key():
    return subprocess.check_output(["az", "cognitiveservices", "account", "keys", "list", "-n", "temple-ai-provider",
                                    "-g", "temple-ai-rg", "--query", "key1", "-o", "tsv"], text=True).strip()


def run(name, suffix, k):
    body = json.dumps({"prompt": prompt(name), "size": "1536x1024", "quality": "high", "n": 1,
                       "output_format": "png"}).encode()
    for attempt in range(6):
        req = urllib.request.Request(EP, data=body, method="POST",
                                     headers={"api-key": k, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=900) as r:
                data = json.load(r)["data"][0]["b64_json"]
            (HERE / f"{name}{suffix}.png").write_bytes(base64.b64decode(data))
            print(name, suffix, "ok", flush=True)
            return True
        except urllib.error.HTTPError as e:
            print(name, "http", e.code, e.read().decode()[:200], flush=True)
            if e.code not in (429, 500, 502, 503, 504):
                return False
        except Exception as e:
            print(name, "error", e, flush=True)
        time.sleep(20 * (attempt + 1))
    return False


if __name__ == "__main__":
    if sys.argv[1] == "--dump":
        for n in list(SCREENS) + ["5-ipad-hand"]:
            print(f"## {n}\n\n{prompt(n)}\n")
        sys.exit()
    name = sys.argv[1]
    suffix = sys.argv[2] if len(sys.argv) > 2 else ""
    sys.exit(0 if run(name, suffix, key()) else 1)
