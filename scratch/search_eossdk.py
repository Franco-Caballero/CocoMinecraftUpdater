import os, re

game_dir = r"C:\Users\smol\Downloads\Big Walk - portable"
files = ["EOSSDK-Win64-Shipping.dll", "OnlineFix64.dll", "winmm.dll"]

for f in files:
    fp = os.path.join(game_dir, f)
    if os.path.exists(fp):
        with open(fp, "rb") as fh:
            data = fh.read()
        print(f"=== Match in {f} ===")
        # Search for online-fix, steamgg, http, etc.
        for match in re.finditer(rb"(?:https?://|www\.)[a-zA-Z0-9.\-_/]+", data):
            print("  URL:", match.group().decode('ascii', errors='ignore'))
        
        for m in re.finditer(rb"Online-Fix[a-zA-Z0-9.\-_]*", data, re.IGNORECASE):
            print("  OF string:", m.group().decode('ascii', errors='ignore'))
