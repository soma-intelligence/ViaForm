"""Final app icon masters for the picked options: 1 Glass lattice (primary) and 4 Graphite wire to solid (alternate).

usage (from the repo root):  python3 scripts/icons/app_masters.py [--fresh]     # Azure renders, then post
                             python3 scripts/icons/app_masters.py post          # post only
  -> scripts/icons/app/<primary|alternate>/
       light.png           1024 full-bleed square, no mask, no shadow (the asset catalog masks it)
       dark.png            dark appearance: darker field, same subject
       tinted.png          tinted appearance: desaturated grey artwork on a dark field
       preview-macos.png   light master masked to the macOS squircle on the 1024 grid, for review only
"""
import pathlib, shutil, sys
from PIL import Image, ImageOps

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from directions import common  # noqa: E402
from directions import app as appdir  # noqa: E402

OUT = common.ICONS / "app"
RAW = common.CAND / "app" / "raw"

FULL = ("Turn the reference image into a FULL-BLEED square app icon master: the artwork fills the entire square "
        "canvas edge to edge, seen straight on and flat, with NO tile, NO rounded corners, NO border, NO rim, NO "
        "visible tile edges and NO black margin anywhere (the operating system masks the corners itself). Keep the "
        "subject exactly the same shape, colours, lighting and soft blur as in the reference, centred, about 64 "
        "percent of the canvas wide, all of it inside the central 80 percent. Photoreal, ultra clean, no text, no "
        "letters, no logo, no watermark. ")
JOBS = {
    ("primary", "light"): ("glass-lattice", FULL + "The canvas is the frosted milky glass surface itself: soft white "
        "frost at the top, the glowing blue lattice node inside the glass in the centre, and a soft cobalt and "
        "electric blue glow rising from the bottom edge of the canvas like the glowing bottom bevel of the reference."),
    # the dark master starts from the full-bleed light master, so it stays full bleed (a first try from the tile
    # render came back as a tile again)
    ("primary", "dark"): ("primary/light", FULL + "Dark appearance of this exact full-bleed artwork, same composition, "
        "still no tile and no edges: the canvas is deep smoked near-black frosted glass "
        "(very dark charcoal #0E1014 with a subtle cool sheen), the lattice node inside stays vivid and luminous blue "
        "and cyan with a white-hot core, and a soft cobalt glow rises from the bottom edge of the canvas."),
    ("alternate", "dark"): ("graphite-wire", FULL + "Dark appearance: keep the reference as it is but make the "
        "background field darker, near black (#0A0B0D to #121418 soft vertical gradient) with the faint grid even "
        "fainter; the part, its blue wireframe half and its matte grey solid half stay exactly the same."),
}


def tinted(src):
    """iOS 18 style tinted variant: luminance only, contrast stretched, on a near-black field."""
    g = ImageOps.autocontrast(src.convert("L"), cutoff=0.5)
    return Image.merge("RGB", (g, g, g))


def post():
    for slot, opt in (("primary", "glass-lattice"), ("alternate", "graphite-wire")):
        d = OUT / slot
        d.mkdir(parents=True, exist_ok=True)
        if slot == "alternate" and not (d / "light.png").exists():
            # option 4 was rendered full bleed already: its raw render is the light master
            Image.open(RAW / f"{opt}.png").convert("RGB").save(d / "light.png", optimize=True)
        if (d / "dark.png").exists():
            tinted(Image.open(d / "dark.png")).save(d / "tinted.png", optimize=True)
        if (d / "light.png").exists():
            appdir.to_icon(Image.open(d / "light.png"), False).save(d / "preview-macos.png", optimize=True)
            for ap in ("dark", "tinted"):
                if (d / f"{ap}.png").exists():
                    appdir.to_icon(Image.open(d / f"{ap}.png"), False).save(d / f"preview-macos-{ap}.png",
                                                                             optimize=True)


if __name__ == "__main__":
    if sys.argv[1:2] != ["post"]:
        fresh = "--fresh" in sys.argv
        k = common.key()
        for (slot, ap), (opt, prompt) in JOBS.items():
            dst = OUT / slot / f"{ap}.png"
            if dst.exists() and not fresh:
                continue
            tmp = dst.with_name(f"{ap}.new.png")
            if common.edit(prompt, [OUT / f"{opt}.png" if "/" in opt else RAW / f"{opt}.png"], tmp, k, transparent=False):
                if dst.exists():
                    shutil.move(dst, dst.with_name(f"{ap}.prev.png"))
                tmp.rename(dst)
    post()
    print("app masters ->", OUT)
