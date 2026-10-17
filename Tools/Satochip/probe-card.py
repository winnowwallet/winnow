#!/usr/bin/env python3
"""List PC/SC readers; optionally read a selected Satochip's public status."""
import argparse
import json
from smartcard.System import readers

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--reader-index', type=int, help='select a reader to send SELECT and GET STATUS only')
args = parser.parse_args()
available = readers()
result = {'readers': [str(reader) for reader in available]}
if args.reader_index is not None:
    if not 0 <= args.reader_index < len(available):
        parser.error('reader index is unavailable')
    connection = available[args.reader_index].createConnection()
    connection.connect()
    try:
        for command in [[0, 0xA4, 4, 0, 9, *bytes.fromhex('5361746f4368697000')], [0xB0, 0x3C, 0, 0, 0]]:
            data, sw1, sw2 = connection.transmit(command)
            if (sw1, sw2) != (0x90, 0):
                raise RuntimeError(f'card status {sw1:02x}{sw2:02x}')
        if len(data) < 4:
            raise RuntimeError('truncated status')
        result['protocol_version'] = data[:2]
        result['applet_version'] = data[2:4]
    finally:
        connection.disconnect()
print(json.dumps(result, indent=2))
