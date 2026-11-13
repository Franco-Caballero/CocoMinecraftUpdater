"""Build independent, SHA-pinned ZIPs below GitHub's 2 GiB asset limit.

Reads source files once while recording hashes. Overrides are explicitly selected
prepared files; the source is never changed. Outputs a review inventory, not an
authoritative catalog or a signed channel. --split-large streams oversized files
as .part1/.part2 entries understood by Coco's native installer, without temporary
copies. Zstandard uses Python 3.14+ and is already supported by the native client.
"""
import argparse
import hashlib
import json
import os
import re
import time
import zipfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path


def safe_path(name):
    parts = name.split('/')
    for part in parts:
        if (not part or part in ('.', '..') or part.endswith(('.', ' '))
                or re.search(r'[\x00-\x1f<>:"\\|?*]', part)
                or re.fullmatch(r'CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]', part.split('.')[0], re.I)
                or part.lower() in {'saves', 'playerdata', 'advancements', 'stats', '.coco'}):
            raise ValueError(f'Unsafe or persistent-data path: {name}')
    return name


def digest_file(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


@dataclass
class Entry:
    name: str
    path: Path
    size: int
    offset: int = 0


def entry_chunks(entry):
    with entry.path.open('rb') as stream:
        stream.seek(entry.offset)
        remaining = entry.size
        while remaining:
            chunk = stream.read(min(4 * 1024 * 1024, remaining))
            if not chunk:
                raise ValueError(f'Source truncated: {entry.name}')
            remaining -= len(chunk)
            yield chunk


def entry_digest(entry):
    digest = hashlib.sha256()
    for chunk in entry_chunks(entry):
        digest.update(chunk)
    return digest.hexdigest()


def assert_no_links(path):
    for candidate in [path, *path.parents]:
        if candidate.is_symlink() or candidate.is_junction():
            raise ValueError(f'Link rejected: {candidate}')


def build(source, output, prefix, base_url, overrides, budget=1_800_000_000,
          resume=False, split_large=False, compression='deflate', level=1, jobs=1, exclude=()):
    assert_no_links(source)
    assert_no_links(output)
    source = source.resolve(strict=True)
    output = output.resolve()
    if not re.fullmatch(r'[a-z0-9][a-z0-9.-]*[a-z0-9]', prefix) or not base_url.startswith('https://'):
        raise ValueError('Invalid prefix or release base URL')
    if output == source or source in output.parents:
        raise ValueError('Output must be outside source')
    files = []
    seen = set()
    excluded = {safe_path(name) for name in exclude}
    excluded_found = set()
    originals = {}
    split_sources = {}
    for directory, dirs, names in os.walk(source, followlinks=False):
        for name in dirs + names:
            path = Path(directory) / name
            if path.is_symlink() or path.is_junction():
                raise ValueError(f'Link rejected: {path}')
        for name in names:
            path = Path(directory) / name
            relative = safe_path(path.relative_to(source).as_posix())
            if relative in excluded:
                excluded_found.add(relative)
                continue
            if path.suffix.lower() in {'.url', '.lnk'}:
                raise ValueError(f'Explicitly exclude promotional/personal shortcuts: {relative}')
            if relative.lower() in seen:
                raise ValueError(f'Windows path collision: {relative}')
            seen.add(relative.lower())
            selected = overrides.get(relative, path)
            assert_no_links(selected)
            size = selected.stat().st_size
            originals[relative] = (selected, size, selected.stat().st_mtime_ns)
            if size > budget and not split_large:
                raise ValueError(f'File exceeds part budget: {relative}')
            if size > budget:
                pieces = []
                for index, offset in enumerate(range(0, size, budget), 1):
                    piece_name = relative + f'.part{index}'
                    pieces.append(piece_name)
                    files.append(Entry(piece_name, selected, min(budget, size - offset), offset))
                split_sources[relative] = pieces
            else:
                files.append(Entry(relative, selected, size))
    if excluded - excluded_found:
        raise ValueError('Excluded path does not exist')
    if set(overrides) - originals.keys():
        raise ValueError('Override does not replace an existing source file')
    names = set()
    for entry in files:
        if entry.name.lower() in names:
            raise ValueError(f'Generated split path collision: {entry.name}')
        names.add(entry.name.lower())
    files.sort(key=lambda entry: (entry.name.count('/'), entry.name.lower()))
    groups = [[]]
    current = 0
    for entry in files:
        if current + entry.size > budget:
            groups.append([])
            current = 0
        groups[-1].append(entry)
        current += entry.size
    if output.is_symlink() or output.is_junction():
        raise ValueError('Output link rejected')
    output.mkdir(parents=True, exist_ok=resume)
    started = time.monotonic()
    archives = []
    inventory = []
    if compression == 'zstd':
        if not hasattr(zipfile, 'ZIP_ZSTANDARD'):
            raise ValueError('Zstandard needs Python 3.14+; use --compression deflate otherwise')
        method = zipfile.ZIP_ZSTANDARD
    elif compression == 'store':
        method = zipfile.ZIP_STORED
    elif compression == 'deflate':
        method = zipfile.ZIP_DEFLATED
    else:
        raise ValueError('Unknown compression')
    if not 1 <= jobs <= 4:
        raise ValueError('Use between 1 and 4 packaging workers')

    def package(index, group):
        target = output / f'{prefix}-part{index:02d}.zip'
        records = []
        if resume and target.exists():
            if target.is_symlink() or target.is_junction():
                raise ValueError('Archive link rejected')
            try:
                with zipfile.ZipFile(target) as existing:
                    if existing.namelist() != [entry.name for entry in group]:
                        raise ValueError('Existing archive has different entries')
                    for entry in group:
                        info = existing.getinfo(entry.name)
                        if info.file_size != entry.size:
                            raise ValueError('Existing archive has different sizes')
                        with existing.open(info) as stream:
                            sha = hashlib.file_digest(stream, 'sha256').hexdigest()
                        if sha != entry_digest(entry):
                            raise ValueError('Existing archive differs from selected source')
                        records.append(dict(path=entry.name, size=entry.size, sha256=sha))
            except zipfile.BadZipFile:
                # Only this exact generated target, explicitly requested with --resume.
                target.unlink()
                records = []
            else:
                sha = digest_file(target)
                print(f'{target.name}: reused verified completed part', flush=True)
                return index, dict(archiveUrl=f'{base_url.rstrip("/")}/{target.name}',
                                   sha256=sha, size=target.stat().st_size), [dict(**r, archiveSha256=sha) for r in records]
        with zipfile.ZipFile(target, 'x', compression=method, compresslevel=level, allowZip64=True) as archive:
            for entry in group:
                hasher = hashlib.sha256()
                count = 0
                with archive.open(entry.name, 'w', force_zip64=True) as dest:
                    for chunk in entry_chunks(entry):
                        hasher.update(chunk)
                        dest.write(chunk)
                        count += len(chunk)
                if count != entry.size:
                    raise ValueError(f'Source changed during packaging: {entry.name}')
                records.append(dict(path=entry.name, size=entry.size, sha256=hasher.hexdigest()))
        size = target.stat().st_size
        if size >= 2 * 1024**3:
            raise ValueError('Archive exceeds GitHub asset limit')
        sha = digest_file(target)
        print(f'{target.name}: {size} bytes, SHA256 {sha}, {time.monotonic()-started:.1f}s', flush=True)
        return index, dict(archiveUrl=f'{base_url.rstrip("/")}/{target.name}', sha256=sha, size=size), [dict(**r, archiveSha256=sha) for r in records]

    completed = {}
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        pending = [pool.submit(package, index, group) for index, group in enumerate(groups, 1)]
        for future in as_completed(pending):
            index, archive, records = future.result()
            completed[index] = (archive, records)
    for index in sorted(completed):
        archive, records = completed[index]
        archives.append(archive)
        inventory.extend(records)
    reconstructed = []
    for name, pieces in split_sources.items():
        path, size, _ = originals[name]
        reconstructed.append(dict(path=name, size=size, sha256=digest_file(path), pieces=pieces))
    for name, (path, size, modified) in originals.items():
        if path.stat().st_size != size or path.stat().st_mtime_ns != modified:
            raise ValueError(f'Source changed during packaging: {name}')
    report = dict(archives=archives, files=inventory, seconds=round(time.monotonic()-started, 2),
                  unpackedBytes=sum(entry.size for entry in files), reassembledFiles=reconstructed,
                  compression=compression, level=level, excludedPaths=sorted(excluded))
    (output / 'inventory.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--prefix', required=True)
    parser.add_argument('--base-url', required=True)
    parser.add_argument('--override', action='append', default=[], metavar='RELATIVE=PREPARED_FILE')
    parser.add_argument('--resume', action='store_true', help='Verify and reuse completed parts after an interruption')
    parser.add_argument('--split-large', action='store_true', help='Stream oversized files as native .partN entries')
    parser.add_argument('--compression', choices=['deflate', 'store', 'zstd'], default='deflate')
    parser.add_argument('--level', type=int, default=1)
    parser.add_argument('--jobs', type=int, default=1)
    parser.add_argument('--exclude', action='append', default=[], help='Exact relative source path to omit')
    args = parser.parse_args()
    replacements = {}
    for value in args.override:
        relative, prepared = value.split('=', 1)
        relative = safe_path(relative)
        if relative in replacements:
            raise ValueError('Duplicate override')
        replacements[relative] = Path(prepared).resolve(strict=True)
    build(args.source, args.output, args.prefix, args.base_url, replacements, resume=args.resume,
          split_large=args.split_large, compression=args.compression, level=args.level,
          jobs=args.jobs, exclude=args.exclude)
