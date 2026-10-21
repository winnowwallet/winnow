import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'generate-supply-chain-metadata'
ROOT = SCRIPT.parents[1]


def generate(cwd, output):
    subprocess.check_call(['python3', str(SCRIPT), '--output-dir', str(output)], cwd=cwd)
    return (json.loads((output / 'winnow.spdx.json').read_text()),
            json.loads((output / 'winnow-build-provenance.json').read_text()))


def repository(directory, lockfile=None):
    root = Path(directory)

    def git(*args):
        subprocess.check_output(['git', '-C', directory, *args], stderr=subprocess.DEVNULL)
    git('init')
    git('config', 'user.name', 'Test')
    git('config', 'user.email', 'test@example.invalid')
    (root / 'Package.swift').write_text('// swift-tools-version: 6.0\n')
    (root / 'project.yml').write_text('name: WinnowApp\n')
    if lockfile is not None:
        (root / 'Package.resolved').write_text(json.dumps(lockfile))
    git('add', '.')
    git('commit', '-m', 'baseline')
    return Path(subprocess.check_output(['git', '-C', directory, 'rev-parse', '--show-toplevel'], text=True).strip())


class SupplyChainMetadataTests(unittest.TestCase):
    def test_no_lockfile_describes_the_root_package_alone(self):
        # SwiftPM writes no Package.resolved for a package without dependencies.
        with tempfile.TemporaryDirectory() as d:
            root = repository(d)
            spdx, provenance = generate(root, root / 'out')
            self.assertEqual(spdx['spdxVersion'], 'SPDX-2.3')
            self.assertEqual(spdx['dataLicense'], 'CC0-1.0')
            self.assertEqual(spdx['SPDXID'], 'SPDXRef-DOCUMENT')
            self.assertTrue(spdx['name'] and spdx['documentNamespace'] and spdx['creationInfo']['created'])
            self.assertEqual([p['SPDXID'] for p in spdx['packages']], ['SPDXRef-Package-winnow'])
            self.assertEqual(spdx['relationships'], [{'spdxElementId': 'SPDXRef-DOCUMENT', 'relationshipType': 'DESCRIBES',
                                                      'relatedSpdxElement': 'SPDXRef-Package-winnow'}])
            build = provenance['predicate']['buildDefinition']
            self.assertEqual([m['uri'] for m in build['resolvedDependencies']],
                             ['file:Package.swift', 'file:project.yml', 'git+https://github.com/winnowwallet/winnow.git'])
            self.assertIsNone(build['externalParameters']['packageLock'])

    def test_a_pinned_package_is_recorded_as_a_dependency(self):
        pin = {'identity': 'example', 'kind': 'remoteSourceControl', 'location': 'https://example.invalid/example',
               'state': {'revision': 'a' * 40, 'version': '1.0.0'}}
        with tempfile.TemporaryDirectory() as d:
            root = repository(d, {'originHash': 'x', 'pins': [pin], 'version': 3})
            spdx, provenance = generate(root, root / 'out')
            self.assertEqual([p['SPDXID'] for p in spdx['packages']], ['SPDXRef-Package-winnow', 'SPDXRef-Package-example'])
            self.assertIn({'spdxElementId': 'SPDXRef-Package-winnow', 'relationshipType': 'DEPENDS_ON',
                           'relatedSpdxElement': 'SPDXRef-Package-example'}, spdx['relationships'])
            build = provenance['predicate']['buildDefinition']
            self.assertIn('file:Package.resolved', [m['uri'] for m in build['resolvedDependencies']])
            self.assertIn('https://example.invalid/example', [m['uri'] for m in build['resolvedDependencies']])
            self.assertEqual(build['externalParameters']['packageLock'], 'Package.resolved')

    def test_this_checkout_ships_no_third_party_package(self):
        # The SBOM of the repository itself matches the app: one package, no pins.
        with tempfile.TemporaryDirectory() as d:
            spdx, _ = generate(ROOT, Path(d) / 'out')
            self.assertEqual([p['name'] for p in spdx['packages']], ['winnow'])
            self.assertFalse((ROOT / 'Package.resolved').exists())
