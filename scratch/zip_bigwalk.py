import os, zipfile, time

source_dir = r"C:\Users\smol\Downloads\Big Walk - portable"
output_zip = r"C:\Users\smol\Desktop\random\CocoMinecraftUpdater\release\Big-Walk.zip"

print(f"Compressing '{source_dir}' to '{output_zip}'...")
start = time.time()

with zipfile.ZipFile(output_zip, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
    for root, dirs, files in os.walk(source_dir):
        for f in files:
            full_path = os.path.join(root, f)
            rel_path = os.path.relpath(full_path, source_dir)
            zf.write(full_path, rel_path)

elapsed = time.time() - start
zip_size = os.path.getsize(output_zip)
print(f"Compression completed in {elapsed:.1f}s.")
print(f"Output ZIP size: {zip_size} bytes ({zip_size / (1024*1024):.2f} MB / {zip_size / (1024*1024*1024):.2f} GB)")
