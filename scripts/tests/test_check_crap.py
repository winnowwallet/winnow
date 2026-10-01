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

    def test_only_a_compiler_that_dies_by_a_signal_is_rerun(self):
        from unittest.mock import patch
        import subprocess
        results = lambda *codes: [subprocess.CompletedProcess([], code, stdout='dump' if code == 0 else '', stderr='')
                                  for code in codes]
        parse = TOOL['parse_dump']
        with patch.dict(parse.__globals__['subprocess'].__dict__, run=lambda *a, **k: next(runs)), \
                patch.object(parse.__globals__['sys'], 'stderr'):
            runs = iter(results(-11, 0))
            self.assertEqual(parse('/tmp/a.swift'), 'dump')
            runs = iter(results(1))
            with self.assertRaises(subprocess.CalledProcessError):
                parse('/tmp/a.swift')
            runs = iter(results(-11, -11, -11, -11, -11, 0))
            with self.assertRaises(subprocess.CalledProcessError) as caught:
                parse('/tmp/a.swift')
            self.assertEqual(caught.exception.returncode, -11)
            self.assertEqual(next(runs).returncode, 0, 'five crashes are the limit')

    def test_a_crash_prints_the_end_of_the_compilers_report(self):
        from unittest.mock import patch
        import io
        import subprocess
        report = '\n'.join(f'frame {n}' for n in range(60))
        runs = iter([subprocess.CompletedProcess([], -11, stdout='', stderr=report),
                     subprocess.CompletedProcess([], 0, stdout='dump', stderr='')])
        parse, printed = TOOL['parse_dump'], io.StringIO()
        with patch.dict(parse.__globals__['subprocess'].__dict__, run=lambda *a, **k: next(runs)), \
                patch.object(parse.__globals__['sys'], 'stderr', printed):
            self.assertEqual(parse('/tmp/a.swift'), 'dump')
        self.assertIn('died by signal 11 (attempt 1 of 5)', printed.getvalue())
        self.assertIn('  frame 59', printed.getvalue())
        self.assertNotIn('frame 19\n', printed.getvalue(), 'only the end of a long report is printed')

    def assert_blanked(self, source, *clauses):
        expected = source
        for clause in clauses:
            self.assertIn(clause, expected)
            expected = expected.replace(clause, TOOL['blank'](clause), 1)
        self.assertEqual(TOOL['parse_copy'](source), expected)

    def test_parse_copy_blanks_class_and_actor_inheritance_in_place(self):
        source = ('public actor LightningBackgroundMonitor: LightningChainMonitor {\n'
                  '    public init(store: LightningBackgroundStore, chain: Data) throws {}\n}\n')
        copy = TOOL['parse_copy'](source)
        self.assertEqual(copy, source.replace(': LightningChainMonitor', ' ' * 23))
        position = lambda text: (text[:text.index('init')].count('\n'), text.index('init') - text.rindex('\n', 0, text.index('init')))
        self.assertEqual(position(copy), position(source), 'the initializer keeps its line and column')
        self.assert_blanked('@MainActor final class A: B, @unchecked Sendable {}\n', ': B, @unchecked Sendable')
        self.assert_blanked('open class Base: NSObject {}\n', ': NSObject')
        self.assert_blanked('    private final class C: P {}\n    fileprivate actor D: P, Q {}\n', ': P', ': P, Q')
        self.assert_blanked('package final class E: P {}\n@objc(Named) public final class F: NSObject {}\n', ': P', ': NSObject')
        self.assert_blanked('enum N { final class Inner: Base {} }\n', ': Base')
        self.assert_blanked('final class Box<Key: Hashable, Value: Collection<Int>>: Base<Key>, P where Value: Sendable {}\n',
                            ': Base<Key>, P')
        self.assert_blanked('public final class Long\n    : Base,\n      P, // kept for the API\n      Q\n{\n}\n',
                            ': Base,\n      P, // kept for the API\n      Q')
        self.assert_blanked('actor Pool<T>:\n    P,\n    Q\nwhere T: Sendable {\n}\n', ':\n    P,\n    Q')
        self.assert_blanked('#if os(iOS)\nfinal class A: B {}\n#else\nfinal class A {}\n#endif\n',
                            '#if os(iOS)', ': B', '#else', '#endif')

    def test_parse_copy_leaves_other_colons_alone(self):
        self.assert_blanked('final class Plain {\n'
                            '    class func make() -> Plain { Plain() }\n'
                            '    class var shared: Plain { Plain() }\n'
                            '    final class var name: String { "" }\n'
                            '    class subscript(index: Int) -> Int { index }\n}\n')
        self.assert_blanked('protocol Owner: AnyObject {}\nprotocol Legacy: class {}\nprotocol Monitor: Actor {}\n'
                            'protocol Spread:\n    class,\n    Sendable {}\n')
        self.assert_blanked('func connect(\n    actor peer: PeerConnection,\n    class kind: Kind\n) {}\n')
        self.assert_blanked('func connect(\n    actor peer: ' + 'Long' * 2000 + '\n) {}\n')

    def test_declarations_dump_the_blanked_copy_and_leave_the_source(self):
        from unittest.mock import patch
        source = 'public actor Monitor: ChainMonitor {\n    public init(chain: Data) {}\n}\n'
        dumped = []

        def dump(input):
            dumped.append(Path(input).read_text())
            return f'  (constructor_decl range=[{input}:2:12 - line:2:32] "init(chain:)"\n'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Monitor.swift'
            path.write_text(source)
            with patch.dict(TOOL['declarations'].__globals__, parse_dump=dump):
                self.assertEqual(TOOL['declarations'](path),
                                 (path, [{'start': 2, 'column': 12, 'end': 2, 'name': 'init(chain:)'}]))
            self.assertEqual(path.read_text(), source)
        self.assertEqual(dumped, [source.replace(': ChainMonitor', ' ' * 14)])

    def test_declarations_leave_defer_bodies_to_their_method(self):
        from unittest.mock import patch
        source = 'func example(x: Int) {\n    defer { if x > 0 { print(x) } }\n    func inner() {}\n}\n'

        def dump(input):
            return (f'  (func_decl decl_context=0x1 range=[{input}:1:1 - line:4:1] "example(x:)"\n'
                    f'    (brace_stmt implicit range=[{input}:1:22 - line:4:1]\n'
                    f'      (defer_stmt range=[{input}:2:5 - line:2:35]\n'
                    f'        (func_decl decl_context=0x2 implicit range=[{input}:2:5 - line:2:35] "$defer()" '
                    'result="()" thrown_type="<null>"\n'
                    f'      (func_decl decl_context=0x2 range=[{input}:3:5 - line:3:19] "inner()" thrown_type="<null>"\n')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Example.swift'
            path.write_text(source)
            with patch.dict(TOOL['declarations'].__globals__, parse_dump=dump):
                self.assertEqual(TOOL['declarations'](path), (path, [
                    {'start': 1, 'column': 1, 'end': 4, 'name': 'example(x:)'},
                    {'start': 3, 'column': 5, 'end': 3, 'name': 'inner()'},
                ]))

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
