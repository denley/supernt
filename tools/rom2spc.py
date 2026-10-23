#!/usr/bin/env python3
"""Wrap a SNES ROM in a file the Super Nt's SPC player accepts and sends over the PIC32 link.

Usage: rom2spc.py ROM OUT.spc [--title TEXT] [--pad SIZE] [--length SECONDS]

The SPC player (Tools -> "Play SPC Files", JB7.2) checks that a file is an SPC and then writes
the whole file verbatim to link address 0x0000_FF00 + file offset (notes/hardware-tests.md,
22 Oct 2026; a 1 MB file arrived whole). quartus/snes_load takes the ROM from there, so the
file is:

  0x00000-0x101FF  a complete, valid, silent .spc (header + ID666 tag with the ROM's name as
                   the song title, 64 KB SPC700 RAM with `bra *` at $0400, DSP registers with
                   no voice keyed on and FLG = mute)
  0x10180-0x101BF  (the SPC format's unused 64 bytes) the info block below
  0x10200-         the ROM, without a 512-byte copier header (dropped when size % 32 KB = 512)

so ROM byte k arrives at link address 0x2_0100 + k. Info block (little-endian):

  +0x00  8  magic "SNTROM01"
  +0x08  4  ROM size in bytes
  +0x0C  4  CRC-32 (zlib) of the ROM
  +0x10  1  1 = a copier header was dropped
  +0x11  1  this tool's mapper guess, MiSTer ROM_TYPE encoding (bits 3-0: 0 LoROM, 1 HiROM,
            2 ExHiROM; bits 7-4: chip, 6 = SA-1, 7 = Super FX); the core decides by itself and shows both
  +0x12  1  header ROM size byte    +0x13  1  header RAM size byte
  +0x14 12  reserved (0)
  +0x20 32  ROM name (ASCII, space-padded): the core shows it on its diagnostics page

--pad SIZE appends filler after the ROM (whole file SIZE bytes), only for transfer tests.
--length SECONDS sets the ID666 song length (default 999, the most the text tag holds; a
short one is a test of what the player does when a "song" ends: snes_load v2 logs it).
Prints the sizes and CRC-32s the core's diagnostics page shows (whole file, ROM part) and the
header detection.
"""
import argparse
import os
import struct
import sys
import zlib

INFO_OFF = 0x10180
ROM_OFF = 0x10200
LINK_BASE = 0xFF00

MAP_NAMES = {0: 'LoROM', 1: 'HiROM', 2: 'ExHiROM'}


def tag(s, n):
    b = s.encode('ascii', 'replace')[:n]
    return b + b'\0' * (n - len(b))


def silent_spc(title, length=999):
    ram = bytearray(0x10000)
    ram[0x0400:0x0402] = bytes([0x2F, 0xFE])            # bra * (the SPC700 idles)
    dsp = bytearray(128)
    dsp[0x6C] = 0xE0                                     # FLG: soft reset, mute, echo off
    dsp[0x4C] = 0x00                                     # KON: nothing
    dsp[0x5C] = 0xFF                                     # KOFF: all voices off
    hdr = bytearray(0x100)
    hdr[0:33] = b'SNES-SPC700 Sound File Data v0.30'
    hdr[0x21:0x25] = bytes([26, 26, 26, 30])             # 26 = has ID666 tag
    hdr[0x25:0x2C] = bytes([0x00, 0x04, 0, 0, 0, 0, 0xEF])  # PC $0400, A X Y PSW, SP
    hdr[0x2E:0x4E] = tag(title, 32)                      # song title
    hdr[0x4E:0x6E] = tag('SNES ROM for snes_load', 32)   # game title
    hdr[0x7E:0x9E] = tag('supernt rom2spc', 32)          # comments
    hdr[0xA9:0xAC] = tag(str(length), 3)                # seconds (999 = 16:39, the most it holds)
    hdr[0xAC:0xB1] = tag('0', 5)
    hdr[0xB1:0xD1] = tag('supernt', 32)
    spc = hdr + ram + dsp + bytes(64) + ram[0xFFC0:]
    assert len(spc) == 0x10200
    return bytearray(spc)


def header_guess(rom):
    """Mapper detection like the Pocket's rom_parser.sv / MiSTer: score the LoROM, HiROM and
    ExHiROM header candidates; returns (rom_type, info dict of the winner, all scores)."""
    infos, scores = {}, {}
    for kind, base in ((0, 0x7FC0), (1, 0xFFC0), (2, 0x40FFC0)):
        if base + 0x40 > len(rom):
            scores[kind] = -1
            continue
        h = rom[base:base + 0x40]
        mapping, rtype, rsize, ssize, region, dev = h[0x15], h[0x16], h[0x17], h[0x18], h[0x19], h[0x1A]
        compl, csum = h[0x1C] | h[0x1D] << 8, h[0x1E] | h[0x1F] << 8
        s = 0
        if csum and compl and (csum + compl) == 0xFFFF:
            s += 4
        if dev == 0x33:
            s += 2
        if rtype < 8:
            s += 1
        if rsize < 16:
            s += 1
        if ssize < 8:
            s += 1
        if region < 14:
            s += 1
        chip = 0
        if mapping == 0x23 and rtype in (0x32, 0x34, 0x35):
            chip = 0x60                                  # SA-1
        elif mapping == 0x20 and rtype in (0x13, 0x14, 0x15, 0x1A):
            chip = 0x70                                  # Super FX (GSU)
        if kind == 0 and mapping in (0x20, 0x22):
            s += 2
        if kind == 1 and mapping == 0x21:
            s += 2
        if kind == 2:
            if mapping in (0x25, 0x35):
                s += 2
            if s:
                s += 4
        scores[kind] = s
        infos[kind] = dict(kind=kind, base=base, mapping=mapping, rtype=rtype, rsize=rsize,
                           ssize=ssize, region=region, csum=csum, compl=compl, chip=chip,
                           title=bytes(h[0:21]).decode('ascii', 'replace'))
    if not infos:
        return 0, None, scores
    lo, hi, ex = (scores.get(k, -1) for k in (0, 1, 2))
    # rom_parser.sv's order: LoROM if >= both, HiROM if >= ExHiROM, ExHiROM only if > 0
    kind = 0 if lo >= hi and lo >= ex else 1 if hi >= ex else 2 if ex > 0 else 0
    best = infos[kind]
    return kind | best['chip'], best, scores


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('rom')
    ap.add_argument('out')
    ap.add_argument('--title', help='name shown on the diagnostics page and in the ID666 tag')
    ap.add_argument('--pad', type=lambda s: int(s, 0), default=0)
    ap.add_argument('--length', type=int, default=999, help='ID666 song length in seconds (1-999)')
    a = ap.parse_args()

    rom = open(a.rom, 'rb').read()
    copier = len(rom) % 0x8000 == 512
    if copier:
        rom = rom[512:]
    title = a.title or os.path.splitext(os.path.basename(a.rom))[0]
    rom_type, hdr, scores = header_guess(rom)
    crc_rom = zlib.crc32(rom)

    spc = silent_spc(title, max(1, min(999, a.length)))
    info = bytearray(64)
    info[0:8] = b'SNTROM01'
    struct.pack_into('<II', info, 8, len(rom), crc_rom)
    info[0x10] = int(copier)
    info[0x11] = rom_type
    info[0x12] = hdr['rsize'] if hdr else 0
    info[0x13] = hdr['ssize'] if hdr else 0
    name = title.encode('ascii', 'replace')[:32]
    info[0x20:0x40] = name + b' ' * (32 - len(name))
    spc[INFO_OFF:INFO_OFF + 64] = info
    data = bytes(spc) + rom
    if a.pad > len(data):
        data += bytes(((i * 7) ^ (i >> 8)) & 0xFF for i in range(len(data), a.pad))
    open(a.out, 'wb').write(data)

    print(f'{a.out}: {len(data)} bytes = 0x{len(data):X}, CRC-32 whole file {zlib.crc32(data):08X}')
    print(f'  ROM {len(rom)} bytes = 0x{len(rom):X} at file offset 0x{ROM_OFF:X} '
          f'(link 0x{LINK_BASE + ROM_OFF:08X}-0x{LINK_BASE + ROM_OFF + len(rom) - 1:08X}),'
          f' CRC-32 {crc_rom:08X}' + (', 512-byte copier header dropped' if copier else ''))
    if hdr:
        kind = MAP_NAMES[hdr['kind']] + {0x60: ' + SA-1', 0x70: ' + Super FX'}.get(hdr['chip'], '')
        print(f'  header at ROM 0x{hdr["base"]:06X}: "{hdr["title"]}" map {hdr["mapping"]:02X} type'
              f' {hdr["rtype"]:02X} ROM {hdr["rsize"]:02X} RAM {hdr["ssize"]:02X} checksum'
              f' {hdr["csum"]:04X}/{hdr["compl"]:04X} -> {kind}, ROM_TYPE {rom_type:02X}'
              f' (scores Lo {scores[0]} Hi {scores[1]} ExHi {scores[2]})')
    mask = 1
    while mask < len(rom):
        mask <<= 1
    print(f'  ROM mask {mask - 1:06X}, title in the info block: "{title[:32]}"')


if __name__ == '__main__':
    main()
