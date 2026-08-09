import urllib.request, json

url = "https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/v0.5.84/latest.json"
req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
with urllib.request.urlopen(req) as resp:
    data = json.loads(resp.read().decode('utf-8'))

for exp in data.get('experiences', []):
    if exp.get('id') == 'big-walk':
        print("Big Walk archive URLs in latest.json on v0.5.84:")
        for arch in exp.get('pack', {}).get('archives', []):
            print("- ", arch.get('archiveUrl'))
