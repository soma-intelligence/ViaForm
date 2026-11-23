"""App icon options for ViaForm (design, build, simulate). macOS squircle on the Apple 1024 grid: the artwork is
masked to an 824 px superellipse centred on the canvas, with the system-like soft drop shadow, no text.

Glass options reuse the frosted-glass family (/Users/quentin/Desktop/Soma/glass-icons/refs/style.png as the material
reference): the tile is rendered on black, then its bounding box is masked to the squircle so the edge is clean and
the glowing bottom bevel stays. The other options are rendered full bleed and masked the same way.
"""
import pathlib
from PIL import Image, ImageChops, ImageDraw, ImageFilter

GLASS_REF = pathlib.Path("/Users/quentin/Desktop/Soma/glass-icons/refs/style.png")

GLASS = (
    "Recreate the exact material and lighting of the reference image: a thick slab of frosted, milky translucent "
    "glass shaped as a rounded squircle app icon tile, seen straight on with a slight top-down tilt so the thick "
    "bottom edge and lower side bevels are visible, soft white frosted top half, a glowing coloured light object "
    "suspended INSIDE the glass and diffused by the frost, the light bleeding into the bottom bevel as saturated "
    "refracted colour, a thin bright specular rim along the top edge. Pure black background, the tile centred and "
    "large, filling about 88 percent of the canvas, small even margin. Photoreal 3D product render, ultra clean, no "
    "text, no letters, no logo, no watermark, no extra objects. "
)
FULL = (
    "Full-bleed square artwork for a macOS app icon: the background fills the entire square canvas edge to edge, "
    "with NO tile, NO rounded corners, NO border and NO frame (the system masks the corners itself). Keep all "
    "important content inside the central 80 percent. Premium, calm, Apple pro-app quality, one clear subject that "
    "reads at 64 pixels. No text, no letters, no numbers, no logo, no watermark, no UI. "
)

OPTIONS = {
    "glass-lattice": dict(
        title="Glass lattice", glass=True,
        desc="Frosted glass, a glowing generative lattice node inside: design that grows its own structure.",
        prompt=GLASS + "The glowing object inside the glass is a generative lattice node: a rounded cube built from "
        "smooth organic lattice struts (like a topology-optimised gyroid cell) meeting at a bright core, sculpted 3D "
        "with real volume, softly blurred through the frosted glass. Colour: white-hot core, struts glowing pale cyan "
        "turning vivid blue #2F6BFF and deep cobalt toward the bottom, and the bottom glass bevel glows cobalt and "
        "electric blue instead of orange."),
    "glass-part-trace": dict(
        title="Glass part + trace", glass=True,
        desc="Frosted glass, a faceted machined part with a circuit trace of light: mechanics plus electronics.",
        prompt=GLASS + "The glowing object inside the glass is a faceted machined part (a compact angular bracket "
        "with one round hole, crisp chamfered facets) seen in three-quarter view, with thin bright circuit traces of "
        "light running across its top face and ending in small round pads, sculpted 3D with real volume, softly "
        "blurred through the frosted glass. Colour: the part glows vivid blue #2F6BFF with pale cyan on its upper "
        "facets, the traces white-hot, and the bottom glass bevel glows blue and cyan instead of orange."),
    "glass-drone": dict(
        title="Glass drone frame", glass=True,
        desc="Frosted glass, a glowing quad frame seen from above: the kind of thing you design, build and fly.",
        prompt=GLASS + "The glowing object inside the glass is a lightweight quadcopter frame seen straight from "
        "above: an X of four slender arms with a small central hub and four round rotor rings at the ends, clean "
        "geometric silhouette, sculpted 3D, softly blurred through the frosted glass. Colour: hub white-hot, arms and "
        "rings glowing cyan turning into vivid blue #2F6BFF and indigo toward the bottom, and the bottom glass bevel "
        "glows indigo and blue instead of orange."),
    "graphite-wire": dict(
        title="Graphite wire to solid", glass=False,
        desc="Deep graphite field, one part drawn half as blue wireframe and half as a matte solid: sketch to part.",
        prompt=FULL + "Background: deep graphite (#1C1E22 to #2A2D33 soft vertical gradient) with a very faint fine "
        "grid. Subject, centred: one compact mechanical part (an angular bracket with a round hole) in three-quarter "
        "isometric view, its left half drawn as crisp thin glowing blue #2F6BFF wireframe lines with tiny vertex dots, "
        "its right half a smooth matte light grey solid with soft studio light, the two halves joined seamlessly "
        "along a diagonal, as if the part is being built from the sketch. Clean, precise, quiet."),
    "aluminium-pcb": dict(
        title="Machined aluminium", glass=False,
        desc="Light studio field, a CNC-milled aluminium part with a blue anodised face and engraved traces.",
        prompt=FULL + "Background: soft light studio gradient from near white #F7F8FA at the top to cool light grey "
        "#DADDE3 at the bottom. Subject, centred: a single precision CNC-machined aluminium part (a faceted angular "
        "bracket with one round counterbored hole) floating in three-quarter view, bead-blasted satin aluminium sides, "
        "its large top face anodised in ViaForm blue #2F6BFF with a few thin bright engraved circuit traces ending in "
        "round pads, soft contact shadow below, soft studio light from the upper left. Photoreal product render."),
    "line-blueprint": dict(
        title="Line-art blueprint", glass=False,
        desc="Near-white field, a part drawn in crisp blue line art with construction lines and one dimension.",
        prompt=FULL + "Background: flat warm near-white #F7F7F5 with a very faint fine blue grid. Subject, centred: "
        "an isometric line drawing of a compact mechanical part (an angular bracket with a round hole) in crisp "
        "uniform-weight ViaForm blue #2F6BFF lines with rounded caps, a few lighter thin construction lines extending "
        "past its edges, one dimension line with small arrowheads along one edge, and its top face filled with a soft "
        "flat pale blue tint. Flat vector drawing, no shading, no 3D render, engineering-drawing calm."),
}

SIDE, BODY = 1024, 824


def squircle_mask(size, n=5.0, ss=4):
    S = size * ss
    m = Image.new("L", (S, S), 0)
    px = m.load()
    h = S / 2
    for y in range(S):
        v = abs((y + 0.5 - h) / h) ** n
        if v >= 1:
            continue
        xr = (1 - v) ** (1 / n) * h
        x0, x1 = int(round(h - xr)), int(round(h + xr))
        for x in range(max(0, x0), min(S, x1)):
            px[x, y] = 255
    return m.resize((size, size), Image.LANCZOS)


_MASK = None


def to_icon(raw, glass):
    """Mask the artwork to the macOS squircle on the 1024 grid, add the soft drop shadow."""
    global _MASK
    if _MASK is None:
        _MASK = squircle_mask(BODY)
    im = raw.convert("RGB")
    if glass:  # crop to the tile: everything clearly brighter than the black background
        lum = im.convert("L").point(lambda v: 255 if v > 28 else 0).filter(ImageFilter.MedianFilter(5))
        box = lum.getbbox() or (0, 0) + im.size
        ins = int(0.018 * (box[2] - box[0]))  # the render's corners are rounder than the squircle: tuck them in
        im = im.crop((box[0] + ins, box[1] + ins, box[2] - ins, box[3] - ins))
    art = im.resize((BODY, BODY), Image.LANCZOS).convert("RGBA")
    art.putalpha(_MASK)
    canvas = Image.new("RGBA", (SIDE, SIDE), (0, 0, 0, 0))
    off = (SIDE - BODY) // 2
    shadow = Image.new("RGBA", (SIDE, SIDE), (0, 0, 0, 0))
    sh = Image.new("RGBA", (BODY, BODY), (0, 0, 0, 90))
    sh.putalpha(ImageChops.multiply(_MASK, Image.new("L", (BODY, BODY), 90)))
    shadow.alpha_composite(sh, (off, off + 12))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(art, (off, off))
    return canvas
