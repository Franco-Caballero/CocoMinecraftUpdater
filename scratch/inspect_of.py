import os, re

game_dir = r"C:\Users\smol\Downloads\Big Walk - portable"
files = ["OnlineFix64.dll", "winmm.dll", "SteamOverlay64.dll"]

for fn in files:
    fp = os.path.join(game_dir, fn)
    if os.path.exists(fp):
        with open(fp, "rb") as f:
            data = f.read()
        print(f"=== Strings in {fn} ({len(data)} bytes) ===")
        urls = set(re.findall(rb"https?://[^\s\0\"'\<\>]{4,100}", data))
        for u in sorted(urls):
            print("  URL:", u.decode('utf-8', errors='ignore'))
        
        strs = set(re.findall(rb"[a-zA-Z0-9_/-]{4,50}", data))
        targets = [b"browser", b"url", b"open", b"site", b"page", b"welcome", b"first", b"notice", b"popup", b"message", b"fix", b"online", b"ini", b"steam", b"overlay", b"config", b"notify", b"toast", b"shell", b"http"]
        keys = [s.decode('utf-8', errors='ignore') for s in strs if any(k in s.lower() for k in targets)]
        for k in sorted(keys)[:50]:
            print("  Key:", k)
