"""Export compliance tooling reads and changes only what its reviewed input allows."""
import json
from pathlib import Path
import runpy
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PREFLIGHT = runpy.run_path(str(ROOT / 'scripts/asc-preflight'))
DECLARE = runpy.run_path(str(ROOT / 'scripts/encryption-declaration'))
ANSWERED = dict(approved=True, reviewed_by='owner', reviewed_on='2026-09-30', app_description='A wallet.',
                contains_proprietary_cryptography=False, contains_third_party_cryptography=True,
                available_on_french_store=False)


class FakeAppStoreConnect:
    """Answers the handful of App Store Connect requests the tools make."""

    def __init__(self, declarations=(), post_error=None, uses=None, processing='VALID'):
        self.calls, self.declarations, self.post_error, self.uses = [], list(declarations), post_error, uses
        self.processing, self.linked = processing, None

    def __call__(self, method, path, data=None):
        self.calls.append((method, path.split('?')[0], data))
        if method == 'GET' and path.startswith('/apps?'):
            return {'data': [{'id': 'app', 'attributes': {'bundleId': 'com.btcswift.app', 'name': 'Winnow'}}]}
        if method == 'GET' and path.startswith('/builds?'):
            return {'data': [{'id': 'b1', 'attributes': {'processingState': self.processing,
                                                          'usesNonExemptEncryption': self.uses}}]}
        if method == 'GET' and path.startswith('/appEncryptionDeclarations?'):
            return {'data': self.declarations, 'links': {}}
        if method == 'POST':
            if self.post_error:
                raise self.post_error
            row = {'id': 'd-new', 'attributes': {**data['data']['attributes'],
                                                 'appEncryptionDeclarationState': 'CREATED', 'exempt': None}}
            self.declarations.append(row)
            return {'data': row}
        if method == 'GET' and path == '/builds/b1':
            return {'data': {'attributes': {'usesNonExemptEncryption': self.uses}}}
        if method == 'PATCH' and path == '/builds/b1':
            self.uses = data['data']['attributes']['usesNonExemptEncryption']
            return None
        if method == 'PATCH' and path.endswith('/relationships/appEncryptionDeclaration'):
            self.linked = data['data']['id']
            return None
        if method == 'GET' and path.endswith('/appEncryptionDeclaration'):
            return {'data': {'id': self.linked}}
        raise AssertionError(f'unexpected request {method} {path}')


class EncryptionDeclarationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.questionnaire = Path(temporary.name) / 'questionnaire.json'

    def run_tool(self, answers, asc):
        self.questionnaire.write_text(json.dumps(answers))
        return DECLARE['main'](['--version', '0.8.0', '--build', '90', '--questionnaire', str(self.questionnaire)], asc=asc)

    def declaration(self, exempt, state='APPROVED'):
        attributes = {DECLARE['ANSWERS'][key]: ANSWERED[key] for key in DECLARE['ANSWERS']}
        return {'id': 'd1', 'attributes': {**attributes, 'appDescription': 'A wallet.',
                                           'appEncryptionDeclarationState': state, 'exempt': exempt}}

    def test_the_committed_questionnaire_is_not_yet_approved(self):
        committed = json.loads((ROOT / 'docs/release/encryption-questionnaire.json').read_text())
        self.assertIs(committed['approved'], False)
        with self.assertRaises(SystemExit):
            DECLARE['load_answers'](ROOT / 'docs/release/encryption-questionnaire.json')

    def test_an_unapproved_or_unanswered_questionnaire_sends_nothing(self):
        for change in ({'approved': False}, {'available_on_french_store': None},
                       {'contains_third_party_cryptography': 'yes'}, {'app_description': ''},
                       {'app_description': 'x' * 301}):
            with self.subTest(change=change):
                asc = FakeAppStoreConnect()
                with self.assertRaises(SystemExit):
                    self.run_tool({**ANSWERED, **change}, asc)
                self.assertEqual(asc.calls, [])

    def test_an_approved_non_exempt_declaration_marks_and_links_the_build(self):
        asc = FakeAppStoreConnect(declarations=[self.declaration(exempt=False)])
        result = self.run_tool(ANSWERED, asc)
        self.assertEqual(result['declaration'], 'd1')
        self.assertIs(asc.uses, True)
        self.assertEqual(asc.linked, 'd1')
        self.assertFalse([call for call in asc.calls if call[0] == 'POST'], 'the matching declaration is reused')

    def test_apples_no_document_answer_marks_the_build_exempt_without_a_link(self):
        error = DECLARE['AppleError']('POST', '/appEncryptionDeclarations', 409, {'errors': [
            {'code': 'ENTITY_ERROR.ATTRIBUTE.INVALID', 'detail': DECLARE['NO_DOCUMENT']}]})
        asc = FakeAppStoreConnect(post_error=error)
        result = self.run_tool(ANSWERED, asc)
        self.assertEqual(result['state'], 'DOCUMENTATION_NOT_REQUIRED')
        self.assertIs(asc.uses, False)
        self.assertIsNone(asc.linked)

    def test_any_other_refusal_or_a_contradicting_build_fails(self):
        other = DECLARE['AppleError']('POST', '/appEncryptionDeclarations', 409, {'errors': [
            {'code': 'ENTITY_ERROR.ATTRIBUTE.INVALID', 'detail': 'something else'}]})
        with self.assertRaises(DECLARE['AppleError']):
            self.run_tool(ANSWERED, FakeAppStoreConnect(post_error=other))
        with self.assertRaises(RuntimeError):
            self.run_tool(ANSWERED, FakeAppStoreConnect(declarations=[self.declaration(exempt=False)], uses=False))

    def test_a_declaration_awaiting_apple_leaves_the_build_alone(self):
        asc = FakeAppStoreConnect()
        result = self.run_tool(ANSWERED, asc)
        self.assertEqual(result, {'declaration': 'd-new', 'state': 'CREATED', 'build_updated': False})
        self.assertIsNone(asc.uses)
        self.assertFalse([call for call in asc.calls if call[0] == 'PATCH'])


class PreflightTests(unittest.TestCase):
    def test_release_build_must_be_the_one_valid_build_with_the_reviewed_answer(self):
        get = lambda asc: (lambda path, optional=False: asc('GET', path))
        read = PREFLIGHT['read_build']
        self.assertEqual(read(get(FakeAppStoreConnect(uses=True)), 'app', '0.8.0', '90', 'YES')['id'], 'b1')
        self.assertIsNone(read(get(FakeAppStoreConnect()), 'app', '0.8.0', '90', 'PENDING')['uses_non_exempt_encryption'])
        for asc, expect in ((FakeAppStoreConnect(uses=False), 'YES'), (FakeAppStoreConnect(uses=None), 'NO'),
                            (FakeAppStoreConnect(processing='PROCESSING'), 'PENDING')):
            with self.subTest(expect=expect), self.assertRaises(RuntimeError):
                read(get(asc), 'app', '0.8.0', '90', expect)

    def test_pagination_must_stay_on_app_store_connect_and_end(self):
        pages = {'/one': {'data': [1], 'links': {'next': PREFLIGHT['API'] + '/two'}}, '/two': {'data': [2], 'links': {}}}
        self.assertEqual(PREFLIGHT['collection'](lambda path, optional=False: pages[path], '/one'), [1, 2])
        loop = {'/one': {'data': [], 'links': {'next': PREFLIGHT['API'] + '/one'}}}
        with self.assertRaises(RuntimeError):
            PREFLIGHT['collection'](lambda path, optional=False: loop[path], '/one')
        foreign = {'/one': {'data': [], 'links': {'next': 'https://example.invalid/two'}}}
        with self.assertRaises(RuntimeError):
            PREFLIGHT['collection'](lambda path, optional=False: foreign[path], '/one')


if __name__ == '__main__':
    unittest.main()
