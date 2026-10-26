#!/usr/bin/env python3
"""The v8 save test's ROM and save (make sim-snes-load-save): the SA-1 test ROM with RAM size
byte 05 (32 KB BW-RAM, 8 dump pages) and its checksum fixed, and a 30000-byte save (not a whole
number of pages: the core must fill the rest of BW-RAM with 0s, the dump's last page too).

Usage: mk_savetest.py SA1TEST.sfc OUT.sfc OUT.sav
"""
import hashlib
import struct
import sys

rom = bytearray(open(sys.argv[1], 'rb').read())
rom[0x7FD8] = 0x05
struct.pack_into('<HH', rom, 0x7FDC, 0xFFFF, 0x0000)
csum = sum(rom) & 0xFFFF
struct.pack_into('<HH', rom, 0x7FDC, csum ^ 0xFFFF, csum)
open(sys.argv[2], 'wb').write(rom)
sav, h = bytearray(), b'snes_load v8 save test'
while len(sav) < 30000:
    h = hashlib.sha256(h).digest()
    sav += h
sav[1000:5000] = bytes(4000)                  # a run of 0s, as unused save space looks
open(sys.argv[3], 'wb').write(sav[:30000])
