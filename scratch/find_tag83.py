import json, urllib.request, subprocess

cmd = "protocol=https\nhost=github.com\n\n"
res = subprocess.run(["git", "credential", "fill"], input=cmd, text=True, capture_output=True)
token = None
for line in res.stdout.splitlines():
    if line.startswith("password="):
        token = line.split("=", 1)[1].strip()
        break

headers = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"}
req = urllib.request.Request("https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases/tags/v0.5.83", headers=headers)
try:
    with urllib.request.urlopen(req) as resp:
        rel = json.loads(resp.read().decode('utf-8'))
        print(f"Tag v0.5.83 Release ID: {rel['id']}, Draft: {rel['draft']}, HTML: {rel['html_url']}")
        patch_url = f"https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases/{rel['id']}"
        p_data = json.dumps({"make_latest": "true", "draft": False, "prerelease": False}).encode('utf-8')
        p_req = urllib.request.Request(patch_url, data=p_data, headers={**headers, "Content-Type": "application/json"}, method="PATCH")
        with urllib.request.urlopen(p_req) as p_resp:
            res_obj = json.loads(p_resp.read().decode('utf-8'))
            print("SUCCESSFULLY SET v0.5.83 TO LATEST! URL:", res_obj.get("html_url"))
except Exception as e:
    print("Error fetching tag v0.5.83:", e)
    if hasattr(e, 'read'):
        print(e.read().decode('utf-8'))
