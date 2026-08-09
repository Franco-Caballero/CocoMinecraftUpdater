import urllib.request, json

url = "https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/v0.5.84/latest.json"
req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
with urllib.request.urlopen(req) as resp:
    data = json.loads(resp.read().decode('utf-8'))

print("Top keys:", list(data.keys()))
if 'experiences' in data:
    for exp in data['experiences']:
        if exp.get('id') == 'big-walk':
            print("Found big-walk archives:")
            print(json.dumps(exp.get('pack', {}).get('archives', []), indent=2))
elif 'catalog' in data:
    for exp in data['catalog'].get('experiences', []):
        if exp.get('id') == 'big-walk':
            print("Found big-walk archives:")
            print(json.dumps(exp.get('pack', {}).get('archives', []), indent=2))
