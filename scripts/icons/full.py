"""Every ribbon icon in a picked direction (today: A). Nothing is installed into the app.

usage (from the repo root):  python3 scripts/icons/full.py A [name ...] [--fresh]
  -> scripts/icons/raw-A/<name>.png (render), then  python3 scripts/icons/build.py --direction A
The 8 review commands start from the picked candidates (copied from candidates/A/raw/); every other name is rendered
with the A style and candidates/A/raw/extrude.png as the style reference. An existing render is skipped unless named
or --fresh is given; a replaced render is kept as <name>.try<k>.png.
"""
import importlib, pathlib, shutil, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from directions import common  # noqa: E402
from candidates import keep_old  # noqa: E402

if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--fresh"]
    fresh = "--fresh" in sys.argv
    d = args[0]
    mod = importlib.import_module(f"directions.{d}")
    subjects = importlib.import_module(f"directions.{d}_full").SUBJECTS
    out = common.ICONS / f"raw-{d}"
    out.mkdir(exist_ok=True)
    ref = common.CAND / d / "raw" / f"{mod.STYLE_REF}.png"
    explicit = args[1:]
    names = explicit or list(subjects)
    k = None
    for n in names:
        dst = out / f"{n}.png"
        cand = common.CAND / d / "raw" / f"{n}.png"
        if not explicit and not fresh and not dst.exists() and cand.exists():
            shutil.copyfile(cand, dst)
            print(n, "from candidates", flush=True)
            continue
        if dst.exists() and not (explicit or fresh):
            continue
        k = k or common.key()
        subject = subjects[n].replace("BODY", mod.BODY).replace("ACCENT", mod.ACCENT)
        tmp = out / f"{n}.new.png"
        if common.edit(mod.STYLE + "The icon: " + subject, [ref], tmp, k, transparent=mod.TRANSPARENT):
            keep_old(dst)
            tmp.rename(dst)
