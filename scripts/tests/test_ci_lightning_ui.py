"""The Lightning journey records from its first frame, rebooting an idle simulator."""
import importlib.machinery
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


loader = importlib.machinery.SourceFileLoader(
    'ci_lightning_ui', str(Path(__file__).parents[1] / 'ci-lightning-ui'))
spec = importlib.util.spec_from_loader(loader.name, loader)
ui = importlib.util.module_from_spec(spec)
loader.exec_module(ui)


class Process:
    """One recordVideo process; exits once signalled."""
    def __init__(self):
        self.signals = []

    def poll(self):
        return None if not self.signals else 0

    def send_signal(self, sig):
        self.signals.append(sig)

    def wait(self, timeout=None):
        return 0


class Recorder:
    """recordVideo stand-in: its log reports a frame only on chosen attempts."""
    def __init__(self, starts):
        self.starts = starts

    def __call__(self, args, stdout, stderr):
        stdout.write('Recording started\n' if self.starts.pop(0) else '')
        stdout.flush()
        return Process()


class RecordingStartTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.results = Path(temporary.name)
        self.commands = []

    def run_command(self, args, log, **kwargs):
        self.commands.append(args[2] if args[:2] == ['xcrun', 'simctl'] else args[0])

    def start(self, starts):
        recorder = Recorder(list(starts))
        waits = iter(starts)
        def fake_wait(check, seconds=90):
            if not next(waits):
                raise TimeoutError('no frame')
            self.assertTrue(check())
        with patch.object(ui, 'run', self.run_command), patch.object(ui.subprocess, 'Popen', recorder), \
                patch.object(ui, 'wait', fake_wait):
            return ui.start_recording('owned-device', self.results)

    def test_a_ready_simulator_records_on_the_first_boot(self):
        self.start([True])
        self.assertEqual(self.commands, ['bootstatus'])

    def test_an_idle_simulator_is_rebooted_until_it_records(self):
        self.start([False, True])
        self.assertEqual(self.commands, ['bootstatus', 'shutdown', 'bootstatus'])

    def test_three_frameless_boots_fail_without_a_partial_recording(self):
        (self.results / 'journey.mp4').write_bytes(b'partial')
        with self.assertRaises(TimeoutError):
            self.start([False, False, False])
        self.assertFalse((self.results / 'journey.mp4').exists())
        self.assertEqual(self.commands.count('bootstatus'), 3)


if __name__ == '__main__':
    unittest.main()


PEER = '033881db148c4b2dc1cb1a1a0471380ac9af354fff921fe2c86eed8789a8416da6'
SOCKET_LOSS = f'''2026-10-01T01:32:45.539Z DEBUG   {PEER}-connectd: Activating for message WIRE_OPEN_CHANNEL
2026-10-01T01:32:46.299Z DEBUG   {PEER}-openingd-chan#1: pid 52439, msgfd 83
2026-10-01T01:32:47.489Z DEBUG   {PEER}-hsmd: Got WIRE_HSMD_GET_PER_COMMITMENT_POINT
2026-10-01T01:32:47.489Z INFO    {PEER}-openingd-chan#1: Peer connection lost
2026-10-01T01:32:47.489Z INFO    {PEER}-chan#1: Owning subdaemon openingd died (62208)
2026-10-01T01:34:22.122Z DEBUG   {PEER}-lightningd: peer_disconnected
'''


class ReferenceRetryTests(unittest.TestCase):
    """Only the stock daemons' own socket failure reruns the journey."""
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.results = Path(temporary.name)
        self.evidence = self.results / 'fixture/evidence'

    def failure(self, log):
        self.evidence.mkdir(parents=True, exist_ok=True)
        (self.evidence / 'invoice-cln.log').write_text(log)
        with patch.object(ui.sys, 'platform', 'darwin'):
            return ui.reference_socket_failure(self.evidence)

    def test_only_a_daemons_lost_socket_with_the_app_still_connected_is_classified(self):
        self.assertTrue(self.failure(SOCKET_LOSS))
        self.assertTrue(self.failure(f'2026-10-01T01:39:50.224Z **BROKEN** {PEER}-closingd-chan#1: STATUS_FAIL_HSM_IO: Bad reply\n'))
        for log in (SOCKET_LOSS.replace('01:34:22.122Z', '01:32:48.000Z'),  # the app really disconnected
                    SOCKET_LOSS.replace('Owning subdaemon openingd died', 'Peer transient failure'),
                    SOCKET_LOSS + f'2026-10-01T01:35:00.000Z **BROKEN** {PEER}-chan#1: Funding transaction spent\n',
                    ''):
            with self.subTest(log=log[-80:]):
                self.assertFalse(self.failure(log))
        (self.evidence / 'invoice-cln.log').write_text(SOCKET_LOSS)
        with patch.object(ui.sys, 'platform', 'linux'):
            self.assertFalse(ui.reference_socket_failure(self.evidence))

    def test_a_classified_failure_reruns_once_and_keeps_the_failed_attempt(self):
        import subprocess
        calls = []
        def journey():
            calls.append(len(calls) + 1)
            if len(calls) == 1:
                self.failure(SOCKET_LOSS)
                (self.results / 'journey.mp4').write_bytes(b'first')
                (self.results / 'ui-tests.log').write_text('failed')
                raise subprocess.CalledProcessError(65, 'xcodebuild')
            return {'kind': 'reference'}
        with patch.object(ui.sys, 'platform', 'darwin'):
            self.assertEqual(ui.with_reference_retry(self.results, journey), {'kind': 'reference'})
        self.assertEqual(calls, [1, 2])
        kept = self.results / 'attempt-1'
        self.assertEqual((kept / 'journey.mp4').read_bytes(), b'first')
        self.assertTrue((kept / 'fixture/evidence/invoice-cln.log').exists())
        self.assertFalse((self.results / 'fixture').exists(), 'the rerun starts from a fresh fixture')

    def test_any_other_failure_or_a_second_classified_one_is_final(self):
        import subprocess
        def unclassified():
            self.failure('')
            raise subprocess.CalledProcessError(65, 'xcodebuild')
        with patch.object(ui.sys, 'platform', 'darwin'), self.assertRaises(subprocess.CalledProcessError):
            ui.with_reference_retry(self.results, unclassified)
        self.assertFalse((self.results / 'attempt-1').exists())
        calls = []
        def always():
            calls.append(1)
            self.failure(SOCKET_LOSS)
            raise subprocess.CalledProcessError(65, 'xcodebuild')
        with patch.object(ui.sys, 'platform', 'darwin'), self.assertRaises(subprocess.CalledProcessError):
            ui.with_reference_retry(self.results, always)
        self.assertEqual(len(calls), ui.JOURNEY_ATTEMPTS)
