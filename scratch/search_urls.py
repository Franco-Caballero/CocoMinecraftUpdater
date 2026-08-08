import os, re

game_dir = r"C:\Users\smol\Downloads\Big Walk - portable"

print("=== Scanning files in Big Walk - portable for URLs / Messages ===")

for root, dirs, files in os.walk(game_dir):
    for f in files:
        fp = os.path.join(root, f)
        size = os.path.getsize(fp)
        if size > 15 * 1024 * 1024:
            continue
        try:
            with open(fp, "rb") as fh:
                data = fh.read()
            
            # Find URLs
            urls = re.findall(rb"https?://[^\s\0\"'\<\>]{4,100}", data)
            if urls:
                print(f"File {f} URLs:")
                for u in set(urls):
                    print("  ", u.decode('utf-8', errors='ignore'))
            
            # Find Online-Fix or steamgg or MessageBox
            for term in [b"steamgg", b"online-fix", b"onlinefix"]:
                if term in data.lower():
                    print(f"File {f} contains term: {term.decode()}")
        except Exception as e:
            pass
