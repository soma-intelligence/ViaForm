"""Crop the 3D object areas out of the concept images (viewport placeholders only).
Overlays baked into a crop are painted over by row interpolation, then edges are feathered."""
from PIL import Image, ImageFilter, ImageDraw
import os, sys
C = os.path.join(os.path.dirname(__file__), "../../concepts")
OUT = os.path.join(os.path.dirname(__file__), "../Sources/ProRibbon/Resources/Viewport")

def inpaint(im, box, side='l'):
    x0, y0, x1, y1 = box
    px = im.load()
    if side == 'v':
        for x in range(x0, x1):
            a = px[x, y0 - 2]; b = px[x, y1 + 2]
            for y in range(y0, y1):
                t = (y - y0) / max(1, (y1 - y0))
                px[x, y] = tuple(int(a[i] * (1 - t) + b[i] * t) for i in range(4))
        return
    for y in range(y0, y1):
        a = px[x0 - 2, y] if side == 'l' else px[x1 + 2, y]; b = a
        for x in range(x0, x1):
            t = (x - x0) / max(1, (x1 - x0))
            px[x, y] = tuple(int(a[i] * (1 - t) + b[i] * t) for i in range(4))

def feather(im, r=28, sides="lrtb"):
    w, h = im.size
    m = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(m)
    d.rectangle([r if "l" in sides else 0, r if "t" in sides else 0,
                 w - (r if "r" in sides else 0), h - (r if "b" in sides else 0)], fill=255)
    m = m.filter(ImageFilter.GaussianBlur(r / 2))
    im.putalpha(m)
    return im

def job(src, box, name, paints=(), fe="lrtb", r=28):
    im = Image.open(os.path.join(C, src)).convert("RGBA").crop(box)
    for p in paints:
        inpaint(im, (p[0] - box[0], p[1] - box[1], p[2] - box[0], p[3] - box[1]), p[4] if len(p) > 4 else 'l')
    if fe:
        im = feather(im, r, fe)
    im.save(os.path.join(OUT, name))
    print(name, im.size)

job("1-design.png", (470, 200, 1010, 838), "hand_desk.png", paints=[(715, 323, 778, 357, 'v')], fe="lrtb")
job("2-generative.png", (285, 255, 915, 770), "drone_stress.png")
job("3-simulation.png", (330, 190, 1366, 652), "sim_scene.png", fe="")
job("4-electronics.png", (783, 330, 1304, 832), "board_3d.png", fe="")
job("5-ipad-hand.png", (340, 236, 915, 892), "hand_touch.png", paints=[(425, 236, 541, 340)], fe="lrtb")
for i, b in enumerate([(1085, 243, 1213, 345), (1232, 243, 1361, 345), (1379, 243, 1508, 345),
                       (1085, 411, 1213, 513), (1232, 411, 1361, 513), (1379, 411, 1508, 513)]):
    job("2-generative.png", b, f"outcome_{i}.png", fe="")
