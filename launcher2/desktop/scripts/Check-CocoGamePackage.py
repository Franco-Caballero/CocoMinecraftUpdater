"""Check a game's final ZIPs before uploading them: nothing promotional, no packer hash, one fix folder.

    python -I launcher2/desktop/scripts/Check-CocoGamePackage.py D:\\CocoWork\\<id>\\archives

Reads only the ZIP directories and each OnlineFix.ini; never extracts the game. Exit 1 lists every problem.
It mirrors what Coco does at launch (game_prepare.rs::fix_dirs): the fix runs where OnlineFix64.dll or
OnlineFix.dll lives, or, when neither exists, where an OnlineFix.ini lives (a fix built into another DLL).
"""
import pathlib
import posixpath
import sys
import zipfile

PROMO_SUFFIXES = (".url", ".bat", ".cmd", ".lnk")
PROMO_NAMES = {"read me.txt", "readme.txt", "dlllist.txt", "log.txt", "output_log.txt", "player.log"}
LOADERS = {"onlinefix64.dll", "onlinefix.dll"}


def main(folder: pathlib.Path) -> int:
    archives = sorted(folder.glob("*.zip"))
    if not archives:
        print(f"No ZIP in {folder}")
        return 1
    problems, loaders, inis = [], set(), {}
    for archive in archives:
        with zipfile.ZipFile(archive) as package:
            for name in package.namelist():
                if name.endswith("/"):
                    continue
                parts = [part.lower() for part in name.split("/")]
                base = parts[-1]
                if base.endswith(PROMO_SUFFIXES) or base in PROMO_NAMES:
                    problems.append(f"promotional or packer file: {name}")
                if "saves" in parts[:-1]:
                    problems.append(f"saved data: {name}")
                if any("fix repair" in part for part in parts[:-1]):
                    problems.append(f"spare fix copy (delete the whole folder from the source copy): {name}")
                folder_of = posixpath.dirname(name)
                if base in LOADERS:
                    loaders.add(folder_of)
                if base == "onlinefix.ini":
                    text = package.read(name).decode("utf-8", "replace")
                    inis[folder_of] = text
                    if any(line.strip().startswith("1337=") for line in text.splitlines()):
                        problems.append(f"packer's 1337 still in {name}: remove that line before packing")
                    if "realappid" not in text.lower():
                        problems.append(f"no RealAppId in {name}")
    fix_folders = sorted(loaders) if loaders else sorted(inis)
    for fix in fix_folders:
        print(f"fix folder: {fix or '(root)'}")
    if not fix_folders:
        print("no Online-Fix in this package")
    if len(fix_folders) > 1:
        problems.append(f"{len(fix_folders)} fix folders: Coco primes each one; make sure every one is real")
    print(f"{len(archives)} ZIP checked")
    for problem in problems:
        print(f"PROBLEM: {problem}")
    return 1 if problems else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(pathlib.Path(sys.argv[1])))
