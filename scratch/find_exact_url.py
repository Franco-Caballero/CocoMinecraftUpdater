import os, re

game_dir = r"C:\Users\smol\Downloads\Big Walk - portable"

for root, dirs, files in os.walk(game_dir):
    for f in files:
        if f.endswith(".dll") or f.endswith(".exe") or f.endswith(".ini") or f.endswith(".txt"):
            fp = os.path.join(root, f)
            with open(fp, "rb") as fh:
                data = fh.read()
            
            # Find URLs or domain names
            matches = re.findall(rb"(?:https?://|www\.)[a-zA-Z0-9.\-_/]+", data)
            if matches:
                print(f"URLs in {f}:")
                for m in set(matches):
                    print("  ", m.decode('ascii', errors='ignore'))

            # Search specifically for steamgg or online-fix or onlinefix
            for target in [b"steamgg", b"online-fix", b"onlinefix"]:
                if target in data.lower():
                    print(f"Target '{target.decode()}' found in {f}")
