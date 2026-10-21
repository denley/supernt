#!/usr/bin/env python3
"""Turn a PSF1 console font (8x16) into a $readmemh image of ASCII 0x00-0x7F.

Usage: psf2hex.py font.psf.gz out.hex

Output: 128 glyphs x 16 rows, one byte per line (bit 7 = leftmost pixel), glyph g row r at
line g*16 + r. Glyphs are looked up through the font's Unicode table, so the PSF's own glyph
order doesn't matter; code points without a glyph (controls) are blank.
"""
import gzip
import sys


def main():
    src, out = sys.argv[1], sys.argv[2]
    data = (gzip.open if src.endswith('.gz') else open)(src, 'rb').read()
    if data[:2] != b'\x36\x04':
        sys.exit('not a PSF1 font')
    mode, h = data[2], data[3]
    if h != 16:
        sys.exit(f'glyph height {h}, expected 16')
    n = 512 if mode & 1 else 256
    glyphs = [data[4 + i * h:4 + (i + 1) * h] for i in range(n)]
    cmap = {}
    if mode & 2:  # Unicode table: per glyph, UCS-2 code points ending in 0xFFFF (0xFFFE starts sequences)
        pos, g = 4 + n * h, 0
        while g < n and pos + 1 < len(data):
            u = data[pos] | data[pos + 1] << 8
            pos += 2
            if u == 0xFFFF:
                g += 1
            elif u != 0xFFFE:
                cmap.setdefault(u, g)
    else:
        cmap = {i: i for i in range(n)}
    with open(out, 'w') as f:
        for c in range(128):
            rows = glyphs[cmap[c]] if 0x20 <= c < 0x7F and c in cmap else bytes(h)
            for b in rows:
                f.write(f'{b:02x}\n')


if __name__ == '__main__':
    main()
