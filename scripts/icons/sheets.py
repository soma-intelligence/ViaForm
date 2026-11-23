"""Contact sheets and an index page for the icon candidates.

usage (from the repo root):  python3 scripts/icons/sheets.py
  -> scripts/icons/candidates/sheets/tools-<A|B|C>.png   8 commands at 26, 52, 128 px on light and dark ribbons
     scripts/icons/candidates/sheets/app.png             app icon options at 1024 px, plus 64 px Dock rows
     scripts/icons/candidates/index.html                 everything on one page
python3 scripts/icons/sheets.py --full A
  -> scripts/icons/candidates/sheets/tools-A-full.png    every built icon in out-A at 26 and 52 px, light and dark
"""
import html, importlib, pathlib, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from directions import common  # noqa: E402
from directions import app as appdir  # noqa: E402

CAND = common.CAND
SHEETS = CAND / "sheets"
LIGHT, DARK = (0xF5, 0xF5, 0xF7), (0x1C, 0x1E, 0x22)
INK_L, INK_D = (0x3A, 0x3A, 0x3F), (0xB8, 0xBA, 0xC0)
DIRS = ["A", "B", "C"]


def font(px, bold=False):
    return ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", px) if not bold else \
        ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", px, index=1)


def icon(d, name, dark):
    p = CAND / d / f"{name}{'-dark' if dark else ''}.png"
    if not p.exists():
        p = CAND / d / f"{name}.png"
    return Image.open(p).convert("RGBA") if p.exists() else None


def tool_sheet(d):
    mod = importlib.import_module(f"directions.{d}")
    COL, LEFT = 190, 150
    rows = [(128, 176), (52, 96), (26, 66)]
    H_HEAD = 110
    band = sum(h for _, h in rows) + 24
    W = LEFT + COL * len(common.ORDER) + 20
    H = H_HEAD + 2 * band
    sheet = Image.new("RGBA", (W, H), (255, 255, 255, 255))
    dr = ImageDraw.Draw(sheet)
    dr.text((24, 22), mod.TITLE, font=font(30, True), fill=(20, 20, 24))
    dr.text((24, 64), mod.DESCRIPTION, font=font(17), fill=(90, 90, 96))
    for bi, dark in enumerate((False, True)):
        y0 = H_HEAD + bi * band
        bg, ink = (DARK, INK_D) if dark else (LIGHT, INK_L)
        dr.rectangle((0, y0, W, y0 + band), fill=bg)
        dr.text((20, y0 + 10), "Dark ribbon #1C1E22" if dark else "Light ribbon #F5F5F7", font=font(14), fill=ink)
        y = y0 + 34
        for size, h in rows:
            dr.text((20, y + (min(size, h) // 2) - 8), f"{size} px", font=font(15, True), fill=ink)
            for i, n in enumerate(common.ORDER):
                im = icon(d, n, dark)
                cx = LEFT + i * COL + COL // 2
                if im is None:
                    dr.text((cx - 30, y + 10), "missing", font=font(13), fill=(200, 60, 60))
                    continue
                s = common.small(im, size)
                sheet.alpha_composite(s, (cx - size // 2, y))
                if size == 26:
                    lab = n.upper()
                    tw = dr.textlength(lab, font=font(11, True))
                    dr.text((cx - tw / 2, y + 32), lab, font=font(11, True), fill=ink)
            y += h
    out = SHEETS / f"tools-{d}.png"
    sheet.convert("RGB").save(out, optimize=True)
    return out


def dock_row(icons, wall_dark):
    W, H = 1100, 230
    im = Image.new("RGBA", (W, H))
    top, bot = ((44, 52, 74), (18, 20, 28)) if wall_dark else ((206, 216, 236), (236, 226, 232))
    dr = ImageDraw.Draw(im)
    for y in range(H):
        t = y / H
        dr.line([(0, y), (W, y)], fill=tuple(int(top[c] + (bot[c] - top[c]) * t) for c in range(3)))
    n = len(icons)
    pad, gap, sz = 14, 64, 64
    dw = n * sz + (n - 1) * gap + 2 * pad + 40
    dx, dy = (W - dw) // 2, 70
    dock = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(dock).rounded_rectangle((dx, dy, dx + dw, dy + sz + 2 * pad), radius=24,
                                           fill=(40, 40, 46, 150) if wall_dark else (255, 255, 255, 120),
                                           outline=(255, 255, 255, 60), width=1)
    im.alpha_composite(dock)
    for i, (name, ic) in enumerate(icons):
        x = dx + pad + 20 + i * (sz + gap)
        im.alpha_composite(ic.resize((sz, sz), Image.LANCZOS), (x, dy + pad))
        lab = appdir.OPTIONS[name]["title"]
        f = font(11)
        tw = dr.textlength(lab, font=f)
        ImageDraw.Draw(im).text((x + sz / 2 - tw / 2, dy + sz + 2 * pad + 10), lab, font=f,
                                fill=(230, 232, 238) if wall_dark else (40, 40, 46))
    return im


def app_sheet():
    names = [n for n in appdir.OPTIONS if (CAND / "app" / f"{n}.png").exists()]
    icons = [(n, Image.open(CAND / "app" / f"{n}.png").convert("RGBA")) for n in names]
    cols = 3
    rows = (len(icons) + cols - 1) // cols
    CELL, LAB = 1024, 90
    W = cols * CELL
    dock_h = 230
    H = 120 + rows * (CELL + LAB) + 2 * dock_h + 40
    sheet = Image.new("RGBA", (W, H), (236, 237, 240, 255))
    dr = ImageDraw.Draw(sheet)
    dr.text((40, 34), "ViaForm app icon options (1024 px, macOS squircle on the Apple grid)", font=font(44, True),
            fill=(20, 20, 24))
    for i, (n, ic) in enumerate(icons):
        x, y = (i % cols) * CELL, 120 + (i // cols) * (CELL + LAB)
        sheet.alpha_composite(ic, (x, y))
        o = appdir.OPTIONS[n]
        dr.text((x + 100, y + CELL - 20), f"{i + 1}. {o['title']}", font=font(34, True), fill=(20, 20, 24))
        dr.text((x + 100, y + CELL + 24), o["desc"], font=font(22), fill=(80, 80, 88))
    y = 120 + rows * (CELL + LAB) + 20
    for k, dark in enumerate((False, True)):
        row = dock_row(icons, dark)
        row = row.resize((W, int(row.height * W / row.width)), Image.LANCZOS) if False else row
        sheet.alpha_composite(row, ((W - row.width) // 2, y + k * dock_h))
    out = SHEETS / "app.png"
    sheet.convert("RGB").save(out, optimize=True)
    # a true-size Dock strip too (the big sheet is scaled down when viewed)
    strip = Image.new("RGBA", (1100, 2 * dock_h))
    strip.alpha_composite(dock_row(icons, False), (0, 0))
    strip.alpha_composite(dock_row(icons, True), (0, dock_h))
    strip.convert("RGB").save(SHEETS / "app-dock-64.png", optimize=True)
    return out


def index_html():
    e = html.escape
    parts = ["<!doctype html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' "
             "content='width=device-width,initial-scale=1'><title>ViaForm icon candidates</title><style>"
             ":root{--bg:#fff;--fg:#141418;--mut:#6b6b73;--card:#f5f5f7;--dk:#1c1e22}"
             "body{margin:0;font:15px/1.5 -apple-system,system-ui,sans-serif;background:var(--bg);color:var(--fg)}"
             "main{max-width:1400px;margin:0 auto;padding:32px 16px 80px}h1{font-size:28px;margin:0 0 4px}"
             "h2{font-size:21px;margin:48px 0 4px}p{color:var(--mut);margin:0 0 16px}"
             "img.sheet{width:100%;height:auto;border-radius:12px;border:1px solid #e4e4e8}"
             ".grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px;margin:12px 0}"
             ".cell{background:var(--card);border-radius:12px;padding:12px;text-align:center;font-size:12px;"
             "color:var(--mut)}.cell.dark{background:var(--dk);color:#b8bac0}.cell img{width:96px;height:96px;"
             "display:block;margin:0 auto 6px}.app{display:grid;grid-template-columns:repeat(auto-fill,"
             "minmax(260px,1fr));gap:20px}.app figure{margin:0;background:var(--card);border-radius:16px;padding:16px}"
             ".app img{width:100%;height:auto}.app figcaption b{display:block;color:var(--fg)}"
             "</style></head><body><main><h1>ViaForm icon candidates</h1><p>Real renders for review. Nothing is "
             "installed in the app. Tool icons: 8 representative commands per direction. Sheets show 26, 52 and "
             "128 px on light and dark ribbons.</p>"]
    for d in DIRS:
        mod = importlib.import_module(f"directions.{d}")
        parts.append(f"<h2>{e(mod.TITLE)}</h2><p>{e(mod.DESCRIPTION)}</p>"
                     f"<img class='sheet' src='sheets/tools-{d}.png' alt='{e(mod.TITLE)} contact sheet'>")
        for dark in (False, True):
            parts.append("<div class='grid'>")
            for n in common.ORDER:
                f = f"{d}/{n}-dark.png" if dark and (CAND / d / f"{n}-dark.png").exists() else f"{d}/{n}.png"
                parts.append(f"<div class='cell{' dark' if dark else ''}'><img src='{f}' alt='{n}'>{n}</div>")
            parts.append("</div>")
    parts.append("<h2>App icon options</h2><p>1024 px masters on the macOS grid, then 64 px in a Dock.</p>"
                 "<div class='app'>")
    for i, (n, o) in enumerate(appdir.OPTIONS.items()):
        if (CAND / "app" / f"{n}.png").exists():
            parts.append(f"<figure><img src='app/{n}.png' alt='{e(o['title'])}'><figcaption><b>{i + 1}. "
                         f"{e(o['title'])}</b>{e(o['desc'])}</figcaption></figure>")
    parts.append("</div><h2>In the Dock (64 px)</h2><img class='sheet' src='sheets/app-dock-64.png' alt='Dock rows'>"
                 "<h2>App sheet</h2><img class='sheet' src='sheets/app.png' alt='App icon sheet'></main></body></html>")
    (CAND / "index.html").write_text("".join(parts))


def full_sheet(d):
    src = common.ICONS / f"out-{d}"
    names = sorted(p.stem for p in src.glob("*.png"))
    mod = importlib.import_module(f"directions.{d}")
    cols, CW, CH = 8, 210, 120
    rows = (len(names) + cols - 1) // cols
    band = rows * CH + 40
    W, HH = cols * CW + 40, 100
    sheet = Image.new("RGBA", (W, HH + 2 * band), (255, 255, 255, 255))
    dr = ImageDraw.Draw(sheet)
    dr.text((24, 22), f"{mod.TITLE}: full set ({len(names)} icons)", font=font(30, True), fill=(20, 20, 24))
    dr.text((24, 62), f"Built PNGs from out-{d}/ at 52 px and 26 px", font=font(17), fill=(90, 90, 96))
    for bi, dark in enumerate((False, True)):
        y0 = HH + bi * band
        bg, ink = (DARK, INK_D) if dark else (LIGHT, INK_L)
        dr.rectangle((0, y0, W, y0 + band), fill=bg)
        dr.text((20, y0 + 10), "Dark ribbon #1C1E22" if dark else "Light ribbon #F5F5F7", font=font(14), fill=ink)
        for i, n in enumerate(names):
            im = Image.open(src / f"{n}.png").convert("RGBA")
            x, y = 20 + (i % cols) * CW, y0 + 36 + (i // cols) * CH
            sheet.alpha_composite(common.small(im, 52), (x + 40, y))
            sheet.alpha_composite(common.small(im, 26), (x + 120, y + 13))
            f = font(11, True)
            tw = dr.textlength(n.upper(), font=f)
            dr.text((x + 100 - tw / 2, y + 64), n.upper(), font=f, fill=ink)
    out = SHEETS / f"tools-{d}-full.png"
    sheet.convert("RGB").save(out, optimize=True)
    return out


if __name__ == "__main__":
    SHEETS.mkdir(parents=True, exist_ok=True)
    if "--full" in sys.argv:
        print(full_sheet(sys.argv[sys.argv.index("--full") + 1]))
        sys.exit(0)
    for d in DIRS:
        print(tool_sheet(d))
    print(app_sheet())
    index_html()
    print(CAND / "index.html")
