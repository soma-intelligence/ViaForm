"""Viewport plates (3D area only, no UI) for the Liquid Glass Studio SwiftUI prototype.
Azure gpt-image-2.5-flare images/generations, 1536x1024 high. usage: python3 -I gen_plates.py <plate>
Callers hold /tmp/viaform-azure.lock (see run_plates.sh)."""
import base64, json, pathlib, subprocess, sys, time, urllib.error, urllib.request
HERE = pathlib.Path(__file__).resolve().parent
EP = ("https://temple-ai-provider.cognitiveservices.azure.com/openai/deployments/gpt-image-2.5-flare/"
      "images/generations?api-version=2025-04-01-preview")
BG = ("Clean studio CAD viewport render, no user interface at all, no text, no labels, no panels, no buttons, "
      "no logos, no watermark. Background: deep graphite soft vertical gradient from #121316 at the top to "
      "#1B1D22 at the bottom, a faint thin perspective grid on the ground plane fading into darkness. "
      "Generous empty dark space around the model on every side, the model occupies only the middle 45 percent "
      "of the frame width. ")
PLATES = {
 "hand": BG + ("Subject: a photoreal humanoid robotic hand, open palm slightly curled, three quarter view, "
   "matte white organic generative lattice finger links, dark grey joints, small black cylindrical micro motors "
   "at every knuckle, thin steel tendon cables running down to the wrist. The index finger is selected: a crisp "
   "glowing electric blue #3B82F6 outline around the whole index finger, and a thin blue rotation gizmo arc with "
   "an arrow head around its middle knuckle. Everything else neutral white and grey. Centred, wrist reaching the "
   "bottom edge."),
 "frame": BG + ("Subject: a photoreal 3-inch FPV quadcopter frame seen from a high three quarter view, organic "
   "generative topology optimised branching arms like bone, a carbon fibre centre stack with a small camera, "
   "smooth stress colour map on the arms from blue to green to yellow to red near the motor pad roots, four short "
   "vivid magenta #E0409B downward load arrows on the four motor pads, and four large translucent pale glass "
   "cylinders around the motor pads showing the propeller sweep keep-out zones. Centred."),
 "flight": ("Photoreal 3D flight simulation scene at dusk, wide cinematic frame, no user interface, no text, "
   "no logos, no watermark. A small dark 3-inch FPV quadcopter drone banking in mid flight through a glowing "
   "teal #14C9A0 rectangular race gate on the left third of the frame, more teal gates receding into the "
   "distance in the centre, orange obstacle poles, a dotted glowing teal flight path line curving from the "
   "bottom left foreground through the gates, faint thin white wind streamlines blowing across from the left, "
   "grass field, tree line, orange and purple sunset sky. The right third and the top band of the frame stay "
   "calm and uncluttered."),
 "mounted": ("Photoreal close up product render, no user interface, no text, no logos, no watermark: a small "
   "square green drone flight controller circuit board with a central black chip and a USB-C port, mounted on "
   "four black standoffs on the stack of a black carbon fibre quadcopter frame, three quarter top view, dark "
   "graphite studio background, soft rim light. A thin warm amber #F5A524 glowing outline around the board."),
 "ipadhand": BG + ("Subject: a photoreal humanoid robotic hand, palm facing the viewer and fingers gently "
   "curled, seen from slightly above, matte white generative lattice finger links, dark grey joints, small black "
   "micro motors at every knuckle, thin steel tendons. The thumb on the right side is selected: a crisp glowing "
   "electric blue #3B82F6 outline around the whole thumb and a large curved blue drag arrow next to its tip. "
   "Everything else neutral. The hand fills the centre, wrist reaching the bottom edge."),
}
def key():
    return subprocess.check_output(["az","cognitiveservices","account","keys","list","-n","temple-ai-provider",
        "-g","temple-ai-rg","--query","key1","-o","tsv"], text=True).strip()
def run(name, k):
    body = json.dumps({"prompt": PLATES[name], "size": "1536x1024", "quality": "high", "n": 1,
                       "output_format": "png"}).encode()
    for attempt in range(5):
        req = urllib.request.Request(EP, data=body, method="POST", headers={"api-key": k, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=900) as r:
                data = json.load(r)["data"][0]["b64_json"]
            (HERE / f"{name}.png").write_bytes(base64.b64decode(data)); print(name, "ok", flush=True); return True
        except urllib.error.HTTPError as e:
            print(name, "http", e.code, e.read().decode()[:200], flush=True)
            if e.code not in (429, 500, 502, 503, 504): return False
        except Exception as e:
            print(name, "error", e, flush=True)
        time.sleep(20 * (attempt + 1))
    return False
if __name__ == "__main__":
    sys.exit(0 if run(sys.argv[1], key()) else 1)
