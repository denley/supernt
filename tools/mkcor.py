#!/usr/bin/env python3
"""Turn a mistral-built .rbf into a Super Nt jailbreak .cor file.

Usage: mkcor.py original.cor patched.rbf out.cor

.cor files are ordinary uncompressed Cyclone V .rbf files with every byte
bit-reversed. mistral writes the per-frame EDCRC differently from Quartus for
frames holding MLAB memory, so for every configuration frame whose payload is
unchanged we copy the original frame verbatim. Changed frames keep mistral's
CRCs. The script reports which frames changed so edits can be sanity-checked.
"""
import sys

# e50f die (5CEBA2/5CEBA4): option frame + 64 PRAM blocks, then CRAM frames.
ORAM = 628
PRAM = 64 * 524
FRAME = 524
PAYLOAD = 516  # bytes before the per-frame CRC trailer

REV = bytes(int(f'{i:08b}'[::-1], 2) for i in range(256))


def main():
    orig_cor, patched, out = sys.argv[1:4]
    orig = open(orig_cor, 'rb').read().translate(REV)
    new = bytearray(open(patched, 'rb').read())
    if len(orig) != len(new):
        sys.exit(f'size mismatch: original {len(orig)}, patched {len(new)} (compressed output?)')

    if new[:ORAM + PRAM] != orig[:ORAM + PRAM]:
        diff = [i for i in range(ORAM + PRAM) if new[i] != orig[i]]
        print(f'note: header/PRAM differs at {len(diff)} bytes, first {diff[:8]}')

    changed = []
    start = ORAM + PRAM
    nframes = (len(orig) - start) // FRAME
    for f in range(nframes):
        a = start + f * FRAME
        if new[a:a + PAYLOAD] == orig[a:a + PAYLOAD]:
            new[a:a + FRAME] = orig[a:a + FRAME]
        else:
            changed.append(f)
    tail = start + nframes * FRAME
    if new[tail:] != orig[tail:]:
        print('note: postamble differs')

    open(out, 'wb').write(bytes(new).translate(REV))
    print(f'{len(changed)} frames changed: {changed[:20]}{" ..." if len(changed) > 20 else ""}')


if __name__ == '__main__':
    main()
