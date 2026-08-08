import os, re

game_dir = r"C:\Users\smol\Downloads\Big Walk - portable"
files = ["OnlineFix64.dll", "winmm.dll", "SteamOverlay64.dll"]

for fn in files:
    fp = os.path.join(game_dir, fn)
    if os.path.exists(fp):
        with open(fp, "rb") as f:
            data = f.read()
        print(f"=== Registry/Path Strings in {fn} ===")
        # Look for Software\, AppData, Temp, .ini, .dll, Reg, etc.
        patterns = [rb"Software\\[a-zA-Z0-9_\\]+", rb"AppID", rb"OnlineFix[a-zA-Z0-9_\\]*", rb"[a-zA-Z0-9_]+\.ini", rb"[a-zA-Z0-9_]+\.dll", rb"https?://[^\s\0\"'\<\>]+", rb"HKCU\\[^\s\0]+", rb"HKLM\\[^\s\0]+"]
        for p in patterns:
            matches = set(re.findall(p, data, re.IGNORECASE))
            for m in matches:
                print("  Found:", m.decode('utf-8', errors='ignore'))
