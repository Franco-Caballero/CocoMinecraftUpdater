import json, urllib.request, subprocess

cmd = "protocol=https\nhost=github.com\n\n"
res = subprocess.run(["git", "credential", "fill"], input=cmd, text=True, capture_output=True)
token = None
for line in res.stdout.splitlines():
    if line.startswith("password="):
        token = line.split("=", 1)[1].strip()
        break

headers = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"}
req = urllib.request.Request("https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases?per_page=5", headers=headers)
with urllib.request.urlopen(req) as resp:
    releases = json.loads(resp.read().decode('utf-8'))

for r in releases:
    print(f"ID: {r['id']} | Tag: '{r.get('tag_name')}' | Name: '{r.get('name')}' | Draft: {r.get('draft')}")
    if r.get('name') == 'Coco Pack 0.5.85' or r.get('tag_name') == 'v0.5.85':
        patch_url = f"https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases/{r['id']}"
        p_data = json.dumps({"make_latest": "true", "draft": False, "prerelease": False, "tag_name": "v0.5.85"}).encode('utf-8')
        p_req = urllib.request.Request(patch_url, data=p_data, headers={**headers, "Content-Type": "application/json"}, method="PATCH")
        with urllib.request.urlopen(p_req) as p_resp:
            res_obj = json.loads(p_resp.read().decode('utf-8'))
            print("SUCCESSFULLY SET TO LATEST! HTML:", res_obj.get("html_url"))
