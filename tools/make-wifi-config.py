#!/usr/bin/env python3
"""Create the three Wi-Fi configuration files that stage 1's configure.sh installs on the camera.

Usage:
    make-wifi-config.py --ssid NAME --address 192.0.2.10/24 --mac aa:bb:cc:dd:ee:ff --out DIR [--passphrase-file FILE]

Writes DIR/station.hex, DIR/address and DIR/mac with mode 600. The passphrase is read from a no-echo prompt
(or from --passphrase-file); it is never accepted on the command line, where it would end up in shell history.

station.hex is the SSID followed by the WPA2 passphrase, each in a 32-byte field padded with NUL bytes,
hex-encoded (128 characters). It is equivalent to your Wi-Fi password: keep DIR private and delete it after
the upload. The drivers take fixed 32-byte fields and reject a field whose last byte is not NUL, so the SSID and
the passphrase are limited to 31 bytes each; WPA2 passphrases of 32 to 63 characters do not fit and are
rejected here. The camera's radio is
2.4 GHz only.

--mac must be the camera's own address from the original firmware (see jffs2-files.py), either as 12 hex
characters or with colons. --address is the static IPv4 address and prefix for the camera: the stock-derived
DHCP path was never verified, so a reserved static address is used.
"""
import argparse
import getpass
import ipaddress
import os
import re
import sys


def fail(message):
    sys.exit(f'error: {message}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--ssid', required=True)
    parser.add_argument('--address', required=True, help='static IPv4 address with prefix length, e.g. 192.0.2.10/24')
    parser.add_argument('--mac', required=True)
    parser.add_argument('--out', required=True)
    parser.add_argument('--passphrase-file')
    args = parser.parse_args()

    ssid = args.ssid.encode('utf-8')
    if not 1 <= len(ssid) <= 31:
        fail('the SSID must be 1 to 31 bytes (the drivers need a NUL after the 32-byte field)')

    try:
        interface = ipaddress.ip_interface(args.address)
    except ValueError:
        fail('--address must be an IPv4 address with a prefix length, for example 192.0.2.10/24')
    if interface.version != 4 or '/' not in args.address:
        fail('--address must be an IPv4 address with a prefix length, for example 192.0.2.10/24')
    if interface.ip == interface.network.network_address or interface.ip == interface.network.broadcast_address:
        fail('--address is the network or broadcast address of its subnet')

    mac = args.mac.strip().lower()
    if re.fullmatch(r'[0-9a-f]{12}', mac):
        mac = ':'.join(mac[index:index + 2] for index in range(0, 12, 2))
    if not re.fullmatch(r'([0-9a-f]{2}:){5}[0-9a-f]{2}', mac):
        fail('--mac must be 12 hex characters or six colon-separated bytes')
    if int(mac[:2], 16) & 1:
        fail('--mac is a multicast address')

    if args.passphrase_file:
        with open(args.passphrase_file, 'rb') as handle:
            passphrase = handle.read().rstrip(b'\r\n')
    else:
        passphrase = getpass.getpass('Wi-Fi passphrase (not echoed): ').encode('utf-8')
    if len(passphrase) < 8:
        fail('a WPA2 passphrase has at least 8 characters')
    if len(passphrase) > 31:
        fail('the passphrase is longer than the 31 bytes the camera drivers accept')

    out = args.out
    if os.path.exists(out) and os.listdir(out):
        fail(f'{out} already exists and is not empty')
    os.makedirs(out, mode=0o700, exist_ok=True)
    station = (ssid.ljust(32, b'\0') + passphrase.ljust(32, b'\0')).hex() + '\n'
    for name, content in (('station.hex', station), ('address', f'{interface}\n'), ('mac', f'{mac}\n')):
        descriptor = os.open(os.path.join(out, name), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as handle:
            handle.write(content)
    print(f'Wrote station.hex, address and mac to {out}. station.hex equals your Wi-Fi password: delete {out} after the upload.')


if __name__ == '__main__':
    main()
