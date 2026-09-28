"""Local rejection tests; fixtures are synthetic and perform no Apple requests."""
import ast
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import runpy
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
API = runpy.run_path(str(ROOT / 'scripts/lightning-release-candidate.py'))
SOURCE = '7ceba20bc3d214cfaff6a53fd5f955be5740bc14'


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.candidate = dict(repository='posix4e/winnow-lightning', app_id='6815392502',
                              bundle='com.btcswift.lightning', source=SOURCE,
                              release_tooling_source=SOURCE, ci_run=42, version='0.4.0', build='9',
                              evidence='evidence/evidence.json', distribution_scope='Synthetic test fixture')
        self.folder = self.root / 'evidence'; self.folder.mkdir()
        self.write('lightning-release-candidate.json', self.candidate, self.root)
        self.draft = {name: self.candidate[name] for name in ['source', 'bundle', 'version', 'build', 'distribution_scope']}
        self.draft['facts_review'] = dict(source=SOURCE, reviewed_by='Synthetic test reviewer', status='facts-reviewed')
        self.write('encryption-questionnaire.json', self.draft)
        self.write('crypto-comparison.json', {'source': SOURCE})
        (self.folder / 'encryption-inventory.md').write_text('Synthetic technical inventory, not a determination.\n')
        (self.folder / 'what-to-test.txt').write_text('Synthetic notes, not a live release.\n')
        for kind in ['ipad', 'large_text']:
            manifest = dict(source=SOURCE, dirty=False, bundle=self.candidate['bundle'],
                            device={'device_type': 'iPad' if kind == 'ipad' else 'iPhone'},
                            content_size='large' if kind == 'ipad' else 'accessibility-extra-extra-extra-large')
            self.write(kind + '.json', dict(result='passed', manifest=manifest))
        checks = dict.fromkeys(['owner_authentication', 'cancelled_authentication', 'file_protection', 'exact_share'], 'pending')
        checks.update(ipad='passed', large_text='passed')
        self.evidence = dict(source=SOURCE, ci_run=42, bundle=self.candidate['bundle'], physical_device=False,
                             device_checks_deferred_to_testflight=True, checks=checks,
                             display_evidence={'ipad': 'ipad.json', 'large_text': 'large_text.json'},
                             encryption={'mode': 'pending', 'artifact': 'encryption-inventory.md'})
        self.rehash()

    def write(self, name, value, folder=None):
        ((folder or self.folder) / name).write_text(json.dumps(value))

    def rehash(self):
        self.evidence['artifacts'] = [dict(path=p.name, sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                                      for p in sorted(self.folder.iterdir()) if p.name != 'evidence.json']
        self.write('evidence.json', self.evidence)

    def run_evidence(self):
        return API['validate_evidence'](self.root, self.candidate)

    def apple(self):
        return dict(app={'id': '6815392502', 'bundle': self.candidate['bundle']},
                    observed_at_utc=datetime.now(timezone.utc).isoformat(),
                    candidate=dict(version='0.4.0', build='9', all_builds_read=True,
                                   highest_build_number=8, matching_build_ids=[]))

    def test_complete_synthetic_upload_bindings_pass(self):
        self.assertEqual(API['load_candidate'](self.root), self.candidate)
        self.assertEqual(self.run_evidence(), (self.folder / 'evidence.json').resolve())
        API['validate_apple'](self.candidate, self.apple(), 'upload')

    def test_committed_candidate_fails_closed_on_pending_exact_ci(self):
        with self.assertRaisesRegex(ValueError, '(release_tooling_source|Exact CI run) is pending'):
            API['load_candidate'](ROOT)

    def test_tester_notes_cannot_be_unhashed(self):
        self.evidence['artifacts'] = [a for a in self.evidence['artifacts'] if a['path'] != 'what-to-test.txt']
        self.write('evidence.json', self.evidence)
        with self.assertRaisesRegex(ValueError, 'Tester notes must be hashed'):
            self.run_evidence()

    def test_old_evidence_source_is_rejected(self):
        self.evidence['source'] = '1f1bfdd956c84765c444ed6b0667806b20626c55'
        self.write('evidence.json', self.evidence)
        with self.assertRaisesRegex(ValueError, 'Stale release evidence'):
            self.run_evidence()

    def test_correct_header_cannot_hide_stale_display_binary(self):
        proof = json.loads((self.folder / 'ipad.json').read_text())
        proof['manifest']['source'] = '1f1bfdd956c84765c444ed6b0667806b20626c55'
        self.write('ipad.json', proof); self.rehash()
        with self.assertRaisesRegex(ValueError, 'journey source mismatch'):
            self.run_evidence()

    def test_changed_and_escaping_artifact_is_rejected(self):
        (self.folder / 'encryption-inventory.md').write_text('Changed after review')
        with self.assertRaisesRegex(ValueError, 'artifact changed'):
            self.run_evidence()
        self.evidence['artifacts'][0]['path'] = '../outside.json'
        self.write('evidence.json', self.evidence)
        with self.assertRaisesRegex(ValueError, 'escapes control checkout'):
            self.run_evidence()

    def test_large_text_requires_maximum_accessibility_setting(self):
        proof = json.loads((self.folder / 'large_text.json').read_text())
        proof['manifest']['content_size'] = 'extra-large'
        self.write('large_text.json', proof); self.rehash()
        with self.assertRaisesRegex(ValueError, 'Maximum accessibility text'):
            self.run_evidence()

    def test_deferred_physical_check_cannot_claim_passed(self):
        self.evidence['checks']['owner_authentication'] = 'passed'
        self.write('evidence.json', self.evidence)
        with self.assertRaisesRegex(ValueError, 'Deferred device check must stay pending'):
            self.run_evidence()

    def test_ci_must_match_head_workflow_id_and_success(self):
        run = dict(id=42, head_sha=SOURCE, name='CI', path='.github/workflows/ci.yml', status='completed', conclusion='success')
        API['validate_ci'](self.candidate, run)
        for field, wrong in [('id', 43), ('head_sha', 'a' * 40), ('path', '.github/workflows/release.yml'),
                             ('name', 'Release'), ('status', 'in_progress'), ('conclusion', 'failure')]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                API['validate_ci'](self.candidate, dict(run, **{field: wrong}))

    def test_live_apple_duplicate_or_higher_build_rejects_upload(self):
        for field, wrong in [('matching_build_ids', ['existing-build']), ('highest_build_number', 9), ('all_builds_read', False), ('build', '8')]:
            state = self.apple(); state['candidate'][field] = wrong
            with self.subTest(field=field), self.assertRaises(ValueError):
                API['validate_apple'](self.candidate, state, 'upload')

    def test_stale_apple_receipt_cannot_authorize_upload(self):
        state = self.apple()
        state['observed_at_utc'] = (datetime.now(timezone.utc) - timedelta(minutes=16)).isoformat()
        with self.assertRaisesRegex(ValueError, 'fresh live Apple readback'):
            API['validate_apple'](self.candidate, state, 'upload')

    def test_enabling_requires_one_exact_existing_build(self):
        state = self.apple()
        with self.assertRaisesRegex(ValueError, 'exactly one processed'):
            API['validate_apple'](self.candidate, state, 'declare-and-enable')
        state['candidate']['matching_build_ids'] = ['candidate-build']
        API['validate_apple'](self.candidate, state, 'declare-and-enable')

    def test_questionnaire_needs_responsible_new_source_facts_review(self):
        self.draft['facts_review'].update(status='pending', reviewed_by=None)
        with self.assertRaisesRegex(ValueError, 'facts review is pending'):
            API['validate_questionnaire_review'](self.candidate, self.draft)
        self.write('encryption-questionnaire.json', self.draft); self.rehash()
        with self.assertRaisesRegex(ValueError, 'facts review is pending'):
            self.run_evidence()
        self.draft['facts_review'].update(status='facts-reviewed', reviewed_by='Synthetic test reviewer')
        API['validate_questionnaire_review'](self.candidate, self.draft)
        self.draft['facts_review']['source'] = 'a' * 40
        with self.assertRaises(ValueError):
            API['validate_questionnaire_review'](self.candidate, self.draft)

    def test_apple_pagination_reads_old_high_build_and_rejects_wrong_host(self):
        tree = ast.parse((ROOT / 'scripts/lightning-asc-preflight.py').read_text())
        definitions = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in {'all_build_numbers', 'next_build_page'}]
        pages = {'/builds?filter[app]=6815392502&limit=200': {'data': [{'attributes': {'version': '8'}}],
                 'links': {'next': 'https://api.appstoreconnect.apple.com/v1/builds?cursor=second'}},
                 '/builds?cursor=second': {'data': [{'attributes': {'version': '10'}}], 'links': {}}}
        namespace = {'APP': '6815392502', 'get': lambda path: pages[path]}
        exec(compile(ast.Module(body=definitions, type_ignores=[]), '<preflight-functions>', 'exec'), namespace)
        self.assertEqual(namespace['all_build_numbers'](), [8, 10])
        with self.assertRaisesRegex(RuntimeError, 'Unexpected Apple'):
            namespace['next_build_page']('https://example.com/v1/builds?cursor=second')

    def test_apple_collection_reads_every_version_before_french_store_answer(self):
        path = '/apps/6815392502/appStoreVersions?limit=200'
        second = '/apps/6815392502/appStoreVersions?cursor=second'
        draft = {'attributes': {'appStoreState': 'PREPARE_FOR_SUBMISSION'}}
        released = {'attributes': {'appStoreState': 'READY_FOR_SALE'}}
        pages = {path: {'data': [draft], 'links': {'next': 'https://api.appstoreconnect.apple.com/v1' + second}},
                 second: {'data': [released], 'links': {'next': None}}}
        versions = API['read_apple_collection'](pages.__getitem__, path)
        self.assertEqual(versions, [draft, released])
        with self.assertRaisesRegex(ValueError, 'public store distribution'):
            API['validate_internal_store_scope'](versions)
        API['validate_internal_store_scope']([draft])
        API['validate_internal_store_scope']([])

    def test_apple_collection_preserves_later_matching_declaration(self):
        path = '/appEncryptionDeclarations?filter[app]=6815392502&limit=200'
        second = '/appEncryptionDeclarations?cursor=second'
        rows = [{'id': 'first', 'attributes': {'containsThirdPartyCryptography': True}},
                {'id': 'second', 'attributes': {'containsThirdPartyCryptography': True}}]
        first = {'data': rows[:1], 'links': {'next': 'https://api.appstoreconnect.apple.com/v1' + second}}
        requested = []
        def get(page):
            requested.append(page)
            self.assertEqual(page, second)
            return {'data': rows[1:], 'links': {}}
        self.assertEqual(API['read_apple_collection'](get, path, first_page=first), rows)
        self.assertEqual(requested, [second])

    def test_apple_collection_rejects_cycles_limits_and_unrelated_urls(self):
        path = '/apps/6815392502/appStoreVersions?limit=200'
        base = 'https://api.appstoreconnect.apple.com/v1'
        with self.assertRaisesRegex(ValueError, 'pagination repeated'):
            API['read_apple_collection'](lambda _: {'data': [], 'links': {'next': base + path}}, path)
        for link in ['https://example.com/v1' + path, 'http://api.appstoreconnect.apple.com/v1' + path,
                     base + '/apps/another/appStoreVersions?cursor=second', '/apps/6815392502/appStoreVersions?cursor=second']:
            with self.subTest(link=link), self.assertRaisesRegex(ValueError, 'Unexpected Apple'):
                API['read_apple_collection'](lambda _: {'data': [], 'links': {'next': link}}, path)
        count = 0
        def endless(_):
            nonlocal count
            count += 1
            return {'data': [], 'links': {'next': base + '/apps/6815392502/appStoreVersions?cursor=' + str(count)}}
        with self.assertRaisesRegex(ValueError, 'pagination limit exceeded'):
            API['read_apple_collection'](endless, path, max_pages=2)
        self.assertEqual(count, 2)

    def test_apple_collection_rejects_noncollection_data(self):
        with self.assertRaisesRegex(ValueError, 'Invalid Apple collection page'):
            API['read_apple_collection'](lambda _: {'data': {'id': 'single-object'}}, '/appEncryptionDeclarations?limit=200')


if __name__ == '__main__':
    unittest.main()
