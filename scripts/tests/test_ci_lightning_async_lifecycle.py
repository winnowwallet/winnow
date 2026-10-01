"""Failed construction must not leave a launched process or open log behind."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


DRIVER = Path(__file__).parents[1] / 'ci-lightning-async'

# Run the real constructor in another interpreter, with harmless executable
# stand-ins for Core/CLI. Observe the OS resources while the startup exception
# still owns its traceback; garbage collection must not hide a leaked log.
WORKER = r'''
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys

driver, directory = map(Path, sys.argv[1:])
loader = importlib.machinery.SourceFileLoader('async_fixture', str(driver))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
root, evidence, bitcoin = directory/'state', directory/'evidence', directory/'bin'
pid_file = root/'bitcoin/harmless.pid'
result = {}

def inspect_resources():
    pid = int(pid_file.read_text()) if pid_file.exists() else None
    result['child_pid'] = pid
    if pid is not None:
        try:
            waited, _ = os.waitpid(pid, os.WNOHANG)
            result['child_already_reaped'] = False
        except ChildProcessError:
            result['child_already_reaped'] = True
        try:
            os.kill(pid, 0)
            result['child_alive'] = True
        except ProcessLookupError:
            result['child_alive'] = False
    target = (evidence/'bitcoin.log').stat()
    result['open_log_descriptors'] = 0
    for name in os.listdir('/dev/fd'):
        try:
            descriptor = os.fstat(int(name))
        except (ValueError, OSError):
            continue
        if (descriptor.st_dev, descriptor.st_ino) == (target.st_dev, target.st_ino):
            result['open_log_descriptors'] += 1

try:
    module.Fixture(root, evidence, directory/'unused-harness', directory/'unused-swift', bitcoin)
    result['unexpected_success'] = True
except BaseException as error:
    result.update(error_class=type(error).__name__, error_message=str(error),
                  returncode=getattr(error, 'returncode', None),
                  stderr=getattr(error, 'stderr', None),
                  filename=getattr(error, 'filename', None))
    inspect_resources()
finally:
    # Failed pre-fix runs also remain harmless: record the leak first, then
    # clean only the unique child created by this test before exiting.
    if result.get('child_alive'):
        os.kill(result['child_pid'], signal.SIGKILL)
        os.waitpid(result['child_pid'], 0)
print(json.dumps(result))
'''


class FixtureStartupLifecycleTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='winnow-fixture-lifecycle-')
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        for name in ('state', 'evidence', 'bin'):
            (self.directory/name).mkdir()
        self.executable('bitcoin-cli', '''
import json
from pathlib import Path
import sys
import time
data = Path(next(argument.split('=', 1)[1] for argument in sys.argv if argument.startswith('-datadir=')))
deadline = time.monotonic() + 2
while not (data/'harmless.pid').exists() and time.monotonic() < deadline:
    time.sleep(0.01)
command = next(argument for argument in sys.argv[1:] if not argument.startswith('-'))
if command == 'getblockchaininfo':
    print(json.dumps({'chain': 'regtest'}))
else:
    print('original startup RPC failure', file=sys.stderr)
    sys.exit(19)
''')

    def executable(self, name, source):
        path = self.directory/'bin'/name
        path.write_text('#!' + sys.executable + '\n' + source)
        path.chmod(0o755)

    def harmless_core(self, ignore_terminate=False):
        self.executable('bitcoind', '''
import os
from pathlib import Path
import signal
import sys
import time
data = Path(next(argument.split('=', 1)[1] for argument in sys.argv if argument.startswith('-datadir=')))
if ''' + repr(ignore_terminate) + ''':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
(data/'harmless.pid').write_text(str(os.getpid()))
print('harmless process started', flush=True)
# A final safety limit exists even if a regression defeats worker cleanup.
time.sleep(30)
''')

    def failed_construction(self):
        completed = subprocess.run([sys.executable, '-c', WORKER, str(DRIVER), str(self.directory)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=40)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(completed.stdout)
        self.assertFalse(result.get('unexpected_success', False))
        self.assertEqual(result['open_log_descriptors'], 0, result)
        return result

    def core_events(self):
        return {event['event']: event for event in (json.loads(line) for line in
                (self.directory/'evidence/core-events.jsonl').read_text().splitlines())}

    def test_startup_rpc_failure_reaps_real_process_and_preserves_original_error(self):
        self.harmless_core()
        result = self.failed_construction()
        self.assertEqual(result['error_class'], 'CalledProcessError')
        self.assertEqual(result['returncode'], 19)
        self.assertEqual(result['stderr'], 'original startup RPC failure\n')
        self.assertIsNotNone(result['child_pid'])
        self.assertFalse(result['child_alive'])
        self.assertTrue(result['child_already_reaped'])
        events = self.core_events()
        self.assertEqual(events['launch_requested']['argv'][0], str(self.directory/'bin/bitcoind'))
        self.assertEqual(events['launched']['pid'], result['child_pid'])
        self.assertIsNone(events['launched']['poll'])
        self.assertEqual(events['startup_failure']['error_type'], 'CalledProcessError')
        self.assertEqual(events['startup_failure']['error_exit_code'], 19)
        self.assertIn({'path': 'harmless.pid', 'size': len(str(result['child_pid']))},
                      events['startup_failure']['data_files'])
        self.assertLess(events['startup_ready']['monotonic_ns'], events['startup_failure']['monotonic_ns'])
        self.assertIn('terminate_sent', events)
        self.assertIsNotNone(events['reaped']['poll'])
        self.assertIsNotNone(events['cleanup_finished']['poll'])

    def test_startup_failure_reaps_process_that_ignores_terminate(self):
        self.harmless_core(ignore_terminate=True)
        result = self.failed_construction()
        self.assertEqual(result['error_class'], 'CalledProcessError')
        self.assertEqual(result['returncode'], 19)
        self.assertEqual(result['stderr'], 'original startup RPC failure\n')
        self.assertFalse(result['child_alive'])
        self.assertTrue(result['child_already_reaped'])
        events = self.core_events()
        self.assertEqual(events['terminate_timeout']['timeout_seconds'], 15)
        self.assertIn('kill_sent', events)
        self.assertEqual(events['reaped']['poll'], -9)
        self.assertEqual(events['cleanup_finished']['poll'], -9)

    def test_launch_failure_closes_log_and_preserves_missing_executable_error(self):
        result = self.failed_construction()
        self.assertEqual(result['error_class'], 'FileNotFoundError')
        self.assertEqual(result['filename'], str(self.directory/'bin/bitcoind'))
        self.assertIsNone(result['child_pid'])
        events = self.core_events()
        self.assertEqual(events['launch_requested']['argv'][0], result['filename'])
        self.assertEqual(events['startup_failure']['error_type'], 'FileNotFoundError')
        self.assertIsNone(events['cleanup_finished']['pid'])

    def test_diagnostic_write_failure_preserves_original_error_and_child_cleanup(self):
        self.harmless_core()
        (self.directory/'evidence/core-events.jsonl').mkdir()
        result = self.failed_construction()
        self.assertEqual(result['error_class'], 'CalledProcessError')
        self.assertEqual(result['returncode'], 19)
        self.assertEqual(result['stderr'], 'original startup RPC failure\n')
        self.assertFalse(result['child_alive'])
        self.assertTrue(result['child_already_reaped'])


if __name__ == '__main__':
    unittest.main()
