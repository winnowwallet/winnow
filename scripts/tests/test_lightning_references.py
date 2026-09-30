"""The external reference builder must run only from the pinned, clean checkout."""
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).resolve().parents[1] / 'ci-lightning-references'


class ReferenceCheckoutTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.origin = self.root / 'origin'
        self.origin.mkdir()
        self.git('init', '-q', cwd=self.origin)
        self.git('config', 'user.name', 'Reference test', cwd=self.origin)
        self.git('config', 'user.email', 'reference@example.invalid', cwd=self.origin)
        (self.origin / 'builder').write_text('original builder\n')
        self.git('add', 'builder', cwd=self.origin)
        self.git('commit', '-qm', 'Pinned builder', cwd=self.origin)
        self.commit = self.git('rev-parse', 'HEAD', cwd=self.origin)
        self.destination = self.root / 'checkout'
        self.checkout = runpy.run_path(str(SCRIPT))['checkout']

    def git(self, *args, cwd):
        return subprocess.check_output(['git', *args], cwd=cwd, text=True, stderr=subprocess.PIPE).strip()

    def fetch(self):
        self.checkout(self.destination, str(self.origin), self.commit)

    def test_fetches_exact_revision_and_reuses_clean_checkout(self):
        (self.origin / 'builder').write_text('new unpinned builder\n')
        self.git('commit', '-qam', 'Unpinned change', cwd=self.origin)
        self.fetch()
        self.assertEqual((self.destination / 'builder').read_text(), 'original builder\n')
        self.fetch()
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=self.destination), self.commit)

    def test_rejects_wrong_revision_before_running_builder(self):
        self.fetch()
        with self.assertRaisesRegex(SystemExit, 'Wrong reference checkout'):
            self.checkout(self.destination, str(self.origin), '0' * 40)

    def test_rejects_modified_or_untracked_source(self):
        self.fetch()
        builder = self.destination / 'builder'
        builder.write_text('modified\n')
        with self.assertRaisesRegex(SystemExit, 'local changes'):
            self.fetch()
        self.git('restore', 'builder', cwd=self.destination)
        (self.destination / 'injected.py').write_text('unexpected source\n')
        with self.assertRaisesRegex(SystemExit, 'local changes'):
            self.fetch()

    def test_main_passes_the_original_build_directory_to_external_builder(self):
        module = runpy.run_path(str(SCRIPT))
        main = module['main']
        destination = (self.root / 'reference build').resolve()
        with patch.dict(main.__globals__, checkout=Mock(), run=Mock()):
            with patch('sys.argv', [str(SCRIPT), str(destination)]):
                main()
            main.__globals__['checkout'].assert_called_once_with(
                destination / 'reference-source', module['REPOSITORY'], module['COMMIT'])
            main.__globals__['run'].assert_called_once_with(
                module['sys'].executable,
                str(destination / 'reference-source/scripts/build-references'), str(destination))


if __name__ == '__main__':
    unittest.main()
