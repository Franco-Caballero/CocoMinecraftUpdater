import os, winreg

print("=== Checking Registry Keys ===")
reg_paths = [
    r"Software\OnlineFix",
    r"Software\Online-Fix",
    r"Software\SteamGG",
    r"Software\Valve\Steam",
    r"Software\Big Walk",
]

for rp in reg_paths:
    for root_name, root in [("HKCU", winreg.HKEY_CURRENT_USER), ("HKLM", winreg.HKEY_LOCAL_MACHINE)]:
        try:
            key = winreg.OpenKey(root, rp)
            print(f"FOUND {root_name}\\{rp}")
            try:
                i = 0
                while True:
                    name, val, typ = winreg.EnumValue(key, i)
                    print(f"  Value: {name} = {val}")
                    i += 1
            except OSError:
                pass
            winreg.CloseKey(key)
        except OSError:
            pass

print("\n=== Checking File Paths ===")
check_dirs = [
    os.path.join(os.environ.get("APPDATA", ""), "OnlineFix"),
    os.path.join(os.environ.get("LOCALAPPDATA", ""), "OnlineFix"),
    os.path.join(os.environ.get("PUBLIC", r"C:\Users\Public"), "Documents", "OnlineFix"),
    os.path.join(os.environ.get("USERPROFILE", ""), "AppData", "LocalLow", "House House"),
    os.path.join(os.environ.get("APPDATA", ""), "Goldberg SteamEmu Saves"),
]

for cd in check_dirs:
    if os.path.exists(cd):
        print(f"FOUND DIR: {cd}")
        for root, dirs, files in os.walk(cd):
            for f in files:
                print("  File:", os.path.join(root, f))
    else:
        print(f"NOT FOUND: {cd}")
