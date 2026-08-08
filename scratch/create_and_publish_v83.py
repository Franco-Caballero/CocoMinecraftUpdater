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

# Check if v0.5.83 tag or release exists
req = urllib.request.Request("https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases?per_page=100", headers=headers)
with urllib.request.urlopen(req) as resp:
    releases = json.loads(resp.read().decode('utf-8'))

rel83 = None
for r in releases:
    if r.get("tag_name") == "v0.5.83":
        rel83 = r
        break

if not rel83:
    print("Creating release v0.5.83...")
    body = {
        "tag_name": "v0.5.83",
        "target_commitish": "main",
        "name": "Coco Pack 0.5.83",
        "body": "Publicacion automatica incremental.",
        "draft": False,
        "prerelease": False,
        "make_latest": "true"
    }
    p_req = urllib.request.Request("https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases", data=json.dumps(body).encode('utf-8'), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(p_req) as p_resp:
            res_obj = json.loads(p_resp.read().decode('utf-8'))
            print("CREATED AND PUBLISHED RELEASE v0.5.83! ID:", res_obj.get("id"), "HTML:", res_obj.get("html_url"))
    except Exception as e:
        print("Error creating release:", e)
        if hasattr(e, 'read'):
            print(e.read().decode('utf-8'))
else:
    print(f"Release v0.5.83 already exists! ID: {rel83['id']}, Draft: {rel83['draft']}")
    patch_url = f"https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases/{rel83['id']}"
    p_data = json.dumps({"make_latest": "true", "draft": False, "prerelease": False}).encode('utf-8')
    p_req = urllib.request.Request(patch_url, data=p_data, headers=headers, method="PATCH")
    with urllib.request.urlopen(p_req) as p_resp:
        res_obj = json.loads(p_resp.read().decode('utf-8'))
        print("PATCHED RELEASE v0.5.83 TO LATEST! HTML:", res_obj.get("html_url"))
