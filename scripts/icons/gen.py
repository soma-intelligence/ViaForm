"""Toolbar icons in the Soma Flight jet's finish: satin black studio renders, the profile jet's paint.

Made with Azure gpt-image-2.5 (images/edits), the Soma Flight app icon jet (black, side view) as the style reference. The look follows
the big CAD apps' ribbons: one chunky 3D object per command, the part the command acts on picked out in
colour. One call at a time: the deployment rate-limits.

usage (from the repo root):  python3 scripts/icons/gen.py [name ...]     # default: every icon in ICONS
                             -> scripts/icons/raw/<name>.png, then scripts/icons/build.py
"""
import base64, json, pathlib, subprocess, sys, time, urllib.error, urllib.request, uuid

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "raw"
REF = pathlib.Path("/Users/quentin/Desktop/Soma/Soma_Flight/Apps/iOS/Assets.xcassets/AppIcon.appiconset/light.png")
EP = ("https://temple-ai-provider.cognitiveservices.azure.com/openai/deployments/gpt-image-2.5-flare/"
      "images/edits?api-version=2025-04-01-preview")

STYLE = (
    "The reference image shows only the material and rendering style to copy: the side-view business jet's paint, "
    "a deep satin black with soft charcoal shading and gentle silver specular highlights along the edges, a "
    "realistic but slightly stylised premium product render, like an Apple product render, soft studio lighting "
    "from the upper left, smooth satin gloss, crisp softly rounded edges, very few details. Do NOT draw an aircraft. "
    "Draw a single toolbar icon for a professional 3D CAD application, in the spirit of the icons of Autodesk Fusion "
    "and Shapr3D: one chunky, simple 3D object seen in a three-quarter isometric view from above, made entirely of "
    "that same satin black finish, exactly like the black jet: every solid surface is near-black (#121214 to "
    "#2A2A2E), never white, never light grey. Monochrome: no colour at all. The part the command acts on, as described, is "
    "picked out the way the jet's cockpit windows are: dark smoked glossy glass with a bright clean reflection, or a "
    "brighter polished silver, so it reads at a glance. Any arrow is a short, thick, satin black 3D arrow with a "
    "silver edge highlight. The icon must stay bold and readable at 26 pixels: few large shapes, strong silhouette, "
    "no thin details, no small parts, no panel lines. Centred, filling about 80% of the square with even margins. "
    "No text, no letters, no numbers, no logo, no UI, no frame, no tile, no background plate. Isolated on a fully "
    "transparent background: no ground, no shadow, no reflection, no watermark. "
)

ICONS = {
    # Create
    "sketch": "A flat satin black square plate lying tilted in perspective; on its top face a thick polished silver pencil stroke "
              "draws a closed rectangle outline, a short glossy polished silver pencil resting on it.",
    "extrude": "A satin black rectangular block rising out of a thin satin black base plate; its top face is polished silver and a thick "
               "polished silver arrow points straight up out of that top face.",
    "revolve": "A satin black vase-like solid of revolution, cut away by a quarter so its profile shows; the cut profile "
               "face is polished silver, a thick curved polished silver arrow wraps around its vertical axis.",
    "box": "A single satin black cube with rounded edges; its top face is polished silver.",
    "cylinder": "A single satin black upright cylinder with softly rounded edges; its top circular face is polished silver.",
    "hole": "A thick satin black square plate with one round hole drilled through its centre; the inner wall of the hole "
            "is polished silver.",
    # Modify
    "presspull": "A satin black block; its top face is polished silver and pushed up a little, a thick polished silver double-headed arrow "
                 "pointing up and down above it.",
    "fillet": "A satin black L-shaped block; the inside corner edge between its two faces is a smooth rounded fillet "
              "coloured polished silver.",
    "chamfer": "A satin black block; one top edge is cut off at 45 degrees, that flat bevel face coloured polished silver.",
    "shell": "A satin black open box hollowed out with thick walls, seen from above; the inner floor and inner walls are "
             "polished silver.",
    "combine": "Two satin black shapes merging: a cube and a sphere interpenetrating; the sphere is polished silver.",
    "delete": "A satin black cube floating above a thick polished silver X made of two crossed rounded bars.",
    # Assemble
    "component": "Two satin black blocks stacked slightly apart, one exploded upwards; the upper block is polished silver.",
    "joint": "Two satin black blocks joined by a satin black pin; the round pin is polished silver, a curved polished silver arrow around it.",
    "as_built": "Two satin black plates already touching, joined at a polished silver round pin through both.",
    "rigid_group": "Three small satin black cubes locked together in an L, held by one polished silver rounded band around them.",
    "capture": "A satin black cube inside four thick polished silver corner brackets, like a camera framing it.",
    # Configure, construct
    "configuration_table": "A satin black rounded tile carrying a 3 by 3 grid of small raised cells; the top row is polished silver.",
    "plane": "A thin satin black square plate hovering above a small satin black cube; the plate is translucent smoked glass.",
    "plane_angle": "A small satin black cube with a thin translucent smoked glass square plate slanted at 30 degrees through "
                   "one edge.",
    "axis_through_cylinder": "A satin black upright cylinder with a long thick polished silver rod passing vertically through its "
                             "centre, sticking out above and below.",
    "point_vertex": "A satin black cube; one top corner holds a glossy polished silver sphere.",
    # Inspect
    "measure": "A thick satin black ruler lying diagonally; a glossy polished silver double-headed arrow spans above it.",
    "interference": "Two satin black cubes overlapping each other; the overlapping volume between them is polished silver.",
    "section": "A satin black sphere cut in half by a plane; the flat cut face is polished silver.",
    # Insert
    "import": "A satin black open box; a thick polished silver arrow points down into it.",
    "fastener": "A single satin black hex bolt standing upright; its threads are polished silver.",
    "library": "Three thick satin black books standing side by side; the middle one is polished silver.",
    # Electronics
    "board": "A thick satin black rounded printed circuit board seen in perspective, one polished silver square chip on it, a few "
             "chunky raised satin black traces.",
    "cube3d": "A satin black cube with a polished silver circuit board plate lying on its top face.",
    "mount": "A satin black circuit board hovering above a satin black block, a thick polished silver arrow pointing down between them.",
    # Shell
    "select": "A satin black 3D mouse pointer arrow, tilted, with a polished silver tip.",
}


def key():
    return subprocess.check_output(["az", "cognitiveservices", "account", "keys", "list", "-n", "temple-ai-provider",
                                    "-g", "temple-ai-rg", "--query", "key1", "-o", "tsv"], text=True).strip()


def run(name, k):
    fields = {"prompt": STYLE + "The icon: " + ICONS[name], "size": "1024x1024", "quality": "high",
              "background": "transparent", "output_format": "png", "n": "1"}
    b = uuid.uuid4().hex
    body = b"".join(f"--{b}\r\nContent-Disposition: form-data; name=\"{f}\"\r\n\r\n{v}\r\n".encode()
                    for f, v in fields.items())
    body += (f"--{b}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"ref.png\"\r\n"
             f"Content-Type: image/png\r\n\r\n").encode() + REF.read_bytes() + b"\r\n"
    body += f"--{b}--\r\n".encode()
    for attempt in range(6):
        req = urllib.request.Request(EP, data=body, method="POST",
                                     headers={"api-key": k, "Content-Type": f"multipart/form-data; boundary={b}"})
        try:
            with urllib.request.urlopen(req, timeout=600) as r:
                data = json.load(r)["data"][0]["b64_json"]
            (OUT / f"{name}.png").write_bytes(base64.b64decode(data))
            print(name, "ok", flush=True)
            return
        except urllib.error.HTTPError as e:
            msg = e.read().decode()[:200]
            print(name, "http", e.code, msg, flush=True)
            if e.code not in (429, 500, 502, 503, 504):
                return
        except Exception as e:  # timeouts, resets
            print(name, "error", e, flush=True)
        time.sleep(20 * (attempt + 1))


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    names = sys.argv[1:] or [n for n in ICONS if not (OUT / f"{n}.png").exists()]
    k = key()
    for n in names:
        run(n, k)
