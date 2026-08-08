import os

game_dir = r"C:\Users\smol\Downloads\Big Walk - portable"

total_size = 0
file_count = 0

for root, dirs, files in os.walk(game_dir):
    for f in files:
        fp = os.path.join(root, f)
        total_size += os.path.getsize(fp)
        file_count += 1

print(f"Total files: {file_count}")
print(f"Total size: {total_size} bytes ({total_size / (1024*1024):.2f} MB / {total_size / (1024*1024*1024):.2f} GB)")
