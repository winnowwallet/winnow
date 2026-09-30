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
