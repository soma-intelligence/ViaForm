"""Direction B: monochrome line-and-fill glyphs in the SF Symbols spirit. Flat, even stroke weight, rounded caps; the
acted-on part is the only filled area, in accent blue. Post-processing splits ink from accent so the ink can follow the
appearance (near-black on light, near-white on dark) like a template image, and the blue stays blue."""
from PIL import Image, ImageDraw
from . import common

TITLE = "B. Line glyphs"
DESCRIPTION = ("Flat monochrome line-and-fill glyphs in the SF Symbols spirit, even stroke weight, the acted-on part "
               "filled in accent blue. Ink follows light and dark mode.")
BODY = "drawn in plain black outline strokes only (unfilled)"
ACCENT = "a solid flat filled shape in pure blue #2F6BFF"
STYLE = (
    "Draw a single flat vector icon glyph for a professional CAD application toolbar, in the exact spirit of "
    "Apple SF Symbols: monochrome line art made of bold strokes of one uniform weight (about 7 percent of the icon "
    "width), rounded caps and rounded joins, clean geometric construction, simple isometric line drawing of the "
    "object. If a reference image is given, copy only its stroke weight and two-colour scheme, not its shape. Two "
    "colours only: pure black #000000 for all strokes, and pure blue #2F6BFF for the one filled shape that shows "
    "the part the command acts on. No shading, no gradients, no 3D render, no shadows, no grey, no texture, no "
    "thin hairlines, no tiny details: readable at 26 pixels. Centred, filling about 85% of the square. No text, "
    "no letters, no numbers, no logo, no frame, no background plate. Isolated on a fully transparent background. "
)
TRANSPARENT = True
STYLE_REF = "extrude"

INK_LIGHT = (0x1D, 0x1D, 0x1F)
INK_DARK = (0xEC, 0xEC, 0xEF)
BLUE_LIGHT = (0x2F, 0x6B, 0xFF)
BLUE_DARK = (0x4D, 0x84, 0xFF)


def seed(path):
    s = 1024
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    w = 64
    top = [(512, 200), (790, 360), (512, 520), (234, 360)]
    d.polygon(top, fill=BLUE_LIGHT)
    for a, b in ((top[3], (234, 680)), (top[2], (512, 840)), (top[1], (790, 680)), ((234, 680), (512, 840)),
                 ((512, 840), (790, 680))):
        d.line([a, b], fill=(0, 0, 0), width=w)
    for p in (top[1], top[2], top[3], (234, 680), (512, 840), (790, 680)):
        d.ellipse((p[0] - w / 2, p[1] - w / 2, p[0] + w / 2, p[1] + w / 2), fill=(0, 0, 0))
    im.save(path)


def split(raw):
    """Return (ink_alpha, blue_alpha) masks. Works whether the render came back transparent or on white."""
    im = raw.convert("RGBA")
    px = im.load()
    W, H = im.size
    ink = Image.new("L", im.size, 0)
    blue = Image.new("L", im.size, 0)
    pi, pb = ink.load(), blue.load()
    opaque_bg = im.getchannel("A").getextrema()[0] > 200
    for y in range(H):
        for x in range(W):
            r, g, b, a = px[x, y]
            if opaque_bg:  # white background: coverage from darkness / saturation
                cov = 255 - min(r, g, b)
                a = cov
            if a < 8:
                continue
            sat = b - (r + g) / 2  # blue-ness
            if sat > 45:
                pb[x, y] = a
            else:
                lum = (r + g + b) / 3
                # light grey haze (soft shadow the model sometimes adds) is not ink
                if a < 128 and lum > 90:
                    continue
                pi[x, y] = a if lum < 90 else int(a * max(0.0, min(1.0, (170 - lum) / 80)))
    return ink, blue


def tint(ink, blue, ink_rgb, blue_rgb):
    out = Image.new("RGBA", ink.size, ink_rgb + (0,))
    out.putalpha(ink)
    b = Image.new("RGBA", ink.size, blue_rgb + (0,))
    b.putalpha(blue)
    out.alpha_composite(b)
    return out


def post(raw):
    raw = raw.convert("RGBA").resize((512, 512), Image.LANCZOS)
    ink, blue = split(raw)
    return {"": common.trim_square(tint(ink, blue, INK_LIGHT, BLUE_LIGHT)),
            "-dark": common.trim_square(tint(ink, blue, INK_DARK, BLUE_DARK))}

OVERRIDES = {n: common.RETAKES[n] for n in ("joint", "section")}
