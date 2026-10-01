"""Failed peer construction must reap its unregistered harmless child."""
import errno
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


DRIVER = Path(__file__).parents[1] / 'ci-lightning-async'

# Use the real Peer constructor in an isolated interpreter. Keep its original
# exception/traceback alive while observing OS ownership; collection must not
# disguise a child or selector left behind before Fixture can register it.
WORKER = r'''
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys

driver, directory = map(Path, sys.argv[1:3])
mode = sys.argv[3]
loader = importlib.machinery.SourceFileLoader('async_peer', str(driver))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
pid_file = directory/'harmless.pid'
command = [sys.executable, str(directory/'harmless-peer.py'), str(pid_file), mode]
if mode == 'missing':
    command[0] = str(directory/'missing-peer-executable')
result = {}

def inspect_resources(error):
    peer = None
    traceback = error.__traceback__
    while traceback is not None:
        candidate = traceback.tb_frame.f_locals.get('self')
        if isinstance(candidate, module.Peer):
            peer = candidate
        traceback = traceback.tb_next
    result['peer_in_traceback'] = peer is not None
    selector = getattr(peer, 'selector', None)
    result['selector_closed_or_never_created'] = selector is None or selector.get_map() is None
    process = getattr(peer, 'process', None)
    # Do not poll/wait here: that would reap a leaked child before measuring it.
    result['peer_returncode'] = process.returncode if process is not None else None
    pid = int(pid_file.read_text()) if pid_file.exists() else None
    result['child_pid'] = pid
    if pid is not None:
        try:
            os.waitpid(pid, os.WNOHANG)
            result['child_already_reaped'] = False
        except ChildProcessError:
            result['child_already_reaped'] = True
        try:
            os.kill(pid, 0)
            result['child_alive'] = True
        except ProcessLookupError:
            result['child_alive'] = False

with (directory/'peer.log').open('w') as log:
    try:
        module.Peer(command, log)
        result['unexpected_success'] = True
    except BaseException as error:
        result.update(error_class=type(error).__name__, error_args=error.args,
                      filename=getattr(error, 'filename', None),
                      errno=getattr(error, 'errno', None),
                      decode_message=getattr(error, 'msg', None))
        inspect_resources(error)
    finally:
        # A negative run records the ownership leak first, then cleans only
        # this unique harmless child. It never kills an unrelated process.
        if result.get('child_alive'):
            try:
                os.kill(result['child_pid'], signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(result['child_pid'], 0)
            except ChildProcessError:
                pass
print(json.dumps(result))
'''


class PeerStartupLifecycleTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='winnow-peer-lifecycle-')
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        (self.directory/'harmless-peer.py').write_text('''
import json
import os
from pathlib import Path
import sys
import time
Path(sys.argv[1]).write_text(str(os.getpid()))
reply = 'not-json' if sys.argv[2] == 'invalid-json' else json.dumps(
    {'ok': False, 'error': 'original initial rejection'})
print(reply, flush=True)
# This child remains live after the bad reply, so natural exit cannot mask a
# missing constructor cleanup. A final safety limit bounds a broken worker.
time.sleep(30)
''')

    def failed_construction(self, mode):
        completed = subprocess.run([sys.executable, '-c', WORKER, str(DRIVER),
                                    str(self.directory), mode],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, timeout=40)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(completed.stdout)
        self.assertFalse(result.get('unexpected_success', False), result)
        self.assertTrue(result['peer_in_traceback'], result)
        return result

    def assert_child_reaped(self, result):
        self.assertIsNotNone(result['child_pid'], result)
        self.assertFalse(result['child_alive'], result)
        self.assertTrue(result['child_already_reaped'], result)
        self.assertEqual(result['peer_returncode'], -9, result)
        self.assertTrue(result['selector_closed_or_never_created'], result)

    def test_invalid_initial_json_reaps_real_child_and_preserves_decode_error(self):
        result = self.failed_construction('invalid-json')
        self.assertEqual(result['error_class'], 'JSONDecodeError', result)
        self.assertEqual(result['decode_message'], 'Expecting value', result)
        self.assert_child_reaped(result)

    def test_rejected_initial_reply_reaps_real_child_and_preserves_original_reply(self):
        result = self.failed_construction('rejected')
        self.assertEqual(result['error_class'], 'AssertionError', result)
        self.assertEqual(result['error_args'],
                         [{'ok': False, 'error': 'original initial rejection'}], result)
        self.assert_child_reaped(result)

    def test_missing_executable_preserves_error_without_assuming_partial_resources(self):
        result = self.failed_construction('missing')
        self.assertEqual(result['error_class'], 'FileNotFoundError', result)
        self.assertEqual(result['errno'], errno.ENOENT, result)
        self.assertEqual(result['filename'], str(self.directory/'missing-peer-executable'), result)
        self.assertIsNone(result['child_pid'], result)
        self.assertIsNone(result['peer_returncode'], result)
        self.assertTrue(result['selector_closed_or_never_created'], result)


if __name__ == '__main__':
    unittest.main()
