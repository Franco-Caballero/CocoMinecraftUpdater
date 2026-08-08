import json, urllib.request, subprocess

cmd = "protocol=https\nhost=github.com\n\n"
res = subprocess.run(["git", "credential", "fill"], input=cmd, text=True, capture_output=True)
token = None
for line in res.stdout.splitlines():
    if line.startswith("password="):
        token = line.split("=", 1)[1].strip()
        break

headers = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"}

for page in range(1, 4):
    req = urllib.request.Request(f"https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases?per_page=30&page={page}", headers=headers)
    with urllib.request.urlopen(req) as resp:
        releases = json.loads(resp.read().decode('utf-8'))
        print(f"--- PAGE {page} ({len(releases)} releases) ---")
        for r in releases:
            print(f"ID: {r['id']} | Tag: {r.get('tag_name')} | Draft: {r.get('draft')} | Name: {r.get('name')}")
