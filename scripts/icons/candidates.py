"""Icon candidates for review (nothing here is installed into the app).

usage (from the repo root):
  python3 scripts/icons/candidates.py A|B|C [name ...] [--fresh]   # tool icons of one direction
  python3 scripts/icons/candidates.py app [option ...] [--fresh]   # app icon options
  python3 scripts/icons/candidates.py post A|B|C|app               # redo post-processing only, no Azure calls
  -> scripts/icons/candidates/<dir>/raw/<name>.png (render), candidates/<dir>/<name>.png (processed)
Then python3 scripts/icons/sheets.py for the contact sheets and index.html.

Tool icons: the direction's seed palette is the first reference; once its STYLE_REF icon exists (extrude), that
render becomes the style reference for the rest so the set stays consistent. An existing render is skipped unless
named explicitly or --fresh is given; a replaced render is kept as raw/<name>.try<k>.png.
"""
import importlib, pathlib, sys
from PIL import Image

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from directions import common  # noqa: E402
from directions import app as appdir  # noqa: E402


def keep_old(p):
    if p.exists():
        i = 1
        while p.with_name(f"{p.stem}.try{i}.png").exists():
            i += 1
        p.rename(p.with_name(f"{p.stem}.try{i}.png"))


def post_tool(d, mod, name):
    raw = common.CAND / d / "raw" / f"{name}.png"
    if raw.exists():
        for suffix, im in mod.post(Image.open(raw)).items():
            im.save(common.CAND / d / f"{name}{suffix}.png", optimize=True)


def post_app(name):
    raw = common.CAND / "app" / "raw" / f"{name}.png"
    if raw.exists():
        appdir.to_icon(Image.open(raw), appdir.OPTIONS[name]["glass"]).save(common.CAND / "app" / f"{name}.png",
                                                                             optimize=True)


def run_tools(d, names, fresh, k):
    mod = importlib.import_module(f"directions.{d}")
    out = common.CAND / d
    (out / "raw").mkdir(parents=True, exist_ok=True)
    seed = out / "raw" / "_seed.png"
    if not seed.exists():
        mod.seed(seed)
    explicit = bool(names)
    names = names or common.ORDER
    names = sorted(names, key=lambda n: n != mod.STYLE_REF)  # style reference first
    for n in names:
        raw = out / "raw" / f"{n}.png"
        if raw.exists() and not (explicit or fresh):
            post_tool(d, mod, n)
            continue
        styleref = out / "raw" / f"{mod.STYLE_REF}.png"
        refs = [styleref] if (n != mod.STYLE_REF and styleref.exists()) else [seed]
        subject = getattr(mod, "OVERRIDES", {}).get(n, common.SUBJECTS[n]).replace("BODY", mod.BODY).replace("ACCENT", mod.ACCENT)
        tmp = raw.with_name(f"{n}.new.png")
        if common.edit(mod.STYLE + "The icon: " + subject, refs, tmp, k, transparent=mod.TRANSPARENT):
            keep_old(raw)
            tmp.rename(raw)
            post_tool(d, mod, n)


def run_app(names, fresh, k):
    out = common.CAND / "app"
    explicit = bool(names)
    for n in names or list(appdir.OPTIONS):
        o = appdir.OPTIONS[n]
        raw = out / "raw" / f"{n}.png"
        if raw.exists() and not (explicit or fresh):
            post_app(n)
            continue
        refs = [appdir.GLASS_REF] if o["glass"] else [out / "raw" / "_seed.png"]
        if not o["glass"] and not refs[0].exists():
            refs[0].parent.mkdir(parents=True, exist_ok=True)
            Image.new("RGB", (1024, 1024), (128, 128, 132)).save(refs[0])  # neutral canvas: the prompt does the work
        tmp = raw.with_name(f"{n}.new.png")
        if common.edit(o["prompt"], refs, tmp, k, transparent=False):
            keep_old(raw)
            tmp.rename(raw)
            post_app(n)


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--fresh"]
    fresh = "--fresh" in sys.argv
    if args[0] == "post":
        d = args[1]
        if d == "app":
            for n in appdir.OPTIONS:
                post_app(n)
        else:
            mod = importlib.import_module(f"directions.{d}")
            for n in common.ORDER:
                post_tool(d, mod, n)
        sys.exit(0)
    k = common.key()
    if args[0] == "app":
        run_app(args[1:], fresh, k)
    else:
        run_tools(args[0], args[1:], fresh, k)
