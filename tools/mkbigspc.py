#!/usr/bin/env python3
"""Make a large .spc test file and print CRC-32s of it and its parts.

Usage: mkbigspc.py base.spc out.spc SIZE

out = base (a normal 66048-byte .spc) followed by a pattern up to SIZE bytes. The PIC32's
loader shows whether it sends the whole file or only the .spc structure; the CRCs identify
which bytes arrive (quartus/hwtest logs CRC-32 per run).
"""
import sys
import zlib

base, out, size = sys.argv[1], sys.argv[2], int(sys.argv[3], 0)
b = open(base, 'rb').read()
pat = bytes(((i * 7) ^ (i >> 8)) & 0xFF for i in range(len(b), size))
data = b + pat
open(out, 'wb').write(data)
parts = [('whole file', 0, len(data)), ('header 0-FF', 0, 0x100), ('RAM 100-100FF', 0x100, 0x10100),
         ('DSP 10100-1017F', 0x10100, 0x10180), ('extra RAM 101C0-101FF', 0x101C0, 0x10200),
         ('after 10200', 0x10200, len(data))]
for name, a, e in parts:
    if e > a:
        print(f'{name:22} {e - a:8x} bytes  CRC-32 {zlib.crc32(data[a:e]):08X}')
