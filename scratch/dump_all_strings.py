import os, re

game_dir = r"C:\Users\smol\Downloads\Big Walk - portable"
files = ["OnlineFix64.dll", "winmm.dll", "SteamOverlay64.dll"]

for fn in files:
    fp = os.path.join(game_dir, fn)
    if os.path.exists(fp):
        with open(fp, "rb") as f:
            data = f.read()
        print(f"=== UTF-16/ASCII Strings in {fn} ===")
        # Extract ASCII
        ascii_strs = [m.decode('ascii', errors='ignore') for m in re.findall(rb"[\x20-\x7e]{5,100}", data)]
        # Extract UTF-16LE
        utf16_strs = [m.decode('utf-16le', errors='ignore') for m in re.findall(rb"(?:[\x20-\x7e]\x00){5,100}", data)]
        
        all_strs = ascii_strs + utf16_strs
        interesting = [s for s in all_strs if any(x in s.lower() for x in ["http", "www", "online", "fix", "steam", "app", "save", "data", "soft", "reg", "key", "msg", "box", "ui", "welcome", "notice", "toast", "overlay", "dll", "ini", "link", "site", "web", "launch", "run", "first"])]
        for s in sorted(set(interesting)):
            print("  ", s)
