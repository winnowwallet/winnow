"""A cold simulator needs the selected Xcode's GUI before recording can start."""
import importlib.machinery
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


loader = importlib.machinery.SourceFileLoader(
    'ci_lightning_ui', str(Path(__file__).parents[1] / 'ci-lightning-ui'))
spec = importlib.util.spec_from_loader(loader.name, loader)
ui = importlib.util.module_from_spec(spec)
loader.exec_module(ui)


class DisplayBootstrapTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.developer = self.root / 'Selected Xcode.app/Contents/Developer'
        self.developer.mkdir(parents=True)
        self.results = self.root / 'results'
        self.results.mkdir()

    def selected_xcode(self):
        return patch.object(ui.subprocess, 'check_output',
                            return_value=str(self.developer) + '\n')

    def render(self, args, log, **kwargs):
        if args[1:4] == ['simctl', 'io', 'owned-device']:
            Path(args[-1]).write_bytes(b'nonempty screenshot')

    def test_supported_xcode_layouts_open_exact_bundle_before_rendering(self):
        for application in (self.developer / 'Applications/Simulator.app',
                            self.developer.parent / 'Applications/DeviceHub.app'):
            with self.subTest(application=application.name):
                application.mkdir(parents=True)
                with self.selected_xcode(), patch.object(ui, 'run', side_effect=self.render) as run:
                    ui.prepare_display('owned-device', self.results)
                calls = run.call_args_list
                self.assertEqual(calls[0].args[0], ['open', '-a', str(application)])
                self.assertEqual(len(calls), 2)
                self.assertEqual(calls[1].args[0][0:5],
                                 ['xcrun', 'simctl', 'io', 'owned-device', 'screenshot'])
                self.assertTrue(all(call.kwargs['timeout'] == 60 for call in calls))
                application.rmdir()

    def test_missing_selected_gui_does_not_fall_back_or_render(self):
        with self.selected_xcode(), patch.object(ui, 'run') as run:
            with self.assertRaisesRegex(FileNotFoundError, 'selected Xcode'):
                ui.prepare_display('owned-device', self.results)
        run.assert_not_called()

    def test_gui_launch_failure_stops_before_rendering(self):
        (self.developer / 'Applications/Simulator.app').mkdir(parents=True)
        with self.selected_xcode(), patch.object(ui, 'run',
                side_effect=subprocess.CalledProcessError(1, ['open'])) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                ui.prepare_display('owned-device', self.results)
        self.assertEqual(run.call_count, 1)

    def test_screenshot_timeout_fails_without_claiming_display_ready(self):
        (self.developer / 'Applications/Simulator.app').mkdir(parents=True)
        failure = subprocess.TimeoutExpired(['xcrun', 'simctl', 'io'], 60)
        with self.selected_xcode(), patch.object(ui, 'run', side_effect=[None, failure]):
            with self.assertRaises(subprocess.TimeoutExpired):
                ui.prepare_display('owned-device', self.results)
        self.assertFalse((self.results / 'display-ready.png').exists())

    def test_empty_frame_is_not_display_readiness(self):
        (self.developer / 'Applications/Simulator.app').mkdir(parents=True)
        (self.results / 'display-ready.png').write_bytes(b'')
        with self.selected_xcode(), patch.object(ui, 'run'):
            with self.assertRaisesRegex(AssertionError, 'no screenshot'):
                ui.prepare_display('owned-device', self.results)


if __name__ == '__main__':
    unittest.main()
