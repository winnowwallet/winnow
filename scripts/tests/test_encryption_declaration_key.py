from pathlib import Path
import runpy
import unittest

TOOL = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'encryption-declaration-key'))
PROJECT = (Path(__file__).resolve().parents[2] / 'project.yml').read_text()


class EncryptionDeclarationKeyTests(unittest.TestCase):
    def app(self, text):
        return text.split('\n  WinnowApp:\n', 1)[1].split('\n  WinnowAppTests:\n', 1)[0]

    def rest(self, text):
        head, tail = text.split('\n  WinnowApp:\n', 1)
        return head + tail.split('\n  WinnowAppTests:\n', 1)[1]

    def test_only_the_app_target_changes(self):
        for mode, code in (('PENDING', None), ('YES', 'abc-123'), ('YES', None), ('NO', None)):
            with self.subTest(mode=mode, code=code):
                self.assertEqual(self.rest(TOOL['declare'](PROJECT, mode, code)), self.rest(PROJECT))

    def test_each_answer_sets_exactly_its_keys(self):
        pending = self.app(TOOL['declare'](PROJECT, 'PENDING'))
        self.assertNotIn('ITSAppUsesNonExemptEncryption', pending)
        self.assertNotIn('ITSEncryptionExportComplianceCode', pending)
        approved = self.app(TOOL['declare'](PROJECT, 'YES', 'abc-123'))
        self.assertIn('INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: YES', approved)
        self.assertIn('INFOPLIST_KEY_ITSEncryptionExportComplianceCode: "abc-123"', approved)
        documented = self.app(TOOL['declare'](PROJECT, 'YES'))
        self.assertIn('INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: YES', documented)
        self.assertNotIn('ITSEncryptionExportComplianceCode', documented)
        self.assertIn('INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO', self.app(TOOL['declare'](PROJECT, 'NO')))

    def test_an_unreviewed_or_contradictory_answer_is_refused(self):
        for mode, code in (('MAYBE', None), ('NO', 'abc-123')):
            with self.subTest(mode=mode), self.assertRaises(SystemExit):
                TOOL['declare'](PROJECT, mode, code)


if __name__ == '__main__':
    unittest.main()
