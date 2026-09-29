"""Release evidence must identify the source and survive independent readback."""
import copy
import hashlib
import runpy
from pathlib import Path
import json
import tempfile
import unittest
import subprocess
import sys
import ast
from types import SimpleNamespace

RELEASE = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'release-lightning'))
SOURCE = 'a' * 40


class LightningReleaseTests(unittest.TestCase):
    def test_pinned_ci_selects_exact_green_run_even_when_another_run_is_newer(self):
        script = Path(__file__).resolve().parents[1] / 'release-lightning'
        main = next(node for node in ast.parse(script.read_text()).body if isinstance(node, ast.FunctionDef) and node.name == 'main')
        selection = next(node.value for node in main.body if isinstance(node, ast.Assign)
                         and any(isinstance(target, ast.Name) and target.id == 'green' for target in node.targets))
        expression = compile(ast.Expression(selection), str(script), 'eval')
        runs = [
            dict(databaseId=102, headSha=SOURCE, status='completed', conclusion='success'),
            dict(databaseId=101, headSha=SOURCE, status='completed', conclusion='success'),
            dict(databaseId=100, headSha=SOURCE, status='completed', conclusion='failure'),
            dict(databaseId=99, headSha='b' * 40, status='completed', conclusion='success'),
        ]
        for requested, expected in [(101, 101), (102, 102), (None, 102), (100, None), (99, None), (103, None)]:
            with self.subTest(requested=requested):
                selected = eval(expression, {'runs': runs, 'args': SimpleNamespace(commit=SOURCE, ci_run=requested)})
                self.assertEqual(selected['databaseId'] if selected else None, expected)

    def test_optimized_python_cannot_disable_release_validation(self):
        script = Path(__file__).resolve().parents[1] / 'release-lightning'
        result = subprocess.run([sys.executable, '-O', str(script), '--help'], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Release validation requires Python assertions', result.stderr)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.proof = self.root / 'proof.txt'
        self.proof.write_text('independent device and classification evidence')
        self.evidence = dict(source=SOURCE, bundle=RELEASE['BUNDLE'], physical_device=True,
            checks={name: 'passed' for name in ('owner_authentication', 'cancelled_authentication',
                'file_protection', 'exact_share', 'ipad', 'large_text')},
            artifacts=[dict(path='proof.txt', sha256=hashlib.sha256(self.proof.read_bytes()).hexdigest())],
            encryption=dict(mode='exempt', reviewed_by='test reviewer', rationale='test determination', artifact='proof.txt'))

    def verify(self, evidence, **options):
        path = self.root / 'evidence.json'
        path.write_text(json.dumps(evidence))
        return RELEASE['check_evidence'](path, SOURCE, **options)

    def test_internal_beta_can_defer_physical_checks_without_claiming_they_passed(self):
        self.evidence.update(physical_device=False, device_checks_deferred_to_testflight=True)
        for name in ('owner_authentication', 'cancelled_authentication', 'file_protection', 'exact_share'):
            self.evidence['checks'][name] = 'pending'
        self.verify(self.evidence)
        for field, value in [('physical_device', True), ('device_checks_deferred_to_testflight', False)]:
            with self.subTest(field=field), self.assertRaises(AssertionError):
                self.verify(dict(self.evidence, **{field: value}))
        for value in ['failed', 'passed']:
            evidence = copy.deepcopy(self.evidence)
            evidence['checks']['file_protection'] = value
            with self.subTest(value=value), self.assertRaises(AssertionError):
                self.verify(evidence)

    def test_pending_encryption_can_only_upload_with_a_retained_inventory(self):
        self.evidence['encryption'] = dict(mode='pending', artifact='proof.txt')
        with self.assertRaises(AssertionError):
            self.verify(self.evidence)
        self.verify(self.evidence, allow_pending_encryption=True)
        self.evidence['encryption']['artifact'] = 'missing.txt'
        with self.assertRaises(AssertionError):
            self.verify(self.evidence, allow_pending_encryption=True)

    def test_pending_upload_omits_both_declaration_keys_from_generated_project(self):
        project = self.root / 'project.pbxproj'
        project.write_text('settings = {\n\tINFOPLIST_KEY_ITSAppUsesNonExemptEncryption = YES;\n\tOTHER_SETTING = YES;\n};\n')
        RELEASE['defer_encryption_questionnaire'](project)
        self.assertNotIn('ITSAppUsesNonExemptEncryption', project.read_text())
        self.assertIn('OTHER_SETTING = YES;', project.read_text())
        with self.assertRaises(AssertionError):
            RELEASE['defer_encryption_questionnaire'](project)
        project.write_text('INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = YES;\nINFOPLIST_KEY_ITSEncryptionExportComplianceCode = unreviewed;\n')
        with self.assertRaises(AssertionError):
            RELEASE['defer_encryption_questionnaire'](project)

    def test_reviewed_exemption_and_declaration_are_distinct(self):
        self.verify(self.evidence)
        self.evidence['encryption'].update(mode='declaration', declaration_id='approved-id')
        self.verify(self.evidence)

    def test_wrong_source_bundle_or_simulator_cannot_release(self):
        for field, value in [('source', 'b' * 40), ('bundle', 'com.btcswift.app'), ('physical_device', False)]:
            evidence = dict(self.evidence, **{field: value})
            with self.subTest(field=field), self.assertRaises(AssertionError):
                self.verify(evidence)

    def test_each_device_check_is_required(self):
        for name in self.evidence['checks']:
            evidence = copy.deepcopy(self.evidence)
            evidence['checks'][name] = 'pending'
            with self.subTest(name=name), self.assertRaises(AssertionError):
                self.verify(evidence)

    def test_changed_or_escaping_evidence_is_rejected(self):
        self.proof.write_text('changed')
        with self.assertRaises(AssertionError):
            self.verify(self.evidence)
        self.evidence['artifacts'][0]['path'] = '../elsewhere.txt'
        with self.assertRaises(AssertionError):
            self.verify(self.evidence)

    def test_encryption_cannot_default_to_exempt_or_unrecorded_claim(self):
        for field, value in [('mode', 'unknown'), ('reviewed_by', ''), ('rationale', ''), ('artifact', 'missing.txt')]:
            evidence = copy.deepcopy(self.evidence)
            evidence['encryption'][field] = value
            with self.subTest(field=field), self.assertRaises(AssertionError):
                self.verify(evidence)
