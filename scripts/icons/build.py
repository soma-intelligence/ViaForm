"""Trims the generated renders to their object, squares them and writes the toolbar PNGs.

usage (from the repo root):  python3 scripts/icons/build.py
                             -> apple/Resources/ToolIcons/<name>.png (128 px, shown at 28 pt in the ribbon)
"""
import pathlib
from PIL import Image, ImageFilter

HERE = pathlib.Path(__file__).resolve().parent
RAW = HERE / "raw"
DST = HERE.parents[1] / "apple" / "Resources" / "ToolIcons"
SIZE, MARGIN = 128, 0.04


def build(src: pathlib.Path) -> None:
    im = Image.open(src).convert("RGBA")
    # Bounding box of the clearly opaque pixels, so a faint haze at the edge does not shrink the object.
    box = im.getchannel("A").point(lambda a: 255 if a > 40 else 0).getbbox()
    im = im.crop(box)
    side = int(max(im.size) * (1 + 2 * MARGIN))
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.alpha_composite(im, ((side - im.width) // 2, (side - im.height) // 2))
    sq = sq.resize((SIZE, SIZE), Image.LANCZOS).filter(ImageFilter.UnsharpMask(radius=1, percent=40, threshold=2))
    sq.save(DST / src.name, optimize=True)


if __name__ == "__main__":
    DST.mkdir(parents=True, exist_ok=True)
    names = sorted(p.stem for p in RAW.glob("*.png"))
    for n in names:
        build(RAW / f"{n}.png")
    print(len(names), "icons ->", DST)
