import json, urllib.request, subprocess

cmd = "protocol=https\nhost=github.com\n\n"
res = subprocess.run(["git", "credential", "fill"], input=cmd, text=True, capture_output=True)
token = None
for line in res.stdout.splitlines():
    if line.startswith("password="):
        token = line.split("=", 1)[1].strip()
        break

headers = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"}
req = urllib.request.Request("https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases/tags/v0.5.82", headers=headers)
with urllib.request.urlopen(req) as resp:
    rel = json.loads(resp.read().decode('utf-8'))

print("Assets in v0.5.82:")
for a in rel.get("assets", []):
    print(f"- {a['name']} ({a['size']} bytes) URL: {a['browser_download_url']}")
