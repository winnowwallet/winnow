from pathlib import Path
import runpy
import unittest

TOOL = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'lightning-encryption-declaration'))
PROJECT = (Path(__file__).resolve().parents[2] / 'project.yml').read_text()


class EncryptionDeclarationTests(unittest.TestCase):
    def lightning(self, text):
        return text.split('\n  WinnowLightning:\n', 1)[1].split('\n  WinnowAppTests:\n', 1)[0]

    def ordinary(self, text):
        return text.split('\n  WinnowLightning:\n', 1)[0]

    def test_only_the_lightning_target_changes(self):
        for mode, code in (('PENDING', None), ('YES', 'abc-123'), ('NO', None)):
            with self.subTest(mode=mode):
                declared = TOOL['declare'](PROJECT, mode, code)
                self.assertEqual(self.ordinary(declared), self.ordinary(PROJECT))
                self.assertIn('INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO', self.ordinary(declared))

    def test_each_answer_sets_exactly_its_keys(self):
        pending = self.lightning(TOOL['declare'](PROJECT, 'PENDING'))
        self.assertNotIn('ITSAppUsesNonExemptEncryption', pending)
        self.assertNotIn('ITSEncryptionExportComplianceCode', pending)
        approved = self.lightning(TOOL['declare'](PROJECT, 'YES', 'abc-123'))
        self.assertIn('INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: YES', approved)
        self.assertIn('INFOPLIST_KEY_ITSEncryptionExportComplianceCode: "abc-123"', approved)
        self.assertIn('INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO', self.lightning(TOOL['declare'](PROJECT, 'NO')))

    def test_an_unreviewed_or_incomplete_answer_is_refused(self):
        for mode, code in (('YES', None), ('MAYBE', None)):
            with self.subTest(mode=mode), self.assertRaises(SystemExit):
                TOOL['declare'](PROJECT, mode, code)


if __name__ == '__main__':
    unittest.main()
