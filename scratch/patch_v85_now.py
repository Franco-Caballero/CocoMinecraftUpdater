import json, urllib.request, subprocess

cmd = "protocol=https\nhost=github.com\n\n"
res = subprocess.run(["git", "credential", "fill"], input=cmd, text=True, capture_output=True)
token = None
for line in res.stdout.splitlines():
    if line.startswith("password="):
        token = line.split("=", 1)[1].strip()
        break

headers = {
    "Authorization": f"Bearer {token}",
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "Content-Type": "application/json"
}

req = urllib.request.Request("https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases/tags/v0.5.85", headers=headers)
with urllib.request.urlopen(req) as resp:
    rel = json.loads(resp.read().decode('utf-8'))

print(f"Found v0.5.85 release ID: {rel['id']}")

patch_url = f"https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases/{rel['id']}"
patch_data = json.dumps({"make_latest": "true", "draft": False, "prerelease": False}).encode('utf-8')
patch_req = urllib.request.Request(patch_url, data=patch_data, headers=headers, method="PATCH")

with urllib.request.urlopen(patch_req) as p_resp:
    res_obj = json.loads(p_resp.read().decode('utf-8'))
    print(f"SUCCESS: Release v0.5.85 set to LATEST! URL: {res_obj.get('html_url')}")
