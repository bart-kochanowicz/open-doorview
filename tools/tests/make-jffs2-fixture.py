#!/usr/bin/env python3
"""Writes a tiny JFFS2 image for testing jffs2-files.py. CRC fields are zero; the reader does not check them.

Contents: file "mac" (two versions, the newer one must win), file "big" (two zlib data nodes at different
offsets), file "raw" (uncompressed), file "rt" (rtime) and a file that was renamed from "oldname" to "newname"."""
import struct
import sys
import zlib


def pad(data):
    return data + b'\xff' * (-len(data) % 4)


def dirent(parent, version, ino, name):
    header = struct.pack('<HHI', 0x1985, 0xE001, 40 + len(name))
    body = struct.pack('<IIIIBB', parent, version, ino, 0, len(name), 8) + b'\0\0' + b'\0' * 12
    return pad(header + b'\0' * 4 + body[:28] + name.encode())


def inode(ino, version, offset, data, compression, payload=None):
    if payload is None:
        payload = zlib.compress(data) if compression == 6 else data
    header = struct.pack('<HHI', 0x1985, 0xE002, 68 + len(payload))
    fixed = struct.pack('<IIIHHIIIIIIIBBHII', ino, version, 0o100644, 0, 0, offset + len(data), 0, 0, 0,
                        offset, len(payload), len(data), compression, 0, 0, 0, 0)
    return pad(header + b'\0' * 4 + fixed + payload)


image = b''
image += dirent(1, 1, 2, 'mac') + inode(2, 1, 0, b'0000000000aa', 6)
image += inode(2, 2, 0, b'70aabbccddee', 6)
image += dirent(1, 2, 2, 'mac')
image += dirent(1, 1, 3, 'big') + inode(3, 1, 0, b'A' * 100, 6) + inode(3, 2, 100, b'B' * 50, 6)
image += dirent(1, 1, 4, 'raw') + inode(4, 1, 0, b'plain text\n', 0)
# rtime: (value, repeat) pairs; a repeat copies from just after the previous occurrence of the value. 'a', 'b', 'a'+2 gives ababa.
image += dirent(1, 1, 6, 'rt') + inode(6, 1, 0, b'ababa', 2, payload=bytes([97, 0, 98, 0, 97, 2]))
# A renamed file: the newer directory entry wins.
image += dirent(1, 1, 7, 'oldname') + inode(7, 1, 0, b'x', 0)
image += dirent(1, 2, 7, 'newname')
open(sys.argv[1], 'wb').write(image.ljust(4096, b'\xff'))
