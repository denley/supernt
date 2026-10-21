#!/usr/bin/env python3
"""Make a 1 MB SA-1 test image from the 32 KB test ROM (quartus/snes/testrom) for the SDRAM
simulation (notes/snes-sdram.md, "Simulation"): the SA-1's second test-5 checksum view,
`lda.b #$C0` before `jsr Fletcher` (bank $C0 = ROM offset $00000 with CXB = 0), is patched to
bank $CF = ROM offset $F0000, the 32 KB image is placed at offset 0 and again at $F0000, and
everything in between is filled with a pattern that is never the table. With ROM_MASK $FFFFF
the SA-1 then reads the table from the far end of the 1 MB.

  mkfar.py in.sfc out.sfc [--bad]

--bad corrupts the far copy's table, so test 5 must fail: the far reads are really made.
"""
import sys

src, dst = sys.argv[1], sys.argv[2]
bad = '--bad' in sys.argv[3:]
rom = bytearray(open(src, 'rb').read())
if len(rom) != 0x8000:
    sys.exit(f'{src}: expected 32 KB')
# test 5, second view: ldx #RomTable-$8000 (A2 lo hi), lda #$C0 (A9 C0), ldy #I_SUM+4 (A0 ..),
# jsr Fletcher (20 ..). Every 8 KB block is a copy, so patch all four.
hits = [i for i in range(len(rom) - 8)
        if rom[i] == 0xA2 and rom[i + 3:i + 5] == b'\xA9\xC0' and rom[i + 5] == 0xA0 and rom[i + 8] == 0x20]
if len(hits) != 4:
    sys.exit(f'expected the lda #$C0 of test 5 in each 8 KB block, found {len(hits)}')
for i in hits:
    rom[i + 4] = 0xCF
table = rom[hits[0] + 1] | rom[hits[0] + 2] << 8      # RomTable - $8000 = file offset
img = bytearray((0x5A ^ (i >> 8) ^ (i * 7)) & 0xFF for i in range(0x100000))
img[0:0x8000] = rom
img[0xF0000:0xF8000] = rom
if bad:
    img[0xF0000 + table] ^= 0xFF
open(dst, 'wb').write(img)
print(f'{dst}: 1 MB, test 5 view 2 reads bank $CF (table at ROM offset ${0xF0000 + table:05X})'
      + (', far table corrupted' if bad else ''))
