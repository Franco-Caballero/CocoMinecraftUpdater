import os

path = r"C:\Users\smol\AppData\Roaming\CocoMinecraft\experiences\machine-party"
print("Files in machine-party:")
for f in os.listdir(path):
    p = os.path.join(path, f)
    if os.path.isfile(p):
        print(f"  {f} ({os.path.getsize(p)} bytes)")
