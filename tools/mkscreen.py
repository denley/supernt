#!/usr/bin/env python3
"""Compile a text screen layout into the template ROM of quartus/common/textmode.sv.

Usage: mkscreen.py screen.txt out.hex

The screen is 80 x 22 cells; a line `%%page` starts the next page (each page is padded to 22
lines). Plain text is shown as is (white). `{W.D}` shows the low D hex
digits of status word W (0-31; 0-63 for quartus/common/overlay.sv, which reads bit 5 of W from
template bit 3) in cyan, most significant first; `{W.D@N}` starts at nibble N
instead of 0; `:C` at the end picks the colour (w = white, c = cyan, y = yellow, g = green). `[C]` switches the colour of the following plain
text on that line (`[w]` back to white). `{?F:TEXT}` is TEXT (current colour) shown only while
bit F (0-31) of the flag word (textmode's FLAG_WORD) is 1, blank otherwise. `{E:n}` is n
external character cells (textmode shows the byte the caller supplies for the cell). Lines
longer than 80 cells are an error.

Template word (16 bits): bit 15 = field; bits 14:13 = colour; field: bits 12:8 = word,
bits 2:0 = nibble, bit 3 = word bit 5 (overlay.sv only); text: bits 6:0 = ASCII (7F = external), bit 12 = conditional, bits 11:7 =
its flag bit.
"""
import re
import sys

COLS, ROWS = 80, 22
COLOURS = {'w': 0, 'c': 1, 'y': 2, 'g': 3}


def compile_line(line, n):
    cells, colour, pos = [], 0, 0
    for m in re.finditer(r'\{(\d+)\.(\d)(?:@(\d))?(?::([wcyg]))?\}|\[([wcyg])\]|\{\?(\d+):([^}]*)\}'
                         r'|\{E:(\d+)\}|(.)', line):
        if m.group(8):
            cells += [colour << 13 | 0x7F] * int(m.group(8))
        elif m.group(6):
            fl = int(m.group(6))
            if not 0 <= fl < 32:
                sys.exit(f'line {n}: bad flag {m.group(0)}')
            for ch in m.group(7):
                if not 0x20 <= ord(ch) < 0x7F:
                    sys.exit(f'line {n}: character {ch!r} not in the font')
                cells.append(colour << 13 | 1 << 12 | fl << 7 | ord(ch))
        elif m.group(1):
            w, d, lo = int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)
            c = COLOURS[m.group(4) or 'c']
            if not (0 <= w < 64 and 1 <= d and lo + d <= 8):
                sys.exit(f'line {n}: bad field {m.group(0)}')
            cells += [0x8000 | c << 13 | (w & 31) << 8 | (w >> 5) << 3 | k
                      for k in range(lo + d - 1, lo - 1, -1)]
        elif m.group(5):
            colour = COLOURS[m.group(5)]
        else:
            ch = ord(m.group(9))
            if not 0x20 <= ch < 0x7F:
                sys.exit(f'line {n}: character {m.group(9)!r} not in the font')
            cells.append(colour << 13 | ch)
    if len(cells) > COLS:
        sys.exit(f'line {n}: {len(cells)} cells, max {COLS}')
    return cells + [0x20] * (COLS - len(cells))


def main():
    src, out = sys.argv[1], sys.argv[2]
    pages = [[]]
    for line in open(src).read().rstrip('\n').split('\n'):
        if line.strip() == '%%page':
            pages.append([])
        else:
            pages[-1].append(line)
    with open(out, 'w') as f:
        for p, lines in enumerate(pages):
            if len(lines) > ROWS:
                sys.exit(f'page {p}: {len(lines)} lines, max {ROWS}')
            lines += [''] * (ROWS - len(lines))
            for n, line in enumerate(lines, 1):
                for c in compile_line(line, f'{p}:{n}'):
                    f.write(f'{c:04x}\n')


if __name__ == '__main__':
    main()
