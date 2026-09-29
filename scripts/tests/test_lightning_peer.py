"""Reference startup recovery must never turn a protocol failure into a pass."""
import json
import io
from contextlib import redirect_stderr
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import Mock, patch
from types import SimpleNamespace

SCRIPT = Path(__file__).resolve().parents[1] / 'ci-lightning-peer'
CRASH = '''DEBUG chan#1: Got opening_fundee_finish_response
INFO chan#1: Peer transient failure in CHANNELD_AWAITING_LOCKIN: channeld: Owning subdaemon channeld died (0)
'''


class PeerStartupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.log = self.root / 'cln.log'
        self.log.write_text(CRASH)
        self.module = runpy.run_path(str(SCRIPT))
        self.failure = self.module['ReferenceStartupFailure']

    def test_only_known_pre_signature_macos_crash_is_classified(self):
        receive = self.module['funding_signature']
        peer = Mock()
        peer.receive.side_effect = TimeoutError('no response')
        with patch('sys.platform', 'darwin'):
            with self.assertRaises(self.failure):
                receive(peer, self.log)
            for transcript in ('', CRASH.replace('(0)', '(9)'),
                               CRASH.replace('CHANNELD_AWAITING_LOCKIN', 'CHANNELD_NORMAL'),
                               CRASH.replace('Got opening_fundee_finish_response', ''),
                               CRASH + 'peer_out WIRE_FUNDING_SIGNED',
                               CRASH + 'peer_out WIRE_ERROR', CRASH + '**BROKEN** hsmd'):
                with self.subTest(transcript=transcript):
                    self.log.write_text(transcript)
                    with self.assertRaises(TimeoutError):
                        receive(peer, self.log)
        self.log.write_text(CRASH)
        with patch('sys.platform', 'linux'), self.assertRaises(TimeoutError):
            receive(peer, self.log)

    def test_protocol_rejection_and_success_are_not_reclassified(self):
        peer = Mock()
        peer.receive.side_effect = AssertionError('peer rejected protocol')
        with patch('sys.platform', 'darwin'), self.assertRaises(AssertionError):
            self.module['funding_signature'](peer, self.log)
        peer.receive.side_effect = None
        peer.receive.return_value = {'event': 'broadcast_funding', 'transaction': 'verified'}
        self.assertEqual(self.module['funding_signature'](peer, self.log), peer.receive.return_value)

    def test_retry_uses_fresh_fixture_and_retains_both_attempts(self):
        check = self.module['check_peer']
        directories = []

        def run(mode, evidence, channel_format='staticRemoteKey', offers=False):
            self.assertEqual(channel_format, 'staticRemoteKey')
            self.assertFalse(offers)
            directories.append(evidence)
            (evidence / 'cln.log').write_text(CRASH if len(directories) == 1 else 'passed')
            if len(directories) == 1:
                raise self.failure('reference startup')
            (evidence / 'opening-receipt.json').write_text(json.dumps({'result': 'passed', 'close_mode': mode}))

        evidence = self.root / 'results'
        with patch.dict(check.__globals__, run_peer=run):
            check('cooperative', evidence)
        self.assertEqual(directories, [evidence / 'attempt-1', evidence / 'attempt-2'])
        self.assertEqual((directories[0] / 'cln.log').read_text(), CRASH)
        receipt = json.loads((evidence / 'opening-receipt.json').read_text())
        self.assertEqual([item['result'] for item in receipt['attempts']], ['reference-startup-failure', 'passed'])

    def test_second_crash_or_any_other_failure_remains_fatal(self):
        check = self.module['check_peer']
        for index, (error, calls) in enumerate(((self.failure('startup'), 2),
                                              (AssertionError('bad signature or balance'), 1),
                                              (TimeoutError('payment stalled'), 1))):
            with self.subTest(error=error):
                evidence = self.root / str(index)
                run = Mock(side_effect=error)
                with patch.dict(check.__globals__, run_peer=run), self.assertRaises(type(error)):
                    check('force', evidence)
                self.assertEqual(run.call_count, calls)
                self.assertFalse((evidence / 'opening-receipt.json').exists())


class RoutedReferenceStartupTests(unittest.TestCase):
    SOURCE = '02' + '11' * 32
    RECIPIENT = '03' + '22' * 32
    FUNDING = 'ab' * 32

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.module = runpy.run_path(str(SCRIPT))
        self.failure = self.module['ReferenceStartupFailure']
        self.funder = (f'DEBUG {self.RECIPIENT}-openingd-chan#2: continuing with funding_txid {self.FUNDING}\n'
                       f'DEBUG {self.RECIPIENT}-openingd-chan#2: peer_out WIRE_FUNDING_CREATED\n')
        self.recipient = (f'DEBUG {self.SOURCE}-openingd-chan#1: peer_in WIRE_FUNDING_CREATED\n'
                          f'DEBUG {self.SOURCE}-chan#1: Got opening_fundee_finish_response\n'
                          f'DEBUG {self.SOURCE}-chan#1: Watching funding tx {self.FUNDING}\n'
                          f'DEBUG {self.SOURCE}-channeld-chan#1: init REMOTE: next_idx_local = 1 next_idx_remote = 1\n'
                          f'INFO {self.SOURCE}-chan#1: Peer transient failure in CHANNELD_AWAITING_LOCKIN: channeld: Owning subdaemon channeld died (0)\n')
        self.channels = dict(channels=[dict(peer_id=self.RECIPIENT, state='OPENINGD', owner='lightning_openingd',
            opener='local', status=['Funding channel: create first tx, now waiting for their signature'])])
        self.write_logs(self.funder, self.recipient)
        self.error = self.module['subprocess'].TimeoutExpired(['lightning-cli', '-k', 'fundchannel'], 20)

    def write_logs(self, funder, recipient):
        (self.root / 'cln.log').write_text(funder)
        (self.root / 'recipient-cln.log').write_text(recipient)

    def invoke(self, ln):
        return self.module['open_routed_reference_channel'](ln, self.SOURCE, self.RECIPIENT, self.root)

    def test_known_target_only_prebroadcast_failure_retains_original_and_state(self):
        # The earlier Swift channel is funded; its signatures do not belong to
        # the new stock routed channel being classified.
        self.write_logs(f'DEBUG 02other-channeld-chan#1: peer_out WIRE_FUNDING_SIGNED\n' + self.funder, self.recipient)
        ln = Mock(side_effect=[self.error, self.channels])
        with patch('sys.platform', 'darwin'), self.assertRaises(self.failure) as caught:
            self.invoke(ln)
        self.assertIs(caught.exception.__cause__, self.error)
        self.assertEqual(ln.call_args_list[0].args, ('-k', 'fundchannel', 'id=' + self.RECIPIENT, 'amount=500000sat', 'announce=true'))
        self.assertEqual(ln.call_args_list[1].args, ('listpeerchannels',))
        receipt = json.loads((self.root / 'routed-funding-failure.json').read_text())
        self.assertTrue(receipt['classified'])
        self.assertEqual(receipt['funding_txid'], self.FUNDING)
        self.assertEqual(receipt['reference_channels'], self.channels)
        self.assertIn('TimeoutExpired', receipt['original_failure'])
        self.assertIn('unproven', receipt['cause'])

    def test_success_or_non20s_timeout_or_rpc_rejection_are_unchanged(self):
        result = dict(txid=self.FUNDING)
        ln = Mock(return_value=result)
        self.assertIs(self.invoke(ln), result)
        ln.assert_called_once()
        for error in (self.module['subprocess'].TimeoutExpired(['lightning-cli'], 30),
                      self.module['subprocess'].CalledProcessError(1, ['lightning-cli']),
                      AssertionError('invalid channel signature')):
            with self.subTest(error=error), patch('sys.platform', 'darwin'):
                ln = Mock(side_effect=error)
                with self.assertRaises(type(error)) as caught:
                    self.invoke(ln)
                self.assertIs(caught.exception, error)
                ln.assert_called_once()

    def test_unknown_rejected_or_post_signature_log_remains_fatal(self):
        mutations = [('', self.recipient), (self.funder, ''),
            (self.funder, self.recipient.replace('(0)', '(9)')),
            (self.funder, self.recipient.replace('CHANNELD_AWAITING_LOCKIN', 'CHANNELD_NORMAL')),
            (self.funder, self.recipient.replace('Got opening_fundee_finish_response', 'other response')),
            (self.funder, self.recipient.replace(self.SOURCE, '03' + '55' * 32)),
            (self.funder, self.recipient.replace(self.FUNDING, 'cd' * 32)),
            (self.funder + f'DEBUG {self.RECIPIENT}-openingd: peer_in WIRE_FUNDING_SIGNED\n', self.recipient),
            (self.funder, self.recipient + f'DEBUG {self.SOURCE}-channeld: peer_out WIRE_FUNDING_SIGNED\n')]
        for marker in ('peer_in WIRE_ERROR', '**BROKEN**', 'STATUS_FAIL_HSM_IO', 'sendrawtransaction:', 'sendpsbt.'):
            mutations.append((self.funder + marker, self.recipient))
        for funder, recipient in mutations:
            with self.subTest(funder=funder[-100:], recipient=recipient[-100:]):
                self.write_logs(funder, recipient)
                ln = Mock(side_effect=[self.error, self.channels])
                with patch('sys.platform', 'darwin'), self.assertRaises(type(self.error)) as caught:
                    self.invoke(ln)
                self.assertIs(caught.exception, self.error)
                self.assertFalse(json.loads((self.root / 'routed-funding-failure.json').read_text())['classified'])

    def test_channel_snapshot_must_be_unique_exact_target_waiting_for_signature(self):
        for change in (dict(state='CHANNELD_NORMAL'), dict(owner='channeld'), dict(opener='remote'),
                       dict(peer_id=self.SOURCE), dict(funding_txid=self.FUNDING), dict(channel_id='aa' * 32),
                       dict(status=['Funding broadcast'])):
            channel = self.channels['channels'][0] | change
            with self.subTest(change=change), patch('sys.platform', 'darwin'):
                ln = Mock(side_effect=[self.error, dict(channels=[channel])])
                with self.assertRaises(type(self.error)) as caught:
                    self.invoke(ln)
                self.assertIs(caught.exception, self.error)
        duplicate = dict(channels=self.channels['channels'] * 2)
        with patch('sys.platform', 'darwin'), self.assertRaises(type(self.error)):
            self.invoke(Mock(side_effect=[self.error, duplicate]))

    def test_classified_stock_failure_stops_after_two_fresh_retained_attempts(self):
        check = self.module['check_peer']
        directories = []
        def run(mode, evidence, channel_format='staticRemoteKey', offers=False):
            directories.append(evidence)
            (evidence / 'cln.log').write_text(self.funder)
            (evidence / 'recipient-cln.log').write_text(self.recipient)
            self.module['open_routed_reference_channel'](Mock(side_effect=[self.error, self.channels]),
                self.SOURCE, self.RECIPIENT, evidence)
        evidence = self.root / 'attempts'
        with patch('sys.platform', 'darwin'), patch.dict(check.__globals__, run_peer=run):
            with self.assertRaises(self.failure):
                check('cooperative', evidence)
        self.assertEqual(directories, [evidence / 'attempt-1', evidence / 'attempt-2'])
        self.assertFalse((evidence / 'attempt-3').exists())
        self.assertFalse((evidence / 'opening-receipt.json').exists())
        history = json.loads((evidence / 'attempts.json').read_text())
        self.assertEqual([item['result'] for item in history], ['reference-startup-failure'] * 2)
        for attempt in directories:
            receipt = json.loads((attempt / 'routed-funding-failure.json').read_text())
            self.assertTrue(receipt['classified'])
            self.assertEqual(receipt['reference_channels'], self.channels)
            self.assertEqual((attempt / 'recipient-cln.log').read_text(), self.recipient)

    def test_other_platform_or_failed_diagnostics_do_not_reclassify_timeout(self):
        ln = Mock(side_effect=self.error)
        with patch('sys.platform', 'linux'), self.assertRaises(type(self.error)) as caught:
            self.invoke(ln)
        self.assertIs(caught.exception, self.error)
        ln.assert_called_once()
        for error in (RuntimeError('RPC unavailable'), {'channels': []}):
            ln = Mock(side_effect=[self.error, error] if isinstance(error, Exception) else [self.error, error])
            with patch('sys.platform', 'darwin'), self.assertRaises(type(self.error)) as caught:
                self.invoke(ln)
            self.assertIs(caught.exception, self.error)
        with patch.object(Path, 'read_text', side_effect=OSError('log unavailable')):
            with patch('sys.platform', 'darwin'), self.assertRaises(type(self.error)) as caught:
                self.invoke(Mock(side_effect=[self.error, self.channels]))
            self.assertIs(caught.exception, self.error)
        with patch.object(Path, 'write_text', side_effect=OSError('disk full')):
            with patch('sys.platform', 'darwin'), self.assertRaises(type(self.error)) as caught:
                self.invoke(Mock(side_effect=[self.error, self.channels]))
            self.assertIs(caught.exception, self.error)



class PeerDiagnosticTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.module = runpy.run_path(str(SCRIPT))

    def peer(self, response=b'{"type":"38"}\n'):
        peer = self.module['SwiftPeer'].__new__(self.module['SwiftPeer'])
        peer.process = SimpleNamespace(stdin=io.BytesIO(), stdout=io.BytesIO(response))
        peer.selector = Mock()
        peer.selector.select.return_value = [(peer.process.stdout, None)]
        peer.trace = io.StringIO()
        return peer

    def test_command_and_response_trace_preserves_wire_exchange_and_timeout(self):
        peer = self.peer()
        result = peer.call('receive', expected='38')
        self.assertEqual(result, {'type': '38'})
        self.assertEqual(json.loads(peer.process.stdin.getvalue()), {'command': 'receive', 'expected': '38'})
        records = [json.loads(line) for line in peer.trace.getvalue().splitlines()]
        self.assertEqual([record['kind'] for record in records], ['request', 'response'])
        self.assertEqual(records[0]['arguments'], {'expected': '38'})
        self.assertEqual(records[1]['response'], result)
        peer.selector.select.assert_called_once_with(timeout=60)

    def test_stalled_receive_remains_fatal_and_retains_unanswered_command(self):
        peer = self.peer()
        peer.selector.select.return_value = []
        with self.assertRaisesRegex(TimeoutError, 'Swift peer did not complete'):
            peer.call('receive')
        peer.selector.select.assert_called_once_with(timeout=60)
        records = [json.loads(line) for line in peer.trace.getvalue().splitlines()]
        self.assertEqual([record['kind'] for record in records], ['request', 'failure'])
        self.assertEqual(records[-1]['command'], 'receive')
        self.assertIn('TimeoutError', records[-1]['error'])

    def test_failure_trace_write_cannot_replace_protocol_timeout(self):
        peer = self.peer()
        peer.selector.select.return_value = []
        peer.record = Mock(side_effect=[None, OSError('disk full')])
        output = io.StringIO()
        with redirect_stderr(output), self.assertRaisesRegex(TimeoutError, 'Swift peer did not complete'):
            peer.call('receive')
        self.assertIn('disk full', output.getvalue())
        peer.selector.select.assert_called_once_with(timeout=60)

    def test_oversized_trace_record_is_bounded_and_retains_exact_content_hash(self):
        peer = self.peer()
        record = dict(time_ns=42, kind='request', command='scan_block', arguments={'hex': 'ab' * 40_000})
        with patch('time.time_ns', return_value=42):
            peer.record('request', command=record['command'], arguments=record['arguments'])
        encoded = json.dumps(record, sort_keys=True).encode()
        saved = json.loads(peer.trace.getvalue())
        self.assertTrue(saved['truncated'])
        self.assertEqual(saved['bytes'], len(encoded))
        self.assertEqual(saved['sha256'], self.module['hashlib'].sha256(encoded).hexdigest())
        self.assertLess(len(peer.trace.getvalue().encode()), 65_536)

    def test_failure_state_and_log_tails_are_bounded_without_hiding_rpc_failure(self):
        log = self.root / 'cln.log'
        log.write_text('old daemon line\n' * 100_000 + 'WIRE_SHUTDOWN\nWaiting for their initial closing fee offer\n')
        tail = self.module['bounded_log_tail'](log)
        self.assertLessEqual(len(tail.encode()), 32_768)
        self.assertLessEqual(len(tail.splitlines()), 160)
        self.assertIn('Waiting for their initial closing fee offer', tail)
        ln = Mock(side_effect=RuntimeError('RPC unavailable'))
        output = io.StringIO()
        with redirect_stderr(output):
            self.module['failure_diagnostics'](TimeoutError('closing_signed absent'), ln, self.root)
        ln.assert_called_once_with('listpeerchannels')
        state = json.loads((self.root / 'failure-state.json').read_text())
        self.assertIn('TimeoutError', state['failure'])
        self.assertIn('RPC unavailable', state['reference_channels']['diagnostic_error'])
        self.assertIn('WIRE_SHUTDOWN', output.getvalue())
        self.assertIn('FileNotFoundError', output.getvalue())

    def test_failure_state_captures_reference_channel_commitment_and_htlc_state(self):
        channels = {'channels': [{'state': 'CHANNELD_SHUTTING_DOWN', 'htlcs': [], 'next_local_commitment_number': 15}]}
        with redirect_stderr(io.StringIO()):
            self.module['failure_diagnostics'](TimeoutError('closing_signed absent'), Mock(return_value=channels), self.root)
        state = json.loads((self.root / 'failure-state.json').read_text())
        self.assertEqual(state['reference_channels'], channels)

    def test_filtered_close_events_survive_unrelated_recipient_and_backend_chatter(self):
        log = self.root / 'cln.log'
        events = ['DEBUG channeld: peer_in WIRE_CHANNEL_REESTABLISH',
                  'DEBUG channeld: next_idx_local = 15 next_idx_remote = 15 revocations_received = 14',
                  'DEBUG channeld: peer_out WIRE_SHUTDOWN',
                  'DEBUG peer-closingd-chan#1: Waiting for their initial closing fee offer']
        chatter = 'DEBUG recipient-gossipd: Received channel update\nDEBUG plugin-bcli: getblock completed\n'
        log.write_text('\n'.join(events) + '\n' + chatter * 100_000)
        self.assertNotIn('WIRE_SHUTDOWN', self.module['bounded_log_tail'](log))
        filtered = self.module['bounded_close_tail'](log)
        self.assertEqual(filtered.splitlines(), events)
        self.assertNotIn('getblock', filtered)
        with redirect_stderr(io.StringIO()) as output:
            self.module['failure_diagnostics'](TimeoutError('closing_signed absent'), Mock(return_value={'channels': []}), self.root)
        self.assertIn('WIRE_SHUTDOWN', output.getvalue())
        self.assertIn('Waiting for their initial closing fee offer', output.getvalue())

    def test_filtered_tail_enforces_event_byte_and_physical_line_bounds(self):
        log = self.root / 'cln.log'
        long_line = b'WIRE_CLOSING_SIGNED ' + b'x' * 1_000_000 + b'\n'
        log.write_bytes(long_line + b'final unterminated line')
        lines = list(self.module['bounded_log_lines'](log))
        self.assertEqual(len(lines), 2)
        self.assertLessEqual(len(lines[0]), 4096 + len(b' [line clipped]'))
        self.assertTrue(lines[0].endswith(b' [line clipped]'))
        self.assertEqual(lines[1], b'final unterminated line')
        log.write_bytes(b'\n'.join((f'{index}: WIRE_REVOKE_AND_ACK '.encode() + ('\u2603' * 1000).encode() + b'\xff')
                                  for index in range(300)) + b'\n299: WIRE_CLOSING_SIGNED newest\n')
        for maximum in (32_768, 1024, 1):
            with self.subTest(maximum=maximum):
                tail = self.module['bounded_close_tail'](log, maximum)
                self.assertLessEqual(len(tail.encode()), maximum)
                self.assertLessEqual(len(tail.splitlines()), 160)
        self.assertIn('WIRE_CLOSING_SIGNED newest', self.module['bounded_close_tail'](log))
        self.assertFalse(any(line.startswith('0: ') for line in self.module['bounded_close_tail'](log).splitlines()))
        log.write_text(''.join(f'{index}: WIRE_REVOKE_AND_ACK\n' for index in range(300)) + 'WIRE_CLOSING_SIGNED newest\n')
        events = self.module['bounded_close_tail'](log).splitlines()
        self.assertEqual(len(events), 160)
        self.assertEqual(events[0], '141: WIRE_REVOKE_AND_ACK')
        self.assertEqual(events[-1], 'WIRE_CLOSING_SIGNED newest')
        for maximum in (0, -1):
            with self.assertRaises(ValueError):
                self.module['bounded_close_tail'](log, maximum)

    def test_filtered_diagnostic_read_error_preserves_original_receive_timeout(self):
        peer = self.peer()
        peer.selector.select.return_value = []
        diagnostics = self.module['failure_diagnostics']
        original = None
        output = io.StringIO()
        with patch.dict(diagnostics.__globals__, bounded_close_tail=Mock(side_effect=OSError('daemon log unreadable'))), redirect_stderr(output):
            with self.assertRaises(TimeoutError) as raised:
                try:
                    peer.call('receive')
                except TimeoutError as error:
                    original = error
                    diagnostics(error, Mock(return_value={'channels': []}), self.root)
                    raise
        self.assertIs(raised.exception, original)
        peer.selector.select.assert_called_once_with(timeout=60)
        self.assertIn('daemon log unreadable', output.getvalue())
        saved = json.loads((self.root / 'failure-state.json').read_text())
        self.assertIn('Swift peer did not complete a protocol operation', saved['failure'])


if __name__ == '__main__':
    unittest.main()
