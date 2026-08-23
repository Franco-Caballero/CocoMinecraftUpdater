import os
import sys
import hashlib
import zipfile
import math
import shutil
import json

SRC = r"D:\Cooking.Simulator.2.Better.Together.v1.11.8838be4-OFME.part1\Cooking Simulator 2 Better Together"
OUT_DIR = r"D:\cs2_packages"
os.makedirs(OUT_DIR, exist_ok=True)

LARGE_BUNDLE_REL = os.path.normpath(r"Cooking Simulator 2_Data\StreamingAssets\aa\StandaloneWindows64\charactercreator_assets_all_b787525a66903e5403a00d6afeca6035.bundle")
LARGE_BUNDLE_PATH = os.path.join(SRC, LARGE_BUNDLE_REL)

CLEAN_INI = """[Main]
RealAppId=2455360
FakeAppId=480

#Language=english
BuildId=0
InstallDir=
UnlockAllDLC=false


[Misc]
ExtraProtection=false
PhotonIntegration=false
EmulateTicket=false


[Interfaces]
Apps=true
User=true
Utils=true
Storage=true
UserStats=true
Friends=true
UGC=true
Inventory=true
AppTicket=true


[Hashes]
0=b827003fe85ecf063ff7b3f2da1646239e394da4e244f4ff42c93b3a8c4f18238dd98fb5a1080d6050ad1c0c653db9ce23eba5272cc62f426239d0954b589fad
1337=0668f8b2eb4d826f4478152a3696647fc87cd6ff53df6c860cb626c917e1b2fe90e801355c055eef936b6a159a781926d7c147031668f8ef74273fefa3477263
"""

files_to_pack = []
for root, dirs, files in os.walk(SRC):
    for f in files:
        if f.lower() == 'onlinefix.url':
            continue
        full_path = os.path.join(root, f)
        rel_path = os.path.relpath(full_path, SRC)
        if os.path.normpath(rel_path) == LARGE_BUNDLE_REL:
            continue
        files_to_pack.append((rel_path, full_path, os.path.getsize(full_path)))

part1_files = []
aa_files = []

for rel, full, sz in files_to_pack:
    norm_rel = rel.replace('\\', '/')
    if norm_rel.startswith('Cooking Simulator 2_Data/StreamingAssets/aa/StandaloneWindows64/'):
        aa_files.append((rel, full, sz))
    else:
        part1_files.append((rel, full, sz))

chunk1_path = os.path.join(OUT_DIR, "charactercreator.part1")
chunk2_path = os.path.join(OUT_DIR, "charactercreator.part2")

aa_files.sort(key=lambda x: x[2], reverse=True)

parts_def = []

# Part 1
p1_items = []
for rel, full, sz in part1_files:
    p1_items.append((rel, full, sz))
parts_def.append(("Cooking-Simulator-2-Part1.zip", p1_items))

# Part 2
large_bundle_part1_rel = LARGE_BUNDLE_REL.replace('\\', '/') + ".part1"
parts_def.append(("Cooking-Simulator-2-Part2.zip", [(large_bundle_part1_rel, chunk1_path, os.path.getsize(chunk1_path))]))

# Part 3
large_bundle_part2_rel = LARGE_BUNDLE_REL.replace('\\', '/') + ".part2"
parts_def.append(("Cooking-Simulator-2-Part3.zip", [(large_bundle_part2_rel, chunk2_path, os.path.getsize(chunk2_path))]))

# Distribute remaining AA files
current_part_files = []
current_part_size = 0
part_idx = 4

for rel, full, sz in aa_files:
    if current_part_size + sz > 1400 * 1024 * 1024 and current_part_files:
        parts_def.append((f"Cooking-Simulator-2-Part{part_idx}.zip", current_part_files))
        part_idx += 1
        current_part_files = []
        current_part_size = 0
    current_part_files.append((rel, full, sz))
    current_part_size += sz

if current_part_files:
    parts_def.append((f"Cooking-Simulator-2-Part{part_idx}.zip", current_part_files))

results = []
for name, items in parts_def:
    zip_path = os.path.join(OUT_DIR, name)
    if os.path.exists(zip_path) and os.path.getsize(zip_path) > 0 and name in ["Cooking-Simulator-2-Part1.zip", "Cooking-Simulator-2-Part2.zip", "Cooking-Simulator-2-Part3.zip"]:
        print(f"Skipping already complete {name}...")
    else:
        print(f"Creating {name}...")
        if os.path.exists(zip_path):
            os.remove(zip_path)
        with zipfile.ZipFile(zip_path, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=1) as zf:
            for rel_entry, src_file, sz in items:
                arcname = rel_entry.replace('\\', '/')
                if arcname.lower() == 'onlinefix.ini':
                    zf.writestr(arcname, CLEAN_INI)
                else:
                    zf.write(src_file, arcname)
    
    zip_size = os.path.getsize(zip_path)
    h = hashlib.sha256()
    with open(zip_path, 'rb') as f:
        while True:
            b = f.read(8 * 1024 * 1024)
            if not b:
                break
            h.update(b)
    sha256 = h.hexdigest().lower()
    print(f"Ready: {name} (size={zip_size}, sha256={sha256})")
    results.append({
        "name": name,
        "path": zip_path,
        "size": zip_size,
        "sha256": sha256
    })

results_file = os.path.join(OUT_DIR, "results.json")
with open(results_file, 'w') as f:
    json.dump(results, f, indent=2)
print("ALL DONE! Results written to:", results_file)
