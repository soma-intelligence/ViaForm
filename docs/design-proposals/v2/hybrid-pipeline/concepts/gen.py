"""Hybrid Pipeline concept screens via Azure gpt-image-2.5-flare (images/generations).
usage: python3 gen.py <name> [suffix]   prompts live in prompts.json next to this file.
Every call holds /tmp/viaform-azure.lock (shared with other agents)."""
import base64, json, os, pathlib, signal, subprocess, sys, time, urllib.error, urllib.request

HERE = pathlib.Path(__file__).resolve().parent
EP = ("https://temple-ai-provider.cognitiveservices.azure.com/openai/deployments/gpt-image-2.5-flare/"
      "images/generations?api-version=2025-04-01-preview")
LOCK = "/tmp/viaform-azure.lock"

def key():
    return subprocess.check_output(["az", "cognitiveservices", "account", "keys", "list", "-n", "temple-ai-provider",
                                    "-g", "temple-ai-rg", "--query", "key1", "-o", "tsv"], text=True).strip()

def acquire():
    while True:
        try:
            os.mkdir(LOCK); return
        except FileExistsError:
            time.sleep(3)

def release(*_):
    try: os.rmdir(LOCK)
    except OSError: pass

def call(prompt, k):
    body = json.dumps({"prompt": prompt, "size": "1536x1024", "quality": "high", "n": 1, "output_format": "png"}).encode()
    for attempt in range(6):
        acquire()
        try:
            req = urllib.request.Request(EP, data=body, method="POST", headers={"api-key": k, "Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=900) as r:
                return base64.b64decode(json.load(r)["data"][0]["b64_json"])
        except urllib.error.HTTPError as e:
            print("http", e.code, e.read().decode()[:200], flush=True)
            if e.code not in (429, 500, 502, 503, 504): return None
        except Exception as e:
            print("error", e, flush=True)
        finally:
            release()
        time.sleep(20 * (attempt + 1))
    return None

if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *a: (release(), sys.exit(1)))
    prompts = json.loads((HERE / "prompts.json").read_text())
    name = sys.argv[1]; suffix = sys.argv[2] if len(sys.argv) > 2 else ""
    p = (prompts["common_ipad"] if name.startswith("5") else prompts["common"]) + " " + prompts[name]
    img = call(p, key())
    if img:
        out = HERE / f"{name}{suffix}.png"; out.write_bytes(img); print("ok", out)
    else:
        print("failed", name); sys.exit(1)
