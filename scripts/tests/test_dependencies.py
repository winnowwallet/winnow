"""The research dependency must not loosen wallet or Xcode pin checks."""
import copy
import contextlib
import io
import json
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / 'check-dependencies'
NATIVE_ID = 'native-secp256k1-swift-test'
NATIVE_URL = 'https://github.com/posix4e/native-secp256k1-swift-test'
NATIVE_REVISION = '2ef204167972efc428486e823fc79b1f1bf0e9e7'
P256K_URL = 'https://github.com/21-DOT-DEV/swift-secp256k1'


class DependencyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / 'scripts').mkdir()
        self.script = self.root / 'scripts/check-dependencies'
        self.script.write_text(SCRIPT.read_text())
        self.project = ('packages:\n  Winnow:\n    path: .\n'
                        '  swift-secp256k1:\n    url: ' + P256K_URL + '\n'
                        '    exactVersion: 0.23.2\n')
        self.pins = [
            {'identity': 'swift-secp256k1', 'location': P256K_URL,
             'state': {'revision': 'a' * 40, 'version': '0.23.2'}},
            {'identity': NATIVE_ID, 'location': NATIVE_URL,
             'state': {'revision': NATIVE_REVISION}},
        ]
        self.dependencies = [
            {'sourceControl': [{'identity': p['identity'],
                                'location': {'remote': [{'urlString': p['location']}]},
                                'requirement': ({'exact': [p['state']['version']]}
                                                if 'version' in p['state'] else
                                                {'revision': [p['state']['revision']]})}]}
            for p in self.pins
        ]
        self.xcode = [
            {'packageRef': {'identity': p['identity'], 'location': p['location']},
             'state': {'name': 'sourceControlCheckout', 'checkoutState': copy.deepcopy(p['state'])}}
            for p in self.pins
        ]

    def invoke(self, xcode=False):
        (self.root / 'project.yml').write_text(self.project)
        (self.root / 'Package.resolved').write_text(json.dumps({'pins': self.pins}))
        arguments = [str(self.script)]
        if xcode:
            derived = self.root / 'DerivedData'
            (derived / 'SourcePackages').mkdir(parents=True, exist_ok=True)
            (derived / 'SourcePackages/workspace-state.json').write_text(
                json.dumps({'object': {'dependencies': self.xcode}}))
            arguments += ['--xcode', str(derived)]
        with patch('sys.argv', arguments), contextlib.redirect_stdout(io.StringIO()), \
                patch('subprocess.check_output', return_value=json.dumps({'dependencies': self.dependencies})):
            runpy.run_path(str(self.script), run_name='__main__')

    def test_matching_pins_pass_independent_of_manifest_order(self):
        self.dependencies.reverse()
        self.invoke(xcode=True)

    def test_native_revision_cannot_drift_even_if_manifest_and_lock_agree(self):
        self.pins[1]['state']['revision'] = 'b' * 40
        self.dependencies[1]['sourceControl'][0]['requirement'] = {'revision': ['b' * 40]}
        with self.assertRaisesRegex(SystemExit, 'reviewed native revision'):
            self.invoke()

    def test_native_manifest_cannot_follow_branch(self):
        self.dependencies[1]['sourceControl'][0]['requirement'] = {'branch': ['main']}
        with self.assertRaisesRegex(SystemExit, 'pin the reviewed native revision'):
            self.invoke()

    def test_native_lock_cannot_follow_branch_or_another_repository(self):
        self.pins[1]['state']['branch'] = 'main'
        with self.assertRaisesRegex(SystemExit, 'reviewed native revision'):
            self.invoke()
        del self.pins[1]['state']['branch']
        self.pins[1]['location'] = 'https://example.invalid/native-secp256k1-swift-test'
        with self.assertRaisesRegex(SystemExit, 'reviewed native revision'):
            self.invoke()

    def test_unexpected_and_duplicate_lock_dependencies_fail(self):
        self.pins.append(copy.deepcopy(self.pins[0]))
        with self.assertRaisesRegex(SystemExit, 'duplicate dependency'):
            self.invoke()
        self.pins[-1]['identity'] = 'unexpected'
        with self.assertRaisesRegex(SystemExit, 'unexpected root dependency'):
            self.invoke()

    def test_manifest_cannot_add_local_dependency_or_drop_remote(self):
        self.dependencies.append({'fileSystem': [{'identity': 'local', 'path': '/tmp/local'}]})
        with self.assertRaisesRegex(SystemExit, 'unexpected root manifest dependency'):
            self.invoke()
        self.dependencies = self.dependencies[:1]
        with self.assertRaisesRegex(SystemExit, 'dependency identities disagree'):
            self.invoke()

    def test_manifest_cannot_change_remote_location(self):
        self.dependencies[0]['sourceControl'][0]['location']['remote'][0]['urlString'] += '-fork'
        with self.assertRaisesRegex(SystemExit, 'dependency locations disagree'):
            self.invoke()

    def test_p256k_exact_requirement_and_project_version_still_checked(self):
        self.dependencies[0]['sourceControl'][0]['requirement'] = {'range': [{'lowerBound': '0.23.2', 'upperBound': '1.0.0'}]}
        with self.assertRaisesRegex(SystemExit, 'root manifest and lockfile disagree'):
            self.invoke()
        self.dependencies[0]['sourceControl'][0]['requirement'] = {'exact': ['0.23.2']}
        self.project = self.project.replace('exactVersion: 0.23.2', 'exactVersion: 0.23.1')
        with self.assertRaisesRegex(SystemExit, 'Xcode must pin'):
            self.invoke()

    def test_winnow_must_still_be_local(self):
        self.project = self.project.replace('path: .', 'path: ../another-checkout')
        with self.assertRaisesRegex(SystemExit, 'root package locally'):
            self.invoke()

    def test_xcode_must_match_both_committed_pins(self):
        for index in range(2):
            old = self.xcode[index]['state']['checkoutState']['revision']
            self.xcode[index]['state']['checkoutState']['revision'] = 'c' * 40
            with self.assertRaisesRegex(SystemExit, 'Xcode resolved dependencies differ'):
                self.invoke(xcode=True)
            self.xcode[index]['state']['checkoutState']['revision'] = old

    def test_xcode_missing_or_extra_dependency_fails(self):
        removed = self.xcode.pop()
        with self.assertRaisesRegex(SystemExit, 'Xcode resolved dependencies differ'):
            self.invoke(xcode=True)
        self.xcode.append(removed)
        extra = copy.deepcopy(removed)
        extra['packageRef']['identity'] = 'unexpected'
        self.xcode.append(extra)
        with self.assertRaisesRegex(SystemExit, 'Xcode resolved dependencies differ'):
            self.invoke(xcode=True)


if __name__ == '__main__':
    unittest.main()
