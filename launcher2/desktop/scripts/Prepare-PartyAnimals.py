"""Prepare the host-supplied 1.17.2.0 DLL in an output directory; never edit source.

This build uses a browser thread and an injected video splash, not MessageBox.
Offsets are file offsets validated against the exact upstream SHA-256 and bytes.
No game networking, Steam API, save data or Windows-wide settings are changed.
"""
import argparse
import hashlib
import json
from pathlib import Path

SOURCE_SHA256 = 'df90a04c073a869e3086afdae5fe846fbe5b8fb2025c392e30644dedf9f849f3'


def prepare(source: bytes) -> tuple[bytes, list[dict]]:
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise ValueError('Unknown version.dll build: inspect it before preparing')
    result = bytearray(source)
    changes = []

    def replace(offset: int, before: bytes, after: bytes, reason: str):
        if len(before) != len(after) or result[offset:offset + len(before)] != before:
            raise ValueError(f'Unexpected instruction at {offset:#x}')
        result[offset:offset + len(before)] = after
        changes.append(dict(offset=hex(offset), before=before.hex(), after=after.hex(), reason=reason))

    # DWORD WINAPI thread(void*): return 0, before writing the shortcut or launching it.
    replace(0x59d0, bytes.fromhex('48895c'), bytes.fromhex('31c0c3'),
            'Browser/shortcut thread returns before any side effect')
    # Preserve wrapper cleanup and its completed flag, take its existing no-video branch.
    replace(0x10a959, bytes.fromhex('e8120d0000'), bytes.fromhex('31c0909090'),
            'Skip injected splash preparation; wrapper marks it completed and frees context')
    # Defense in depth: its GetProcAddress result is checked for null before invocation.
    symbol = b'ShellExecuteW\0'
    if source.count(symbol) != 1:
        raise ValueError('Unexpected dynamic browser resolver')
    replace(source.index(symbol), symbol, b'CocoNoLaunchX\0',
            'Disable the checked dynamic browser resolver as an independent backstop')
    return bytes(result), changes


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    prepared, changes = prepare(args.source.read_bytes())
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / 'version.dll').write_bytes(prepared)
    report = dict(sourceSha256=SOURCE_SHA256, preparedSha256=hashlib.sha256(prepared).hexdigest(),
                  size=len(prepared), changes=changes)
    (args.output / 'preparation.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))
