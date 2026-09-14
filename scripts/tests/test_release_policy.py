"""Release freshness checks must fail from the recorded observation, not git age."""
import datetime as dt
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'check-release-policy'


class ReleasePolicyTests(unittest.TestCase):
    def check(self, *, age=0, source_hash='a' * 64, commit='c' * 40, observation=True, tag='v0.6.3'):
        now = dt.datetime.now(dt.timezone.utc)
        day = (now - dt.timedelta(days=age)).date().isoformat()
        text = '// Generation: ' + now.isoformat() + ', 100 peers\n'
        text += '// winnow-census artifact of ' + day + ', recorded tip 900000.\n'
        if observation:
            text += '// Source SHA256: ' + source_hash + '\n'
            if commit:
                text += '// Source commit: ' + commit + '\n'
            text += '// Observation date: ' + day + '; generated: ' + now.isoformat() + '\n'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Sources/WalletCore/Network/Protocol/FallbackPeersGenerated.swift'
            path.parent.mkdir(parents=True)
            path.write_text(text)
            return subprocess.run([str(SCRIPT)], cwd=directory, env={**os.environ, 'RELEASE_TAG': tag},
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode

    def test_fresh_and_seven_day_old_observations_are_accepted(self):
        self.assertEqual(self.check(age=0), 0)
        self.assertEqual(self.check(age=7), 0)

    def test_new_generation_cannot_refresh_old_or_future_observation(self):
        self.assertNotEqual(self.check(age=8), 0)
        self.assertNotEqual(self.check(age=-1), 0)

    def test_source_provenance_and_stable_version_are_required(self):
        self.assertNotEqual(self.check(source_hash='not-a-hash'), 0)
        self.assertNotEqual(self.check(observation=False), 0)
        self.assertNotEqual(self.check(tag='v0.6.3-rc1'), 0)

    def test_the_bundle_must_name_the_census_commit_it_came_from(self):
        self.assertNotEqual(self.check(commit=None), 0)
        self.assertNotEqual(self.check(commit='abc123'), 0)
