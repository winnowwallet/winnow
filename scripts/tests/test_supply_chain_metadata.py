"""Source attribution must follow the repository the checkout was built from."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / 'scripts/generate-supply-chain-metadata'
UPSTREAM = 'https://github.com/winnowwallet/winnow'
# Any repository other than upstream, so a hard-coded default cannot pass.
OTHER = 'https://github.com/example/winnow-copy'


class SupplyChainMetadataTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.source = self.base / 'source'
        self.source.mkdir()
        (self.source / 'Package.swift').write_text('// Package fixture\n')
        (self.source / 'project.yml').write_text('name: WinnowApp\n')
        (self.source / 'Package.resolved').write_text(json.dumps({'pins': [dict(
            identity='reference', location='https://example.invalid/reference.git',
            state=dict(revision='a' * 40, version='1.0.0'))]}))
        self.commit = self.commit_fixture(self.source)
        self.ipa = self.base / 'WinnowApp.ipa'
        self.ipa.write_bytes(b'independently verified IPA fixture\x00\xff')
        self.digest = hashlib.sha256(self.ipa.read_bytes()).hexdigest()

    def git(self, root, *args):
        environment = dict(os.environ, GIT_AUTHOR_DATE='2026-09-28T12:00:00+00:00',
                           GIT_COMMITTER_DATE='2026-09-28T12:00:00+00:00')
        return subprocess.check_output(['git', '-C', str(root), *args], env=environment,
                                       text=True, stderr=subprocess.PIPE).strip()

    def commit_fixture(self, root):
        self.git(root, 'init', '-q')
        self.git(root, 'add', '.')
        self.git(root, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'Fixture')
        return self.git(root, 'rev-parse', 'HEAD')

    def generate(self, *options, output='metadata'):
        directory = self.base / output
        result = subprocess.run([sys.executable, str(GENERATOR), '--output-dir', str(directory),
                                 '--subject', str(self.ipa), '--subject-name', self.ipa.name, *options],
                                cwd=self.source, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return directory

    def documents(self, directory):
        return [json.loads((directory / name).read_text()) for name in
                ('winnow.spdx.json', 'winnow-build-provenance.json')]

    def assert_attribution(self, directory, repository, subject_name=None):
        spdx, provenance = self.documents(directory)
        package = next(item for item in spdx['packages'] if item['SPDXID'] == 'SPDXRef-Package-winnow')
        self.assertEqual(package['downloadLocation'], repository)
        self.assertEqual(package['versionInfo'], self.commit)
        self.assertEqual(spdx['documentNamespace'], f'{repository}/sbom/{self.commit}')
        predicate = provenance['predicate']
        sources = [item for item in predicate['buildDefinition']['resolvedDependencies'] if item['uri'].startswith('git+')]
        self.assertEqual(sources, [dict(uri=f'git+{repository}.git', digest=dict(sha1=self.commit))])
        self.assertEqual(provenance['subject'], [dict(name=subject_name or self.ipa.name, digest=dict(sha256=self.digest))])
        self.assertEqual(predicate['runDetails']['metadata']['invocationId'], self.commit)

    def test_upstream_default_preserves_all_source_attributions_and_subject(self):
        directory = self.generate()
        self.assert_attribution(directory, UPSTREAM)
        spdx, provenance = self.documents(directory)
        self.assertEqual(spdx['creationInfo']['created'], '2026-09-28T12:00:00Z')
        self.assertEqual(provenance['predicate']['runDetails']['builder']['id'],
                         UPSTREAM + '/.github/workflows/ci.yml')

    def test_another_repository_and_commit_attribute_the_actual_ipa_deterministically(self):
        first = self.generate('--source-repository', OTHER)
        second = self.generate('--source-repository', OTHER, output='replay')
        self.assert_attribution(first, OTHER)
        for name in ('winnow.spdx.json', 'winnow-build-provenance.json'):
            self.assertEqual((first / name).read_bytes(), (second / name).read_bytes())
        normalized = self.generate('--source-repository', OTHER + '.git/', output='normalized')
        for name in ('winnow.spdx.json', 'winnow-build-provenance.json'):
            self.assertEqual((first / name).read_bytes(), (normalized / name).read_bytes())

    def test_source_tree_subject_still_identifies_the_checkout_tree(self):
        directory = self.base / 'tree'
        subprocess.run([sys.executable, str(GENERATOR), '--output-dir', str(directory),
                        '--source-repository', OTHER], cwd=self.source, check=True)
        _, provenance = self.documents(directory)
        self.assertEqual(provenance['subject'], [dict(name='winnow-source-tree',
                         digest=dict(sha1=self.git(self.source, 'rev-parse', 'HEAD^{tree}')))])

    def test_repository_options_reject_credentials_and_nonrepository_urls(self):
        for repository in ['http://example.invalid/repo', 'https://secret@example.invalid/repo',
                           'https://example.invalid/', OTHER + '?token=secret', OTHER + '#ref', OTHER + ' bad']:
            with self.subTest(repository=repository):
                result = subprocess.run([sys.executable, str(GENERATOR), '--output-dir', str(self.base / 'invalid'),
                                         '--source-repository', repository], cwd=self.source, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.base / 'invalid').exists())

    def test_all_ci_and_release_generations_pass_actual_workflow_repository(self):
        results = self.base / 'ci-results'
        debug = results / 'production-build/release/winnow-debug'
        debug.parent.mkdir(parents=True)
        debug.write_bytes(self.ipa.read_bytes())
        exported = self.source / 'build/export/WinnowApp.ipa'
        exported.parent.mkdir(parents=True)
        exported.write_bytes(self.ipa.read_bytes())
        environment = dict(os.environ, CI_RESULTS=str(results), GITHUB_REPOSITORY='example/winnow-copy',
                           GITHUB_SHA=self.commit, dir='tdx')
        files = [ROOT / '.github/workflows/ci-hosted.yml', ROOT / '.github/workflows/release.yml', ROOT / 'scripts/ci-tdx-lane']
        expected_counts = [2, 1, 1]
        outputs = [[results / 'supply-chain', results / 'supply-chain-replay'],
                   [self.source / 'build/supply-chain'], [results / 'tdx']]
        for file, expected, directories in zip(files, expected_counts, outputs):
            text = file.read_text().replace('\\\n', ' ')
            # Generator command continues until the next script or workflow key.
            commands = re.findall(r'scripts/generate-supply-chain-metadata[^\n]*(?:\n[ ]+(?:--[^\n]*))*', text)
            with self.subTest(file=file):
                self.assertEqual(len(commands), expected)
                for command, directory in zip(commands, directories):
                    self.assertIn('--source-repository "https://github.com/$GITHUB_REPOSITORY"', command)
                    command = command.replace('scripts/generate-supply-chain-metadata',
                                              shlex.quote(sys.executable) + ' ' + shlex.quote(str(GENERATOR)))
                    command = command.replace('${{ github.repository }}', environment['GITHUB_REPOSITORY'])
                    command = command.replace('${{ github.workflow_sha }}', self.commit)
                    command = ' '.join(command.splitlines())
                    result = subprocess.run(['bash', '-c', command], cwd=self.source, env=environment,
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    name = 'WinnowApp.ipa' if file.name == 'release.yml' else 'winnow-debug'
                    self.assert_attribution(directory, OTHER, subject_name=name)
