import os, json, urllib.request, subprocess

print("Getting GitHub credentials via git credential fill...")
cmd = "protocol=https\nhost=github.com\n\n"
res = subprocess.run(["git", "credential", "fill"], input=cmd, text=True, capture_output=True)

token = None
for line in res.stdout.splitlines():
    if line.startswith("password="):
        token = line.split("=", 1)[1].strip()
        break

if not token:
    raise Exception("Could not retrieve GitHub token.")

headers = {
    "Authorization": f"Bearer {token}",
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28"
}

# Fetch releases
req = urllib.request.Request("https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases?per_page=10", headers=headers)
with urllib.request.urlopen(req) as resp:
    releases = json.loads(resp.read().decode('utf-8'))

rel79 = None
for r in releases:
    if r.get("tag_name") == "v0.5.79":
        rel79 = r
        break

if not rel79:
    raise Exception("v0.5.79 release not found on GitHub.")

print(f"Found v0.5.79 release ID: {rel79['id']}")

# Check if Big-Walk.zip asset already exists in release
for asset in rel79.get("assets", []):
    if asset.get("name") == "Big-Walk.zip":
        print(f"Asset Big-Walk.zip already uploaded! URL: {asset.get('browser_download_url')}")
        exit(0)

asset_path = r"C:\Users\smol\Desktop\random\CocoMinecraftUpdater\release\Big-Walk.zip"
file_size = os.path.getsize(asset_path)
print(f"Uploading Big-Walk.zip ({file_size / (1024*1024):.2f} MB) to v0.5.79 release...")

upload_url = rel79["upload_url"].split("{")[0] + "?name=Big-Walk.zip"

upload_headers = {
    "Authorization": f"Bearer {token}",
    "Content-Type": "application/zip",
    "Content-Length": str(file_size)
}

with open(asset_path, "rb") as f:
    up_req = urllib.request.Request(upload_url, data=f, headers=upload_headers, method="POST")
    with urllib.request.urlopen(up_req) as up_resp:
        result = json.loads(up_resp.read().decode('utf-8'))
        print(f"Upload complete! Asset URL: {result.get('browser_download_url')}")
