"""Shared pieces for the icon candidate directions: Azure client, the shared lock, the 8 review commands, helpers.

Azure gpt-image-2.5 (images/edits) on temple-ai-provider, one call at a time under the shared lock
/tmp/viaform-azure.lock (a directory, created with mkdir, removed after the call, like the other ViaForm generators).
The key is read from the Azure CLI at run time and never written to disk.
"""
import base64, json, os, pathlib, subprocess, time, urllib.error, urllib.request, uuid

from PIL import Image, ImageDraw, ImageFilter

ICONS = pathlib.Path(__file__).resolve().parents[1]
CAND = ICONS / "candidates"
EP = ("https://temple-ai-provider.cognitiveservices.azure.com/openai/deployments/gpt-image-2.5-flare/"
      "images/edits?api-version=2025-04-01-preview")
LOCK = "/tmp/viaform-azure.lock"
STALE = 20 * 60  # a lock older than this is left over from a crashed run

ACCENT = (0x2F, 0x6B, 0xFF)

# The 8 review commands. "BODY" and "ACCENT" are filled in by each direction (how a neutral part and the acted-on
# part look in that style), so the subjects stay the same across directions.
SUBJECTS = {
    "sketch": "A thin flat square sheet lying in a three-quarter top view; a closed rectangle outline drawn on its top "
              "face with one bold ACCENT stroke, and a short chunky pencil resting diagonally on the sheet, its tip on "
              "the rectangle corner. The sheet is BODY.",
    "extrude": "A rectangular block rising out of a flat rectangular outline on the ground; the block's top face is "
               "ACCENT and one short thick ACCENT arrow points straight up out of the top face. The block sides are BODY.",
    "revolve": "A flat L-shaped profile standing upright next to a vertical axis line; a thick ACCENT circular arrow "
               "sweeps around the axis, showing the profile turning into a solid ring. The profile is BODY.",
    "fillet": "A solid L-shaped block (a thick floor and a thick wall); the inside corner edge where the wall meets the "
              "floor is a smooth large rounded fillet coloured ACCENT. Everything else is BODY.",
    "hole": "A thick square plate with one large round hole drilled straight through its centre; the inner wall of the "
            "hole is ACCENT. The plate is BODY.",
    "joint": "Two blocks side by side, slightly apart, connected by one thick round pin through both; the pin is ACCENT "
             "with a short curved ACCENT arrow around it showing rotation. The blocks are BODY.",
    "section": "A cube sliced vertically in half with the front half removed; the large flat cut face is ACCENT. The "
               "remaining half of the cube is BODY.",
    "measure": "A block with one thick ACCENT dimension line running along its top front edge, with bold arrowheads at "
               "both ends and two short extension ticks. The block is BODY.",
}
ORDER = list(SUBJECTS)

# Simpler retakes for subjects that came back too busy or unclear at 26 px in a direction's first pass.
# A direction opts in with OVERRIDES = {name: RETAKES[name]}.
RETAKES = {
    "revolve": "One single bold shape: a thick upright vertical axis line, and around it one large thick ACCENT "
               "circular arrow seen in perspective (an ellipse with a bold arrowhead) that wraps around the axis. "
               "Next to the axis, one small flat rectangular profile that is BODY. Nothing else.",
    "joint": "Two thick plates that are BODY, overlapping at one corner, joined by one large round ACCENT pin through "
             "the overlap, seen in isometric view. Nothing else: no arrows, no extra parts.",
    "section": "A cube cut cleanly in half by a vertical plane: only the back half of the cube remains, and its large "
               "flat cut face, facing the viewer at the front, is ACCENT; the outline of the thin cutting plane "
               "extends slightly beyond the cube on all sides. The remaining half is BODY.",
    "measure": "A wide flat block that is BODY, and floating just above its top front edge one very thick bold ACCENT "
               "dimension arrow with two large arrowheads, one at each end, and two short thick ACCENT end ticks. "
               "The arrow is the main feature, as wide as the block.",
}


def key():
    return subprocess.check_output(["az", "cognitiveservices", "account", "keys", "list", "-n", "temple-ai-provider",
                                    "-g", "temple-ai-rg", "--query", "key1", "-o", "tsv"], text=True).strip()


def lock():
    while True:
        try:
            os.mkdir(LOCK)
            return
        except FileExistsError:
            try:
                if time.time() - os.stat(LOCK).st_mtime > STALE:
                    os.rmdir(LOCK)
                    continue
            except OSError:
                pass
            time.sleep(3)


def unlock():
    try:
        os.rmdir(LOCK)
    except OSError:
        pass


def edit(prompt, refs, out, k, transparent=True):
    """One images/edits call under the shared lock, with backoff on 429 and 5xx. Writes out, returns True on success."""
    fields = {"prompt": prompt, "size": "1024x1024", "quality": "high", "output_format": "png", "n": "1"}
    if transparent:
        fields["background"] = "transparent"
    b = uuid.uuid4().hex
    body = b"".join(f"--{b}\r\nContent-Disposition: form-data; name=\"{f}\"\r\n\r\n{v}\r\n".encode()
                    for f, v in fields.items())
    for i, r in enumerate(refs):
        body += (f"--{b}\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"ref{i}.png\"\r\n"
                 f"Content-Type: image/png\r\n\r\n").encode() + pathlib.Path(r).read_bytes() + b"\r\n"
    body += f"--{b}--\r\n".encode()
    for attempt in range(8):
        lock()
        try:
            req = urllib.request.Request(EP, data=body, method="POST",
                                         headers={"api-key": k, "Content-Type": f"multipart/form-data; boundary={b}"})
            with urllib.request.urlopen(req, timeout=600) as r:
                data = json.load(r)["data"][0]["b64_json"]
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_bytes(base64.b64decode(data))
            print(out.relative_to(ICONS), "ok", flush=True)
            return True
        except urllib.error.HTTPError as e:
            msg = e.read().decode(errors="replace")[:200]
            print(out.name, "http", e.code, msg, flush=True)
            if e.code not in (408, 429, 500, 502, 503, 504):
                return False
        except Exception as e:  # timeouts, resets
            print(out.name, "error", type(e).__name__, flush=True)
        finally:
            unlock()
        time.sleep(min(30 * (attempt + 1), 180))
    return False


def trim_square(im, margin=0.06, size=256, thresh=40):
    """Crop to the clearly opaque pixels, centre on a transparent square with an even margin, resize."""
    im = im.convert("RGBA")
    box = im.getchannel("A").point(lambda a: 255 if a > thresh else 0).getbbox()
    if box:
        im = im.crop(box)
    side = int(max(im.size) * (1 + 2 * margin))
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.alpha_composite(im, ((side - im.width) // 2, (side - im.height) // 2))
    return sq.resize((size, size), Image.LANCZOS)


def small(im, px):
    """Downscale to a toolbar size the way build.py does (Lanczos, light unsharp)."""
    s = im.resize((px, px), Image.LANCZOS)
    return s.filter(ImageFilter.UnsharpMask(radius=0.6, percent=40, threshold=2)) if px <= 64 else s


def iso_seed(path, top, left, right, edge=None, size=1024):
    """A plain isometric cube on transparency, used only to seed a direction's palette before its first good icon."""
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c, r = size / 2, size * 0.3
    import math
    dx, dy = r * math.cos(math.radians(30)), r * 0.5
    T = [(c, c - 2 * dy - r * 0.1), (c + dx, c - dy - r * 0.1), (c, c - r * 0.1), (c - dx, c - dy - r * 0.1)]
    L = [T[3], T[2], (T[2][0], T[2][1] + r), (T[3][0], T[3][1] + r)]
    R = [T[2], T[1], (T[1][0], T[1][1] + r), (T[2][0], T[2][1] + r)]
    for poly, col in ((L, left), (R, right), (T, top)):
        d.polygon(poly, fill=col, outline=edge, width=6 if edge else 0)
    im.save(path)
