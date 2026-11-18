"""Resolve the selected v81 mods and pin every upstream dependency."""

import argparse
import concurrent.futures
import hashlib
import io
import json
from pathlib import Path
import zipfile

import requests

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("workspace", type=Path)
ROOT = parser.parse_args().workspace
ROOT.mkdir(parents=True, exist_ok=True)
REQUESTED = """
notnotnotswipez-MoreCompany-1.14.0
FlipMods-TooManyEmotes-2.3.17
Verity-TooManySuits-2.0.4
x753-More_Suits-1.5.4
Smxrez-SimpleCompany-2.0.4
Smxrez-FashionableCompany-1.2.1
Norman-GlowStickSuits-1.0.4
ViViKo-AmongUsSuits-1.0.2
ShaosilGaming-GeneralImprovements-1.5.5
EliteMasterEric-Coroner-2.4.1
AllToasters-SpectateEnemies-2.9.1
ButteryStancakes-ButteryFixes-1.17.19
fumiko-CullFactory-2.0.11
DiFFoZ-LethalPerformance-1.3.0
qwbarch-Mirage-1.29.1
x753-Mimics-2.7.4
SoftDiamond-RollingGiant-2.6.3
Jordo-NeedyCats-1.2.5
KayNetsua-E_Gypt_Moon-2.0.27
Generic_GMD-Generic_Interiors-5.2.0
mrov-TerminalFormatter-0.3.7
TestAccount666-GoodItemScan-2.1.0
quackandcheese-ToggleMute-1.3.1
Terraformer9x-TerrasScrap-81.4.2
TeamXiaolan-DawnLib-0.9.25
TestAccount666-ShipWindows-2.11.1
FlipMods-ReservedWalkieSlot-2.0.7
FlipMods-ReservedItemSlotCore-2.0.55
AudioKnight-StarlancerAIFix-3.13.2
TwinDimensionalProductions-CoilHeadStare-1.1.0
sfDesat-Orion-2.1.7
JuninCsr-Boombox_Controller_Remastered-2.1.0
sfDesat-Aquatis-2.2.8
FlipMods-FasterItemDropship-1.3.1
LethalResonance-LETHALRESONANCE-4.7.8
KlutzyBubbles-BetterEmotes-1.5.8
Gemumoddo-BadAssCompany-1.3.1
Gemumoddo-LethalEmotesAPI-1.18.0
Zaggy1024-OpenBodyCams-3.0.12
Zaggy1024-PathfindingLagFix-2.4.2
Zingar-SecretLabs-3.4.5
FlipMods-MoreBlood-1.0.3
matsuura-HealthMetrics-1.0.2
Entity378-SellBodiesFixed-1.14.1
quackandcheese-MirrorDecor-1.3.3
zealsprince-Locker-1.6.3
DiFFoZ-BepInEx_Faster_Load_AssetBundles_Patcher-1.1.0
Rattenbonkers-TVLoader-1.1.2
AuroraBytes-FacelessStalker_Fork-1.2.5
taffyko-NameplateTweaks-1.0.7
egeadam-MoreScreams-1.0.3
Ccode_lang-SirenHead-2.0.7
x753-Peepers-1.0.5
Dev1A3-LethalFixes-1.3.3
FlipMods-ObjectVolumeController-1.1.3
""".split()

def download(key):
    owner, slug, version = key.split("-")
    url = f"https://thunderstore.io/package/download/{owner}/{slug}/{version}/"
    file = ROOT / f"{key}.zip"
    if not file.exists():
        response = requests.get(url, timeout=(20, 90))
        response.raise_for_status()
        zipfile.ZipFile(io.BytesIO(response.content)).close()
        file.write_bytes(response.content)
    data = file.read_bytes()
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        manifest = json.loads(z.read("manifest.json").decode("utf-8-sig"))
        assert manifest["version_number"] == version, (key, manifest)
        return key, dict(url=url, sha256=hashlib.sha256(data).hexdigest(), size=len(data),
                         deps=manifest["dependencies"], files=z.namelist())

with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    meta = dict(pool.map(download, REQUESTED + ["syndicat3-LethalCompanyV81Pack-1.2.0"]))
    pack_pins = {dep.rsplit("-",1)[0]:dep for dep in meta.pop("syndicat3-LethalCompanyV81Pack-1.2.0")["deps"]}
    pins = {key.rsplit("-",1)[0]:key for key in REQUESTED}
    while True:
        more = set()
        for entry in meta.values():
            for dep in entry["deps"]:
                name, version = dep.rsplit("-",1)
                chosen = pins.get(name, pack_pins.get(name, dep))
                if tuple(map(int, chosen.rsplit("-",1)[1].split("."))) < tuple(map(int, version.split("."))):
                    if name in {item.rsplit("-",1)[0] for item in REQUESTED}:
                        raise ValueError((dep, chosen))
                    chosen = dep
                pins[name] = chosen
                if chosen not in meta:
                    more.add(chosen)
        if not more:
            break
        meta.update(pool.map(download, sorted(more)))
    meta = {key: entry for key, entry in meta.items() if pins[key.rsplit("-", 1)[0]] == key}
    (ROOT / "inventory.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    print(f"{len(meta)} packages, {sum(x['size'] for x in meta.values()):,} bytes")
