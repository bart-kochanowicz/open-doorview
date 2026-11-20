#!/usr/bin/env python3
"""List or read files from a JFFS2 image without mounting it (read-only, pure Python).

Usage:
    jffs2-files.py list <image> [name ...]       print name, size and SHA-256 prefix of each file
    jffs2-files.py cat  <image> <name>           write the file's content to stdout

The image can be a full SPI flash dump or a single partition. JFFS2 keeps every version of a file as
separate nodes; the newest directory entry and the newest data for each offset win, which is what this
script does. The same name can exist in several partitions of a dump (the stock firmware keeps a backup
copy of its data partition), so every match is printed. Compression types zlib, rtime and none are
supported; a file that uses another type is reported as unsupported.

The stock firmware stores the camera's MAC address in a file named `mac` as 12 hexadecimal characters
without separators. Read it from your own backup with:    jffs2-files.py cat original-a.bin mac
"""
import hashlib
import struct
import sys
import zlib

NODE_DIRENT = 0xE001
NODE_INODE = 0xE002
MAGIC = 0x1985


def rtime_decompress(source, length):
    positions = [0] * 256
    out = bytearray()
    index = 0
    while len(out) < length:
        value = source[index]
        repeat = source[index + 1]
        index += 2
        out.append(value)
        last = positions[value]
        positions[value] = len(out)
        for _ in range(repeat):
            out.append(out[last])
            last += 1
    return bytes(out)


def parse(data):
    dirents = {}
    inodes = {}
    position = 0
    size = len(data)
    while position + 12 <= size:
        magic, node_type, total = struct.unpack_from('<HHI', data, position)
        if magic != MAGIC or total < 12 or position + total > size:
            position += 4
            continue
        if node_type == NODE_DIRENT:
            _parent, version, ino, _mctime, name_size, _kind = struct.unpack_from('<IIIIBB', data, position + 12)
            name = data[position + 40:position + 40 + name_size].decode('latin1')
            if ino and (ino not in dirents or dirents[ino][0] < version):
                dirents[ino] = (version, name)
        elif node_type == NODE_INODE:
            fields = struct.unpack_from('<IIIHHIIIIIIIBBHII', data, position + 12)
            ino, version, _mode, _uid, _gid, _isize, _atime, _mtime, _ctime, offset, csize, dsize, compression = fields[:13]
            payload = data[position + 68:position + 68 + csize]
            if compression == 0:
                raw = payload
            elif compression == 6:
                raw = zlib.decompress(payload)
            elif compression == 2:
                raw = rtime_decompress(payload, dsize)
            else:
                raw = None
            inodes.setdefault(ino, []).append((version, offset, raw, dsize))
        position += (total + 3) & ~3
    return dirents, inodes


def assemble(nodes):
    content = bytearray()
    for _version, offset, raw, size in sorted(nodes, key=lambda node: node[0]):
        if raw is None:
            return None
        if len(content) < offset + size:
            content.extend(b'\0' * (offset + size - len(content)))
        content[offset:offset + size] = raw
    return bytes(content)


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ('list', 'cat'):
        sys.exit(__doc__)
    command, image = sys.argv[1], sys.argv[2]
    names = set(sys.argv[3:])
    with open(image, 'rb') as handle:
        data = handle.read()
    dirents, inodes = parse(data)
    matches = [(name, ino) for ino, (_version, name) in dirents.items() if not names or name in names]
    if command == 'cat':
        if len(names) != 1:
            sys.exit('cat needs exactly one file name')
        files = []
        for name, ino in matches:
            content = assemble(inodes.get(ino, []))
            if content is not None and content not in files:
                files.append(content)
        if not files:
            sys.exit('file not found')
        if len(files) > 1:
            sys.exit('the name exists with different contents in several places; use "list" and inspect each')
        sys.stdout.buffer.write(files[0])
        return
    for name, ino in sorted(matches):
        content = assemble(inodes.get(ino, []))
        if content is None:
            print(f'{name}\tunsupported compression')
        else:
            print(f'{name}\t{len(content)}\t{hashlib.sha256(content).hexdigest()[:16]}')


if __name__ == '__main__':
    main()
