#!/usr/bin/env python3
"""Follow LAB flip-flops back through single-input (buffer) LUTs.

Usage: ffsrc.py file.bt PORT...   e.g. LAB.016.026.0:FFB0

For an FF output port, looks at its ALM half's LUT mask. If the half is a pure
buffer/inverter of one input (5-input half masks aaaaaaaa, cccccccc, f0f0f0f0,
ff00ff00, ffff0000 or their complements), traces that input's routing back to
its source port and repeats. Otherwise prints the half's mask and all of its
routed inputs. Index bits per nextpnr: A=0 B=1 C/D=2 E=3 F=4; low 32 bits of
LUT_MASK are the top half (FFT*), high 32 the bottom (FFB*).
"""
import re
import sys

sys.path.insert(0, __file__.rsplit('/', 1)[0])
import trace  # noqa: E402

# nextpnr mistral/lab.cc: MLAB LUT masks are stored with this bit permutation
# (stored bit MLAB_PERMUTE[i] holds logical bit i).
MLAB_PERMUTE = [0, 1, 4, 5, 8, 9, 12, 13, 29, 28, 25, 24, 21, 20, 17, 16,
                2, 3, 6, 7, 10, 11, 14, 15, 31, 30, 27, 26, 23, 22, 19, 18,
                32, 33, 36, 37, 40, 41, 44, 45, 61, 60, 57, 56, 53, 52, 49, 48,
                34, 35, 38, 39, 42, 43, 46, 47, 63, 62, 59, 58, 55, 54, 51, 50]

BUF = {0xaaaaaaaa: 'A', 0xcccccccc: 'B', 0xf0f0f0f0: 'CD', 0xff00ff00: 'E', 0xffff0000: 'F'}


def load_efsel(path):
    """ALMs whose TEF_SEL/BEF_SEL is set to F (default is E)."""
    sel = set()
    pat = re.compile(r'^s ((?:M?LAB)\.\d+\.\d+):([TB])EF_SEL\.(\d+) F')
    for line in open(path):
        m = pat.match(line)
        if m:
            sel.add((f'{m[1]}.{m[3]}', m[2]))
    return sel


def load_masks(path):
    masks = {}
    pat = re.compile(r'^s ((?:M?LAB)\.\d+\.\d+):LUT_MASK\.(\d+) ([0-9a-f]+)\.([0-9a-f]+)')
    for line in open(path):
        m = pat.match(line)
        if m:
            v = (int(m[3], 16) << 32) | int(m[4], 16)
            if m[1].startswith('MLAB'):
                v = sum(((v >> MLAB_PERMUTE[i]) & 1) << i for i in range(64))
            masks[f'{m[1]}.{m[2]}'] = (v >> 32, v & 0xffffffff)
    return masks


def half_inputs(drv, alm, top):
    ins = {}
    for pin in ('A', 'B', 'C', 'D', 'E0', 'F0', 'E1', 'F1'):
        port = f'{alm}:{pin}'
        if port in drv:
            ins[pin] = trace.back(drv, port)[-1]
    return ins


def follow(drv, masks, port, depth=0, maxdepth=8, efsel=frozenset()):
    pad = '  ' * depth
    m = re.match(r'((?:M?LAB)\.\d+\.\d+\.\d+):FF([TB])', port)
    if not m or depth > maxdepth:
        print(f'{pad}{port}')
        return
    alm, half = m[1], m[2]
    hi, lo = masks.get(alm, (0, 0))
    mask = lo if half == 'T' else hi
    ins = half_inputs(drv, alm, half == 'T')
    which = BUF.get(mask) or BUF.get(mask ^ 0xffffffff)
    if mask in (0, 0xffffffff):
        # Constant LUT: the FF loads from the E/F bypass. Per nextpnr, the top
        # half's bypass picks E0 or F1, the bottom's E1 or F0.
        f = (alm, half) in efsel
        pin = {('T', False): 'E0', ('T', True): 'F1', ('B', False): 'E1', ('B', True): 'F0'}[(half, f)]
        print(f'{pad}{port} = bypass {pin}')
        if pin in ins:
            follow(drv, masks, ins[pin], depth + 1, maxdepth, efsel)
        else:
            print(f'{pad}  (bypass {pin} unrouted; ALM inputs {ins})')
        return
    if which:
        inv = '' if mask in BUF else ' (inv)'
        cands = {'A': ['A'], 'B': ['B'], 'CD': ['C', 'D'],
                 'E': ['E0' if half == 'T' else 'E1'], 'F': ['F0' if half == 'T' else 'F1']}[which]
        src = [ins[c] for c in cands if c in ins]
        print(f'{pad}{port} = buf {which}{inv}')
        for s in src:
            follow(drv, masks, s, depth + 1, maxdepth, efsel)
        if not src:
            print(f'{pad}  (input {which} unrouted; ALM inputs {ins})')
    else:
        print(f'{pad}{port} = lut {mask:08x} ' + ' '.join(f'{k}<{v}' for k, v in ins.items()))


def main():
    path, ports = sys.argv[1], sys.argv[2:]
    drv, _ = trace.load(path)
    masks = load_masks(path)
    efsel = load_efsel(path)
    for p in ports:
        follow(drv, masks, p, efsel=efsel)


if __name__ == '__main__':
    main()
