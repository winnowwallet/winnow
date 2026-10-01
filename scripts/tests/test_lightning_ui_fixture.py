"""A failed async UI case must retain its journal when BOLT11 starts next."""
import hashlib
import importlib.machinery
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock, patch


loader = importlib.machinery.SourceFileLoader(
    'lightning_ui_fixture', str(Path(__file__).parents[1] / 'lightning-ui-fixture'))
spec = importlib.util.spec_from_loader(loader.name, loader)
ui = importlib.util.module_from_spec(spec)
loader.exec_module(ui)


class OutgoingJournalTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.journey = ui.Journey.__new__(ui.Journey)
        self.journey.evidence = self.root / 'evidence'
        self.journey.evidence.mkdir()
        self.journey.run = 'ln-failed-async'
        self.journey.clients, self.journey.timeline = {}, []
        state = self.root / 'state'
        state.mkdir()
        self.journey.fixture = SimpleNamespace(root=state, base=['-rpcport=18443'],
                                               p2p_port=18444, bitcoin=self.root / 'bitcoin', log=Mock())
        self.journey.ln = Mock(return_value={'id': 'stock-node'})

    def register_journal(self, role, content, pid):
        source = self.root / self.journey.run / role / 'story-events.jsonl'
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_bytes(content)
        self.journey.clients[role] = {'pid': pid, 'journal': str(source)}
        return source

    def start_invoice_fixture(self):
        peer = {'CLN_COMMIT': 'pinned', 'wait_for': lambda check: check()}
        with patch.dict(ui.os.environ, WINNOW_CLN_DIR=str(self.root / 'cln')), \
                patch('runpy.run_path', return_value=peer), \
                patch.object(ui.subprocess, 'check_output', return_value='pinned\n'), \
                patch.object(ui.subprocess, 'run'), patch.object(ui.subprocess, 'Popen'), \
                patch.object(ui.reference, 'port', return_value=9735), \
                patch.object(ui.secrets, 'token_hex', return_value='next-invoice'):
            return self.journey.invoice_fixture()

    def test_failed_async_clients_survive_later_invoice_registration_and_final_export(self):
        contents = {'recipient': b'{"name":"recipient.failed-ui"}\n',
                    'sender': b'{"name":"sender.failed-ui"}\n'}
        originals = {role: self.register_journal(role, content, 100 + index)
                     for index, (role, content) in enumerate(contents.items())}
        response = self.start_invoice_fixture()
        self.assertEqual(response['run'], 'bolt11-next-invoice')
        self.assertEqual(self.journey.clients, {})
        invoice_content = b'{"name":"invoice.restart"}\n'
        self.register_journal('sender', invoice_content, 200)
        self.journey.export_journals()

        self.assertEqual((self.journey.evidence / 'sender-story-events.jsonl').read_bytes(), invoice_content)
        self.assertEqual((self.journey.evidence / 'recipient-story-events.jsonl').read_bytes(), contents['recipient'])
        events = [json.loads(line) for line in (self.journey.evidence / 'process-events.jsonl').read_text().splitlines()]
        self.assertEqual(len(events), 2)
        for event in events:
            content = contents[event['role']]
            self.assertEqual(event['event'], 'client_journal_preserved')
            self.assertEqual(event['run'], 'ln-failed-async')
            self.assertEqual(event['pid'], 100 + list(contents).index(event['role']))
            self.assertEqual(event['snapshot'], 'ln-failed-async-' + event['role'] + '-story-events.jsonl')
            self.assertEqual(event['sha256'], hashlib.sha256(content).hexdigest())
            self.assertEqual((self.journey.evidence / event['snapshot']).read_bytes(), content)
            self.assertEqual(originals[event['role']].read_bytes(), content)

    def test_failed_export_does_not_discard_outgoing_identity_or_start_a_reference(self):
        self.register_journal('recipient', b'{"name":"failed-ui"}\n', 100)
        self.journey.evidence.rmdir()
        self.journey.evidence.write_text('not a directory')
        original_clients = dict(self.journey.clients)
        with patch.object(ui.subprocess, 'Popen') as start, self.assertRaises(OSError):
            self.journey.invoice_fixture()
        start.assert_not_called()
        self.assertEqual(self.journey.clients, original_clients)
        self.assertEqual(self.journey.run, 'ln-failed-async')

    def test_missing_journal_does_not_read_other_wallet_files(self):
        directory = self.root / 'missing-journal'
        directory.mkdir()
        (directory / 'wallet.json').write_text('private wallet data must not be exported')
        self.journey.clients = {'recipient': {'pid': 100, 'journal': str(directory / 'story-events.jsonl')}}
        self.journey.export_journals(preserve_run=True)
        self.assertEqual(list(self.journey.evidence.iterdir()), [])
        self.assertEqual(self.journey.timeline, [])


if __name__ == '__main__':
    unittest.main()
