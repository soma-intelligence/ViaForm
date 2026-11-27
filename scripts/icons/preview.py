"""Contact sheet of the raw renders, big and at toolbar size on light and dark: preview.py out.png [name ...]"""
import pathlib, sys
from PIL import Image, ImageDraw
RAW = pathlib.Path(__file__).resolve().parent / "raw"
names = sys.argv[2:] or sorted(p.stem for p in RAW.glob("*.png"))
cols = min(6, len(names)); rows = (len(names) + cols - 1) // cols
C = 260
W = Image.new("RGBA", (cols * C, rows * (C + 100)), (242, 242, 245, 255))
d = ImageDraw.Draw(W)
for i, n in enumerate(names):
    x, y = (i % cols) * C, (i // cols) * (C + 100)
    im = Image.open(RAW / f"{n}.png").convert("RGBA"); im = im.crop(im.getchannel("A").point(lambda a: 255 if a > 40 else 0).getbbox())
    big = im.copy(); big.thumbnail((C - 30, C - 40), Image.LANCZOS); W.alpha_composite(big, (x + (C - big.width) // 2, y + 5))
    d.text((x + 8, y + C - 30), n, fill=(90, 90, 96))
    d.rectangle((x, y + C, x + C, y + C + 100), fill=(38, 39, 43))
    for s, ox in ((30, 20), (60, 70)):
        t = im.copy(); t.thumbnail((s, s), Image.LANCZOS)
        W.alpha_composite(t, (x + ox, y + C - 70 + (60 - s) // 2 - 10)) if False else None
        W.alpha_composite(t, (x + ox + 110, y + C + 20 + (60 - s) // 2))
W.save(sys.argv[1])
