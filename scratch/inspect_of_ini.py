import os, re

game_dir = r"C:\Users\smol\Downloads\Big Walk - portable"
of_dll = os.path.join(game_dir, "OnlineFix64.dll")

with open(of_dll, "rb") as f:
    data = f.read()

print("=== INI keys/sections in OnlineFix64.dll ===")
# Find strings like [Section] or key names near GetPrivateProfileString
matches = re.findall(rb"\[[a-zA-Z0-9_]+\]", data)
for m in set(matches):
    print("Section:", m.decode('ascii'))

# Find keys
keys = re.findall(rb"[a-zA-Z0-9_]{3,30}=(?:true|false|[0-9]+|)", data, re.IGNORECASE)
for k in set(keys):
    print("Sample key:", k.decode('ascii', errors='ignore'))
