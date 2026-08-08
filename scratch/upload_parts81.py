import os, json, urllib.request, subprocess

print("Getting GitHub credentials...")
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

req = urllib.request.Request("https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases?per_page=10", headers=headers)
with urllib.request.urlopen(req) as resp:
    releases = json.loads(resp.read().decode('utf-8'))

rel81 = None
for r in releases:
    if r.get("tag_name") == "v0.5.81" or r.get("name") == "Coco Pack 0.5.81":
        rel81 = r
        break

if not rel81:
    raise Exception("v0.5.81 release not found on GitHub.")

print(f"Found v0.5.81 release ID: {rel81['id']}, Draft: {rel81['draft']}")

# Publish draft first if it's draft
if rel81['draft']:
    pub_url = f"https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases/{rel81['id']}"
    pub_data = json.dumps({"draft": False, "prerelease": False}).encode('utf-8')
    pub_req = urllib.request.Request(pub_url, data=pub_data, headers={**headers, "Content-Type": "application/json"}, method="PATCH")
    with urllib.request.urlopen(pub_req) as p_resp:
        rel81 = json.loads(p_resp.read().decode('utf-8'))
        print(f"v0.5.81 is now PUBLIC! URL: {rel81['html_url']}")

upload_base = rel81["upload_url"].split("{")[0]

parts = [
    ("Big-Walk-Part1.zip", r"C:\Users\smol\Desktop\random\CocoMinecraftUpdater\release\Big-Walk-Part1.zip"),
    ("Big-Walk-Part2.zip", r"C:\Users\smol\Desktop\random\CocoMinecraftUpdater\release\Big-Walk-Part2.zip")
]

existing_names = [a.get("name") for a in rel81.get("assets", [])]

for part_name, part_path in parts:
    if part_name in existing_names:
        print(f"Asset '{part_name}' already uploaded! Skipping.")
        continue
    
    file_size = os.path.getsize(part_path)
    print(f"Uploading '{part_name}' ({file_size / (1024*1024):.2f} MB) to v0.5.81 release...")
    up_url = f"{upload_base}?name={part_name}"
    up_headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/zip",
        "Content-Length": str(file_size)
    }
    with open(part_path, "rb") as f:
        up_req = urllib.request.Request(up_url, data=f, headers=up_headers, method="POST")
        with urllib.request.urlopen(up_req) as up_resp:
            res_obj = json.loads(up_resp.read().decode('utf-8'))
            print(f"Successfully uploaded {part_name}! URL: {res_obj.get('browser_download_url')}")
