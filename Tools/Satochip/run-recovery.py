#!/usr/bin/env python3
"""Run Winnow against an unmodified Satochip applet in jCardSim, never a card."""
import argparse
from contextlib import ExitStack
import hashlib
from importlib.metadata import version
import json
from pathlib import Path
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import zipfile

APPLET = '3aa97fdc32c3fe3afade3cd5eb7cd9d0d4bd197c'
CLIENT = '49d1100054f010baae952fe1f0c1104958c0a07b'
JAR_SHA256 = 'f6c3b6b8140401a47cf39d7b9dbfc052e381474c6c3b22018051024be1fca97c'
SOURCES_SHA256 = 'a6a0332427b4232d853a5c402cb056d82ebfdb88e765198977c803d950a19240'


class Lines:
    def __init__(self, command, stderr):
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=stderr, text=True, bufsize=1)
        self.output = queue.Queue()

        def collect():
            for line in self.process.stdout:
                self.output.put(line.strip())
            self.output.put(None)
        self.reader = threading.Thread(target=collect, daemon=True)
        self.reader.start()

    def send(self, line):
        self.process.stdin.write(line + '\n')
        self.process.stdin.flush()

    def read(self):
        line = self.output.get(timeout=30)
        if line is None:
            raise RuntimeError('development subprocess stopped; inspect its log')
        return line

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.reader.join(timeout=1)
        self.process.stdout.close()


class CardStatus(Exception):
    def __init__(self, status):
        self.status = status
        super().__init__(f'Satochip status {status:04x}')


class PrivateBitcoin:
    """Disposable regtest consensus check, with all P2P networking disabled."""
    def __init__(self, binaries, directory, log):
        directory.mkdir()
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        self.cli = [str(binaries / 'bitcoin-cli'), '-regtest', f'-datadir={directory}', f'-rpcport={port}']
        self.process = subprocess.Popen([
            str(binaries / 'bitcoind'), '-regtest', f'-datadir={directory}', f'-rpcport={port}',
            '-rpcbind=127.0.0.1', '-rpcallowip=127.0.0.1', '-networkactive=0', '-listen=0', '-dnsseed=0',
            '-fallbackfee=0.00002000', '-printtoconsole=0'],
            stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 20
            while True:
                try:
                    self.rpc('getblockchaininfo')
                    break
                except subprocess.CalledProcessError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError('private Bitcoin node did not start')
                    time.sleep(0.1)
            self.rpc('createwallet', 'satochip-lab')
            self.mining_address = self.rpc('getnewaddress', wallet=True)
            self.rpc('generatetoaddress', '999', self.mining_address)
        except BaseException:
            self.close()
            raise

    def rpc(self, *arguments, wallet=False):
        selection = ['-rpcwallet=satochip-lab'] if wallet else []
        output = subprocess.check_output([*self.cli, *selection, *arguments],
                                         stderr=subprocess.PIPE, text=True, timeout=120)
        try:
            return json.loads(output)
        except json.JSONDecodeError:
            return output.strip()

    def fund(self, script):
        descriptor = self.rpc('getdescriptorinfo', f'rawtr({script[4:]})')['descriptor']
        address = self.rpc('deriveaddresses', descriptor)[0]
        txid = self.rpc('sendtoaddress', address, '0.0008', wallet=True)
        self.rpc('generatetoaddress', '1', self.mining_address)
        raw = self.rpc('gettransaction', txid, wallet=True)['hex']
        transaction = self.rpc('decoderawtransaction', raw)
        output = next(row for row in transaction['vout'] if row['scriptPubKey']['hex'] == script)
        if self.rpc('getblockcount') != 1000:
            raise RuntimeError('unexpected private chain height')
        return {'private_regtest': True, 'txid': txid, 'vout': output['n']}

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()


class SimulatedCard:
    def __init__(self, args, classes, log, seed):
        from pysatochip.CardConnector import CardConnector
        from pysatochip.CardDataParser import CardDataParser
        self.lines = Lines([str(args.java_home / 'bin/java'),
                            '-Dcom.licel.jcardsim.randomdata.secure=1', '-cp',
                            f'{classes}:{args.jcardsim}', 'SimulatorBridge'], log)
        # Use the official secure channel and APDU client, replacing only its
        # reader connection. No CardConnector constructor/PCSC monitor runs.
        cc = CardConnector.__new__(CardConnector)
        cc.parser = CardDataParser()
        cc._sc_lock = threading.RLock()
        cc._sc_initializing = False
        cc.sc = None
        cc.needs_secure_channel = True
        cc.card_present = True
        cc.cardservice = SimpleNamespace(connection=SimpleNamespace(transmit=self.raw))
        cc.card_type = 'Satochip'
        cc.pin = [None, None]

        def checked(apdu):
            data, sw1, sw2 = CardConnector.card_transmit(cc, apdu)
            if (sw1, sw2) != (0x90, 0):
                raise CardStatus(sw1 * 256 + sw2)
            return data, sw1, sw2
        cc.card_transmit = checked
        self.client = cc
        try:
            status = cc.card_get_status()[3]
            if (status['protocol_minor_version'], status['applet_minor_version']) != (15, 1):
                raise RuntimeError('unexpected applet version')
            # All seeds/PINs are disposable fixtures in this simulator only.
            cc.card_setup(5, 1, b'123456', b'abcdefghijklmnop', 1, 1,
                          b'123456', b'abcdefghijklmnop', 32, 0, 1, 1, 1)
            cc.card_verify_PIN_deprecated(0, list(b'123456'))
            cc.card_bip32_import_seed(seed)
        except BaseException:
            self.lines.close()
            raise

    def raw(self, apdu):
        self.lines.send(bytes(apdu).hex())
        while True:
            line = self.lines.read()
            try:
                data = bytes.fromhex(line)
            except ValueError:
                continue  # jCardSim prints crypto initialization diagnostics.
            if len(data) < 2:
                raise RuntimeError('truncated simulated APDU response')
            return list(data[:-2]), data[-2], data[-1]

    def derive(self, path):
        public, _ = self.client.card_bip32_get_extendedkey(path)
        return public.get_public_key_bytes(compressed=True)

    def nonce(self, aggregate, message):
        public, encrypted = self.client.card_musig2_generate_nonce(255, aggregate, message, b'winnow-recovery-test')
        if len(public) != 68 or len(encrypted) != 144:
            raise RuntimeError('unexpected nonce response lengths')
        return public, encrypted

    def sign(self, encrypted, parameters):
        return self.client.card_musig2_sign_hash(
            255, encrypted, bytes.fromhex(parameters['b']), bytes.fromhex(parameters['ea']),
            parameters['r_has_even_y'], parameters['ggacc_is_1'])


def rejected(operation, status):
    try:
        operation()
    except CardStatus as error:
        if error.status == status:
            return
        raise
    raise RuntimeError(f'expected rejection {status:04x}')


def pinned(directory, revision):
    actual = subprocess.check_output(['git', '-C', str(directory), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != revision:
        raise RuntimeError(f'{directory.name}: expected revision {revision}')
    subprocess.run(['git', '-C', str(directory), 'diff', '--quiet', 'HEAD'], check=True)


def run(args, report):
    pinned(args.applet, APPLET)
    pinned(args.client, CLIENT)
    if hashlib.sha256(args.jcardsim.read_bytes()).hexdigest() != JAR_SHA256:
        raise RuntimeError('unexpected jCardSim jar checksum')
    if hashlib.sha256(args.jcardsim_sources.read_bytes()).hexdigest() != SOURCES_SHA256:
        raise RuntimeError('unexpected jCardSim source checksum')
    sys.path.insert(0, str(args.client))
    with tempfile.TemporaryDirectory(prefix='winnow-satochip-') as temporary, ExitStack() as stack:
        classes = Path(temporary)
        log = stack.enter_context(args.output.with_suffix('.log').open('w'))
        source_root = args.applet
        if args.counter_fix:
            source_root = classes / 'patched-applet'
            shutil.copytree(args.applet / 'src', source_root / 'src')
            patch = Path(__file__).with_name('counter-index.patch')
            subprocess.run(['patch', '--batch', '--forward', '-p1', '-i', str(patch)],
                           cwd=source_root, check=True, stdout=log, stderr=log)
        sources = sorted((source_root / 'src/org/satochip/applet').glob('*.java'))
        bridge = Path(__file__).with_name('SimulatorBridge.java')
        # jCardSim 3.0.5.11 ignores ByteContainer.length when converting a
        # shortened RSA exponent, interpreting 02 as 020001 after 010001.
        # Correct the simulator, not the applet, retaining the source license.
        with zipfile.ZipFile(args.jcardsim_sources) as archive:
            container = archive.read('com/licel/jcardsim/crypto/ByteContainer.java').decode()
        old = 'return new BigInteger(1, data);'
        if container.count(old) != 1:
            raise RuntimeError('unexpected simulator source')
        shim = classes / 'ByteContainer.java'
        shim.write_text(container.replace(old, 'return new BigInteger(1, java.util.Arrays.copyOf(data, length));'))
        subprocess.run([str(args.java_home / 'bin/javac'), '-cp', str(args.jcardsim),
                        '-d', str(classes), str(shim), *map(str, sources), str(bridge)], check=True, stderr=log)
        native = Lines([str(args.fixture), 'satochip-recovery'], log)
        stack.callback(native.close)
        fixture = json.loads(native.read())
        if not fixture.get('test_keys_only') or fixture.get('network') != 'signet':
            raise RuntimeError('refusing non-fixture input')
        node = None
        if args.bitcoin_bin:
            node = PrivateBitcoin(args.bitcoin_bin, classes / 'bitcoin', log)
            stack.callback(node.close)
            report['bitcoin_version'] = subprocess.check_output(
                [str(args.bitcoin_bin / 'bitcoind'), '--version'], text=True).splitlines()[0]
        native.send(json.dumps(node.fund(fixture['funding_script']) if node else {}))
        seed = bytes.fromhex(fixture['card_seed'])
        card = None
        encrypted = None
        parameters = None

        def new_card():
            result = SimulatedCard(args, classes, log, seed)
            stack.callback(result.lines.close)
            if result.derive(fixture['card_path']).hex() != fixture['card_public_key']:
                raise RuntimeError('restored hardware participant key differs')
            return result

        while True:
            event = json.loads(native.read())
            if event['action'] == 'complete':
                for check in ['watch_only_key_restore_rejected', 'wrong_phone_words_rejected']:
                    if event.get(check) is not True:
                        raise RuntimeError(f'missing native recovery check {check}')
                    report['checks'].append(check)
                break
            if event['action'] == 'nonce':
                if card is None or event['scenario'] in {'card-restored', 'both-restored'}:
                    old = encrypted
                    card = new_card()
                    if old is not None:
                        rejected(lambda: card.sign(old, parameters), 0x9c44)
                        report['checks'].append('replacement card rejects old encrypted nonce')
                aggregate, message = bytes.fromhex(event['aggregate_key']), bytes.fromhex(event['message'])
                public, encrypted = card.nonce(aggregate, message)
                native.send(json.dumps({'public_nonce': public.hex()}))
            elif event['action'] == 'sign':
                parameters = event
                corrupt = bytearray(encrypted)
                corrupt[-1] ^= 1
                rejected(lambda: card.sign(corrupt, parameters), 0x9c44)
                partial = card.sign(encrypted, parameters)
                if len(partial) != 32:
                    raise RuntimeError('unexpected partial signature length')
                rejected(lambda: card.sign(encrypted, parameters), 0x9c47)
                native.send(json.dumps({'partial_signature': partial.hex()}))
            elif event['action'] == 'result':
                if node:
                    consensus = node.rpc('testmempoolaccept', json.dumps([event['transaction_hex']]))[0]
                    if consensus.get('allowed') is not True:
                        raise RuntimeError(f'Bitcoin Core rejected recovery payment: {consensus.get("reject-reason")}')
                    event['consensus_allowed'] = True
                report['recovery'].append(event)
            else:
                raise RuntimeError('unexpected fixture event')
        if native.process.wait(timeout=10) != 0 or len(report['recovery']) != 4:
            raise RuntimeError('incomplete native recovery run')
        report['consensus_node_tested'] = node is not None
        wrong = SimulatedCard(args, classes, log, bytes([seed[0] ^ 1]) + seed[1:])
        stack.callback(wrong.lines.close)
        if wrong.derive(fixture['card_path']).hex() == fixture['card_public_key']:
            raise RuntimeError('wrong hardware seed reproduced the participant')
        report['checks'].append('wrong hardware seed does not reproduce the participant key')
        report['checks'] += ['tampered nonce rejected in all four scenarios', 'consumed nonce replay rejected in all four scenarios']

        # IDs survive reset; a consumed nonce must remain consumed afterwards.
        card.lines.send('RESET')
        if card.lines.read() != '9000':
            raise RuntimeError('simulator reset failed')
        card.client.card_verify_PIN_deprecated(0, list(b'123456'))
        card.derive(fixture['card_path'])
        rejected(lambda: card.sign(encrypted, parameters), 0x9c47)
        report['checks'].append('consumed nonce replay rejected after simulated reset')

        public, first = card.nonce(aggregate, message)
        for _ in range(16):
            card.nonce(aggregate, message)
        rejected(lambda: card.sign(first, parameters), 0x9c47)
        report['checks'].append('17th outstanding nonce evicts the first of 16 slots')

        # Simulated EEPROM fault injection reaches a boundary without 32,768
        # signing operations. It changes state, never upstream source or code.
        card.lines.send('COUNTER 32767')
        if card.lines.read() != '9000':
            raise RuntimeError('counter injection failed')
        for value in [32767, 32768, 32769]:
            try:
                public, _ = card.nonce(aggregate, message)
                status = '9000'
            except CardStatus as error:
                status = f'{error.status:04x}'
            report['counter_boundary'].append({'counter': value, 'status': status})
            if status != '9000':
                report['findings'].append({'id': 'signed-nonce-counter', 'counter': value, 'status': status,
                                           'detail': 'Signed short modulo produces a negative slot index in v0.15-0.1.'})
        if args.counter_fix:
            card.lines.send('COUNTER 65535')
            if card.lines.read() != '9000':
                raise RuntimeError('counter injection failed')
            _, before_wrap = card.nonce(aggregate, message)
            rejected(lambda: card.nonce(aggregate, message), 0x9c46)
            rejected(lambda: card.sign(before_wrap, parameters), 0x9c44)
            public, _ = card.nonce(aggregate, message)
            if public[-2:] != b'\x00\x01':
                raise RuntimeError('counter did not restart at 1 after rotation')
            report['checks'].append('counter overflow rotates MAC key, rejects old token and restarts at 1')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['applet', 'client', 'jcardsim', 'jcardsim-sources', 'java-home', 'fixture', 'output']:
        parser.add_argument('--' + name, required=True, type=lambda p: Path(p).resolve())
    parser.add_argument('--counter-fix', action='store_true',
                        help='apply the included one-line applet fix to a temporary source copy')
    parser.add_argument('--bitcoin-bin', type=lambda p: Path(p).resolve(),
                        help='optional Bitcoin Core bin directory for an isolated regtest mempool check')
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    report = {'applet_commit': APPLET, 'client_commit': CLIENT, 'jcardsim_sha256': JAR_SHA256,
              'mode': 'unmodified-applet-with-simulator-fix',
              'simulator_fix': 'ByteContainer.getBigInteger respects the active byte length; RSA multiplication self-check required',
              'simulator_entropy': 'OS-seeded RandomData; independent wrapping keys per simulated card',
              'physical_card_tested': False,
              'icloud_tested': False, 'consensus_node_tested': False,
              'recovery': [], 'checks': [], 'counter_boundary': [], 'findings': []}
    report.update({'counter_fix': args.counter_fix, 'python_version': sys.version.split()[0],
                   'fixture_sha256': hashlib.sha256(args.fixture.read_bytes()).hexdigest(),
                   'winnow_revision': subprocess.check_output(
                       ['git', '-C', str(Path(__file__).parent), 'rev-parse', 'HEAD'], text=True).strip()})
    report['java_version'] = subprocess.run([str(args.java_home / 'bin/java'), '-version'],
                                             check=True, capture_output=True, text=True).stderr.splitlines()[0]
    report['python_dependencies'] = {name: version(name) for name in ['pyscard', 'cryptography', 'pycryptodomex', 'pyOpenSSL']}
    report['winnow_worktree_dirty'] = bool(subprocess.check_output(
        ['git', '-C', str(Path(__file__).parent), 'status', '--porcelain'], text=True).strip())
    if args.counter_fix:
        report['mode'] = 'applet-with-counter-fix-and-simulator-fix'
        report['applet_patch_sha256'] = hashlib.sha256(Path(__file__).with_name('counter-index.patch').read_bytes()).hexdigest()
    try:
        run(args, report)
        report['result'] = 'complete_with_findings' if report['findings'] else 'passed'
    except Exception as error:
        report['result'] = 'failed'
        report['error'] = f'{type(error).__name__}: {error}'
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            report['subprocess_error'] = error.stderr.strip()
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f"Satochip recovery: {report['result']}; {len(report['recovery'])}/4 scenarios; report: {args.output}")
    return 0 if report['result'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
