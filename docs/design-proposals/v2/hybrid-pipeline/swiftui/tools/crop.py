# Cuts the 3D-only areas out of the accepted concept images into package art.
import sys
from PIL import Image, ImageDraw, ImageFilter
C = "../../concepts/"
OUT = "../Sources/HybridPipeline/Resources/Art/"

def feather(im, px):
    w, h = im.size
    m = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(m)
    d.rectangle([px, px, w - px, h - px], fill=255)
    m = m.filter(ImageFilter.GaussianBlur(px / 2))
    im = im.convert("RGBA")
    im.putalpha(m)
    return im

def blurpatch(im, box, r=18):
    # Soft-edged blur so the baked overlay card leaves no hard box behind.
    pad = 30
    big = (max(box[0] - pad, 0), max(box[1] - pad, 0), min(box[2] + pad, im.width), min(box[3] + pad, im.height))
    blurred = im.crop(big).filter(ImageFilter.GaussianBlur(r * 2))
    m = Image.new("L", blurred.size, 0)
    ImageDraw.Draw(m).rectangle([box[0] - big[0], box[1] - big[1], box[2] - big[0], box[3] - big[1]], fill=255)
    m = m.filter(ImageFilter.GaussianBlur(pad / 2))
    im.paste(blurred, big[:2], m)

ipad = Image.open(C + "5-ipad.png").convert("RGB")
hand = ipad.crop((440, 128, 1012, 886))
d = ImageDraw.Draw(hand)
d.rectangle([0, 0, 34, 175], fill=hand.getpixel((60, 20)))
hand = feather(hand, 34)
hand.save(OUT + "hand.png")

gen = Image.open(C + "2-generative.png").convert("RGB")
frame = gen.crop((385, 150, 1052, 612))
fd = ImageDraw.Draw(frame)
fd.rectangle([185, 436, 520, 462], fill=frame.getpixel((300, 455)))
# Baked load labels: removed here, drawn as live SwiftUI text instead.
fd.rectangle([0, 28, 86, 56], fill=frame.getpixel((95, 40)))
fd.rectangle([524, 8, 636, 36], fill=frame.getpixel((520, 20)))
frame = feather(frame, 26)
frame.save(OUT + "frame.png")
gen.crop((312, 712, 447, 794)).save(OUT + "tile.png")
gen.crop((772, 853, 902, 918)).save(OUT + "tile_applied.png")

sim = Image.open(C + "3-simulation.png").convert("RGB")
course = sim.crop((273, 143, 1222, 681))
for b in [(2, 2, 205, 112), (725, 4, 949, 184), (2, 462, 188, 536)]:
    blurpatch(course, b, 40)
    blurpatch(course, b, 40)
course.save(OUT + "course.png")

pcb = Image.open(C + "4-electronics.png").convert("RGB")
pcb.crop((982, 216, 1212, 388)).save(OUT + "link3d.png")
