"""Direct Canvas concept screens via Azure gpt-image-2.5-flare images/generations.
usage: python3 gen.py <screen> [suffix]   -> <screen><suffix>.png next to this file
One call at a time, guarded by the shared /tmp/viaform-azure.lock (taken by the shell wrapper run.sh)."""
import base64, json, pathlib, subprocess, sys, time, urllib.error, urllib.request

HERE = pathlib.Path(__file__).resolve().parent
EP = ("https://temple-ai-provider.cognitiveservices.azure.com/openai/deployments/gpt-image-2.5-flare/"
      "images/generations?api-version=2025-04-01-preview")
PROMPTS = json.loads((HERE / "prompts.json").read_text())


def key():
    return subprocess.check_output(["az", "cognitiveservices", "account", "keys", "list", "-n", "temple-ai-provider",
                                    "-g", "temple-ai-rg", "--query", "key1", "-o", "tsv"], text=True).strip()


def run(name, suffix, k):
    p = PROMPTS["style"] + "\n\n" + PROMPTS[name]
    body = json.dumps({"prompt": p, "size": "1536x1024", "quality": "high", "n": 1, "output_format": "png"}).encode()
    for attempt in range(6):
        req = urllib.request.Request(EP, data=body, method="POST",
                                     headers={"api-key": k, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=900) as r:
                data = json.load(r)["data"][0]["b64_json"]
            (HERE / f"{name}{suffix}.png").write_bytes(base64.b64decode(data))
            print(name, "ok", flush=True)
            return 0
        except urllib.error.HTTPError as e:
            print(name, "http", e.code, e.read().decode()[:200], flush=True)
            if e.code not in (429, 500, 502, 503, 504):
                return 1
        except Exception as e:
            print(name, "error", e, flush=True)
        time.sleep(20 * (attempt + 1))
    return 1


if __name__ == "__main__":
    sys.exit(run(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "", key()))
