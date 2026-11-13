"""Turn a reviewed multipart inventory into an immutable standalone draft.

No archive rereads or decompression: the packer already measured every byte.
Apply-CocoStandaloneDraft.ps1 independently validates local archive hashes before promotion.
"""
import argparse
import json
import re
import shutil
from pathlib import Path

SUPPORT = {'unityplayer.dll', 'gameassembly.dll', 'winmm.dll', 'version.dll',
           'onlinefix.dll', 'onlinefix64.dll', 'steam_api.dll', 'steam_api64.dll'}


def create(inventory, draft_root, game_id, name, version, executable, description, cover, required=()):
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,46}[a-z0-9]', game_id):
        raise ValueError('Invalid game ID')
    rows = {row['path']: row for row in inventory['files']}
    if len(rows) != len(inventory['files']) or executable not in rows:
        raise ValueError('Duplicate inventory paths or executable absent')
    archives = inventory['archives']
    if not 1 <= len(archives) <= 64:
        raise ValueError('Invalid archive count')
    for archive in archives:
        if (not archive['archiveUrl'].startswith('https://') or
                not re.fullmatch('[a-f0-9]{64}', archive['sha256']) or
                not 0 < archive['size'] < 2 * 1024**3):
            raise ValueError('Invalid archive URL/hash/size')
    reconstructed = {row['path'] for row in inventory.get('reassembledFiles', [])}
    selected = {executable, *required}
    selected.update(path for path in rows if Path(path).name.lower() in SUPPORT)
    if selected & reconstructed:
        raise ValueError('Verify oversized reconstructed files once at installation, not every launch')
    if selected - rows.keys():
        raise ValueError('Required path absent from inventory')
    required_files = [rows[path] for path in sorted(selected)]
    if len(required_files) > 128:
        raise ValueError('Too many required files')
    extension = cover.suffix.lower()
    if extension not in {'.png', '.jpg', '.webp'}:
        raise ValueError('Unsupported cover extension')
    candidate = dict(id=game_id, name=name, ui=dict(imagePath=f'assets/experiences/{game_id}{extension}'),
        description=description, instanceId=game_id, managementMode='managed',
        runtime=dict(type='standalone', executable=executable, requiredFiles=required_files),
        pack=dict(packId=f'standalone-{game_id}', lockPath=f'launcher/experiences/{game_id}.lock.json',
                  version=version, sha256=archives[0]['sha256'], size=sum(a['size'] for a in archives), archives=archives),
        hosting=dict(mode='p2p'),
        launch=dict(workflow='coco-standalone', arguments=[], autoJoin=False, serverName=f'Coco - {name}'), files=[])
    locked = [dict(url=a['archiveUrl'], sha256=a['sha256'], size=a['size']) for a in archives]
    lock = dict(schemaVersion=1, experienceId=game_id, type='standalone', files=[], archive=locked[0])
    if len(locked) > 1:
        lock['archives'] = locked
    target = draft_root / game_id
    target.mkdir(parents=True, exist_ok=False)
    for filename, content in [('catalog-candidate.json', candidate), ('source-lock.json', lock)]:
        (target / filename).write_text(json.dumps(content, ensure_ascii=True, indent=2) + '\n', encoding='utf-8')
    shutil.copyfile(cover, target / ('cover' + extension))
    (target / 'REVIEW.txt').write_text(
        f'{name} {version}\n{len(archives)} independent ZIPs, {len(required_files)} required files.\n'
        'Review host approval, rights, executable, metadata, exclusions and native installation.\n'
        'URLs are proposed until the exact assets are uploaded and verified.\n'
        f'Excluded: {inventory.get("excludedPaths", [])}\n'
        f'Reconstructed files to verify: {inventory.get("reassembledFiles", [])}\n', encoding='utf-8')
    print(f'Draft ready: {target}; download {candidate["pack"]["size"]} bytes')
    return candidate


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--id', required=True)
    parser.add_argument('--name', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--executable', required=True)
    parser.add_argument('--description', required=True)
    parser.add_argument('--cover', type=Path, required=True)
    parser.add_argument('--require', action='append', default=[])
    parser.add_argument('--draft-root', type=Path, default=Path(__file__).resolve().parents[2] / 'drafts')
    args = parser.parse_args()
    create(json.loads(args.inventory.read_text(encoding='utf-8')), args.draft_root, args.id, args.name,
           args.version, args.executable, args.description, args.cover, args.require)
