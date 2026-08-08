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
    "X-GitHub-Api-Version": "2022-11-28"
}

# Get release v0.5.83 by tag
req = urllib.request.Request("https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases/tags/v0.5.83", headers=headers)
with urllib.request.urlopen(req) as resp:
    rel = json.loads(resp.read().decode('utf-8'))

print(f"Found release v0.5.83 ID: {rel['id']}")

patch_url = f"https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases/{rel['id']}"
patch_data = json.dumps({"make_latest": "true", "draft": False, "prerelease": False}).encode('utf-8')
patch_req = urllib.request.Request(patch_url, data=patch_data, headers={**headers, "Content-Type": "application/json"}, method="PATCH")

with urllib.request.urlopen(patch_req) as p_resp:
    res_obj = json.loads(p_resp.read().decode('utf-8'))
    print(f"SUCCESS: Release v0.5.83 is now set as LATEST! URL: {res_obj.get('html_url')}")
