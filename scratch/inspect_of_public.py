import os

public_of = r"C:\Users\Public\Documents\OnlineFix"

print(f"=== Inspecting {public_of} ===")

if os.path.exists(public_of):
    for root, dirs, files in os.walk(public_of):
        for f in files:
            fp = os.path.join(root, f)
            print(f"File: {fp} ({os.path.getsize(fp)} bytes)")
            if os.path.getsize(fp) < 2000:
                with open(fp, "r", encoding="utf-8", errors="ignore") as fh:
                    print("--- Content ---")
                    print(fh.read())
                    print("---------------")
else:
    print("Not found!")
