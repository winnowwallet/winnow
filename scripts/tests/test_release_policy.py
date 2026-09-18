"""Release version checks do not depend on a peer snapshot or checkout files."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'check-release-policy'


class ReleasePolicyTests(unittest.TestCase):
    def check(self, tag):
        with tempfile.TemporaryDirectory() as directory:
            return subprocess.run([str(SCRIPT)], cwd=directory, env={**os.environ, 'RELEASE_TAG': tag},
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode

    def test_stable_tags_and_manual_validation_need_no_peer_snapshot(self):
        for tag in ('', 'v0.7.4', 'v1.0.0', 'v10.20.30'):
            with self.subTest(tag=tag):
                self.assertEqual(self.check(tag), 0)

    def test_invalid_and_prerelease_tags_are_rejected(self):
        for tag in ('v0.7.4-rc1', '0.7.4', 'v01.2.3', 'v1.2', 'v1.2.3.4'):
            with self.subTest(tag=tag):
                self.assertNotEqual(self.check(tag), 0)
