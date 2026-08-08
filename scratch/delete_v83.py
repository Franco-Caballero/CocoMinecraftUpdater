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

for r in releases:
    if r.get("tag_name") == "v0.5.83":
        print(f"Deleting incomplete release v0.5.83 (ID: {r['id']})...")
        del_req = urllib.request.Request(f"https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases/{r['id']}", headers=headers, method="DELETE")
        with urllib.request.urlopen(del_req) as del_resp:
            print("Successfully deleted release v0.5.83!")
