# Cuts the 3D model areas out of the concept images and keys out their
# light background, so the SwiftUI viewport draws its own background,
# grid and furniture around them. Run: python3 tools/prep_assets.py
from pathlib import Path
from PIL import Image, ImageFilter, ImageChops, ImageDraw

HERE = Path(__file__).resolve().parent.parent
CONCEPTS = HERE.parent / "concepts"
OUT = HERE / "Sources" / "DirectCanvas" / "Resources"
OUT.mkdir(parents=True, exist_ok=True)


def keyed(src, box, erase=(), threshold=9, soft=14, keep_shadow=True):
    im = Image.open(CONCEPTS / src).convert("RGB").crop(box)
    w, h = im.size
    # background model: per row, mean of the leftmost and rightmost 8 px columns
    px = im.load()
    bg = Image.new("RGB", (w, h))
    bp = bg.load()
    for y in range(h):
        cols = [px[x, y] for x in list(range(0, 8)) + list(range(w - 8, w))]
        m = tuple(sum(c[i] for c in cols) // len(cols) for i in range(3))
        for x in range(w):
            bp[x, y] = m
    bg = bg.filter(ImageFilter.GaussianBlur(6))
    diff = ImageChops.difference(im, bg).convert("L")
    # background = bg-like pixels connected to the crop border (flood fill),
    # so white model parts stay fully opaque
    binary = diff.point(lambda v: 255 if v < threshold else 0)
    W = 77
    for x in range(0, w, 6):
        for y in (0, h - 1):
            if binary.getpixel((x, y)) == 255:
                ImageDraw.floodfill(binary, (x, y), W, thresh=0)
    for y in range(0, h, 6):
        for x in (0, w - 1):
            if binary.getpixel((x, y)) == 255:
                ImageDraw.floodfill(binary, (x, y), W, thresh=0)
    alpha = binary.point(lambda v: 0 if v == W else 255)
    alpha = alpha.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(1.0))
    d = ImageDraw.Draw(alpha)
    for r in erase:
        d.rectangle(r, fill=0)
    # feather the crop border so nothing ends on a hard edge
    edge = Image.new("L", (w, h), 0)
    ImageDraw.Draw(edge).rectangle((10, 10, w - 11, h - 11), fill=255)
    edge = edge.filter(ImageFilter.GaussianBlur(6))
    alpha = ImageChops.multiply(alpha, edge)
    out = im.convert("RGBA")
    out.putalpha(alpha)
    return out


def save(img, name):
    img.save(OUT / name)
    print(name, img.size)


# Design: robotic hand, under the context menu
save(keyed("1-design.png", (385, 172, 945, 912)), "hand_design.png")

# Generative: frame with stress map, labels and arrows erased (drawn natively)
fx, fy = 220, 150
labels = [(380, 128, 470, 172), (650, 232, 690, 268), (965, 155, 1040, 196),
          (290, 492, 360, 532), (1010, 545, 1080, 584)]
arrows = [(371, 128, 390, 180), (944, 150, 964, 214), (658, 266, 680, 330),
          (266, 492, 285, 553), (983, 545, 1002, 608)]
erase = [(a - fx, b - fy, c - fx, d - fy) for a, b, c, d in labels + arrows]
save(keyed("2-generative.png", (fx, fy, 1085, 712), erase=erase), "frame_stress.png")

# Variant thumbnails from the gallery strip
cards = [(66, 300), (314, 528), (548, 764), (782, 998), (1016, 1232), (1251, 1476)]
for i, (a, b) in enumerate(cards):
    im = Image.open(CONCEPTS / "2-generative.png").convert("RGB").crop((a + 6, 806, b - 6, 922))
    im.save(OUT / f"variant_{i}.png")
print("variants", len(cards))

# Electronics: frame thumbnail for the board link card
Image.open(CONCEPTS / "4-electronics.png").convert("RGB").crop((1246, 124, 1510, 318)).save(OUT / "board_in_frame.png")

# Simulation: drone only
save(keyed("3-simulation.png", (722, 516, 816, 596), threshold=40, soft=6), "drone_sim.png")

# iPad: hand, value bubble and suggestion capsule erased
ix, iy = 465, 92
erase = [(1058 - ix, 412 - iy, 1150 - ix, 450 - iy), (878 - ix, 652 - iy, 1220 - ix, 760 - iy)]
save(keyed("5-ipad.png", (ix, iy, 1090, 960), erase=erase), "hand_ipad.png")
