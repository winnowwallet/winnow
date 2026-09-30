import json
from pathlib import Path
import runpy
import tempfile
from types import SimpleNamespace
import unittest

TOOL = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'check-crap'))


class CrapEvidenceTests(unittest.TestCase):
    def row(self, decisions, counts):
        root = Path('/sample')
        path = root / 'Sources/Core/example.swift'
        violation = {'file': str(path), 'line': 3, 'reason': f'currently complexity is {decisions}'}
        parsed = {path: [{'start': 3, 'end': 7, 'column': 1, 'name': 'example()'}]}
        coverage = {'Sources/Core/example.swift': counts} if counts is not None else {}
        return TOOL['records'](root, [violation], parsed, coverage)[0]

    def test_reports_partition_sources_by_prefix(self):
        in_scope = TOOL['in_scope']
        self.assertTrue(in_scope('Sources/WalletCore/a.swift', [], []))
        self.assertFalse(in_scope('Sources/WinnowLightningApp/a.swift', [], ['Sources/WinnowLightningApp']))
        self.assertTrue(in_scope('Sources/WinnowLightningAppendix/a.swift', [], ['Sources/WinnowLightningApp']),
                        'a prefix names a directory, not a string prefix')
        self.assertTrue(in_scope('Sources/WinnowLightningApp/a.swift', ['Sources/WinnowLightningApp/'], []))
        self.assertFalse(in_scope('Sources/WinnowApp/a.swift', ['Sources/WinnowLightningApp'], []))

    def test_entry_path_and_exact_twelve_boundary(self):
        uncovered = self.row(2, {3: 0, 4: 0, 7: 0})
        self.assertEqual(uncovered['complexity'], 3)
        self.assertEqual(uncovered['crap'], 12)
        self.assertEqual(self.row(3, {3: 0})['crap'], 20)
        self.assertEqual(self.row(11, {3: 1, 4: 1})['crap'], 12)
        self.assertEqual(self.row(12, {3: 1})['crap'], 13)

    def test_partial_line_coverage_uses_standard_formula(self):
        row = self.row(4, {3: 10, 4: 0, 5: 20, 7: 0})
        self.assertEqual(row['coverage'], 0.5)
        self.assertEqual(row['covered_lines'], 2)
        self.assertEqual(row['executable_lines'], 4)
        self.assertEqual(row['crap'], 8.125)

    def test_missing_is_unmeasured_and_never_assumed_covered(self):
        row = self.row(4, None)
        self.assertFalse(row['coverage_measured'])
        self.assertIsNone(row['coverage'])
        self.assertIsNone(row['crap'])
        self.assertEqual(row['conservative_crap'], 30)

    def test_nested_declaration_maps_to_narrowest_function(self):
        declaration = TOOL['method']({'file': 'example.swift', 'line': 5}, [
            {'start': 1, 'end': 20, 'column': 1, 'name': 'parent()'},
            {'start': 5, 'end': 8, 'column': 5, 'name': 'nested()'},
        ])
        self.assertEqual(declaration['name'], 'nested()')
        with self.assertRaises(ValueError):
            TOOL['method']({'file': 'example.swift', 'line': 30}, [])

    def test_nested_function_coverage_does_not_inflate_its_parent(self):
        root = Path('/sample'); path = root / 'Sources/Core/example.swift'
        violation = {'file': str(path), 'line': 1, 'reason': 'currently complexity is 4'}
        declarations = {path: [
            {'start': 1, 'end': 20, 'column': 1, 'name': 'parent()'},
            {'start': 5, 'end': 8, 'column': 5, 'name': 'nested()'},
        ]}
        rows = TOOL['records'](root, [violation], declarations,
                               {'Sources/Core/example.swift': {1: 0, 5: 1, 6: 1, 8: 1, 20: 0}})
        self.assertEqual(rows[0]['coverage'], 0)
        self.assertEqual(rows[0]['executable_lines'], 2)
        self.assertEqual(rows[0]['crap'], 30)

    def test_package_and_app_line_coverage_union_never_drops_uncovered_lines(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / 'package.lcov'; second = root / 'app.lcov'
            first.write_text('SF:/old/checkout/Sources/Core/example.swift\nDA:3,0\nDA:4,2\nDA:5,0\nend_of_record\n')
            second.write_text('SF:/new/checkout/Sources/Core/example.swift\nDA:3,1\nDA:4,0\nDA:6,0\nend_of_record\n')
            self.assertEqual(TOOL['line_coverage']([first, second], root), {
                'Sources/Core/example.swift': {3: 1, 4: 2, 5: 0, 6: 0}})

    def test_source_identity_detects_edits_before_accepting_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'Sources/Core/example.swift'; source.parent.mkdir(parents=True)
            source.write_text('func example() {}\n')
            before = TOOL['manifest'](root)
            manifest = root / 'manifest.json'
            manifest.write_text(json.dumps({'files': before}))
            source.write_text('func example() { if true {} }\n')
            self.assertNotEqual(before, TOOL['manifest'](root))
            with self.assertRaisesRegex(ValueError, 'Coverage source manifest mismatch'):
                TOOL['report'](SimpleNamespace(source_root=root, manifest=manifest))
            source.write_text('func example() {}\n')
            self.assertEqual(before, TOOL['manifest'](root))


if __name__ == '__main__':
    unittest.main()
