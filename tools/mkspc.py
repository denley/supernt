#!/usr/bin/env python3
"""Write a minimal .spc file that plays a steady A major chord (A4, C#5, E5 square waves).

Usage: mkspc.py out.spc

A test file for the Super Nt SPC player with known contents: a 16-sample square wave
BRR loop on voices 0-2 and a 4-instruction SPC700 program that keys them on.
"""
import sys

PROG = 0x0400   # SPC700 program
DIR = 0x0200    # sample directory (DSP DIR = page 2)
SAMPLE = 0x0300 # one looping BRR block


def tag(s, n):
    b = s.encode('ascii')[:n]
    return b + b'\0' * (n - len(b))


def main():
    ram = bytearray(0x10000)
    # mov $f2,#$4c ; mov $f3,#$07 (KON voices 0-2) ; bra *
    ram[PROG:PROG + 8] = bytes([0x8F, 0x4C, 0xF2, 0x8F, 0x07, 0xF3, 0x2F, 0xFE])
    ram[DIR:DIR + 4] = bytes([SAMPLE & 0xFF, SAMPLE >> 8] * 2)  # start, loop
    # BRR header: shift 11, filter 0, loop + end; 8 samples of +7 then 8 of -8.
    ram[SAMPLE:SAMPLE + 9] = bytes([0xB3] + [0x77] * 4 + [0x88] * 4)

    dsp = bytearray(128)
    dsp[0x0C] = dsp[0x1C] = 0x60  # main volume
    dsp[0x6C] = 0x20              # FLG: unmuted, echo writes off
    dsp[0x5D] = DIR >> 8
    # 16-sample period: pitch p plays 32000*p/4096 samples/s -> 2000*p/4096 Hz.
    for v, hz in enumerate((440.0, 554.37, 659.26)):
        p = round(hz * 4096 / 2000)
        base = v << 4
        dsp[base + 0] = dsp[base + 1] = 0x28  # voice volume
        dsp[base + 2], dsp[base + 3] = p & 0xFF, p >> 8
        dsp[base + 4] = 0      # sample 0
        dsp[base + 5] = 0      # ADSR off, use GAIN
        dsp[base + 7] = 0x7F   # direct gain, full

    hdr = bytearray(0x100)
    hdr[0:33] = b'SNES-SPC700 Sound File Data v0.30'
    hdr[0x21:0x25] = bytes([26, 26, 26, 30])  # 26 = has ID666 tag
    hdr[0x25:0x2C] = bytes([PROG & 0xFF, PROG >> 8, 0, 0, 0, 0, 0xEF])  # PC A X Y PSW SP
    hdr[0x2E:0x4E] = tag('Super Nt test chord', 32)
    hdr[0x4E:0x6E] = tag('supernt', 32)
    hdr[0x7E:0x9E] = tag('A major, square waves', 32)
    hdr[0xA9:0xAC] = tag('600', 3)   # seconds before fade
    hdr[0xAC:0xB1] = tag('5000', 5)  # fade, ms
    hdr[0xB1:0xD1] = tag('supernt', 32)

    with open(sys.argv[1], 'wb') as f:
        f.write(hdr + ram + dsp + bytes(64) + ram[0xFFC0:])


if __name__ == '__main__':
    main()
