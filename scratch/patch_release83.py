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

# Fetch releases
req = urllib.request.Request("https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases?per_page=10", headers=headers)
with urllib.request.urlopen(req) as resp:
    releases = json.loads(resp.read().decode('utf-8'))

rel83 = None
for r in releases:
    if r.get("tag_name") == "v0.5.83":
        rel83 = r
        break

if not rel83:
    print("Release v0.5.83 not found in releases list.")
else:
    print(f"Found release v0.5.83 ID: {rel83['id']}")
    patch_url = f"https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases/{rel83['id']}"
    patch_data = json.dumps({"make_latest": "true", "draft": False, "prerelease": False}).encode('utf-8')
    patch_req = urllib.request.Request(patch_url, data=patch_data, headers={**headers, "Content-Type": "application/json"}, method="PATCH")
    with urllib.request.urlopen(patch_req) as p_resp:
        res_obj = json.loads(p_resp.read().decode('utf-8'))
        print(f"Patch result: make_latest is now set! HTML URL: {res_obj.get('html_url')}")
