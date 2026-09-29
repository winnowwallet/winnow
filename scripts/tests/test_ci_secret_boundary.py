"""Repository secrets must never cross into a validation worker workflow."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2] / '.github/workflows'


def jobs(text):
    section = text.split('\njobs:\n', 1)[1]
    starts = list(re.finditer(r'^  ([\w-]+):\s*$', section, re.M))
    return {m[1]: section[m.end():starts[i+1].start() if i+1 < len(starts) else len(section)]
            for i, m in enumerate(starts)}


class SecretBoundaryTests(unittest.TestCase):
    def test_workers_have_no_repository_secret_channel(self):
        for name in ('ci-hosted.yml', 'ci-tdx.yml'):
            with self.subTest(workflow=name):
                text = (ROOT/name).read_text()
                self.assertNotRegex(text, r'\bsecrets\s*[:.]')
                self.assertNotRegex(text, r'(?m)^\s+environment:', 'An environment could inject signing secrets')
        for name in ('ci.yml', 'tdx-trial.yml', 'release.yml'):
            for job, body in jobs((ROOT/name).read_text()).items():
                if re.search(r'uses: \./\.github/workflows/(ci|ci-hosted|ci-tdx)\.yml', body):
                    with self.subTest(workflow=name, job=job):
                        self.assertNotRegex(body, r'\bsecrets\s*[:.]')

    def test_only_deployment_receives_named_cloudflare_secrets(self):
        caller = (ROOT/'ci.yml').read_text()
        self.assertNotRegex(caller, r'secrets:\s*inherit')
        receivers = {name for name, body in jobs(caller).items() if re.search(r'\bsecrets\s*[:.]', body)}
        self.assertEqual(receivers, {'website'})
        self.assertEqual(set(re.findall(r'secrets\.([A-Z_]+)', caller)), {'CF_API_TOKEN', 'CF_ACCOUNT_ID'})
        deployment = jobs(caller)['website']
        self.assertIn('uses: ./.github/workflows/site.yml', deployment)
        self.assertNotIn('runs-on:', deployment)


class AggregateGateTests(unittest.TestCase):
    def test_failed_cancelled_or_unexpectedly_skipped_deployment_blocks_gate(self):
        import itertools
        import os
        import subprocess
        import textwrap
        script = textwrap.dedent(jobs((ROOT/'ci.yml').read_text())['validation'].split('run: |\n', 1)[1])
        statuses = ('success', 'skipped', 'failure', 'cancelled')
        for hosted, tdx, lightning, website, deploy in itertools.product(statuses, statuses, statuses, statuses, ('true', 'false')):
            expected = ((hosted, tdx) in [('success', 'skipped'), ('skipped', 'success')]
                        and lightning == 'success'
                        and website == ('success' if deploy == 'true' else 'skipped'))
            with self.subTest(hosted=hosted, tdx=tdx, website=website, deploy=deploy):
                result = subprocess.run(['bash', '-e', '-c', script],
                                        env={**os.environ, 'HOSTED': hosted, 'TDX': tdx,
                                             'WEBSITE': website, 'DEPLOY': deploy, 'LIGHTNING': lightning},
                                        capture_output=True)
                self.assertEqual(result.returncode == 0, expected)
