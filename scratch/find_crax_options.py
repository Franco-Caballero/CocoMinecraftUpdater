pck = r"C:\Users\smol\AppData\Roaming\CocoMinecraft\experiences\machine-party\steam_api64.dll"
with open(pck, "rb") as f:
    content = f.read()

import re
matches = set(re.findall(b"[a-zA-Z0-9_]{3,30}", content))
keywords = [m.decode('ascii') for m in matches if any(x in m.lower() for x in [b"ini", b"config", b"emulat", b"steam", b"ticket", b"offline", b"lan", b"ip", b"socket", b"port", b"peer", b"connect"])]
print("Found strings in union-crax wrapper:")
print(sorted(keywords)[:60])
