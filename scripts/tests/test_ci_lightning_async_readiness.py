"""Offline replay must not outrun the initialized release-response route."""
from pathlib import Path
import runpy
from types import SimpleNamespace
import unittest
from unittest.mock import patch


DRIVER = Path(__file__).parents[1] / 'ci-lightning-async'


class Recipient:
    """Model distinct TCP acceptance, Init, and notification replay events."""
    def __init__(self, return_provider, notification_provider, init_after=None, status_error=None):
        self.return_provider, self.notification_provider = return_provider, notification_provider
        self.init_after, self.status_error = init_after, status_error
        self.started, self.stopped = 0, 5
        self.starts, self.status_reads = 0, 0
        self.connections = []
        self.initialized = False
        self.notification_replayed = False

    def start(self):
        self.starts += 1
        self.started, self.stopped = 10, None

    def call(self, command, **values):
        if command == 'connect':
            self.connections.append(values['peer'])
            if values['peer'] == self.notification_provider.node:
                if not self.initialized:
                    raise AssertionError('Held notification replayed before its return route completed Init')
                self.notification_replayed = True
            # Successful TCP acceptance deliberately does not set initialized.
            return {'connected': True}
        if command != 'status':
            raise AssertionError('Unexpected protocol or financial command')
        self.status_reads += 1
        if self.status_error is not None:
            raise self.status_error
        self.initialized = self.init_after is not None and self.status_reads >= self.init_after
        peers = [self.return_provider.node] if self.initialized else [self.notification_provider.node]
        return {'peers': peers}


class AsyncRecipientReadinessTests(unittest.TestCase):
    def setUp(self):
        self.module = runpy.run_path(str(DRIVER))
        self.reconnect = self.module['reconnect_async_recipient']
        self.return_provider = SimpleNamespace(node='holding-provider-a', initial={'port': 21001})
        self.notification_provider = SimpleNamespace(node='receiving-provider-b', initial={'port': 22001})

    def test_notification_replay_waits_for_init_not_successful_tcp_connect(self):
        recipient = Recipient(self.return_provider, self.notification_provider, init_after=3)
        stopped = recipient.stopped
        with patch.object(self.module['time'], 'sleep'):
            self.reconnect(recipient, self.return_provider, self.notification_provider)
        self.assertTrue(recipient.notification_replayed)
        self.assertEqual(recipient.status_reads, 3)
        self.assertEqual(recipient.connections, [self.return_provider.node, self.notification_provider.node])
        self.assertEqual(recipient.starts, 1)
        self.assertEqual((stopped, recipient.started), (5, 10))

    def test_tcp_acceptance_without_init_hits_original_deadline_without_replay(self):
        recipient = Recipient(self.return_provider, self.notification_provider)
        # Use the real wait with its original 45-second deadline, advancing a
        # monotonic clock after one non-ready status response without sleeping.
        with patch.object(self.module['time'], 'monotonic', side_effect=[0, 0, 45]), \
             patch.object(self.module['time'], 'sleep'):
            with self.assertRaisesRegex(TimeoutError, 'Async peer condition did not become true'):
                self.reconnect(recipient, self.return_provider, self.notification_provider)
        self.assertEqual(recipient.connections, [self.return_provider.node])
        self.assertEqual(recipient.status_reads, 1)
        self.assertFalse(recipient.notification_replayed)
        self.assertEqual(recipient.starts, 1)

    def test_failed_init_observation_is_fatal_without_notification_connect_or_retry(self):
        failure = RuntimeError('peer exited during Init')
        recipient = Recipient(self.return_provider, self.notification_provider, status_error=failure)
        with self.assertRaises(RuntimeError) as caught:
            self.reconnect(recipient, self.return_provider, self.notification_provider)
        self.assertIs(caught.exception, failure)
        self.assertEqual(recipient.connections, [self.return_provider.node])
        self.assertFalse(recipient.notification_replayed)
        self.assertEqual((recipient.starts, recipient.status_reads), (1, 1))


class ScannedSwiftPeer:
    """Verified blocks own readiness; remote channel_ready may arrive earlier or later."""
    swift = True
    node = 'swift-node'
    transaction = 'funding-transaction'

    def __init__(self, ready_after=0, scan_error=None, wrong_id=False, wrong_transaction=False):
        self.process = SimpleNamespace(poll=lambda: None)
        self.phase, self.scanned, self.snapshot_reads = 'awaitingConfirmation', [], 0
        self.local_ready = False
        self.ready_after, self.scan_error, self.wrong_id = ready_after, scan_error, wrong_id
        self.broadcast_transaction = 'wrong-transaction' if wrong_transaction else self.transaction
        self.calls, self.events = [], []

    def event(self, kind):
        if kind == 'funding_required':
            return {'id': 'temporary', 'script': 'funding-script'}
        if kind == 'broadcast_funding':
            return {'id': 'funded-channel', 'transaction': self.broadcast_transaction}
        raise AssertionError('Unexpected event request')

    def drain(self):
        return []

    def call(self, command, **values):
        self.calls.append((command, values))
        if command == 'open':
            return {'temporary_id': 'temporary'}
        if command == 'fund':
            assert values == {'id': 'temporary', 'transaction': self.transaction, 'output': '1'}
            return {'status': 'funding_created'}
        if command == 'scan_begin':
            return {'next': '1'}
        if command == 'scan_block':
            height = int(values['height'])
            if self.scan_error is not None and height == 4:
                raise self.scan_error
            assert height == len(self.scanned) + 1
            self.scanned.append(height)
            if len(self.scanned) == 6:
                self.local_ready = True
                if self.ready_after == 0:
                    self.phase = 'ready'
            return {'height': values['height']}
        if command == 'height':
            assert values['height'] == '6' and self.scanned == list(range(1, 7))
            return {'height': '6', 'chain_events': '[]'}
        if command == 'snapshot':
            self.snapshot_reads += 1
            if self.scanned == list(range(1, 7)) and self.snapshot_reads >= self.ready_after:
                self.phase = 'ready'
            return {'id': 'wrong-channel' if self.wrong_id else 'funded-channel', 'phase': self.phase}
        if command == 'confirm':
            assert values == {'id': 'funded-channel', 'transaction': self.transaction}
            # Mirror the real phase guard and localReady early return: a
            # scan-confirmed channel may still await remote channel_ready.
            if self.phase == 'ready':
                raise RuntimeError('duplicate confirmation after verified scanner readiness')
            assert self.phase == 'awaitingConfirmation'
            if self.local_ready:
                return {}
            self.local_ready = True
            if self.ready_after == 0:
                self.phase = 'ready'
            return {}
        if command == 'recovery':
            assert self.phase == 'ready' and self.scanned == list(range(1, 7))
            assert values['id'] == 'funded-channel'
            return {}
        raise AssertionError('Unexpected command: ' + command)


class ScannedProviderPeer:
    """Real Peer identities are hashable keys in the production sync frontier."""
    swift = False
    node = 'provider'

    def __init__(self):
        self.broadcasts = []
        self.process = SimpleNamespace(poll=lambda: None)


class ScannerOwnedFundingTests(unittest.TestCase):
    def setUp(self):
        self.module = runpy.run_path(str(DRIVER))
        self.fixture = self.module['Fixture'].__new__(self.module['Fixture'])
        self.fixture.address, self.fixture.chain = 'mining-address', 'genesis'
        self.rpc_calls, self.mined = [], 0
        self.fixture.funding = lambda script, amount: ('funding-transaction', 1)
        self.fixture.rpc = self.rpc

    def rpc(self, method, *args):
        self.rpc_calls.append((method, args))
        if method == 'generatetoaddress':
            assert args == (6, 'mining-address')
            self.mined = 6
            return ['block-' + str(height) for height in range(1, 7)]
        if method == 'getblockcount':
            return self.mined
        if method == 'getblockhash':
            return 'block-' + str(args[0])
        if method == 'getblock':
            return 'raw-' + args[0]
        if method == 'sendrawtransaction':
            assert args == ('funding-transaction',)
            return 'funding-txid'
        if method == 'getaddressinfo':
            return {'scriptPubKey': 'recovery-script'}
        raise AssertionError('Unexpected RPC: ' + method)

    def provider(self, swift):
        provider = ScannedProviderPeer()
        def call(command, **values):
            if command == 'status':
                return {'height': 0, 'peers': [swift.node],
                        'channels': [{'peer': swift.node, 'usable': True}]}
            if command == 'open':
                assert values == {'peer': swift.node, 'public': False, 'amount': 1_000_000}
                return {}
            if command == 'fund':
                assert values == {'id': 'temporary', 'peer': swift.node, 'transaction': swift.transaction}
                provider.broadcasts.append(swift.transaction)
                return {}
            if command == 'block':
                return {}
            raise AssertionError('Unexpected provider command: ' + command)
        provider.call, provider.drain = call, lambda: []
        provider.event = lambda kind: {'temporary_id': 'temporary', 'script': 'funding-script', 'amount': 1_000_000}
        funding = provider.event('funding')
        provider.events = [funding]
        return provider

    def open(self, swift, fundee=False):
        provider = self.provider(swift)
        self.fixture.peers = [swift, provider]
        # Keep production sync and waits; only remove sleeping in this finite
        # state model. Neither an absent scan nor a wrong channel can pass.
        with patch.object(self.module['time'], 'sleep'):
            return (self.fixture.fund_swift_recipient(provider, swift) if fundee else
                    self.fixture.open_swift(swift, provider))

    def verified_once(self, swift):
        self.assertEqual(self.mined, 6)
        self.assertEqual(swift.scanned, list(range(1, 7)))
        commands = [command for command, _ in swift.calls]
        self.assertNotIn('confirm', commands)
        self.assertEqual(commands.count('recovery'), 1)
        self.assertEqual(sum(method == 'sendrawtransaction' for method, _ in self.rpc_calls), 1)

    def test_funder_already_ready_after_verified_scan_does_not_reconfirm(self):
        swift = ScannedSwiftPeer()
        self.assertEqual(self.open(swift), 'funded-channel')
        self.verified_once(swift)

    def test_funder_waits_for_late_remote_readiness_without_financial_retry(self):
        swift = ScannedSwiftPeer(ready_after=3)
        self.assertEqual(self.open(swift), 'funded-channel')
        self.assertEqual(swift.snapshot_reads, 3)
        self.verified_once(swift)
        self.assertEqual(sum(command == 'fund' for command, _ in swift.calls), 1)

    def test_fundee_already_ready_after_verified_scan_does_not_reconfirm(self):
        swift = ScannedSwiftPeer()
        self.assertEqual(self.open(swift, fundee=True)['peer'], swift.node)
        self.verified_once(swift)

    def test_fundee_waits_for_late_remote_readiness_without_reconfirm(self):
        swift = ScannedSwiftPeer(ready_after=4)
        self.assertEqual(self.open(swift, fundee=True)['peer'], swift.node)
        self.assertEqual(swift.snapshot_reads, 4)
        self.verified_once(swift)

    def test_scanner_failure_stays_fatal_without_confirmation_or_recovery(self):
        failure = RuntimeError('verified scan failed')
        swift = ScannedSwiftPeer(scan_error=failure)
        with self.assertRaises(RuntimeError) as caught:
            self.open(swift)
        self.assertIs(caught.exception, failure)
        self.assertFalse(any(command in ('confirm', 'recovery') for command, _ in swift.calls))

    def test_ready_wrong_channel_is_rejected_before_recovery(self):
        swift = ScannedSwiftPeer(wrong_id=True)
        with self.assertRaises(AssertionError):
            self.open(swift)
        self.assertFalse(any(command in ('confirm', 'recovery') for command, _ in swift.calls))

    def test_wrong_funding_broadcast_is_rejected_before_mining(self):
        swift = ScannedSwiftPeer(wrong_transaction=True)
        with self.assertRaises(AssertionError):
            self.open(swift)
        self.assertEqual(self.mined, 0)
        self.assertFalse(any(method == 'sendrawtransaction' for method, _ in self.rpc_calls))


if __name__ == '__main__':
    unittest.main()
