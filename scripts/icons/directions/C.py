"""Direction C: soft matte clay. Light grey clay objects with soft ambient light, the acted-on face in matte blue clay.
Rendered, tactile but quiet: no gloss, no hard specular."""
from . import common

TITLE = "C. Matte clay"
DESCRIPTION = ("Soft matte clay renders in light warm grey, the acted-on face in matte accent blue. Tactile and quiet, "
               "no gloss, soft ambient light.")
BODY = "soft matte light grey clay"
ACCENT = "matte ViaForm blue clay #2F6BFF"
STYLE = (
    "Draw a single toolbar icon for a professional 3D CAD application as a soft matte clay 3D render, like a "
    "minimal clay model in a bright studio. If a reference image is given, copy only its material, colours and "
    "lighting, not its shape. Three-quarter isometric view from above. Material: smooth matte clay, no gloss, no "
    "specular highlights, no reflections, no texture, gently rounded edges (small bevels catch the light). Lighting: "
    "soft large key light from the upper left, soft ambient occlusion in creases, gentle form shading so every face "
    "reads distinctly: top faces lightest, side faces clearly darker. Neutral parts are light cool grey clay (#E4E6EA "
    "lit, #B9BDC5 in shade), never white, never black. The acted-on part is matte blue clay in ViaForm blue (#2F6BFF, "
    "#4C82FF lit, #1F4FCC in shade), the only colour. Arrows are chunky rounded blue clay arrows. Bold simple shapes, "
    "strong silhouette, no small details, readable at 26 pixels. Centred, filling about 85% of the square. No text, no "
    "letters, no numbers, no logo, no UI, no frame, no background plate, no ground, no cast shadow, no outline. "
    "Isolated on a fully transparent background. "
)
TRANSPARENT = True
STYLE_REF = "extrude"


def seed(path):
    common.iso_seed(path, top=(0x4C, 0x82, 0xFF), left=(0xD6, 0xD9, 0xDE), right=(0xB9, 0xBD, 0xC5))


def post(raw):
    return {"": common.trim_square(raw)}

OVERRIDES = {n: common.RETAKES[n] for n in ("revolve", "section", "measure")}
