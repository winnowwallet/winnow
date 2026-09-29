"""Keep development archiving distinct from strict distribution verification."""
import contextlib
import io
import os
from pathlib import Path
import plistlib
import runpy
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
VERIFY = runpy.run_path(str(ROOT / 'scripts/verify-signed-archive'))['verify']


class SignedAppTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.app = Path(self.tmp.name) / 'WinnowApp.app'
        self.app.mkdir()
        self.info = {'CFBundleShortVersionString': '0.7.9', 'CFBundleVersion': '37',
                     'CFBundleIdentifier': 'com.btcswift.app', 'CFBundleExecutable': 'WinnowApp'}
        self.entitlements = {'application-identifier': '2858MX5336.com.btcswift.app',
                             'com.apple.developer.team-identifier': '2858MX5336',
                             'com.apple.developer.icloud-container-identifiers': ['iCloud.com.btcswift.app'],
                             'com.apple.developer.icloud-services': ['CloudKit'], 'get-task-allow': True}
        env = patch.dict(os.environ, TESTFLIGHT_MARKETING_VERSION='0.7.9', TESTFLIGHT_BUILD_NUMBER='37')
        env.start()
        self.addCleanup(env.stop)

    def verify(self, distribution=False, architectures='arm64\n', signature_error=None):
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(self.info))
        with patch('subprocess.run', side_effect=signature_error) as signature, patch(
                'subprocess.check_output', side_effect=[plistlib.dumps(self.entitlements), architectures]), \
                contextlib.redirect_stdout(io.StringIO()):
            VERIFY(self.app, distribution)
        signature.assert_called_once_with(['codesign', '--verify', '--deep', '--strict', str(self.app)], check=True)

    def test_observed_development_archive_without_environment_is_valid_before_export(self):
        self.verify()

    def test_distribution_requires_production_and_debugging_disabled(self):
        for environment in (None, 'Development', 'Production'):
            for debug in (None, True, False):
                with self.subTest(environment=environment, debug=debug):
                    self.entitlements.pop('com.apple.developer.icloud-container-environment', None)
                    self.entitlements.pop('get-task-allow', None)
                    if environment is not None:
                        self.entitlements['com.apple.developer.icloud-container-environment'] = environment
                    if debug is not None:
                        self.entitlements['get-task-allow'] = debug
                    if environment == 'Production' and debug is False:
                        self.verify(True)
                    else:
                        with self.assertRaises(AssertionError):
                            self.verify(True)

    def test_non_development_signature_never_gets_archive_exception(self):
        self.entitlements['get-task-allow'] = False
        with self.assertRaises(AssertionError):
            self.verify()

    def test_wrong_release_identity_is_rejected(self):
        for field in ('CFBundleShortVersionString', 'CFBundleVersion', 'CFBundleIdentifier'):
            with self.subTest(field=field):
                original = self.info[field]
                self.info[field] = 'wrong'
                with self.assertRaises(AssertionError):
                    self.verify()
                self.info[field] = original
        for field in ('application-identifier', 'com.apple.developer.team-identifier',
                      'com.apple.developer.icloud-container-identifiers', 'com.apple.developer.icloud-services'):
            with self.subTest(field=field):
                original = self.entitlements[field]
                self.entitlements[field] = 'wrong'
                with self.assertRaises(AssertionError):
                    self.verify()
                self.entitlements[field] = original

    def test_bad_signature_and_non_iphone_architecture_are_rejected(self):
        import subprocess
        with self.assertRaises(subprocess.CalledProcessError):
            self.verify(signature_error=subprocess.CalledProcessError(1, 'codesign'))
        for architecture in ('x86_64\n', 'arm64 x86_64\n', ''):
            with self.subTest(architecture=architecture), self.assertRaises(AssertionError):
                self.verify(architectures=architecture)

    def test_research_distribution_requires_reviewed_encryption_and_no_cloud(self):
        self.info['CFBundleIdentifier'] = 'com.btcswift.lightning'
        self.entitlements = {'application-identifier': '2858MX5336.com.btcswift.lightning',
                             'com.apple.developer.team-identifier': '2858MX5336', 'get-task-allow': False}
        with patch.dict(os.environ, TESTFLIGHT_BUNDLE_ID='com.btcswift.lightning', LIGHTNING_NONEXEMPT_ENCRYPTION='', LIGHTNING_ENCRYPTION_COMPLIANCE_CODE='approved-code'):
            with self.assertRaises(AssertionError):
                self.verify(True)
            for value in (True, False):
                self.info['ITSAppUsesNonExemptEncryption'] = value
                self.info['ITSEncryptionExportComplianceCode'] = 'approved-code'
                os.environ['LIGHTNING_NONEXEMPT_ENCRYPTION'] = 'YES' if value else 'NO'
                self.verify(True)
                self.info['ITSAppUsesNonExemptEncryption'] = not value
                with self.assertRaises(AssertionError):
                    self.verify(True)
            os.environ['LIGHTNING_NONEXEMPT_ENCRYPTION'] = 'YES'
            self.info['ITSAppUsesNonExemptEncryption'] = True
            for code in ('', 'different-code'):
                self.info['ITSEncryptionExportComplianceCode'] = code
                with self.subTest(code=code), self.assertRaises(AssertionError):
                    self.verify(True)
            os.environ['LIGHTNING_NONEXEMPT_ENCRYPTION'] = 'NO'
            self.info['ITSAppUsesNonExemptEncryption'] = False
            self.entitlements['com.apple.developer.icloud-services'] = ['CloudKit']
            with self.assertRaises(AssertionError):
                self.verify(True)

    def test_pending_questionnaire_cannot_claim_exemption_or_approved_code(self):
        self.info['CFBundleIdentifier'] = 'com.btcswift.lightning'
        self.entitlements = {'application-identifier': '2858MX5336.com.btcswift.lightning',
                             'com.apple.developer.team-identifier': '2858MX5336', 'get-task-allow': False}
        with patch.dict(os.environ, TESTFLIGHT_BUNDLE_ID='com.btcswift.lightning', LIGHTNING_NONEXEMPT_ENCRYPTION='PENDING'):
            self.verify(True)
            for value in (True, False, ''):
                self.info['ITSAppUsesNonExemptEncryption'] = value
                with self.subTest(value=value), self.assertRaises(AssertionError):
                    self.verify(True)
            self.info.pop('ITSAppUsesNonExemptEncryption')
            self.info['ITSEncryptionExportComplianceCode'] = 'unreviewed-code'
            with self.assertRaises(AssertionError):
                self.verify(True)


class UploadIntegrityTests(unittest.TestCase):
    def test_upload_only_accepts_the_verified_ipa_bytes(self):
        import hashlib
        import subprocess
        import textwrap
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        step = workflow.split('      - name: Upload the verified package to App Store Connect\n', 1)[1]
        script = textwrap.dedent(step.split('        run: |\n', 1)[1].split('\n      - name:', 1)[0])
        for changed in (False, True):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                ipa = root / 'build/export/WinnowApp.ipa'
                ipa.parent.mkdir(parents=True)
                ipa.write_bytes(b'verified distribution bytes')
                ipa.with_suffix('.ipa.verified.sha256').write_text(
                    hashlib.sha256(ipa.read_bytes()).hexdigest() + '  build/export/WinnowApp.ipa\n')
                if changed:
                    ipa.write_bytes(b'changed after verification')
                keydir = root / 'signing'
                keydir.mkdir()
                (keydir / 'AuthKey.p8').write_text('test fixture, not a key')
                tools = root / 'bin'
                tools.mkdir()
                xcrun = tools / 'xcrun'
                xcrun.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$UPLOAD_TRACE"\n')
                xcrun.chmod(0o755)
                trace = root / 'upload-trace'
                result = subprocess.run(['bash', '-e', '-c', script], cwd=root, capture_output=True,
                                        env={**os.environ, 'PATH': str(tools) + ':' + os.environ['PATH'],
                                             'API_PRIVATE_KEYS_DIR': str(keydir), 'ASC_KEY_ID': 'TEST',
                                             'ASC_ISSUER_ID': 'TEST', 'UPLOAD_TRACE': str(trace)})
                self.assertEqual(result.returncode == 0, not changed)
                self.assertEqual(trace.exists(), not changed)
                if not changed:
                    self.assertIn('build/export/WinnowApp.ipa', trace.read_text())

    def test_production_verification_precedes_upload(self):
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        self.assertLess(workflow.index('name: Export the App Store distribution package'),
                        workflow.index('name: Verify the exported production package'))
        self.assertLess(workflow.index('name: Verify the exported production package'),
                        workflow.index('name: Upload the verified package to App Store Connect'))
        self.assertIn('<string>export</string>', workflow)
        self.assertIn('<string>Production</string>', workflow)
        verifier = (ROOT / 'scripts/verify-exported-ipa').read_text()
        self.assertIn('--distribution', verifier)
        self.assertIn('"$script_dir/verify-release-e2e-exclusion"', verifier)
