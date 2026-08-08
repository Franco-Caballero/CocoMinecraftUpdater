import hashlib, os

zip_path = r"C:\Users\smol\Desktop\random\CocoMinecraftUpdater\release\Big-Walk.zip"
print("Computing SHA-256 for Big-Walk.zip...")

hasher = hashlib.sha256()
with open(zip_path, "rb") as f:
    while chunk := f.read(65536):
        hasher.update(chunk)

sha256 = hasher.hexdigest()
size = os.path.getsize(zip_path)
print(f"SHA-256: {sha256}")
print(f"Size: {size} bytes")
