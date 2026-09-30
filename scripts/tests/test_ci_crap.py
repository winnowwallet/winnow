from pathlib import Path
import json
import hashlib
import runpy
import tempfile
import unittest

TOOL = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'ci-crap'))
CRAP = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'check-crap'))


class CoverageCollectorTests(unittest.TestCase):
    def file(self, root, name):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'evidence')
        return path.resolve()

    def test_package_requires_one_profile_and_compiled_tests(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ValueError):
                TOOL['package_inputs'](root)
            profile = self.file(root, 'debug/codecov/default.profdata')
            with self.assertRaises(ValueError):
                TOOL['package_inputs'](root)
            binary = self.file(root, 'debug/CoreTests.xctest/Contents/MacOS/CoreTests')
            self.assertEqual(TOOL['package_inputs'](root), (profile, [binary]))
            self.file(root, 'other/codecov/default.profdata')
            with self.assertRaises(ValueError):
                TOOL['package_inputs'](root)

    def test_flat_bundle_and_symlinks_are_deduplicated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile = self.file(root, 'actual/codecov/default.profdata')
            binary = self.file(root, 'actual/CoreTests.xctest/CoreTests')
            (root / 'alias').symlink_to(root / 'actual', target_is_directory=True)
            self.assertEqual(TOOL['package_inputs'](root), (profile, [binary]))

    def test_app_includes_debug_library_and_test_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile = self.file(root, 'Build/ProfileData/device/Coverage.profdata')
            app = self.file(root, 'Build/Products/ResearchDebug-iphonesimulator/WinnowApp.app/WinnowApp')
            dylib = self.file(root, 'Build/Products/ResearchDebug-iphonesimulator/WinnowApp.app/WinnowApp.debug.dylib')
            tests = self.file(root, 'Build/Products/ResearchDebug-iphonesimulator/WinnowApp.app/PlugIns/WinnowAppTests.xctest/WinnowAppTests')
            self.assertEqual(TOOL['app_inputs'](root, 'ResearchDebug'), ([profile], sorted([app, dylib, tests])))
            with self.assertRaises(ValueError):
                TOOL['app_inputs'](root, 'Debug')

    def test_app_missing_profile_cannot_supply_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.file(root, 'Build/Products/ResearchDebug-iphonesimulator/WinnowApp.app/WinnowApp')
            with self.assertRaises(ValueError):
                TOOL['app_inputs'](root, 'ResearchDebug')

    def test_tests_alone_cannot_impersonate_a_compiled_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.file(root, 'Build/ProfileData/device/Coverage.profdata')
            self.file(root, 'Build/Products/ResearchDebug-iphonesimulator/WinnowAppTests.xctest/WinnowAppTests')
            with self.assertRaises(ValueError):
                TOOL['app_inputs'](root, 'ResearchDebug')

    def test_app_only_edits_preserve_package_evidence_but_compiled_edits_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = {'Sources/WalletCore/Wallet.swift': 'wallet-a', 'Sources/WinnowApp/App.swift': 'app-a'}
            current = dict(original, **{'Sources/WinnowApp/App.swift': 'app-b'})
            compiled = root / 'compiled.json'; final = root / 'final.json'; lines = root / 'package.lcov'
            compiled.write_text(json.dumps({'files': original}))
            final.write_text(json.dumps({'files': current}))
            lines.write_text('SF:/repo/Sources/WalletCore/Wallet.swift\nDA:1,0\nend_of_record\n')
            self.assertEqual(TOOL['validate_package_sources'](lines, compiled, final),
                             ['Sources/WalletCore/Wallet.swift'])
            current['Sources/WalletCore/Wallet.swift'] = 'wallet-b'
            final.write_text(json.dumps({'files': current}))
            with self.assertRaisesRegex(ValueError, 'source manifest mismatch'):
                TOOL['validate_package_sources'](lines, compiled, final)

    def test_empty_package_source_evidence_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / 'manifest.json'; lines = root / 'package.lcov'
            manifest.write_text(json.dumps({'files': {'Sources/WalletCore/Wallet.swift': 'hash'}}))
            lines.write_text('SF:/SDK/External.swift\nDA:1,1\nend_of_record\n')
            with self.assertRaisesRegex(ValueError, 'no first-party Sources evidence'):
                TOOL['validate_package_sources'](lines, manifest, manifest)

    def archive_fixture(self, root):
        source = self.file(root, 'Sources/Core/Example.swift')
        manifest = root / 'manifest.json'
        manifest.write_text(json.dumps({'files': {'Sources/Core/Example.swift': hashlib.sha256(source.read_bytes()).hexdigest()}}))
        return source, manifest

    def test_archives_require_success_and_an_actual_reference(self):
        result = {'status': {'_value': 'succeeded'}, 'coverage': {
            'hasCoverageData': {'_value': 'true'}, 'archiveRef': {'id': {'_value': 'archive-id'}}}}
        metadata = {'actions': {'_values': [{'actionResult': result}]}}
        self.assertEqual(TOOL['coverage_archives'](metadata), ['archive-id'])
        result['status']['_value'] = 'failed'
        with self.assertRaisesRegex(ValueError, 'unsuccessful'):
            TOOL['coverage_archives'](metadata)
        result['status']['_value'] = 'succeeded'; del result['coverage']['archiveRef']
        with self.assertRaisesRegex(ValueError, 'reference'):
            TOOL['coverage_archives'](metadata)
        with self.assertRaisesRegex(ValueError, 'no successful'):
            TOOL['coverage_archives']({})

    def test_archive_executable_lines_keep_zeros_and_whole_line_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source, manifest = self.archive_fixture(root)
            records = {str(source): [{'line': 1, 'isExecutable': False},
                {'line': 2, 'isExecutable': True, 'executionCount': 0},
                {'line': 3, 'isExecutable': True, 'executionCount': 2,
                 'subranges': [{'column': 1, 'length': 3, 'executionCount': 0}]}]}
            lines, hashes = TOOL['archived_source_lines'](records, manifest, root)
            self.assertNotIn('DA:1,', lines)
            self.assertIn('DA:2,0', lines); self.assertIn('DA:3,2', lines)
            self.assertEqual(hashes, json.loads(manifest.read_text())['files'])

    def test_independent_archive_runs_union_without_discarding_uncovered_lines(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source, manifest = self.archive_fixture(root)
            paths = []
            for index, counts in enumerate([(0, 2), (1, 0)]):
                records = {str(source): [{'line': n, 'isExecutable': True, 'executionCount': count}
                                         for n, count in zip((2, 3), counts)]}
                lines, _ = TOOL['archived_source_lines'](records, manifest, root)
                path = root / f'run-{index}.lcov'; path.write_text(lines); paths.append(path)
            self.assertEqual(CRAP['line_coverage'](paths, root)['Sources/Core/Example.swift'], {2: 1, 3: 2})

    def test_archive_hash_and_checkout_mismatch_fail_without_path_guessing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source, manifest = self.archive_fixture(root)
            record = [{'line': 2, 'isExecutable': True, 'executionCount': 1}]
            source.write_bytes(b'changed source')
            with self.assertRaisesRegex(ValueError, 'manifest mismatch'):
                TOOL['archived_source_lines']({str(source): record}, manifest, root)
            with self.assertRaisesRegex(ValueError, 'outside the declared checkout'):
                TOOL['archived_source_lines']({'/other/Sources/Core/Example.swift': record}, manifest, root)

    def test_malformed_or_absent_executable_archive_evidence_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source, manifest = self.archive_fixture(root)
            for record in [{'line': 2, 'isExecutable': True},
                           {'line': 2, 'isExecutable': True, 'executionCount': -1},
                           {'line': 0, 'isExecutable': True, 'executionCount': 1}]:
                with self.assertRaisesRegex(ValueError, 'Malformed'):
                    TOOL['archived_source_lines']({str(source): [record]}, manifest, root)
            with self.assertRaisesRegex(ValueError, 'no first-party executable'):
                TOOL['archived_source_lines']({str(source): [{'line': 1, 'isExecutable': False}]}, manifest, root)


if __name__ == '__main__':
    unittest.main()
