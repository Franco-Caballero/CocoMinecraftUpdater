"""Build the installed-file manifest from the pinned Thunderstore ZIPs."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import zipfile


METADATA = {"manifest.json", "readme.md", "icon.png", "changelog.md",
            "license", "license.md", "license.txt"}
REPLACED = {
    "JacobG5-DestroyItemInSlotFix-1.0.0":
        "DawnLib 0.9.25 already patches DestroyItemInSlot. Running both makes its IL match fail.",
}
DEFAULTS = {
    "BepInEx/config/BepInEx.cfg":
        "[Logging.Console]\nEnabled = false\n",
    "BepInEx/config/BetterEmotes.cfg":
        "[Emote Keys]\nEmote Wheel Key = <Keyboard>/f8\n",
    "BepInEx/config/butterystancakes.lethalcompany.butteryfixes.cfg":
        "[Compatibility]\nBodiesCollectSelf = false\n",
    "BepInEx/config/FlipMods.TooManyEmotes.cfg":
        "[Emote Settings]\nI am a Party Pooper = true\n"
        "DoNotUnlockPropEmotes PartyPooperMode = false\n",
    "BepInEx/config/nomnomab.rollinggiant.cfg":
        "[z_Ignore]\n__version = 11\n",
    "BepInEx/config/ShaosilGaming.GeneralImprovements.cfg":
        "[Fixes]\nAutomaticallyCollectTeleportedCorpses = false\n"
        "[Scanner]\nFixPersonalScanner = false\n"
        "[Tools]\nWalkieUseShortcut = None\n",
    "BepInEx/config/uk.1a3.lethalfixes.cfg":
        "[Compatibility]\nTerminal Scan Command = false\n",
    "BepInEx/config/x753.More_Suits.cfg":
        "[General]\nIgnore !less-suits.txt = true\n",
}


def destination(name, source):
    if name.startswith("BepInEx-"):
        if source == "BepInExPack/winhttp.dll":
            return "winhttp.dll"
        if source == "BepInExPack/BepInEx/config/BepInEx.cfg":
            return None
        if source.startswith("BepInExPack/BepInEx/"):
            return source.removeprefix("BepInExPack/")
        return None
    if source.split("/")[0].lower() in METADATA or source.endswith(".pdb"):
        return None
    if name.startswith("ViViKo-") and source.endswith("/!less-suits.txt"):
        return None
    if name.startswith("LethalResonance-") and source.endswith("/replacers/meltdown.json"):
        return None
    relative = source.removeprefix("BepInEx/")
    for folder in ("config", "core"):
        if relative.startswith(folder + "/"):
            return "BepInEx/" + relative
    for folder in ("plugins", "patchers"):
        if relative.startswith(folder + "/"):
            return f"BepInEx/{folder}/{name.rsplit('-', 1)[0]}/{relative.removeprefix(folder + '/')}"
    return f"BepInEx/plugins/{name.rsplit('-', 1)[0]}/{relative}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inventory", type=Path)
    parser.add_argument("lock", type=Path)
    parser.add_argument("--trial", type=Path, help="Fresh game copy, used only for local testing")
    args = parser.parse_args()
    inventory = json.loads(args.inventory.read_text(encoding="utf-8"))
    result = {"gameVersion": "81", "packages": [], "defaults": DEFAULTS}
    source_catalog = Path(__file__).resolve().parents[3] / "launcher/catalog.template.json"
    catalog = json.loads(source_catalog.read_text(encoding="utf-8-sig"))
    game = next(item for item in catalog["experiences"] if item["id"] == "lethal-company")
    if str(game["pack"]["version"]) != result["gameVersion"]:
        raise ValueError("The catalog no longer selects Lethal Company v81")
    result["gameExecutable"] = game["runtime"]["executable"]
    result["gameExecutableSha256"] = next(item["sha256"] for item in game["runtime"]["requiredFiles"]
                                          if item["path"] == game["runtime"]["executable"])
    installed = set()
    for name, package in sorted(inventory.items()):
        archive = args.inventory.with_name(name + ".zip")
        with archive.open("rb") as source:
            if hashlib.file_digest(source, "sha256").hexdigest() != package["sha256"]:
                raise ValueError(f"Unexpected ZIP digest: {archive}")
        files = []
        with zipfile.ZipFile(archive) as z:
            for entry in sorted(z.infolist(), key=lambda item: item.filename):
                if entry.is_dir():
                    continue
                target = None if name in REPLACED else destination(name, entry.filename)
                if target is None:
                    continue
                if (target.lower() in installed or ".." in PurePosixPath(target).parts
                        or "\\" in target or ":" in target):
                    raise ValueError(f"Invalid or duplicate install path: {target}")
                installed.add(target.lower())
                data = z.read(entry)
                files.append({"source": entry.filename, "path": target, "size": len(data),
                              "sha256": hashlib.sha256(data).hexdigest()})
                if args.trial:
                    trial_path = args.trial / target
                    trial_path.parent.mkdir(parents=True, exist_ok=True)
                    with trial_path.open("xb") as stream:
                        stream.write(data)
        entry = {"name": name, **{k: package[k] for k in
                 ("url", "size", "sha256", "deps")}, "files": files}
        if name in REPLACED:
            entry["disabledReason"] = REPLACED[name]
        result["packages"].append(entry)
    if args.trial:
        for relative, content in DEFAULTS.items():
            with (args.trial / relative).open("x", encoding="utf-8") as stream:
                stream.write(content)
    # Keep the identity of the profile published by Coco 0.6.61 on every checkout.
    args.lock.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n",
                         encoding="utf-8", newline="\r\n")


if __name__ == "__main__":
    main()
