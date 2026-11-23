"""Direction A: refined isometric objects. Soft neutral grey bodies, the acted-on part in ViaForm blue, crisp vector-like
shading with a fine darker outline. Fusion-like vocabulary, calmer palette."""
from . import common

TITLE = "A. Refined isometric"
DESCRIPTION = ("Small isometric objects in soft neutral greys, the acted-on part in accent blue #2F6BFF, flat "
               "three-tone shading with a fine outline. Fusion vocabulary, calmer.")
BODY = "soft neutral light grey"
ACCENT = "solid ViaForm blue #2F6BFF"
STYLE = (
    "Draw a single toolbar icon for a professional 3D CAD application, in a refined, calm, premium vector "
    "illustration style. If a reference image is given, copy only its colours, shading and line weight, not its "
    "shape. Isometric three-quarter view from above. Shading is clean and flat in three tones per object: top faces "
    "lightest, left faces mid, right faces darkest, with only a very subtle soft gradient inside each face; no "
    "glossy highlights, no reflections, no texture. Neutral parts are soft light greys (top #EEF0F3, left #D2D5DB, "
    "right #B4B8C1), never black, never white. The acted-on part is solid ViaForm blue (#4A80FF lit, #2F6BFF mid, "
    "#2256D6 shade), the only colour in the icon. Every object has a crisp fine dark slate outline (#4A4F5A) of even "
    "weight, rounded joins, so the silhouette reads on both a light and a dark toolbar. Arrows are short, thick, flat "
    "blue with bold heads. Few large simple shapes, no small details, no panel lines, readable at 26 pixels. "
    "Centred, filling about 85% of the square. No text, no letters, no numbers, no logo, no UI, no frame, no "
    "background plate, no ground, no shadow. Isolated on a fully transparent background. "
)
TRANSPARENT = True
STYLE_REF = "extrude"  # first good icon becomes the style reference for the rest


def seed(path):
    common.iso_seed(path, top=(0x4A, 0x80, 0xFF), left=(0xD2, 0xD5, 0xDB), right=(0xB4, 0xB8, 0xC1),
                    edge=(0x4A, 0x4F, 0x5A))


def post(raw):
    return {"": common.trim_square(raw)}

OVERRIDES = {n: common.RETAKES[n] for n in ("revolve", "measure")}
