import importlib.util
import hashlib
import sys
import json
import tempfile
import unittest
import zipfile
from pathlib import Path


def load(filename):
    spec = importlib.util.spec_from_file_location(filename, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    sys.modules[filename] = module
    spec.loader.exec_module(module)
    return module


packer = load('New-CocoMultipartArchives.py')
prepare = load('Prepare-PartyAnimals.py')


class MultipartTests(unittest.TestCase):
    def test_independent_parts_preserve_source_and_apply_only_selected_override(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            source = base / 'source'
            source.mkdir()
            (source / 'game.exe').write_bytes(b'original')
            (source / 'data.bin').write_bytes(b'data1234')
            override = base / 'prepared'
            override.write_bytes(b'prepared')
            output = base / 'output'
            report = packer.build(source, output, 'game-1.0', 'https://example.com/release',
                                  {'game.exe': override}, budget=10)
            self.assertEqual(len(report['archives']), 2)
            reconstructed = {}
            for archive in report['archives']:
                path = output / archive['archiveUrl'].split('/')[-1]
                self.assertEqual(packer.digest_file(path), archive['sha256'])
                with zipfile.ZipFile(path) as zipped:
                    self.assertIsNone(zipped.testzip())
                    for name in zipped.namelist():
                        self.assertNotIn(name, reconstructed)
                        reconstructed[name] = zipped.read(name)
            self.assertEqual(reconstructed, {'game.exe': b'prepared', 'data.bin': b'data1234'})
            self.assertEqual((source / 'game.exe').read_bytes(), b'original')
            self.assertEqual(json.loads((output / 'inventory.json').read_text())['unpackedBytes'], 16)
            with self.assertRaises(FileExistsError):
                packer.build(source, output, 'game-1.0', 'https://example.com/release', {}, budget=10)

    def test_rejects_private_data_and_windows_path_ambiguities(self):
        for name in ['saves/world.dat', '../file', 'C:/file', 'folder/NUL.txt', 'folder/file.', '.coco/state', 'a\\b']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                packer.safe_path(name)

    def test_resume_reuses_complete_part_and_rebuilds_interrupted_part(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            source = base / 'source'
            source.mkdir()
            (source / 'a.bin').write_bytes(b'aaaaaaaa')
            (source / 'b.bin').write_bytes(b'bbbbbbbb')
            output = base / 'output'
            first = packer.build(source, output, 'game-1.0', 'https://example.com/release', {}, budget=10)
            original = (output / 'game-1.0-part01.zip').read_bytes()
            (output / 'game-1.0-part02.zip').write_bytes(b'PK interrupted')
            resumed = packer.build(source, output, 'game-1.0', 'https://example.com/release', {}, budget=10, resume=True)
            self.assertEqual(original, (output / 'game-1.0-part01.zip').read_bytes())
            self.assertEqual(first['files'], resumed['files'])

    def test_rejects_unknown_dll_before_any_output(self):
        with self.assertRaisesRegex(ValueError, 'Unknown'):
            prepare.prepare(b'another version of the DLL')

    def test_large_file_streams_as_native_parts_and_records_reconstructed_hash(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            source = base / 'source'
            source.mkdir()
            content = bytes(range(31))
            (source / 'large.ucas').write_bytes(content)
            (source / 'Saved.lnk').write_bytes(b'personal shortcut')
            report = packer.build(source, base / 'output', 'large-1.0', 'https://example.com/release', {},
                                  budget=10, split_large=True, jobs=2, exclude=['Saved.lnk'])
            restored = {}
            for archive in report['archives']:
                with zipfile.ZipFile(base / 'output' / archive['archiveUrl'].split('/')[-1]) as zipped:
                    restored.update((name, zipped.read(name)) for name in zipped.namelist())
            original = report['reassembledFiles'][0]
            self.assertEqual(b''.join(restored[name] for name in original['pieces']), content)
            self.assertEqual(original['sha256'], hashlib.sha256(content).hexdigest())
            self.assertEqual(original['size'], len(content))
            self.assertTrue((source / 'Saved.lnk').exists())
            self.assertNotIn('Saved.lnk', restored)

    def test_generated_split_name_cannot_collide_with_real_file(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            source = base / 'source'
            source.mkdir()
            (source / 'data.bin').write_bytes(b'x' * 30)
            (source / 'data.bin.part1').write_bytes(b'original')
            with self.assertRaisesRegex(ValueError, 'collision'):
                packer.build(source, base / 'output', 'collision-1.0', 'https://example.com/release', {},
                             budget=10, split_large=True)

    @unittest.skipUnless(hasattr(zipfile, 'ZIP_ZSTANDARD'), 'Python 3.14+ Zstandard')
    def test_zstandard_archives_roundtrip(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            source = base / 'source'
            source.mkdir()
            (source / 'data').write_bytes(bytes(range(256)) * 4)
            report = packer.build(source, base / 'output', 'zstd-1.0', 'https://example.com/release', {},
                                  compression='zstd', level=9)
            with zipfile.ZipFile(base / 'output' / report['archives'][0]['archiveUrl'].split('/')[-1]) as zipped:
                self.assertEqual(zipped.getinfo('data').compress_type, zipfile.ZIP_ZSTANDARD)
                self.assertEqual(zipped.read('data'), (source / 'data').read_bytes())


if __name__ == '__main__':
    unittest.main()
