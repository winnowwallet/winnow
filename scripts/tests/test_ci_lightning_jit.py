"""The instant-receive driver checks the provider's exact fee and names each variant."""
from pathlib import Path
import runpy
from types import SimpleNamespace
import unittest
from unittest.mock import patch


DRIVER = runpy.run_path(str(Path(__file__).parents[1] / 'ci-lightning-jit'))


def options(**values):
    return SimpleNamespace(**{'client_trusts_lsp': False, 'scid_privacy': False, 'anchors': False,
                              'zero_reserve': False, **values})


class InstantReceiveDriverTests(unittest.TestCase):
    def test_opening_fee_is_the_bLIP52_formula(self):
        fee = DRIVER['opening_fee']
        self.assertEqual(fee(50_000_000), 1_000_000, 'minimum fee')
        self.assertEqual(fee(200_000_000), 2_000_000, 'one percent')
        self.assertEqual(fee(100_000_001), 1_000_001, 'rounded up')

    def test_each_variant_has_its_own_evidence_and_provider_settings(self):
        plain, trusted = options(), options(client_trusts_lsp=True, scid_privacy=True, anchors=True, zero_reserve=True)
        self.assertEqual(DRIVER['scenario'](plain), 'jit-lsp-broadcasts-real-scid-static-key-reserve')
        self.assertEqual(DRIVER['scenario'](trusted), 'jit-trusts-lsp-scid-privacy-anchors-zero-reserve')
        self.assertEqual(set(DRIVER['provider_environment'](plain).values()), {'0'})
        self.assertEqual(set(DRIVER['provider_environment'](trusted).values()), {'1'})

    def test_zero_reserve_without_anchors_is_refused_before_anything_starts(self):
        with patch('sys.argv', ['ci-lightning-jit', '--zero-reserve']), self.assertRaises(SystemExit), \
                patch('sys.stderr'):
            DRIVER['main']()


if __name__ == '__main__':
    unittest.main()
