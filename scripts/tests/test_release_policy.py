"""Release version checks do not depend on a peer snapshot or the working directory."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'check-release-policy'


class ReleasePolicyTests(unittest.TestCase):
    def check(self, tag, notes=None):
        env = {**os.environ, 'RELEASE_TAG': tag}
        if notes is not None:
            env['TESTFLIGHT_WHATS_NEW_FILE'] = str(notes)
        with tempfile.TemporaryDirectory() as directory:
            return subprocess.run([str(SCRIPT)], cwd=directory, env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode

    def test_stable_tags_and_manual_validation_need_no_peer_snapshot(self):
        for tag in ('', 'v0.7.4', 'v1.0.0', 'v10.20.30'):
            with self.subTest(tag=tag):
                self.assertEqual(self.check(tag), 0)

    def test_invalid_and_prerelease_tags_are_rejected(self):
        for tag in ('v0.7.4-rc1', '0.7.4', 'v01.2.3', 'v1.2', 'v1.2.3.4'):
            with self.subTest(tag=tag):
                self.assertNotEqual(self.check(tag), 0)

    def test_what_to_test_must_exist_and_fit_app_store_connect(self):
        with tempfile.TemporaryDirectory() as directory:
            notes = Path(directory) / 'what-to-test.txt'
            self.assertNotEqual(self.check('v1.0.0', notes), 0, 'a missing file')
            notes.write_text('\n')
            self.assertNotEqual(self.check('v1.0.0', notes), 0, 'an empty file')
            notes.write_text('x' * 4000 + '\n')
            self.assertEqual(self.check('v1.0.0', notes), 0, 'exactly the limit')
            notes.write_text('x' * 4001)
            self.assertNotEqual(self.check('v1.0.0', notes), 0, 'one over the limit')
