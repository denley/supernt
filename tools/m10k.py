#!/usr/bin/env python3
"""Dump M10K block RAM contents from a mistral-cv .bt decompile.

Usage:
  m10k.py file.bt summary              per-block config and fill statistics
  m10k.py file.bt dump BLOCK [WIDTH]   hex dump of one block (e.g. M10K.003.002)
  m10k.py file.bt strings [MIN]        ASCII runs found under each width view

mistral prints each M10K as 256 rows "RAM.n" of 40 bits (rows that are all zero
are omitted). How narrower logical widths map onto the 40-bit rows isn't known
for sure, so 'dump' and 'strings' slice each row into 40/WIDTH words, low bits
first, which matches the obvious layout; verify against known contents.
"""
import re
import sys
from collections import defaultdict

ROWS, ROWBITS = 256, 40


def load(path):
    rams = defaultdict(lambda: [0] * ROWS)
    cfg = defaultdict(dict)
    pat = re.compile(r'^s (M10K\.\d+\.\d+):(\S+) (\S+)')
    for line in open(path):
        m = pat.match(line)
        if not m:
            continue
        blk, key, val = m.groups()
        if key.startswith('RAM.'):
            rams[blk][int(key[4:])] = int(val.replace('.', ''), 16)
        else:
            cfg[blk][key] = val
    for blk in cfg:
        rams[blk]  # every configured block gets an entry, even if all zero
    return rams, cfg


def words(rows, width):
    per = ROWBITS // width
    mask = (1 << width) - 1
    for r in rows:
        for k in range(per):
            yield (r >> (k * width)) & mask


def summary(rams, cfg):
    for blk in sorted(rams):
        rows = rams[blk]
        ones = sum(bin(r).count('1') for r in rows)
        distinct = len(set(rows))
        c = cfg[blk]
        print(f"{blk}  A_W={c.get('A_DATA_WIDTH', '-'):>3} B_W={c.get('B_DATA_WIDTH', '-'):>3} "
              f"ones={ones:5d}/{ROWS * ROWBITS} distinct_rows={distinct:3d}")


def dump(rows, width):
    ws = list(words(rows, width))
    digits = (width + 3) // 4
    per_line = max(1, 64 // (digits + 1))
    for i in range(0, len(ws), per_line):
        print(f'{i:04x}: ' + ' '.join(f'{w:0{digits}x}' for w in ws[i:i + per_line]))


def strings(rams, minlen):
    for blk in sorted(rams):
        for width in (8, 9, 10, 16, 20):
            ws = list(words(rams[blk], width))
            for bits8 in ({8: [0], 9: [0, 1], 10: [0, 1, 2], 16: [0, 8], 20: [0, 10]}[width]):
                bs = bytes((w >> bits8) & 0xff for w in ws)
                for m in re.finditer(rb'[ -~]{%d,}' % minlen, bs):
                    print(f'{blk} w{width}>>{bits8} @{m.start():04x}: {m.group().decode()}')


def main():
    path, cmd = sys.argv[1], sys.argv[2]
    rams, cfg = load(path)
    if cmd == 'summary':
        summary(rams, cfg)
    elif cmd == 'dump':
        dump(rams[sys.argv[3]], int(sys.argv[4]) if len(sys.argv) > 4 else ROWBITS)
    elif cmd == 'strings':
        strings(rams, int(sys.argv[3]) if len(sys.argv) > 3 else 6)


if __name__ == '__main__':
    main()
