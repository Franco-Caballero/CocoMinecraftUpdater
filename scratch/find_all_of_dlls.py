import os, re

game_dir = r"C:\Users\smol\Downloads\Big Walk - portable"

for root, dirs, files in os.walk(game_dir):
    for f in files:
        if "eossdk" in f.lower() or "onlinefix" in f.lower() or "steam" in f.lower() or "winmm" in f.lower():
            fp = os.path.join(root, f)
            print("Found file:", fp)
            with open(fp, "rb") as fh:
                data = fh.read()
            urls = re.findall(rb"https?://[^\s\0\"'\<\>]{4,100}", data)
            if urls:
                print("  URLs:")
                for u in set(urls):
                    print("   ", u.decode('ascii', errors='ignore'))
            ofs = re.findall(rb"[a-zA-Z0-9_\-]*online[a-zA-Z0-9_\-]*", data, re.IGNORECASE)
            if ofs:
                print("  OF keywords:")
                for o in list(set(ofs))[:10]:
                    print("   ", o.decode('ascii', errors='ignore'))
