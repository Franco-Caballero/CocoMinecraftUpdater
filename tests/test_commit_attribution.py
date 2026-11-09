import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'tools/check_commit_attribution.py'
spec = importlib.util.spec_from_file_location('attribution', SCRIPT)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class AttributionTests(unittest.TestCase):
    def test_allows_human_coauthors_and_normal_prose(self):
        self.assertFalse(guard.message_errors('Document Claude settings\n\nCo-authored-by: Alice <alice@example.com>'))

    def test_blocks_case_insensitive_assistant_trailers(self):
        for identity in ['Claude Opus <noreply@anthropic.com>', 'Codex <bot@example.com>', 'Copilot <ai@example.com>']:
            self.assertTrue(guard.message_errors('Fix\n\ncO-aUtHoReD-bY: ' + identity))

    def test_pre_push_catches_old_attribution_even_with_a_clean_tip(self):
        with tempfile.TemporaryDirectory() as folder:
            env = {**os.environ, 'GIT_AUTHOR_NAME': 'Maintainer', 'GIT_AUTHOR_EMAIL': 'owner@example.com',
                   'GIT_COMMITTER_NAME': 'Maintainer', 'GIT_COMMITTER_EMAIL': 'owner@example.com'}
            def git(*args):
                return subprocess.check_output(['git', '-C', folder, *args], env=env, stderr=subprocess.DEVNULL).decode().strip()
            git('init', '-q')
            git('-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-qm', 'Initial')
            clean = git('rev-parse', 'HEAD')
            git('-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-qm', 'Change\n\nCo-authored-by: Claude <noreply@anthropic.com>')
            git('-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-qm', 'Clean tip')
            dirty = git('rev-parse', 'HEAD')
            def check(sha):
                return subprocess.run([sys.executable, str(SCRIPT), '--pre-push'], cwd=folder,
                    input=f'refs/heads/main {sha} refs/heads/main {"0"*40}\n', text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(check(clean).returncode, 0)
            self.assertEqual(check(dirty).returncode, 1)
            self.assertIn('assistant coauthor', check(dirty).stderr)


if __name__ == '__main__':
    unittest.main()
