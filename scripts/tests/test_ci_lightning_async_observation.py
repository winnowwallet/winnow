"""Observation must preserve driver results, fatal bounds and private inputs."""
import io
import json
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import Mock, patch


DRIVER = Path(__file__).parents[1] / 'ci-lightning-async'


class Process:
    def __init__(self, replies):
        self.pid = 4321
        self.stdin = io.BytesIO()
        self.stdout = io.BytesIO(b''.join(json.dumps(reply).encode() + b'\n' for reply in replies))
        self.returncode = None
        self.kill = Mock(side_effect=self.killed)
        self.wait = Mock(return_value=-9)

    def killed(self):
        self.returncode = -9

    def poll(self):
        return self.returncode


class PeerObservationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='winnow-peer-observation-')
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.module = runpy.run_path(str(DRIVER))
        self.log = (self.directory / 'recipient.log').open('w')
        self.addCleanup(self.log.close)
        self.selector = Mock()
        self.selector.select.return_value = [object()]
        self.process = Process([{'ok': True, 'node': 'private-initial-payload', 'port': 1},
                                {'ok': True, 'result': {'private-success-payload': 'private-preimage'}}])
        self.launch = patch.object(self.module['subprocess'], 'Popen', return_value=self.process)
        self.launcher = self.launch.start()
        self.addCleanup(self.launch.stop)
        self.selection = patch.object(self.module['selectors'], 'DefaultSelector', return_value=self.selector)
        self.selection.start()
        self.addCleanup(self.selection.stop)

    def peer(self):
        return self.module['Peer'](['private-argv', 'private-seed'], self.log)

    def records(self):
        return [json.loads(line) for line in (self.directory / 'peer-events.jsonl').read_text().splitlines()]

    def test_real_peer_methods_preserve_result_and_lifecycle_without_exporting_inputs(self):
        peer = self.peer()
        result = peer.call('offer', seed='private-command-seed', key='private-command-key')
        self.assertEqual(result, {'private-success-payload': 'private-preimage'})
        peer.close()
        self.process.kill.assert_called_once_with()
        self.process.wait.assert_called_once_with(timeout=10)
        self.assertTrue(all(call.args == (30,) for call in self.selector.select.call_args_list))
        raw = (self.directory / 'peer-events.jsonl').read_text()
        self.assertNotIn('private-', raw)
        records = self.records()
        self.assertEqual([row['event'] for row in records],
                         ['start_started', 'start_completed', 'command_started', 'command_completed',
                          'close_started', 'close_completed'])
        self.assertEqual(records[1]['pid'], self.process.pid)
        self.assertEqual(records[3]['command'], 'offer')
        self.assertTrue(records[3]['success'])
        self.assertTrue(all(row['role'] == 'recipient' for row in records))
        self.assertTrue(all(records[index]['monotonic_ns'] <= records[index + 1]['monotonic_ns']
                            for index in range(len(records) - 1)))

    def test_actual_peer_read_timeout_remains_fatal_at_original_30_second_bound(self):
        peer = self.peer()
        self.selector.select.reset_mock()
        self.selector.select.return_value = []
        with self.assertRaisesRegex(TimeoutError, 'Peer stalled'):
            peer.call('status', seed='private-command-seed')
        self.selector.select.assert_called_once_with(30)
        self.assertEqual(len(self.process.stdin.getvalue().splitlines()), 1)
        last = self.records()[-1]
        self.assertEqual((last['event'], last['command'], last['error_type'], last['success']),
                         ('command_failed', 'status', 'TimeoutError', False))
        self.assertNotIn('private-', (self.directory / 'peer-events.jsonl').read_text())

    def test_diagnostic_write_failure_cannot_replace_cancellation_or_retry_command(self):
        peer = self.peer()
        output = self.directory / 'peer-events.jsonl'
        output.unlink()
        output.mkdir()
        failure = KeyboardInterrupt('private-original-error-text')
        peer.read = Mock(side_effect=failure)
        with self.assertRaises(KeyboardInterrupt) as caught:
            peer.call('connect', key='private-command-key')
        self.assertIs(caught.exception, failure)
        peer.read.assert_called_once_with()
        self.assertEqual(len(self.process.stdin.getvalue().splitlines()), 1)

    def test_failed_stage_keeps_original_45_second_wait_and_condition_count(self):
        check = Mock(return_value=False)
        with patch.object(self.module['time'], 'monotonic', side_effect=[0, 0, 45]), \
             patch.object(self.module['time'], 'sleep') as sleep:
            with self.assertRaisesRegex(TimeoutError, 'Async peer condition did not become true'):
                self.module['observed_wait'](self.directory, 'recipient_received', check)
        check.assert_called_once_with()
        sleep.assert_called_once_with(0.05)
        records = self.records()
        self.assertEqual([row['event'] for row in records], ['stage_started', 'stage_failed'])
        self.assertEqual(records[-1]['stage'], 'recipient_received')
        self.assertEqual(records[-1]['error_type'], 'TimeoutError')
        self.assertFalse(records[-1]['success'])


if __name__ == '__main__':
    unittest.main()
